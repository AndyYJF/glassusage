#include "mini_desktop_capture.h"
#include "frame_sync.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstring>
#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")
#if defined(_DEBUG)
#include <cstdarg>
#include <cstdio>
#include <share.h>
#endif
#if defined(_M_X64)
#include <emmintrin.h>
#endif

using Microsoft::WRL::ComPtr;

namespace {
constexpr DWORD kExcludeFromCapture = 0x11;
constexpr int kCapturePadding = 256;
std::atomic<UINT_PTR> next_sync_token{0};

#if defined(_DEBUG)
// Lag probe, Debug builds only and only when GLASSUSAGE_LAG_PROBE is set at
// launch. The texture shows a synthetic pattern anchored to absolute screen
// coordinates plus the callback sequence and the window is NOT excluded from
// capture, so an external duplication tool can read the composed desktop back
// and measure the on-screen offset between backdrop content and window position.
struct LagProbe {
  std::mutex mutex;
  std::vector<std::string> lines;
  std::atomic<uint64_t> callback_sequence{0};
};
LagProbe& Probe() {
  static LagProbe probe;
  return probe;
}
bool ProbeFlag(const wchar_t* name) {
  wchar_t value[8];
  return GetEnvironmentVariableW(name, value, 8) > 0;
}
bool LagProbeEnabled() {
  static const bool enabled = ProbeFlag(L"GLASSUSAGE_LAG_PROBE");
  return enabled;
}
long long ProbeQpc() {
  LARGE_INTEGER value;
  QueryPerformanceCounter(&value);
  return value.QuadPart;
}
void ProbeText(std::string text) {
  std::lock_guard<std::mutex> lock(Probe().mutex);
  if (Probe().lines.size() < 200000) Probe().lines.push_back(std::move(text));
}
void ProbeLine(const char* format, ...) {
  char buffer[512];
  va_list arguments;
  va_start(arguments, format);
  std::vsnprintf(buffer, sizeof(buffer), format, arguments);
  va_end(arguments);
  ProbeText(buffer);
}
constexpr uint32_t kProbeMagenta = 0xffff00ff;  // RGBA bytes ff,00,ff,ff
constexpr uint32_t kProbeGreen = 0xff00ff00;    // RGBA bytes 00,ff,00,ff
constexpr int kProbeStripePeriod = 512;
constexpr int kProbeStripeWidth = 64;
#endif
}  // namespace

struct MiniDesktopCapture::CaptureDevice {
  HMONITOR monitor = nullptr;
  DXGI_OUTPUT_DESC output{};
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutputDuplication> duplication;
  ComPtr<ID3D11Texture2D> desktop;
  ComPtr<ID3D11Texture2D> staging;
  UINT crop_width = 0;
  UINT crop_height = 0;

  HRESULT Initialize(HMONITOR requested) {
    *this = CaptureDevice{};
    ComPtr<IDXGIFactory1> factory;
    HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return hr;
    for (UINT a = 0;; ++a) {
      ComPtr<IDXGIAdapter1> adapter;
      hr = factory->EnumAdapters1(a, &adapter);
      if (hr == DXGI_ERROR_NOT_FOUND) break;
      if (FAILED(hr)) return hr;
      for (UINT o = 0;; ++o) {
        ComPtr<IDXGIOutput> candidate;
        hr = adapter->EnumOutputs(o, &candidate);
        if (hr == DXGI_ERROR_NOT_FOUND) break;
        if (FAILED(hr)) return hr;
        hr = candidate->GetDesc(&output);
        if (FAILED(hr)) return hr;
        if (output.Monitor != requested || !output.AttachedToDesktop) continue;
        hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
            &device, nullptr, &context);
        if (FAILED(hr)) return hr;
        ComPtr<IDXGIOutput1> output1;
        hr = candidate.As(&output1);
        if (FAILED(hr)) return hr;
        hr = output1->DuplicateOutput(device.Get(), &duplication);
        if (SUCCEEDED(hr)) monitor = requested;
        return hr;
      }
    }
    return DXGI_ERROR_NOT_FOUND;
  }

  POINT SourcePoint(int x, int y, const D3D11_TEXTURE2D_DESC& desc) const {
    switch (output.Rotation) {
      case DXGI_MODE_ROTATION_ROTATE90:
        return POINT{y, static_cast<LONG>(desc.Height) - 1 - x};
      case DXGI_MODE_ROTATION_ROTATE180:
        return POINT{static_cast<LONG>(desc.Width) - 1 - x,
                     static_cast<LONG>(desc.Height) - 1 - y};
      case DXGI_MODE_ROTATION_ROTATE270:
        return POINT{static_cast<LONG>(desc.Width) - 1 - y, x};
      default:
        return POINT{x, y};
    }
  }
};

MiniDesktopCapture::MiniDesktopCapture(
    HWND window, flutter::TextureRegistrar* registrar, int fps)
    : window_(window), registrar_(registrar), fps_(fps) {}

MiniDesktopCapture::~MiniDesktopCapture() { Stop(); }

bool MiniDesktopCapture::IsSupported() {
  using GetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto get_version = reinterpret_cast<GetVersion>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  return get_version && get_version(&version) == 0 && version.dwBuildNumber >= 19041;
}

std::string MiniDesktopCapture::Start() {
  if (running_) return {};
  if (!IsSupported()) {
    return "Live backdrop requires Windows 10 2004 or later";
  }
  GetWindowDisplayAffinity(window_, &previous_affinity_);
#if defined(_DEBUG)
  const bool lag_probe = LagProbeEnabled();
#else
  const bool lag_probe = false;
#endif
  if (!lag_probe) {
    if (!SetWindowDisplayAffinity(window_, kExcludeFromCapture)) {
      return "Cannot exclude mini window from capture: " +
             std::to_string(GetLastError());
    }
    affinity_changed_ = true;
  }
  const auto state = state_;
  const HWND window = window_;
  texture_ = std::make_shared<flutter::TextureVariant>(
      flutter::PixelBufferTexture([state, window](size_t, size_t)
          -> const FlutterDesktopPixelBuffer* {
#if defined(_DEBUG)
        const auto requested_at = std::chrono::steady_clock::now();
        bool cropped_current = false;
        bool outside = false;
#endif
        struct Lease {
          FlutterDesktopPixelBuffer buffer{};
          std::shared_ptr<Frame> frame;
          std::vector<uint8_t> rgba;
        };
        auto lease = std::make_unique<Lease>();
        bool synchronized_frame = false;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          lease->frame = state->frame;
          synchronized_frame = lease->frame && lease->frame->sync_token != 0 &&
              lease->frame->sync_token == state->pending_token;
        }
        if (!lease->frame) return nullptr;
        const auto& frame = *lease->frame;
        RECT view = frame.window_rect;
        if (!synchronized_frame) {
          POINT origin{0, 0};
          if (!GetClientRect(window, &view) || !ClientToScreen(window, &origin)) {
            return nullptr;
          }
          OffsetRect(&view, origin.x, origin.y);
        }
        if (view.right <= view.left || view.bottom <= view.top ||
            view.right - view.left > 4096 || view.bottom - view.top > 4096) {
          return nullptr;
        }
#if defined(_DEBUG)
        cropped_current = true;
        outside = view.left < frame.source_rect.left ||
            view.top < frame.source_rect.top ||
            view.right > frame.source_rect.right ||
            view.bottom > frame.source_rect.bottom;
#endif
#if defined(_DEBUG)
        const double age_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - frame.position_sampled_at).count();
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          ++state->diagnostic_samples;
          if (!cropped_current) ++state->diagnostic_fallbacks;
          if (outside) ++state->diagnostic_outside;
          state->diagnostic_age_sum_ms += age_ms;
          state->diagnostic_age_max_ms = std::max(state->diagnostic_age_max_ms, age_ms);
          if (state->diagnostic_callback_at != std::chrono::steady_clock::time_point{}) {
            const double gap_ms = std::chrono::duration<double, std::milli>(
                requested_at - state->diagnostic_callback_at).count();
            state->diagnostic_gap_max_ms = std::max(state->diagnostic_gap_max_ms, gap_ms);
            if (state->diagnostic_moves != state->diagnostic_callback_moves) {
              state->diagnostic_moving_gap_max_ms =
                  std::max(state->diagnostic_moving_gap_max_ms, gap_ms);
            }
          }
          state->diagnostic_callback_at = requested_at;
          state->diagnostic_callback_moves = state->diagnostic_moves;
        }
#endif
        const size_t width = static_cast<size_t>(view.right - view.left);
        const size_t height = static_cast<size_t>(view.bottom - view.top);
        const size_t stride = width * 4;
        lease->rgba.resize(stride * height);
#if defined(_DEBUG)
        if (LagProbeEnabled() && width > 0 && height > 0) {
          const uint64_t sequence = Probe().callback_sequence.fetch_add(1) + 1;
          ProbeLine("probe_cb seq=%llu qpc=%lld view=%ld,%ld,%ld,%ld token=%llu",
              static_cast<unsigned long long>(sequence), ProbeQpc(),
              view.left, view.top, view.right, view.bottom,
              static_cast<unsigned long long>(synchronized_frame ? frame.sync_token : 0));
          std::vector<uint32_t> stripe(width), code(width);
          for (size_t x = 0; x < width; ++x) {
            const int absolute = static_cast<int>(view.left) + static_cast<int>(x);
            const int phase = ((absolute % kProbeStripePeriod) + kProbeStripePeriod) %
                kProbeStripePeriod;
            stripe[x] = phase < kProbeStripeWidth ? kProbeGreen : kProbeMagenta;
            code[x] = ((sequence >> (x * 8 / width)) & 1) ? kProbeGreen : kProbeMagenta;
          }
          for (size_t y = 0; y < height; ++y) {
            std::memcpy(lease->rgba.data() + y * stride,
                        (y < height / 2 ? stripe : code).data(), stride);
          }
        } else
#endif
        {
          // Never substitute an older screen origin when the prefetched
          // region does not cover a teleport/resize. Unavailable pixels stay
          // transparent until capture catches up; valid pixels keep their
          // actual screen coordinates.
          RECT overlap{};
          if (IntersectRect(&overlap, &view, &frame.source_rect)) {
            const size_t bytes = static_cast<size_t>(overlap.right - overlap.left) * 4;
            for (LONG y = overlap.top; y < overlap.bottom; ++y) {
              const auto* source = frame.rgba.data() +
                  ((y - frame.source_rect.top) * frame.width +
                   (overlap.left - frame.source_rect.left)) * 4;
              auto* target = lease->rgba.data() +
                  (static_cast<size_t>(y - view.top) * width +
                   static_cast<size_t>(overlap.left - view.left)) * 4;
              std::memcpy(target, source, bytes);
            }
          }
        }
        if (synchronized_frame) {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (state->pending_token == frame.sync_token) {
            state->consumed_token = frame.sync_token;
          }
        }
        lease->buffer.buffer = lease->rgba.data();
        lease->buffer.width = width;
        lease->buffer.height = height;
        lease->buffer.release_context = lease.get();
        lease->buffer.release_callback = [](void* context) {
          delete static_cast<Lease*>(context);
        };
        state->presented.fetch_add(1);
#if defined(_DEBUG)
        const double callback_duration_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - requested_at).count();
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          ++state->diagnostic_completed_callbacks;
          state->diagnostic_callback_duration_sum_ms += callback_duration_ms;
          state->diagnostic_callback_duration_max_ms = std::max(
              state->diagnostic_callback_duration_max_ms, callback_duration_ms);
        }
#endif
        return &lease.release()->buffer;
      }));
  texture_id_ = registrar_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    texture_.reset();
    SetWindowDisplayAffinity(window_, previous_affinity_);
    affinity_changed_ = false;
    return "Cannot register live desktop texture";
  }
  started_ = std::chrono::steady_clock::now();
  subclassed_ = SetWindowSubclass(window_, WindowSubclassProc, 0x4750,
      reinterpret_cast<DWORD_PTR>(this)) != 0;
  if (!subclassed_) return "Cannot install synchronized mini-window dragging";
  running_ = true;
  thread_ = std::thread(&MiniDesktopCapture::Run, this);
#if defined(_DEBUG)
  if (lag_probe) {
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    probe_notify_on_move_ = ProbeFlag(L"GLASSUSAGE_LAG_PROBE_NOTIFY_MOVE");
    ProbeLine("probe_start qpc=%lld freq=%lld tick_ms=%llu subclassed=%d notify_on_move=%d",
        ProbeQpc(), frequency.QuadPart,
        static_cast<unsigned long long>(GetTickCount64()),
        subclassed_ ? 1 : 0, probe_notify_on_move_ ? 1 : 0);
  }
#endif
  return {};
}

bool MiniDesktopCapture::BeginDrag() {
  POINT cursor{}, client{0, 0};
  RECT outer{}, size{};
  if (!GetCursorPos(&cursor) || !GetWindowRect(window_, &outer) ||
      !GetClientRect(window_, &size) || !ClientToScreen(window_, &client)) return false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->frame || paused_) return false;
    if (state_->dragging) return true;
  }
  if (!(GetAsyncKeyState(VK_LBUTTON) & 0x8000)) return true;
  SetCapture(window_);
  if (GetCapture() != window_) return false;
  drag_mouse_offset_ = {cursor.x - outer.left, cursor.y - outer.top};
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->dragging = true;
    state_->finishing_drag = false;
    state_->drag_client_offset = {client.x - outer.left, client.y - outer.top};
    OffsetRect(&size, client.x, client.y);
    state_->drag_target = size;
    if (!drag_loop_) ++state_->drag_serial;
  }
  if (!drag_loop_) {
    drag_loop_ = true;
    SendMessageW(window_, WM_ENTERSIZEMOVE, 0, 0);
  }
  return true;
}

void MiniDesktopCapture::UpdateDrag() {
  POINT cursor{};
  RECT size{};
  if (!GetCursorPos(&cursor) || !GetClientRect(window_, &size)) return;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->dragging) return;
    OffsetRect(&size, cursor.x - drag_mouse_offset_.x + state_->drag_client_offset.x,
               cursor.y - drag_mouse_offset_.y + state_->drag_client_offset.y);
    state_->drag_target = size;
  }
#if defined(_DEBUG)
  if (LagProbeEnabled()) {
    ProbeLine("probe_drag_target qpc=%lld rect=%ld,%ld", ProbeQpc(), size.left, size.top);
  }
#endif
}

void MiniDesktopCapture::EndDrag() {
  UpdateDrag();
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (!state_->dragging) return;
    state_->dragging = false;
    state_->finishing_drag = true;
  }
  if (GetCapture() == window_) ReleaseCapture();
}

void MiniDesktopCapture::CancelDrag() {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->dragging = false;
    state_->finishing_drag = false;
    state_->pending_token = 0;
    state_->consumed_token = 0;
    ++state_->drag_serial;
  }
  if (GetCapture() == window_) ReleaseCapture();
  if (drag_loop_) {
    drag_loop_ = false;
    SendMessageW(window_, WM_EXITSIZEMOVE, 0, 0);
  }
  wake_.notify_all();
}

void MiniDesktopCapture::RequestDragFrame(UINT_PTR token) {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (token == 0 || state_->pending_token != token) return;
  }
  if (SendMessageW(window_, glassusage_frame_sync::Request(), token, 0) != 1) {
    CancelDrag();
    return;
  }
  registrar_->MarkTextureFrameAvailable(texture_id_);
}

void MiniDesktopCapture::CommitDragFrame(UINT_PTR token) {
  RECT target{};
  POINT client_offset{};
  bool consumed;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (state_->pending_token != token || !state_->frame) return;
    consumed = state_->consumed_token == token;
    target = state_->frame->window_rect;
    client_offset = state_->drag_client_offset;
  }
  if (!consumed) {
    // An unrelated already-scheduled frame must not move the window early.
    RequestDragFrame(token);
    return;
  }
  RECT outer = target;
  OffsetRect(&outer, -client_offset.x, -client_offset.y);
  SendMessageW(window_, WM_MOVING, WMSZ_LEFT, reinterpret_cast<LPARAM>(&outer));
  const BOOL moved = SetWindowPos(window_, nullptr, target.left - client_offset.x,
      target.top - client_offset.y, 0, 0,
      SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (!moved) {
    CancelDrag();
    return;
  }
  bool finished = false;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    // Hide/pause can re-enter through SetWindowPos and cancel this token.
    if (state_->pending_token != token) return;
    state_->pending_token = 0;
    state_->consumed_token = 0;
    finished = !state_->dragging && target.left == state_->drag_target.left &&
        target.top == state_->drag_target.top;
    if (finished) state_->finishing_drag = false;
  }
#if defined(_DEBUG)
  if (LagProbeEnabled()) {
    ProbeLine("probe_sync_commit token=%llu qpc=%lld rect=%ld,%ld",
        static_cast<unsigned long long>(token), ProbeQpc(), target.left, target.top);
  }
#endif
  if (finished && drag_loop_) {
    drag_loop_ = false;
    SendMessageW(window_, WM_EXITSIZEMOVE, 0, 0);
  }
  wake_.notify_all();
}

LRESULT CALLBACK MiniDesktopCapture::WindowSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR,
    DWORD_PTR data) {
  auto* self = reinterpret_cast<MiniDesktopCapture*>(data);
  if (message == glassusage_frame_sync::Ready()) {
    self->RequestDragFrame(static_cast<UINT_PTR>(wparam));
    return 0;
  }
  if (message == glassusage_frame_sync::Presented()) {
    self->CommitDragFrame(static_cast<UINT_PTR>(wparam));
    return 0;
  }
  if (message == WM_SYSCOMMAND && (wparam & 0xfff0) == SC_MOVE &&
      (wparam & 0xf) == HTCAPTION && self->BeginDrag()) return 0;
  if (message == WM_MOUSEMOVE && self->drag_loop_ && GetCapture() == window) {
    if (GetAsyncKeyState(VK_LBUTTON) & 0x8000) self->UpdateDrag();
    else self->EndDrag();
    return 0;
  }
  if (message == WM_LBUTTONUP && self->drag_loop_ && GetCapture() == window) {
    self->EndDrag();
    return 0;
  }
  if (message == WM_CAPTURECHANGED || message == WM_CANCELMODE) self->EndDrag();
  if ((message == WM_SHOWWINDOW && !wparam) ||
      (message == WM_SIZE && wparam == SIZE_MINIMIZED)) self->CancelDrag();
#if defined(_DEBUG)
  if (LagProbeEnabled()) {
    if (message == WM_WINDOWPOSCHANGED) {
      const auto* position = reinterpret_cast<const WINDOWPOS*>(lparam);
      if (!(position->flags & SWP_NOMOVE)) {
        ProbeLine("probe_move qpc=%lld x=%d y=%d", ProbeQpc(), position->x, position->y);
        if (self->probe_notify_on_move_ && self->texture_id_ >= 0) {
          self->registrar_->MarkTextureFrameAvailable(self->texture_id_);
        }
      }
    } else if (message == WM_ENTERSIZEMOVE || message == WM_EXITSIZEMOVE) {
      ProbeLine("probe_sizemove qpc=%lld enter=%d", ProbeQpc(),
          message == WM_ENTERSIZEMOVE ? 1 : 0);
    }
  }
#endif
  return DefSubclassProc(window, message, wparam, lparam);
}

void MiniDesktopCapture::Stop() {
  CancelDrag();
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    running_ = false;
    state_->frame.reset();
    state_->capture_state = "ended";
    ++state_->recovery_epoch;
  }
  wake_.notify_all();
  if (thread_.joinable()) thread_.join();
  if (subclassed_ && IsWindow(window_)) {
    RemoveWindowSubclass(window_, WindowSubclassProc, 0x4750);
  }
  subclassed_ = false;
  if (texture_id_ >= 0) {
    // Keep callbacks and their frame store alive until raster-thread retirement.
    const auto texture = texture_;
    registrar_->UnregisterTexture(texture_id_, [texture]() {});
    texture_id_ = -1;
    texture_.reset();
  }
  if (affinity_changed_ && IsWindow(window_)) {
    SetWindowDisplayAffinity(window_, previous_affinity_);
  }
  affinity_changed_ = false;
}

void MiniDesktopCapture::SetPaused(bool paused) {
  if (paused) CancelDrag();
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (paused_.exchange(paused) == paused) return;
    state_->frame.reset();
    state_->error.clear();
    state_->capture_state = paused ? "paused" : "waitingForFrame";
    state_->waiting_since = std::chrono::steady_clock::now();
    ++state_->recovery_epoch;
  }
  wake_.notify_all();
}

void MiniDesktopCapture::SetError(HRESULT error) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (state_->frame) state_->waiting_since = std::chrono::steady_clock::now();
  state_->frame.reset();
  state_->capture_state = "retrying";
  ++state_->recovery_epoch;
  state_->error = "Desktop capture HRESULT " +
                  std::to_string(static_cast<uint32_t>(error));
}

flutter::EncodableMap MiniDesktopCapture::Stats() {
  using V = flutter::EncodableValue;
  const double elapsed = std::chrono::duration<double>(
      std::chrono::steady_clock::now() - started_).count();
  flutter::EncodableMap result;
  result[V("textureId")] = V(texture_id_);
  result[V("frames")] = V(static_cast<int64_t>(state_->frames.load()));
  result[V("presented")] = V(static_cast<int64_t>(state_->presented.load()));
  result[V("changes")] = V(static_cast<int64_t>(state_->changes.load()));
  result[V("elapsed")] = V(elapsed);
  result[V("luminance")] = V(state_->luminance.load());
  const bool paused = paused_.load() || !IsWindowVisible(window_) || IsIconic(window_);
  result[V("paused")] = V(paused);
  DWORD affinity = WDA_NONE;
  GetWindowDisplayAffinity(window_, &affinity);
  result[V("selfExcluded")] = V(affinity == kExcludeFromCapture);
  std::lock_guard<std::mutex> lock(state_->mutex);
  const bool valid = !paused && state_->frame != nullptr;
  const bool timed_out = !paused && !valid &&
      std::chrono::steady_clock::now() - state_->waiting_since >
          std::chrono::seconds(5);
  result[V("hasValidFrame")] = V(valid);
  result[V("captureState")] = V(std::string(
      paused ? "paused" : timed_out ? "failed" : state_->capture_state));
  result[V("recoveryEpoch")] = V(static_cast<int64_t>(state_->recovery_epoch));
  if (state_->last_frame != std::chrono::steady_clock::time_point{}) {
    result[V("lastFrameAgeMs")] = V(std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - state_->last_frame).count());
  }
  result[V("error")] = V(state_->error);
  if (state_->frame) {
    const auto& rect = state_->frame->window_rect;
    result[V("width")] = V(static_cast<int>(rect.right - rect.left));
    result[V("height")] = V(static_cast<int>(rect.bottom - rect.top));
  }
  return result;
}

void MiniDesktopCapture::Run() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
#if defined(_DEBUG)
  FILE* latency_log = nullptr;
  wchar_t temporary_path[MAX_PATH]{};
  const DWORD temporary_length = GetTempPathW(MAX_PATH, temporary_path);
  if (temporary_length > 0 && temporary_length < MAX_PATH) {
    const std::wstring path = std::wstring(temporary_path, temporary_length) +
        L"glassusage-latency-" + std::to_wstring(GetCurrentProcessId()) + L".log";
    latency_log = _wfsopen(path.c_str(), L"a", _SH_DENYNO);
    if (latency_log) {
      std::fprintf(latency_log, "session_start tick_ms=%llu pid=%lu; age=position_sample_to_crop; gap=callback_start_interval; publish=changed_frame_assignment; callback_duration=valid_entry_to_final_metrics_before_return\n",
          static_cast<unsigned long long>(GetTickCount64()), GetCurrentProcessId());
      std::fflush(latency_log);
    }
  }
  auto diagnostic_report_at = std::chrono::steady_clock::now();
  uint64_t diagnostic_report_moves = 0;
  uint64_t diagnostic_publications = 0;
  double diagnostic_publish_gap_max_ms = 0;
  double diagnostic_moving_publish_gap_max_ms = 0;
  std::chrono::steady_clock::time_point diagnostic_published_at;
  enum DiagnosticStage {
    kPace, kReport, kPreflight, kAcquire, kDesktopCopy, kRelease,
    kClientRect, kClientToScreen, kReadbackPrepare, kGpuCopy, kMap,
    kConvert, kUnmap, kValidate, kPublish, kNotify, kFinish, kStageCount
  };
  const char* stage_names[kStageCount] = {
    "pace", "report", "preflight", "acquire", "desktop_copy", "release",
    "client_rect", "client_to_screen", "readback_prepare", "gpu_copy", "map",
    "convert", "unmap", "validate", "publish", "notify", "finish"
  };
  struct DiagnosticRecord {
    uint64_t sequence = 0;
    ULONGLONG tick = 0;
    double start_ms = 0, total_ms = 0, sample_offset_ms = 0, since_publish_ms = 0;
    const char* outcome = "unclassified";
    int exit_stage = kPace;
    DWORD error = 0;
    bool sampled = false, had_previous = false, had_published = false;
    bool outer_valid = false, cursor_valid = false, validated = false;
    bool desktop_changed = false, acquired = false;
    RECT rect{}, previous{}, published{}, outer{}, validation{};
    POINT cursor{};
  };
  std::vector<DiagnosticRecord> diagnostic_records;
  diagnostic_records.reserve(128);
  uint64_t diagnostic_sequence = 0;
  RECT diagnostic_previous_sample{}, diagnostic_published_rect{};
  bool diagnostic_had_sample = false, diagnostic_had_publication = false;
  const auto flush_diagnostic_records = [&] {
    if (!latency_log) return;
    for (const auto& record : diagnostic_records) {
      std::fprintf(latency_log,
          "loop seq=%llu tick_ms=%llu start_ms=%.3f total_ms=%.3f reason=%s exit_stage=%s error=0x%08lX "
          "sampled=%d sample_offset_ms=%.3f desktop_changed=%d acquired=%d "
          "rect=%ld,%ld,%ld,%ld previous_valid=%d previous=%ld,%ld,%ld,%ld "
          "delta=%ld,%ld published_valid=%d published=%ld,%ld,%ld,%ld since_publish_ms=%.3f "
          "outer_valid=%d outer=%ld,%ld,%ld,%ld cursor_valid=%d cursor=%ld,%ld "
          "validated=%d validation=%ld,%ld,%ld,%ld\n",
          static_cast<unsigned long long>(record.sequence),
          static_cast<unsigned long long>(record.tick), record.start_ms, record.total_ms,
          record.outcome, stage_names[record.exit_stage], record.error,
          record.sampled ? 1 : 0, record.sample_offset_ms, record.desktop_changed ? 1 : 0,
          record.acquired ? 1 : 0, record.rect.left, record.rect.top, record.rect.right, record.rect.bottom,
          record.had_previous ? 1 : 0, record.previous.left, record.previous.top,
          record.previous.right, record.previous.bottom,
          record.sampled && record.had_previous ? record.rect.left - record.previous.left : 0L,
          record.sampled && record.had_previous ? record.rect.top - record.previous.top : 0L,
          record.had_published ? 1 : 0, record.published.left, record.published.top,
          record.published.right, record.published.bottom, record.since_publish_ms,
          record.outer_valid ? 1 : 0, record.outer.left, record.outer.top, record.outer.right, record.outer.bottom,
          record.cursor_valid ? 1 : 0, record.cursor.x, record.cursor.y,
          record.validated ? 1 : 0, record.validation.left, record.validation.top,
          record.validation.right, record.validation.bottom);
    }
    diagnostic_records.clear();
  };
  const auto flush_probe_lines = [&] {
    std::vector<std::string> lines;
    {
      std::lock_guard<std::mutex> lock(Probe().mutex);
      lines.swap(Probe().lines);
    }
    if (!latency_log) return;
    for (const auto& line : lines) std::fprintf(latency_log, "%s\n", line.c_str());
  };
  struct DiagnosticStageStats {
    uint64_t loops = 0, inactive = 0, unchanged = 0, moving = 0;
    double maximum_ms[kStageCount]{};
    double wake_late_max_ms = 0;
    double slowest_ms = 0, slowest_wake_late_ms = 0;
    double slowest_stages[kStageCount]{};
    ULONGLONG slowest_tick = 0;
    const char* slowest_outcome = "none";
    bool slowest_moving = false;
  } diagnostic_stage_stats;
  struct DiagnosticLoop {
    DiagnosticStageStats& stats;
    std::vector<DiagnosticRecord>* records;
    DiagnosticRecord record;
    std::chrono::steady_clock::time_point started = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point checkpoint = started;
    ULONGLONG tick = GetTickCount64();
    DiagnosticStage stage = kPace;
    double elapsed_ms[kStageCount]{};
    double wake_late_ms = 0;
    const char* outcome = "unclassified";
    bool inactive = false, unchanged = false, moving = false;

    DiagnosticLoop(DiagnosticStageStats& value, std::vector<DiagnosticRecord>* output)
        : stats(value), records(output) {}
    void Enter(DiagnosticStage next) {
      const auto time = std::chrono::steady_clock::now();
      elapsed_ms[stage] += std::chrono::duration<double, std::milli>(time - checkpoint).count();
      checkpoint = time;
      stage = next;
    }
    ~DiagnosticLoop() {
      record.exit_stage = stage;
      Enter(kFinish);
      record.total_ms = std::chrono::duration<double, std::milli>(checkpoint - started).count();
      record.outcome = outcome;
      if (records) records->push_back(record);
      ++stats.loops;
      if (inactive) { ++stats.inactive; return; }
      if (unchanged) ++stats.unchanged;
      if (moving) ++stats.moving;
      stats.wake_late_max_ms = std::max(stats.wake_late_max_ms, wake_late_ms);
      const double total_ms = std::chrono::duration<double, std::milli>(checkpoint - started).count();
      const bool slowest = total_ms > stats.slowest_ms;
      for (int i = 0; i < kStageCount; ++i) {
        stats.maximum_ms[i] = std::max(stats.maximum_ms[i], elapsed_ms[i]);
        if (slowest) stats.slowest_stages[i] = elapsed_ms[i];
      }
      if (slowest) {
        stats.slowest_ms = total_ms;
        stats.slowest_tick = tick;
        stats.slowest_outcome = outcome;
        stats.slowest_moving = moving;
        stats.slowest_wake_late_ms = wake_late_ms;
      }
    }
  };
#endif
  std::unique_ptr<CaptureDevice> capture;
  RECT previous_rect{};
  uint64_t previous_hash = 0;
  uint64_t capture_epoch = 0;
  bool was_hidden = false;
  auto next_frame = std::chrono::steady_clock::now();
  const auto kFramePeriod = std::chrono::nanoseconds(1000000000 / fps_);
  while (running_) {
#if defined(_DEBUG)
    DiagnosticLoop diagnostic_loop(diagnostic_stage_stats, latency_log ? &diagnostic_records : nullptr);
    diagnostic_loop.record.sequence = ++diagnostic_sequence;
    diagnostic_loop.record.tick = diagnostic_loop.tick;
    diagnostic_loop.record.start_ms = std::chrono::duration<double, std::milli>(
        diagnostic_loop.started - started_).count();
    diagnostic_loop.record.published = diagnostic_published_rect;
    diagnostic_loop.record.had_published = diagnostic_had_publication;
#endif
    next_frame += kFramePeriod;
    {
      std::unique_lock<std::mutex> lock(state_->mutex);
      wake_.wait_until(lock, next_frame, [this] { return !running_ || paused_; });
      if (paused_ && running_) {
#if defined(_DEBUG)
        diagnostic_loop.inactive = true;
#endif
        wake_.wait(lock, [this] { return !running_ || !paused_; });
        next_frame = std::chrono::steady_clock::now();
      }
    }
    const auto now = std::chrono::steady_clock::now();
#if defined(_DEBUG)
    diagnostic_loop.wake_late_ms = std::max(0.0,
        std::chrono::duration<double, std::milli>(now - next_frame).count());
    diagnostic_loop.Enter(kReport);
    if (latency_log && now - diagnostic_report_at >= std::chrono::seconds(1)) {
      uint64_t samples, fallbacks, outside, moves;
      uint64_t completed_callbacks;
      double age_sum_ms, age_max_ms, gap_max_ms, moving_gap_max_ms, since_callback_ms;
      double callback_duration_sum_ms, callback_duration_max_ms;
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        samples = state_->diagnostic_samples;
        fallbacks = state_->diagnostic_fallbacks;
        outside = state_->diagnostic_outside;
        moves = state_->diagnostic_moves;
        age_sum_ms = state_->diagnostic_age_sum_ms;
        age_max_ms = state_->diagnostic_age_max_ms;
        gap_max_ms = state_->diagnostic_gap_max_ms;
        moving_gap_max_ms = state_->diagnostic_moving_gap_max_ms;
        completed_callbacks = state_->diagnostic_completed_callbacks;
        callback_duration_sum_ms = state_->diagnostic_callback_duration_sum_ms;
        callback_duration_max_ms = state_->diagnostic_callback_duration_max_ms;
        since_callback_ms = state_->diagnostic_callback_at == std::chrono::steady_clock::time_point{} ? 0 :
            std::chrono::duration<double, std::milli>(now - state_->diagnostic_callback_at).count();
        state_->diagnostic_samples = 0;
        state_->diagnostic_fallbacks = 0;
        state_->diagnostic_outside = 0;
        state_->diagnostic_age_sum_ms = 0;
        state_->diagnostic_age_max_ms = 0;
        state_->diagnostic_gap_max_ms = 0;
        state_->diagnostic_moving_gap_max_ms = 0;
        state_->diagnostic_completed_callbacks = 0;
        state_->diagnostic_callback_duration_sum_ms = 0;
        state_->diagnostic_callback_duration_max_ms = 0;
      }
      std::fprintf(latency_log,
          "tick_ms=%llu span_ms=%.1f samples=%llu moves=%llu fallbacks=%llu outside=%llu "
          "frame_age_avg_ms=%.3f frame_age_max_ms=%.3f callback_gap_max_ms=%.3f "
          "moving_gap_max_ms=%.3f since_callback_ms=%.3f "
          "publications=%llu publish_gap_max_ms=%.3f moving_publish_gap_max_ms=%.3f "
          "since_publish_ms=%.3f completed_callbacks=%llu "
          "callback_duration_avg_ms=%.3f callback_duration_max_ms=%.3f\n",
          static_cast<unsigned long long>(GetTickCount64()),
          std::chrono::duration<double, std::milli>(now - diagnostic_report_at).count(),
          static_cast<unsigned long long>(samples),
          static_cast<unsigned long long>(moves - diagnostic_report_moves),
          static_cast<unsigned long long>(fallbacks), static_cast<unsigned long long>(outside),
          samples ? age_sum_ms / static_cast<double>(samples) : 0,
          age_max_ms, gap_max_ms, moving_gap_max_ms, since_callback_ms,
          static_cast<unsigned long long>(diagnostic_publications),
          diagnostic_publish_gap_max_ms, diagnostic_moving_publish_gap_max_ms,
          diagnostic_published_at == std::chrono::steady_clock::time_point{} ? 0 :
              std::chrono::duration<double, std::milli>(now - diagnostic_published_at).count(),
          static_cast<unsigned long long>(completed_callbacks),
          completed_callbacks ? callback_duration_sum_ms / static_cast<double>(completed_callbacks) : 0,
          callback_duration_max_ms);
      std::fprintf(latency_log,
          "stages tick_ms=%llu loops=%llu inactive=%llu unchanged=%llu moving=%llu wake_late_max_ms=%.3f",
          static_cast<unsigned long long>(GetTickCount64()),
          static_cast<unsigned long long>(diagnostic_stage_stats.loops),
          static_cast<unsigned long long>(diagnostic_stage_stats.inactive),
          static_cast<unsigned long long>(diagnostic_stage_stats.unchanged),
          static_cast<unsigned long long>(diagnostic_stage_stats.moving),
          diagnostic_stage_stats.wake_late_max_ms);
      for (int i = 0; i < kStageCount; ++i) {
        std::fprintf(latency_log, " %s_max_ms=%.3f", stage_names[i], diagnostic_stage_stats.maximum_ms[i]);
      }
      std::fprintf(latency_log,
          "\nslow_loop start_tick_ms=%llu outcome=%s moving=%d total_ms=%.3f wake_late_ms=%.3f",
          static_cast<unsigned long long>(diagnostic_stage_stats.slowest_tick),
          diagnostic_stage_stats.slowest_outcome, diagnostic_stage_stats.slowest_moving ? 1 : 0,
          diagnostic_stage_stats.slowest_ms, diagnostic_stage_stats.slowest_wake_late_ms);
      for (int i = 0; i < kStageCount; ++i) {
        std::fprintf(latency_log, " %s_ms=%.3f", stage_names[i], diagnostic_stage_stats.slowest_stages[i]);
      }
      std::fprintf(latency_log, "\n");
      flush_diagnostic_records();
      flush_probe_lines();
      std::fflush(latency_log);
      diagnostic_stage_stats = {};
      diagnostic_report_at = now;
      diagnostic_report_moves = moves;
      diagnostic_publications = 0;
      diagnostic_publish_gap_max_ms = 0;
      diagnostic_moving_publish_gap_max_ms = 0;
    }
    diagnostic_loop.Enter(kPreflight);
#endif
    if (next_frame < now - kFramePeriod) next_frame = now;
#if defined(_DEBUG)
    diagnostic_loop.outcome = "stopped";
#endif
    if (!running_) break;
    if (!IsWindowVisible(window_) || IsIconic(window_)) {
#if defined(_DEBUG)
      diagnostic_loop.inactive = true;
      diagnostic_loop.outcome = "hidden_or_minimized";
#endif
      std::unique_lock<std::mutex> lock(state_->mutex);
      if (!was_hidden) {
        state_->frame.reset();
        state_->capture_state = "paused";
        ++state_->recovery_epoch;
        was_hidden = true;
      }
      wake_.wait_for(lock, std::chrono::milliseconds(100),
                     [this] { return !running_ || paused_; });
      continue;
    }
    uint64_t epoch, drag_serial;
    bool synchronized_drag;
    RECT drag_target{};
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (state_->pending_token != 0) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "awaiting_drag_frame";
#endif
        continue;
      }
      if (was_hidden) {
        state_->waiting_since = now;
        was_hidden = false;
      }
      epoch = state_->recovery_epoch;
      drag_serial = state_->drag_serial;
      synchronized_drag = state_->dragging || state_->finishing_drag;
      drag_target = state_->drag_target;
    }
    const HMONITOR monitor = synchronized_drag
        ? MonitorFromRect(&drag_target, MONITOR_DEFAULTTONEAREST)
        : MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
    if (!capture || capture->monitor != monitor || capture_epoch != epoch) {
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (paused_) {
#if defined(_DEBUG)
          diagnostic_loop.outcome = "reset_paused";
#endif
          continue;
        }
        if (!running_) {
#if defined(_DEBUG)
          diagnostic_loop.outcome = "reset_stopped";
#endif
          continue;
        }
        if (epoch != state_->recovery_epoch) {
#if defined(_DEBUG)
          diagnostic_loop.outcome = "reset_epoch_changed";
#endif
          continue;
        }
        if (state_->frame) state_->waiting_since = now;
        state_->frame.reset();
        state_->capture_state = capture_epoch == 0 ? "waitingForFrame" : "recovering";
        epoch = ++state_->recovery_epoch;
      }
      capture_epoch = epoch;
      capture = std::make_unique<CaptureDevice>();
      previous_rect = {};
      const HRESULT hr = capture->Initialize(monitor);
      if (FAILED(hr)) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "capture_initialize_failed";
        diagnostic_loop.record.error = static_cast<DWORD>(hr);
#endif
        SetError(hr);
        std::unique_lock<std::mutex> lock(state_->mutex);
        wake_.wait_for(lock, std::chrono::milliseconds(250),
                       [this] { return !running_ || paused_; });
        continue;
      }
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kAcquire);
#endif
    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> resource;
    HRESULT hr = capture->duplication->AcquireNextFrame(1, &info, &resource);
#if defined(_DEBUG)
    diagnostic_loop.Enter(kDesktopCopy);
#endif
    const bool acquired = SUCCEEDED(hr);
    const bool desktop_changed = acquired &&
        (info.LastPresentTime.QuadPart != 0 || !capture->desktop);
#if defined(_DEBUG)
    diagnostic_loop.record.acquired = acquired;
    diagnostic_loop.record.desktop_changed = desktop_changed;
#endif
    if (desktop_changed) {
      ComPtr<ID3D11Texture2D> image;
#if defined(_DEBUG)
      diagnostic_loop.outcome = "desktop_resource_as_failed";
#endif
      hr = resource.As(&image);
      if (SUCCEEDED(hr)) {
        D3D11_TEXTURE2D_DESC desc{};
        image->GetDesc(&desc);
        if (!capture->desktop) {
          desc.Usage = D3D11_USAGE_DEFAULT;
          desc.BindFlags = 0;
          desc.CPUAccessFlags = 0;
          desc.MiscFlags = 0;
#if defined(_DEBUG)
          diagnostic_loop.outcome = "desktop_texture_create_failed";
#endif
          hr = capture->device->CreateTexture2D(&desc, nullptr, &capture->desktop);
        }
        if (SUCCEEDED(hr)) {
          capture->context->CopyResource(capture->desktop.Get(), image.Get());
        }
      }
    } else if (!acquired && hr != DXGI_ERROR_WAIT_TIMEOUT) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "acquire_failed";
      diagnostic_loop.record.error = static_cast<DWORD>(hr);
#endif
      SetError(hr);
      capture.reset();
      continue;
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kRelease);
#endif
    if (acquired) capture->duplication->ReleaseFrame();
    if (FAILED(hr) && hr != DXGI_ERROR_WAIT_TIMEOUT) {
#if defined(_DEBUG)
      diagnostic_loop.record.error = static_cast<DWORD>(hr);
#endif
      SetError(hr);
      continue;
    }
    if (!capture->desktop) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "no_desktop_texture";
#endif
      continue;
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kClientRect);
#endif
    RECT window_rect{};
    if (!GetClientRect(window_, &window_rect)) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "client_rect_failed";
      diagnostic_loop.record.error = GetLastError();
#endif
      continue;
    }
    POINT origin{0, 0};
#if defined(_DEBUG)
    diagnostic_loop.Enter(kClientToScreen);
#endif
    if (synchronized_drag) {
      origin = {drag_target.left, drag_target.top};
    } else if (!ClientToScreen(window_, &origin)) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "client_to_screen_failed";
      diagnostic_loop.record.error = GetLastError();
#endif
      continue;
    }
    OffsetRect(&window_rect, origin.x, origin.y);
#if defined(_DEBUG)
    const auto position_sampled_at = std::chrono::steady_clock::now();
    diagnostic_loop.Enter(kReadbackPrepare);
    diagnostic_loop.record.sampled = true;
    diagnostic_loop.record.rect = window_rect;
    diagnostic_loop.record.previous = diagnostic_previous_sample;
    diagnostic_loop.record.had_previous = diagnostic_had_sample;
    diagnostic_loop.record.sample_offset_ms = std::chrono::duration<double, std::milli>(
        position_sampled_at - diagnostic_loop.started).count();
    if (diagnostic_had_publication) {
      diagnostic_loop.record.since_publish_ms = std::chrono::duration<double, std::milli>(
          position_sampled_at - diagnostic_published_at).count();
    }
    diagnostic_loop.record.outer_valid = GetWindowRect(window_, &diagnostic_loop.record.outer) != 0;
    diagnostic_loop.record.cursor_valid = GetCursorPos(&diagnostic_loop.record.cursor) != 0;
    diagnostic_previous_sample = window_rect;
    diagnostic_had_sample = true;
    diagnostic_loop.moving = !EqualRect(&window_rect, &previous_rect);
    if (!EqualRect(&window_rect, &previous_rect)) {
      std::lock_guard<std::mutex> lock(state_->mutex);
      ++state_->diagnostic_moves;
    }
#endif
    if (!synchronized_drag && !desktop_changed && EqualRect(&window_rect, &previous_rect)) {
#if defined(_DEBUG)
      diagnostic_loop.unchanged = true;
      diagnostic_loop.outcome = "unchanged";
#endif
      continue;
    }
    const int width = window_rect.right - window_rect.left;
    const int height = window_rect.bottom - window_rect.top;
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "invalid_client_size";
#endif
      continue;
    }
    RECT rect = window_rect;
    InflateRect(&rect, kCapturePadding, kCapturePadding);
    RECT visible{};
    if (!IntersectRect(&visible, &rect, &capture->output.DesktopCoordinates)) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "outside_capture_monitor";
#endif
      continue;
    }
    D3D11_TEXTURE2D_DESC desktop_desc{};
    capture->desktop->GetDesc(&desktop_desc);
    const int left = visible.left - capture->output.DesktopCoordinates.left;
    const int top = visible.top - capture->output.DesktopCoordinates.top;
    const int right = visible.right - capture->output.DesktopCoordinates.left - 1;
    const int bottom = visible.bottom - capture->output.DesktopCoordinates.top - 1;
    const POINT first = capture->SourcePoint(left, top, desktop_desc);
    const POINT last = capture->SourcePoint(right, bottom, desktop_desc);
    D3D11_BOX box{};
    box.left = static_cast<UINT>(std::min(first.x, last.x));
    box.top = static_cast<UINT>(std::min(first.y, last.y));
    box.right = static_cast<UINT>(std::max(first.x, last.x) + 1);
    box.bottom = static_cast<UINT>(std::max(first.y, last.y) + 1);
    box.back = 1;
    if (box.right > desktop_desc.Width || box.bottom > desktop_desc.Height) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "copy_box_out_of_bounds";
#endif
      continue;
    }
    const UINT crop_width = box.right - box.left;
    const UINT crop_height = box.bottom - box.top;
    if (!capture->staging || capture->crop_width != crop_width ||
        capture->crop_height != crop_height) {
      capture->staging.Reset();
      D3D11_TEXTURE2D_DESC desc{};
      desc.Width = crop_width;
      desc.Height = crop_height;
      desc.MipLevels = desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      hr = capture->device->CreateTexture2D(&desc, nullptr, &capture->staging);
      if (FAILED(hr)) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "staging_create_failed";
        diagnostic_loop.record.error = static_cast<DWORD>(hr);
#endif
        SetError(hr);
        continue;
      }
      capture->crop_width = crop_width;
      capture->crop_height = crop_height;
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kGpuCopy);
#endif
    capture->context->CopySubresourceRegion(capture->staging.Get(), 0, 0, 0, 0,
        capture->desktop.Get(), 0, &box);
    D3D11_MAPPED_SUBRESOURCE mapped{};
#if defined(_DEBUG)
    diagnostic_loop.Enter(kMap);
#endif
    hr = capture->context->Map(capture->staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = "map_failed";
      diagnostic_loop.record.error = static_cast<DWORD>(hr);
#endif
      SetError(hr);
      continue;
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kConvert);
#endif
    auto frame = std::make_shared<Frame>();
    frame->width = static_cast<size_t>(rect.right - rect.left);
    frame->height = static_cast<size_t>(rect.bottom - rect.top);
    frame->source_rect = rect;
    frame->window_rect = window_rect;
    frame->monitor = capture->monitor;
#if defined(_DEBUG)
    frame->position_sampled_at = position_sampled_at;
#endif
    frame->rgba.resize(frame->width * frame->height * 4);
    uint64_t hash = 1469598103934665603ULL;
    double luminance = 0;
    size_t samples = 0;
    for (int y = visible.top; y < visible.bottom; ++y) {
      if (capture->output.Rotation == DXGI_MODE_ROTATION_IDENTITY ||
          capture->output.Rotation == DXGI_MODE_ROTATION_UNSPECIFIED) {
        const auto* source = reinterpret_cast<const uint32_t*>(
            static_cast<const uint8_t*>(mapped.pData) +
            (y - visible.top) * mapped.RowPitch);
        auto* target = reinterpret_cast<uint32_t*>(frame->rgba.data() +
            ((y - rect.top) * frame->width + (visible.left - rect.left)) * 4);
        const int row_width = visible.right - visible.left;
        int pixel_x = 0;
#if defined(_M_X64)
        const __m128i byte_mask = _mm_set1_epi32(0xff);
        const __m128i green_mask = _mm_set1_epi32(0x0000ff00);
        const __m128i alpha = _mm_set1_epi32(static_cast<int>(0xff000000u));
        for (; pixel_x + 4 <= row_width; pixel_x += 4) {
          const __m128i pixels = _mm_loadu_si128(
              reinterpret_cast<const __m128i*>(source + pixel_x));
          const __m128i red = _mm_and_si128(_mm_srli_epi32(pixels, 16), byte_mask);
          const __m128i blue = _mm_slli_epi32(_mm_and_si128(pixels, byte_mask), 16);
          const __m128i green = _mm_and_si128(pixels, green_mask);
          _mm_storeu_si128(reinterpret_cast<__m128i*>(target + pixel_x),
              _mm_or_si128(alpha, _mm_or_si128(green, _mm_or_si128(red, blue))));
        }
#endif
        for (; pixel_x < row_width; ++pixel_x) {
          const uint32_t color = source[pixel_x];
          target[pixel_x] = 0xff000000 | (color & 0x0000ff00) |
                      ((color & 0x00ff0000) >> 16) | ((color & 0xff) << 16);
        }
        if ((y & 31) == 0 && y >= window_rect.top && y < window_rect.bottom) {
          const int sample_left = std::max(visible.left, window_rect.left);
          const int sample_right = std::min(visible.right, window_rect.right);
          for (int x = sample_left - visible.left;
               x < sample_right - visible.left; x += 32) {
            const uint32_t color = source[x];
            hash = (hash ^ color) * 1099511628211ULL;
            luminance += (0.2126 * ((color >> 16) & 255) +
                          0.7152 * ((color >> 8) & 255) + 0.0722 * (color & 255)) / 255;
            ++samples;
          }
        }
        continue;
      }
      for (int x = visible.left; x < visible.right; ++x) {
        const POINT source = capture->SourcePoint(
            x - capture->output.DesktopCoordinates.left,
            y - capture->output.DesktopCoordinates.top, desktop_desc);
        const auto* pixel = static_cast<const uint8_t*>(mapped.pData) +
            (source.y - box.top) * mapped.RowPitch + (source.x - box.left) * 4;
        auto* target = frame->rgba.data() +
            ((y - rect.top) * frame->width + (x - rect.left)) * 4;
        target[0] = pixel[2]; target[1] = pixel[1];
        target[2] = pixel[0]; target[3] = 255;
        if ((x & 31) == 0 && (y & 31) == 0 &&
            x >= window_rect.left && x < window_rect.right &&
            y >= window_rect.top && y < window_rect.bottom) {
          hash = (hash ^ (pixel[0] | (pixel[1] << 8) | (pixel[2] << 16))) * 1099511628211ULL;
          luminance += (0.2126 * pixel[2] + 0.7152 * pixel[1] + 0.0722 * pixel[0]) / 255;
          ++samples;
        }
      }
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kUnmap);
#endif
    capture->context->Unmap(capture->staging.Get(), 0);
#if defined(_DEBUG)
    diagnostic_loop.Enter(kValidate);
#endif
    RECT current_rect{};
    const BOOL current_rect_valid = GetClientRect(window_, &current_rect);
#if defined(_DEBUG)
    diagnostic_loop.record.validated = current_rect_valid != 0;
    diagnostic_loop.record.validation = current_rect;
    if (!current_rect_valid) diagnostic_loop.record.error = GetLastError();
#endif
    if (!current_rect_valid ||
        current_rect.right != width || current_rect.bottom != height ||
        (synchronized_drag
            ? MonitorFromRect(&window_rect, MONITOR_DEFAULTTONEAREST)
            : MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST)) != capture->monitor) {
#if defined(_DEBUG)
      diagnostic_loop.outcome = !current_rect_valid ? "validation_client_rect_failed" :
          (current_rect.right != width || current_rect.bottom != height) ?
          "size_changed_during_capture" : "monitor_changed_during_capture";
#endif
      continue;
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kPublish);
#endif
    bool notify;
    UINT_PTR sync_token = 0;
    {
      // GPU commands/readback are complete before taking the UI-visible lock.
      std::lock_guard<std::mutex> lock(state_->mutex);
      if (!running_) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "publish_stopped";
#endif
        continue;
      }
      if (paused_) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "publish_paused";
#endif
        continue;
      }
      if (epoch != state_->recovery_epoch) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "publish_epoch_changed";
#endif
        continue;
      }
      if (drag_serial != state_->drag_serial) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "drag_session_changed";
#endif
        continue;
      }
      if (!IsWindowVisible(window_)) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "publish_hidden";
#endif
        continue;
      }
      if (IsIconic(window_)) {
#if defined(_DEBUG)
        diagnostic_loop.outcome = "publish_minimized";
#endif
        continue;
      }
      notify = synchronized_drag || !state_->frame || state_->frame->width != frame->width ||
          state_->frame->height != frame->height ||
          !EqualRect(&state_->frame->source_rect, &frame->source_rect) ||
          state_->frame->rgba != frame->rgba;
      if (notify) {
        if (synchronized_drag) {
          sync_token = ++next_sync_token;
          frame->sync_token = sync_token;
          state_->pending_token = sync_token;
          state_->consumed_token = 0;
        }
        state_->frame = std::move(frame);
      }
#if defined(_DEBUG)
      if (notify) {
        const auto published_at = std::chrono::steady_clock::now();
        if (diagnostic_published_at != std::chrono::steady_clock::time_point{}) {
          const double gap_ms = std::chrono::duration<double, std::milli>(
              published_at - diagnostic_published_at).count();
          diagnostic_publish_gap_max_ms = std::max(diagnostic_publish_gap_max_ms, gap_ms);
          if (!EqualRect(&window_rect, &previous_rect)) {
            diagnostic_moving_publish_gap_max_ms =
                std::max(diagnostic_moving_publish_gap_max_ms, gap_ms);
          }
        }
        diagnostic_published_at = published_at;
        diagnostic_published_rect = window_rect;
        diagnostic_had_publication = true;
        ++diagnostic_publications;
      }
#endif
      if (samples > 0) state_->luminance = luminance / samples;
      if (hash != previous_hash) state_->changes.fetch_add(1);
      previous_hash = hash;
      state_->capture_state = "live";
      state_->last_frame = std::chrono::steady_clock::now();
      state_->error.clear();
    }
#if defined(_DEBUG)
    diagnostic_loop.Enter(kNotify);
#endif
    previous_rect = window_rect;
    state_->frames.fetch_add(1);
    if (sync_token != 0) {
      PostMessageW(window_, glassusage_frame_sync::Ready(), sync_token, 0);
#if defined(_DEBUG)
      if (LagProbeEnabled()) {
        ProbeLine("probe_sync_ready token=%llu qpc=%lld rect=%ld,%ld",
            static_cast<unsigned long long>(sync_token), ProbeQpc(),
            window_rect.left, window_rect.top);
      }
#endif
    } else if (notify) {
      registrar_->MarkTextureFrameAvailable(texture_id_);
    }
#if defined(_DEBUG)
    if (notify && LagProbeEnabled()) {
      ProbeLine("probe_notify qpc=%lld rect=%ld,%ld", ProbeQpc(),
          window_rect.left, window_rect.top);
    }
    diagnostic_loop.Enter(kFinish);
    diagnostic_loop.outcome = notify ? "published" : "deduplicated";
#endif
  }
  capture.reset();
#if defined(_DEBUG)
  flush_diagnostic_records();
  flush_probe_lines();
  if (latency_log) std::fclose(latency_log);
#endif
  CoUninitialize();
}
