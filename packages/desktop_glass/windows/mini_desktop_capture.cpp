#include "mini_desktop_capture.h"

#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstring>

using Microsoft::WRL::ComPtr;

namespace {
constexpr DWORD kExcludeFromCapture = 0x11;
}  // namespace

struct GlassCaptureDevice {
  std::mutex mutex;
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

struct GlassGpuFrame {
  ComPtr<ID3D11Texture2D> texture;
  FlutterDesktopGpuSurfaceDescriptor descriptor{};
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
  if (!SetWindowDisplayAffinity(window_, kExcludeFromCapture)) {
    return "Cannot exclude mini window from capture: " +
           std::to_string(GetLastError());
  }
  affinity_changed_ = true;
  const auto state = state_;
  texture_ = std::make_shared<flutter::TextureVariant>(
      flutter::GpuSurfaceTexture(kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
          [state, window = window_](size_t, size_t) {
            return RenderGpuFrame(state, window);
          }));
  texture_id_ = registrar_->RegisterTexture(texture_.get());
  if (texture_id_ < 0) {
    texture_.reset();
    SetWindowDisplayAffinity(window_, previous_affinity_);
    affinity_changed_ = false;
    return "Cannot register live desktop texture";
  }
  started_ = std::chrono::steady_clock::now();
  running_ = true;
  thread_ = std::thread(&MiniDesktopCapture::Run, this);
  return {};
}

void MiniDesktopCapture::Stop() {
  state_->active = false;
  running_ = false;
  if (thread_.joinable()) thread_.join();
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
  paused_ = paused;
  state_->paused = paused;
}

void MiniDesktopCapture::NotifyWindowMoved() {
  if (running_ && !paused_ && texture_id_ >= 0) {
    state_->last_move_us = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    registrar_->MarkTextureFrameAvailable(texture_id_);
  }
}

void MiniDesktopCapture::SetError(HRESULT error) {
  std::lock_guard<std::mutex> lock(state_->mutex);
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
  result[V("staleCropDrops")] = V(static_cast<int64_t>(state_->stale_crops.load()));
  result[V("elapsed")] = V(elapsed);
  result[V("luminance")] = V(state_->luminance.load());
  result[V("paused")] = V(paused_.load() || !IsWindowVisible(window_) || IsIconic(window_));
  DWORD affinity = WDA_NONE;
  GetWindowDisplayAffinity(window_, &affinity);
  result[V("selfExcluded")] = V(affinity == kExcludeFromCapture);
  std::lock_guard<std::mutex> lock(state_->mutex);
  result[V("error")] = V(state_->error);
  if (state_->gpu_frame) {
    result[V("width")] = V(static_cast<int>(state_->gpu_frame->descriptor.width));
    result[V("height")] = V(static_cast<int>(state_->gpu_frame->descriptor.height));
  }
  return result;
}

// Crop the latest desktop on the raster thread, using the window position at
// texture consumption time. The GPU surface stays alive until the next callback.
const FlutterDesktopGpuSurfaceDescriptor* MiniDesktopCapture::RenderGpuFrame(
    const std::shared_ptr<State>& state, HWND window) {
  for (int attempt = 0; attempt < 2; ++attempt) {
    if (!state->active || state->paused || !IsWindow(window)) return nullptr;
    std::shared_ptr<GlassCaptureDevice> device;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      device = state->capture;
    }
    if (!device) return nullptr;
    RECT rect{};
    POINT origin{0, 0};
    if (!GetClientRect(window, &rect) || !ClientToScreen(window, &origin)) return nullptr;
    OffsetRect(&rect, origin.x, origin.y);
    if (MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) != device->monitor) return nullptr;
    const int width = rect.right - rect.left;
    const int height = rect.bottom - rect.top;
    if (width <= 0 || height <= 0 || width > 2048 || height > 2048) return nullptr;
    const bool rotated = device->output.Rotation != DXGI_MODE_ROTATION_IDENTITY &&
                         device->output.Rotation != DXGI_MODE_ROTATION_UNSPECIFIED;
    // Rotated monitors retain the existing CPU conversion path.
    std::shared_ptr<Frame> rotated_frame;
    if (rotated) {
      rotated_frame = RenderFrame(state, window);
      if (!rotated_frame || rotated_frame->width != static_cast<size_t>(width) ||
          rotated_frame->height != static_cast<size_t>(height)) return nullptr;
      for (size_t i = 0; i < rotated_frame->rgba.size(); i += 4)
        std::swap(rotated_frame->rgba[i], rotated_frame->rgba[i + 2]);
    }
    auto frame = std::make_shared<GlassGpuFrame>();
    {

      std::lock_guard<std::mutex> gpu_lock(device->mutex);

      if (!device->desktop) return nullptr;
      D3D11_TEXTURE2D_DESC desc{};
      desc.Width = static_cast<UINT>(width);
      desc.Height = static_cast<UINT>(height);
      desc.MipLevels = desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_DEFAULT;
      desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
      desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

      HRESULT hr = device->device->CreateTexture2D(&desc, nullptr, &frame->texture);

      if (FAILED(hr)) {
        std::lock_guard<std::mutex> lock(state->mutex);
        state->error = "Cannot create shared desktop surface: " + std::to_string(static_cast<uint32_t>(hr));
        return nullptr;
      }
      ComPtr<IDXGIResource> resource;
      HANDLE handle = nullptr;
      hr = frame->texture.As(&resource);
      if (SUCCEEDED(hr)) hr = resource->GetSharedHandle(&handle);
      if (FAILED(hr) || !handle) return nullptr;
      frame->descriptor.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
      frame->descriptor.handle = handle;
      frame->descriptor.width = frame->descriptor.visible_width = width;
      frame->descriptor.height = frame->descriptor.visible_height = height;
      frame->descriptor.format = kFlutterDesktopPixelFormatBGRA8888;
      if (rotated) {
        device->context->UpdateSubresource(frame->texture.Get(), 0, nullptr,
            rotated_frame->rgba.data(), static_cast<UINT>(width * 4), 0);
      } else {
        RECT visible{};
        if (!IntersectRect(&visible, &rect, &device->output.DesktopCoordinates)) return nullptr;
        if (!EqualRect(&visible, &rect)) {
          ComPtr<ID3D11RenderTargetView> view;
          hr = device->device->CreateRenderTargetView(frame->texture.Get(), nullptr, &view);
          if (FAILED(hr)) return nullptr;
          const float transparent[] = {0, 0, 0, 0};
          device->context->ClearRenderTargetView(view.Get(), transparent);
        }
        D3D11_BOX box{};
        box.left = static_cast<UINT>(visible.left - device->output.DesktopCoordinates.left);
        box.top = static_cast<UINT>(visible.top - device->output.DesktopCoordinates.top);
        box.right = static_cast<UINT>(visible.right - device->output.DesktopCoordinates.left);
        box.bottom = static_cast<UINT>(visible.bottom - device->output.DesktopCoordinates.top);
        box.back = 1;
        device->context->CopySubresourceRegion(frame->texture.Get(), 0,
            visible.left - rect.left, visible.top - rect.top, 0,
            device->desktop.Get(), 0, &box);
      }
      device->context->Flush();

    }
    RECT current{};
    POINT current_origin{0, 0};
    if (!GetClientRect(window, &current) || !ClientToScreen(window, &current_origin)) return nullptr;
    OffsetRect(&current, current_origin.x, current_origin.y);
    if (MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) != device->monitor) return nullptr;
    if (!EqualRect(&rect, &current)) {
      state->stale_crops.fetch_add(1);
      if (attempt == 0) continue;
    }
    std::lock_guard<std::mutex> lock(state->mutex);
    if (!state->active || state->paused || state->capture != device) return nullptr;
    state->gpu_frame = frame;
    state->presented.fetch_add(1);

    return &state->gpu_frame->descriptor;
  }
  return nullptr;
}

std::shared_ptr<MiniDesktopCapture::Frame> MiniDesktopCapture::RenderFrame(
    const std::shared_ptr<State>& state, HWND window) {
  const auto set_error = [&state](HRESULT hr) {
    std::lock_guard<std::mutex> lock(state->mutex);
    state->error = "Desktop capture HRESULT " + std::to_string(static_cast<uint32_t>(hr));
  };
  const auto window_rect = [window](RECT* rect) {
    POINT origin{0, 0};
    if (!IsWindow(window) || !GetClientRect(window, rect) || !ClientToScreen(window, &origin)) return false;
    OffsetRect(rect, origin.x, origin.y);
    return true;
  };
  for (int attempt = 0; attempt < 2; ++attempt) {
    if (!state->active || state->paused) return nullptr;
    std::shared_ptr<GlassCaptureDevice> device;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      device = state->capture;
    }
    if (!device) return nullptr;
    RECT rect{};
    if (!window_rect(&rect) || MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) != device->monitor) return nullptr;
    std::unique_lock<std::mutex> gpu_lock(device->mutex);
    auto& capture = *device;
    if (!capture.desktop) return nullptr;
    HRESULT hr = S_OK;
    const int width = rect.right - rect.left;
    const int height = rect.bottom - rect.top;
    if (width <= 0 || height <= 0 || width > 2048 || height > 2048) return nullptr;
    RECT visible{};
    if (!IntersectRect(&visible, &rect, &capture.output.DesktopCoordinates)) return nullptr;
    D3D11_TEXTURE2D_DESC desktop_desc{};
    capture.desktop->GetDesc(&desktop_desc);
    const int left = visible.left - capture.output.DesktopCoordinates.left;
    const int top = visible.top - capture.output.DesktopCoordinates.top;
    const int right = visible.right - capture.output.DesktopCoordinates.left - 1;
    const int bottom = visible.bottom - capture.output.DesktopCoordinates.top - 1;
    const POINT first = capture.SourcePoint(left, top, desktop_desc);
    const POINT last = capture.SourcePoint(right, bottom, desktop_desc);
    D3D11_BOX box{};
    box.left = static_cast<UINT>(std::min(first.x, last.x));
    box.top = static_cast<UINT>(std::min(first.y, last.y));
    box.right = static_cast<UINT>(std::max(first.x, last.x) + 1);
    box.bottom = static_cast<UINT>(std::max(first.y, last.y) + 1);
    box.back = 1;
    if (box.right > desktop_desc.Width || box.bottom > desktop_desc.Height) return nullptr;
    const UINT crop_width = box.right - box.left;
    const UINT crop_height = box.bottom - box.top;
    if (capture.crop_width != crop_width || capture.crop_height != crop_height) {
      capture.staging.Reset();
      D3D11_TEXTURE2D_DESC desc{};
      desc.Width = crop_width;
      desc.Height = crop_height;
      desc.MipLevels = desc.ArraySize = 1;
      desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
      desc.SampleDesc.Count = 1;
      desc.Usage = D3D11_USAGE_STAGING;
      desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      hr = capture.device->CreateTexture2D(&desc, nullptr, &capture.staging);
      if (FAILED(hr)) { set_error(hr); return nullptr; }
      capture.crop_width = crop_width;
      capture.crop_height = crop_height;
    }
    capture.context->CopySubresourceRegion(capture.staging.Get(), 0, 0, 0, 0,
        capture.desktop.Get(), 0, &box);
    D3D11_MAPPED_SUBRESOURCE mapped{};
    hr = capture.context->Map(capture.staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) { set_error(hr); return nullptr; }
    auto frame = std::make_shared<Frame>();
    frame->width = static_cast<size_t>(width);
    frame->height = static_cast<size_t>(height);
    frame->rgba.resize(frame->width * frame->height * 4);
    uint64_t hash = 1469598103934665603ULL;
    double luminance = 0;
    size_t samples = 0;
    for (int y = visible.top; y < visible.bottom; ++y) {
      if (capture.output.Rotation == DXGI_MODE_ROTATION_IDENTITY ||
          capture.output.Rotation == DXGI_MODE_ROTATION_UNSPECIFIED) {
        const auto* source = reinterpret_cast<const uint32_t*>(
            static_cast<const uint8_t*>(mapped.pData) +
            (y - visible.top) * mapped.RowPitch);
        auto* target = reinterpret_cast<uint32_t*>(frame->rgba.data() +
            ((y - rect.top) * frame->width + (visible.left - rect.left)) * 4);
        for (int x = 0; x < visible.right - visible.left; ++x) {
          const uint32_t color = source[x];
          target[x] = 0xff000000 | (color & 0x0000ff00) |
                      ((color & 0x00ff0000) >> 16) | ((color & 0xff) << 16);
        }
        if ((y & 31) == 0) {
          for (int x = 0; x < visible.right - visible.left; x += 32) {
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
        const POINT source = capture.SourcePoint(
            x - capture.output.DesktopCoordinates.left,
            y - capture.output.DesktopCoordinates.top, desktop_desc);
        const auto* pixel = static_cast<const uint8_t*>(mapped.pData) +
            (source.y - box.top) * mapped.RowPitch + (source.x - box.left) * 4;
        auto* target = frame->rgba.data() +
            ((y - rect.top) * frame->width + (x - rect.left)) * 4;
        target[0] = pixel[2]; target[1] = pixel[1];
        target[2] = pixel[0]; target[3] = 255;
        if ((x & 31) == 0 && (y & 31) == 0) {
          hash = (hash ^ (pixel[0] | (pixel[1] << 8) | (pixel[2] << 16))) * 1099511628211ULL;
          luminance += (0.2126 * pixel[2] + 0.7152 * pixel[1] + 0.0722 * pixel[0]) / 255;
          ++samples;
        }
      }
    }
    capture.context->Unmap(capture.staging.Get(), 0);
    gpu_lock.unlock();
    RECT current{};
    if (!window_rect(&current) || !EqualRect(&rect, &current) ||
        MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST) != device->monitor) {
      state->stale_crops.fetch_add(1);
      continue;
    }
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->active || state->paused || state->capture.get() != device.get()) return nullptr;
      if (samples > 0) state->luminance = luminance / samples;
      if (hash != state->previous_hash) state->changes.fetch_add(1);
      state->previous_hash = hash;
      state->frame = frame;
      state->error.clear();
    }
    return frame;
  }
  return nullptr;
}

void MiniDesktopCapture::Run() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  std::shared_ptr<GlassCaptureDevice> capture;
  RECT previous_rect{};
  auto next_sample = std::chrono::steady_clock::now();
  const auto frame_period = std::chrono::nanoseconds(1000000000 / fps_);
  auto last_frame_notice = std::chrono::steady_clock::now() - frame_period;
  while (running_) {
    if (paused_ || !IsWindowVisible(window_) || IsIconic(window_)) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      continue;
    }
    const HMONITOR monitor = MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
    if (!capture || capture->monitor != monitor) {
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->capture.reset();
      }
      capture = std::make_shared<GlassCaptureDevice>();
      const HRESULT hr = capture->Initialize(monitor);
      if (FAILED(hr)) {
        SetError(hr);
        capture.reset();
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        continue;
      }
    }
    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> resource;

    HRESULT hr = capture->duplication->AcquireNextFrame(16, &info, &resource);
    bool changed = false;
    if (SUCCEEDED(hr)) {

      if (info.LastPresentTime.QuadPart != 0 || !capture->desktop) {
        ComPtr<ID3D11Texture2D> image;
        hr = resource.As(&image);
        if (SUCCEEDED(hr)) {
          std::lock_guard<std::mutex> lock(capture->mutex);
          D3D11_TEXTURE2D_DESC desc{};
          image->GetDesc(&desc);
          if (!capture->desktop) {
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = 0;
            desc.CPUAccessFlags = 0;
            desc.MiscFlags = 0;
            hr = capture->device->CreateTexture2D(&desc, nullptr, &capture->desktop);
          }
          if (SUCCEEDED(hr)) {
            capture->context->CopyResource(capture->desktop.Get(), image.Get());
            changed = true;
          }
        }
      }
      capture->duplication->ReleaseFrame();
    }
    if (FAILED(hr) && hr != DXGI_ERROR_WAIT_TIMEOUT) {
      SetError(hr);
      {
        std::lock_guard<std::mutex> lock(state_->mutex);
        state_->capture.reset();
      }
      capture.reset();
      continue;
    }
    if (!capture->desktop) continue;
    RECT rect{};
    POINT origin{0, 0};
    if (!GetClientRect(window_, &rect) || !ClientToScreen(window_, &origin)) continue;
    OffsetRect(&rect, origin.x, origin.y);
    const bool moved = !EqualRect(&rect, &previous_rect);
    previous_rect = rect;
    const auto now = std::chrono::steady_clock::now();
    if (!moved && (!changed || now - last_frame_notice < frame_period)) continue;
    last_frame_notice = now;
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->capture = capture;
      state_->error.clear();
    }
    state_->frames.fetch_add(1);
    registrar_->MarkTextureFrameAvailable(texture_id_);
    const auto now_us = std::chrono::duration_cast<std::chrono::microseconds>(
        now.time_since_epoch()).count();
    if (now >= next_sample && now_us - state_->last_move_us.load() > 200000) {
      next_sample = now + std::chrono::seconds(1);
      RenderFrame(state_, window_);
    }
  }
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->capture.reset();
  }
  capture.reset();
  CoUninitialize();
}
