#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void SetupTrayAndHotkey(HWND hwnd);
  void RemoveTrayAndHotkey(HWND hwnd);
  void ShowTrayContextMenu(HWND hwnd);
  void NotifyDartEvent(const std::string& event_name);
  flutter::EncodableMap MiniGeometry();
  void UpdateMiniHitTest(POINT cursor);
  void StopMiniHost();
  static LRESULT CALLBACK MiniMouseHook(int code, WPARAM wparam, LPARAM lparam);

  bool mini_mode_ = false;
  LONG_PTR main_style_ = 0;
  LONG_PTR main_ex_style_ = 0;
  RECT mini_card_{};  // Physical pixels relative to the fixed host.
  HHOOK mini_mouse_hook_ = nullptr;
  static FlutterWindow* mini_host_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Method channel for Win32 tray / hotkey / visibility synchronization.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> win32_channel_;

  NOTIFYICONDATAW nid_{};
  bool tray_added_ = false;
  bool allow_quit_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
