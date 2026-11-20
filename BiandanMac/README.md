# 便单 for macOS（BiandanMac）

SwiftUI 原生客户端，macOS 14+，本地缓存用 SQLite（GRDB.swift）。用华为账号登录后自动续期，读写便单云端的四张同步表（favorites / Task / showTask / tomato）。设计与规划见 [../docs/macos/plan.md](../docs/macos/plan.md)，UI 原型见 [../docs/macos/ui-prototype.html](../docs/macos/ui-prototype.html)。

当前进度：**P0–P4**。
- P0–P3：工程骨架、编解码、登录续期、只读同步、列表 / 四象限 / 日历 / 检查器 / 专注记录 / 设置。
- P4：写入。包括完成、撤销、放弃、恢复、勾选子任务、记次数；新建一次性任务；编辑标题、备注、分类、时间、提醒、地点和完成目标；删除前可预览影响范围；四象限拖动；待办单的新建、编辑、删除和排序。
- P5：重复任务。新建时可设重复（8 种方式、自定义周 / 月 / 年 / 农历、工作日筛选、持续天数、习惯）；编辑重复规则前预览新增 / 改期 / 移除 / 保留的实例数；只改某一次（脱离系列）；一次性任务可设为重复。
- 下一步 P6：专注记录的补记、编辑、删除。

## 界面主题

所有页面统一沿用四象限主界面的风格，规范见 [DESIGN.md](DESIGN.md)，组件在 `App/ThemeKit.swift`。新增页面必须按这份规范来做。

## 打开与运行

1. 用 Xcode 打开 `BiandanMac/Package.swift`，首次打开会自动拉取 GRDB。
2. 选择 scheme `BiandanMac` 和 `My Mac`，按 ⌘R 运行。
3. 点「使用华为账号登录」后，App 会在 `127.0.0.1:42681` 等待授权回调。浏览器里完成华为授权，回到 App 后会自动进行首次全量同步。

> 端口 42681 和 Python 版便单 MCP 的授权回调端口相同。登录前请先关闭正在等待授权的 MCP。另外，App 和 MCP 不要共用同一份凭据。

## 测试

```bash
# 1. 用 Python 参考实现重新生成黄金用例（需要 Python 3.10+；3.9 会自动兼容处理）
python3 Tools/gen_golden.py

# 2. 运行单元测试（也可以在 Xcode 里按 ⌘U）
swift test
```

- `GoldenTests`：循环实例 ID、taskContent 编解码、重复规则编码、实例窗口展开、进度计算、表单编码、PKCE，逐项和 Python 参考实现对比。
- `CoreTests`：日期、农历、颜色、目标、提醒位、专注 log、记录归一化。
- `StoreTests`：SQLite 差异合并、云端多出的未知字段保留、快照查询、侧栏计数。

## 目录

```
Sources/BiandanMac/
├─ Core/     JSONValue、LocalDate、BusinessID、Codecs、Models、Recurrence、LunarCalendar
├─ Auth/     OAuthFlow（PKCE、回环监听、换码）、TokenProvider（钥匙串、续期）
├─ Cloud/    HTTPTransport、SyncAPIClient
├─ Store/    LocalStore（GRDB）、DataSnapshot（内存查询）
├─ Sync/     SyncEngine（只读全量拉取）
├─ App/      BiandanApp、AppModel、Theme
└─ Views/    登录、侧栏、四象限、列表、日历、检查器、专注记录、设置
Tests/BiandanMacTests/   单测 + Fixtures/golden.json
Tools/gen_golden.py      黄金用例生成脚本
```

## 数据位置

- 本地数据库：`~/Library/Application Support/BiandanMac/biandan.sqlite`
- 华为凭据：钥匙串，服务名 `ai.racore.BiandanMac`，账户名 `huawei-refresh-<续期地址哈希>`
