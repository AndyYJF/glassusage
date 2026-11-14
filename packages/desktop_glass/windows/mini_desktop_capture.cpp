#include "mini_desktop_capture.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstring>
#if defined(_M_X64)
#include <emmintrin.h>
#endif

using Microsoft::WRL::ComPtr;
namespace {
constexpr DWORD kExcludeFromCapture = 0x11;
bool SyntheticBackdrop() {
#if defined(_DEBUG)
  wchar_t value[8];
  return GetEnvironmentVariableW(L"GLASSUSAGE_LAG_PROBE", value, 8) > 0;
#else
  return false;
#endif
}
BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  reinterpret_cast<std::vector<HMONITOR>*>(data)->push_back(monitor);
  return TRUE;
}
}  // namespace

struct MiniDesktopCapture::CaptureDevice {
  HMONITOR monitor = nullptr;
  DXGI_OUTPUT_DESC output{};
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutputDuplication> duplication;
  ComPtr<ID3D11Texture2D> staging;
  std::vector<uint8_t> rgba;

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

  HRESULT Read(bool& changed) {
    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> resource;
    HRESULT hr = duplication->AcquireNextFrame(0, &info, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return S_OK;
    if (FAILED(hr)) return hr;
    if (!info.LastPresentTime.QuadPart && !rgba.empty()) {
      duplication->ReleaseFrame();
      return S_OK;
    }
    ComPtr<ID3D11Texture2D> image;
    hr = resource.As(&image);
    D3D11_TEXTURE2D_DESC desc{};
    if (SUCCEEDED(hr)) {
      image->GetDesc(&desc);
      if (!staging) {
        auto readback = desc;
        readback.Usage = D3D11_USAGE_STAGING;
        readback.BindFlags = readback.MiscFlags = 0;
        readback.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        hr = device->CreateTexture2D(&readback, nullptr, &staging);
      }
      if (SUCCEEDED(hr)) context->CopyResource(staging.Get(), image.Get());
    }
    duplication->ReleaseFrame();
    if (FAILED(hr)) return hr;
    D3D11_MAPPED_SUBRESOURCE mapped{};
    hr = context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) return hr;
    const int width = output.DesktopCoordinates.right - output.DesktopCoordinates.left;
    const int height = output.DesktopCoordinates.bottom - output.DesktopCoordinates.top;
    rgba.resize(static_cast<size_t>(width) * height * 4);
    for (int y = 0; y < height; ++y) {
      auto* dst = reinterpret_cast<uint32_t*>(rgba.data()) + static_cast<size_t>(y) * width;
      if (output.Rotation == DXGI_MODE_ROTATION_IDENTITY ||
          output.Rotation == DXGI_MODE_ROTATION_UNSPECIFIED) {
        const auto* src = reinterpret_cast<const uint32_t*>(
            static_cast<const uint8_t*>(mapped.pData) + y * mapped.RowPitch);
        int x = 0;
#if defined(_M_X64)
        const auto mask = _mm_set1_epi32(0x000000ff);
        const auto green = _mm_set1_epi32(0x0000ff00);
        const auto alpha = _mm_set1_epi32(static_cast<int>(0xff000000));
        for (; x + 4 <= width; x += 4) {
          const auto pixels = _mm_loadu_si128(reinterpret_cast<const __m128i*>(src + x));
          const auto converted = _mm_or_si128(alpha, _mm_or_si128(
              _mm_and_si128(pixels, green), _mm_or_si128(
              _mm_slli_epi32(_mm_and_si128(pixels, mask), 16),
              _mm_and_si128(_mm_srli_epi32(pixels, 16), mask))));
          _mm_storeu_si128(reinterpret_cast<__m128i*>(dst + x), converted);
        }
#endif
        for (; x < width; ++x) {
          const uint32_t p = src[x];
          dst[x] = 0xff000000 | (p & 0xff00) | ((p & 0xff) << 16) | ((p >> 16) & 0xff);
        }
      } else {
        for (int x = 0; x < width; ++x) {
          const POINT p = SourcePoint(x, y, desc);
          const auto* src = reinterpret_cast<const uint32_t*>(
              static_cast<const uint8_t*>(mapped.pData) + p.y * mapped.RowPitch);
          const uint32_t v = src[p.x];
          dst[x] = 0xff000000 | (v & 0xff00) | ((v & 0xff) << 16) | ((v >> 16) & 0xff);
        }
      }
    }
    context->Unmap(staging.Get(), 0);
    changed = true;
    return S_OK;
  }
};

MiniDesktopCapture::MiniDesktopCapture(HWND window,
    flutter::TextureRegistrar* registrar, int fps)
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
  if (!IsSupported()) return "Live backdrop requires Windows 10 2004 or later";
  GetWindowDisplayAffinity(window_, &previous_affinity_);
  if (!SyntheticBackdrop()) {
    if (!SetWindowDisplayAffinity(window_, kExcludeFromCapture))
      return "Cannot exclude mini host from capture: " + std::to_string(GetLastError());
    affinity_changed_ = true;
  }
  const auto state = state_;
  texture_ = std::make_shared<flutter::TextureVariant>(
      flutter::PixelBufferTexture([state](size_t, size_t) -> const FlutterDesktopPixelBuffer* {
        struct Lease {
          FlutterDesktopPixelBuffer buffer{};
          std::shared_ptr<Frame> frame;
        };
        auto lease = std::make_unique<Lease>();
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          lease->frame = state->frame;
        }
        if (!lease->frame) return nullptr;
        lease->buffer.buffer = lease->frame->rgba.data();
        lease->buffer.width = lease->frame->width;
        lease->buffer.height = lease->frame->height;
        lease->buffer.release_context = lease.get();
        lease->buffer.release_callback = [](void* context) { delete static_cast<Lease*>(context); };
        state->presented.fetch_add(1);
        return &lease.release()->buffer;
      }));
  texture_id_ = registrar_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    Stop();
    return "Cannot register desktop atlas texture";
  }
  started_ = std::chrono::steady_clock::now();
  running_ = true;
  thread_ = std::thread(&MiniDesktopCapture::Run, this);
  return {};
}

void MiniDesktopCapture::Stop() {
  running_ = false;
  wake_.notify_all();
  if (thread_.joinable()) thread_.join();
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->frame.reset();
  }
  if (texture_id_ >= 0) {
    const auto texture = texture_;
    registrar_->UnregisterTexture(texture_id_, [texture]() {});
    texture_id_ = -1;
  }
  texture_.reset();
  if (affinity_changed_ && IsWindow(window_))
    SetWindowDisplayAffinity(window_, previous_affinity_);
  affinity_changed_ = false;
}

void MiniDesktopCapture::SetPaused(bool paused) {
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (paused_.exchange(paused) == paused) return;
    state_->frame.reset();
    state_->error.clear();
    state_->waiting_since = std::chrono::steady_clock::now();
    ++state_->recovery_epoch;
  }
  wake_.notify_all();
}

void MiniDesktopCapture::SetError(HRESULT error) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  if (state_->frame) state_->waiting_since = std::chrono::steady_clock::now();
  state_->frame.reset();
  state_->error = "Desktop capture HRESULT " + std::to_string(static_cast<uint32_t>(error));
  ++state_->recovery_epoch;
}

flutter::EncodableMap MiniDesktopCapture::Stats() {
  using V = flutter::EncodableValue;
  const auto now = std::chrono::steady_clock::now();
  const bool paused = paused_ || !IsWindowVisible(window_) || IsIconic(window_);
  DWORD affinity = WDA_NONE;
  GetWindowDisplayAffinity(window_, &affinity);
  std::lock_guard<std::mutex> lock(state_->mutex);
  const bool valid = !paused && state_->frame != nullptr;
  // Stats and runner bounds updates run on the platform thread. Sample only
  // the actual card, not the full atlas, for foreground contrast selection.
  const auto* card = static_cast<const RECT*>(GetPropW(window_, L"GlassUsageMiniCardBounds"));
  if (valid && card) {
    const auto& frame = *state_->frame;
    double luminance = 0;
    size_t samples = 0;
    const int right = std::min(static_cast<int>(frame.width), static_cast<int>(card->right));
    const int bottom = std::min(static_cast<int>(frame.height), static_cast<int>(card->bottom));
    for (int y = std::max(0L, card->top); y < bottom; y += 16) {
      for (int x = std::max(0L, card->left); x < right; x += 16) {
        const auto* p = frame.rgba.data() + (static_cast<size_t>(y) * frame.width + x) * 4;
        luminance += (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255.0;
        ++samples;
      }
    }
    state_->luminance.store(samples ? luminance / samples : 0);
  }
  const bool failed = !paused && !valid && now - state_->waiting_since > std::chrono::seconds(5);
  flutter::EncodableMap result{
    {V("textureId"), V(texture_id_)},
    {V("frames"), V(static_cast<int64_t>(state_->frames.load()))},
    {V("presented"), V(static_cast<int64_t>(state_->presented.load()))},
    {V("changes"), V(static_cast<int64_t>(state_->frames.load()))},
    {V("elapsed"), V(std::chrono::duration<double>(now - started_).count())},
    {V("luminance"), V(state_->luminance.load())},
    {V("paused"), V(paused)},
    {V("hasValidFrame"), V(valid)},
    {V("captureState"), V(std::string(paused ? "paused" : valid ? "running" : failed ? "failed" : "waitingForFrame"))},
    {V("selfExcluded"), V(affinity == kExcludeFromCapture)},
    {V("recoveryEpoch"), V(static_cast<int64_t>(state_->recovery_epoch))},
    {V("error"), V(state_->error)},
  };
  if (state_->frame) {
    result[V("width")] = V(static_cast<int>(state_->frame->width));
    result[V("height")] = V(static_cast<int>(state_->frame->height));
    result[V("lastFrameAgeMs")] = V(std::chrono::duration<double, std::milli>(now - state_->last_frame).count());
  }
  return result;
}

void MiniDesktopCapture::Run() {
  std::vector<std::unique_ptr<CaptureDevice>> outputs;
  std::vector<HMONITOR> monitors;
  RECT previous_bounds{};
  uint64_t epoch = 0;
  bool inactive = false;
  const auto period = std::chrono::nanoseconds(1000000000 / fps_);
  auto deadline = std::chrono::steady_clock::now();
  auto topology_check = deadline;
  try {
    while (running_) {
      deadline += period;
      {
        std::unique_lock<std::mutex> lock(state_->mutex);
        wake_.wait_until(lock, deadline, [this] { return !running_ || paused_; });
        if (paused_ && running_) {
          outputs.clear();
          wake_.wait(lock, [this] { return !running_ || !paused_; });
        }
      }
      if (!running_) break;
      const auto now = std::chrono::steady_clock::now();
      if (now > deadline + period) deadline = now;
      if (!IsWindowVisible(window_) || IsIconic(window_)) {
        outputs.clear();
        if (!inactive) {
          std::lock_guard<std::mutex> lock(state_->mutex);
          state_->frame.reset();
          state_->waiting_since = now;
          ++state_->recovery_epoch;
        }
        inactive = true;
        continue;
      }
      RECT bounds{};
      POINT origin{};
      if (!GetClientRect(window_, &bounds) || !ClientToScreen(window_, &origin)) continue;
      OffsetRect(&bounds, origin.x, origin.y);
      const int width = bounds.right - bounds.left;
      const int height = bounds.bottom - bounds.top;
      if (width <= 0 || height <= 0 || static_cast<int64_t>(width) * height > 67108864) {
        SetError(E_INVALIDARG);
        continue;
      }
      uint64_t current_epoch;
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        current_epoch = state_->recovery_epoch;
      }
      if (now >= topology_check) {
        std::vector<HMONITOR> current;
        EnumDisplayMonitors(nullptr, nullptr, CollectMonitor, reinterpret_cast<LPARAM>(&current));
        if (current != monitors) {
          monitors = std::move(current);
          outputs.clear();
        }
        topology_check = now + std::chrono::seconds(1);
      }
      bool changed = inactive || !EqualRect(&previous_bounds, &bounds);
      inactive = false;
      HRESULT hr = S_OK;
      if (epoch != current_epoch) outputs.clear();
      epoch = current_epoch;
      if (outputs.empty()) {
        for (const auto monitor : monitors) {
          auto output = std::make_unique<CaptureDevice>();
          hr = output->Initialize(monitor);
          if (FAILED(hr)) break;
          outputs.push_back(std::move(output));
        }
        changed = true;
      }
      bool ready = !outputs.empty();
      if (SUCCEEDED(hr)) {
        for (auto& output : outputs) {
          hr = output->Read(changed);
          if (FAILED(hr)) break;
          ready = ready && !output->rgba.empty();
        }
      }
      if (FAILED(hr)) {
        SetError(hr);
        outputs.clear();
        std::unique_lock<std::mutex> lock(state_->mutex);
        wake_.wait_for(lock, std::chrono::milliseconds(250), [this] { return !running_ || paused_; });
        continue;
      }
      if (!changed || !ready) continue;
      auto frame = std::make_shared<Frame>();
      frame->width = width;
      frame->height = height;
      frame->bounds = bounds;
      frame->rgba.resize(static_cast<size_t>(width) * height * 4);
      for (const auto& output : outputs) {
        const RECT area = output->output.DesktopCoordinates;
        RECT visible{};
        if (!IntersectRect(&visible, &bounds, &area)) continue;
        const size_t output_width = area.right - area.left;
        for (LONG y = visible.top; y < visible.bottom; ++y) {
          const auto* src = output->rgba.data() +
              ((y - area.top) * output_width + visible.left - area.left) * 4;
          auto* dst = frame->rgba.data() +
              (static_cast<size_t>(y - bounds.top) * width + visible.left - bounds.left) * 4;
          std::memcpy(dst, src, static_cast<size_t>(visible.right - visible.left) * 4);
        }
      }
      if (SyntheticBackdrop()) {
        auto* pixels = reinterpret_cast<uint32_t*>(frame->rgba.data());
        for (int y = 0; y < height; ++y) {
          for (int x = 0; x < width; ++x) {
            const int absolute = x + bounds.left;
            const int phase = ((absolute % 512) + 512) % 512;
            pixels[static_cast<size_t>(y) * width + x] = phase < 64 ? 0xff00ff00 : 0xffff00ff;
          }
        }
      }
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        if (!running_ || paused_ || epoch != state_->recovery_epoch) continue;
        state_->frame = std::move(frame);
        state_->error.clear();
        state_->last_frame = now;
        state_->frames.fetch_add(1);
      }
      previous_bounds = bounds;
      registrar_->MarkTextureFrameAvailable(texture_id_);
    }
  } catch (const std::exception&) {
    SetError(E_OUTOFMEMORY);
  }
}
