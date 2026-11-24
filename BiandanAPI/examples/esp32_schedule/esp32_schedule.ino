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
