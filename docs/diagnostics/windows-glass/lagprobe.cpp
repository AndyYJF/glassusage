// Standalone readback tool for the GlassUsage lag probe (diagnostic only).
// Reads every composed desktop frame through its own Desktop Duplication and
// writes run-length classified pixel rows crossing the probed window, with the
// frame's DWM present time (QPC). Usage: lagprobe <hwnd> <out.log> <seconds>
#define NOMINMAX
#include <d3d11.h>
#include <dxgi1_2.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>

using Microsoft::WRL::ComPtr;

static long long Qpc() {
  LARGE_INTEGER value;
  QueryPerformanceCounter(&value);
  return value.QuadPart;
}

int main(int argc, char** argv) {
  if (argc < 4) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(_strtoi64(argv[1], nullptr, 10)));
  FILE* out = std::fopen(argv[2], "w");
  if (!out || !IsWindow(window)) return 3;
  static char file_buffer[1 << 20];
  std::setvbuf(out, file_buffer, _IOFBF, sizeof(file_buffer));
  const double seconds = std::atof(argv[3]);
  LARGE_INTEGER frequency;
  QueryPerformanceFrequency(&frequency);
  const double kRows[] = {0.12, 0.25, 0.40, 0.60, 0.75, 0.90};
  const UINT kRowCount = 6;

  const HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  ComPtr<IDXGIFactory1> factory;
  if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return 4;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutputDuplication> duplication;
  DXGI_OUTPUT_DESC output{};
  for (UINT a = 0; !duplication; ++a) {
    ComPtr<IDXGIAdapter1> adapter;
    if (factory->EnumAdapters1(a, &adapter) == DXGI_ERROR_NOT_FOUND) break;
    for (UINT o = 0;; ++o) {
      ComPtr<IDXGIOutput> candidate;
      if (adapter->EnumOutputs(o, &candidate) == DXGI_ERROR_NOT_FOUND) break;
      candidate->GetDesc(&output);
      if (output.Monitor != monitor) continue;
      HRESULT hr = D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
          D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
          &device, nullptr, &context);
      if (FAILED(hr)) return 5;
      ComPtr<IDXGIOutput1> output1;
      candidate.As(&output1);
      hr = output1->DuplicateOutput(device.Get(), &duplication);
      if (FAILED(hr)) {
        std::fprintf(out, "probe_error stage=duplicate hr=0x%08lX\n", static_cast<unsigned long>(hr));
        std::fclose(out);
        return 6;
      }
      break;
    }
  }
  if (!duplication) return 7;
  std::fprintf(out, "probe_tool_start qpc=%lld freq=%lld tick_ms=%llu output=%ld,%ld,%ld,%ld rotation=%d\n",
      Qpc(), frequency.QuadPart, static_cast<unsigned long long>(GetTickCount64()),
      output.DesktopCoordinates.left, output.DesktopCoordinates.top,
      output.DesktopCoordinates.right, output.DesktopCoordinates.bottom,
      static_cast<int>(output.Rotation));

  ComPtr<ID3D11Texture2D> staging;
  UINT staging_width = 0;
  const long long end = Qpc() + static_cast<long long>(seconds * frequency.QuadPart);
  unsigned long long frames = 0, missed = 0;
  while (Qpc() < end) {
    DXGI_OUTDUPL_FRAME_INFO info{};
    ComPtr<IDXGIResource> resource;
    HRESULT hr = duplication->AcquireNextFrame(100, &info, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) continue;
    if (FAILED(hr)) {
      std::fprintf(out, "probe_error stage=acquire hr=0x%08lX\n", static_cast<unsigned long>(hr));
      break;
    }
    const long long acquired_qpc = Qpc();
    ComPtr<ID3D11Texture2D> image;
    RECT window_rect{};
    if (info.LastPresentTime.QuadPart != 0 && SUCCEEDED(resource.As(&image)) &&
        GetWindowRect(window, &window_rect)) {
      ++frames;
      if (info.AccumulatedFrames > 1) missed += info.AccumulatedFrames - 1;
      D3D11_TEXTURE2D_DESC desc{};
      image->GetDesc(&desc);
      if (!staging || staging_width != desc.Width) {
        D3D11_TEXTURE2D_DESC staging_desc{};
        staging_desc.Width = desc.Width;
        staging_desc.Height = kRowCount;
        staging_desc.MipLevels = staging_desc.ArraySize = 1;
        staging_desc.Format = desc.Format;
        staging_desc.SampleDesc.Count = 1;
        staging_desc.Usage = D3D11_USAGE_STAGING;
        staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        staging.Reset();
        device->CreateTexture2D(&staging_desc, nullptr, &staging);
        staging_width = desc.Width;
      }
      const int height = window_rect.bottom - window_rect.top;
      int rows[6];
      bool any = false;
      for (UINT k = 0; k < kRowCount; ++k) {
        rows[k] = window_rect.top + static_cast<int>(height * kRows[k]) -
            output.DesktopCoordinates.top;
#ifdef NATIVE_REFRACTION
        // Host y50 + two narrow native position/sequence tags, clear of Flutter.
        rows[k]=window_rect.top+(k==0?160:k==1?172:static_cast<int>(height*kRows[k]))-
            output.DesktopCoordinates.top;
#endif
        if (!staging || rows[k] < 0 || rows[k] >= static_cast<int>(desc.Height)) {
          rows[k] = -1;
          continue;
        }
        D3D11_BOX box{0, static_cast<UINT>(rows[k]), 0, desc.Width,
                      static_cast<UINT>(rows[k]) + 1, 1};
        context->CopySubresourceRegion(staging.Get(), 0, 0, k, 0, image.Get(), 0, &box);
        any = true;
      }
      D3D11_MAPPED_SUBRESOURCE mapped{};
      if (any && SUCCEEDED(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) {
        const int output_left = output.DesktopCoordinates.left;
#if defined(BRIDGE_RGB) || defined(NATIVE_REFRACTION)
        const int first = std::max(0, static_cast<int>(window_rect.left) - output_left);
        const int last = std::min(static_cast<int>(desc.Width),
            static_cast<int>(window_rect.right) - output_left);
#else
        const int first = std::max(0, static_cast<int>(window_rect.left) - output_left - 400);
        const int last = std::min(static_cast<int>(desc.Width),
            static_cast<int>(window_rect.right) - output_left + 400);
#endif
        std::fprintf(out,
            "probe_cap qpc=%lld last_present=%lld accumulated=%u rect=%ld,%ld,%ld,%ld x0=%d",
            acquired_qpc, info.LastPresentTime.QuadPart, info.AccumulatedFrames,
            window_rect.left, window_rect.top, window_rect.right, window_rect.bottom,
            first + output_left);
        for (UINT k = 0; k < kRowCount; ++k) {
          std::string row;
          if (rows[k] < 0) {
            std::fprintf(out, " r%u=-", k);
            continue;
          }
          const auto* pixel = static_cast<const uint8_t*>(mapped.pData) +
              k * mapped.RowPitch + static_cast<size_t>(first) * 4;
          char current = 0;
          int run = 0;
          for (int x = first; x < last; ++x, pixel += 4) {
            const int b = pixel[0], g = pixel[1], r = pixel[2];
            const char kind = (g > 140 && r < 110 && b < 110) ? 'G' :
                (r > 140 && b > 140 && g < 110) ? 'M' : 'o';
            if (kind != current) {
              if (run) { row += current; row += std::to_string(run); }
              current = kind;
              run = 0;
            }
            ++run;
          }
          if (run) { row += current; row += std::to_string(run); }
          if (row.size() > 1200) row.resize(1200);
          std::fprintf(out, " r%u=%s", k, row.c_str());
#if defined(BRIDGE_RGB)
          // Only the bounded diagnostic host, encoded color runs, no images.
          std::string colors;
          unsigned previous = 0;
          int color_run = 0;
          pixel = static_cast<const uint8_t*>(mapped.pData) +
              k * mapped.RowPitch + static_cast<size_t>(first) * 4;
          const auto append_color = [&] {
            char text[32];
            std::snprintf(text, sizeof(text), "%06X:%d,", previous, color_run);
            colors += text;
          };
          for (int x = first; x < last; ++x, pixel += 4) {
            const unsigned color = (pixel[2] << 16) | (pixel[1] << 8) | pixel[0];
            if (color_run && color != previous) { append_color(); color_run = 0; }
            previous = color;
            ++color_run;
          }
          if (color_run) append_color();
          std::fprintf(out, " c%u=%s", k, colors.c_str());
#endif
        }
        std::fprintf(out, " done_qpc=%lld\n", Qpc());
        context->Unmap(staging.Get(), 0);
      }
    }
    duplication->ReleaseFrame();
  }
  std::fprintf(out, "probe_tool_end qpc=%lld frames=%llu missed=%llu\n", Qpc(), frames, missed);
  std::fclose(out);
  return 0;
}
