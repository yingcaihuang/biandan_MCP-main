package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// 内容没变的上报也要更新最后上报时间，并且重启、压缩之后都不丢。
func TestDataLastReportPersists(t *testing.T) {
	dir := t.TempDir()
	st, err := newDataStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	batch := func(now time.Time, by string) []*dataRecord {
		r, err := parseDataRecord(json.RawMessage(`{"id":"d","ts":"2026-11-25","n":1}`), time.UTC, now)
		if err != nil {
			t.Fatal(err)
		}
		r.By = by
		return []*dataRecord{r}
	}
	check := func(st *dataStore, want time.Time, by, label string) {
		t.Helper()
		v := st.view("t")
		if v == nil || !v.LastReport.Equal(want) || v.LastBy != by {
			t.Fatalf("%s：最后上报时间应为 %v（%s），实际 %+v", label, want, by, v)
		}
	}
	t1 := time.Date(2026, 11, 25, 8, 0, 0, 0, time.UTC)
	t2 := t1.Add(3 * time.Hour)
	if res, err := st.ingest("t", batch(t1, "a"), false, nil, "a", t1); err != nil || !res.Changed {
		t.Fatalf("第一次上报：%+v %v", res, err)
	}
	version := st.view("t").Version
	if res, err := st.ingest("t", batch(t2, "b"), false, nil, "b", t2); err != nil || res.Changed || res.Version != version {
		t.Fatalf("内容没变应不改版本号：%+v %v", res, err)
	}
	check(st, t2, "b", "没变的上报")

	st2, err := newDataStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	check(st2, t2, "b", "重启后")
	if st2.view("t").Version != version {
		t.Errorf("重启后版本号变了")
	}

	// 大量没变的上报会触发压缩，压缩后最后上报时间也要保留
	last := t2
	for i := 1; i <= 1100; i++ {
		last = t2.Add(time.Duration(i) * time.Minute)
		if _, err := st2.ingest("t", batch(last, "c"), false, nil, "c", last); err != nil {
			t.Fatal(err)
		}
	}
	data, _ := os.ReadFile(filepath.Join(dir, "t.log"))
	if n := strings.Count(string(data), "\n"); n > 200 {
		t.Errorf("日志应已压缩，实际 %d 行", n)
	}
	st3, err := newDataStore(dir, 0)
	if err != nil {
		t.Fatal(err)
	}
	check(st3, last, "c", "压缩并重启后")
	if v := st3.view("t"); len(v.Records) != 1 || v.Version != version {
		t.Errorf("压缩后数据或版本号不对：%+v", v)
	}
}

// records、stats（包括 not_modified）的返回都带最后上报时间。
func TestDataLastReportInResponses(t *testing.T) {
	s := newDataServer(t, t.TempDir())
	ingestOK(t, s, tokenRecords)
	has := func(out map[string]any, label string) {
		t.Helper()
		if at, _ := out["last_report_at"].(string); at == "" || out["last_report_by"] != "tokenbot" || out["last_report_age_seconds"] == nil {
			t.Errorf("%s 应带最后上报时间：%v", label, out)
		}
	}
	out := readOK(t, s, "/v1/data/records", `{"dataset":"token-usage","limit":1}`)
	has(out, "records")
	version := out["version"].(string)
	has(readOK(t, s, "/v1/data/stats", `{"dataset":"token-usage"}`), "stats")
	nm := readOK(t, s, "/v1/data/stats", `{"dataset":"token-usage","if_version":"`+version+`"}`)
	if nm["not_modified"] != true {
		t.Fatalf("if_version：%v", nm)
	}
	has(nm, "not_modified")
	has(readOK(t, s, "/v1/data/datasets", `{"dataset":"token-usage"}`)["datasets"].([]any)[0].(map[string]any), "datasets")
}
