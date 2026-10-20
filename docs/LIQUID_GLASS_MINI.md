# 跨平台液态玻璃小窗

更新：2026-10-20。材质来自用户提供的 liquid_glass_small_window.zip。采用共用 Dart 界面与控制、本地 desktop_glass 插件、原生纹理供帧。数据采集、计费和数据库语义保持原有实现。

## 合并审核索引

本轮解决 macOS 小窗拖动时背景滞后、偶发一两帧抖动，以及返回主界面时的无障碍桥崩溃。以下文件应配套审核；不需要修改 Flutter SDK、数据库或采集器。

| 文件 | 变更目的与审核重点 |
| --- | --- |
| `macos/Runner/MainFlutterWindow.swift` | 原生鼠标事件移动窗口；小窗左键序列直接送 Flutter，并关闭系统标题栏移动；检查退出时恢复 `isMovable`、完整/紧凑重复切换不覆盖恢复值，以及监听清理。避免改回 `performDrag`。 |
| `lib/core/window/desktop_window_manager.dart` | Dart/Swift 通道与小窗生命周期配套；检查恢复主界面前暂停并移除实时纹理。120ms 仅作切换缓冲，不替代滑块崩溃修复。 |
| `packages/desktop_glass/macos/Classes/DesktopGlassPlugin.swift` | 在栅格线程取纹理时按最新位置裁剪；重点检查线程归属、锁范围、纹理注册/注销和“桌面版本 + 窗口位置”缓存条件。 |
| `packages/desktop_glass/lib/desktop_glass.dart` | 会话坐标元数据与诊断字段；当前原生返回小窗纹理，勿恢复 Dart 逐帧查询位置；取纹理计数不等于显示 FPS。 |
| `lib/presentation/pages/mini_card_view.dart` | 原生纹理驱动画面；首帧快速轮询后改为低频统计，使用无 OverlayPortal 的滑块，两项效果归零时跳过滤镜。 |
| `lib/domain/models/settings_model.dart` | 保存折射/色散参数；旧配置缺键时使用默认值。 |
| `test/settings_model_test.dart` | 只覆盖参数往返和旧配置默认值，不扩大为实时效果/原生稳定性的验收证据。 |
| `docs/LIQUID_GLASS_MINI.md` | 记录渲染时序、平台边界及验证范围，供合并和后续维护时对照。 |

验证记录：macOS 编译、定向静态分析及 3 项相关测试通过；用户已确认最终拖动效果正常。该实测不等同于正式 30 秒性能采样，也不代表 Windows/Linux、多屏、连续 20 轮切换已经回归。合并审核时建议检查完整/紧凑、双效果归零、隐藏恢复、返回主界面，以及跨屏行为。

顶部拖动补充：提交版 `3418ef6` 中，顶部与内部都会命中 Flutter 并启动同一自定义拖动，但透明标题栏仍允许额外的系统移动。临时运行记录中，顶部 6 次手势、1602 次移动事件出现 76 次额外改位，最大 13.15 点；内部 7 次手势、2802 次事件均为 0。仅隐藏标题栏、单独关闭系统移动的先前尝试未通过用户验收，均已撤回；仅转发鼠标事件的对照仍出现额外改位。当前将小窗左键按下、移动、松开直接转发给原 Flutter 控制器，同时关闭 `isMovable`，退出时恢复原值，完整/紧凑切换不重复保存。该组合下顶部额外改位归零，用户确认完整小窗顶部和紧凑上半部均顺滑；临时计数已移除。滑块和按钮仍由 Flutter 处理，不按固定标题栏高度划分区域。

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
- 折射 0–60、色散 0–4，随 settings.json 持久化（widgetRefraction/widgetChromatic）；测试背景需主动切换，明确标记「测试背景 · 非桌面实时折射」。失败默认使用磨砂，不显示黑窗或用测试条纹冒充桌面。
- 底部显示实时/静止状态，不再把纹理回调计数作为可见 FPS 展示。悬停可查看纹理提交频率或错误；`FrameTiming` 单独记录 Flutter 帧，均不能代表屏幕扫描输出。

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

`MiniCardView` 仅依赖共用控制器与能力结果。进入后连接，隐藏/最小化暂停，恢复继续，切换测试背景、返回主界面和销毁时停止。首次连接以 100ms 间隔等待首帧，收到后改为每秒诊断统计。复用最初 Windows 版本的直接滤镜链：`ImageFiltered` 以原生 `Texture` 为子节点，新纹理驱动滤镜输出刷新，不依赖兄弟节点的背景缓存，也不添加持续重绘的 Dart Ticker。纹理提交和 `FrameTiming` 分开统计，不以纹理次数宣称可见画面达标。

## 平台实现

### Windows

DXGI Desktop Duplication 和纹理注册位于插件 `windows/`。原生线程最多按目标速率工作，桌面帧保留在 D3D11 纹理，只裁剪小窗客户区并读回 CPU，转换 RGBA 后提交 `PixelBufferTexture`。这是局部 CPU 读回，并非全程 GPU 零拷贝。

最新帧覆盖旧帧，上传期间用独立引用保持像素有效；停止时等待捕获线程结束，异步注销纹理时保留回调存储。尺寸变化重建 staging 缓冲，显示器变化或 DXGI access-lost 重建设备。

仅实时会话期间设置 `WDA_EXCLUDEFROMCAPTURE`，停止后恢复启动前的 affinity。它阻止捕获自身的折射结果，也使小窗不出现在多数系统截图/录屏中。验收画面应从应用内部渲染导出；内部截图只包含 Flutter 视图，不代表系统截图中的可见性。

Windows runner 继续处理托盘、快捷键和小窗原生窗口样式，不再拥有捕获实例。

### macOS

ScreenCaptureKit 保留单路整屏捕获（点分辨率），按自身 NSWindow 编号过滤窗口。Flutter 栅格线程实际取纹理时，Core Image 的 Metal 上下文读取最新原生窗口位置，在 GPU 裁剪出小窗区域，输出 IOSurface 支持的 BGRA `CVPixelBuffer` 给 Flutter。最多复用三个裁剪缓冲，缓冲被占用时跳帧，不积压旧图。原生移动/缩放通知及 common-mode 几何轮询只请求刷新，实际裁剪推迟到取帧时，避免提交按旧位置预先裁剪的图像，所以静止桌面拖动也能更新；Dart 不再查询窗口坐标或平移整屏纹理。小窗拖动通过原生 NSEvent 监听直接 setFrameOrigin，不进入 window_manager 的 performDrag 嵌套循环；鼠标松开或退出小窗即释放监听。亮度和像素变化每 250ms 在捕获队列按小窗区域抽样，不占用裁剪缓冲或阻塞取纹理。桌面帧和窗口位置都没变时复用前一裁剪。新帧通知合并后通过主 RunLoop common modes 调用 Flutter 纹理入口；窗口移动已经在主线程时立即通知，省掉一次 RunLoop 排队，保持平台线程约束，并让 AppKit 拖动的 tracking loop 继续处理通知。

只有跨屏或显示器几何变化才重配捕获；进行中的更新结束后重查状态，1Hz 看门狗兜底。设备失效时刷新内容并重建流，重建后立即开始捕获。从小窗返回主界面前先暂停会话并移除实时纹理层，延迟约 120ms 再做窗口几何/材质切换，规避 macOS embedder 在渲染中重建 surface 的崩溃。

工程作为本地桌面应用配置，未启用 App Sandbox，以便原有本地日志读取正常工作；录屏仍需系统 TCC 授权。没有扩展既有凭据存储、托盘、安装或签名流程。

### Linux

Dart 能力层明确返回不支持实时捕获，未添加 Portal/PipeWire。正常显示数据、控件与磨砂状态，不存在模拟桌面回退。系统磨砂不保证在所有合成器生效。

## 共用渲染

`原生对齐的小窗 Texture → ImageFiltered（0.8px blur）→ ImageFiltered（原版 liquid_glass.frag）→ 内容与描边`，复用最初 Windows 版本的直接纹理滤镜链；着色器保持上游 0.1.3 原文，不做自定义修改。折射和色散都为 0 时直接显示原生 Texture，跳过滤镜用于关闭效果。实时滤镜以 `ImageFilter.isShaderFilterSupported` 为准，不可用时显示原因并降级。

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
| Windows 持续动态场景 60 FPS | 待正式验收 | 纹理回调和 `FrameTiming` 分开统计；恢复直接纹理滤镜链后仍需 Windows 实机复测，不声明达标 |
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

## macOS 返回主界面崩溃

2026-10-20 的原生堆栈在 `AccessibilityBridge::CreateRemoveReparentedNodesUpdate` 崩溃，之前同时有 AXTree 节点更新错误。小窗 Material Slider 的 OverlayPortal 会在切换时产生孤立的语义节点；改用没有 OverlayPortal 的 `CupertinoSlider`，保留折射/色散值、持久化、拖动和语义标签。不通过关闭无障碍功能规避。macOS Debug 编译、定向静态分析及既有小窗/设置测试通过；已实测成功返回主界面，当前新进程未出现 AXTree 错误。尚未完成连续 20 轮切换及 Windows 实机回归。参见 [Flutter #190357](https://github.com/flutter/flutter/issues/190357)。
