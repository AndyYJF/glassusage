# GlassUsage 纯 Flutter 迁移计划

> 制定日期：2026-10-16（Asia/Shanghai）
> 当前阶段：已补充前端/IPC/SQLite 防卡顿架构约束，在 `c:\Users\AndyYan\AGV\glassusage` 启动实施，进度详见 `docs/MIGRATION_STATUS.md`。
> 工作目录：`c:\Users\AndyYan\AGV\glassusage`
> 上游基线：`AndyYJF/glassusage`，`main`，提交 `d77de0348e9865ec8ce41a8dea8722d3ce324dde`，版本 `0.6.3`。

## 1. 目标与实施边界

将现有 Windows 桌面应用迁移为 Flutter 应用，复用原项目的功能、数据语义、采集规则和视觉方向，并在架构层面根除原版 Tauri + React (WebView2) 存在的 UI 卡顿问题。界面、业务逻辑、解析、计价、调度、查询与导出均由 Dart 实现；运行和构建应用不再依赖 React、TypeScript、Vite、Tauri、Rust 或 WebView2。

本计划对“纯 Flutter”的实施定义：允许 Flutter 标准 Windows runner、Flutter 桌面插件、SQLite 等必要的系统库，以及 Dart FFI 对系统 API 的调用；不保留 Rust 后端，不通过 WebView 承载界面，不把旧应用包装进 Flutter。若后续要求连插件内部的原生实现也禁止，需要先重新界定桌面系统能力的范围。

Windows 是首个完整交付平台。保留代码结构的跨平台能力，macOS、Linux、Android、iOS 不列入本次验收；读取本机桌面工具日志的场景也不能直接等同于移动端功能。

完整目标包含原项目的十种数据源、远程实例、主窗口与独立悬浮窗、导出、预算、设置和发布链路。下面的阶段是施工顺序，不是默认删减功能的范围。

**原实现完整归档保留在 `reference/upstream` 供对照，根目录使用 Flutter；阶段进度和验证边界以 `docs/MIGRATION_STATUS.md` 为准。**

## 2. 源码梳理与原版 UI 卡顿根因诊断

原项目的数据链路：

```text
本机日志 / 本机 SQLite / Cursor 账户 API / SSH 快照
                         ↓
                 各来源 Collector
                         ↓
       UsageEvent：统一字段、模型名、token 和费用
                         ↓
       SQLite：去重、更新、增量水位、日聚合、状态
                         ↓
       查询与实时统计 → Tauri IPC → React 主界面 / mini card
```

它主要读取工具已经保存的数据。Cursor 单独访问账户 API，远程实例通过 SSH 拉取数据；不能把“本地统计”理解为应用完全不联网。

### 2.1 原版前端 UI 卡顿的四大根因（迁移时必须根除，严禁 1:1 照搬缺陷）

1. **同步 IPC 阻塞主线程 + SQLite 单连接全局互斥锁争用**：
   - 原 `src-tauri/src/commands.rs` 中所有高频查询与设置接口（`get_overview`、`get_timeseries`、`get_agent_stats`、`get_usage_log`、`get_group_stats`、`get_source_health`、`get_live_rates`、`set_settings` 等）均为同步 `pub fn`，直接在 Windows 主线程（Win32 消息泵 / UI 线程）上执行。
   - 原 `Store` 虽开启 WAL，但仅用单个 `parking_lot::Mutex<Connection>` 串行化所有读写。后台扫描线程执行 `ingest_scan` 或 `reprice` 持有锁期间，主线程发起任何查询都会在锁上直接阻塞等待磁盘事务提交，导致窗口拖拽卡死、点击无响应。
2. **SQLite 索引失效导致全表扫描 + 无防抖事件风暴 + 重复查询**：
   - `rebuild_rollup_days_tx` 使用 `WHERE date(ts_ms/1000, 'unixepoch', 'localtime') = ?1`，因对列套函数导致 `idx_ev_ts` 索引失效，每次流式增量入库都触发全表扫描。
   - `source_health` 执行 `SELECT source, instance, COUNT(*), MAX(ts_ms) FROM usage_events GROUP BY source, instance` 缺少 `(source, instance, ts_ms)` 复合索引；且 `scan_all` 一次连发 10 个无防抖 `source-status` 事件，每次都在主线程触发全表聚合 + 10 个来源的磁盘目录遍历（`detect()`）。
   - `get_live_rates` 每 1~2 秒在主线程重复查询 2~3 次今日汇总 SQL，同时后台 `spawn_live_ticker` 空转推送无人监听的 `live-rates` 事件并双重衰减 EMA。
   - `overview` 每次串行执行 6 次原始表范围查询，`timeseries` 在 `day`/`week` 粒度下仍逐行计算 `unixepoch(date(...))` 而未复用 `daily_rollup`。
3. **WebView2 9 步 SVG 色散位移滤镜 (`#lens-*`) 与全屏动态模糊背景开销过大**：
   - 每个 `#lens-*` 滤镜含 3 次 `feDisplacementMap` + 3 次 `feColorMatrix` + 2 次 `feBlend`；在 Settings 拖动折射滑块时逐帧修改 SVG DOM 的 `scale` 属性触发全屏滤镜重编译。
   - CSS 材质下 `.animated-bg` 使用两个 `60vw × 60vw` 的 `filter: blur(90px)` 伪元素持续位移，迫使上层所有 `backdrop-filter` 元素每帧重采样。
   - `acrylic`/`mica` 模式下遗漏了 `.gbtn`、`.gseg-thumb`、`.gslider-thumb` 的 `backdrop-filter` 降级，导致数十个筛选按钮各自创建独立合成层。
4. **高频状态更新未做局部重绘隔离**：
   - 设置页拖拽滑块时在 `onChange`（每帧 `pointermove`）中直接修改全局 Settings 缓存，导致全应用订阅组件每帧重渲染。
   - Mini Card 同时运行 4 个 `requestAnimationFrame` `setState`（60fps）与 250ms 定时器，驱动整棵组件树与数十个 `Odometer` 节点高频重排。

### 2.2 模块迁移映射

| 原模块 | 作用 | 迁移方向 |
| --- | --- | --- |
| `src-tauri/src/model.rs` | 统一事件、token 分解、筛选、来源健康、实时速率 | Dart 领域模型 |
| `src-tauri/src/collectors/` | 各来源探测、解析、增量读取和去重键 | 每来源独立 Dart collector（运行于后台 Isolate） |
| `src-tauri/src/store.rs` | SQLite 表、事务、查询、日汇总 | 独立存储层，保留数据语义并修复索引与慢查询 |
| `src-tauri/src/pricing.rs` | 模型归一化、价格缓存、别名、覆盖与重算 | Dart 计价服务 |
| `src-tauri/src/state.rs`、`watcher.rs`、`live.rs` | 扫描调度、文件监听、实时窗口、预算检查 | Dart 后台 Isolate 服务与合并防抖事件流 |
| `src-tauri/src/remote/` | SSH、代理、快照验证、远程调度 | Dart 远程传输与同步服务 |
| `src-tauri/src/dpapi.rs`、`settings.rs` | 凭据和设置持久化 | 系统凭据适配层、版本化设置 |
| `src-tauri/src/commands.rs` | 查询、导出、设置、窗口操作入口 | Dart 异步应用服务接口，彻底取消同步阻塞调用 |
| `src/pages/`、`src/components/` | 总览、明细、比较、来源详情、设置、首次引导 | Flutter 页面与组件（含 `RepaintBoundary` 隔离） |
| `src/widget/`、`window.rs`、`lib.rs` | 托盘、快捷键、独立悬浮窗、窗口材质、自启动 | Flutter 桌面平台服务 |
| `.github/workflows/release.yml` | Node/Rust 检查、Tauri 构建、发布与更新签名 | Flutter 检查、Windows 打包与更新链路 |

## 3. 必须保留的数据规则与存储层性能优化

### 3.1 统一事件和 token 口径

统一保留：来源、交互形态、实例、会话、项目、原始模型、归一化模型、提供商、时间、输入、输出、缓存读取、缓存写入、推理、费用和去重键。

总 token 为：

```text
input_tokens + output_tokens + cache_read_tokens + cache_write_tokens
```

推理 token 是输出的分项，不再加一次。Pi 的上游把推理单列在输出以外，解析时须先把推理并入标准输出，随后再使用统一公式。不能对十种来源直接套同一套 JSON 字段映射。

时间统一存储为 epoch 毫秒；页面的“今天”、周、月和日历按本地时间计算。范围使用一致的包含起点、不包含终点规则，覆盖跨日和夏令时场景。

### 3.2 增量、去重、事务与 SQL 索引优化（含防卡顿修复）

- 数据库保持 `(source, instance, dedup_key)` 唯一性，重复扫描不增加已存在的请求。
- 区分不可变事件的忽略式插入，以及流式消息、会话快照的更新式写入。
- 新事件、受影响的汇总和扫描水位放在同一事务提交。写入失败时不推进水位。
- JSONL 只消费完整行，末尾半行留给下次；保存字节偏移、行号及模型、会话、累计计数等解析上下文。
- 正确处理截断、轮转和数据库重建。实现时补充对同尺寸替换等情况的识别，不能只依靠文件大小。
- 更新旧事件时同步修正旧日和新日的汇总；实时速率只接收本次实际增加的 token，不能把整个快照再次计入。
- 单文件失败保留文件级错误和跳过行数。出现权限、锁、未知结构等问题时，来源不能仍显示为完全正常。
- **[性能修复] 日汇总重算必须走时间戳范围索引**：重算 `daily_rollup` 时，严禁使用 `WHERE date(ts_ms/1000, 'unixepoch', 'localtime') = ?1`（会导致 `idx_ev_ts` 索引失效并全表扫描），必须先按本地时区计算该日 `[day_start_ms, day_end_ms)` 毫秒边界，使用 `WHERE ts_ms >= ?1 AND ts_ms < ?2` 命中索引。
- **[性能修复] 补齐复合覆盖索引**：除原有索引外，新增 `CREATE INDEX IF NOT EXISTS idx_ev_src_inst_ts ON usage_events(source, instance, ts_ms)`，使 `source_health` 的 `GROUP BY source, instance` 与 `MAX(ts_ms)` 直接走索引扫描。
- **[性能修复] 优先复用 `daily_rollup` 与单次聚合**：`overview` 中的整日统计（今日、昨日、本周、上周）以及无子维度过滤条件下的 `day`/`week` 粒度 `timeseries`，优先利用 `daily_rollup` 或合并为单次扫描条件聚合，避免每次页面刷新对 `usage_events` 连续执行 6 次全范围扫描。

### 3.3 费用与模型名称

- 来源提供的可靠费用优先；缺失时才按价格表估算。
- 保存费用出处（来源原报 / 价格估算 / 未知），重算时按记录保护原报费用，避免只按整个来源设置保护名单。
- LiteLLM 拉取结果覆盖内置价格快照，不能因刷新把内置独有模型删除；支持离线缓存和手动覆盖。
- 未知模型，或有缓存 token 却缺少对应缓存价格时，保留 `unpriced`，界面展示未计价数量。
- 归一化保留精确匹配、提供商前缀、版本分隔符、日期后缀和别名规则；避免把未知的新型号随意匹配成旧型号。
- 上游内置价格与别名是迁移输入，不视为已验证的现行价格。实施时复核有争议映射，记录价格来源和更新时间。

## 4. 十种来源迁移清单

| 来源 | 原有入口 | Dart 迁移重点 | 关键验证 |
| --- | --- | --- | --- |
| Claude Code | `.claude/projects`、`transcripts` 的 JSONL，Desktop 会话元数据 | 共享转录只计一次；按 message/request 去重；后续流式记录更新先前事件；CLI/Desktop 标签 | 同消息跨两次扫描输出增长；Desktop 元数据只改变标签 |
| Codex | `.codex/sessions`、`archived_sessions` | 累计用量取差值；累计回退重设基线；保留模型/项目/会话上下文；缓存从总输入中拆出；last usage 兼容路径 | 重复累计快照、压缩回退、重启增量、模型切换 |
| Cursor | 本地 `state.vscdb` 凭据、Dashboard / Team API | 本地 token、粘贴 cookie、Team key 三种认证；分页、日期格式、限流、超时、鉴权错误、金额单位 | 多页不丢失；失效凭据不泄漏；无凭据明确提示 |
| Antigravity | `.gemini` 下 IDE / CLI 数据库 | IDE protobuf wire 解码与字段约束；CLI 列名探测；IDE 开关；未知 schema 可见 | 输出等于推理加正文；格式漂移跳过并提示；CLI 快照更新 |
| OpenCode | `opencode*.db`，旧版 message JSON | 优先 message 表，兼容 session 汇总；updated 水位；流式更新；模型/提供商多种布局 | message 与 fallback 不双计；同更新时间边界；旧布局重扫 |
| Hermes Agent | `.hermes/state.db`、profiles | 多 home、profile 与远程快照；session 全表快照更新；真实费用优先于估计 | 会话增长不重复；缺列兼容；不同实例不串数据 |
| OpenClaw | `.openclaw`、`.clawdbot`、`.moltbot` | 发现转录表；SQLite 和 JSONL；旧 message 与新 trajectory；优先 last-call usage | 数据库/归档去重；session 元数据；归档增长与远程同步 |
| Pi | `.pi/agent/sessions` | session/model 状态持久化；assistant、toolResult、compaction、branch summary；推理并入输出；原报 cost | 每种 usage 事件、reasoning 口径、缺 id、增量元数据 |
| Kimi Code | `.kimi-code`、旧 `.kimi` 的 `wire.jsonl` | `usage.record` 只算 turn；旧 StatusUpdate 流式更新；agent/session 键；项目索引 | 忽略 session 累计记录；多 agent 隔离；相同时间戳不冲突 |
| DeepSeek Harness | `.dsh/sessions/session.vN.jsonl.zstd` 等 | 每会话只读最高代；拼接 Zstd 帧及末尾半帧；同 turn/step 替换；retry 新计；compaction 独立计 | 多代不重计；attempt/message 合并；retry 和跨次扫描 fold 状态 |

所有来源保留自定义路径和原有环境变量约定。探测与解析分离，用户指定的目录也要给出明确的有效性和错误状态。

## 5. Flutter 架构与并发防卡顿设计

```text
lib/
  main.dart
  app/                  启动、依赖组装、路由、主题、语言
  domain/               UsageEvent、Filter、Totals、Health、Settings 等
  data/
    collectors/         十种来源、增量读取、protobuf、Zstd
    database/           schema、迁移、事务、查询、rollup
    pricing/            模型名称、价格表、覆盖、重算
    remote/             SSH、主机密钥、代理、快照与同步
    persistence/        设置、凭据、旧版导入
  services/             监听、调度、实时速率、预算、导出
  platform/             窗口、托盘、全局快捷键、自启动、系统材质、更新
  presentation/
    pages/              dashboard、usage、compare、agent、settings、onboarding
    widgets/            玻璃组件、图表、日历、来源状态
    mini/               独立 mini card
assets/                 复用图标、价格快照及必要素材
test/                   脱敏样本、解析和业务回归
integration_test/       桌面关键流程
tool/                   Dart 检查、导出核对及本地构建辅助
windows/                Flutter 标准 runner 与插件注册
docs/                   功能对照、验证记录、接手记录
```

具体分包在依赖审查后确定，避免提前引入多层框架。解析器和计价逻辑尽量不依赖 Flutter，便于独立测试。

### 5.1 后台 Isolate 隔离与事件流防抖（核心防卡顿约束）

1. **UI 主 Isolate 零同步数据库/磁盘 I/O**：
   - 大量日志解析、扫描、入库、重定价以及**所有页面的数据库读查询（`overview`、`timeseries`、`usage_log`、`group_stats`、`source_health`、`filter_options`）、数据导出、目录存在性探测（`detect()`）**均不得在 Flutter UI 主 Isolate 上同步阻塞执行。
   - 数据库连接开启 `PRAGMA journal_mode = WAL`、`PRAGMA synchronous = NORMAL` 与 `busy_timeout`。写操作与重查询放在后台工作 Isolate 中执行（或使用读写分离的后台 Isolate 连接），UI 仅通过异步 Future / Stream 接收序列化后的轻量结果模型。
2. **主窗口与悬浮窗共享单一后台服务**：
   - 主窗口和悬浮窗共享同一份扫描与状态服务；第二个窗口不能启动另一套扫描、远程同步和预算提醒。
3. **实时速率（`LiveRates`）单流推送与今日汇总内存缓存**：
   - 废除原版“前端每 1~2 秒轮询 `get_live_rates` + 后台 `spawn_live_ticker` 重复调用 `tick()`”的冲突设计，统一由后台服务按窗口可见性（mini card 可见时 1s，仅主窗口可见时 2s，全部隐藏时暂停）通过单一 Stream 推送。
   - 今日总 token、今日总费用及预算口径下的今日汇总在内存中缓存并随 `usage-updated` 增量刷新（跨日自动归零重算），严禁在每次 `tick()` 中重复执行 2~3 次 SQLite 聚合查询。
4. **`source-status` 与 `usage-updated` 批量合并防抖**：
   - `scan_all` 或文件监听触发的多来源状态变更在后台服务层做批量合并与防抖（Debounce 300~600ms），避免一次全量扫描触发 10 次连续 UI 刷新。
   - 各来源 `detect()` 的文件系统探测结果在内存中缓存，仅在扫描执行或用户修改自定义路径设置时更新，不在每次 UI 读取健康状态时同步遍历磁盘目录。

依赖按能力选型：SQLite、路径、文件监听、窗口/多窗口、托盘、快捷键、自启动、系统凭据、SSH、Zstd、图表、文件保存。开始实现时检查当前 Flutter/Windows 支持、许可证、维护状况、原生依赖和 release 构建能力，再写入并锁定依赖。

## 6. 桌面与界面功能对照及渲染性能优化

| 功能 | Flutter 目标 |
| --- | --- |
| 总览 | 今日/昨日、本周/上周、选择范围统计；来源占比、趋势、健康状态、未计价提示 |
| 用量明细 | 时间、来源、实例、提供商、模型、文本、未计价筛选；排序、分页和导出 |
| 比较与来源详情 | 来源/模型/提供商/实例/项目维度，来源日历热图、模型与项目分布 |
| 实时统计 | 滑动窗口 RPM/TPM，60 秒火花线，近 5 分钟活跃来源；轮询数据标识 |
| 首次引导 | 来源探测、启用、自定义路径和首次扫描状态 |
| 设置 | 系统/明/暗主题、中英/跟随系统、来源开关、刷新周期、价格覆盖、凭据、远程实例 |
| 预算 | 每日费用/token 上限、限定来源、跨日重置、修改设置后重算提醒状态 |
| 导出 | 按当前筛选完整导出 CSV/JSON、月报 JSON；不能只导出当前分页 |
| 主窗口 | 自定义标题栏、拖动、缩放、最小化、关闭到托盘、恢复与位置持久化 |
| mini card | 独立窗口、紧凑/展开、置顶、拖动、边缘吸附、恢复主窗口 |
| 托盘与快捷键 | 打开、mini card、重扫、退出；默认 Ctrl+Alt+G；更换快捷键释放旧注册 |
| 自启动 | 注册与取消、启动参数、最小化启动 |
| 更新 | 检查可用版本、下载与验证、安装和重启；更换为 Flutter 发行渠道 |

### 6.1 视觉还原与 GPU 渲染防卡顿规范

1. **玻璃材质与 `BackdropFilter` 严格预算**：
   - 视觉继续围绕 GlassUsage 的半透明玻璃、柔和背景和清晰数据展开。基础组件用 Flutter 绘制、模糊、描边和斜向高光渐变实现；提供低效果档和关闭效果选项（`refraction <= 0.01` 时完全关闭模糊/折射滤镜），字体、对比度、焦点、中文布局及 Windows 125%/150% 缩放一并检查。
   - **严禁在滚动列表项、表格行、筛选 Chip、普通小按钮上挂载 `BackdropFilter`**（这些次要表面使用半透明渐变填充 + 高光细边框，开销趋近于零）。
   - 仅主卡片/侧边栏/弹窗在需要时使用模糊，且当窗口材质为 Windows 原生 `Acrylic` 或 `Mica` 时，内部卡片默认不再叠加高斯模糊层，直接透出系统背板或轻度着色。
2. **动态背景（`animatedBackground`）轻量化与生命周期节流**：
   - 动态背景采用预柔和的多重径向渐变（`RadialGradient`）慢速插值绘制，不使用超大尺寸 `ImageFilter.blur(90)` 实时模糊滤镜。
   - 当窗口最小化、隐藏到托盘、切换至 `Acrylic`/`Mica` 或用户关闭动态背景时，立即停止背景 `AnimationController` / `Ticker`，确保后台常驻时 GPU 零空转。
3. **高频交互与局部动画的 `RepaintBoundary` 隔离**：
   - **设置页滑块（折射强度、轮询间隔）**：拖拽过程中（`onChanged`）仅更新滑块自身的局部状态，松手时（`onChangeEnd`）才提交到全局 Settings 并触发持久化，避免拖拽时整页组件树每帧重建。
   - **Mini Card 与顶栏实时组件**：`Odometer`（滚动数字）和 `Sparkline`（火花线）各自使用 `RepaintBoundary` 独立隔离；数值过渡动画仅在目标值变化时按需启动，空闲时停止 Ticker，且仅重绘数字/曲线局部区域。
   - **占比列表（`ShareList`）与图表**：缓存颜色计算结果，不在 build 循环中重复解析；进度条动画优先采用 `FractionallySizedBox` / `Transform.scale` 等低布局开销方式。

不把折射效果的试验放在数据正确性之前，也不因特效不可逐像素复刻而保留浏览器渲染层。需要记录视觉近似与原功能是否等价，避免把“看起来类似”当作所有能力已迁移。

## 7. 远程实例与旧数据

### 7.1 SSH 与快照

- 迁移 Hermes/OpenClaw 实例管理、连接测试、手动同步、周期同步、路径覆盖和归档导入。
- 保留密码、私钥和 SSH agent 三种认证及 HTTP CONNECT 代理。Windows agent 的接入能力须在早期验证；不足时明确记录阻塞，不能默默删去该认证方式。
- 保留服务器主机密钥记录与变更拒绝；清楚展示连接失败的步骤。
- 优先使用远端 SQLite backup 获取一致快照；原数据只读，可创建并清理必要的临时备份文件。
- 无 backup 能力时按原方案处理 DB/WAL 等文件，并在本地进行完整性验证；失败不替换上一份有效快照，也不宣称已得到一致数据。
- 下载先落临时路径，验证后整组替换；保留上次成功快照。限制远程相对路径，避免路径越界。
- 同实例同步不重入，失败有重试与状态；远程数据仍走普通 collector，以 instance 区分。

### 7.2 旧版迁移

原应用主要数据目录为 `%APPDATA%\com.glassusage.desktop`，包括 `usage.db`、设置、价格缓存、远程快照和主机密钥记录。实施前只读检查实际文件，不能假定本机已经安装或已有历史数据。

先制定并验证备份/迁移方案，再读取或接管旧目录：

1. 在旧应用停止写入后备份，或使用 SQLite 在线备份机制，不能只复制正在使用的主 DB 而遗漏 WAL。
2. 在副本中做 schema 版本迁移和金额出处处理。旧记录缺少费用出处时，采用可解释策略并记录无法无损推断的部分。
3. 核对事件数、按来源/token 分项、费用、未计价数量、设置和实例配置。
4. Windows DPAPI 密文需要在同一账户下兼容解密后迁移，或明确提示重新录入；新凭据不以明文写设置、日志或测试样本。
5. 解析器未完全兼容旧水位时，使用独立 Flutter 水位/版本标记重新扫描，并保留稳定去重键；不能直接信任 Rust 的私有状态格式。
6. 保留可恢复副本，防止开发阶段的新程序与旧程序同时改写同一份生产数据库。

## 8. 实施顺序和阶段出口

下列勾选跟踪 `c:\Users\AndyYan\AGV\glassusage` 工作区内的实际交付进度。真实账号、服务器、物理键盘、登录循环与公开签名发行的未验项单列于第 10 节。

### P0：基线和技术可行性

- [x] 保存原版本、功能矩阵与基线对照，将上游源码归档至 `reference/upstream`。
- [x] 检查 Flutter Windows 工具链与构建环境。
- [x] 查阅并锁定依赖，验证多窗口、托盘、快捷键、Windows agent、DPAPI、Zstd 拼接帧和更新签名实现。
- [x] 确定旧数据迁移及新发行包标识，避免 Flutter 应用误装 Tauri 更新包。

出口：有可执行的依赖方案和明确的风险结果；系统能力不存在隐藏的旧后端依赖。

### P1：Flutter 工程与领域/存储层（含 SQL 索引与后台 Isolate 架构）

- [x] 在根目录建立 Flutter Windows 工程，保留 `reference/upstream` 供逐项对照。
- [x] 实现领域类型、schema 版本（含 `idx_ev_src_inst_ts` 复合索引）、事务写入、去重、更新、扫描状态和来源健康。
- [x] 修复 `daily_rollup` 重算的范围索引查询（`ts_ms >= ?2 AND ts_ms < ?3`）并优化 `overview`/`timeseries` 聚合查询。
- [x] 实现计价与费用出处，接入内置价格资源。
- [x] 以临时数据库验证重扫、回滚、汇总更新与未知价格。

出口：脱离界面可完成“事件 → 入库 → 汇总 → 查询”，失败不会丢水位，且无全表扫描慢 SQL。

### P2：Claude / Codex 贯通与后台 Isolate 调度

- [x] 实现共享增量读取器、解析状态、目录探测缓存和自定义路径。
- [x] 迁移 Claude、Codex，并完成重复、流式、差分、回退、截断和重启用例。
- [x] 接入后台扫描/数据库 Isolate、文件监听、事件合并防抖（`source-status` / `usage-updated`）与兜底轮询。
- [x] 在可用的本机日志上只读核对，避免输出对话正文。

出口：Claude/Codex 样本端到端回归通过，后台扫描与数据库读写均在独立 Isolate 执行，不阻塞 UI 线程。

### P3：全部本地采集器

- [x] 依次迁移 Hermes、OpenCode、OpenClaw、Pi、Kimi。
- [x] 迁移 Antigravity protobuf/CLI 与 DeepSeek Harness Zstd/fold。
- [x] 接入 Cursor 认证、分页、同步和错误状态。
- [x] 每来源用固定脱敏样本核对事件键、token 分项、费用与增量结果。

出口：十种来源均有可检查实现；无真实数据的来源标记“样本已验证 / 实机待验证”。

### P4：完整 Flutter 主界面（含毛玻璃预算与重绘隔离）

- [x] 构建视觉基础组件（受控模糊预算、停帧节流的动态背景、局部状态滑块）和主导航，接入真实后台服务。
- [x] 完成总览、明细、比较、来源详情、日历、设置和首次引导。
- [x] 实现筛选、分页、导出、月报、价格覆盖和中英主题切换。
- [x] 为扫描中、无数据、未安装、关闭、权限不足、解析失败、未计价提供可操作提示。

出口：主界面所有功能来自真实数据或明确空状态，滑块拖拽、图表切换和列表滚动流畅无卡顿。

### P5：桌面常驻与独立 mini card

- [x] 接入托盘、关闭隐藏、退出、单实例、自启动和窗口位置持久化。
- [x] 实现独立悬浮窗、紧凑模式、置顶、吸附与全局快捷键。
- [x] 主窗口与悬浮窗复用后台状态与单一 `LiveRates` 推送流（内存增量维护今日汇总），`Odometer` 与 `Sparkline` 独立 `RepaintBoundary` 隔离。
- [x] 接入实时速率和预算提醒，核对多窗口不重复提醒。

出口：关闭主窗口后继续采集；mini card 可独立使用且低 CPU/GPU 占用；真正退出后进程与快捷键释放。

### P6：远程实例和旧数据迁移

- [x] 完成远程实例表单、凭据、主机密钥、代理、连接诊断与调度。
- [x] 实现一致快照、校验、替换与失败保留机制。
- [x] 迁移旧 DB/设置/价格/实例/凭据，并核对汇总差异。

出口：远程样本验证通过；具备可用服务器时完成真实连接与同步。无测试服务器时保留待验记录。

### P7：Windows 发布、更新与旧栈清理

- [x] 替换 CI（`.github/workflows/ci.yml`）、Release（`.github/workflows/release.yml`）与本地构建入口，生成 Windows release（`build\windows\x64\runner\Release\glassusage.exe`）、便携版 `.zip` 与 NSIS 安装包（`windows/installer/glassusage.nsi`）。
- [x] 隔离旧 Tauri 更新资产（不再发布 `latest.json` Tauri updater manifest，提供 `SHA256SUMS.txt` 校验）。
- [ ] 验证安装、启动、重装及卸载保留数据。
- [x] 确认原 `src/`、`src-tauri/`、npm/Vite/TS 配置与旧生成脚本已完整归档到 `reference/upstream`，原素材已迁移到 Flutter assets，旧栈不参与构建。
- [x] 保留 LICENSE 与必要署名，更新 `docs/MIGRATION_STATUS.md`。

出口：从干净检出可以仅使用 Flutter/Dart 和 Windows 常规构建/打包工具产出应用；运行时不需要 Node、Rust、Tauri 或 WebView2。

## 9. 验收与证据要求

### 数据正确性

- 同一输入连续扫描、重启后扫描、清水位重扫，最终统计一致。
- 事务失败不能造成后续跳读；半行和半帧补齐后只入库一次。
- 覆盖每来源有意义的去重/更新路径，并比较 token 分项、金额和未计价数量。
- 今天、周/月边界、时区和模型切换结果可解释；筛选后图表、明细和导出范围一致。
- 上游已有单元测试作为输入线索迁移，另覆盖迁移新增的边界。

### Windows 实际交互与性能防卡顿验证

- `flutter analyze`、必要的 Dart/Flutter 测试、Windows release 构建通过。
- 真正启动 release 应用，检查主页面、数据刷新、图表、设置保存与错误状态。
- 检查托盘、快捷键、自启动、关闭隐藏、独立悬浮窗、多屏/缩放、预算和退出。
- **性能与流畅度验证**：
  - 使用大样本观察后台扫描入库时主界面拖拽、页面切换、筛选响应，确认 UI 主 Isolate 无同步 SQLite 阻塞掉帧；
  - 验证设置页连续快速拖动折射率/轮询滑块时无全局组件树重建卡顿；
  - 验证窗口最小化/隐藏到托盘时动态背景与实时速率 Ticker 正确暂停降频。
- 网络不可用、Cursor 凭据失效、数据库锁住、SSH 失败、未知 schema 均有明确状态。

构建成功、启动成功、样本通过、真实来源验证、安装升级验证分别记录。缺少真实来源、凭据、服务器或签名密钥时，明确哪些能力尚未实机覆盖，不能据此宣布完整迁移已验收。

## 10. 接手与后续验收

实现过程中持续维护 `docs/MIGRATION_STATUS.md`：记录当前阶段、已改模块、功能对照、执行过的验证、失败原因、剩余问题和下一条可执行动作。发生中断后先读本计划和该状态文件。

开始前需延续的默认决策：Windows 优先；全部原功能仍在范围内；允许 Flutter 插件/系统库；保留玻璃视觉方向并落实防卡顿预算；旧数据先备份再迁移；价格、插件 API 和发布能力实施时重新核实。

当前状态：

- [x] 仓库已拉取至 `c:\Users\AndyYan\AGV\glassusage`。
- [x] 完成原项目 UI 卡顿根因分析，并将 Isolate 异步查询、SQL 索引修复、事件流合并防抖、模糊合成预算与局部重绘隔离纳入本计划。
- [x] 归档上游源码至 `reference/upstream`，初始化 Flutter Windows 工程并完成 P0 → P7 核心代码实现、全量测试（16/16）与 Windows Release 构建。
