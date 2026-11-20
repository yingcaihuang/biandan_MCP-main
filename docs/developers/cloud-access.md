# 从零接入便单云端数据与自动续期

面向要开发便单客户端、自动化脚本或 Agent 的开发者。你可以通过本机 MCP 调用便单业务工具，也可以用 Python 发布包中的参考实现，在你自己的客户端完成华为授权、读写和续期。数据接口使用用户授权的凭据访问当前账号的便单记录。

本指南描述便单客户端已验证的华为授权、续期和同步接口行为。示例使用便单 MCP 发布包自带的 Python 模块。集成时请用测试账号验证你依赖的字段和写入行为。字段、编码和跨表写入规则见 [便单数据模型与写入规则](data-model.md)。

## 1. 首次授权、读取与重启续期

准备一个能登录便单 Online 的华为测试账号，先确认账号里有一条待办。打开发布仓库 README，按「下载并解压」一节选择 Python 包或 Windows x64 包。运行本指南的 Python 示例时，请使用 Python 包，并按 README 中的要求准备 Python。 [便单 Online](https://www.biandangroup.com/#/biandan_online) · [发布仓库 README](https://gitcode.com/biandangroup/biandan_MCP/blob/main/README.md)

### 方式 A：通过本机 MCP

1. 在解压目录运行 `python biandan_mcp.py --http`，保留终端窗口。使用 Windows x64 包时，双击 `start-biandan-mcp.cmd`。
2. 在另一个终端运行 `python biandan_mcp.py --print-http-config`。使用 Windows x64 包时，双击 `copy-mcp-config.cmd`。将生成的 Streamable HTTP 地址和 `Authorization` 请求头填入 Agent 客户端。默认地址为 `http://127.0.0.1:42682/mcp`。
3. 让 Agent 调用 `biandan_list_occurrences`，参数为 `{"time_query":"today","status":"pending","limit":20}`。首次需要登录时，系统会打开华为授权页。完成授权后再查一次。若测试任务没有安排在今天，可以改用 `biandan_search_tasks` 按标题搜索。
4. 关闭服务，再以同一系统用户和状态目录启动。再次查询时，本机 MCP 使用保存的刷新令牌取得新的访问令牌。凭据仍有效时无需再次授权。

加载 MCP、列工具和调用 `biandan_help` 不会触发授权。`biandan_check_connection` 会实际访问云端。多个同机客户端可以共用 HTTP 服务和授权。各客户端的设置入口见 [发布仓库 README](https://gitcode.com/biandangroup/biandan_MCP/blob/main/README.md)。

### 方式 B：在自己的 Python 客户端中接入

将下面的示例保存为 `read_biandan.py`，放在 Python 包的解压目录。它复用发布包的授权、续期和读写模块，首次需要时打开浏览器，并从 `Task` 读取至多 5 条记录。请先关闭正在运行的共享 MCP，或为测试客户端使用独立状态目录。同一状态目录的凭据由一个活动进程管理，方便保持令牌轮换的一致性。

```python
import json

from biandan_cloud import BiandanCloud, CloudError
from biandan_mcp import RENEWAL_URL
from biandan_renewal import RenewingAuthorization, renewal_session


def read_tasks():
    with renewal_session():
        authorization = RenewingAuthorization(RENEWAL_URL, device_gate=True)
        client = BiandanCloud(None, authorizer=authorization)
        while True:
            try:
                return client.list_page("Task", page_size=5)["records"]
            except CloudError as error:
                message = str(error).lower()
                if "in the browser" not in message and "in your browser" not in message:
                    raise
                input("请完成浏览器中的华为授权，然后按 Enter 继续。")


if __name__ == "__main__":
    records = read_tasks()
    print(json.dumps(
        [{"task_id": str(row["attributes"]["id1"]), "title": row["attributes"].get("taskTitle") or ""}
         for row in records],
        ensure_ascii=False,
        indent=2,
    ))
```

运行 `python read_biandan.py`。首次授权后，示例只打印任务业务 ID 和标题。退出后用同一系统用户和状态目录再运行一次，验证刷新令牌可以跨进程复用。若浏览器授权被拒绝或超时，重新运行示例发起新授权。自行实现客户端时，可根据下文的授权状态和 HTTP 响应触发交互。

若只做一次只读联调，可运行 `python biandan_cloud.py --oauth list Task --page-size 5`。这个命令只获取访问令牌供单次进程使用。持续登录用上述共享 HTTP 或集成续期模块。

## 2. 自行实现授权与保持登录

### 兼容范围

上面的参考流程沿用便单已登记的 Web OAuth 客户端、官网回调和现有续期服务。采用同一套流程的第三方本地客户端，可复用 Python 参考实现。使用自有 OAuth 客户端 ID 时，需有自己登记的回调和与该 ID 匹配的续期服务，同时单独验证应用获得的用户凭据是否具备访问便单数据的权限。便单续期服务只使用便单 Web OAuth 客户端的配置。

### 首次授权

1. 在用户设备上先绑定 `http://127.0.0.1:42681/biandan/callback`。为每次请求生成新的随机 `state` 和 PKCE verifier。复用便单官网中转时，`state` 以 `biandan-local-v1.` 开头，后接 32 字节随机值的无填充 Base64URL 编码。内存保存本次 `state` 和 verifier。
2. 在系统浏览器打开华为授权页 `https://oauth-login.cloud.huawei.com/oauth2/v3/authorize`。请求使用 `response_type=code`，便单公开客户端 ID `5765880207852987515`，已登记回调 `https://www.biandangroup.com/#/biandan_online`，`scope=openid profile`，以及 `state`、`code_challenge`、`code_challenge_method=S256` 和 `access_type=offline`。`code_challenge` 为 verifier 的 SHA-256 摘要经无填充 Base64URL 编码。
3. 用户在华为页面登录并授权。官网将本次一次性 `code` 或授权错误连同 `state` 跳转到本机监听器。校验回调路径和完整 `state` 后，用 `application/x-www-form-urlencoded` POST 到 `https://oauth-login.cloud.huawei.com/oauth2/v3/token`。参考客户端提交 `grant_type=authorization_code`、`client_id`、原登记的 `redirect_uri`、`code` 和 `code_verifier`。用本次请求返回的 `access_token` 访问华为同步接口，将 `refresh_token` 保存到本机。使用官网回调时，换码的 `redirect_uri` 仍填官网地址。
4. 只接收当前授权流程的回调，完成、拒绝或超时后关闭回环监听器。应用密码和二次验证交给华为授权页。

### 换取新访问令牌

| HTTPS 接口 | 请求 | 成功响应 |
| --- | --- | --- |
| `POST https://auth.biandangroup.com/v1/device` | `Content-Type: application/json`，正文 `{"refresh_token":"<华为刷新令牌>"}`。首次续期尚无设备凭据时调用。 | `access_token`、`expires_in`、`device_grant`，以及华为轮换时返回的 `refresh_token`。 |
| `POST https://auth.biandangroup.com/v1/refresh` | 同样的 JSON 正文，附 `Authorization: Bearer <device_grant>`。后续续期使用。 | `access_token`、`expires_in`、与当前刷新令牌配套的 `device_grant`，以及华为轮换时返回的 `refresh_token`。 |

- 运行时保留访问令牌，按 `expires_in` 计算过期时间。重启后首次访问、令牌接近过期或同步接口返回访问令牌相关的 401 时按需刷新。进程内合并并发刷新。刷新后只重试明确遭拒的那次请求。
- 将 `refresh_token` 和最新版 `device_grant` 一起原子保存。响应未提供新的刷新令牌时沿用原值。参考实现默认将状态文件放在 Windows 的 `%LOCALAPPDATA%\.biandan-mcp` 或 macOS/Linux 的 `~/.biandan-mcp`，可用 `BIANDAN_MCP_STATE_DIR` 覆盖。Windows 使用当前用户的 DPAPI。macOS 和 Linux 参考实现用仅当前用户可读写的文件，其他客户端也可使用系统凭据库。
- 华为刷新令牌的常规有效期是 180 天，撤销授权或更改密码等情况可能提前失效。便单设备凭据也有从登记起算的到期时间，后续刷新保留该到期时间。「保持登录」指在凭据有效期内静默取得访问令牌。OAuth Client Secret 由续期服务持有。 [华为账号 Web 更新凭证指南](https://developer.huawei.com/consumer/cn/doc/HMSCore-Guides/web-refresh-access-token-0000001050048952) · [华为刷新用户级凭证参考](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/account-api-obtain-refresh-token/)
- 只把华为访问令牌发给华为同步接口。续期请求使用刷新令牌和便单设备凭据。本机 MCP 的访问密钥只用于访问本机 `/mcp`。程序输出和日志均应排除上述凭据的实际值。

| 响应 | 客户端处理 |
| --- | --- |
| 续期服务 `401 reauthorization_required` | 清除失效的本机续期状态，在用户下一次需要访问云端时完成重新授权。若当前正处理用户操作，可提示其当场授权。 |
| 续期服务 `403` | 检查是否在使用同一份刷新令牌与设备凭据。已有设备凭据时先核查配置和状态，避免循环登记。 |
| 续期服务 `429` | 保留授权状态。按服务提供的重试时间或有上限的退避策略重试。 |
| 暂时网络故障或 `503` | 保留授权状态，稍后重试。 |
| 本机 `/mcp` 的 `401` | 检查本机 MCP 访问密钥。可以重新生成客户端配置。 |

共享 HTTP 是发布包中默认自动续期的入口。STDIO 的 `--oauth`、记录级 CLI 的 `--oauth` 和显式注入 `BIANDAN_TOKEN` 的方式只使用访问令牌。自行集成时可复用上面的续期模块。

## 3. 直接读写华为同步记录

当前参考实现的同步基础地址是 `https://driveapis.cloud.huawei.com.cn/sync/v1/rongqi`。`kind` 使用 `Task`、`showTask`、`favorites` 或 `tomato`。业务请求由客户端直连该地址。

| 请求项 | 当前参考实现 |
| --- | --- |
| 授权 | `Authorization: Bearer <华为访问令牌>` |
| 通用头 | `Accept: application/json`、`x-hw-sync-env: dataSync2DP`，并按请求生成 `x-hw-trace-id`。`x-hw-app-version` 使用 Python 发布包中 `biandan_cloud.py` 的 `BiandanCloud.request()` 所用的值。 |
| 写请求头 | 有 JSON 正文时带 `Content-Type: application/json`。 |

| 操作 | 方法与相对路径 | 参数 |
| --- | --- | --- |
| 验证容器 | `GET /about` | 验证已授权账号可访问便单容器。 |
| 列表 | `GET /kinds/{kind}/record` | `pageSize`、`fields`，下一页附 `cursor`。 |
| 详情 | `GET /kinds/{kind}/record/{record_id}` | 请求完整 `attributes` 和 `version`。 |
| 新增 | `POST /kinds/{kind}/record` | 正文 `{"attributes": {...}}`。 |
| 更新 | `PATCH /kinds/{kind}/record/{record_id}` | 查询参数 `baseversion`，正文为合并后的完整 `attributes`。 |
| 删除 | `DELETE /kinds/{kind}/record/{record_id}` | 查询参数 `baseversion`。 |

参考客户端的列表投影为 `nextCursor,records(kind,id,attributes,createdTime,editedTime,version)`，单页请求量支持 1–100。将 `nextCursor` 原样用于下一页；若游标重复，停止并报告结果不完整。参考模块可归一化 `records` 或 `recordList`、`recordID` 或 `id` 与部分 `fields` 包装格式。只返回 ID 时，模块逐条读取详情。

`record_id` 是云记录外层 ID，按字符串传递。更新和删除前先 GET 最新版本，以 `version` 作为 `baseversion`。表内的 `id1`、`id2`、`id3` 和 `time` 用于业务关联。更新保留其他属性，遇到 `409` 先读回并检查冲突。新增超时先按业务 ID 核对结果，再决定是否重试 POST。

### 在测试账号走完 CRUD

以下示例使用发布包的记录级 CLI，在同一可信终端由本机凭证管理器为进程注入有效的 `BIANDAN_TOKEN`。也可以在每条命令的子命令前加 `--oauth`，按提示单次授权。

1. 新建 `list-create.json`，把 `1234` 换成测试账号中未占用的业务 ID。该测试待办单应保持为空。

   ```json
   {"id3":1234,"favoritesName":"第三方接入测试","favoritesColor":0}
   ```

2. 新建 `list-patch.json`，只填要修改的属性。CLI 会读取并合并现有属性。

   ```json
   {"favoritesName":"第三方接入测试（已改名）"}
   ```

3. 执行以下命令。将 `云记录 ID` 替换成云端记录外层 ID，`1` 和 `2` 分别替换成两次 GET 读到的对应版本。若新增响应没有给出记录 ID，用列表分页按新建待办单的业务 ID 查询。如果测试待办单被加入了任务，先移出任务再删除。

   ```powershell
   python biandan_cloud.py create favorites list-create.json
   python biandan_cloud.py get favorites '云记录 ID'
   python biandan_cloud.py update favorites '云记录 ID' 1 list-patch.json
   python biandan_cloud.py get favorites '云记录 ID'
   python biandan_cloud.py delete favorites '云记录 ID' 2
   ```

4. 再查列表或在便单端刷新，核对删除已同步。新建任务、改期、完成和删除涉及任务定义与执行实例，按 [写入规则](data-model.md) 或对应 MCP 业务工具处理。

## 4. 接入验收

- 从空测试状态目录启动，先确认本机工具可加载。第一次查询触发授权，授权后能读到测试账号中的已知记录。
- 重启程序并重复读取，凭据仍有效时无需再次打开授权页。
- 用隔离测试账号验证分页和待办单增删改查，再验证任务定义与执行实例在便单端同步。
- 验证撤销授权、续期暂时不可用和 429 时的提示。检查日志只记录状态码、追踪 ID 和必要上下文。
