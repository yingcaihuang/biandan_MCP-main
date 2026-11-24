# 便单日程 API（biandan-api）对接文档

> 通用数据上报（token 统计等，和日程无关）的对接文档见 [DATA_API.md](DATA_API.md)。

便单 Mac 版把本机的全部日程（华为账号里的便单日程，以及从 CalDAV、订阅地址、系统日历、.ics 文件导入的日程）推到服务器，ESP32 等设备用 POST 请求按分类读取 JSON。

```
便单 Mac 版（一直开着）── 数据变化 3 秒后推送 / 每 10 分钟心跳 ──▶ biandan-api（127.0.0.1:18730）
                                                                   ▲  nginx /biandan/api/ 转发
ESP32 ── HTTPS POST + 读取密钥 ──▶ ESA ──▶ https://www.aigslb.link/biandan/api/…
```

- 服务器只保存最新的一份快照。Mac 关机或断网时，设备读到的是最后一次推送的数据，可以看 `data_age_seconds` 判断数据新不新。
- 重复日程只包含便单已经生成的那些次，和 App 里看到的一样。

## 1. 基本约定

| 项目 | 说明 |
| --- | --- |
| 地址 | `https://www.aigslb.link/biandan/api` |
| 方法 | 除健康检查外都用 `POST`，请求体是 JSON（`Content-Type: application/json`，UTF-8）。请求体可以为空，表示全部用默认值 |
| 鉴权 | 请求头 `Authorization: Bearer <密钥>`。读取密钥 `bdr_` 开头，推送密钥 `bdp_` 开头，都是 47 个字符，两种不能混用 |
| 时区 | 日期、时刻都是便单所在时区（`Asia/Shanghai`）的本地时间。`today` 以服务端为准 |
| 编码 | 请求里不带 `Accept-Encoding` 时，返回未压缩的正文和 `Content-Length`（ESP32 的 HTTPClient 默认就是这样）。带了 `gzip` 才会压缩 |
| 缓存 | 所有响应都带 `Cache-Control: no-store`，ESA 不缓存（已验证 `x-site-cache-status: DYNAMIC`） |
| 证书 | 公网证书由 Let's Encrypt 签发，设备只需要信任 **ISRG Root X1**（见第 6 节） |
| 未知字段 | 请求里出现不认识的字段会返回 400，方便发现拼写错误 |

### 密钥管理（在 Mac 上 `BiandanAPI` 目录执行）

```bash
./deploy.sh --add-key read esp32-kitchen   # 新建读取密钥，保存在 ~/.biandan-api/read-esp32-kitchen.key（权限 600）
./deploy.sh --list-keys                    # 列出服务器上的密钥名称
./deploy.sh --remove-key read esp32-kitchen  # 吊销，立即生效
```

建议每台设备用一把读取密钥，丢了只吊销那一把。服务器上只存密钥的 SHA-256，密钥本身只在新建时写进本机文件。

## 2. 查询日程 `POST /v1/schedule`（读取密钥）

### 请求字段（都可以省略）

| 字段 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `start` | string | 不限 | 起始日期：`YYYY-MM-DD`、`today`、`tomorrow`、`yesterday` |
| `end` | string | 等于 `start` | 结束日期（含）。给了 `end` 就必须给 `start`；不能和 `days` 同时给 |
| `days` | int | — | 从 `start`（省略时为今天）起共几天，1–400 |
| `status` | string | `all` | `all`、`pending`（待完成）、`completed`（已完成）、`abandoned`（已放弃） |
| `list_ids` | string[] | 全部 | 只看这些分类（分类 ID 见 `/v1/lists`） |
| `include_undated` | bool | 不限日期时 `true`，限定日期时 `false` | 是否包含无日期的日程 |
| `include_empty_lists` | bool | `false` | 按分类分组时，没有日程的分类也返回 |
| `group_by` | string | `list` | `list` 按分类；`date` 按日期；`none` 不分组 |
| `fields` | string | `full` | `full` 完整字段；`compact` 精简字段（推荐给 ESP32） |
| `limit` | int | 500 | 最多返回几条，超过 2000 按 2000 |
| `if_version` | string | — | 上次响应里的 `version`。数据没变时只返回 `{"ok":true,"not_modified":true,"version":"…"}` |

日期范围的规则：日程的 `[start_date, end_date]` 和查询范围有交集就算命中，所以跨天日程在范围内的每一天都算。按日期分组时，跨天日程只放在它在范围内的第一天。

> `if_version` 比较的是**数据版本**，和查询条件无关。设备改了查询条件（天数、分类、状态…）时要先清空保存的版本，否则会误以为数据没变。

### 请求示例

```bash
KEY=$(cat ~/.biandan-api/read-esp32.key)
# 今天的全部日程，精简字段
curl -sS -X POST https://www.aigslb.link/biandan/api/v1/schedule \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"start":"today","fields":"compact"}'
# 未来 7 天未完成的，按日期分组
curl -sS -X POST https://www.aigslb.link/biandan/api/v1/schedule \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"days":7,"status":"pending","group_by":"date","fields":"compact"}'
```

### 响应（`fields: "compact"`）

```json
{
  "ok": true,
  "version": "78248c40bb3c1689",
  "generated_at": "2026-11-24T11:42:10+08:00",
  "received_at": "2026-11-24T11:42:11+08:00",
  "data_age_seconds": 35,
  "timezone": "Asia/Shanghai",
  "today": "2026-11-24",
  "query": {"start": "2026-11-24", "end": "2026-11-24", "status": "all", "include_undated": false,
            "group_by": "list", "fields": "compact", "limit": 500},
  "total": 2,
  "returned": 2,
  "truncated": false,
  "groups": [
    {
      "id": "1001", "name": "工作", "color": "#E5483A", "total": 2, "count": 2,
      "items": [
        {"occurrence_id": "1795…", "title": "周会", "list_id": "1001",
         "start_date": "2026-11-24", "end_date": "2026-11-24", "start_time": "09:00", "end_time": "10:00",
         "all_day": false, "undated": false, "status": "pending", "overdue": false,
         "important": true, "urgent": true},
        {"occurrence_id": "1795…", "title": "交周报", "list_id": "1001",
         "start_date": "2026-11-24", "end_date": "2026-11-24",
         "all_day": true, "undated": false, "status": "pending", "overdue": false,
         "important": false, "urgent": false}
      ]
    }
  ]
}
```

| 顶层字段 | 说明 |
| --- | --- |
| `version` | 数据版本，内容不变就不变（与推送时间无关），用于 `if_version` |
| `generated_at` / `received_at` | Mac 生成快照的时间 / 服务器收到的时间 |
| `data_age_seconds` | 距上次收到推送过了几秒。Mac 开着时至少每 10 分钟推一次，**超过 1800 秒**说明 Mac 可能关机或断网 |
| `today` | 服务端当天日期，显示「今天」时用它 |
| `query` | 实际生效的查询条件（补齐了默认值） |
| `total` / `returned` / `truncated` | 命中总数 / 实际返回条数 / 是否因为 `limit` 截断 |
| `groups[]` | 分组：`id`、`name`、`color`（分类颜色 `#RRGGBB`，按日期分组时没有）、`total`（这组命中数）、`count`（这组实际返回数）、`items` |

分组顺序：按分类时和便单侧栏一致（`id` 为 `"1"` 的是「未分类」）；按日期时 `id` 是 `YYYY-MM-DD`，`name` 形如 `11月24日 周二`，无日期的组 `id` 为 `undated`。组内排序：有日期的在前，按开始日期、全天优先、开始时刻、标题。

### 每条日程的字段

精简模式只有带 ★ 的字段；完整模式（`full`）全部都有。值为空的可选字段不出现。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| ★ `occurrence_id` | string | 这一次日程的 ID（重复日程每次不同） |
| `task_id` | string | 所属日程定义的 ID（重复日程各次相同） |
| ★ `list_id` | string | 分类 ID |
| `list_name` | string | 分类名称 |
| ★ `title` | string | 标题 |
| `remark` | string | 备注 |
| `subtasks` | string[] | 子任务 |
| ★ `undated` | bool | 无日期（没有下面的日期、时刻字段） |
| ★ `all_day` | bool | 全天（没有 `start_time` / `end_time`） |
| ★ `start_date` / `end_date` | string | `YYYY-MM-DD` |
| ★ `start_time` / `end_time` | string | `HH:MM`，24 小时制 |
| ★ `status` | string | `pending`、`completed`、`abandoned` |
| ★ `overdue` | bool | 逾期：待完成且结束日期早于今天 |
| `completed_at` | string | 完成时间 `YYYY-MM-DD HH:MM:SS` |
| ★ `important` / ★ `urgent` | bool | 重要 / 紧急 |
| `quadrant` / `quadrant_name` | int / string | 四象限：1 重要且紧急，2 重要但不紧急，3 不重要但紧急，4 不重要且不紧急 |
| `collected` | bool | 已收藏 |
| `repeating` / `habit` | bool | 重复日程 / 习惯 |
| `repeat_rule` | string | 重复规则的中文说明，如「每周 一、三」 |
| `location` | string | 地点 |
| `reminder` | object | 时间提醒：`date`（`YYYY-MM-DD`）、`time`（`HH:MM`） |
| `source` | object | 来源：`kind` 为 `biandan`（便单里直接建的）、`caldav`、`url`（订阅地址）、`system`（系统日历 / 邮箱账户）、`file`（.ics 文件）；`name` 为来源名称 |

### 响应大小参考（52 条日程时实测）

| 请求 | 大小 |
| --- | --- |
| `{"days":3,"status":"pending","fields":"compact"}` | 约 0.8 KB |
| `{"start":"today","fields":"compact"}` | 约 1.9 KB |
| `{"days":7,"fields":"compact"}` | 约 3.3 KB |
| `{"days":7}`（完整字段） | 约 6.4 KB |
| `{"fields":"compact"}`（全部） | 约 14.7 KB |
| `{}`（全部、完整字段） | 约 30 KB |

ESP32 建议用 `compact`、限定天数、设 `limit`，再配合 ArduinoJson 的 Filter 只留要用的字段。

## 3. 分类 `POST /v1/lists`（读取密钥）

请求体可为空，也可以带 `{"if_version":"…"}`。返回全部分类和每个分类的数量：

```json
{"ok": true, "version": "78248c40bb3c1689", "timezone": "Asia/Shanghai", "today": "2026-11-24",
 "lists": [
   {"id": "1", "name": "未分类", "color": "#B9B09C", "order": 0, "is_default": true, "total": 5, "pending": 3, "overdue": 1},
   {"id": "1001", "name": "工作", "color": "#E5483A", "order": 1, "is_default": false, "total": 18, "pending": 6, "overdue": 0}
 ]}
```

`total` 是这个分类的全部日程次数（含已完成、已放弃），`pending` 是待完成，`overdue` 是逾期。

## 4. 健康检查 `GET /v1/health`（不用密钥）

```json
{"ok": true, "service": "biandan-api", "version": "1.0.0", "has_data": true, "data_age_seconds": 35}
```

## 5. 错误

出错时 `ok` 为 `false`：`{"ok":false,"error":{"code":"…","message":"中文说明"}}`。

| HTTP | `code` | 含义和处理 |
| --- | --- | --- |
| 400 | `bad_request` | 请求字段有误（日期格式、取值、未知字段…），看 `message` |
| 401 | `unauthorized` | 没带密钥、密钥错误或已吊销，或者拿推送密钥来读 |
| 404 | `not_found` | 路径不对 |
| 405 | `method_not_allowed` | 方法不对（查询接口只收 POST） |
| 413 | `payload_too_large` | 请求体太大（查询 16 KB，推送 16 MB） |
| 429 | `rate_limited` | 这把密钥请求太频繁（读取每分钟 120 次，推送每分钟 60 次），按 `Retry-After` 秒数等待 |
| 429 | `too_many_failures` | 这个地址 10 分钟内认证失败超过 20 次，暂时拒绝，按 `Retry-After` 等待 |
| 503 | `no_data` | 服务器还没收到过 Mac 推送的数据 |
| 503 | `service_down` | 服务没有运行（nginx 返回） |
| 500 | `storage_error` | 服务器保存数据失败（只在推送时） |

设备端建议：401 时停下并提示更换密钥，不要一直重试（会触发 `too_many_failures`）；网络错误和 5xx 时加大间隔重试。

## 6. ESP32 示例（Arduino）

完整代码在 [examples/esp32_schedule/esp32_schedule.ino](examples/esp32_schedule/esp32_schedule.ino)，需要 Arduino-ESP32 核心和 ArduinoJson 7.x。要点：

- 用 `WiFiClientSecure::setCACert()` 信任 ISRG Root X1（有效期到 2035-06-04，SHA-256 指纹 `96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6`），不要用 `setInsecure()`。
- 先用 NTP 对时，证书校验需要正确的时间。
- `http.useHTTP10(true)` 后可以直接 `deserializeJson(doc, http.getStream(), …)` 从流里解析。
- 每 1–5 分钟轮询一次即可，配合 `if_version`，数据没变时响应只有几十字节。
- 中文显示需要屏幕库带中文字库（如 U8g2 的 `u8g2_font_wqy12_t_gb2312`）。

```cpp
// 便单日程 → ESP32 示例：每 2 分钟查一次「今天起 3 天内未完成」的日程，按分类打印到串口。
// 需要：Arduino-ESP32 核心 2.x 或 3.x；ArduinoJson 7.x（库管理器搜索 ArduinoJson）。
// 接口说明见 BiandanAPI/README.md。
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <time.h>

static const char *WIFI_SSID = "你的WiFi名称";
static const char *WIFI_PASS = "你的WiFi密码";
static const char *API_URL = "https://www.aigslb.link/biandan/api/v1/schedule";
// 读取密钥（bdr_ 开头）。每台设备用自己的一把：./deploy.sh --add-key read <设备名>
static const char *READ_KEY = "bdr_把读取密钥填在这里";
static const uint32_t POLL_MS = 120000;  // 轮询间隔；每把密钥每分钟最多 120 次

// ISRG Root X1（Let's Encrypt 根证书，有效期到 2035-06-04）。不要用 setInsecure()，否则密钥可能被中间人截获。
static const char ROOT_CA[] = R"PEM(
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
)PEM";

// 上次拿到的数据版本。查询条件不变时带上 if_version，数据没变服务端只回一行。
// 改了查询条件（天数、分类、状态…）要先清空，否则会误以为「没变」。
static String lastVersion;
static uint32_t lastPoll = 0;
static uint32_t waitMs = 0;

static void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("连接 WiFi");
  for (int i = 0; i < 40 && WiFi.status() != WL_CONNECTED; i++) {
    delay(500);
    Serial.print('.');
  }
  Serial.println(WiFi.status() == WL_CONNECTED ? " 已连接" : " 失败");
}

// 校验证书有效期需要正确的时间；显示「今天」以服务端返回的 today 为准。
static void syncClock() {
  configTzTime("CST-8", "ntp.aliyun.com", "pool.ntp.org");
  for (int i = 0; i < 20 && time(nullptr) < 1700000000; i++) delay(500);
}

// 返回 true 表示成功（包括数据没变）。
static bool fetchSchedule() {
  WiFiClientSecure client;
  client.setCACert(ROOT_CA);
  HTTPClient http;
  http.setTimeout(15000);
  http.useHTTP10(true);  // 不用分块传输，ArduinoJson 可以直接从流里解析
  if (!http.begin(client, API_URL)) {
    Serial.println("HTTPClient.begin 失败");
    return false;
  }
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Authorization", String("Bearer ") + READ_KEY);

  JsonDocument req;
  req["days"] = 3;
  req["status"] = "pending";
  req["fields"] = "compact";
  req["limit"] = 60;
  if (lastVersion.length() > 0) req["if_version"] = lastVersion;
  String body;
  serializeJson(req, body);

  int code = http.POST(body);
  if (code != HTTP_CODE_OK) {
    // 401 密钥不对；429 请求太频繁（看 Retry-After）；503 服务器还没收到 Mac 推送的数据
    String detail = code > 0 ? http.getString() : HTTPClient::errorToString(code);
    Serial.printf("HTTP %d %s\n", code, detail.c_str());
    http.end();
    return false;
  }

  // 只保留要用的字段，省内存。
  JsonDocument filter;
  filter["not_modified"] = true;
  filter["version"] = true;
  filter["today"] = true;
  filter["data_age_seconds"] = true;
  filter["total"] = true;
  filter["truncated"] = true;
  filter["groups"][0]["name"] = true;
  filter["groups"][0]["items"][0]["title"] = true;
  filter["groups"][0]["items"][0]["start_date"] = true;
  filter["groups"][0]["items"][0]["start_time"] = true;
  filter["groups"][0]["items"][0]["end_time"] = true;
  filter["groups"][0]["items"][0]["all_day"] = true;
  filter["groups"][0]["items"][0]["overdue"] = true;
  filter["groups"][0]["items"][0]["important"] = true;

  JsonDocument doc;
  DeserializationError err = deserializeJson(doc, http.getStream(), DeserializationOption::Filter(filter));
  http.end();
  if (err) {
    Serial.printf("解析失败：%s\n", err.c_str());
    return false;
  }
  if (doc["not_modified"] | false) {
    Serial.println("数据没变");
    return true;
  }
  lastVersion = doc["version"].as<String>();
  int age = doc["data_age_seconds"] | 0;
  Serial.printf("今天 %s，共 %d 条%s，数据 %d 秒前更新\n", doc["today"] | "?", doc["total"] | 0,
                (doc["truncated"] | false) ? "（只返回了一部分）" : "", age);
  if (age > 1800) Serial.println("注意：超过 30 分钟没收到 Mac 推送，数据可能不是最新的");

  for (JsonObject group : doc["groups"].as<JsonArray>()) {
    Serial.printf("【%s】\n", group["name"] | "");
    for (JsonObject item : group["items"].as<JsonArray>()) {
      bool allDay = item["all_day"] | false;
      Serial.printf("  %s %s%s%s %s%s%s\n", item["start_date"] | "", allDay ? "全天" : (item["start_time"] | ""),
                    (!allDay && item["end_time"]) ? "-" : "", allDay ? "" : (item["end_time"] | ""),
                    item["title"] | "", (item["overdue"] | false) ? " [逾期]" : "",
                    (item["important"] | false) ? " [重要]" : "");
    }
  }
  return true;
}

void setup() {
  Serial.begin(115200);
  connectWiFi();
  syncClock();
}

void loop() {
  if (lastPoll != 0 && millis() - lastPoll < waitMs) {
    delay(200);
    return;
  }
  connectWiFi();
  bool ok = WiFi.status() == WL_CONNECTED && fetchSchedule();
  lastPoll = millis();
  if (lastPoll == 0) lastPoll = 1;
  // 失败时等久一点再试，避免连续认证失败触发限流（每个地址 10 分钟内最多失败 20 次）。
  waitMs = ok ? POLL_MS : POLL_MS * 2;
}
```

## 7. 推送接口 `POST /v1/push`（推送密钥，便单 App 用）

便单 Mac 版「设置 → 同步 → 远程日程接口」打开「推送到远程」后自动推送：本机数据变化（同步、修改、导入更新）3 秒后推一次，内容没变时每 10 分钟推一次当心跳，失败按 30 秒、1、2、4… 分钟退避，最长 30 分钟。只有登录且至少同步过一次才推送，退出登录清空本地库时不会把远程数据也清空。推送密钥优先读钥匙串（设置里粘贴保存的），没有时读 `~/.biandan-api/push-mac.key`。

请求体是一份完整快照，整份替换服务器上的数据：

```json
{
  "format": "biandan-schedule", "version": 1,
  "generated_at": "2026-11-24T11:42:10+08:00", "timezone": "Asia/Shanghai", "device": "BiandanMac 1.3.4",
  "lists": [{"id": "1", "name": "未分类", "color": "#B9B09C", "order": 0, "is_default": true}],
  "items": [{"occurrence_id": "…", "task_id": "…", "list_id": "1", "title": "…", "undated": false, "all_day": true,
             "start_date": "2026-11-24", "end_date": "2026-11-24", "status": "pending",
             "important": false, "urgent": false, "collected": false, "repeating": false, "habit": false,
             "source": {"kind": "biandan", "name": "便单"}}]
}
```

`items` 的字段和第 2 节完整模式相同（`list_name`、`overdue`、`quadrant`、`quadrant_name` 由服务端算出，不用推）。服务端会检查格式：`occurrence_id` 不能重复，日期必须是 `YYYY-MM-DD`，时刻必须是 `HH:MM`；找不到分类的日程归到默认分类。最多 1000 个分类、50000 条日程。

返回 `{"ok":true,"version":"…","changed":true,"lists":7,"items":52,"received_at":"…"}`，`changed` 表示内容和上一份是否不同。格式错误时返回 400，`code` 为 `invalid_json` 或 `invalid_snapshot`。

## 8. 部署和运维

| 项目 | 位置 |
| --- | --- |
| 源码 | 本目录（Go 1.22+，只用标准库） |
| 部署 | `./deploy.sh`：测试 → 编译 linux/amd64 → 上传 → 重启服务 → 配置 nginx（先备份，`nginx -t` 不通过自动还原）→ 检查公网 |
| 检查 | `./deploy.sh --check` |
| 程序 | `/usr/local/bin/biandan-api`，systemd 服务 `biandan-api`，用户 `biandan-api`，只监听 `127.0.0.1:18730` |
| 密钥文件 | `/etc/biandan-api/keys`（`root:biandan-api 640`），每行「角色 名称 sha256:哈希」；改完 `systemctl reload biandan-api` 生效 |
| 数据 | `/var/lib/biandan-api/snapshot.json`（先写临时文件再改名，重启后读回） |
| nginx | `/etc/nginx/snippets/biandan-api.conf`，由 `/etc/nginx/conf.d/default.conf` 的 443 段 include |
| 日志 | `journalctl -u biandan-api`（只记推送、认证失败，不记日程内容） |

本地测试：`go test ./...`；公网端到端测试：`BIANDAN_E2E=1 go test -run TestE2E -v .`（用 `~/.biandan-api/read-esp32.key` 读公网接口，检查数据新鲜度、分组和条数、分类数量、常用查询、`if_version` 和鉴权，只打印数量；`BIANDAN_E2E_EXPECT_ITEMS=<条数>` 可以和本机数据库核对）；便单 App 实推测试：在 `BiandanMac` 目录运行 `BIANDAN_LIVE_PUSH=1 swift test --filter SchedulePushTests/testLivePush`（复制本机数据库后推送，只打印数量）。
