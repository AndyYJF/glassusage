// Standalone diagnostic. Never loads, reparents or modifies GlassUsage.
#define NOMINMAX
#define UNICODE
#include <windows.h>
#include <d3d11.h>
#include <dcomp.h>
#include <wrl/client.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
constexpr int kHostWidth = 1280, kHostHeight = 520;
constexpr int kCardWidth = 648, kCardHeight = 400, kCardTop = 50;
constexpr uint32_t kGreen = 0xff00ff00, kMagenta = 0xffff00ff;

long long Qpc() {
  LARGE_INTEGER value;
  QueryPerformanceCounter(&value);
  return value.QuadPart;
}
void Check(HRESULT hr, const char* operation) {
  if (FAILED(hr)) {
    char message[180];
    std::snprintf(message, sizeof(message), "%s HRESULT=0x%08lX", operation,
                  static_cast<unsigned long>(hr));
    throw std::runtime_error(message);
  }
}
LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_CLOSE) { DestroyWindow(hwnd); return 0; }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(hwnd, message, wp, lp);
}

void UpdateSurface(IDCompositionSurface* surface, ID3D11DeviceContext* context,
                   const std::vector<uint32_t>& pixels, int width, int height) {
  ComPtr<IDXGISurface> update;
  POINT offset{};
  Check(surface->BeginDraw(nullptr, IID_PPV_ARGS(&update), &offset), "BeginDraw");
  try {
    ComPtr<ID3D11Texture2D> texture;
    Check(update.As(&texture), "surface texture");
    const D3D11_BOX box{static_cast<UINT>(offset.x), static_cast<UINT>(offset.y), 0,
        static_cast<UINT>(offset.x + width), static_cast<UINT>(offset.y + height), 1};
    context->UpdateSubresource(texture.Get(), 0, &box, pixels.data(), width * 4, 0);
    texture.Reset();
    update.Reset();
  } catch (...) {
    surface->EndDraw();
    throw;
  }
  Check(surface->EndDraw(), "EndDraw");
}

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (GetFileAttributesA(argv[1]) != INVALID_FILE_ATTRIBUTES) return 3;
  const double duration = std::stod(argv[2]);
  if (duration <= 0 || duration > 30) return 4;
  FILE* log = std::fopen(argv[1], "w");
  if (!log) return 5;
  HWND hwnd = nullptr;
  HANDLE start_event = nullptr;
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  int result = 0;
  try {
    WNDCLASSW wc{};
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = L"GlassUsageIndependentCompositionProbe";
    if (!RegisterClassW(&wc)) throw std::runtime_error("RegisterClass failed");
    hwnd = CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
        wc.lpszClassName, L"Native composition diagnostic (automatic)", WS_POPUP,
        120, 220, kHostWidth, kHostHeight, nullptr, nullptr, wc.hInstance, nullptr);
    if (!hwnd) throw std::runtime_error("CreateWindow failed");

    ComPtr<ID3D11Device> gpu;
    ComPtr<ID3D11DeviceContext> context;
    Check(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        &gpu, nullptr, &context), "D3D11CreateDevice");
    ComPtr<IDXGIDevice> dxgi;
    Check(gpu.As(&dxgi), "DXGI device");
    ComPtr<IDCompositionDevice> compositor;
    Check(DCompositionCreateDevice(dxgi.Get(), IID_PPV_ARGS(&compositor)), "DCompositionCreateDevice");
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> root, card;
    ComPtr<IDCompositionSurface> background, surface;
    Check(compositor->CreateTargetForHwnd(hwnd, TRUE, &target), "CreateTargetForHwnd");
    Check(compositor->CreateVisual(&root), "CreateVisual root");
    Check(compositor->CreateVisual(&card), "CreateVisual card");
    Check(compositor->CreateSurface(kHostWidth, kHostHeight,
        DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &background), "CreateSurface background");
    Check(compositor->CreateSurface(kCardWidth, kCardHeight,
        DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED, &surface), "CreateSurface card");
    UpdateSurface(background.Get(), context.Get(),
        std::vector<uint32_t>(kHostWidth * kHostHeight, 0xff202024), kHostWidth, kHostHeight);
    Check(root->SetContent(background.Get()), "root content");
    Check(card->SetContent(surface.Get()), "card content");
    Check(root->AddVisual(card.Get(), FALSE, nullptr), "AddVisual");
    Check(target->SetRoot(root.Get()), "SetRoot");

    const std::string event_name = "Local\\GlassUsageDCompProbe-" + std::to_string(GetCurrentProcessId());
    start_event = CreateEventA(nullptr, TRUE, FALSE, event_name.c_str());
    if (!start_event) throw std::runtime_error("CreateEvent failed");
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    RECT host{};
    GetWindowRect(hwnd, &host);
    std::fprintf(log, "probe_start qpc=%lld freq=%lld host=%ld,%ld,%ld,%ld width=%d source=dcomp_surface\n",
        Qpc(), frequency.QuadPart, host.left, host.top, host.right, host.bottom, kCardWidth);
    std::vector<uint32_t> pixels(kCardWidth * kCardHeight);
    unsigned long long sequence = 0;
    const auto draw = [&](int x) {
      const auto planned = Qpc();
      for (int column = 0; column < kCardWidth; ++column) {
        const int absolute = host.left + x + column;
        const uint32_t stripe = (absolute % 512) < 64 ? kGreen : kMagenta;
        const uint32_t code = ((sequence >> (column * 8 / kCardWidth)) & 1) ? kGreen : kMagenta;
        for (int y = 0; y < kCardHeight; ++y) {
          pixels[y * kCardWidth + column] = y < kCardHeight / 2 ? stripe : code;
        }
      }
      UpdateSurface(surface.Get(), context.Get(), pixels, kCardWidth, kCardHeight);
      Check(card->SetOffsetX(static_cast<float>(x)), "SetOffsetX");
      Check(card->SetOffsetY(static_cast<float>(kCardTop)), "SetOffsetY");
      // One device, one surface/offset batch; the host HWND never moves.
      Check(compositor->Commit(), "Commit");
      std::fprintf(log, "visual_frame seq=%llu qpc=%lld view=%ld,%ld,%ld,%ld submitted_qpc=%lld\n",
          sequence, planned, host.left + x, host.top + kCardTop,
          host.left + x + kCardWidth, host.top + kCardTop + kCardHeight, Qpc());
      ++sequence;
    };
    draw(32);
    std::fflush(log);
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    std::printf("{\"ready\":true,\"hwnd\":%llu,\"event\":\"Local\\\\GlassUsageDCompProbe-%lu\"}\n",
        static_cast<unsigned long long>(reinterpret_cast<UINT_PTR>(hwnd)), GetCurrentProcessId());
    std::fflush(stdout);
    auto created = std::chrono::steady_clock::now();
    auto started = created;
    bool running = false, quit = false;
    auto next_frame = created;
    while (!quit && IsWindow(hwnd)) {
      MSG msg{};
      while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) quit = true;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
      }
      if (quit || (GetAsyncKeyState(VK_ESCAPE) & 0x8000)) break;
      const auto now = std::chrono::steady_clock::now();
      if (!running) {
        if (WaitForSingleObject(start_event, 0) == WAIT_OBJECT_0) {
          running = true;
          started = next_frame = now;
          std::fprintf(log, "animation_start qpc=%lld\n", Qpc());
          std::fflush(log);
        } else if (std::chrono::duration<double>(now-created).count()>60) {
          throw std::runtime_error("Start signal timed out");
        }
      }
      if (running) {
        const double elapsed = std::chrono::duration<double>(now-started).count();
        if (elapsed>=duration) break;
        if (now>=next_frame) {
          const double period = elapsed<duration/2 ? 2.0 : .5;
          const double phase = (1-std::cos(elapsed*6.283185307179586/period))/2;
          draw(32+static_cast<int>(std::round(phase*(kHostWidth-kCardWidth-64))));
          next_frame = now+std::chrono::microseconds(16667);
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    std::fprintf(log, "probe_end qpc=%lld updates=%llu\n", Qpc(), sequence);
    std::printf("{\"complete\":true,\"updates\":%llu}\n", sequence);
    std::fflush(stdout);
  } catch (const std::exception& error) {
    std::fprintf(log, "probe_error message=%s\n", error.what());
    std::fprintf(stderr, "%s\n", error.what());
    result = 1;
  }
  if (hwnd && IsWindow(hwnd)) DestroyWindow(hwnd);
  if (start_event) CloseHandle(start_event);
  std::fclose(log);
  CoUninitialize();
  return result;
}
