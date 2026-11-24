package main

// 端到端测试：直接请求公网接口，确认能读到便单 App 推上来的数据。默认跳过。
//
//	BIANDAN_E2E=1 go test -run TestE2E -v .
//
// 可选环境变量：
//
//	BIANDAN_API_PUBLIC      接口地址，默认 https://www.aigslb.link/biandan/api
//	BIANDAN_E2E_READ_KEY    读取密钥文件，默认 ~/.biandan-api/read-esp32.key
//	BIANDAN_E2E_MAX_AGE     数据最多多少秒没更新，默认 660（App 每 10 分钟心跳一次）
//	BIANDAN_E2E_EXPECT_ITEMS 期望的日程条数（和本机数据库核对时用），不设就不核对
//
// 只打印数量和版本，不打印日程标题。

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

type e2eClient struct {
	t    *testing.T
	base string
	key  string
	http *http.Client
}

func newE2E(t *testing.T) *e2eClient {
	t.Helper()
	if os.Getenv("BIANDAN_E2E") != "1" {
		t.Skip("设置 BIANDAN_E2E=1 才请求公网接口")
	}
	base := strings.TrimRight(env("BIANDAN_API_PUBLIC", "https://www.aigslb.link/biandan/api"), "/")
	home, _ := os.UserHomeDir()
	keyFile := env("BIANDAN_E2E_READ_KEY", filepath.Join(home, ".biandan-api", "read-esp32.key"))
	raw, err := os.ReadFile(keyFile)
	if err != nil {
		t.Fatalf("读不到读取密钥 %s：%v", keyFile, err)
	}
	key := strings.TrimSpace(string(raw))
	if !strings.HasPrefix(key, "bdr_") || len(key) != 47 {
		t.Fatalf("%s 里不是读取密钥（应为 bdr_ 开头的 47 个字符）", keyFile)
	}
	return &e2eClient{t: t, base: base, key: key, http: &http.Client{Timeout: 20 * time.Second}}
}

// do 发请求，返回 HTTP 状态码和解析后的 JSON。token 为空时不带 Authorization。
func (c *e2eClient) do(method, path, token, body string) (int, map[string]any) {
	c.t.Helper()
	req, err := http.NewRequest(method, c.base+path, strings.NewReader(body))
	if err != nil {
		c.t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		c.t.Fatalf("%s %s 请求失败：%v", method, path, err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	if cc := resp.Header.Get("Cache-Control"); !strings.Contains(cc, "no-store") {
		c.t.Errorf("%s %s 的 Cache-Control 应为 no-store，实际 %q", method, path, cc)
	}
	var out map[string]any
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(&out); err != nil {
		c.t.Fatalf("%s %s 返回的不是 JSON（HTTP %d，%d 字节）", method, path, resp.StatusCode, len(data))
	}
	return resp.StatusCode, out
}

func (c *e2eClient) query(body string) map[string]any {
	c.t.Helper()
	code, out := c.do("POST", "/v1/schedule", c.key, body)
	if code != 200 || out["ok"] != true {
		c.t.Fatalf("查询 %s：HTTP %d %v", body, code, out["error"])
	}
	return out
}

func num(v any) int {
	switch n := v.(type) {
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	case float64:
		return int(n)
	}
	return -1
}

func e2eGroups(out map[string]any) []map[string]any {
	raw, _ := out["groups"].([]any)
	groups := make([]map[string]any, 0, len(raw))
	for _, g := range raw {
		if m, ok := g.(map[string]any); ok {
			groups = append(groups, m)
		}
	}
	return groups
}

func e2eItems(group map[string]any) []map[string]any {
	raw, _ := group["items"].([]any)
	items := make([]map[string]any, 0, len(raw))
	for _, it := range raw {
		if m, ok := it.(map[string]any); ok {
			items = append(items, m)
		}
	}
	return items
}

func TestE2E(t *testing.T) {
	c := newE2E(t)
	maxAge, _ := strconv.Atoi(env("BIANDAN_E2E_MAX_AGE", "660"))

	t.Run("健康检查：有数据且是新的", func(t *testing.T) {
		code, out := c.do("GET", "/v1/health", "", "")
		if code != 200 || out["service"] != "biandan-api" {
			t.Fatalf("HTTP %d %v", code, out)
		}
		if out["has_data"] != true {
			t.Fatal("服务器还没收到过推送")
		}
		age := num(out["data_age_seconds"])
		t.Logf("服务 %v，数据 %d 秒前更新", out["version"], age)
		if age < 0 || age > maxAge {
			t.Errorf("数据 %d 秒没更新（上限 %d）：App 可能没在推送", age, maxAge)
		}
	})

	var all map[string]any
	t.Run("全部日程：分组、字段、条数", func(t *testing.T) {
		all = c.query(`{"limit":2000}`)
		total, returned := num(all["total"]), num(all["returned"])
		if total <= 0 {
			t.Fatalf("total=%d，没有读到日程", total)
		}
		if returned != total || all["truncated"] != false {
			t.Errorf("returned=%d total=%d truncated=%v", returned, total, all["truncated"])
		}
		if want := os.Getenv("BIANDAN_E2E_EXPECT_ITEMS"); want != "" && strconv.Itoa(total) != want {
			t.Errorf("服务器有 %d 条日程，本机数据库是 %s 条", total, want)
		}
		sum, seen := 0, map[string]bool{}
		sources := map[string]int{}
		status := map[string]int{}
		for _, g := range e2eGroups(all) {
			items := e2eItems(g)
			if num(g["total"]) != len(items) || num(g["count"]) != len(items) {
				t.Errorf("分组 %v：total=%v count=%v 实际 %d 条", g["id"], g["total"], g["count"], len(items))
			}
			if name, _ := g["name"].(string); name == "" {
				t.Errorf("分组 %v 没有名称", g["id"])
			}
			for _, it := range items {
				sum++
				id, _ := it["occurrence_id"].(string)
				if id == "" || seen[id] {
					t.Errorf("occurrence_id 为空或重复：%q", id)
				}
				seen[id] = true
				if it["list_id"] != g["id"] {
					t.Errorf("日程 %s 的 list_id=%v，却在分组 %v 里", id, it["list_id"], g["id"])
				}
				if title, _ := it["title"].(string); strings.TrimSpace(title) == "" {
					t.Logf("注意：日程 %s 没有标题", id)
				}
				st, _ := it["status"].(string)
				if !statuses[st] {
					t.Errorf("日程 %s 的 status=%q", id, st)
				}
				status[st]++
				if it["undated"] != true {
					sd, _ := it["start_date"].(string)
					ed, _ := it["end_date"].(string)
					if !validDate(sd) || !validDate(ed) || ed < sd {
						t.Errorf("日程 %s 的日期不对：%q–%q", id, sd, ed)
					}
					for _, f := range []string{"start_time", "end_time"} {
						if v, ok := it[f].(string); ok && !validClock(v) {
							t.Errorf("日程 %s 的 %s=%q", id, f, v)
						}
					}
				}
				if src, ok := it["source"].(map[string]any); ok {
					kind, _ := src["kind"].(string)
					if !sourceKinds[kind] {
						t.Errorf("日程 %s 的 source.kind=%q", id, kind)
					}
					sources[kind]++
				} else {
					t.Errorf("日程 %s 没有 source", id)
				}
			}
		}
		if sum != total {
			t.Errorf("各分组合计 %d 条，total=%d", sum, total)
		}
		t.Logf("版本 %v，%d 条日程，%d 个分组，状态 %v，来源 %v，今天 %v",
			all["version"], total, len(e2eGroups(all)), status, sources, all["today"])
	})
	if all == nil {
		t.FailNow()
	}
	version, _ := all["version"].(string)

	t.Run("分类接口和日程对得上", func(t *testing.T) {
		code, out := c.do("POST", "/v1/lists", c.key, "")
		if code != 200 || out["ok"] != true {
			t.Fatalf("HTTP %d %v", code, out["error"])
		}
		perGroup := map[string]int{}
		for _, g := range e2eGroups(all) {
			perGroup[g["id"].(string)] = num(g["total"])
		}
		lists, _ := out["lists"].([]any)
		if len(lists) == 0 {
			t.Fatal("没有分类")
		}
		defaults, sum := 0, 0
		for _, raw := range lists {
			l := raw.(map[string]any)
			id, _ := l["id"].(string)
			if l["is_default"] == true {
				defaults++
			}
			if color, _ := l["color"].(string); color != "" && !colorPattern.MatchString(color) {
				t.Errorf("分类 %s 的颜色 %q", id, color)
			}
			if num(l["total"]) != perGroup[id] {
				t.Errorf("分类 %s：/v1/lists 说 %v 条，/v1/schedule 分组是 %d 条", id, l["total"], perGroup[id])
			}
			if num(l["pending"]) > num(l["total"]) || num(l["overdue"]) > num(l["pending"]) {
				t.Errorf("分类 %s 的数量不合理：total=%v pending=%v overdue=%v", id, l["total"], l["pending"], l["overdue"])
			}
			sum += num(l["total"])
		}
		if defaults != 1 {
			t.Errorf("默认分类有 %d 个，应为 1 个", defaults)
		}
		if sum != num(all["total"]) {
			t.Errorf("各分类合计 %d 条，日程 total=%v", sum, all["total"])
		}
		if out["version"] != version {
			t.Logf("两次请求之间数据更新了（%v → %v）", version, out["version"])
		}
		t.Logf("%d 个分类", len(lists))
	})

	t.Run("ESP32 常用查询", func(t *testing.T) {
		today := c.query(`{"start":"today","fields":"compact"}`)
		for _, g := range e2eGroups(today) {
			for _, it := range e2eItems(g) {
				if _, ok := it["source"]; ok {
					t.Error("精简模式不该有 source")
				}
				sd, _ := it["start_date"].(string)
				ed, _ := it["end_date"].(string)
				day, _ := today["today"].(string)
				if sd > day || ed < day {
					t.Errorf("今天的查询里出现 %s–%s 的日程", sd, ed)
				}
			}
		}
		week := c.query(`{"days":7,"status":"pending","group_by":"date","fields":"compact"}`)
		prev := ""
		for _, g := range e2eGroups(week) {
			id, _ := g["id"].(string)
			if !validDate(id) || id <= prev {
				t.Errorf("按日期分组的顺序或 id 不对：%q（前一组 %q）", id, prev)
			}
			prev = id
			for _, it := range e2eItems(g) {
				if it["status"] != "pending" {
					t.Errorf("只查待完成，却返回了 %v", it["status"])
				}
			}
		}
		t.Logf("今天 %v 条；未来 7 天待完成 %v 条，%d 天有日程", today["total"], week["total"], len(e2eGroups(week)))

		cur, _ := week["version"].(string)
		same := c.query(`{"if_version":"` + cur + `","fields":"compact"}`)
		if same["version"] == cur && same["not_modified"] != true {
			t.Errorf("版本没变时应只回 not_modified：%v", same)
		}
		if _, ok := same["groups"]; ok && same["not_modified"] == true {
			t.Error("not_modified 时不该带 groups")
		}
		stale := c.query(`{"if_version":"0000000000000000","start":"today"}`)
		if stale["not_modified"] == true || stale["groups"] == nil {
			t.Errorf("版本不同时应返回完整数据：%v", stale)
		}
	})

	t.Run("鉴权", func(t *testing.T) {
		for name, token := range map[string]string{"不带密钥": "", "错误密钥": "bdr_" + strings.Repeat("x", 43)} {
			code, out := c.do("POST", "/v1/schedule", token, "")
			if code != 401 {
				t.Errorf("%s 应返回 401，实际 %d %v", name, code, out)
			}
		}
	})
}
