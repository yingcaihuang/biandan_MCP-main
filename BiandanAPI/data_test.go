package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const testReport = "bdu_test-report-key-00000000000000000000000000"

// newDataServer：带 push、read、report 三把测试密钥的服务。
func newDataServer(t *testing.T, dir string) *server {
	t.Helper()
	keys := filepath.Join(dir, "keys")
	if _, err := os.Stat(keys); err != nil {
		content := keyLine("push", "mac", testPush) + keyLine("read", "esp32", testRead) + keyLine("report", "tokenbot", testReport)
		if err := os.WriteFile(keys, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return newTestServer(t, dir)
}

const tokenRecords = `{"dataset":"token-usage","records":[
 {"id":"d1-gpt","ts":"2026-11-23 12:00:00","model":"gpt","input":100,"output":50,"cost":0.1},
 {"id":"d1-claude","ts":"2026-11-23 13:00","model":"claude","input":200,"output":80,"cost":0.25},
 {"id":"d2-gpt","ts":"2026-11-24 09:00","model":"gpt","input":300,"output":120,"cost":0.3,"usage":{"cache":10},"tags":["a"]}
]}`

func ingestOK(t *testing.T, s *server, body string) map[string]any {
	t.Helper()
	code, out := call(t, s, "POST", "/v1/data/ingest", testReport, body)
	if code != 200 || out["ok"] != true {
		t.Fatalf("上报失败：HTTP %d %v", code, out)
	}
	return out
}

func readOK(t *testing.T, s *server, path, body string) map[string]any {
	t.Helper()
	code, out := call(t, s, "POST", path, testRead, body)
	if code != 200 || out["ok"] != true {
		t.Fatalf("%s %s：HTTP %d %v", path, body, code, out)
	}
	return out
}

func TestDataRoles(t *testing.T) {
	s := newDataServer(t, t.TempDir())
	for _, c := range []struct{ path, token string }{
		{"/v1/data/ingest", testPush}, {"/v1/data/ingest", testRead}, {"/v1/data/ingest", ""},
		{"/v1/data/records", testReport}, {"/v1/data/stats", testReport}, {"/v1/data/datasets", testReport},
		{"/v1/schedule", testReport}, {"/v1/push", testReport},
	} {
		if code, _ := call(t, s, "POST", c.path, c.token, tokenRecords); code != 401 {
			t.Errorf("%s 用 %.8s 应返回 401，实际 %d", c.path, c.token, code)
		}
	}
	if code, _ := call(t, s, "GET", "/v1/data/ingest", testReport, ""); code != 405 {
		t.Errorf("GET 应返回 405，实际 %d", code)
	}
	if code, out := call(t, s, "POST", "/v1/data/records", testRead, `{"dataset":"token-usage"}`); code != 404 {
		t.Errorf("没上报过应返回 404，实际 %d %v", code, out)
	}
}

func TestDataIngestUpsert(t *testing.T) {
	s := newDataServer(t, t.TempDir())
	out := ingestOK(t, s, tokenRecords)
	if out["inserted"] != 3.0 || out["total"] != 3.0 || out["changed"] != true {
		t.Fatalf("第一次上报：%v", out)
	}
	v1 := out["version"]
	out = ingestOK(t, s, tokenRecords)
	if out["unchanged"] != 3.0 || out["changed"] != false || out["version"] != v1 {
		t.Errorf("重复上报应不变：%v", out)
	}
	out = ingestOK(t, s, `{"dataset":"token-usage","record":{"id":"d2-gpt","ts":"2026-11-24 09:00","model":"gpt","input":350,"output":120,"cost":0.3}}`)
	if out["updated"] != 1.0 || out["total"] != 3.0 || out["version"] == v1 {
		t.Errorf("同一 id 应覆盖：%v", out)
	}
	// 不带 id 每次追加；不带 ts 用接收时间
	ingestOK(t, s, `{"dataset":"token-usage","record":{"model":"gpt","input":1}}`)
	out = ingestOK(t, s, `{"dataset":"token-usage","record":{"model":"gpt","input":1}}`)
	if out["inserted"] != 1.0 || out["total"] != 5.0 {
		t.Errorf("不带 id 应追加：%v", out)
	}
	out = ingestOK(t, s, `{"dataset":"token-usage","delete_ids":["d1-gpt","nope"]}`)
	if out["deleted"] != 1.0 || out["total"] != 4.0 {
		t.Errorf("delete_ids：%v", out)
	}
	out = ingestOK(t, s, `{"dataset":"token-usage","replace":true,"records":[]}`)
	if out["total"] != 0.0 {
		t.Errorf("replace 空数组应清空：%v", out)
	}
	if code, _ := call(t, s, "POST", "/v1/data/stats", testRead, `{"dataset":"token-usage"}`); code != 404 {
		t.Errorf("清空后应返回 404，实际 %d", code)
	}
	// 超过保留期（默认 400 天）的不保存
	out = ingestOK(t, s, `{"dataset":"old","records":[{"id":"x","ts":"2025-01-01","n":1},{"id":"y","ts":1764000000,"n":2}]}`)
	if out["expired"] != 1.0 || out["total"] != 1.0 {
		t.Errorf("保留期：%v", out)
	}
}

func TestDataIngestValidation(t *testing.T) {
	s := newDataServer(t, t.TempDir())
	for _, body := range []string{
		`{"dataset":"Token","record":{"n":1}}`,
		`{"dataset":"../x","record":{"n":1}}`,
		`{"dataset":"t","records":[]}`,
		`{"dataset":"t","record":{"bad name":1}}`,
		`{"dataset":"t","record":{"ts":"昨天"}}`,
		`{"dataset":"t","record":{"ts":"2099-01-01"}}`,
		`{"dataset":"t","record":{"id":true}}`,
		`{"dataset":"t","record":[1,2]}`,
		`{"dataset":"t","record":{"n":1},"records":[{"n":2}]}`,
		`{"dataset":"t","record":{"n":1},"unknown":1}`,
		`{"dataset":"t","record":{"n":1},"timezone":"Mars/Base"}`,
		`{"dataset":"t","replace":true,"delete_ids":["a"]}`,
	} {
		if code, out := call(t, s, "POST", "/v1/data/ingest", testReport, body); code != 400 {
			t.Errorf("%s 应返回 400，实际 %d %v", body, code, out)
		}
	}
	big := `{"dataset":"t","record":{"s":"` + strings.Repeat("x", 17<<10) + `"}}`
	if code, _ := call(t, s, "POST", "/v1/data/ingest", testReport, big); code != 400 {
		t.Errorf("超过 16 KB 的记录应返回 400，实际 %d", code)
	}
}

func TestDataQueries(t *testing.T) {
	s := newDataServer(t, t.TempDir())
	ingestOK(t, s, tokenRecords)

	out := readOK(t, s, "/v1/data/records", `{"dataset":"token-usage","where":{"model":"gpt"},"order":"asc","fields":["input","usage.cache"]}`)
	recs := out["records"].([]any)
	if out["total"] != 2.0 || len(recs) != 2 {
		t.Fatalf("按 model 筛选：%v", out)
	}
	first, second := recs[0].(map[string]any), recs[1].(map[string]any)
	if first["id"] != "d1-gpt" || first["ts"] != "2026-11-23T12:00:00+08:00" || first["model"] != nil || second["usage.cache"] != 10.0 {
		t.Errorf("明细字段：%v %v", first, second)
	}
	out = readOK(t, s, "/v1/data/records", `{"dataset":"token-usage","limit":1}`)
	if r := out["records"].([]any)[0].(map[string]any); r["id"] != "d2-gpt" || out["truncated"] != true || r["model"] != "gpt" {
		t.Errorf("默认最新在前、全部字段：%v", out)
	}
	out = readOK(t, s, "/v1/data/records", `{"dataset":"token-usage","where":{"model":["claude","x"],"input":200}}`)
	if out["total"] != 1.0 {
		t.Errorf("where 数组和数字：%v", out)
	}
	if out := readOK(t, s, "/v1/data/records", `{"dataset":"token-usage","if_version":"`+out["version"].(string)+`"}`); out["not_modified"] != true {
		t.Errorf("if_version：%v", out)
	}

	out = readOK(t, s, "/v1/data/stats", `{"dataset":"token-usage","bucket":"day","group_by":["model"]}`)
	groups := out["groups"].([]any)
	totals := out["totals"].(map[string]any)["sum"].(map[string]any)
	if len(groups) != 3 || totals["input"] != 600.0 || totals["cost"] != 0.65 || totals["output"] != 250.0 {
		t.Fatalf("按天、model 汇总：%v", out)
	}
	if g := groups[0].(map[string]any); g["bucket"] != "2026-11-23" || g["model"] != "claude" || g["count"] != 1.0 {
		t.Errorf("第一组：%v", g)
	}
	out = readOK(t, s, "/v1/data/stats", `{"dataset":"token-usage","days":1,"sum":["input","usage.cache"]}`)
	if tot := out["totals"].(map[string]any); tot["count"] != 1.0 || tot["sum"].(map[string]any)["usage.cache"] != 10.0 {
		t.Errorf("今天、嵌套字段求和：%v", out)
	}
	out = readOK(t, s, "/v1/data/stats", `{"dataset":"token-usage","group_by":["model"],"sort":"input","limit":1}`)
	if g := out["groups"].([]any)[0].(map[string]any); g["model"] != "gpt" || out["truncated"] != true {
		t.Errorf("按 input 从大到小：%v", out)
	}
	for _, body := range []string{
		`{"dataset":"token-usage","bucket":"minute"}`,
		`{"dataset":"token-usage","sort":"nope"}`,
		`{"dataset":"token-usage","start":"2026-11-25","end":"2026-11-24"}`,
		`{"dataset":"token-usage","days":3,"start":"today"}`,
	} {
		if code, _ := call(t, s, "POST", "/v1/data/stats", testRead, body); code != 400 {
			t.Errorf("%s 应返回 400，实际 %d", body, code)
		}
	}

	out = readOK(t, s, "/v1/data/datasets", "")
	sets := out["datasets"].([]any)
	if len(sets) != 1 {
		t.Fatalf("数据集列表：%v", out)
	}
	d := sets[0].(map[string]any)
	fields := d["fields"].(map[string]any)
	if d["records"] != 3.0 || fields["input"] != "number" || fields["model"] != "string" || fields["usage.cache"] != "number" || fields["tags"] != "array" || d["last_report_by"] != "tokenbot" {
		t.Errorf("字段类型：%v", d)
	}
	if code, out := call(t, s, "GET", "/v1/health", "", ""); code != 200 || out["datasets"] != 1.0 {
		t.Errorf("健康检查应带数据集数量：%v", out)
	}
}

func TestDataPersistence(t *testing.T) {
	dir := t.TempDir()
	s := newDataServer(t, dir)
	ingestOK(t, s, tokenRecords)
	ingestOK(t, s, `{"dataset":"token-usage","delete_ids":["d1-claude"]}`)
	version := readOK(t, s, "/v1/data/datasets", `{"dataset":"token-usage"}`)["datasets"].([]any)[0].(map[string]any)["version"]

	// 模拟断电：日志末尾留下半行
	logFile := filepath.Join(dir, "data", "datasets", "token-usage.log")
	f, err := os.OpenFile(logFile, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(`{"version":"broken","records":[{"id":"zz`)
	f.Close()

	s2 := newDataServer(t, dir)
	d := readOK(t, s2, "/v1/data/datasets", `{"dataset":"token-usage"}`)["datasets"].([]any)[0].(map[string]any)
	if d["records"] != 2.0 || d["version"] != version {
		t.Errorf("重启后应读回写坏之前的数据：%v（版本应为 %v）", d, version)
	}
	data, _ := os.ReadFile(logFile)
	if strings.Contains(string(data), "broken") || strings.Count(string(data), "\n") != 1 {
		t.Errorf("写坏的尾巴应在启动时整理掉：%q", data)
	}
	// 整理后继续上报、再重启
	ingestOK(t, s2, `{"dataset":"token-usage","record":{"id":"d3","ts":"2026-11-24 10:00","input":5}}`)
	s3 := newDataServer(t, dir)
	if out := readOK(t, s3, "/v1/data/stats", `{"dataset":"token-usage","sum":["input"]}`); out["totals"].(map[string]any)["sum"].(map[string]any)["input"] != 405.0 {
		t.Errorf("第二次重启后的汇总：%v", out)
	}
	// 日程快照不受影响
	if code, _ := call(t, s3, "POST", "/v1/schedule", testRead, ""); code != 503 {
		t.Errorf("没推过日程时 /v1/schedule 应返回 503，实际 %d", code)
	}
}
