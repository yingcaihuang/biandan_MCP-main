# 通用数据上报接口对接文档

用来让其它程序（比如 token 用量统计）把数据报到服务器上，再按时间和字段查询、汇总。和便单日程**完全独立**：用的密钥、接口和存储文件都是分开的。

- **地址**：`https://www.aigslb.link/biandan/api`
- **方法**：都用 `POST`，请求体是 JSON，加 `Content-Type: application/json`
- **鉴权**：请求头加 `Authorization: Bearer <密钥>`
  - **上报密钥**（`bdu_` 开头）：只能调 `/v1/data/ingest`，读不了数据，也碰不到日程
  - **读取密钥**（`bdr_` 开头）：和日程用的是同一种，可以调 `/v1/data/records`、`/v1/data/stats`、`/v1/data/datasets`，不能上报
- **时区**：默认按 `Asia/Shanghai` 换算。上报和查询都可以传 `timezone`（IANA 名称）指定别的时区
- **服务端不需要事先定义字段**：每条记录是一个任意 JSON 对象，以后加字段直接加就行

## 1. 密钥管理（在 Mac 上 `BiandanAPI` 目录执行）

```bash
./deploy.sh --add-key report <名称>     # 新建上报密钥，建议每个上报程序用一把
./deploy.sh --add-key read <名称>       # 新建读取密钥
./deploy.sh --remove-key report <名称>  # 删除，立即生效
./deploy.sh --list-keys
```

新建的密钥只保存在本机 `~/.biandan-api/<角色>-<名称>.key`（权限 600），服务器上只存它的 SHA-256。现在已经有一把：`~/.biandan-api/report-token-stats.key`。

## 2. 数据模型

- **数据集（dataset）**：一类数据一个，比如 `token-usage`。名称只能用小写字母、数字、`.`、`_`、`-`，必须以字母或数字开头，最多 64 个字符。第一次上报时自动创建。
- **记录**：一个 JSON 对象。有两个保留字段：
  - `id`（可选，字符串或数字，最多 128 个字符）：带上 `id` 时，同一个 `id` 再报会**覆盖**旧记录；不带时服务器自动生成，每次都**新增**一条。
  - `ts`（可选）：这条数据对应的时间。不带时用服务器收到的时间。支持这几种写法：
    - RFC 3339：`2026-11-24T17:00:00+08:00`
    - 本地时间，按 `timezone` 解释：`2026-11-24 17:00:00`、`2026-11-24 17:00`、`2026-11-24`（当天 0 点）
    - Unix 时间戳，秒或毫秒都行，可以带小数
  - 其它字段原样保存，可以是数字、字符串、布尔、数组或嵌套对象。顶层字段名只能用字母、数字、`_`、`-`。

**token 统计的两种报法：**

| 场景 | 做法 |
| --- | --- |
| 定时报「今天到现在的累计用量」 | `id` 用 `日期/模型` 这种写法（如 `2026-11-24/gpt-4o`），`ts` 用那天的日期。同一天反复报会覆盖，不会重复累加。 |
| 每次调用完报一条明细 | 不带 `id`（或者用请求 ID 做 `id`，防止重试时重复），`ts` 用调用时间。 |

## 3. 上报 `POST /v1/data/ingest`（上报密钥）

| 字段 | 说明 |
| --- | --- |
| `dataset` | 必填，数据集名称 |
| `records` | 记录数组，一次最多 5000 条 |
| `record` | 只报一条时可以用这个代替 `records`，两个只能用一个 |
| `delete_ids` | 要删除的记录 `id` 列表，可以和 `records` 一起用（先删后写） |
| `replace` | `true` 时，这次的 `records` 就是数据集的全部内容，原来的都删掉。`records` 为空就是清空整个数据集。不能和 `delete_ids` 一起用 |
| `timezone` | 解释不带时区的 `ts` 时用，默认 `Asia/Shanghai` |

请求体里有不认识的字段时会报错，这样拼错字段名能马上发现。整批记录里只要有一条不合法，整批都不保存。

```bash
curl -sS -X POST https://www.aigslb.link/biandan/api/v1/data/ingest \
  -H "Authorization: Bearer $(cat ~/.biandan-api/report-token-stats.key)" \
  -H 'Content-Type: application/json' \
  -d '{"dataset":"token-usage","records":[
        {"id":"2026-11-24/gpt-4o","ts":"2026-11-24","provider":"openai","model":"gpt-4o",
         "input":120000,"output":35000,"cache_read":8000,"cost":0.65,"requests":42},
        {"id":"2026-11-24/claude","ts":"2026-11-24","provider":"anthropic","model":"claude",
         "input":90000,"output":20000,"cost":0.48,"requests":18,"meta":{"app":"dsh"}}
      ]}'
```

响应：

```json
{"ok":true,"dataset":"token-usage","version":"df1b4efd6200ca5c","changed":true,
 "received":2,"inserted":2,"updated":0,"unchanged":0,"deleted":0,"expired":0,"total":2,
 "received_at":"2026-11-24T17:41:13+08:00"}
```

- `inserted`、`updated`、`unchanged`：这次报上来的记录里，新增、覆盖、内容没变的各有几条。内容没变时不写盘，`changed` 为 `false`，版本号也不变。
- `deleted`：原来的记录这次删掉了几条，包括 `delete_ids`、`replace` 删掉的，以及超出条数上限被挤掉的。
- `expired`：`ts` 早于保留期（默认 400 天）的记录，这些没有保存。
- `version`：数据集内容的版本号，查询时可以拿来做 `if_version`。

## 4. 查询明细 `POST /v1/data/records`（读取密钥）

| 字段 | 说明 |
| --- | --- |
| `dataset` | 必填 |
| `start` / `end` | 时间范围。可以写 `today`、`yesterday`、`now`、`YYYY-MM-DD`、`YYYY-MM`、RFC 3339。`end` 写日期或月份时，包含那一整天或整个月 |
| `days` | 最近 N 天，包含今天，不能和 `start` 一起用。`"days":7` 就是最近 7 天 |
| `where` | 按字段相等筛选，所有条件都要满足。值写成数组时，等于其中任意一个就算满足；写 `null` 表示没有这个字段。嵌套字段用点号，比如 `"meta.app"` |
| `fields` | 只返回这些字段，支持点号。不传时返回全部字段 |
| `order` | 默认 `desc`（最新的在前），也可以用 `asc` |
| `limit` / `offset` | 分页，`limit` 默认 100、最大 1000 |
| `if_version` | 和当前版本号相同时，只回 `{"ok":true,"not_modified":true,"version":"…"}` |
| `timezone` | 返回的 `ts` 和日期边界按这个时区算 |

```bash
curl -sS -X POST https://www.aigslb.link/biandan/api/v1/data/records \
  -H "Authorization: Bearer $READ_KEY" -H 'Content-Type: application/json' \
  -d '{"dataset":"token-usage","days":7,"where":{"provider":["openai","anthropic"]},"fields":["model","input","output"]}'
```

```json
{"ok":true,"dataset":"token-usage","version":"df1b4efd6200ca5c","timezone":"Asia/Shanghai",
 "start":"2026-11-18T00:00:00+08:00","end":"2026-11-25T00:00:00+08:00",
 "total":2,"returned":2,"offset":0,"truncated":false,
 "records":[{"id":"2026-11-24/gpt-4o","ts":"2026-11-24T00:00:00+08:00","model":"gpt-4o","input":120000,"output":35000}]}
```

## 5. 汇总 `POST /v1/data/stats`（读取密钥）

先按时间段和字段分组，再对数值字段求和。筛选用的字段（`dataset`、`start`、`end`、`days`、`where`、`timezone`、`if_version`）和查明细一样，另外还有：

| 字段 | 说明 |
| --- | --- |
| `bucket` | 按时间段分组：`hour`、`day`、`week`（从周一开始，组名用那个周一的日期）、`month`、`year`。不传就不按时间分 |
| `group_by` | 按这些字段分组，最多 5 个，支持点号 |
| `sum` | 要求和的字段，支持点号。不传时对所有顶层数值字段求和，嵌套字段要自己列出来 |
| `sort` | 默认 `key`（按时间段和分组字段升序）。也可以填 `count` 或者 `sum` 里的某个字段，这时从大到小排 |
| `limit` | 最多返回多少组，默认 1000、最大 10000 |

```bash
# 最近 30 天，每天每个模型用了多少
curl -sS -X POST https://www.aigslb.link/biandan/api/v1/data/stats \
  -H "Authorization: Bearer $READ_KEY" -H 'Content-Type: application/json' \
  -d '{"dataset":"token-usage","days":30,"bucket":"day","group_by":["model"],"sum":["input","output","cost"]}'
```

```json
{"ok":true,"dataset":"token-usage","version":"df1b4efd6200ca5c","timezone":"Asia/Shanghai",
 "bucket":"day","group_by":["model"],"sum_fields":["input","output","cost"],
 "records":2,"group_count":2,"returned":2,"truncated":false,
 "groups":[{"bucket":"2026-11-24","model":"claude","count":1,"sum":{"input":90000,"output":20000,"cost":0.48},
            "first_ts":"2026-11-24T00:00:00+08:00","last_ts":"2026-11-24T00:00:00+08:00"}],
 "totals":{"count":2,"sum":{"input":210000,"output":55000,"cost":1.13}}}
```

其它常用写法：

- 本月各模型的总费用，从高到低：`{"dataset":"token-usage","start":"2026-11","end":"2026-11","group_by":["model"],"sum":["cost"],"sort":"cost"}`
- 今天的总量：`{"dataset":"token-usage","days":1}`，看 `totals` 就行
- 按月看趋势：`{"dataset":"token-usage","bucket":"month"}`

求和结果保留 6 位小数，是整数时直接输出整数。字段不是数字的记录在求和时跳过，但 `count` 仍然会算上它。

## 6. 数据集列表 `POST /v1/data/datasets`（读取密钥）

请求体可以为空，也可以传 `{"dataset":"token-usage"}` 只看一个。返回各数据集的条数、时间范围、最近一次上报的时间和密钥名称，以及出现过的字段和类型。类型有 `number`、`string`、`bool`、`array`、`object`，同一个字段出现过多种类型时用 `|` 连起来。嵌套对象会往下展开一层，比如 `meta.app`。

```json
{"ok":true,"timezone":"Asia/Shanghai","retention_days":400,"max_datasets":100,"max_records_per_dataset":100000,
 "datasets":[{"name":"token-usage","version":"df1b4efd6200ca5c","records":2,
   "first_ts":"2026-11-24T00:00:00+08:00","last_ts":"2026-11-24T00:00:00+08:00",
   "last_report_at":"2026-11-24T17:41:13+08:00","last_report_by":"token-stats","last_report_age_seconds":12,
   "fields":{"cost":"number","input":"number","model":"string","meta":"object","meta.app":"string"}}]}
```

`GET /v1/health` 不需要密钥，里面的 `datasets` 是现在有几个数据集。

## 7. 限制

| 项目 | 上限 |
| --- | --- |
| 数据集个数 | 100 个，超了返回 409。不用的数据集可以用 `replace: true` 加空 `records` 清掉 |
| 每个数据集的记录数 | 10 万条，超出后删掉 `ts` 最早的 |
| 保留期 | 400 天，按 `ts` 算，过期的自动删掉 |
| 单条记录 | 16 KB，顶层字段最多 100 个 |
| 一次上报 | 5000 条记录，请求体 8 MB |
| 频率 | 每把上报密钥每分钟 120 次。读取密钥每分钟 120 次，和日程查询共用这个额度 |
| 认证失败 | 同一个 IP 10 分钟内失败 20 次后，暂时返回 429 |

保留期和默认时区可以在服务器上用环境变量 `BIANDAN_API_DATA_RETENTION_DAYS`（填 0 就不按时间删）和 `BIANDAN_API_DATA_TZ` 修改。数据存在服务器的 `/var/lib/biandan-api/datasets/<名称>.log`。

## 8. 错误

出错时返回 `{"ok":false,"error":{"code":"…","message":"…"}}`，其中 `message` 是中文说明。

| HTTP | code | 原因 |
| --- | --- | --- |
| 400 | `bad_request`、`invalid_dataset`、`invalid_record`、`too_many_records` | 参数不对。`invalid_record` 会说明是第几条记录出了问题 |
| 401 | `unauthorized` | 没带密钥、密钥不对，或者密钥角色不对（比如用读取密钥去上报） |
| 404 | `no_dataset` | 数据集还没上报过，或者已经清空 |
| 405 | `method_not_allowed` | 不是 POST |
| 409 | `too_many_datasets` | 数据集个数到上限了 |
| 413 | `payload_too_large` | 请求体太大 |
| 429 | `rate_limited`、`too_many_failures` | 请求太频繁，按响应头 `Retry-After` 给的秒数等一会儿再试 |
| 500 | `storage_error` | 服务器保存失败，可以重试 |
| 503 | `service_down` | 服务没起来 |

**建议上报程序这样处理**：网络错误、429、5xx 时，等一会儿再重试，间隔逐次加长。带了 `id` 的记录重试也不会重复。400 和 401 重试没用，应该记日志并修正请求。

## 9. Python 上报示例

```python
import json, os, time, urllib.request

URL = "https://www.aigslb.link/biandan/api/v1/data/ingest"
KEY = open(os.path.expanduser("~/.biandan-api/report-token-stats.key")).read().strip()

def report(dataset, records, retries=5):
    body = json.dumps({"dataset": dataset, "records": records}).encode()
    for attempt in range(retries):
        req = urllib.request.Request(URL, data=body, method="POST", headers={
            "Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            if e.code in (400, 401, 404, 409, 413):
                raise RuntimeError(e.read().decode()) from e
            wait = int(e.headers.get("Retry-After", 2 ** attempt))
        except OSError:
            wait = 2 ** attempt
        time.sleep(wait)
    raise RuntimeError("上报失败，重试次数用完")

print(report("token-usage", [
    {"id": "2026-11-24/gpt-4o", "ts": "2026-11-24", "model": "gpt-4o", "input": 120000, "output": 35000, "cost": 0.65},
]))
```
