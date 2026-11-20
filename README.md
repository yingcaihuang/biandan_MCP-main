# 便单 MCP v0.4.2

接好后，你可以直接对你使用的 AI 助手说「看看我今天有哪些待办」「明早九点提醒我交材料」。AI 可以查询、新建、修改、移动和完成任务，也能管理待办单、循环任务、提醒、习惯打卡和专注记录。

要开发自己的便单客户端或 Agent 集成，可查看[第三方开发文档](#第三方开发)。

## 第一步：下载并解压

- **Windows 64 位**：[下载 Windows 版](./releases/biandan-mcp-preview-0.4.2-windows-x64.zip)。解压后可直接运行。
- **macOS、Linux 或已安装 Python 的电脑**：[下载 Python 版](./releases/biandan-mcp-preview-0.4.2-python.zip)。需要 Python 3.10 或更新版本。

打开 ZIP 文件页面后，点「下载」。把整个 ZIP 解压到固定位置。接下来按你用的客户端选一节。

## 小艺 Work

1. 从[小艺 Work 官网](https://xiaoyi.huawei.com/work/)下载 Windows 桌面版。下载上面的便单 Windows 包并解压，双击 `start-biandan-mcp.cmd`，保留便单启动窗口。
2. 打开小艺 Work，新建工作任务，把运行环境选为 **本地电脑**，并选择这台装有便单 MCP 的电脑。手机接续任务时，也要选这台电脑作为执行环境。
3. 如果你的版本提供可填写本机地址和自定义请求头的 MCP 入口，按下方「通用 HTTP 配置」填入地址和请求头。保存后对小艺说「用便单连接器查询今天未完成的待办」。
4. 如果界面只有云端连接器，或找不到自定义 MCP 设置，但当前的「本地电脑」任务能执行 PowerShell，可以用下面的方式先查一次。华为公开页面确认了本地执行环境，自定义 MCP 的入口和支持范围请以你安装的版本为准。 [华为小艺 Work 产品说明](https://xiaoyi.huawei.com/work/)

### 小艺 Work 本机终端验证

把下面整段发给小艺 Work：**「请在本地电脑用 PowerShell 执行下面这段，只给我看今天的待办结果。若需要我确认运行，请提示我。请勿打印本机密钥。」** 也可以直接在这台电脑上的 PowerShell 粘贴运行，先确认便单服务可用。

```powershell
$state = if ($env:BIANDAN_MCP_STATE_DIR) { $env:BIANDAN_MCP_STATE_DIR } else { Join-Path $env:LOCALAPPDATA '.biandan-mcp' }
$key = (Get-Content -Raw -LiteralPath (Join-Path $state 'http-access-key') -ErrorAction Stop).Trim()
$headers = @{ Authorization = "Bearer $key"; Accept = 'application/json, text/event-stream' }
$body = @{
    jsonrpc = '2.0'; id = 1; method = 'tools/call'
    params = @{ name = 'biandan_list_occurrences'; arguments = @{ time_query = 'today'; status = 'pending' } }
} | ConvertTo-Json -Depth 8
$reply = Invoke-RestMethod -Uri 'http://127.0.0.1:42682/mcp' -Method Post -Headers $headers -ContentType 'application/json' -Body $body -TimeoutSec 60
$reply.result.content[0].text
```

这段命令只查今天未完成的任务。首次需要登录时，命令会提示等待授权。完成浏览器授权后再执行一次。本机密钥由命令读取，无需把它发给小艺。如果小艺能运行并返回结果，便单的本机接口已接通。要尝试其他操作，可以让小艺以同样方式调用 `biandan_help` 查询工具用法。小艺 Work 当前入口如果既无法连接本机 MCP 也无法运行本机命令，可以用下面的其他桌面客户端。


## WorkBuddy 桌面版

1. **启动便单。** Windows 双击解压目录中的 `start-biandan-mcp.cmd`。用 Python 版时，在解压目录打开终端，运行 `python3 biandan_mcp.py --http`。Windows 上如果命令叫 `python`，用 `python biandan_mcp.py --http`。保留启动窗口。
2. **复制配置。** Windows 双击 `copy-mcp-config.cmd`。Python 版另开一个终端，在解压目录运行 `python3 biandan_mcp.py --print-http-config`，手动复制输出。
3. **添加连接器。** 打开 WorkBuddy 的「专家 · 技能 · 连接器」，切到「连接器」，然后选「自定义连接器 → 添加 MCP」。在配置编辑器粘贴刚复制的 JSON。已有其他连接器时，把 `biandan` 项加入原来的 `mcpServers`，不要覆盖其他条目。如编辑器要求填写类型，在 `biandan` 项里加 `"type": "http"`。保存后如提示信任，确认名称是便单再点信任。
4. **试一句。** 新开一个工作任务，输入「用便单连接器列出今天未完成的待办」。首次需要登录时会打开浏览器，用平时登录便单的华为账号授权，然后请 AI 再查一次。

如果是逐项填写的界面，类型选 **HTTP / Streamable HTTP**，地址填 `http://127.0.0.1:42682/mcp`。请求头名称填 `Authorization`，值填复制配置里的完整 `Bearer ...`。这串值由便单在当前电脑上生成，请只粘贴到连接器设置。 [腾讯 WorkBuddy 本地 MCP 接入说明](https://docs.ardot.tencent.com/ardot-mcp/ide-integration.html#workbuddy)

如果需要手填 JSON，可以参考下面的样子。把 `本机密钥` 换成复制出来的实际值。

```json
{"mcpServers":{"biandan":{"type":"http","url":"http://127.0.0.1:42682/mcp","headers":{"Authorization":"Bearer 本机密钥"}}}}
```

## 豆包工作桌面版

打开已登录的**豆包工作桌面版**，进入「技能 · 连接器 · 伙伴」，在连接器页面选「新建 → 新建自定义连接器」。菜单名称可能随版本略有变化。

- **有 HTTP 地址和自定义请求头输入框时**，可以先试共享 HTTP。照 WorkBuddy 段落的前 2 步启动便单并生成配置。在豆包里把名称填为 `biandan`，类型选 HTTP，填同一地址及 `Authorization` 请求头。保存后试上面的只读指令。
- **HTTP 连不上或没有请求头设置时**，如果界面提供「本地命令 / STDIO」，用下表填写。STDIO 由豆包启动程序，首次调用需要访问便单账号的工具时才会打开浏览器授权。它可能在连接器进程重启时要求再次授权。一个电脑上请先关闭其他正在等华为授权的便单窗口。

| STDIO 表单 | Windows 版填写 |
| --- | --- |
| 名称 | `biandan` |
| 命令 / 可执行文件 | 解压后 `biandan-mcp.exe` 的完整路径，例如 `C:\Apps\BiandanMCP\biandan-mcp.exe` |
| 参数 | 单独添加一项 `--oauth` |
| 环境变量 | 留空 |

Python 版的命令填 Python 解释器的完整路径，参数依次是解压后 `biandan_mcp.py` 的完整路径、`--oauth`。可以用 `python3 -c "import sys; print(sys.executable)"` 查看解释器路径。请在豆包里开启刚建的连接器，再发「用便单连接器检查连接」。

如果当前入口只收公网地址，也没有 STDIO，请换到提供本地连接器的桌面入口，或使用 WorkBuddy 桌面版。网页版、手机端和云电脑不能通过本机地址连接你电脑上的便单。 [豆包桌面本地命令接入参考](https://open.czur.com/ai/mcp/doubao) · [豆包云端应用插件的网络要求](https://open.doubao.com/apps-plugin/docs/release/package-and-submit)

## 其他客户端

这些客户端使用下面的本机 HTTP 参数。请先启动便单，再把地址和请求头填到你所用客户端的设置里。首次调用需要访问便单账号的工具时，如果浏览器打开华为授权页，完成授权后让 AI 重试。

### 通用 HTTP 配置

| 设置项 | 怎么填 |
| --- | --- |
| 连接器名称 | `biandan` |
| 传输方式 | HTTP 或 Streamable HTTP |
| 服务器地址 | `http://127.0.0.1:42682/mcp` |
| 请求头名称 | `Authorization` |
| 请求头值 | Windows 双击 `copy-mcp-config.cmd`，找生成配置中 `Authorization` 的完整值，包含 `Bearer` 和它后面的空格。Python 版运行 `python3 biandan_mcp.py --print-http-config` 查看。 |

| 客户端 | 从哪里添加 |
| --- | --- |
| 千问办公桌面版 | 打开「连接器 → 添加 → 手动填写配置」，类型选 Streamable HTTP，再填通用 HTTP 参数。当前版本须能访问本机地址。 [入口参考](https://help.dida365.com/articles/7438132116019216384) |
| Cursor 桌面版 | 打开 MCP 设置，或编辑项目的 `.cursor/mcp.json`，把便单加入 `mcpServers`。这个文件如果随项目共享，请把配置放到个人设置中。 [Cursor MCP 文档](https://prod.cursor.com/docs/mcp) |
| VS Code 桌面版 | 在命令面板打开 MCP 用户配置，把 `biandan` 项加到 `servers` 下。类型填 `http`，再填通用参数里的地址和请求头。 [VS Code MCP 配置文档](https://code.visualstudio.com/docs/agents/reference/mcp-configuration) |
| Claude Code | 可以在本机终端执行下面的命令，然后在 Claude Code 里用 `/mcp` 检查连接状态。 [Claude Code MCP 文档](https://code.claude.com/docs/en/mcp) |

```powershell
$key = (Get-Content -Raw -LiteralPath (Join-Path $env:LOCALAPPDATA '.biandan-mcp/http-access-key') -ErrorAction Stop).Trim()
claude mcp add --scope user --transport http biandan http://127.0.0.1:42682/mcp --header "Authorization: Bearer $key"
```

Claude Code 的命令示例使用 Windows 上的默认凭据目录。macOS 或 Linux 用户也可以把通用 HTTP 配置中的 `biandan` 项加进本机的 Claude Code 配置。纯云端连接器需要能访问的远程服务，便单 v0.4.2 的 HTTP 地址只供运行服务的电脑使用。


### TRAE 桌面版

1. 照 WorkBuddy 的前 2 步启动便单、复制配置。
2. 打开 TRAE 设置，进入「MCP → 添加 → 手动添加」。如果界面提供表单，类型选 Streamable HTTP，按通用配置填地址和请求头。如果打开的是 JSON 编辑器，使用下面这段，把 `本机密钥` 换成实际值。已有 `mcpServers` 时，在其中添加 `biandan`。
3. 保存后，在当前智能体中启用便单工具，再让它「用便单列出今天未完成的待办」。 [TRAE 支持的传输方式](https://docs.trae.cn/ide_model-context-protocol) · [TRAE 官方配置 FAQ](https://forum.trae.cn/t/topic/65)

```json
{
  "mcpServers": {
    "biandan": {
      "type": "streamable-http",
      "url": "http://127.0.0.1:42682/mcp",
      "headers": { "Authorization": "Bearer 本机密钥" }
    }
  }
}
```

### Google Antigravity IDE

1. 照 WorkBuddy 的前 2 步准备好便单服务和本机密钥。
2. 在智能体侧栏点「… → MCP Servers → Manage MCP Servers → View raw config」。在打开的 `mcp_config.json` 中使用下面这段，把 `本机密钥` 换成实际值。已有 `mcpServers` 时，在其中添加 `biandan`。请把带密钥的配置留在个人设置里。
3. 保存并刷新 MCP 列表，回到智能体对话，输入「用便单检查连接」。 [Google Antigravity MCP 文档](https://antigravity.google/docs/mcp)

```json
{
  "mcpServers": {
    "biandan": {
      "serverUrl": "http://127.0.0.1:42682/mcp",
      "headers": { "Authorization": "Bearer 本机密钥" }
    }
  }
}
```

### Codex CLI、Codex IDE 扩展和 ChatGPT 桌面端的本地 Codex

1. 照 WorkBuddy 的前 2 步准备好便单服务和本机密钥。
2. 用文本编辑器打开个人目录下的 `.codex/config.toml`。Windows 上可以把 `%USERPROFILE%\.codex` 粘贴到资源管理器地址栏。macOS 或 Linux 上的路径是 `~/.codex/config.toml`。如果已有 `[mcp_servers.biandan]`，更新该段，否则把下面这段加到文件末尾。
3. 把 `本机密钥` 换成实际值，保存后重启正在使用的本地客户端。Codex CLI 或桌面端可在会话里输入 `/mcp` 查看连接，再让 AI「用便单检查连接」。同一台电脑上的本地 Codex 客户端可以共用这份个人配置。 [OpenAI MCP 配置文档](https://learn.chatgpt.com/docs/extend/mcp)

```toml
[mcp_servers.biandan]
url = "http://127.0.0.1:42682/mcp"
http_headers = { Authorization = "Bearer 本机密钥" }
```

### Claude Desktop 本地 MCP

Claude Desktop 可用 STDIO，由客户端启动便单进程。首次使用需要访问便单账号的工具时，在浏览器完成华为授权，再让 AI 重试。进程重启后可能需要重新授权。

1. 打开 Claude Desktop 的开发者设置，找到编辑本地 MCP 配置的入口。也可以直接打开个人配置文件。Windows 的路径是 `%APPDATA%\Claude\claude_desktop_config.json`，macOS 的路径是 `~/Library/Application Support/Claude/claude_desktop_config.json`。
2. Windows 用户把下面的 `command` 改成解压后 `biandan-mcp.exe` 的完整路径。JSON 中路径的每个反斜杠要写两次。使用 Python 版时，`command` 填解释器的完整路径，`args` 依次填写 `biandan_mcp.py` 的完整路径和 `--oauth`。已有 `mcpServers` 时，在其中添加 `biandan`。
3. 保存，完全退出并重新打开 Claude Desktop。看到便单工具后，输入「用便单检查连接」。 [MCP SDK 的本地客户端配置说明](https://py.sdk.modelcontextprotocol.io/get-started/real-host/)

```json
{
  "mcpServers": {
    "biandan": {
      "command": "C:\\Apps\\BiandanMCP\\biandan-mcp.exe",
      "args": ["--oauth"]
    }
  }
}
```

## 可以直接复制给 AI 的话

- 「列出我今天未完成的待办，按待办单分组。」
- 「在工作清单建一条待办，明天下午三点准备汇报，提前半小时提醒。」
- 「从下周开始，每周一和周三读书，持续到月底。」
- 「把这周三这一次改到周四，其他日期照旧。」
- 「看过去一周的专注时长，按天汇总。」
- 「先预览删除这个循环任务会影响哪些实例，等我确认。」

AI 可用 `biandan_help` 查看具体工具的参数和示例。写入会同步到你的便单账号，任务删除是永久操作。地点可以保存，实际到达提醒由支持该功能且已授权的鸿蒙设备处理。

## 遇到问题

| 提示 | 怎么处理 |
| --- | --- |
| 连接不上 | 检查 AI 客户端和便单是否在同一台电脑。用 HTTP 时，确认便单的启动窗口还开着。 |
| HTTP 401 | 重新复制连接配置，检查请求头名为 `Authorization`，值里的 `Bearer` 和后面的空格都要保留。 |
| 等待华为授权 | 切回浏览器完成授权，再让 AI 重试。共享 HTTP 模式支持自动续期，授权被撤销或刷新令牌过期后需要重新授权。 |
| 端口已占用 | 先关闭重复启动的便单窗口，再启动一次。 |
| AI 只给建议、没有操作便单 | 在会话里启用 `biandan` 连接器，明确说「请调用便单工具」，先用只读指令核对连接。 |

升级时，先关闭正在运行的旧版，把新版解压到固定位置后启动。使用 STDIO 的用户如果换了解压位置，记得更新连接器里的文件路径。

## 第三方开发

- [便单数据模型与写入规则](./docs/developers/data-model.md)涵盖四张同步表的字段、编码、关联和跨表写入示例。
- [从零接入便单云端数据与自动续期](./docs/developers/cloud-access.md)包含授权、首次读取、重启续期和记录级增删改查示例。建议先用测试账号跑通读取与续期，再验证写入。

## 更新日志

### v0.4.2

- 华为授权改为按需触发。HTTP 和 STDIO 都会在首次调用需要访问便单账号的工具时，按需打开授权页。
- 启动服务、加载连接器、列出工具和查看帮助时无需授权。等待授权期间重复调用不会打开新的授权页。

### v0.4.1

- 发布 Windows x64 和 Python 体验包，支持共享 HTTP 和 STDIO 接入。
