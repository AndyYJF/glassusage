#include "flutter_window.h"

#include <optional>

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
      [this, hwnd](const flutter::MethodCall<flutter::EncodableValue>& call,
                   std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                       result) {
        const std::string& method = call.method_name();
        if (method == "quitApp") {
          allow_quit_ = true;
          RemoveTrayAndHotkey(hwnd);
          DestroyWindow(hwnd);
          result->Success(flutter::EncodableValue(true));
        } else if (method == "hideToTray") {
          ShowWindow(hwnd, SW_HIDE);
          NotifyDartEvent("window:hidden");
          result->Success(flutter::EncodableValue(true));
        } else if (method == "showMainWindow") {
          ShowWindow(hwnd, SW_SHOW);
          if (IsIconic(hwnd)) {
            ShowWindow(hwnd, SW_RESTORE);
          }
          SetForegroundWindow(hwnd);
          NotifyDartEvent("window:visible");
          result->Success(flutter::EncodableValue(true));
        } else if (method == "getHwnd") {
          result->Success(
              flutter::EncodableValue(static_cast<int64_t>(
                  reinterpret_cast<intptr_t>(hwnd))));
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
      ShowWindow(hwnd, SW_SHOW);
      if (IsIconic(hwnd)) {
        ShowWindow(hwnd, SW_RESTORE);
      }
      SetForegroundWindow(hwnd);
      NotifyDartEvent("tray:open");
      break;
    case kMenuIdWidget:
      ShowWindow(hwnd, SW_SHOW);
      if (IsIconic(hwnd)) {
        ShowWindow(hwnd, SW_RESTORE);
      }
      SetForegroundWindow(hwnd);
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
        ShowWindow(hwnd, SW_SHOW);
        if (IsIconic(hwnd)) {
          ShowWindow(hwnd, SW_RESTORE);
        }
        SetForegroundWindow(hwnd);
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
          ShowWindow(hwnd, SW_SHOW);
          if (IsIconic(hwnd)) {
            ShowWindow(hwnd, SW_RESTORE);
          }
          SetForegroundWindow(hwnd);
          NotifyDartEvent("tray:open");
        }
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
