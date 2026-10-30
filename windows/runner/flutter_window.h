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
  void UpdateMiniRegion(HWND hwnd);
  void StopMiniDrag(HWND hwnd, bool notify);
  void UpdateMiniDrag(HWND hwnd);
  static LRESULT CALLBACK MiniDragViewProc(HWND hwnd, UINT message,
      WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data);

  bool mini_mode_ = false;
  bool mini_dragging_ = false;
  bool mini_timer_resolution_ = false;
  bool mini_drag_moved_ = false;
  POINT drag_cursor_{};
  POINT drag_window_{};
  LONG_PTR main_style_ = 0;

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
