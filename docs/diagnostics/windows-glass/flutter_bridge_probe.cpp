// Isolated Flutter/ANGLE -> layered HWND -> DirectComposition compatibility gate.
#define main unused_atomic_probe_main
#include "native_comp_probe.cpp"
#undef main
#include <flutter_windows.h>
#include <dwmapi.h>
#include <filesystem>
#ifdef NATIVE_REFRACTION
#include "native_refraction.h"
#endif

struct FlutterApi {
#define MEMBER(name) decltype(&FlutterDesktop##name) name = nullptr
  MEMBER(EngineCreate); MEMBER(ViewControllerCreate); MEMBER(ViewControllerDestroy);
  MEMBER(ViewControllerGetView); MEMBER(ViewGetHWND); MEMBER(EngineGetMessenger);
  MEMBER(MessengerSetCallback); MEMBER(MessengerSendResponse);
  MEMBER(ViewControllerForceRedraw); MEMBER(ViewControllerHandleTopLevelWindowProc);
#undef MEMBER
  void Load(HMODULE library) {
#define LOAD(name) name = reinterpret_cast<decltype(name)>(GetProcAddress(library, "FlutterDesktop" #name)); if (!name) throw std::runtime_error("Missing FlutterDesktop" #name)
    LOAD(EngineCreate); LOAD(ViewControllerCreate); LOAD(ViewControllerDestroy);
    LOAD(ViewControllerGetView); LOAD(ViewGetHWND); LOAD(EngineGetMessenger);
    LOAD(MessengerSetCallback); LOAD(MessengerSendResponse);
    LOAD(ViewControllerForceRedraw); LOAD(ViewControllerHandleTopLevelWindowProc);
#undef LOAD
  }
} api;
FlutterDesktopViewControllerRef controller = nullptr;
HWND flutter_child = nullptr;
FILE* bridge_log = nullptr;
int visual_x = 0, visual_y = 0;
std::vector<uint32_t> rgba_pixels;
unsigned rgba_version = 0;

void RgbaMessage(FlutterDesktopMessengerRef messenger,
                 const FlutterDesktopMessage* message, void*) {
  if (message->message_size == kCardWidth*kCardHeight*4) {
    rgba_pixels.resize(kCardWidth*kCardHeight);
    const auto* bytes=message->message;
    for (size_t i=0;i<rgba_pixels.size();++i) {
      rgba_pixels[i]=(uint32_t(bytes[i*4+3])<<24)|(uint32_t(bytes[i*4])<<16)|
          (uint32_t(bytes[i*4+1])<<8)|bytes[i*4+2];
    }
    ++rgba_version;
    std::fprintf(bridge_log,"rgba_receive qpc=%lld version=%u half=0x%08X clear=0x%08X\n",
        Qpc(),rgba_version,rgba_pixels[64*kCardWidth+256],rgba_pixels[64*kCardWidth+416]);
  }
  if (message->response_handle) api.MessengerSendResponse(messenger,message->response_handle,nullptr,0);
}

HWND CreateAlphaControl(HWND parent) {
  HWND child=CreateWindowExW(WS_EX_LAYERED,L"STATIC",L"Known per-pixel alpha control",
      WS_CHILD|WS_VISIBLE,0,0,kCardWidth,kCardHeight,parent,nullptr,GetModuleHandleW(nullptr),nullptr);
  if (!child) throw std::runtime_error("Create alpha control failed");
  BITMAPINFO info{};
  info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth=kCardWidth;info.bmiHeader.biHeight=-kCardHeight;
  info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
  HDC screen=GetDC(nullptr),memory=CreateCompatibleDC(screen);
  void* data=nullptr;
  HBITMAP bitmap=CreateDIBSection(screen,&info,DIB_RGB_COLORS,&data,nullptr,0);
  if (!bitmap || !memory) throw std::runtime_error("Create alpha DIB failed");
  auto* pixels=static_cast<uint32_t*>(data);
  for (int y=0;y<kCardHeight;++y) for (int x=0;x<kCardWidth;++x) {
    uint32_t color=0;
    if (y>=32 && y<96 && x>=32 && x<160) color=0xffff0000;
    if (y>=32 && y<96 && x>=192 && x<320) color=0x80800000;
    if (y>=200) color=((197>>(x*8/kCardWidth))&1)?kGreen:kMagenta;
    pixels[y*kCardWidth+x]=color;
  }
  HGDIOBJ previous=SelectObject(memory,bitmap);
  SIZE size{kCardWidth,kCardHeight};POINT source{};
  BLENDFUNCTION blend{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
  const BOOL updated=UpdateLayeredWindow(child,screen,nullptr,&size,memory,&source,0,&blend,ULW_ALPHA);
  const DWORD error=updated?0:GetLastError();
  SelectObject(memory,previous);DeleteObject(bitmap);DeleteDC(memory);ReleaseDC(nullptr,screen);
  std::fprintf(bridge_log,"alpha_control_upload qpc=%lld updated=%d error=%lu code=197\n",Qpc(),updated,error);
  if (!updated) throw std::runtime_error("UpdateLayeredWindow control failed");
  return child;
}

void FixtureMessage(FlutterDesktopMessengerRef messenger,
                    const FlutterDesktopMessage* message, void*) {
  std::fprintf(bridge_log, "dart_event qpc=%lld json=%.*s\n", Qpc(),
      static_cast<int>(message->message_size), reinterpret_cast<const char*>(message->message));
  if (message->response_handle) api.MessengerSendResponse(messenger, message->response_handle, nullptr, 0);
}
void RouteClick(int x, int y) {
  const int local_x = x-visual_x, local_y = y-visual_y;
  if (!flutter_child || local_x<0 || local_y<0 || local_x>=kCardWidth || local_y>=kCardHeight) return;
  std::fprintf(bridge_log, "route_click qpc=%lld host=%d,%d source=%d,%d\n",
      Qpc(),x,y,local_x,local_y);
  const LPARAM point = MAKELPARAM(local_x,local_y);
  // Only this fixture's own HWND receives messages; no global mouse input.
  SendMessageW(flutter_child,WM_MOUSEMOVE,0,point);
  SendMessageW(flutter_child,WM_LBUTTONDOWN,MK_LBUTTON,point);
  SendMessageW(flutter_child,WM_LBUTTONUP,0,point);
}
LRESULT CALLBACK BridgeWindowProc(HWND hwnd,UINT message,WPARAM wp,LPARAM lp) {
  if (message==WM_LBUTTONDOWN && visual_y==kCardTop) {
    RouteClick(static_cast<short>(LOWORD(lp)),static_cast<short>(HIWORD(lp)));
    return 0;
  }
  if (controller) {
    LRESULT result;
    if (api.ViewControllerHandleTopLevelWindowProc(controller,hwnd,message,wp,lp,&result)) return result;
  }
  return WindowProc(hwnd,message,wp,lp);
}

int main(int argc,char** argv) {
  if (argc!=4) return 2;
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (GetFileAttributesA(argv[1])!=INVALID_FILE_ATTRIBUTES) return 3;
  const double duration=std::stod(argv[3]);
  if (duration<=5 || duration>30) return 4;
  bridge_log=std::fopen(argv[1],"w");
  if (!bridge_log) return 5;
  CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
  HWND host=nullptr;
  HANDLE start_event=nullptr;
  HMODULE library=nullptr;
  HANDLE pacing_timer=nullptr;
  HWND controlled_desktop=nullptr;
  int result=0;
  try {
    WNDCLASSW wc{};
    wc.lpfnWndProc=BridgeWindowProc;
    wc.hInstance=GetModuleHandleW(nullptr);
    wc.hCursor=LoadCursorW(nullptr,IDC_ARROW);
    wc.lpszClassName=L"GlassUsageIsolatedFlutterBridgeProbe";
    if (!RegisterClassW(&wc)) throw std::runtime_error("RegisterClass failed");
    host=CreateWindowExW(WS_EX_NOREDIRECTIONBITMAP|WS_EX_TOPMOST|WS_EX_TOOLWINDOW,
        wc.lpszClassName,L"Isolated Flutter composition bridge",WS_POPUP,
        120,220,kHostWidth,kHostHeight,nullptr,nullptr,wc.hInstance,nullptr);
    if (!host) throw std::runtime_error("CreateWindow failed");

    library=LoadLibraryExW(L"C:/Users/AndyYan/Desktop/codex/glassusage/build/windows/x64/runner/Debug/flutter_windows.dll",
        nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!library) throw std::runtime_error("Load existing Flutter engine failed");
    api.Load(library);
    const std::wstring assets=std::filesystem::path(argv[2]).wstring();
    FlutterDesktopEngineProperties properties{};
    properties.assets_path=assets.c_str();
    properties.icu_data_path=L"C:/Users/AndyYan/AGV/flutter-sdk/bin/cache/artifacts/engine/windows-x64/icudtl.dat";
    properties.ui_thread_policy=RunOnPlatformThread;
    auto engine=api.EngineCreate(&properties);
    if (!engine) throw std::runtime_error("EngineCreate failed");
    controller=api.ViewControllerCreate(kCardWidth,kCardHeight,engine);
    if (!controller) throw std::runtime_error("ViewControllerCreate failed");
    flutter_child=api.ViewGetHWND(api.ViewControllerGetView(controller));
    SetLastError(0);
    const HWND previous_parent=SetParent(flutter_child,host);
    const DWORD parent_error=GetLastError();
    std::fprintf(bridge_log,"source_parent qpc=%lld hwnd=%llu previous=%llu parent=%llu error=%lu\n",Qpc(),
        reinterpret_cast<UINT_PTR>(flutter_child),reinterpret_cast<UINT_PTR>(previous_parent),
        reinterpret_cast<UINT_PTR>(GetParent(flutter_child)),parent_error);
    SetWindowPos(flutter_child,nullptr,0,0,kCardWidth,kCardHeight,SWP_NOZORDER|SWP_NOACTIVATE|SWP_SHOWWINDOW);
    api.MessengerSetCallback(api.EngineGetMessenger(engine),"fixture/event",FixtureMessage,nullptr);
    api.MessengerSetCallback(api.EngineGetMessenger(engine),"fixture/rgba",RgbaMessage,nullptr);
    api.ViewControllerForceRedraw(controller);

    ComPtr<ID3D11Device> gpu;
    ComPtr<ID3D11DeviceContext> context;
    Check(D3D11CreateDevice(nullptr,D3D_DRIVER_TYPE_HARDWARE,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr,0,D3D11_SDK_VERSION,&gpu,nullptr,&context),"D3D11CreateDevice");
#ifdef NATIVE_REFRACTION
    RECT host_bounds{};GetWindowRect(host,&host_bounds);
    if (GetEnvironmentVariableW(L"GLASSUSAGE_CONTROLLED_DESKTOP",nullptr,0))
      controlled_desktop=CreateControlledDesktop(host_bounds);
    NativeRefraction optics(gpu.Get(),context.Get(),host,bridge_log);
    if (controlled_desktop) { DestroyWindow(controlled_desktop);controlled_desktop=nullptr; }
    optics.CheckOptics(host_bounds.left+600,host_bounds.top+kCardTop,bridge_log);
    optics.CheckOptics(host_bounds.left+600,host_bounds.top+kCardTop,bridge_log,true);
    pacing_timer=CreateWaitableTimerExW(nullptr,nullptr,0x2,TIMER_ALL_ACCESS);
    if (!pacing_timer) throw std::runtime_error("High resolution wait timer unavailable");
#endif
    ComPtr<IDXGIDevice> dxgi;
    Check(gpu.As(&dxgi),"DXGI");
    ComPtr<IDCompositionDevice> compositor;
    Check(DCompositionCreateDevice(dxgi.Get(),IID_PPV_ARGS(&compositor)),"DCompositionCreateDevice");
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> root,group,back,foreground;
    ComPtr<IDCompositionSurface> gray,blue,rgba_surface;
    ComPtr<IUnknown> wrapped;
    ComPtr<IUnknown> control_wrapped;
    Check(compositor->CreateTargetForHwnd(host,FALSE,&target),"CreateTargetForHwnd");
    Check(compositor->CreateVisual(&root),"root");
    Check(compositor->CreateVisual(&group),"group");
    Check(compositor->CreateVisual(&back),"back");
    Check(compositor->CreateVisual(&foreground),"foreground");
    Check(compositor->CreateSurface(kHostWidth,kHostHeight,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_ALPHA_MODE_PREMULTIPLIED,&gray),"gray");
    Check(compositor->CreateSurface(kCardWidth,kCardHeight,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_ALPHA_MODE_PREMULTIPLIED,&blue),"blue");
    Check(compositor->CreateSurface(kCardWidth,kCardHeight,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_ALPHA_MODE_PREMULTIPLIED,&rgba_surface),"rgba surface");
    UpdateSurface(gray.Get(),context.Get(),std::vector<uint32_t>(kHostWidth*kHostHeight,0xff202024),kHostWidth,kHostHeight);
    UpdateSurface(blue.Get(),context.Get(),std::vector<uint32_t>(kCardWidth*kCardHeight,0xff204060),kCardWidth,kCardHeight);
    Check(root->SetContent(gray.Get()),"gray content");
    Check(back->SetContent(blue.Get()),"blue content");
    Check(group->AddVisual(back.Get(),FALSE,nullptr),"back child");
    Check(group->AddVisual(foreground.Get(),TRUE,back.Get()),"foreground child");
#ifdef NATIVE_REFRACTION
    optics.CopyHost(gray.Get(),host_bounds);
    ComPtr<IDCompositionRectangleClip> clip;Check(compositor->CreateRectangleClip(&clip),"group rounded clip");
    clip->SetLeft(0.f);clip->SetTop(0.f);clip->SetRight(kCardWidth);clip->SetBottom(kCardHeight);
    clip->SetTopLeftRadiusX(36);clip->SetTopLeftRadiusY(36);
    clip->SetTopRightRadiusX(36);clip->SetTopRightRadiusY(36);
    clip->SetBottomLeftRadiusX(36);clip->SetBottomLeftRadiusY(36);
    clip->SetBottomRightRadiusX(36);clip->SetBottomRightRadiusY(36);
    Check(group->SetClip(clip.Get()),"group clip");
#endif
    Check(root->AddVisual(group.Get(),FALSE,nullptr),"group child");
    Check(target->SetRoot(root.Get()),"SetRoot");
    Check(compositor->Commit(),"initial Commit");
    const std::string event_name="Local\\GlassUsageFlutterBridgeProbe-"+std::to_string(GetCurrentProcessId());
    start_event=CreateEventA(nullptr,TRUE,FALSE,event_name.c_str());
    if (!start_event) throw std::runtime_error("CreateEvent failed");
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    std::fprintf(bridge_log,"bridge_start qpc=%lld freq=%lld source_hwnd=%llu host_hwnd=%llu\n",
        Qpc(),frequency.QuadPart,reinterpret_cast<UINT_PTR>(flutter_child),reinterpret_cast<UINT_PTR>(host));
    ShowWindow(host,SW_SHOWNOACTIVATE);
    std::printf("{\"ready\":true,\"hwnd\":%llu,\"event\":\"Local\\\\GlassUsageFlutterBridgeProbe-%lu\"}\n",
        reinterpret_cast<UINT_PTR>(host),GetCurrentProcessId());
    std::fflush(stdout);
    auto created=std::chrono::steady_clock::now(),started=created,next_frame=created;
    bool running=false,bridged=false,clicked=false,quit=false,alpha_control=false,rgba_bridge=false;
    unsigned uploaded_version=0;
    unsigned native_sequence=0;
    while (!quit && IsWindow(host)) {
      MSG msg{};
      while (PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)) {
        if (msg.message==WM_QUIT) quit=true;
        TranslateMessage(&msg); DispatchMessageW(&msg);
      }
      if (quit || (GetAsyncKeyState(VK_ESCAPE)&0x8000)) break;
      const auto now=std::chrono::steady_clock::now();
      if (!running) {
        if (WaitForSingleObject(start_event,0)==WAIT_OBJECT_0) {
          running=true; started=next_frame=now;
          std::fprintf(bridge_log,"baseline_start qpc=%lld\n",Qpc());
        } else if (std::chrono::duration<double>(now-created).count()>60) {
          throw std::runtime_error("Start signal timeout");
        }
      }
      if (running) {
        const double elapsed=std::chrono::duration<double>(now-started).count();
        if (elapsed>=duration) break;
        if (!bridged && elapsed>=3) {
#ifdef NATIVE_REFRACTION
          if (rgba_pixels.empty()) throw std::runtime_error("No RGBA foreground received");
          UpdateSurface(rgba_surface.Get(),context.Get(),rgba_pixels,kCardWidth,kCardHeight);
          uploaded_version=rgba_version;
          Check(foreground->SetContent(rgba_surface.Get()),"RGBA foreground content");
          SetLastError(0);
          SetWindowLongPtrW(flutter_child,GWL_EXSTYLE,GetWindowLongPtrW(flutter_child,GWL_EXSTYLE)|WS_EX_LAYERED);
          if (!SetLayeredWindowAttributes(flutter_child,0,255,LWA_ALPHA)) throw std::runtime_error("Fixture layered style failed");
          BOOL cloak=TRUE;
          Check(DwmSetWindowAttribute(flutter_child,DWMWA_CLOAK,&cloak,sizeof(cloak)),"Cloak fixture source");
          rgba_bridge=true;
          std::fprintf(bridge_log,"rgba_bridge_start qpc=%lld version=%u\n",Qpc(),uploaded_version);
#else
          SetLastError(0);
          const LONG_PTR previous_style=SetWindowLongPtrW(flutter_child,GWL_EXSTYLE,
              GetWindowLongPtrW(flutter_child,GWL_EXSTYLE)|WS_EX_LAYERED);
          const DWORD style_error=GetLastError();
          const BOOL layered=SetLayeredWindowAttributes(flutter_child,0,255,LWA_ALPHA);
          const DWORD layered_error=layered?0:GetLastError();
          const HRESULT wrap_hr=compositor->CreateSurfaceFromHwnd(flutter_child,&wrapped);
          std::fprintf(bridge_log,"bridge_enable qpc=%lld valid=%d previous_style=0x%llX style_error=%lu ex_style=0x%llX layered=%d layered_error=%lu wrap_hr=0x%08lX\n",Qpc(),
              IsWindow(flutter_child),static_cast<unsigned long long>(previous_style),style_error,
              static_cast<unsigned long long>(GetWindowLongPtrW(flutter_child,GWL_EXSTYLE)),layered,layered_error,static_cast<unsigned long>(wrap_hr));
          Check(wrap_hr,"CreateSurfaceFromHwnd Flutter child");
          Check(foreground->SetContent(wrapped.Get()),"wrapped content");
          BOOL cloak=TRUE;
          const HRESULT cloak_hr=DwmSetWindowAttribute(flutter_child,DWMWA_CLOAK,&cloak,sizeof(cloak));
          std::fprintf(bridge_log,"source_cloak qpc=%lld hr=0x%08lX\n",Qpc(),static_cast<unsigned long>(cloak_hr));
          Check(cloak_hr,"Cloak Flutter child");
          api.ViewControllerForceRedraw(controller);
#endif
          bridged=true;
        }
        if (bridged && now>=next_frame) {
          if (rgba_bridge && uploaded_version!=rgba_version) {
            UpdateSurface(rgba_surface.Get(),context.Get(),rgba_pixels,kCardWidth,kCardHeight);
            uploaded_version=rgba_version;
            std::fprintf(bridge_log,"rgba_upload qpc=%lld version=%u\n",Qpc(),uploaded_version);
          }
          const double phase=(1-std::cos((elapsed-3)*6.283185307179586/2))/2;
          visual_x=32+static_cast<int>(std::round(phase*(kHostWidth-kCardWidth-64)));
          visual_y=kCardTop;
#ifdef NATIVE_REFRACTION
          const auto prepared=Qpc();
          optics.Render(blue.Get(),host_bounds.left+visual_x,host_bounds.top+visual_y,native_sequence);
#endif
          Check(group->SetOffsetX(static_cast<float>(visual_x)),"group x");
          Check(group->SetOffsetY(static_cast<float>(visual_y)),"group y");
          Check(compositor->Commit(),"group Commit");
          std::fprintf(bridge_log,"group_commit qpc=%lld x=%d y=%d\n",Qpc(),visual_x,visual_y);
#ifdef NATIVE_REFRACTION
          std::fprintf(bridge_log,"native_lens_frame seq=%u qpc=%lld submitted_qpc=%lld left=%ld x=%d target_hz=%d rgba_version=%u\n",
              native_sequence++,prepared,Qpc(),host_bounds.left+visual_x,visual_x,elapsed<11?60:240,uploaded_version);
          next_frame=now+std::chrono::microseconds(elapsed<11?16667:4167);
#else
          next_frame=now+std::chrono::microseconds(16667);
#endif
        }
        if (bridged && !clicked && elapsed>=5) {
          RouteClick(visual_x+64,visual_y+64);
          clicked=true;
        }
#ifndef NATIVE_REFRACTION
        if (bridged && !alpha_control && elapsed>=11) {
          HWND control=CreateAlphaControl(host);
          Check(compositor->CreateSurfaceFromHwnd(control,&control_wrapped),"Wrap alpha control");
          Check(foreground->SetContent(control_wrapped.Get()),"Alpha control content");
          BOOL cloak=TRUE;
          Check(DwmSetWindowAttribute(control,DWMWA_CLOAK,&cloak,sizeof(cloak)),"Cloak alpha control");
          Check(compositor->Commit(),"Alpha control Commit");
          std::fprintf(bridge_log,"alpha_control_start qpc=%lld\n",Qpc());
          alpha_control=true;
        }
        if (alpha_control && !rgba_bridge && elapsed>=15 && rgba_version>0) {
          UpdateSurface(rgba_surface.Get(),context.Get(),rgba_pixels,kCardWidth,kCardHeight);
          uploaded_version=rgba_version;
          Check(foreground->SetContent(rgba_surface.Get()),"RGBA foreground content");
          Check(compositor->Commit(),"RGBA bridge Commit");
          std::fprintf(bridge_log,"rgba_bridge_start qpc=%lld version=%u\n",Qpc(),uploaded_version);
          rgba_bridge=true;
        }
#endif
      }
#ifdef NATIVE_REFRACTION
      LARGE_INTEGER due;due.QuadPart=-10000;
      if (!SetWaitableTimer(pacing_timer,&due,0,nullptr,nullptr,FALSE)) throw std::runtime_error("Pacing timer failed");
      WaitForSingleObject(pacing_timer,100);
#else
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
#endif
    }
    std::fprintf(bridge_log,"bridge_end qpc=%lld bridged=%d clicked=%d\n",Qpc(),bridged,clicked);
    std::printf("{\"complete\":true,\"bridged\":%s}\n",bridged?"true":"false");
    std::fflush(stdout);
  } catch (const std::exception& error) {
    std::fprintf(bridge_log,"probe_error message=%s\n",error.what());
    std::fprintf(stderr,"%s\n",error.what()); result=1;
  }
  if (controller) {
    const auto owned=controller; controller=nullptr;
    api.ViewControllerDestroy(owned);
  }
  if (host && IsWindow(host)) DestroyWindow(host);
  if (controlled_desktop) DestroyWindow(controlled_desktop);
  if (start_event) CloseHandle(start_event);
  if (pacing_timer) CloseHandle(pacing_timer);
  if (library) FreeLibrary(library);
  std::fclose(bridge_log); bridge_log=nullptr;
  CoUninitialize();
  return result;
}
