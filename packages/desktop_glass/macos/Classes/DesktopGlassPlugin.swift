import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreImage
import Metal

public class DesktopGlassPlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private var session: GlassCaptureSession?
  private var generation: Int64 = 0
  private var permissionRequested = false

  init(registrar: FlutterPluginRegistrar) { self.registrar = registrar }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "glassusage/desktop_glass", binaryMessenger: registrar.messenger)
    let plugin = DesktopGlassPlugin(registrar: registrar)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "capabilities":
      result(["realtimeCapture": true, "selfExclusion": true,
              "requiresPermission": !CGPreflightScreenCaptureAccess()])
    case "start":
      let fps = (args["targetFps"] as? NSNumber)?.intValue ?? 60
      guard (1...60).contains(fps) else {
        result(FlutterError(code: "argument", message: "targetFps must be between 1 and 60", details: nil))
        return
      }
      guard let view = registrar.view, let window = view.window else {
        result(FlutterError(code: "windowUnavailable", message: "Flutter window is unavailable", details: nil))
        return
      }
      generation += 1
      let token = generation
      session?.end()
      session = nil
      if !CGPreflightScreenCaptureAccess() {
        if !permissionRequested {
          permissionRequested = true
          _ = CGRequestScreenCaptureAccess()
        }
        guard CGPreflightScreenCaptureAccess() else {
          result(FlutterError(code: "permissionDenied", message: "Screen Recording permission is required; enable it in System Settings and retry or relaunch", details: nil))
          return
        }
      }
      Task { @MainActor in
        do {
          let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
          guard self.generation == token else {
            result(FlutterError(code: "cancelled", message: "Capture start was superseded", details: nil))
            return
          }
          let capture = try GlassCaptureSession(id: token, window: window, view: view,
              registry: self.registrar.textures, content: content, fps: fps)
          self.session = capture
          capture.begin()
          result(capture.startResult())
        } catch {
          result(FlutterError(code: "captureUnavailable", message: error.localizedDescription, details: nil))
        }
      }
    case "stop", "pause", "resume", "stats":
      let requested = (args["sessionId"] as? NSNumber)?.int64Value ?? -1
      let owned = session?.id == requested
      if call.method == "stats" {
        result(owned ? session!.stats() : ["active": false, "sessionId": requested])
      } else {
        if owned {
          if call.method == "stop" {
            generation += 1
            session?.end()
            session = nil
          } else {
            session?.setPaused(call.method == "pause")
          }
        }
        result(nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  deinit { session?.end() }
}

// 合并审核：主线程维护窗口几何和纹理注册；捕获队列只保存最新桌面并低频抽样；
// Flutter 栅格线程取纹理时才 GPU 裁剪，池与裁剪缓存也仅由该线程访问。
// 跨线程共享的桌面帧、位置、计数和生命周期状态使用 lock，GPU 工作不持有该锁。
private final class GlassCaptureSession: NSObject, FlutterTexture, SCStreamOutput, SCStreamDelegate {
  let id: Int64
  private(set) var textureId: Int64 = 0
  private weak var window: NSWindow?
  private weak var view: NSView?
  private let registry: FlutterTextureRegistry
  private var content: SCShareableContent
  private let fps: Int
  private let lock = NSLock()
  private let outputQueue = DispatchQueue(label: "glassusage.desktop-glass.frames", qos: .userInteractive)
  private var stream: SCStream?
  private var latest: CVPixelBuffer?
  private var desktop: CVPixelBuffer?
  private var activeStreamID: ObjectIdentifier?
  private var recoveryEpoch: Int64 = 1
  private var hasValidFrame = false
  private var captureState = "waitingForFrame"
  private var lastFrameAt: TimeInterval = 0
  private var lastFrameStatus = "started"
  private var frameDeadline: TimeInterval = 0
  private var rebuildAttempts = 0
  private let imageContext: CIContext
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  // Pool and crop cache are confined to Flutter's raster thread.
  private var cropPool: CVPixelBufferPool?
  private var cropSize = CGSize.zero
  private var renderedVersion: Int64 = -1
  private var renderedEpoch: Int64 = -1
  private var renderedRect = CGRect.null
  private var geometryTimer: Timer?
  private var notificationPending = false
  private var sampledAt: TimeInterval = 0
  private var frames: Int64 = 0
  private var presented: Int64 = 0
  private var cropPoolMisses: Int64 = 0
  private var staleCropDrops: Int64 = 0
  private var changes: Int64 = 0
  private var lastHash: UInt64 = 0
  private var luminance: Double = 0
  private var failure = ""
  private var ended = false
  private var paused = false
  private var streaming = false
  private var transitioning = false
  private var updating = false
  private var displayId: CGDirectDisplayID = 0
  private var displayOrigin = CGPoint.zero
  private var displayPoints = CGSize.zero
  private var sampleRect = CGRect.zero
  private var retryAt: TimeInterval = 0
  private var needsRebuild = false
  private var observers: [NSObjectProtocol] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var watchdogTimer: Timer?
  private let started = ProcessInfo.processInfo.systemUptime

  init(id: Int64, window: NSWindow, view: NSView, registry: FlutterTextureRegistry,
       content: SCShareableContent, fps: Int) throws {
    self.id = id
    self.window = window
    self.view = view
    self.registry = registry
    self.content = content
    self.fps = fps
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw NSError(domain: "GlassUsage.DesktopGlass", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable for live glass"])
    }
    imageContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    super.init()
    let geometry = try makeGeometry()
    let own = content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
    guard !own.isEmpty else { throw captureError("Cannot identify the own window for exclusion") }
    displayId = geometry.display.displayID
    displayOrigin = geometry.display.frame.origin
    displayPoints = geometry.display.frame.size
    sampleRect = windowRectInDisplay() ?? .zero
    let filter = SCContentFilter(display: geometry.display, excludingWindows: own)
    let initialStream = SCStream(filter: filter, configuration: geometry.config, delegate: self)
    try initialStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
    stream = initialStream
    activeStreamID = ObjectIdentifier(initialStream)
    textureId = registry.register(self)
    guard textureId != 0 else { throw captureError("Cannot register desktop texture") }
  }

  private func captureError(_ message: String) -> NSError {
    NSError(domain: "GlassUsage.DesktopGlass", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  /// Display-local card rect (top-down points, equal to texture pixels because
  /// the capture runs at point resolution). Shared by cropping and diagnostics.
  private func windowRectInDisplay() -> CGRect? {
    guard let window = window, let view = view, let screen = window.screen else { return nil }
    let client = window.convertToScreen(view.convert(view.bounds, to: nil))
    // AppKit is bottom-up in logical points; the texture is top-down.
    return CGRect(x: client.minX - screen.frame.minX,
                  y: screen.frame.maxY - client.maxY,
                  width: client.width, height: client.height)
  }

  private func makeGeometry() throws -> (display: SCDisplay, config: SCStreamConfiguration) {
    guard let window = window, let screen = window.screen,
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
      throw captureError("The window display is unavailable; reconnect capture")
    }
    let config = SCStreamConfiguration()
    // Whole display at point resolution (textureScale 1 px per point). The
    // glass blurs and refracts the backdrop, so the Retina softness is
    // invisible; bandwidth stays a quarter of the pixel-resolution capture.
    config.width = max(1, Int(display.frame.width.rounded()))
    config.height = max(1, Int(display.frame.height.rounded()))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.queueDepth = 3
    config.showsCursor = false
    return (display, config)
  }

  private func mappingInfo() -> [String: Any] {
    // Both platforms publish a window-sized texture; no Dart translation.
    ["displayMapped": false, "textureScale": 1.0]
  }

  func startResult() -> [String: Any] {
    var result: [String: Any] = ["sessionId": id, "textureId": textureId]
    result.merge(mappingInfo()) { _, new in new }
    return result
  }

  func begin() {
    let center = NotificationCenter.default
    for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        self?.reconcile()
      })
    }
    observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
        object: window, queue: .main) { [weak self] _ in
      self?.recoverIfPaused()
    })
    // Re-crop the latest display frame on moves, even if the desktop is idle.
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        guard let self = self else { return }
        let rect = self.windowRectInDisplay() ?? .zero
        self.lock.lock(); self.sampleRect = rect; self.lock.unlock()
        self.scheduleFrame()
      })
    }
    // Display changes require a new content filter / stream.
    observers.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
      self?.updateGeometry()
    })
    observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      self?.updateGeometry()
    })
    workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: NSWorkspace.shared,
      queue: .main) { [weak self] _ in
        self?.recoverAfterSpaceChange()
      })
    // Common-mode geometry polling also runs inside AppKit's native drag loop.
    // It never reconfigures the capture stream.
    geometryTimer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
      guard let self = self, let rect = self.windowRectInDisplay() else { return }
      self.lock.lock()
      let changed = self.sampleRect != rect
      self.sampleRect = rect
      self.lock.unlock()
      if changed { self.scheduleFrame() }
    }
    RunLoop.main.add(geometryTimer!, forMode: .common)
    // Slow watchdog: start/stop retries and anything the notifications missed.
    watchdogTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.checkFrameDeadline()
      self?.updateGeometry()
      self?.reconcile()
    }
    RunLoop.main.add(watchdogTimer!, forMode: .common)
    reconcile()
  }

  func setPaused(_ value: Bool) {
    lock.lock()
    paused = value
    let frameIsValid = hasValidFrame
    if value {
      hasValidFrame = false
      captureState = "paused"
      desktop = nil
      latest = nil
    }
    lock.unlock()
    if !value && window?.isOnActiveSpace == true && !frameIsValid {
      recoverAfterSpaceChange()
      return
    }
    reconcile()
  }

  private func recoverIfPaused() {
    lock.lock(); let needsRecovery = paused; lock.unlock()
    if needsRecovery { recoverAfterSpaceChange() }
  }

  private func recoverAfterSpaceChange(retry: Int = 0) {
    guard !ended, let window = window, window.isVisible, !window.isMiniaturized else { return }
    guard window.isOnActiveSpace else {
      // AppKit may post the Space-change notification before the window's
      // active-Space membership settles. Retry briefly, then let the watchdog
      // handle later visibility changes without keeping a retry loop alive.
      if retry < 3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
          self?.recoverAfterSpaceChange(retry: retry + 1)
        }
      }
      return
    }
    lock.lock()
    // A Space-change can be the only reliable resume signal after AppKit hides
    // the mini-window. If it is visible on the active Space again, the prior
    // lifecycle pause is stale and must not block its new capture stream.
    paused = false
    recoveryEpoch += 1
    activeStreamID = nil
    hasValidFrame = false
    captureState = "recovering"
    lastFrameAt = 0
    frameDeadline = ProcessInfo.processInfo.systemUptime + 5
    desktop = nil
    latest = nil
    lock.unlock()
    rebuildAttempts = 0
    needsRebuild = true
    refreshContent(rebuild: true)
  }

  private func checkFrameDeadline() {
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    guard !ended, !paused, !hasValidFrame, frameDeadline > 0,
          now >= frameDeadline else { lock.unlock(); return }
    frameDeadline = 0
    hasValidFrame = false
    rebuildAttempts += 1
    let exhausted = rebuildAttempts > 2
    captureState = exhausted ? "failed" : "retrying"
    failure = "No complete capture frame after recovery"
    lock.unlock()
    needsRebuild = !exhausted
    retryAt = now + 1
  }

  private func reconcile() {
    guard !transitioning, let stream = stream else { return }
    lock.lock(); let isPaused = paused; let isEnded = ended; lock.unlock()
    let shouldRun = !isEnded && !isPaused && window?.isVisible == true &&
        window?.isMiniaturized == false && window?.isOnActiveSpace == true
    if isPaused { lock.lock(); captureState = "paused"; hasValidFrame = false; lock.unlock() }
    guard !shouldRun || ProcessInfo.processInfo.systemUptime >= retryAt else { return }
    guard shouldRun != streaming else { return }
    if shouldRun && rebuildAttempts > 2 {
      lock.lock(); captureState = "failed"; hasValidFrame = false; lock.unlock()
      return
    }
    transitioning = true
    let completion: (Error?) -> Void = { [self] error in
      DispatchQueue.main.async {
        self.transitioning = false
        self.streaming = error == nil ? shouldRun : false
        if let error = error {
          self.rebuildAttempts += 1
          self.lock.lock()
          self.failure = error.localizedDescription
          self.hasValidFrame = false
          self.captureState = self.rebuildAttempts > 2 ? "failed" : "retrying"
          self.frameDeadline = 0
          self.lock.unlock()
          self.retryAt = ProcessInfo.processInfo.systemUptime + 1
          self.needsRebuild = self.rebuildAttempts <= 2
        } else {
          self.lock.lock()
          self.hasValidFrame = false
          self.captureState = isPaused ? "paused" : "waitingForFrame"
          if shouldRun {
            self.frameDeadline = ProcessInfo.processInfo.systemUptime + 5
          }
          self.lock.unlock()
        }
      }
    }
    if shouldRun { stream.startCapture(completionHandler: completion) }
    else { stream.stopCapture(completionHandler: completion) }
  }

  private func updateGeometry() {
    guard !ended, !updating, !transitioning,
          ProcessInfo.processInfo.systemUptime >= retryAt else { return }
    if needsRebuild {
      if rebuildAttempts > 2 {
        lock.lock(); captureState = "failed"; hasValidFrame = false; lock.unlock()
        needsRebuild = false
        return
      }
      refreshContent(rebuild: true)
      return
    }
    guard let stream = stream else { return }
    do {
      let geometry = try makeGeometry()
      guard geometry.display.displayID != displayId ||
            geometry.display.frame.origin != displayOrigin ||
            geometry.display.frame.size != displayPoints else { return }
      updating = true
      let own = content.windows.filter { $0.windowID == CGWindowID(window!.windowNumber) }
      let filter = SCContentFilter(display: geometry.display, excludingWindows: own)
      Task { @MainActor in
        do {
          try await stream.updateContentFilter(filter)
          try await stream.updateConfiguration(geometry.config)
          self.displayId = geometry.display.displayID
          self.displayOrigin = geometry.display.frame.origin
          self.displayPoints = geometry.display.frame.size
          let rect = self.windowRectInDisplay() ?? .zero
          self.lock.lock(); self.sampleRect = rect; self.lock.unlock()
        } catch {
          self.lock.lock(); self.failure = error.localizedDescription; self.lock.unlock()
        }
        self.updating = false
        // Anything that arrived mid-update was dropped by the `updating` gate;
        // re-check so the stream converges on the latest state.
        self.updateGeometry()
      }
    } catch {
      rebuildAttempts += 1
      lock.lock()
      failure = error.localizedDescription
      hasValidFrame = false
      captureState = rebuildAttempts > 2 ? "failed" : "retrying"
      lock.unlock()
      needsRebuild = rebuildAttempts <= 2
      retryAt = ProcessInfo.processInfo.systemUptime + 1
      if needsRebuild { refreshContent(rebuild: true) }
    }
  }

  private func refreshContent(rebuild: Bool) {
    guard !updating else { return }
    updating = true
    let previousStream = rebuild ? stream : nil
    if rebuild {
      stream = nil
      streaming = false
      lock.lock()
      activeStreamID = nil
      recoveryEpoch += 1
      hasValidFrame = false
      captureState = "recovering"
      frameDeadline = ProcessInfo.processInfo.systemUptime + 5
      desktop = nil
      latest = nil
      lock.unlock()
    }
    Task { @MainActor in
      defer { self.updating = false }
      do {
        if let previousStream = previousStream {
          try? previousStream.removeStreamOutput(self, type: .screen)
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            previousStream.stopCapture { _ in continuation.resume() }
          }
        }
        guard !self.ended else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !self.ended else { return }
        self.content = content
        if rebuild {
          let geometry = try self.makeGeometry()
          let own = content.windows.filter { $0.windowID == CGWindowID(self.window!.windowNumber) }
          guard !own.isEmpty else { throw self.captureError("Cannot identify the own window") }
          let replacement = SCStream(filter: SCContentFilter(display: geometry.display, excludingWindows: own),
              configuration: geometry.config, delegate: self)
          try replacement.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
          self.stream = replacement
          self.lock.lock()
          self.activeStreamID = ObjectIdentifier(replacement)
          self.frameDeadline = ProcessInfo.processInfo.systemUptime + 5
          self.lock.unlock()
          self.displayId = geometry.display.displayID
          self.displayOrigin = geometry.display.frame.origin
          self.displayPoints = geometry.display.frame.size
          let rect = self.windowRectInDisplay() ?? .zero
          self.lock.lock(); self.sampleRect = rect; self.lock.unlock()
          self.needsRebuild = false
          self.reconcile()
        }
      } catch {
        self.rebuildAttempts += 1
        self.lock.lock()
        self.failure = error.localizedDescription
        self.hasValidFrame = false
        self.captureState = self.rebuildAttempts > 2 ? "failed" : "retrying"
        self.lock.unlock()
        self.needsRebuild = rebuild && self.rebuildAttempts <= 2
        self.retryAt = ProcessInfo.processInfo.systemUptime + 1
        self.lock.lock(); self.frameDeadline = 0; self.lock.unlock()
      }
      self.updating = false
      if self.needsRebuild { self.updateGeometry() }
    }
  }

  func end() {
    lock.lock()
    let alreadyEnded = ended
    ended = true
    activeStreamID = nil
    hasValidFrame = false
    captureState = "ended"
    latest = nil
    desktop = nil
    lock.unlock()
    guard !alreadyEnded else { return }
    geometryTimer?.invalidate()
    geometryTimer = nil
    watchdogTimer?.invalidate()
    watchdogTimer = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()
    registry.unregisterTexture(textureId)
    try? stream?.removeStreamOutput(self, type: .screen)
    reconcile()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    // 时序关键点：在消费纹理时读取最新位置，勿移回捕获回调里预先裁剪。
    // 后者会提交按旧位置生成的图像，拖动时表现为背景落后一两帧。
    // A move or a new ScreenCaptureKit frame can land while the GPU is cropping.
    // Retry once with the newest snapshot. A newer desktop frame may wait for
    // the next copy, but a crop for an old window position must never be used.
    for attempt in 0..<2 {
      lock.lock()
      guard !ended, !paused, hasValidFrame, let image = desktop else {
        lock.unlock()
        return nil
      }
      let region = sampleRect
      let version = frames
      let epoch = recoveryEpoch
      let previous = renderedEpoch == epoch && renderedRect == region ? latest : nil
      lock.unlock()

      if renderedEpoch != epoch {
        renderedVersion = -1
        renderedRect = .null
        renderedEpoch = epoch
      }
      // Desktop version and position must both match to reuse a crop.
      let unchanged = version == renderedVersion && region == renderedRect
      let cropped = unchanged ? previous : renderCrop(image, region: region)

      lock.lock()
      guard !ended, !paused, recoveryEpoch == epoch, hasValidFrame else {
        lock.unlock()
        return nil
      }
      let moved = sampleRect != region
      let raced = frames != version || moved
      if moved || (raced && attempt == 0) {
        staleCropDrops += 1
        lock.unlock()
        if attempt == 1 { scheduleFrame() }
        continue
      }
      guard let buffer = cropped ?? previous else {
        cropPoolMisses += 1
        lock.unlock()
        scheduleFrame()
        return nil
      }
      if cropped == nil {
        cropPoolMisses += 1
      }
      latest = buffer
      presented += 1
      lock.unlock()
      // A pool fallback still contains the previous desktop frame. Keep its
      // version so the next copy retries the crop instead of caching it as new.
      if cropped != nil {
        renderedVersion = version
        renderedRect = region
      }
      if raced || cropped == nil {
        scheduleFrame()
      }
      return Unmanaged.passRetained(buffer)
    }
    return nil
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of outputType: SCStreamOutputType) {
    guard outputType == .screen, sampleBuffer.isValid,
          let attachment = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let status = attachment.first?[.status] as? Int,
          let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let statusName: String
    switch status {
    case SCFrameStatus.complete.rawValue: statusName = "complete"
    case SCFrameStatus.idle.rawValue: statusName = "idle"
    case SCFrameStatus.blank.rawValue: statusName = "blank"
    case SCFrameStatus.suspended.rawValue: statusName = "suspended"
    case SCFrameStatus.started.rawValue: statusName = "started"
    case SCFrameStatus.stopped.rawValue: statusName = "stopped"
    default: statusName = "unknown"
    }
    lock.lock()
    guard !ended, !paused, activeStreamID == ObjectIdentifier(stream) else { lock.unlock(); return }
    lastFrameStatus = statusName
    guard status == SCFrameStatus.complete.rawValue else {
      if status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.suspended.rawValue ||
          status == SCFrameStatus.stopped.rawValue {
        hasValidFrame = false
        captureState = statusName == "stopped" ? "retrying" : "waitingForFrame"
        if frameDeadline == 0 {
          frameDeadline = ProcessInfo.processInfo.systemUptime + 5
        }
        desktop = nil
        latest = nil
      }
      lock.unlock()
      if status == SCFrameStatus.stopped.rawValue {
        DispatchQueue.main.async { [weak self] in
          self?.needsRebuild = true
          self?.updateGeometry()
        }
      }
      return
    }
    desktop = image
    frames += 1
    failure = ""
    hasValidFrame = true
    captureState = "live"
    lastFrameAt = ProcessInfo.processInfo.systemUptime
    frameDeadline = 0
    let region = sampleRect
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.rebuildAttempts = 0
    }
    scheduleFrame()

    // 统计在捕获队列读取桌面区域，不持有裁剪缓冲，也不阻塞栅格线程取帧。
    let now = ProcessInfo.processInfo.systemUptime
    if now - sampledAt >= 0.25 {
      sampledAt = now
      sample(image, region: region)
    }
  }

  private func scheduleFrame() {
    lock.lock()
    guard !ended, !paused else { lock.unlock(); return }
    let enqueue = !notificationPending
    notificationPending = true
    lock.unlock()
    if Thread.isMainThread {
      // 窗口移动已在平台主线程，立即通知，避免再排一次 RunLoop 引入位置延迟。
      // 捕获队列的通知则合并后投递到 common modes；纹理入口仍须在平台线程调用。
      deliverFrame()
    } else if enqueue {
      RunLoop.main.perform(inModes: [.common]) { [weak self] in
        self?.deliverFrame()
      }
      CFRunLoopWakeUp(CFRunLoopGetMain())
    }
  }

  private func deliverFrame() {
    lock.lock()
    let active = notificationPending && !ended && !paused
    notificationPending = false
    lock.unlock()
    if active { registry.textureFrameAvailable(textureId) }
  }

  private func renderCrop(_ image: CVPixelBuffer, region: CGRect) -> CVPixelBuffer? {
    autoreleasepool {
      let width = Int(region.width.rounded())
      let height = Int(region.height.rounded())
      guard width > 0, height > 0 else { return nil }
      let size = CGSize(width: width, height: height)
      if cropPool == nil || cropSize != size {
        let attributes: [CFString: Any] = [
          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
          kCVPixelBufferMetalCompatibilityKey: true,
          kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool = pool else { return nil }
        cropPool = pool
        cropSize = size
      }
      guard let pool = cropPool else { return nil }
      var buffer: CVPixelBuffer?
      let limits = [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary
      guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limits, &buffer) == kCVReturnSuccess,
            let buffer = buffer else { return nil }
      let source = CIImage(cvPixelBuffer: image)
      // Core Image is bottom-up; AppKit's captured rectangle is top-down.
      let rect = CGRect(x: region.minX, y: source.extent.height - region.minY - CGFloat(height),
                        width: CGFloat(width), height: CGFloat(height))
      let crop = source.clampedToExtent().cropped(to: rect)
          .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
      imageContext.render(crop, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
      return buffer
    }
  }

  private func sample(_ image: CVPixelBuffer, region: CGRect) {
    guard CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(image) else { return }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(image)
    var hash: UInt64 = 1469598103934665603
    var brightness: Double = 0
    var count = 0
    let width = CVPixelBufferGetWidth(image)
    let height = CVPixelBufferGetHeight(image)
    let x0 = max(0, min(width, Int(region.minX)))
    let y0 = max(0, min(height, Int(region.minY)))
    let x1 = max(x0, min(width, Int(region.maxX)))
    let y1 = max(y0, min(height, Int(region.maxY)))
    for y in Swift.stride(from: y0, to: y1, by: 16) {
      for x in Swift.stride(from: x0, to: x1, by: 16) {
        let p = y * stride + x * 4
        hash = (hash ^ UInt64(pixels[p]) ^ (UInt64(pixels[p + 1]) << 8) ^ (UInt64(pixels[p + 2]) << 16)) &* 1099511628211
        brightness += (0.2126 * Double(pixels[p + 2]) + 0.7152 * Double(pixels[p + 1]) + 0.0722 * Double(pixels[p])) / 255
        count += 1
      }
    }
    lock.lock()
    if hash != lastHash { changes += 1 }
    lastHash = hash
    if count > 0 { luminance = brightness / Double(count) }
    lock.unlock()
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock()
    guard activeStreamID == ObjectIdentifier(stream), !ended else { lock.unlock(); return }
    failure = error.localizedDescription
    hasValidFrame = false
    captureState = "retrying"
    frameDeadline = 0
    desktop = nil
    latest = nil
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.streaming = false
      guard let self = self else { return }
      self.rebuildAttempts += 1
      self.needsRebuild = self.rebuildAttempts <= 2
      self.retryAt = ProcessInfo.processInfo.systemUptime + 1
      if self.rebuildAttempts > 2 {
        self.lock.lock(); self.captureState = "failed"; self.lock.unlock()
      }
    }
  }

  func stats() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    let frameAgeMs = lastFrameAt > 0
        ? (ProcessInfo.processInfo.systemUptime - lastFrameAt) * 1000 : -1
    var result: [String: Any] = ["active": !ended, "sessionId": id, "textureId": textureId,
            "frames": frames, "presented": presented, "changes": changes,
            "cropPoolMisses": cropPoolMisses, "staleCropDrops": staleCropDrops,
            "elapsed": ProcessInfo.processInfo.systemUptime - started,
            "luminance": luminance, "error": failure, "paused": paused,
            "selfExcluded": true, "hasValidFrame": hasValidFrame,
            "captureState": captureState, "recoveryEpoch": recoveryEpoch,
            "lastFrameAgeMs": frameAgeMs, "lastFrameStatus": lastFrameStatus]
    result.merge(mappingInfo()) { _, new in new }
    return result
  }
}
