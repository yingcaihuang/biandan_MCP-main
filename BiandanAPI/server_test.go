package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	testPush = "bdp_test-push-key-0000000000000000000000000000"
	testRead = "bdr_test-read-key-0000000000000000000000000000"
)

// 北京时间 2026-11-24（周二）10:00。
var fixedNow = time.Date(2026, 11, 24, 2, 0, 0, 0, time.UTC)

const sample = `{
 "format":"biandan-schedule","version":1,"generated_at":"2026-11-24T09:58:00+08:00",
 "timezone":"Asia/Shanghai","device":"test-mac",
 "lists":[
  {"id":"1002","name":"生活","color":"#5DB65A","order":2},
  {"id":"1","name":"未分类","color":"#B9B09C","order":0,"is_default":true},
  {"id":"1001","name":"工作","color":"#E5483A","order":1}
 ],
 "items":[
  {"occurrence_id":"a","task_id":"ta","list_id":"1001","title":"周会","remark":"三楼会议室","start_date":"2026-11-24","end_date":"2026-11-24","start_time":"09:00","end_time":"10:00","status":"pending","important":true,"urgent":true,"source":{"kind":"caldav","name":"公司日历"}},
  {"occurrence_id":"b","task_id":"tb","list_id":"1002","title":"买菜","start_date":"2026-11-24","all_day":true,"status":"completed","completed_at":"2026-11-24 08:30:00"},
  {"occurrence_id":"c","task_id":"tc","list_id":"1001","title":"交周报","start_date":"2026-11-20","end_date":"2026-11-20","all_day":true,"status":"pending"},
  {"occurrence_id":"d","task_id":"td","list_id":"1","title":"读书","undated":true,"status":"pending"},
  {"occurrence_id":"e","task_id":"te","list_id":"1002","title":"体检","start_date":"2026-11-26","start_time":"14:00","end_time":"15:00","status":"abandoned","source":{"kind":"system","name":"日历"}},
  {"occurrence_id":"f","task_id":"tf","list_id":"9999","title":"孤儿","start_date":"2026-11-25","all_day":true,"status":"pending"}
 ]}`

func keyLine(role, name, token string) string {
	digest := hashKey(token)
	return fmt.Sprintf("%s %s sha256:%s\n", role, name, hex.EncodeToString(digest[:]))
}

func newTestServer(t *testing.T, dir string) *server {
	t.Helper()
	keys := filepath.Join(dir, "keys")
	if _, err := os.Stat(keys); err != nil {
		content := "# 测试密钥\n" + keyLine("push", "mac", testPush) + keyLine("read", "esp32", testRead)
		if err := os.WriteFile(keys, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	s, err := newServer(keys, filepath.Join(dir, "data"))
	if err != nil {
		t.Fatal(err)
	}
	s.now = func() time.Time { return fixedNow }
	return s
}

func call(t *testing.T, s *server, method, path, token, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, req)
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("%s %s 返回的不是 JSON：%q", method, path, rec.Body.String())
	}
	return rec.Code, out
}

func pushed(t *testing.T) *server {
	t.Helper()
	s := newTestServer(t, t.TempDir())
	if code, out := call(t, s, "POST", "/v1/push", testPush, sample); code != 200 {
		t.Fatalf("推送失败 %d %v", code, out)
	}
	return s
}

func groups(t *testing.T, out map[string]any) []map[string]any {
	t.Helper()
	raw, _ := out["groups"].([]any)
	result := make([]map[string]any, len(raw))
	for i, g := range raw {
		result[i] = g.(map[string]any)
	}
	return result
}

func itemIDs(group map[string]any) string {
	var ids []string
	for _, item := range group["items"].([]any) {
		ids = append(ids, item.(map[string]any)["occurrence_id"].(string))
	}
	return strings.Join(ids, ",")
}

func errorCode(out map[string]any) string {
	if e, ok := out["error"].(map[string]any); ok {
		return e["code"].(string)
	}
	return ""
}

func TestHealthAndRouting(t *testing.T) {
	s := newTestServer(t, t.TempDir())
	for _, path := range []string{"/v1/health", "/biandan/api/v1/health"} {
		code, out := call(t, s, "GET", path, "", "")
		if code != 200 || out["ok"] != true || out["has_data"] != false {
			t.Fatalf("%s：%d %v", path, code, out)
		}
	}
	if code, out := call(t, s, "POST", "/v1/nothing", "", ""); code != 404 || errorCode(out) != "not_found" {
		t.Fatalf("未知路径：%d %v", code, out)
	}
}

func TestAuth(t *testing.T) {
	s := newTestServer(t, t.TempDir())
	cases := []struct {
		method, path, token string
		code                int
		err                 string
	}{
		{"POST", "/v1/schedule", "", 401, "unauthorized"},
		{"POST", "/v1/schedule", "wrong", 401, "unauthorized"},
		{"POST", "/v1/schedule", testPush, 401, "unauthorized"}, // 推送密钥不能读
		{"POST", "/v1/push", testRead, 401, "unauthorized"},     // 读取密钥不能推送
		{"GET", "/v1/schedule", testRead, 405, "method_not_allowed"},
		{"POST", "/v1/schedule", testRead, 503, "no_data"},
	}
	for _, c := range cases {
		code, out := call(t, s, c.method, c.path, c.token, "")
		if code != c.code || errorCode(out) != c.err {
			t.Errorf("%s %s 密钥 %q：得到 %d %v，应为 %d %s", c.method, c.path, c.token, code, out, c.code, c.err)
		}
	}
}

func TestAuthFailureLimit(t *testing.T) {
	s := newTestServer(t, t.TempDir())
	for i := 0; i < 20; i++ {
		call(t, s, "POST", "/v1/lists", "wrong", "")
	}
	if code, out := call(t, s, "POST", "/v1/lists", testRead, ""); code != 429 || errorCode(out) != "too_many_failures" {
		t.Fatalf("失败 20 次后应被限流：%d %v", code, out)
	}
}

func TestPushChangedAndPersisted(t *testing.T) {
	dir := t.TempDir()
	s := newTestServer(t, dir)
	code, first := call(t, s, "POST", "/v1/push", testPush, sample)
	if code != 200 || first["changed"] != true || first["items"] != float64(6) || first["lists"] != float64(3) {
		t.Fatalf("第一次推送：%d %v", code, first)
	}
	_, second := call(t, s, "POST", "/v1/push", testPush, sample)
	if second["changed"] != false || second["version"] != first["version"] {
		t.Fatalf("内容没变时 changed 应为 false：%v", second)
	}
	// 只有生成时间和设备名不同，版本号也不变。
	retimed := strings.Replace(strings.Replace(sample, "2026-11-24T09:58:00+08:00", "2026-11-24T09:59:30+08:00", 1), `"test-mac"`, `"other-mac"`, 1)
	_, third := call(t, s, "POST", "/v1/push", testPush, retimed)
	if third["changed"] != false || third["version"] != first["version"] {
		t.Fatalf("只改生成时间时版本号不该变：%v", third)
	}
	// 重启后从磁盘读回同一份数据。
	restarted := newTestServer(t, dir)
	_, out := call(t, restarted, "POST", "/v1/schedule", testRead, "")
	if out["version"] != first["version"] || out["total"] != float64(6) {
		t.Fatalf("重启后：%v", out)
	}
}

func TestPushRejectsBadSnapshot(t *testing.T) {
	s := newTestServer(t, t.TempDir())
	cases := map[string]string{
		"格式不对":    `{"format":"other","version":1}`,
		"版本不对":    `{"format":"biandan-schedule","version":2}`,
		"状态不对":    `{"format":"biandan-schedule","version":1,"items":[{"occurrence_id":"x","status":"done"}]}`,
		"日期不对":    `{"format":"biandan-schedule","version":1,"items":[{"occurrence_id":"x","status":"pending","start_date":"2026/11/24"}]}`,
		"重复 ID":   `{"format":"biandan-schedule","version":1,"items":[{"occurrence_id":"x","status":"pending"},{"occurrence_id":"x","status":"pending"}]}`,
		"不是 JSON": `{`,
	}
	for name, body := range cases {
		if code, out := call(t, s, "POST", "/v1/push", testPush, body); code != 400 {
			t.Errorf("%s：%d %v", name, code, out)
		}
	}
	if code, out := call(t, s, "POST", "/v1/push", testPush, strings.Repeat(" ", maxPushBody+1)); code != 413 {
		t.Errorf("超大请求体：%d %v", code, out)
	}
}

func TestQueryAllGroupedByList(t *testing.T) {
	s := pushed(t)
	code, out := call(t, s, "POST", "/v1/schedule", testRead, "")
	if code != 200 || out["total"] != float64(6) || out["today"] != "2026-11-24" || out["truncated"] != false {
		t.Fatalf("%d %v", code, out)
	}
	got := groups(t, out)
	want := []struct{ id, name, items string }{
		{"1", "未分类", "f,d"}, // 找不到分类的 f 归到默认分类；无日期的 d 排最后
		{"1001", "工作", "c,a"},
		{"1002", "生活", "b,e"},
	}
	if len(got) != len(want) {
		t.Fatalf("分组数 %d：%v", len(got), got)
	}
	for i, w := range want {
		if got[i]["id"] != w.id || got[i]["name"] != w.name || itemIDs(got[i]) != w.items {
			t.Errorf("第 %d 组：%v %v %s，应为 %v", i, got[i]["id"], got[i]["name"], itemIDs(got[i]), w)
		}
	}
	work := got[1]["items"].([]any)
	c, a := work[0].(map[string]any), work[1].(map[string]any)
	if c["overdue"] != true || a["overdue"] != false {
		t.Errorf("逾期判断不对：c=%v a=%v", c["overdue"], a["overdue"])
	}
	if a["quadrant"] != float64(1) || a["quadrant_name"] != "重要且紧急" || a["list_name"] != "工作" {
		t.Errorf("象限或分类名不对：%v", a)
	}
	if src := a["source"].(map[string]any); src["kind"] != "caldav" || src["name"] != "公司日历" {
		t.Errorf("来源不对：%v", src)
	}
	if src := c["source"].(map[string]any); src["kind"] != "biandan" {
		t.Errorf("没写来源时应为 biandan：%v", src)
	}
}

func TestQueryFilters(t *testing.T) {
	s := pushed(t)
	cases := []struct {
		name, body string
		total      int
		groups     string // 组 id:实例 id，逗号分隔，分号分隔各组
	}{
		{"今天", `{"start":"today"}`, 2, "1001:a;1002:b"},
		{"未来 7 天未完成", `{"days":7,"status":"pending"}`, 2, "1:f;1001:a"},
		{"指定分类", `{"list_ids":["1002"]}`, 2, "1002:b,e"},
		{"今天加无日期", `{"start":"today","include_undated":true}`, 3, "1:d;1001:a;1002:b"},
		{"按日期分组", `{"start":"2026-11-20","days":7,"group_by":"date"}`, 5,
			"2026-11-20:c;2026-11-24:b,a;2026-11-25:f;2026-11-26:e"},
		{"不分组", `{"group_by":"none","status":"pending"}`, 4, "all:c,a,f,d"},
		{"截断", `{"limit":2}`, 6, "1:;1001:c;1002:b"},
	}
	for _, c := range cases {
		code, out := call(t, s, "POST", "/v1/schedule", testRead, c.body)
		if code != 200 || out["total"] != float64(c.total) {
			t.Errorf("%s：%d total=%v %v", c.name, code, out["total"], out)
			continue
		}
		var parts []string
		for _, g := range groups(t, out) {
			parts = append(parts, g["id"].(string)+":"+itemIDs(g))
		}
		if got := strings.Join(parts, ";"); got != c.groups {
			t.Errorf("%s：分组 %s，应为 %s", c.name, got, c.groups)
		}
	}
	_, out := call(t, s, "POST", "/v1/schedule", testRead, `{"start":"2026-11-20","days":7,"group_by":"date"}`)
	if name := groups(t, out)[0]["name"]; name != "11月20日 周五" {
		t.Errorf("日期分组名：%v", name)
	}
	_, out = call(t, s, "POST", "/v1/schedule", testRead, `{"limit":2}`)
	if out["truncated"] != true || out["returned"] != float64(2) {
		t.Errorf("截断标记：%v", out)
	}
	if g := groups(t, out)[0]; g["total"] != float64(2) || g["count"] != float64(0) {
		t.Errorf("截断后分组计数：%v", g)
	}
}

func TestQueryCompactAndVersion(t *testing.T) {
	s := pushed(t)
	_, out := call(t, s, "POST", "/v1/schedule", testRead, `{"fields":"compact","start":"today"}`)
	item := groups(t, out)[0]["items"].([]any)[0].(map[string]any)
	for _, field := range []string{"remark", "source", "list_name", "quadrant"} {
		if _, ok := item[field]; ok {
			t.Errorf("精简模式不该有 %s：%v", field, item)
		}
	}
	if item["title"] != "周会" || item["start_time"] != "09:00" {
		t.Errorf("精简模式字段：%v", item)
	}
	version := out["version"].(string)
	for _, path := range []string{"/v1/schedule", "/v1/lists"} {
		_, again := call(t, s, "POST", path, testRead, `{"if_version":"`+version+`"}`)
		if again["not_modified"] != true || again["version"] != version || again["groups"] != nil {
			t.Errorf("%s 版本没变应只回 not_modified：%v", path, again)
		}
	}
}

func TestQueryBadRequests(t *testing.T) {
	s := pushed(t)
	for _, body := range []string{
		`{"start":"2026/11/24"}`,
		`{"status":"done"}`,
		`{"group_by":"week"}`,
		`{"start":"today","end":"yesterday"}`,
		`{"end":"today"}`,
		`{"days":3,"end":"today"}`,
		`{"days":500}`,
		`{"strat":"today"}`,
		`{"start":"today"}{}`,
		`[1]`,
	} {
		if code, out := call(t, s, "POST", "/v1/schedule", testRead, body); code != 400 || errorCode(out) != "bad_request" {
			t.Errorf("%s：%d %v", body, code, out)
		}
	}
}

func TestLists(t *testing.T) {
	s := pushed(t)
	code, out := call(t, s, "POST", "/v1/lists", testRead, "")
	if code != 200 {
		t.Fatalf("%d %v", code, out)
	}
	var got []string
	for _, raw := range out["lists"].([]any) {
		l := raw.(map[string]any)
		got = append(got, fmt.Sprintf("%s/%s/%v/%v/%v", l["id"], l["name"], l["total"], l["pending"], l["overdue"]))
	}
	if want := "1/未分类/2/2/0 1001/工作/2/2/1 1002/生活/2/0/0"; strings.Join(got, " ") != want {
		t.Fatalf("分类：%v，应为 %s", got, want)
	}
}

func TestRealIPOnlyFromLoopback(t *testing.T) {
	req := httptest.NewRequest("POST", "/v1/lists", nil)
	req.Header.Set("X-Real-IP", "203.0.113.9")
	if ip := clientIP(req); ip != "192.0.2.1" {
		t.Errorf("非本机来源不该信 X-Real-IP：%s", ip)
	}
	req.RemoteAddr = "127.0.0.1:5000"
	if ip := clientIP(req); ip != "203.0.113.9" {
		t.Errorf("本机 nginx 转发应取 X-Real-IP：%s", ip)
	}
	req.Header.Set("X-Forwarded-For", "198.51.100.7, 203.0.113.9")
	if ip := clientIP(req); ip != "198.51.100.7" {
		t.Errorf("经 ESA 时应取 X-Forwarded-For 第一个：%s", ip)
	}
	req.Header.Set("X-Forwarded-For", "not-an-ip")
	if ip := clientIP(req); ip != "203.0.113.9" {
		t.Errorf("X-Forwarded-For 不是地址时退回 X-Real-IP：%s", ip)
	}
	_ = http.StatusOK
}

func TestParseKeys(t *testing.T) {
	for _, bad := range []string{
		"push mac\n",
		"admin mac sha256:" + strings.Repeat("0", 64) + "\n",
		"push mac md5:abc\n",
		"push 名字 sha256:" + strings.Repeat("0", 64) + "\n",
		keyLine("read", "a", "x") + keyLine("read", "a", "y"),
	} {
		if _, err := parseKeys([]byte(bad)); err == nil {
			t.Errorf("应报错：%q", bad)
		}
	}
	token, err := newToken("read")
	if err != nil || !strings.HasPrefix(token, "bdr_") || len(token) != 47 {
		t.Fatalf("newToken：%q %v", token, err)
	}
}
