# 便单 for macOS 界面主题规范

**所有页面统一沿用四象限主界面的风格。** 新增窗口、弹窗、设置页、面板时都按这份规范来做，不要另起一套样式。实现组件在 [Sources/BiandanMac/App/ThemeKit.swift](Sources/BiandanMac/App/ThemeKit.swift)，颜色定义在 [Sources/BiandanMac/App/Theme.swift](Sources/BiandanMac/App/Theme.swift)。

## 颜色

| 用途 | 取值 |
| --- | --- |
| 页面背景 | `Theme.background` `#F4EFE3` 暖米色 |
| 面板 / 标题栏 / 底栏 | `Theme.panel` `#FBF8F1` |
| 卡片 | `Theme.card` `#FFFDF8`，描边 `Theme.line` `#E6DFCF`，行分隔线 `#F0EADD` |
| 正文 / 次要文字 / 字段名 | `Theme.text` / `Theme.subtext` / `Theme.fieldName` |
| 强调色（主按钮、开关、选中） | 只用 `Theme.accent` `#F5B800` 黄色 |
| 多选底色 | `Theme.selectionFill` `#FFF4CC`，配合 `Theme.accent` 2pt 描边 |
| 危险操作 | `Theme.overdue` `#D93025` |
| 和象限相关的颜色 | 只用 `Quadrant.tint`（边框）/ `.fill`（底色）/ `.titleColor`（文字） |

四象限颜色：重要且紧急 红 `#E5483A`；重要但不紧急 黄 `#E9BC12`（文字 `#D9A800`）；不重要但紧急 蓝 `#4BA9E0`；不重要且不紧急 绿 `#5DB65A`。

## 形状与字体

- 卡片圆角 10，大块区域（象限、日历格子）圆角 14，输入框和按钮圆角 8。
- 页面标题用 heavy 粗体（弹窗 20pt，主界面 26pt）；分区标题 11pt semibold、`Theme.subtext`；正文 12.5–13pt。
- 云端字段名用 `FieldTag`，受「设置 → 高级 → 显示云端字段名」控制。

## 组件（直接组合，不要自己重写）

| 场景 | 组件 |
| --- | --- |
| 弹窗 | `ThemedSheet(title, subtitle:, tag:, headerFill:, titleColor:) { 内容 } footer: { 按钮 }`。和某个象限相关时，`headerFill` / `titleColor` / `tag` 用该象限的颜色 |
| 分区卡片 | `InspectorSection("标题") { … }` |
| 表单行 | `ThemedRow("标签", field: "云端字段") { 控件 }` |
| 开关 | `ThemedSwitch(isOn:)` |
| 分段选择 | `ThemedSegmented(selection:, options:)`，与「列表 / 四象限 / 日历」一致 |
| 单选列表 | `ThemedChoiceList(selection:, options:)` |
| 选择象限 | `QuadrantPicker(selection:)` |
| 选择日期 | `ThemedDateField(date:, minimum:, tint:)`：月历面板含快捷日期、农历、节假日「休 / 班」 |
| 选择时刻 | `ThemedTimeField(time:, tint:)`：常用时刻 + 小时 / 5 分钟网格 |
| 选择待办单 | `ThemedListPicker(selection:)` |
| 输入框 | `TextField(...).themedField()` |
| 按钮 | `.buttonStyle(.themedPrimary)` 主操作 / `.themed` 次要 / `.themedDestructive` 删除 |
| 错误提示 | `ThemedErrorText(message:)`；全局写入失败用底部 `OperationBanner` |
| 设置窗口 / 多分区窗口 | 左侧 `Theme.panel` 侧栏（彩色图标块 + 标题，选中为白卡片）+ 右侧米色内容区，每页顶部是彩色图标 + heavy 标题 + 说明；分区颜色用四象限色。参考 SettingsView.swift |
| 概览大卡片 | 顶部 `QuadrantStrip` 色带 + 头像或状态图标 + heavy 标题 + `StatusPill`，下方一排统计（参考设置 → 账户、同步） |
| 点击弹出的菜单 | 按钮 + `.popover`，内容用 `ThemedMenuRow` 分组放进 `.themedCard()`（参考 AccountMenu.swift 的账户面板） |
| 确认操作 | `ThemedSheet` 弹窗（参考 `SignOutSheet`、`DeleteTaskSheet`、`BatchDeleteSheet`） |
| 多选与批量操作 | ⌘ 点击卡片调用 `model.tapSelect(item)`；有多选时内容区底部浮出 `BatchActionBar`（白卡片 + 黄色描边，按钮用 `.themed` / `.themedDestructive`，二级选项用 `.popover` + `ThemedMenuPanel`）。整批修改在 `AppModel+Batch.swift` 里合并成一步撤销 |
| 数值加减 | 系统 `Stepper` 可以用，标签文字自己放 `Text` 并用主题字体 |
| 浮动输入面板 | 参考 `GlobalQuickAddPanel.swift`：不抢焦点的 `NSPanel`，内容是白卡片（圆角 14，`Theme.accent` 描边），Esc 或点外面关闭 |
| 悬停浮层 | 鼠标移上去要显示可点击的说明时，用 `.hoverPopover { close in … }`（HoverPopover.swift）：稍停弹出、移开收起，背景 `Theme.card`；不要用系统 `.help` 提示做大段说明 |
| 统计卡片与图表 | 概览一排统计同习惯页（heavy 数字 + 11pt 说明）；图表放进白卡片（圆角 12，`Theme.line` 描边），用 Swift Charts `BarMark`，颜色只用 `Theme.accent` 或 `Quadrant.tint`；比例条用分类色板 `list.swatch`。参考 StatsView.swift |
| 键盘操作 | 主窗口按键统一在 `MainKeyMonitor` 处理；新增任务视图时，把它的显示顺序接进 `AppModel.keyboardOrder`，卡片点击调用 `model.tapSelect(item)` |
| 右键菜单 | `.themedContextMenu(onOpen:) { close in ThemedMenuPanel { ThemedMenuGroup { ThemedMenuRow … } } }`，二级选项直接平铺（`QuadrantMiniGrid`、`ThemedMenuListRow`），不做子菜单；破坏性操作单独一组。见 ThemedContextMenu.swift |

## 浏览器里的页面

App 自己返回给浏览器的 HTML 页面也要遵守这套主题，比如华为授权回调页 [AuthCallbackPage.swift](Sources/BiandanMac/Auth/AuthCallbackPage.swift)。参考 [docs/macos/ui-prototype.html](../docs/macos/ui-prototype.html)：

- 用上面同一组颜色，声明 `color-scheme: light`，浏览器是深色模式也保持米色背景。
- 居中放一张白卡片：顶部 6px 四象限色带，下面是「便」字渐变 logo、状态标签、heavy 标题、次要说明；有步骤时用编号列表，完成的步骤用绿色，进行中的用黄色。
- 页面只放固定文案，不拼接 URL 参数。默认不写脚本，返回时带严格的 CSP。
- 需要实时更新的页面（例如登录进度）只允许一段带 nonce 的内联脚本：只连本机（`connect-src 'self'`），轮询时带会话令牌，一律用 `textContent` 更新。动态文字在服务端渲染时先做 HTML 转义。

## 禁止

- `.formStyle(.grouped)`、系统默认灰色分组背景。
- `.buttonStyle(.borderedProminent)`、`.buttonStyle(.bordered)`、系统蓝色强调色、`.pickerStyle(.radioGroup)`。
- 系统 `DatePicker`、下拉 `Picker`、`.pickerStyle(.segmented)`。日期、时刻、待办单、分段选择用上表的主题组件。
- 带文字的系统 `Toggle`，改用「`Text` + `Spacer` + `ThemedSwitch`」或 `ThemedRow`。
- 系统 `TabView` 标签栏（灰色工具栏、蓝色选中），多分区窗口改用上表的主题侧栏。
- 点击触发的系统 `Menu`、`confirmationDialog`、`alert`。系统右键菜单 `.contextMenu` 也不要用。
- 不带修饰键（空格、方向键、⌫、Esc）的 `.keyboardShortcut` 和菜单快捷键：会抢走输入框里的按键，改在 `MainKeyMonitor` 里处理。
- 新增未在上表列出的颜色值。确实需要时，先加到 `Theme` 并更新本文件。

## 新页面自查

1. 背景是米色，内容放在白色卡片里，卡片带细描边。
2. 主按钮是黄色，删除按钮是红色，没有系统蓝。
3. 和任务相关的页面，标题栏颜色跟随任务所在的象限。
4. 浅色模式（`.preferredColorScheme(.light)`）下查看过效果。
