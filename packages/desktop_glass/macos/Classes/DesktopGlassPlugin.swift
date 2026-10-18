import Cocoa
import FlutterMacOS
import ScreenCaptureKit
import CoreMedia
import CoreVideo

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
          result(["sessionId": token, "textureId": capture.textureId])
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

// Window/configuration and registry changes run on main. Only the latest frame
// and counters cross into ScreenCaptureKit's queue and Flutter's raster thread.
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
  private var frames: Int64 = 0
  private var presented: Int64 = 0
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
  private var sourceRect = CGRect.zero
  private var pixelSize = CGSize.zero
  private var retryAt: TimeInterval = 0
  private var needsRebuild = false
  private var observers: [NSObjectProtocol] = []
  private var geometryTimer: Timer?
  private let started = ProcessInfo.processInfo.systemUptime

  init(id: Int64, window: NSWindow, view: NSView, registry: FlutterTextureRegistry,
       content: SCShareableContent, fps: Int) throws {
    self.id = id
    self.window = window
    self.view = view
    self.registry = registry
    self.content = content
    self.fps = fps
    super.init()
    let geometry = try makeGeometry()
    let own = content.windows.filter { $0.windowID == CGWindowID(window.windowNumber) }
    guard !own.isEmpty else { throw captureError("Cannot identify the own window for exclusion") }
    displayId = geometry.display.displayID
    sourceRect = geometry.rect
    pixelSize = CGSize(width: geometry.config.width, height: geometry.config.height)
    let filter = SCContentFilter(display: geometry.display, excludingWindows: own)
    stream = SCStream(filter: filter, configuration: geometry.config, delegate: self)
    try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
    textureId = registry.register(self)
    guard textureId != 0 else { throw captureError("Cannot register desktop texture") }
  }

  private func captureError(_ message: String) -> NSError {
    NSError(domain: "GlassUsage.DesktopGlass", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func makeGeometry() throws -> (display: SCDisplay, rect: CGRect, config: SCStreamConfiguration) {
    guard let window = window, let view = view, let screen = window.screen,
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
      throw captureError("The window display is unavailable; reconnect capture")
    }
    let client = window.convertToScreen(view.convert(view.bounds, to: nil))
    // AppKit is bottom-up in logical points; ScreenCaptureKit uses a top-down
    // display-local source rectangle, then scales it into the configured pixels.
    let rect = CGRect(x: client.minX - screen.frame.minX,
                      y: screen.frame.maxY - client.maxY,
                      width: client.width, height: client.height)
    let config = SCStreamConfiguration()
    config.sourceRect = rect
    config.width = max(1, Int((client.width * screen.backingScaleFactor).rounded()))
    config.height = max(1, Int((client.height * screen.backingScaleFactor).rounded()))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.queueDepth = 3
    config.showsCursor = false
    return (display, rect, config)
  }

  func begin() {
    let center = NotificationCenter.default
    for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        self?.reconcile()
      })
    }
    geometryTimer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
      self?.updateGeometry()
      self?.reconcile()
    }
    RunLoop.main.add(geometryTimer!, forMode: .common)
    reconcile()
  }

  func setPaused(_ value: Bool) {
    lock.lock(); paused = value; lock.unlock()
    reconcile()
  }

  private func reconcile() {
    guard !transitioning, let stream = stream else { return }
    lock.lock(); let shouldRun = !ended && !paused && window?.isVisible == true && window?.isMiniaturized == false; lock.unlock()
    guard !shouldRun || ProcessInfo.processInfo.systemUptime >= retryAt else { return }
    guard shouldRun != streaming else { return }
    transitioning = true
    let completion: (Error?) -> Void = { [self] error in
      DispatchQueue.main.async {
        self.transitioning = false
        self.streaming = error == nil ? shouldRun : false
        if let error = error {
          self.lock.lock(); self.failure = error.localizedDescription; self.lock.unlock()
          self.retryAt = ProcessInfo.processInfo.systemUptime + 1
        } else {
          self.reconcile()
        }
      }
    }
    if shouldRun { stream.startCapture(completionHandler: completion) }
    else { stream.stopCapture(completionHandler: completion) }
  }

  private func updateGeometry() {
    guard !ended, !updating, !transitioning,
          ProcessInfo.processInfo.systemUptime >= retryAt, let stream = stream else { return }
    if needsRebuild {
      refreshContent(rebuild: true)
      return
    }
    do {
      let geometry = try makeGeometry()
      let size = CGSize(width: geometry.config.width, height: geometry.config.height)
      guard geometry.display.displayID != displayId || geometry.rect != sourceRect || size != pixelSize else { return }
      updating = true
      let own = content.windows.filter { $0.windowID == CGWindowID(window!.windowNumber) }
      let filter = SCContentFilter(display: geometry.display, excludingWindows: own)
      Task { @MainActor in
        defer { self.updating = false }
        do {
          if geometry.display.displayID != self.displayId { try await stream.updateContentFilter(filter) }
          try await stream.updateConfiguration(geometry.config)
          self.displayId = geometry.display.displayID
          self.sourceRect = geometry.rect
          self.pixelSize = size
        } catch {
          self.lock.lock(); self.failure = error.localizedDescription; self.lock.unlock()
        }
      }
    } catch {
      lock.lock(); failure = error.localizedDescription; lock.unlock()
      refreshContent(rebuild: false)
    }
  }

  private func refreshContent(rebuild: Bool) {
    guard !updating else { return }
    updating = true
    Task { @MainActor in
      defer { self.updating = false }
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !self.ended else { return }
        self.content = content
        if rebuild {
          let geometry = try self.makeGeometry()
          let own = content.windows.filter { $0.windowID == CGWindowID(self.window!.windowNumber) }
          guard !own.isEmpty else { throw self.captureError("Cannot identify the own window") }
          try? self.stream?.removeStreamOutput(self, type: .screen)
          let replacement = SCStream(filter: SCContentFilter(display: geometry.display, excludingWindows: own),
              configuration: geometry.config, delegate: self)
          try replacement.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.outputQueue)
          self.stream = replacement
          self.displayId = geometry.display.displayID
          self.sourceRect = geometry.rect
          self.pixelSize = CGSize(width: geometry.config.width, height: geometry.config.height)
          self.needsRebuild = false
          self.streaming = false
        }
      } catch {
        self.lock.lock(); self.failure = error.localizedDescription; self.lock.unlock()
        self.retryAt = ProcessInfo.processInfo.systemUptime + 1
      }
    }
  }

  func end() {
    lock.lock(); let alreadyEnded = ended; ended = true; latest = nil; lock.unlock()
    guard !alreadyEnded else { return }
    geometryTimer?.invalidate()
    geometryTimer = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    registry.unregisterTexture(textureId)
    try? stream?.removeStreamOutput(self, type: .screen)
    reconcile()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock(); defer { lock.unlock() }
    guard !ended, let latest = latest else { return nil }
    presented += 1
    return Unmanaged.passRetained(latest)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
              of outputType: SCStreamOutputType) {
    guard outputType == .screen, sampleBuffer.isValid,
          let attachment = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
          let status = attachment.first?[.status] as? Int,
          status == SCFrameStatus.complete.rawValue,
          let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    var hash: UInt64 = 1469598103934665603
    var brightness: Double = 0
    var count = 0
    CVPixelBufferLockBaseAddress(image, .readOnly)
    if let base = CVPixelBufferGetBaseAddress(image) {
      let pixels = base.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(image)
      for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(image), by: 32) {
        for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(image), by: 32) {
          let p = y * stride + x * 4
          hash = (hash ^ UInt64(pixels[p]) ^ (UInt64(pixels[p + 1]) << 8) ^ (UInt64(pixels[p + 2]) << 16)) &* 1099511628211
          brightness += (0.2126 * Double(pixels[p + 2]) + 0.7152 * Double(pixels[p + 1]) + 0.0722 * Double(pixels[p])) / 255
          count += 1
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(image, .readOnly)
    lock.lock()
    guard !ended, !paused else { lock.unlock(); return }
    latest = image
    frames += 1
    if hash != lastHash { changes += 1 }
    lastHash = hash
    if count > 0 { luminance = brightness / Double(count) }
    failure = ""
    lock.unlock()
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.lock.lock(); let active = !self.ended; self.lock.unlock()
      if active { self.registry.textureFrameAvailable(self.textureId) }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock(); failure = error.localizedDescription; lock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.streaming = false
      self?.needsRebuild = true
      self?.retryAt = ProcessInfo.processInfo.systemUptime + 1
    }
  }

  func stats() -> [String: Any] {
    lock.lock(); defer { lock.unlock() }
    return ["active": !ended, "sessionId": id, "textureId": textureId,
            "frames": frames, "presented": presented, "changes": changes,
            "elapsed": ProcessInfo.processInfo.systemUptime - started,
            "luminance": luminance, "error": failure, "paused": paused,
            "selfExcluded": true]
  }
}
