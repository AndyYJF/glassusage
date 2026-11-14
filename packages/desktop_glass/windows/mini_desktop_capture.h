#ifndef RUNNER_MINI_DESKTOP_CAPTURE_H_
#define RUNNER_MINI_DESKTOP_CAPTURE_H_

#include <flutter/encodable_value.h>
#include <flutter/texture_registrar.h>
#include <windows.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Native capture of a padded mini-window region. During dragging, prepare a
// target-coordinate frame before committing the corresponding window move.
class MiniDesktopCapture {
 public:
  MiniDesktopCapture(HWND window, flutter::TextureRegistrar* registrar, int fps);
  ~MiniDesktopCapture();
  static bool IsSupported();
  std::string Start();
  void Stop();
  void SetPaused(bool paused);
  flutter::EncodableMap Stats();
  int64_t texture_id() const { return texture_id_; }

 private:
  struct CaptureDevice;
  struct Frame {
    size_t width = 0;
    size_t height = 0;
    RECT source_rect{};
    RECT window_rect{};
    HMONITOR monitor = nullptr;
    UINT_PTR sync_token = 0;
#if defined(_DEBUG)
    std::chrono::steady_clock::time_point position_sampled_at;
#endif
    std::vector<uint8_t> rgba;
  };
  struct State {
    std::mutex mutex;
    std::shared_ptr<Frame> frame;
    std::string error;
    std::string capture_state = "waitingForFrame";
    uint64_t recovery_epoch = 1;
    std::chrono::steady_clock::time_point waiting_since =
        std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point last_frame;
    std::atomic<uint64_t> frames{0};
    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> changes{0};
    std::atomic<double> luminance{0};
    bool dragging = false;
    bool finishing_drag = false;
    RECT drag_target{};
    POINT drag_client_offset{};
    uint64_t drag_serial = 0;
    UINT_PTR pending_token = 0;
    UINT_PTR consumed_token = 0;
#if defined(_DEBUG)
    uint64_t diagnostic_samples = 0;
    uint64_t diagnostic_fallbacks = 0;
    uint64_t diagnostic_outside = 0;
    uint64_t diagnostic_moves = 0;
    uint64_t diagnostic_callback_moves = 0;
    double diagnostic_age_sum_ms = 0;
    double diagnostic_age_max_ms = 0;
    double diagnostic_gap_max_ms = 0;
    double diagnostic_moving_gap_max_ms = 0;
    std::chrono::steady_clock::time_point diagnostic_callback_at;
    uint64_t diagnostic_completed_callbacks = 0;
    double diagnostic_callback_duration_sum_ms = 0;
    double diagnostic_callback_duration_max_ms = 0;
#endif
  };
  void Run();
  void SetError(HRESULT error);
  bool BeginDrag();
  void UpdateDrag();
  void EndDrag();
  void CancelDrag();
  void RequestDragFrame(UINT_PTR token);
  void CommitDragFrame(UINT_PTR token);
  static LRESULT CALLBACK WindowSubclassProc(HWND window, UINT message,
      WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data);
  bool subclassed_ = false;
  bool drag_loop_ = false;
  POINT drag_mouse_offset_{};
#if defined(_DEBUG)
  bool probe_notify_on_move_ = false;
#endif

  HWND window_;
  flutter::TextureRegistrar* registrar_;
  std::shared_ptr<State> state_ = std::make_shared<State>();
  std::shared_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  std::atomic<bool> running_{false};
  std::atomic<bool> paused_{false};
  std::condition_variable wake_;
  int fps_;
  DWORD previous_affinity_ = WDA_NONE;
  bool affinity_changed_ = false;
  std::thread thread_;
  std::chrono::steady_clock::time_point started_;
};

#endif
