# 跨平台液态玻璃小窗

更新：2026-10-17。材质来自用户提供的 liquid_glass_small_window.zip。采用共用 Dart 界面与控制、本地 desktop_glass 插件、原生纹理供帧。数据采集、计费和数据库语义保持原有实现。

## 使用与构建

固定 Flutter **3.47.7 / Dart 3.13.5**，本地版本见 `.fvmrc`，CI 与既有发布工作流使用同一版本。

```sh
flutter pub get
flutter run -d windows
# 在对应平台主机上构建：
flutter build windows --release
flutter build macos --release
flutter build linux --release
```

- Windows 10 2004+ / Windows 11 支持实时桌面折射；旧版本明确降级。
- macOS 最低 12.3，仅首次进入实时小窗时请求「屏幕录制」权限。拒绝后显示原因并降级，当前进程不重复弹框；可在系统设置授权后重试，必要时重启。主界面不申请录屏权限。
- Linux 第一版为磨砂模式，优先尝试系统材质，不支持时使用可读的 Dart 材质。不申请录屏权限，也不模拟桌面。
- 通过侧栏「迷你浮窗」进入；Windows 保留托盘和原有 Ctrl+Alt+G。macOS/Linux 没有新增托盘或全局快捷键，隐藏动作采用最小化以保留恢复入口。
- 完整 432×300、紧凑 228×54 逻辑像素；保留真实用量、趋势、费用、拖动、置顶和返回主界面。调整尺寸后按实际客户区重建捕获缓冲。
- 折射 0–60、色散 0–4；测试背景需主动切换，明确标记「测试背景 · 非桌面实时折射」。失败默认使用磨砂，不显示黑窗或用测试条纹冒充桌面。
- 底部动态数字显示原生纹理回调频率，不代表显示器扫描输出；静止场景标记「静止待命」。Flutter `FrameTiming` 仅用于诊断日志，悬停状态文字可查看捕获或着色器错误。

## 接入结构

`packages/desktop_glass/lib/desktop_glass.dart` 提供 `DesktopGlass`：

| 调用 | 结果 / 语义 |
| --- | --- |
| `capabilities()` | `GlassCapabilities`：实时捕获、自身排除、权限需求、不可用原因 |
| `start(targetFps: 60)` | `GlassSession(id, textureId)`；目标范围 1–60，替换当前原生会话 |
| `pause(id)` / `resume(id)` | 只控制匹配编号的会话 |
| `stop(id)` | 只停止匹配编号的会话；重复或过期停止无副作用 |
| `stats(id)` | `GlassStats`；过期会话返回 null |

统计字段：`frames` 捕获输出数、`presented` 纹理回调提交数、`changes` 采样像素哈希变化数、`elapsed` 会话秒数、`luminance` 亮度、`paused`、`error`；`raw` 保留平台尺寸与排除状态。纹理提交数包括可能重复读取最新帧，不能视为独立新画面数，也不等同于显示器扫描输出。

平台通道 `glassusage/desktop_glass` 只传控制与统计；逐帧画面通过 Flutter `Texture`，不经过 Dart 解码或逐帧 MethodChannel。`lib/core/window/desktop_glass_controller.dart` 管理组件拥有的会话。迟到的启动结果只释放自身编号，旧组件不会全局停止新会话。

`MiniCardView` 仅依赖共用控制器与能力结果。进入后连接，隐藏/最小化暂停，恢复继续，切换测试背景、返回主界面和销毁时停止。实时画面由原生纹理新帧触发绘制，不额外启动 Flutter Ticker 强制整棵界面持续重绘；静止时只在必要状态变化时刷新。界面上的动态数字由纹理回调计数估算，诊断日志独立记录 `FrameTiming`，两者都不等同于显示器物理扫描输出。

## 平台实现

### Windows

DXGI Desktop Duplication 和纹理注册位于插件 `windows/`。原生线程最多按目标速率工作，桌面帧保留在 D3D11 纹理，只裁剪小窗客户区并读回 CPU，转换 RGBA 后提交 `PixelBufferTexture`。这是局部 CPU 读回，并非全程 GPU 零拷贝。

最新帧覆盖旧帧，上传期间用独立引用保持像素有效；停止时等待捕获线程结束，异步注销纹理时保留回调存储。尺寸变化重建 staging 缓冲，显示器变化或 DXGI access-lost 重建设备。

仅实时会话期间设置 `WDA_EXCLUDEFROMCAPTURE`，停止后恢复启动前的 affinity。它阻止捕获自身的折射结果，也使小窗不出现在多数系统截图/录屏中。验收画面应从应用内部渲染导出；内部截图只包含 Flutter 视图，不代表系统截图中的可见性。

Windows runner 继续处理托盘、快捷键和小窗原生窗口样式，不再拥有捕获实例。

### macOS

ScreenCaptureKit 按自身 NSWindow 编号过滤窗口。BGRA `CVPixelBuffer` 注册为 Flutter 纹理，保留最新缓冲，检查完整帧状态并采样亮度/变化计数。捕获区域以 Flutter 客户区为基准，转换 AppKit 坐标并跟随位置、尺寸、屏幕和 backing scale；设备失效时刷新内容并重建流。

工程作为本地桌面应用配置，未启用 App Sandbox，以便原有本地日志读取正常工作；录屏仍需系统 TCC 授权。没有扩展既有凭据存储、托盘、安装或签名流程。

### Linux

Dart 能力层明确返回不支持实时捕获，未添加 Portal/PipeWire。正常显示数据、控件与磨砂状态，不存在模拟桌面回退。系统磨砂不保证在所有合成器生效。

## 共用渲染

`Texture → 0.8px blur → ImageFilter.shader → 内容与描边`。原生纹理与着色器统一使用物理像素，Flutter 布局通过 DPR 从逻辑像素转换。实时滤镜以 `ImageFilter.isShaderFilterSupported` 为准，不可用时显示原因并降级。

Flutter 3.47 桌面默认启用 Impeller，见 [Flutter 官方说明](https://docs.flutter.dev/perf/impeller)，但默认开启不代表当前运行设备支持全部滤镜能力。

## 验证状态

| 项目 | 当前状态 | 证据 / 限制 |
| --- | --- | --- |
| 三平台结构、会话、共用渲染与生命周期 | 已实现 | 本次源码 |
| Windows Debug / Profile | 编译通过 | Flutter 3.47.7 本机构建 |
| Dart 静态分析 | 通过 | flutter analyze，0 issues |
| 既有单元与界面测试 | 通过 | 最终串行全量 39 项通过；一次并行构建期间测试进程提前退出，单独与全量重跑均通过 |
| Windows 真实桌面画面 | 用户实测无问题 | 用户要求直接提交推送；此前内部截图确认真实桌面纹理 |
| Windows 自动操作、20 次切换与资源专项 | 待完整验收 | Computer Use 被物理 Escape 中断；用户实测不扩大为逐项自动化证据 |
| Windows 持续动态场景 60 FPS | 待正式验收 | 移除了会强制持续重绘的 Flutter Ticker；纹理回调和 `FrameTiming` 分开统计。最终 30 秒采样未完成，不声明达标 |
| macOS / Linux Release CI | 已配置，待远程结果 | 新增编译任务；保留 Windows 分析、测试和 Release 构建；仅推送分支，不创建 MR |
| macOS 授权、真实折射、多屏与 60 FPS | 待 Mac 实机验收 | CI 编译不能替代实机 |

性能诊断构建：

```sh
flutter build windows --profile --dart-define=LIVE_GLASS_METRICS=true
```

每秒输出 `LIVE_GLASS_METRICS` JSON：原生计数、`rasterFrames`、`rasterFps`、`textureFps`、`rasterMs` 样本。默认关闭，不输出桌面图像或文字。捕获内容仅驻内存，不落盘、不联网。诊断日志和截图位于忽略的 `build/`，不随源码提交。

正式验收：优化构建，真实桌面持续运动且源刷新率至少 60 Hz；预热 5 秒后取连续 30 秒，按累计计数差/实际时长计算捕获、纹理提交和 Flutter 实际渲染平均值，三者均须 ≥59 FPS（兼容 59.94 Hz）；合并区间全部 `rasterMs` 求 P95，须 ≤16.7ms。检查 `changes` 持续增长、无错误、排除有效，避免把静止场景或定时器次数当成性能结果。仍需逐项验证完整/紧凑、拖动、缩放、置顶、隐藏恢复、返回主界面、连续切换 20 次资源释放与 affinity 恢复。

第一版跨屏选择单个显示器，不拼接第二路画面。Windows 旋转显示器、HDR、多显卡、锁屏恢复，以及 macOS 多屏坐标仍需专项验收。既有 Windows accessibility bridge 树更新错误未在本次扩展为无障碍专项修复。

## 来源与许可

`assets/shaders/liquid_glass.frag` 原样来自附件内 flutter_liquid_glasses 0.1.3；附件注明上游提交 f67b4615fcd6a47d2ffde15246b8888f8383446e。Apache-2.0 LICENSE、NOTICE 位于 `reference/liquid_glass/`，随 Flutter assets 打包。插件其余代码沿用仓库 MIT 许可。

参考：[Microsoft Desktop Duplication](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/desktop-dup-api)、[窗口捕获排除](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)、[Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)。
