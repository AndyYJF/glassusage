#ifndef FLUTTER_PLUGIN_DESKTOP_GLASS_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_DESKTOP_GLASS_PLUGIN_C_API_H_
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define DESKTOP_GLASS_EXPORT __declspec(dllexport)
#else
#define DESKTOP_GLASS_EXPORT __declspec(dllimport)
#endif
#if defined(__cplusplus)
extern "C" {
#endif
DESKTOP_GLASS_EXPORT void DesktopGlassPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#if defined(__cplusplus)
}
#endif
#endif
