#ifndef RUNNER_MINI_DESKTOP_CAPTURE_H_
#define RUNNER_MINI_DESKTOP_CAPTURE_H_

#include <flutter/encodable_value.h>
#include <flutter/texture_registrar.h>
#include <windows.h>

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

struct GlassCaptureDevice;
struct GlassGpuFrame;

// Captures at the monitor refresh rate, capped by the requested target rate.
class MiniDesktopCapture {
 public:
  MiniDesktopCapture(HWND window, flutter::TextureRegistrar* registrar, int fps);
  ~MiniDesktopCapture();
  static bool IsSupported();
  std::string Start();
  void Stop();
  void SetPaused(bool paused);
  void NotifyWindowMoved();
  flutter::EncodableMap Stats();
  int64_t texture_id() const { return texture_id_; }

 private:
  struct Frame {
    size_t width = 0;
    size_t height = 0;
    std::vector<uint8_t> rgba;
  };
  struct State {
    std::mutex mutex;
    std::shared_ptr<Frame> frame;
    std::shared_ptr<GlassCaptureDevice> capture;
    std::shared_ptr<GlassGpuFrame> gpu_frame;
    std::atomic<bool> active{true};
    std::atomic<bool> paused{false};
    uint64_t previous_hash = 0;
    std::string error;
    std::atomic<uint64_t> frames{0};
    std::atomic<uint64_t> presented{0};
    std::atomic<uint64_t> changes{0};
    std::atomic<uint64_t> stale_crops{0};
    std::atomic<int64_t> last_move_us{0};
    std::atomic<double> luminance{0};
  };
  static std::shared_ptr<Frame> RenderFrame(const std::shared_ptr<State>& state, HWND window);
  static const FlutterDesktopGpuSurfaceDescriptor* RenderGpuFrame(
      const std::shared_ptr<State>& state, HWND window);
  void Run();
  void SetError(HRESULT error);

  HWND window_;
  flutter::TextureRegistrar* registrar_;
  std::shared_ptr<State> state_ = std::make_shared<State>();
  std::shared_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  std::atomic<bool> running_{false};
  std::atomic<bool> paused_{false};
  int fps_;
  DWORD previous_affinity_ = WDA_NONE;
  bool affinity_changed_ = false;
  std::thread thread_;
  std::chrono::steady_clock::time_point started_;
};

#endif
