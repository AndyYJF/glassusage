# Windows 小窗拖动延迟交接（2026-11-14）

## 当前状态：WIP，不是可发布修复

分支 `fix/windows-glass-parity`，本轮以 `6c924b3` 为基线保存现场。
工作区包含之前的 Windows 恢复/晚裁剪/诊断修改，以及已验证失败的
`frame_sync` 拖动原型。此次提交只保存代码与证据，不表示验收通过；
不要直接合并 main、发布、安装或把当前源码构建替换用户正在使用的版本。

失败原型会拦截小窗的 `SC_MOVE`，并非只在设置诊断环境变量时生效。
即使探针环境变量未设置，也不能把当前分支当作已恢复的普通拖动实现。
`LIQUID_GLASS_MINI.md` 的旧路径说明不能覆盖本交接中的 WIP 警告。

## 关键结论（不要重走已否定路线）

| 路径 / 证据 | 结论 |
|---|---|
| 原窗口移动与 Flutter 纹理独立提交 | 已在本地合成画面中看到同纹理序号与窗口坐标错配；不只是 UU 体感。极快拖动还可超出预取范围。 |
| 早期所谓约150ms发布间隔 | 后续证明包含静止/去重，不能作为某个 API 阻塞150ms的证据。 |
| 着色器0/0与45.2/0.3粗略对照、Flutter时间线 | 不支持着色器计算或普通 UI/raster 耗时是主因；物理显示、UU时延没有测到。 |
| `SetNextFrameCallback` 后 `SetWindowPos` | **失败**：273张带token图像有39张错配，最大338px；更新约30Hz。回调不是DWM几何/内容原子边界。 |
| 固定原生host内，表面与visual位置同设备一次Commit | 基础实验1595张有效图像0px错配，证明该受控事务可行，不代表完整产品。 |
| Flutter HWND桥接 | 画面和私有点击回执正常，但透明区变黑；已知原生逐像素alpha对照正常。不能直接用该桥接方案。 |
| Dart picture → premultiplied RGBA → 原生表面 | 735张有效图像透明混合正确，26个动态编码。仅约5Hz前景的兼容性证明，有GPU读回/CPU转换/上传成本。 |
| 冻结的受控桌面输入 → 原生折射/色散 + 透明前景 | 折射开关改变27081像素；3325张可解码合成画面坐标错配0px；实际约57.65/209.58Hz，没有达到请求的240Hz。 |

高频段1886次更新中1857次被独立观察到，29次未独立观察到，不能断言
全部显示或全部丢帧。约4.22ms中位数是准备到首次观察到本地合成图像，
不是鼠标到物理屏幕、UU端到端延迟，也不是已证明的用户体感改善。
帧坐标条带绕过光学公式；其0px结论不是对全部折射像素的逐像素对齐验收。

## 保存的代码与证据

- 当前未验收产品修改：
  `lib/core/window/desktop_window_manager.dart`、`lib/presentation/pages/mini_card_view.dart`、
  `packages/desktop_glass/windows/mini_desktop_capture.cpp/.h`、
  `packages/desktop_glass/windows/frame_sync.h`、`windows/runner/flutter_window.cpp`。
- [最重要的失败记录](diagnostics/windows-glass/FRAME_SYNC_VALIDATION_RESULT.md)：
  token106在原生移动提交7.14ms后仍显示旧几何/新纹理，338px错配。
- [最新原生折射结果与限制](diagnostics/windows-glass/NATIVE_REFRACTION_RESULT.md)。
- 其余背景、时间线、前景桥接和可行性报告也在 `docs/diagnostics/windows-glass/`。
- 同目录原样归档独立探针源码、Dart夹具、manifest、构建批处理和离线分析器。
  它们不是插件/正式渲染器，不接入项目构建；脚本保留本机VS/SDK/engine绝对路径，
  **不是开箱即用的跨机器测试包**。重放前核对路径，先编译夹具kernel_blob，
  不要下载/重编整个Flutter engine，也不要误启动应用业务入口。
- 原始分类像素日志、构建产物、备份和较早计划仍保留在本机：
  `C:/Users/AndyYan/Desktop/codex/.codex_tmp/glassusage-lag-probe/`、
  `C:/Users/AndyYan/Desktop/codex/.codex_tmp/glassusage-root-cause/`、
  `C:/Users/AndyYan/Desktop/codex/.codex_tmp/glassusage-latency-fix/`。
  未纳入Git，换机器仅有报告和源码，不会自动带上原始日志。不要删除这些现场。

探针入口：`run_native_comp_probe.py --native-refraction`；受控桌面来源开关
`GLASSUSAGE_CONTROLLED_DESKTOP=1`。这仍是自动运动/冻结背景模式，
**没有手动拖动模式**。当前 `analyze_native_refraction.py` 已在离线解码中
修正棋盘与GM分类条带的颜色碰撞，无需为该解码问题重新采样。

## 下一步与未解决问题

用户在2026-11-13选择稍后做手动拖动，先保存证据；本轮只要求提交与交接。
下一位agent应先只读核对进程/分支/现场，再与用户约定手动采样时机：

1. 给**独立**原生探针增加真正的水平鼠标拖动入口和按实际开始动作触发的短采样；
   先确认窗口已启动，再明确告诉用户何时拖动，约20秒后自动停止。
   不要让用户去拖未启动的实例或把自动正弦运动写成真实输入验收。
2. 分开验证鼠标输入→目标坐标→原生提交→本地合成；补捕获丢失/取消、
   点击/滑块、圆角命中与外部穿透。当前私有SendMessage回执不能替代这些。
3. 再验证动态桌面源新鲜度与捕获排除拓扑，避免自反馈。
   当前只有一次性冻结桌面纹理；不能直接推广到动态背景。
4. 还有纵向/跨屏/DPI、host边界移动、前景导出成本、高刷新率及完整光学一致性。
   原生HLSL只是核心SDF/折射/七路色散，不包含全部模糊、交互高光、真实业务控件。
5. 历史拖动崩溃未闭环，未在最近轮次复现；不能因探针运行正常宣布已修复。
   产品接入应在独立验证后另行明确范围，不能继续给失败的frame callback方案叠等待。

## 本机与操作约束

- 使用 Git Bash，不用 PowerShell；不在main操作。不删除诊断现场、用户改动或密钥。
- 用户通过UU远控。此前截图辅助进程曾触发黄色捕获边框，退出后消失。
  后续采用DXGI分类像素日志，没有截图/视频文件；不要擅自再开截图辅助程序。
- 不随意关闭 `WDA_EXCLUDEFROMCAPTURE`。独立受控输入的DXGI报告曾出现
  `ProtectedContentMaskedOut=1`，位置/原因未确定，没有绕过保护。
- 最后一次运行核验为2026-11-13：安装版 `C:/App/GlassUsage/glassusage.exe`，
  PID30744；折射45.2、色散0.3，探针已退出。**这是历史状态，续接时重新核对**，
  不要未经确认结束其他实例或覆盖设置。独立探针不需要运行GlassUsage业务入口。
- 不做重复全量审计、完整构建、签名/打包/发布；验证要针对尚未回答的问题。
  如需网络，最后指定代理为7890。签名私钥不属于诊断/交接材料，禁止纳入Git。

本轮提交未重新构建或运行测试，只做暂存内容和空白错误检查；既有成功的
原生构建/诊断结果是历史证据，不能冒充本轮重新验收。
