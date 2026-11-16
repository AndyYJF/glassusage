#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <cmath>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"


namespace {
constexpr UINT kTrayIconId = 1;
constexpr UINT kWmTrayIcon = WM_USER + 100;
constexpr int kHotkeyIdToggle = 1;

constexpr UINT kMenuIdOpen = 1001;
constexpr UINT kMenuIdWidget = 1002;
constexpr UINT kMenuIdRescan = 1003;
constexpr UINT kMenuIdQuit = 1004;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow* FlutterWindow::mini_host_ = nullptr;

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  win32_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "glassusage/win32",
          &flutter::StandardMethodCodec::GetInstance());

  HWND hwnd = GetHandle();

  win32_channel_->SetMethodCallHandler(
      [this, hwnd](const auto& call, auto result) {
        if (call.method_name() == "setMiniMode") {
          const auto* enabled = call.arguments()
              ? std::get_if<bool>(call.arguments()) : nullptr;
          if (!enabled) {
            result->Error("argument", "Expected mini mode boolean");
            return;
          }
          if (*enabled != mini_mode_) {
            if (*enabled) {
              RECT card{};
              GetWindowRect(hwnd, &card);
              main_style_ = GetWindowLongPtr(hwnd, GWL_STYLE);
              main_ex_style_ = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
              mini_host_ = this;
              mini_mouse_hook_ = SetWindowsHookExW(WH_MOUSE_LL, MiniMouseHook,
                                                  GetModuleHandle(nullptr), 0);
              if (!mini_mouse_hook_) {
                mini_host_ = nullptr;
                result->Error("miniHost", "Cannot route transparent host input");
                return;
              }
              mini_mode_ = true;
              SetPropW(hwnd, L"GlassUsageMiniCardBounds", &mini_card_);
              SetWindowLongPtr(hwnd, GWL_STYLE,
                              WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS |
                              (main_style_ & WS_VISIBLE));
              SetWindowLongPtr(hwnd, GWL_EXSTYLE, main_ex_style_ | WS_EX_LAYERED);
              SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
              SetWindowRgn(hwnd, nullptr, TRUE);
              const int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
              const int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
              mini_card_ = card;
              OffsetRect(&mini_card_, -x, -y);
              SetWindowPos(hwnd, nullptr, x, y,
                           GetSystemMetrics(SM_CXVIRTUALSCREEN),
                           GetSystemMetrics(SM_CYVIRTUALSCREEN),
                           SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
              SetTimer(hwnd, 0x4748, 50, nullptr);
              POINT cursor{};
              GetCursorPos(&cursor);
              UpdateMiniHitTest(cursor);
            } else {
              StopMiniHost();
              SetWindowLongPtr(hwnd, GWL_STYLE, main_style_);
              SetWindowLongPtr(hwnd, GWL_EXSTYLE, main_ex_style_);
              SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                           SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                           SWP_NOACTIVATE | SWP_FRAMECHANGED);
            }
          }
          result->Success(flutter::EncodableValue(MiniGeometry()));
        } else if (call.method_name() == "setMiniCardBounds" && mini_mode_) {
          const auto* values = call.arguments()
              ? std::get_if<std::vector<double>>(call.arguments()) : nullptr;
          if (!values || values->size() != 4) {
            result->Error("argument", "Expected four physical coordinates");
            return;
          }
          mini_card_ = {static_cast<LONG>(std::lround((*values)[0])),
                        static_cast<LONG>(std::lround((*values)[1])),
                        static_cast<LONG>(std::lround((*values)[2])),
                        static_cast<LONG>(std::lround((*values)[3]))};
          POINT cursor{};
          GetCursorPos(&cursor);
          UpdateMiniHitTest(cursor);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  SetupTrayAndHotkey(hwnd);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

flutter::EncodableMap FlutterWindow::MiniGeometry() {
  using V = flutter::EncodableValue;
  RECT host{};
  GetWindowRect(GetHandle(), &host);
  const double scale = GetDpiForWindow(GetHandle()) / 96.0;
  return {{V("left"), V(mini_card_.left / scale)},
          {V("top"), V(mini_card_.top / scale)},
          {V("width"), V((mini_card_.right - mini_card_.left) / scale)},
          {V("height"), V((mini_card_.bottom - mini_card_.top) / scale)},
          {V("hostLeft"), V(host.left / scale)},
          {V("hostTop"), V(host.top / scale)}};
}

void FlutterWindow::StopMiniHost() {
  mini_mode_ = false;
  RemovePropW(GetHandle(), L"GlassUsageMiniCardBounds");
  KillTimer(GetHandle(), 0x4748);
  if (mini_mouse_hook_) UnhookWindowsHookEx(mini_mouse_hook_);
  mini_mouse_hook_ = nullptr;
  if (mini_host_ == this) mini_host_ = nullptr;
}

void FlutterWindow::UpdateMiniHitTest(POINT cursor) {
  if (!mini_mode_) return;
  const HWND hwnd = GetHandle();
  ScreenToClient(hwnd, &cursor);
  const HWND capture = GetCapture();
  bool inside = capture == hwnd || (capture && IsChild(hwnd, capture));
  if (!inside && PtInRect(&mini_card_, cursor)) {
    const double radius = std::min(28.0 * GetDpiForWindow(hwnd) / 96.0,
        std::min(mini_card_.right - mini_card_.left,
                 mini_card_.bottom - mini_card_.top) / 2.0);
    const double cx = std::clamp(static_cast<double>(cursor.x),
        mini_card_.left + radius, mini_card_.right - radius);
    const double cy = std::clamp(static_cast<double>(cursor.y),
        mini_card_.top + radius, mini_card_.bottom - radius);
    inside = (cursor.x - cx) * (cursor.x - cx) +
             (cursor.y - cy) * (cursor.y - cy) <= radius * radius;
  }
  const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  const LONG_PTR next = inside ? style & ~WS_EX_TRANSPARENT
                               : style | WS_EX_TRANSPARENT;
  if (style != next) SetWindowLongPtr(hwnd, GWL_EXSTYLE, next);
}

LRESULT CALLBACK FlutterWindow::MiniMouseHook(int code, WPARAM wparam, LPARAM lparam) {
  // Change input routing before User32 chooses the target. HTTRANSPARENT alone
  // only forwards to windows in the same thread, not other applications.
  if (code >= 0 && mini_host_) {
    mini_host_->UpdateMiniHitTest(reinterpret_cast<MSLLHOOKSTRUCT*>(lparam)->pt);
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

void FlutterWindow::SetupTrayAndHotkey(HWND hwnd) {
  ZeroMemory(&nid_, sizeof(nid_));
  nid_.cbSize = sizeof(NOTIFYICONDATAW);
  nid_.hWnd = hwnd;
  nid_.uID = kTrayIconId;
  nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid_.uCallbackMessage = kWmTrayIcon;
  nid_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(nid_.szTip, L"GlassUsage");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &nid_) == TRUE;

  RegisterHotKey(hwnd, kHotkeyIdToggle, MOD_CONTROL | MOD_ALT, 'G');
}

void FlutterWindow::RemoveTrayAndHotkey(HWND hwnd) {
  if (tray_added_) {
    Shell_NotifyIconW(NIM_DELETE, &nid_);
    tray_added_ = false;
  }
  UnregisterHotKey(hwnd, kHotkeyIdToggle);
}

void FlutterWindow::ShowTrayContextMenu(HWND hwnd) {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;

  AppendMenuW(menu, MF_STRING, kMenuIdOpen, L"Open GlassUsage");
  AppendMenuW(menu, MF_STRING, kMenuIdWidget, L"Mini card");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuIdRescan, L"Rescan all sources");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuIdQuit, L"Quit");

  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(hwnd);
  UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                            pt.x, pt.y, 0, hwnd, nullptr);
  DestroyMenu(menu);

  switch (cmd) {
    case kMenuIdOpen:
      NotifyDartEvent("tray:open");
      break;
    case kMenuIdWidget:
      NotifyDartEvent("tray:widget");
      break;
    case kMenuIdRescan:
      NotifyDartEvent("tray:rescan");
      break;
    case kMenuIdQuit:
      allow_quit_ = true;
      RemoveTrayAndHotkey(hwnd);
      DestroyWindow(hwnd);
      break;
    default:
      break;
  }
}

void FlutterWindow::NotifyDartEvent(const std::string& event_name) {
  if (win32_channel_) {
    win32_channel_->InvokeMethod(
        "onWin32Event",
        std::make_unique<flutter::EncodableValue>(event_name));
  }
}

void FlutterWindow::OnDestroy() {
  StopMiniHost();
  win32_channel_.reset();
  RemoveTrayAndHotkey(GetHandle());
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (mini_mode_) {
    if (message == WM_NCCALCSIZE) return 0;
    if (message == WM_TIMER && wparam == 0x4748) {
      POINT cursor{};
      GetCursorPos(&cursor);
      UpdateMiniHitTest(cursor);
      return 0;
    }
    if (message == WM_DISPLAYCHANGE) {
      SetWindowPos(hwnd, nullptr, GetSystemMetrics(SM_XVIRTUALSCREEN),
          GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN),
          GetSystemMetrics(SM_CYVIRTUALSCREEN), SWP_NOZORDER | SWP_NOACTIVATE);
    }
    if (message == WM_DPICHANGED) {
      // The host covers physical virtual-screen coordinates, not the suggested
      // per-monitor window rectangle. Flutter still receives the new DPI.
      PostMessage(hwnd, WM_DISPLAYCHANGE, 0, 0);
    }
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;

    case WM_CLOSE:
      if (!allow_quit_) {
        ShowWindow(hwnd, SW_HIDE);
        NotifyDartEvent("window:hidden");
        return 0;
      }
      break;

    case kWmTrayIcon: {
      UINT mouse_msg = LOWORD(lparam);
      if (mouse_msg == WM_LBUTTONUP || mouse_msg == WM_LBUTTONDBLCLK) {
        NotifyDartEvent("tray:open");
        return 0;
      } else if (mouse_msg == WM_RBUTTONUP || mouse_msg == WM_CONTEXTMENU) {
        ShowTrayContextMenu(hwnd);
        return 0;
      }
      break;
    }

    case WM_HOTKEY:
      if (wparam == kHotkeyIdToggle) {
        if (IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
          NotifyDartEvent("hotkey:toggle");
        } else {
          NotifyDartEvent("tray:open");
        }
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
