# 便单 for macOS：UI 设计与接入规划 v0.1

> 依据：发布仓库 README、`docs/developers/*.md`，以及 Python 参考实现 v0.4.2（`biandan_cloud / renewal / recurrence / tools / mcp / http`，约 2700 行）。
> 目标：原生 SwiftUI 应用，用本地 SQLite 缓存数据，用华为账号登录并自动续期，四张同步表的所有字段都能读写。
> UI 原型：[ui-prototype.html](ui-prototype.html)，用浏览器打开即可查看。

---

## 0. 范围

| 项 | 是否包含 | 说明 |
| --- | --- | --- |
| `favorites` 待办单 | ✅ | 新建、改名、改颜色、排序、删除（任务移回默认 / 连同任务一起删除） |
| `Task` 待办定义 | ✅ 26 个字段全部接入 | 编辑器分区覆盖所有字段，云端 ID、版本等只读信息放在「高级」区 |
| `showTask` 执行实例 | ✅ 9 个字段全部接入 | 完成、撤销、放弃、恢复、设置次数、勾选子任务、改期本次 |
| `tomato` 专注记录 | ✅ 只做记录管理 | 列表、补记、编辑（标题、好坏番茄数）、删除、按日期汇总。**不做番茄钟计时器** |
| 习惯打卡视图 | ❌ | 不单独做打卡日历。`isLoop=2` 只在重复规则里作为「标记为习惯」开关 |
| 本机 MCP 服务 | 可选（P7） | 应用可以接替 Python MCP 提供 `127.0.0.1:42682/mcp`，让 AI 客户端继续使用 |

---

## 1. 信息架构

```
┌ 主窗口（NavigationSplitView 三栏）──────────────────────────────────────┐
│ 侧栏                 │ 内容区                        │ 检查器（可收起）    │
│ ─ 账户卡/同步状态    │ 标题 + 日期 + 农历            │ 选中任务的全字段     │
│ 视图                 │ [列表|四象限|日历] [近1天▾] + │ 基本 / 时间 / 重复  │
│  今天 · 近7天 · 全部 │ 快速添加栏 ⌘N                 │ 完成目标 / 提醒     │
│  四象限 · 日历       │                               │ 执行实例            │
│  无日期 · 收藏       │ （按视图切换）                │ 高级（只读）        │
│  已完成 · 已放弃     │                               │                     │
│ 待办单（可拖动排序） │                               │                     │
│ 记录：专注记录       │                               │                     │
└──────────────────────┴───────────────────────────────┴─────────────────────┘
```

- **列表视图**：按日期分组（逾期、今天、明天、之后、无日期），每行一个执行实例（showTask）。
- **四象限视图**：沿用截图的配色。卡片拖到其他象限时，改写 `isImportant` 和 `isUrgency`。时间范围可选近 1、3、7 天或全部。
- **日历视图**：月视图和周视图，显示实例的起止跨度。拖动改期：一次性任务调用 reschedule_task，重复实例调用 reschedule_occurrence（脱离系列）。
- **检查器**：编辑的是任务定义。底部的「执行实例」区针对当前选中的那一次。
- **其他窗口和弹窗**：登录欢迎页、新建任务弹窗、重复规则弹窗（带影响预览）、待办单编辑、删除确认（带预览）、专注记录表、设置（账户、同步、日历、MCP、高级）、菜单栏小组件（今天的待办，可选）。

交互约定：
- 点圆圈完成当次；如有子任务或次数目标，一次全部补齐，等同于 complete_occurrence。
- 删除重复任务时必须选择范围：仅本次、本次及之后未完成的、整个系列。确认前先展示预览结果。
- 所有破坏性操作支持 ⌘Z。撤销时调用反向业务操作（如 reopen、restore），不做本地回滚。

---

## 2. 字段与 UI 对照（共 44 列）

### Task（26）

| 字段 | UI 控件 | Swift 表示 | 编解码要点 |
| --- | --- | --- | --- |
| `id1` | 高级区，只读 | `BizID`（String） | 新建时按 `time_ns/1000` 生成；重试同一次创建时复用 |
| `taskTitle` | 标题输入框 | `String` | 不能为空 |
| `taskContent` | 备注、子任务列表、附件（只读） | `TaskContent{remark, subtasks, attachments}` | 嵌套 JSON 数组；改备注时保留子任务和附件 |
| `id3` | 待办单选择器 | `BizID` | 值 ≤1 时归为 1 |
| `isCollectible` / `isImportant` / `isUrgency` | 开关，四象限拖动 | `Bool` | 0/1 |
| `startTime` / `endTime` | 日期选择 | `LocalDate?` | `YYYY-MM-DD` |
| `validStartTime` / `validEndTime` | 时刻选择 | `LocalTime` | `HH:mm:00` |
| `haveNoTime` | 「无指定时间」开关 | `Bool` | 开启时日期写成 1970-01-01 ~ 2100-12-31 |
| `isLoop` | 重复类型：不重复 / 重复 / 习惯 | `enum LoopKind` | 0/1/2，≥2 视为习惯 |
| `loopSet` | 重复预设 | `enum LoopSet` (0–8) | |
| `loopBaseNumber` | 间隔「每 N」 | `Int` | 1–366 |
| `loopUnit` | 单位 + 日期筛选 | `LoopUnit{unit, filter}` | `unit + 100×filter` |
| `loopDate` | 星期、日号、MM-DD 选择器 | `[String]` | 逗号分隔，含义取决于单位 |
| `duration` | 每次持续天数 | `Int` | 周期型预设忽略此值 |
| `unitTimeNumber` | 目标：次数 1–99 或子任务 | `Goal.count(n) / .checklist(mask)` | 值 ≥100 时为 位掩码×100 |
| `isRemind` | 时间提醒、地点提醒两个开关 | `OptionSet RemindFlags` | 位 0 是时间提醒，位 1 是地点提醒；改一项时保留另一项 |
| `remindDate` / `remindTime` | 提醒日期时刻 | `LocalDate` / `LocalTime` | 关闭提醒后仍保留原值 |
| `isFinish` | 高级区，只读 | `Bool` | 由 reconcile 汇总计算 |
| `latitude` / `longitude` | 地图选点（MapKit） | `Coordinate?` | 未设置时为 `-1, -1`；坐标系 GCJ-02 |
| `location` | 地点名称 | `String` | |

### showTask（9）

| 字段 | UI | 说明 |
| --- | --- | --- |
| `id2` | 高级区 | 重复实例 ID = `2^51 + sha256("task:date")[:8] mod 2^51`；一次性任务的实例 ID 等于 id1 |
| `id1` | 隐式关联 | 改期本次时重挂到脱离系列后的新任务 |
| `startTime` / `endTime` / `validStartTime` / `validEndTime` | 实例行、改期本次 | |
| `completedCount` | 进度条、子任务勾选、设置次数 | `-1` 表示已放弃；子任务模式下为 位掩码×100 |
| `recentFinishedTime` | 「完成于」 | `YYYY-MM-DD HH:mm:00` |
| `isFinish` | 圆圈状态 | 进度 ≥ 目标时为 1 |

### favorites（3）

| 字段 | UI | 说明 |
| --- | --- | --- |
| `id3` | — | 1 留给「默认」，不可删除、不可编辑 |
| `favoritesName` | 名称 | |
| `favoritesColor` | 24 色色板 + 侧栏拖动排序 | `sort×100 + color` |

### tomato（6）

| 字段 | UI | 说明 |
| --- | --- | --- |
| `time` | 开始时间（主键，毫秒） | 补记时由开始时间生成 |
| `date` | 日期列、按日汇总 | |
| `minutes` | 分钟 | 1–1440，向下取整 |
| `goodCount` / `badCount` | 好番茄、坏番茄 | ≥0 |
| `log` | 关联事项、标题 | JSON `{eventId, eventTitle, eventType, endTime}`，兼容旧的纯文本 |

> 为了确保「全字段」不丢数据：本地每条记录都会保存原始 `attributes` JSON。PATCH 时以原始 JSON 为底再合并改动，云端多出来的未知字段也会原样保留（与 Python `update()` 的做法一致）。

---

## 3. 架构

```
BiandanMac (SwiftUI App, macOS 14+)
├─ BiandanCore        纯逻辑，无 I/O，可单测
│   Models/  TaskDef, Occurrence, TodoList, FocusRecord, RawRecord
│   Codecs/  TaskContentCodec, ListColorCodec, GoalCodec, RemindFlags, LoopUnitCodec, FocusLogCodec
│   Recurrence/  RuleEncoder, RecurrenceWindows, LunarCalendar(LUNAR_YEARS), ChinaMakeupDays
│   IDs/  BusinessID, OccurrenceID(CryptoKit SHA256)
├─ BiandanAuth
│   PKCE, AuthorizeURLBuilder, LoopbackReceiver(NWListener 127.0.0.1:42681)
│   TokenExchange(oauth2/v3/token), RenewalClient(/v1/device, /v1/refresh)
│   CredentialStore(Keychain，refresh_token 和 device_grant 存成一项，原子写)
│   TokenProvider(actor：合并并发刷新，401 后按 rejected token 再刷新一次)
├─ BiandanCloud
│   SyncAPIClient(URLSession，禁止重定向，25s 超时，trace-id，x-hw-* 请求头)
│   list/get/create/update/delete，记录归一化（records/recordList, recordID/id, fields 包装）
├─ BiandanStore       SQLite（GRDB.swift）
│   四张业务表 + outbox + sync_meta，迁移管理
├─ BiandanService     移植 BiandanTools 的业务操作（create_task, update_recurrence, update_progress…）
├─ BiandanSync        SyncEngine(actor)：全量拉取、差异合并、命令队列重放、冲突处理
├─ BiandanMCP (可选)  本机 Streamable HTTP MCP，复用 Service 和 TOOLS schema
└─ App/  @Observable ViewModels + Views（Sidebar, QuadrantView, ListView, CalendarView, Inspector, Sheets, Settings）
```

### 3.1 Python → Swift 对照

| Python | Swift | 要点 |
| --- | --- | --- |
| `biandan_cloud.request_json` | `HTTPTransport` | 禁止跟随重定向（`URLSessionTaskDelegate` 返回 nil）；只有 401 且响应体 `error==reauthorization_required` 时识别为需要重新授权；响应带 `errors`/`error` 时按失败处理 |
| `exchange_authorization` | `OAuthFlow` | verifier 用 48 字节随机数做 base64url；`state = "biandan-local-v1." + 32 字节随机数`；`access_type=offline`；换码时 `redirect_uri` 填官网地址 |
| `receive_loopback_code` | `LoopbackReceiver` | 校验 Host 头、`/biandan/callback` 路径和 state（常量时间比较），180 秒超时，响应加 `no-store` 和 `no-referrer` |
| `RenewingAuthorization` | `TokenProvider` actor | `expires_at = now + expires_in - min(60, expires_in/10)`；首次走 `/v1/device`，之后带 `Bearer device_grant` 调 `/v1/refresh`；收到 `reauthorization_required` 时清除凭据并重新登录；令牌只接受 ASCII 33–126、长度 ≤4096 |
| `RefreshTokenStore` + 文件锁 | Keychain + 单实例 | 用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |
| `BiandanCloud.request` | `SyncAPIClient` | 基址 `https://driveapis.cloud.huawei.com.cn/sync/v1/rongqi`；请求头 `x-hw-sync-env: dataSync2DP`、`x-hw-app-version: 16.3.0.001`、`x-hw-trace-id: 07200_02_<ms>_<8位随机>` |
| `biandan_recurrence` | `RecurrenceWindows` | 原样移植，包括 JS `setDate` 溢出行为、艾宾浩斯偏移 `0,1,2,4,6,14,29+15k`、week_start、周期型预设边界、上限 1000 条 |
| `biandan_tools.BiandanTools` | `BiandanService` | 业务语义完全对齐：ensure_record 写后读回校验、patch 后确认、reconcile 汇总、改期本次时脱离系列（`derived_id(occ,"detached")`） |
| `biandan_http` + `biandan_mcp` | `BiandanMCP`（可选） | 只监听 127.0.0.1；校验 Host/Origin 和 Bearer 本机密钥；工具 schema 复用 `--list-tools` 的输出 |

### 3.2 华为登录流程

1. 用户点「使用华为账号登录」后，应用启动 `NWListener` 监听 `127.0.0.1:42681`，再用 `NSWorkspace.open` 在系统浏览器打开授权页。
   - 不能用 `ASWebAuthenticationSession`：最终回调是 http 回环地址，经官网中转后才到本机。
2. 浏览器经官网跳回 `http://127.0.0.1:42681/biandan/callback?code&state`。应用校验后返回「已收到授权，可以关闭本页」，并把应用窗口切回前台。
3. 用 code 换令牌，拿到 `access_token` 和 `refresh_token`，再调 `/v1/device` 取得 `device_grant`。凭据写入钥匙串。
4. 之后每次启动都静默续期，不再弹出授权页。只有收到 `401 reauthorization_required` 时才回到登录页。
5. 账户卡显示的昵称和头像：如果令牌响应里带 `id_token`，就从中解析，需要实测确认；拿不到时显示「华为账号」。
6. 退出登录时清除钥匙串和本地 SQLite，提供可选项「保留本地缓存」。

沙盒权限（entitlements）：`com.apple.security.network.client` 和 `com.apple.security.network.server`。

### 3.3 SQLite 结构（示意）

```sql
CREATE TABLE task (
  cloud_id TEXT PRIMARY KEY, version INTEGER, created_time TEXT, edited_time TEXT,
  id1 TEXT UNIQUE NOT NULL, task_title TEXT, task_content TEXT, id3 TEXT,
  is_collectible INT, is_important INT, is_urgency INT, start_time TEXT, end_time TEXT,
  is_loop INT, have_no_time INT, unit_time_number INT, valid_start_time TEXT, valid_end_time TEXT,
  loop_set INT, loop_base_number INT, loop_unit INT, loop_date TEXT, duration INT,
  is_remind INT, remind_date TEXT, remind_time TEXT, is_finish INT,
  latitude REAL, longitude REAL, location TEXT,
  raw_attributes TEXT NOT NULL            -- 原始 attributes，PATCH 时以此为底
);
CREATE TABLE show_task (cloud_id TEXT PRIMARY KEY, version INT, ..., id2 TEXT UNIQUE, id1 TEXT, ...);
CREATE INDEX show_task_by_task ON show_task(id1);
CREATE INDEX show_task_by_date ON show_task(start_time, end_time);
CREATE TABLE favorites (cloud_id TEXT PRIMARY KEY, version INT, ..., id3 TEXT UNIQUE, favorites_name TEXT, favorites_color INT, raw_attributes TEXT);
CREATE TABLE tomato (cloud_id TEXT PRIMARY KEY, version INT, ..., time TEXT UNIQUE, date TEXT, good_count INT, bad_count INT, minutes REAL, log TEXT, raw_attributes TEXT);
CREATE TABLE outbox (           -- 业务命令队列（不是记录级队列）
  op_id TEXT PRIMARY KEY, command TEXT, args_json TEXT, created_at TEXT,
  attempts INT DEFAULT 0, last_error TEXT, state TEXT -- pending/running/failed/needs_user
);
CREATE TABLE sync_meta (kind TEXT PRIMARY KEY, last_pull_at TEXT, record_count INT);
```

### 3.4 同步策略

云端**没有增量接口，也没有推送**，所以采用「全量拉取 + 按版本对比」：

- **拉取**
  - 时机：启动、窗口激活、每 5 分钟、每次写入后、手动点「立即同步」。
  - 做法：四张表各自分页拉取，每页 100 条；游标重复时中止，并标记本次结果不完整。
  - 比对：按 `cloud_id` 和 `version` 对比，只更新有变化的行。
  - 删除：本地有、云端没有、且没有待处理命令的记录，按已删除处理。拉取不完整时不做删除判定。
- **写入**
  - 方式：云端为准，按命令执行，与 Python 一致。UI 先乐观更新，再执行 `BiandanService` 的业务命令（写入→读回校验），完成后刷新相关记录。
  - 离线或失败：命令进入 outbox，用**原业务 ID**重放，相当于 Python 的 `operation_id`，保证幂等。
  - 顺序：同一任务的命令串行执行；全局最多 1 个写入命令并发，与 Python HTTP 模式的全局锁一致。
- **冲突**
  - 收到 409 或版本不匹配：重新读取，把本次改动的字段合并上去再重试。
  - 同一字段云端也改过时，以云端为准，并在界面提示「已被其他设备修改」。
- **凭据唯一**：同一份凭据只能由一个进程管理。**不要让应用和 Python MCP 共用凭据**。如果需要 AI 接入，用 P7 的内置 MCP。

---

## 4. 实施阶段

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P0 | Xcode 工程、SPM 模块骨架、GRDB、CI 跑单元测试 | 能编译，空界面能运行 |
| P1 | Core 编解码、循环规则、农历、ID 算法 | **黄金用例**：用 Python 模块生成几百组输入输出 fixtures，Swift 结果逐项一致 |
| P2 | Auth：PKCE、回环监听、换码、续期、钥匙串 | 首次登录 → `/about` 返回 200 → 重启后静默续期 → 撤销授权后正确回到登录页 |
| P3 | 云端客户端 + 只读同步进 SQLite + 列表、四象限、日历只读 | 测试账号的数据和鸿蒙端一致 |
| P4 | 写入：待办单 CRUD，任务新建、编辑、移动、改期、提醒、地点、目标、完成 | 每个操作在手机便单上能看到同步结果 |
| P5 | 循环：新建、修改规则（含预览）、删除范围、改期本次 | 规则影响预览的计数与 Python `preview` 一致 |
| P6 | 专注记录列表、补记、编辑、删除、汇总 | |
| P7（可选） | 内置 MCP 服务（42682，与 Python 版工具同名同 schema） | Claude、Codex 等用原配置即可连上应用 |
| P8 | 菜单栏组件、快捷键、本地通知（时间提醒）、签名公证 | |

---

## 5. 风险与待确认

1. **接口不是公开 API**：沿用便单 Web 客户端 ID、官网中转和续期服务。`x-hw-app-version` 如果被服务端校验，需要跟随版本更新。正式发布前要和便单官方确认是否允许。
2. **端口 42681**：和 Python MCP 的授权回调端口相同。两边同时发起登录会冲突，应用需要检测端口占用并给出提示。
3. **调休数据只到 2026 年**：今天已经是 2026-11。2027 年的「工作日/休息日 + 中国调休」规则需要补数据，建议改成可远程更新的 JSON。
4. **GCJ-02 坐标**：MapKit 在国内返回的坐标需要实测，确认是不是 GCJ-02，避免地点提醒偏移。
5. **全量拉取的开销**：任务和实例多（比如几千条）时，每次同步要请求几十次。需要设置节流，并做分表的增量合并。
6. **时间提醒**：云端只存字段，Mac 端是否用 `UNUserNotificationCenter` 本地提醒，由我们自己决定（P8）。
