#include "include/desktop_glass/desktop_glass_plugin_c_api.h"
#include "mini_desktop_capture.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

namespace {
using V = flutter::EncodableValue;
using Map = flutter::EncodableMap;

int64_t IntegerArgument(const flutter::MethodCall<V>& call,
                        const char* key, int64_t fallback) {
  const auto* arguments = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
  if (!arguments) return fallback;
  const auto found = arguments->find(V(key));
  if (found == arguments->end()) return fallback;
  if (const auto* value32 = std::get_if<int32_t>(&found->second)) return *value32;
  if (const auto* value64 = std::get_if<int64_t>(&found->second)) return *value64;
  return fallback;
}

class DesktopGlassPlugin : public flutter::Plugin {
 public:
  explicit DesktopGlassPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<V>>(
        registrar->messenger(), "glassusage/desktop_glass",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      const auto& method = call.method_name();
      if (method == "capabilities") {
        const bool supported = MiniDesktopCapture::IsSupported();
        Map data{{V("realtimeCapture"), V(supported)},
                 {V("selfExclusion"), V(supported)},
                 {V("requiresPermission"), V(false)}};
        if (!supported) data[V("reason")] = V("windowsVersionUnsupported");
        result->Success(V(data));
      } else if (method == "start") {
        const int64_t fps = IntegerArgument(call, "targetFps", 60);
        if (fps < 1 || fps > 60) {
          result->Error("argument", "targetFps must be between 1 and 60");
          return;
        }
        capture_.reset();
        const HWND window = GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
        capture_ = std::make_unique<MiniDesktopCapture>(
            window, registrar_->texture_registrar(), static_cast<int>(fps));
        const std::string error = capture_->Start();
        if (!error.empty()) {
          capture_.reset();
          result->Error("captureUnavailable", error);
          return;
        }
        session_id_ = ++next_session_id_;
        result->Success(V(Map{{V("sessionId"), V(session_id_)},
                              {V("textureId"), V(capture_->texture_id())}}));
      } else if (method == "stats" || method == "stop" ||
                 method == "pause" || method == "resume") {
        const int64_t requested = IntegerArgument(call, "sessionId", -1);
        const bool owned = capture_ && requested == session_id_;
        if (method == "stats") {
          auto data = owned ? capture_->Stats() : Map{};
          data[V("active")] = V(owned);
          data[V("sessionId")] = V(requested);
          result->Success(V(data));
        } else {
          if (owned) {
            if (method == "stop") capture_.reset();
            else capture_->SetPaused(method == "pause");
          }
          result->Success();
        }
      } else {
        result->NotImplemented();
      }
    });
  }

 private:
  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<V>> channel_;
  std::unique_ptr<MiniDesktopCapture> capture_;
  int64_t session_id_ = 0;
  int64_t next_session_id_ = 0;
};
}  // namespace

void DesktopGlassPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  auto* wrapper = flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  wrapper->AddPlugin(std::make_unique<DesktopGlassPlugin>(wrapper));
}
