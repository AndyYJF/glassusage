import Cocoa
import FlutterMacOS
import window_manager

// 小窗固定宿主（移植自 Windows 80b1781）：进入小窗后窗口铺满卡片所在屏幕，拖动期间
// 原生窗口不移动；卡片位置与桌面纹理的反向平移由 Flutter 在同一帧提交，因此不会错位。
// 卡片外区域通过 ignoresMouseEvents 穿透给下层应用。
class MainFlutterWindow: NSWindow {
  private var miniMode = false
  private weak var miniFlutterViewController: FlutterViewController?
  private var movableBeforeMiniMode: Bool?
  private var host: MiniHost?
  private var hitTimer: Timer?
  private var mouseMonitors: [Any] = []

  /// Matches `_miniCornerRadius` on macOS in mini_card_view.dart.
  private static let miniCornerRadius: CGFloat = 16

  /// Main-window appearance saved on entry, plus the card rect in host-local
  /// top-left points (the same space as Dart's `miniCardBounds`).
  private struct MiniHost {
    var card: CGRect
    var revealed: Bool
    let opaque: Bool
    let background: NSColor
    let shadow: Bool
    let mask: NSImage?
  }

  /// macos_window_utils (used by flutter_acrylic) wraps the Flutter view in an
  /// NSVisualEffectView content view.
  private var effectView: NSVisualEffectView? {
    contentViewController?.view as? NSVisualEffectView
  }

  override func sendEvent(_ event: NSEvent) {
    if miniMode, let flutter = miniFlutterViewController {
      // 小窗的左键序列直接交给 Flutter，避免 NSWindow 启动标题栏移动；
      // 卡片拖动、按钮与滑块都由 Flutter 判断。
      switch event.type {
      case .leftMouseDown:
        if !isKeyWindow { makeKey() }
        flutter.mouseDown(with: event)
      case .leftMouseDragged:
        flutter.mouseDragged(with: event)
      case .leftMouseUp:
        flutter.mouseUp(with: event)
      default:
        super.sendEvent(event)
      }
    } else {
      super.sendEvent(event)
    }
  }

  // The host covers the full screen frame, including the menu bar strip.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    host != nil ? frameRect : super.constrainFrameRect(frameRect, to: screen)
  }

  // MARK: - Fixed mini host

  private func enterMiniHost() -> [String: Any]? {
    if let host = host { return geometry(card: host.card) }
    guard let screen = screen ?? NSScreen.main else { return nil }
    let cardFrame = frame
    host = MiniHost(card: .zero, revealed: false, opaque: isOpaque,
                    background: backgroundColor, shadow: hasShadow,
                    mask: effectView?.maskImage)
    // Stay invisible until Flutter has laid the card out at its host offset;
    // the first frames at host size still show the previous layout.
    alphaValue = 0
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    // flutter_acrylic maps "transparent" to an under-window blur material. An
    // empty mask stops it from blurring the whole screen behind the host.
    effectView?.maskImage = NSImage()
    setFrame(screen.frame, display: true)
    let hostFrame = frame
    let card = CGRect(x: cardFrame.minX - hostFrame.minX,
                      y: hostFrame.maxY - cardFrame.maxY,
                      width: cardFrame.width, height: cardFrame.height)
    host?.card = card
    startHitRouting()
    // Safety net: never leave the window invisible if Dart fails to confirm.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      self?.revealMiniHost()
    }
    return geometry(card: card)
  }

  private func revealMiniHost() {
    guard host?.revealed == false else { return }
    host?.revealed = true
    alphaValue = 1
  }

  private func exitMiniHost() {
    guard let saved = host else { return }
    stopHitRouting()
    host = nil
    ignoresMouseEvents = false
    // Shrink back to the card first so the restored material never covers the
    // whole screen; Dart then restores the main bounds.
    let hostFrame = frame
    setFrame(NSRect(x: hostFrame.minX + saved.card.minX,
                    y: hostFrame.maxY - saved.card.maxY,
                    width: saved.card.width, height: saved.card.height), display: true)
    effectView?.maskImage = saved.mask
    isOpaque = saved.opaque
    backgroundColor = saved.background
    hasShadow = saved.shadow
    alphaValue = 1
  }

  /// Same keys as the Windows runner's MiniGeometry. hostLeft/hostTop use
  /// window_manager's global top-left space (primary screen height based).
  private func geometry(card: CGRect) -> [String: Any] {
    let hostFrame = frame
    let primaryHeight = NSScreen.screens.first?.frame.height ?? hostFrame.maxY
    return ["left": Double(card.minX), "top": Double(card.minY),
            "width": Double(card.width), "height": Double(card.height),
            "hostLeft": Double(hostFrame.minX),
            "hostTop": Double(primaryHeight - hostFrame.maxY)]
  }

  // MARK: - Click-through routing

  private func startHitRouting() {
    stopHitRouting()
    // Monitors follow the pointer immediately; the slow timer covers the card
    // moving under a stationary pointer and any missed events (as on Windows).
    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
      self?.updateHitTest()
    }
    RunLoop.main.add(timer, forMode: .common)
    hitTimer = timer
    // Global events arrive while the host ignores the mouse, local ones otherwise.
    if let monitor = NSEvent.addGlobalMonitorForEvents(
        matching: [.mouseMoved, .leftMouseUp, .rightMouseUp], handler: { [weak self] _ in
      self?.updateHitTest()
    }) { mouseMonitors.append(monitor) }
    if let monitor = NSEvent.addLocalMonitorForEvents(
        matching: [.mouseMoved, .leftMouseUp, .rightMouseUp], handler: { [weak self] event in
      self?.updateHitTest()
      return event
    }) { mouseMonitors.append(monitor) }
    updateHitTest()
  }

  private func stopHitRouting() {
    hitTimer?.invalidate()
    hitTimer = nil
    for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
    mouseMonitors.removeAll()
  }

  private func updateHitTest() {
    guard let host = host else { return }
    // Keep routing fixed while a button is held: a drag that began on the card
    // stays with Flutter, one that began elsewhere stays with the other app.
    guard NSEvent.pressedMouseButtons == 0 else { return }
    let mouse = NSEvent.mouseLocation
    let hostFrame = frame
    let point = CGPoint(x: mouse.x - hostFrame.minX, y: hostFrame.maxY - mouse.y)
    let inside = Self.roundedRect(host.card, contains: point)
    if ignoresMouseEvents == inside { ignoresMouseEvents = !inside }
  }

  private static func roundedRect(_ rect: CGRect, contains point: CGPoint) -> Bool {
    guard rect.contains(point) else { return false }
    let radius = min(miniCornerRadius, min(rect.width, rect.height) / 2)
    let cx = min(max(point.x, rect.minX + radius), rect.maxX - radius)
    let cy = min(max(point.y, rect.minY + radius), rect.maxY - radius)
    let dx = point.x - cx
    let dy = point.y - cy
    return dx * dx + dy * dy <= radius * radius
  }

  private func setMiniCardBounds(_ arguments: Any?) -> Bool {
    guard host != nil, let typed = arguments as? FlutterStandardTypedData,
          typed.type == .float64, typed.elementCount == 4 else { return false }
    let values: [Double] = typed.data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    host?.card = CGRect(x: values[0], y: values[1],
                        width: values[2] - values[0], height: values[3] - values[1])
    updateHitTest()
    return true
  }

  deinit { stopHitRouting() }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    miniFlutterViewController = flutterViewController
    self.contentViewController = flutterViewController
    if let visible = (self.screen ?? NSScreen.main)?.visibleFrame {
      let width = min(CGFloat(1220), visible.width)
      let height = min(CGFloat(800), visible.height)
      let initialFrame = NSRect(
        x: visible.midX - width / 2,
        y: visible.midY - height / 2,
        width: width,
        height: height
      )
      self.setFrame(initialFrame, display: true)
    } else {
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The mini window has its own controls; the standard traffic-light buttons
    // would overlap the card content. window_manager has no API for this.
    let chrome = FlutterMethodChannel(
      name: "glassusage/desktop_window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    chrome.setMethodCallHandler { [weak self] call, result in
      guard let window = self else {
        result(nil)
        return
      }
      switch call.method {
      case "setMiniMode":
        let mini = (call.arguments as? Bool) ?? false
        if mini != window.miniMode {
          if mini {
            window.movableBeforeMiniMode = window.isMovable
            // 关闭 WindowServer 的标题栏移动；卡片只在 Flutter 场景内移动。
            window.isMovable = false
          } else {
            if let movable = window.movableBeforeMiniMode {
              window.isMovable = movable
            }
            window.movableBeforeMiniMode = nil
          }
        }
        window.miniMode = mini
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          window.standardWindowButton(kind)?.isHidden = mini
        }
        if mini {
          result(window.enterMiniHost())
        } else {
          window.exitMiniHost()
          result(nil)
        }
      case "setMiniCardBounds":
        if window.setMiniCardBounds(call.arguments) {
          result(nil)
        } else {
          result(FlutterError(code: "argument", message: "Expected four host coordinates", details: nil))
        }
      case "showMiniHost":
        window.revealMiniHost()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
