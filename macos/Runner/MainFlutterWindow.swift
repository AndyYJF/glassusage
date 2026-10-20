import Cocoa
import FlutterMacOS

// 审核入口：Dart 的 startMiniDragging 只启动一次监听；逐次移动在本文件完成。
// 与 desktop_glass 的按取帧时位置裁剪配合，避免窗口先移动、背景迟一两帧追赶。
class MainFlutterWindow: NSWindow {
  private var miniMode = false
  private var miniDragMonitor: Any?
  private weak var miniFlutterViewController: FlutterViewController?
  private var movableBeforeMiniMode: Bool?

  override func sendEvent(_ event: NSEvent) {
    if miniMode, let flutter = miniFlutterViewController {
      // 小窗的左键序列直接交给 Flutter，避免 NSWindow 同时启动标题栏移动。
      // 仅仅命中 FlutterView 不够：原先顶部仍在两次自定义移动之间被额外改位。
      // Flutter 继续判断按钮、滑块与拖动手势；不按固定标题栏高度划分区域。
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

  // 松开鼠标、退出小窗及窗口释放都必须移除监听，避免残留拖动状态。
  private func endMiniDrag() {
    if let monitor = miniDragMonitor {
      NSEvent.removeMonitor(monitor)
      miniDragMonitor = nil
    }
  }

  private func startMiniDrag() {
    guard miniMode else { return }
    endMiniDrag()
    let mouseOrigin = NSEvent.mouseLocation
    let windowOrigin = frame.origin
    // 保持正常事件循环；勿改回 performDrag，否则拖动期间取景/刷新可能滞后。
    // 保留原始按下位置的偏移，避免开始拖动时窗口跳到鼠标中心。
    miniDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
      guard let self = self else { return event }
      if event.type == .leftMouseUp {
        self.endMiniDrag()
      } else {
        let mouse = NSEvent.mouseLocation
        self.setFrameOrigin(NSPoint(x: windowOrigin.x + mouse.x - mouseOrigin.x,
                                    y: windowOrigin.y + mouse.y - mouseOrigin.y))
      }
      return event
    }
  }

  deinit { endMiniDrag() }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    miniFlutterViewController = flutterViewController
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The mini window has its own controls; the standard traffic-light buttons
    // would overlap the card content. window_manager has no API for this.
    let chrome = FlutterMethodChannel(
      name: "glassusage/desktop_window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    chrome.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "setMiniMode":
        let mini = (call.arguments as? Bool) ?? false
        if let window = self {
          // 完整/紧凑互切会重复传 true；只在首次进入时保存主窗口原值。
          if mini != window.miniMode {
            if mini {
              window.movableBeforeMiniMode = window.isMovable
              // 同时关闭 WindowServer 的标题栏移动；事件转发负责绕过 AppKit。
              window.isMovable = false
            } else {
              if let movable = window.movableBeforeMiniMode {
                window.isMovable = movable
              }
              window.movableBeforeMiniMode = nil
            }
          }
          window.miniMode = mini
          if !mini { window.endMiniDrag() }
          for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = mini
          }
        }
      case "startMiniDragging":
        self?.startMiniDrag()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
    }

    super.awakeFromNib()
  }
}
