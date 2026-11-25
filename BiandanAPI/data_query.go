package main

// 通用数据的查询接口（读取密钥）：/v1/data/records、/v1/data/stats、/v1/data/datasets。

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"slices"
	"sort"
	"strings"
	"time"
)

// ---- 公共部分 ----

type dataFilter struct {
	Dataset   string         `json:"dataset"`
	Start     string         `json:"start"`
	End       string         `json:"end"`
	Days      int            `json:"days"`
	Where     map[string]any `json:"where"`
	Timezone  string         `json:"timezone"`
	IfVersion string         `json:"if_version"`
}

// dataTimeRange：[from, to)，零值表示那一端不限。
type dataTimeRange struct{ from, to time.Time }

func (tr dataTimeRange) contains(t time.Time) bool {
	return (tr.from.IsZero() || !t.Before(tr.from)) && (tr.to.IsZero() || t.Before(tr.to))
}

func dataDayStart(t time.Time, loc *time.Location) time.Time {
	y, m, d := t.In(loc).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, loc)
}

// dataParseBound：日期、月份作 end 时包含那一整天（整月）。
func dataParseBound(s string, loc *time.Location, now time.Time, end bool) (time.Time, error) {
	s = strings.TrimSpace(s)
	after := func(t time.Time, months, days int) time.Time {
		if end {
			return t.AddDate(0, months, days)
		}
		return t
	}
	switch s {
	case "now":
		return now, nil
	case "today":
		return after(dataDayStart(now, loc), 0, 1), nil
	case "yesterday":
		return after(dataDayStart(now, loc).AddDate(0, 0, -1), 0, 1), nil
	}
	if t, err := time.ParseInLocation(dateLayout, s, loc); err == nil {
		return after(t, 0, 1), nil
	}
	if t, err := time.ParseInLocation("2006-01", s, loc); err == nil {
		return after(t, 1, 0), nil
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, nil
	}
	return time.Time{}, fmt.Errorf("时间 %q 应为 today、yesterday、now、YYYY-MM-DD、YYYY-MM 或 RFC 3339", s)
}

func dataResolveRange(f *dataFilter, loc *time.Location, now time.Time) (dataTimeRange, error) {
	var tr dataTimeRange
	if f.Days < 0 || f.Days > 3660 {
		return tr, errors.New("days 应为 1–3660")
	}
	if f.Days > 0 {
		if f.Start != "" {
			return tr, errors.New("days 和 start 只能用一个")
		}
		today := dataDayStart(now, loc)
		tr.from = today.AddDate(0, 0, 1-f.Days)
		tr.to = today.AddDate(0, 0, 1)
	}
	var err error
	if f.Start != "" {
		if tr.from, err = dataParseBound(f.Start, loc, now, false); err != nil {
			return tr, err
		}
	}
	if f.End != "" {
		if tr.to, err = dataParseBound(f.End, loc, now, true); err != nil {
			return tr, err
		}
	}
	if !tr.from.IsZero() && !tr.to.IsZero() && !tr.from.Before(tr.to) {
		return tr, errors.New("start 要早于 end")
	}
	return tr, nil
}

// dataFieldValue：按字段名取值，用点取嵌套对象里的字段（usage.input）；id 是记录的 id。
func dataFieldValue(r *dataRecord, path string) (any, bool) {
	if path == "id" {
		return r.ID, true
	}
	var cur any = r.Fields
	for _, part := range strings.Split(path, ".") {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		if cur, ok = m[part]; !ok {
			return nil, false
		}
	}
	return cur, true
}

func dataAsFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	case float64:
		return n, true
	}
	return 0, false
}

func dataSameValue(got any, present bool, want any) bool {
	if want == nil {
		return !present || got == nil
	}
	if !present {
		return false
	}
	if wf, ok := dataAsFloat(want); ok {
		gf, ok := dataAsFloat(got)
		return ok && gf == wf
	}
	switch w := want.(type) {
	case string:
		switch g := got.(type) {
		case string:
			return g == w
		case json.Number:
			return g.String() == w
		}
	case bool:
		g, ok := got.(bool)
		return ok && g == w
	}
	return false
}

// dataMatches：where 里每个字段都要相等；值是数组时等于其中任意一个；null 表示没有这个字段。
func dataMatches(r *dataRecord, where map[string]any) bool {
	for path, want := range where {
		got, present := dataFieldValue(r, path)
		if list, ok := want.([]any); ok {
			if !slices.ContainsFunc(list, func(w any) bool { return dataSameValue(got, present, w) }) {
				return false
			}
		} else if !dataSameValue(got, present, want) {
			return false
		}
	}
	return true
}

// dataPrepare：校验公共字段并取数据集。出错时已经写好响应，返回 ok=false。
func (s *server) dataPrepare(w http.ResponseWriter, f *dataFilter) (*dataView, *time.Location, dataTimeRange, bool) {
	var tr dataTimeRange
	if !datasetPattern.MatchString(f.Dataset) {
		writeError(w, http.StatusBadRequest, "invalid_dataset", datasetRule)
		return nil, nil, tr, false
	}
	loc, err := s.dataLocation(f.Timezone)
	if err == nil {
		tr, err = dataResolveRange(f, loc, s.now())
	}
	if err == nil && len(f.Where) > 20 {
		err = errors.New("where 最多 20 个字段")
	}
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return nil, nil, tr, false
	}
	view := s.data.view(f.Dataset)
	if view == nil {
		writeError(w, http.StatusNotFound, "no_dataset", "没有这个数据集（还没有上报过，或已经清空）")
		return nil, nil, tr, false
	}
	return view, loc, tr, true
}

// dataFilterRecords：符合时间范围和 where 的记录，按 ts 升序（相同时按 id）。
func dataFilterRecords(v *dataView, f *dataFilter, tr dataTimeRange) []*dataRecord {
	out := []*dataRecord{}
	for _, r := range v.Records {
		if tr.contains(r.TS) && dataMatches(r, f.Where) {
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].TS.Equal(out[j].TS) {
			return out[i].TS.Before(out[j].TS)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func dataAddRange(result map[string]any, tr dataTimeRange, loc *time.Location) {
	if !tr.from.IsZero() {
		result["start"] = tr.from.In(loc).Format(time.RFC3339)
	}
	if !tr.to.IsZero() {
		result["end"] = tr.to.In(loc).Format(time.RFC3339)
	}
}

// dataAddReport：最后一次上报的时间、密钥名称、距今秒数。内容没变的上报也算。
func dataAddReport(result map[string]any, v *dataView, loc *time.Location) {
	if v.LastReport.IsZero() {
		return
	}
	result["last_report_at"] = v.LastReport.In(loc).Format(time.RFC3339)
	result["last_report_by"] = v.LastBy
	result["last_report_age_seconds"] = max(int64(time.Since(v.LastReport)/time.Second), 0)
}

// dataNotModified：版本号只在数据变化时才变，所以「没变化」的结果里也带上最后上报时间。
func dataNotModified(w http.ResponseWriter, v *dataView, loc *time.Location) {
	result := map[string]any{"ok": true, "not_modified": true, "version": v.Version}
	dataAddReport(result, v, loc)
	writeJSON(w, http.StatusOK, result)
}

// ---- 明细 /v1/data/records ----

type dataRecordsRequest struct {
	dataFilter
	Fields []string `json:"fields"`
	Order  string   `json:"order"`
	Limit  int      `json:"limit"`
	Offset int      `json:"offset"`
}

func (s *server) dataRecords(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var req dataRecordsRequest
	if err := decodeRequest(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体有误："+err.Error())
		return
	}
	if req.Limit == 0 {
		req.Limit = 100
	}
	var bad string
	switch {
	case req.Order != "" && req.Order != "asc" && req.Order != "desc":
		bad = "order 只能是 asc 或 desc"
	case req.Limit < 0 || req.Limit > 1000:
		bad = "limit 应为 1–1000"
	case req.Offset < 0:
		bad = "offset 不能小于 0"
	case len(req.Fields) > 100:
		bad = "fields 最多 100 个"
	}
	if bad != "" {
		writeError(w, http.StatusBadRequest, "bad_request", bad)
		return
	}
	view, loc, tr, ok := s.dataPrepare(w, &req.dataFilter)
	if !ok {
		return
	}
	if req.IfVersion != "" && req.IfVersion == view.Version {
		dataNotModified(w, view, loc)
		return
	}
	matched := dataFilterRecords(view, &req.dataFilter, tr)
	if req.Order != "asc" { // 默认最新的在前
		slices.Reverse(matched)
	}
	page := matched[min(req.Offset, len(matched)):min(req.Offset+req.Limit, len(matched))]
	records := make([]map[string]any, 0, len(page))
	for _, rec := range page {
		item := map[string]any{"id": rec.ID, "ts": rec.TS.In(loc).Format(time.RFC3339)}
		if len(req.Fields) == 0 {
			for k, v := range rec.Fields {
				item[k] = v
			}
		} else {
			for _, f := range req.Fields {
				if v, ok := dataFieldValue(rec, f); ok {
					item[f] = v
				}
			}
		}
		records = append(records, item)
	}
	result := map[string]any{
		"ok": true, "dataset": view.Name, "version": view.Version, "timezone": loc.String(),
		"total": len(matched), "returned": len(records), "offset": req.Offset,
		"truncated": req.Offset+len(records) < len(matched), "records": records,
	}
	dataAddRange(result, tr, loc)
	dataAddReport(result, view, loc)
	writeJSON(w, http.StatusOK, result)
}

// ---- 汇总 /v1/data/stats ----

type dataStatsRequest struct {
	dataFilter
	GroupBy []string `json:"group_by"`
	Bucket  string   `json:"bucket"`
	Sum     []string `json:"sum"`
	Sort    string   `json:"sort"`
	Limit   int      `json:"limit"`
}

type dataStatsGroup struct {
	bucket      string
	key         []any
	sortKey     string
	count       int
	sums        map[string]float64
	first, last time.Time
}

func dataBucketLabel(t time.Time, loc *time.Location, bucket string) string {
	local := t.In(loc)
	switch bucket {
	case "hour":
		return local.Format("2006-01-02T15:00")
	case "day":
		return local.Format(dateLayout)
	case "week": // 周一开始，用那个周一的日期
		day := dataDayStart(t, loc)
		return day.AddDate(0, 0, -((int(day.Weekday()) + 6) % 7)).Format(dateLayout)
	case "month":
		return local.Format("2006-01")
	case "year":
		return local.Format("2006")
	}
	return ""
}

// dataNumber：汇总结果保留 6 位小数；是整数时输出整数。
func dataNumber(f float64) any {
	r := math.Round(f*1e6) / 1e6
	if r == math.Trunc(r) && math.Abs(r) < 1e15 {
		return int64(r)
	}
	return r
}

func dataSums(sums map[string]float64, fields []string) map[string]any {
	out := make(map[string]any, len(fields))
	for _, f := range fields {
		out[f] = dataNumber(sums[f])
	}
	return out
}

// dataNumericFields：这些记录里出现过数值的顶层字段，按名称排序。
func dataNumericFields(records []*dataRecord) []string {
	seen := map[string]bool{}
	for _, r := range records {
		for k, v := range r.Fields {
			if _, ok := v.(json.Number); ok {
				seen[k] = true
			}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func (s *server) dataStats(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var req dataStatsRequest
	if err := decodeRequest(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体有误："+err.Error())
		return
	}
	if req.Limit == 0 {
		req.Limit = 1000
	}
	var bad string
	switch {
	case !slices.Contains([]string{"", "hour", "day", "week", "month", "year"}, req.Bucket):
		bad = "bucket 只能是 hour、day、week、month、year"
	case len(req.GroupBy) > 5:
		bad = "group_by 最多 5 个字段"
	case len(req.Sum) > 50:
		bad = "sum 最多 50 个字段"
	case req.Limit < 0 || req.Limit > 10000:
		bad = "limit 应为 1–10000"
	}
	if bad != "" {
		writeError(w, http.StatusBadRequest, "bad_request", bad)
		return
	}
	view, loc, tr, ok := s.dataPrepare(w, &req.dataFilter)
	if !ok {
		return
	}
	if req.IfVersion != "" && req.IfVersion == view.Version {
		dataNotModified(w, view, loc)
		return
	}
	matched := dataFilterRecords(view, &req.dataFilter, tr)
	sumFields := req.Sum
	if len(sumFields) == 0 {
		sumFields = dataNumericFields(matched)
	}
	// sort：key（默认，按时间段和分组字段升序）、count，或某个 sum 字段（这两种从大到小）
	if req.Sort != "" && req.Sort != "key" && req.Sort != "count" && !slices.Contains(sumFields, req.Sort) {
		writeError(w, http.StatusBadRequest, "bad_request", "sort 只能是 key、count 或 sum 里的字段")
		return
	}

	groups := map[string]*dataStatsGroup{}
	totals := &dataStatsGroup{sums: map[string]float64{}}
	add := func(g *dataStatsGroup, rec *dataRecord) {
		g.count++
		if g.first.IsZero() || rec.TS.Before(g.first) {
			g.first = rec.TS
		}
		if rec.TS.After(g.last) {
			g.last = rec.TS
		}
		for _, f := range sumFields {
			if v, ok := dataFieldValue(rec, f); ok {
				if n, ok := dataAsFloat(v); ok {
					g.sums[f] += n
				}
			}
		}
	}
	for _, rec := range matched {
		bucket := dataBucketLabel(rec.TS, loc, req.Bucket)
		key := make([]any, len(req.GroupBy))
		for i, f := range req.GroupBy {
			if v, ok := dataFieldValue(rec, f); ok {
				key[i] = v
			}
		}
		encoded, _ := json.Marshal(key)
		sortKey := bucket + "\x00" + string(encoded)
		g := groups[sortKey]
		if g == nil {
			g = &dataStatsGroup{bucket: bucket, key: key, sortKey: sortKey, sums: map[string]float64{}}
			groups[sortKey] = g
		}
		add(g, rec)
		add(totals, rec)
	}

	list := make([]*dataStatsGroup, 0, len(groups))
	for _, g := range groups {
		list = append(list, g)
	}
	sort.Slice(list, func(i, j int) bool {
		a, b := list[i], list[j]
		switch req.Sort {
		case "", "key":
		case "count":
			if a.count != b.count {
				return a.count > b.count
			}
		default:
			if a.sums[req.Sort] != b.sums[req.Sort] {
				return a.sums[req.Sort] > b.sums[req.Sort]
			}
		}
		return a.sortKey < b.sortKey
	})
	out := make([]map[string]any, 0, min(len(list), req.Limit))
	for _, g := range list[:min(len(list), req.Limit)] {
		item := map[string]any{
			"count": g.count, "sum": dataSums(g.sums, sumFields),
			"first_ts": g.first.In(loc).Format(time.RFC3339), "last_ts": g.last.In(loc).Format(time.RFC3339),
		}
		if req.Bucket != "" {
			item["bucket"] = g.bucket
		}
		for i, f := range req.GroupBy {
			item[f] = g.key[i]
		}
		out = append(out, item)
	}
	result := map[string]any{
		"ok": true, "dataset": view.Name, "version": view.Version, "timezone": loc.String(),
		"records": len(matched), "group_count": len(list), "returned": len(out),
		"truncated": len(out) < len(list), "sum_fields": sumFields, "groups": out,
		"totals": map[string]any{"count": totals.count, "sum": dataSums(totals.sums, sumFields)},
	}
	if req.Bucket != "" {
		result["bucket"] = req.Bucket
	}
	if len(req.GroupBy) > 0 {
		result["group_by"] = req.GroupBy
	}
	dataAddRange(result, tr, loc)
	dataAddReport(result, view, loc)
	writeJSON(w, http.StatusOK, result)
}

// ---- 数据集列表 /v1/data/datasets ----

type dataDatasetsRequest struct {
	Dataset  string `json:"dataset"`
	Timezone string `json:"timezone"`
}

func dataTypeOf(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case json.Number, float64:
		return "number"
	case string:
		return "string"
	case bool:
		return "bool"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	}
	return "unknown"
}

// dataDescribe：一个数据集的条数、时间范围和字段（嵌套对象用点展开一层以下的数值字段）。
func dataDescribe(v *dataView, loc *time.Location) map[string]any {
	types := map[string]map[string]bool{}
	note := func(name string, val any) {
		if types[name] == nil {
			types[name] = map[string]bool{}
		}
		types[name][dataTypeOf(val)] = true
	}
	var first, last time.Time
	for _, r := range v.Records {
		if first.IsZero() || r.TS.Before(first) {
			first = r.TS
		}
		if r.TS.After(last) {
			last = r.TS
		}
		for k, val := range r.Fields {
			note(k, val)
			if m, ok := val.(map[string]any); ok {
				for sub, sv := range m {
					note(k+"."+sub, sv)
				}
			}
		}
	}
	fields := make(map[string]string, len(types))
	for name, set := range types {
		names := make([]string, 0, len(set))
		for t := range set {
			names = append(names, t)
		}
		sort.Strings(names)
		fields[name] = strings.Join(names, "|")
	}
	out := map[string]any{"name": v.Name, "version": v.Version, "records": len(v.Records), "fields": fields}
	if !first.IsZero() {
		out["first_ts"] = first.In(loc).Format(time.RFC3339)
		out["last_ts"] = last.In(loc).Format(time.RFC3339)
	}
	dataAddReport(out, v, loc)
	return out
}

func (s *server) dataDatasets(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var req dataDatasetsRequest
	if err := decodeRequest(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体有误："+err.Error())
		return
	}
	loc, err := s.dataLocation(req.Timezone)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var views []*dataView
	if req.Dataset != "" {
		if !datasetPattern.MatchString(req.Dataset) {
			writeError(w, http.StatusBadRequest, "invalid_dataset", datasetRule)
			return
		}
		v := s.data.view(req.Dataset)
		if v == nil {
			writeError(w, http.StatusNotFound, "no_dataset", "没有这个数据集（还没有上报过，或已经清空）")
			return
		}
		views = []*dataView{v}
	} else {
		views = s.data.views()
	}
	list := make([]map[string]any, 0, len(views))
	for _, v := range views {
		list = append(list, dataDescribe(v, loc))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "timezone": loc.String(), "retention_days": int(s.data.retention / (24 * time.Hour)),
		"max_datasets": maxDatasets, "max_records_per_dataset": s.data.maxRecords, "datasets": list,
	})
}
