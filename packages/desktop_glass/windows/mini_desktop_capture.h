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

// A screen-anchored desktop atlas for the fixed mini host. Card motion and
// sampling happen together in Flutter; capture never commits window movement.
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
    RECT bounds{};
    std::vector<uint8_t> rgba;
  };
  struct State {
    std::mutex mutex;
    std::shared_ptr<Frame> frame;
    std::string error;
    uint64_t recovery_epoch = 1;
    std::chrono::steady_clock::time_point waiting_since = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point last_frame;
    std::atomic<uint64_t> frames{0};
    std::atomic<uint64_t> presented{0};
    std::atomic<double> luminance{0};
  };
  void Run();
  void SetError(HRESULT error);
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
