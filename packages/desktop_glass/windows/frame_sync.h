#ifndef GLASSUSAGE_FRAME_SYNC_H_
#define GLASSUSAGE_FRAME_SYNC_H_

#include <windows.h>

// Runner and capture plugin share only message IDs, never object ownership.
namespace glassusage_frame_sync {
inline UINT Request() {
  static const UINT message = RegisterWindowMessageW(L"GlassUsage.Backdrop.NextFrame.v1");
  return message;
}
inline UINT Presented() {
  static const UINT message = RegisterWindowMessageW(L"GlassUsage.Backdrop.FrameSubmitted.v1");
  return message;
}
inline UINT Ready() {
  static const UINT message = RegisterWindowMessageW(L"GlassUsage.Backdrop.FrameReady.v1");
  return message;
}
}  // namespace glassusage_frame_sync

#endif
