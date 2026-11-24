package main

// 通用数据上报的接口（对接文档见 DATA_API.md）：
//
//	POST /v1/data/ingest    上报密钥：写入、更新、删除记录
//	POST /v1/data/records   读取密钥：按时间和字段筛选明细（data_query.go）
//	POST /v1/data/stats     读取密钥：按时间段、字段分组汇总数值字段（data_query.go）
//	POST /v1/data/datasets  读取密钥：列出数据集、条数和字段类型（data_query.go）

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/http"
	"strings"
	"time"
)

const datasetRule = "dataset 只能用小写字母、数字、点、下划线、短横线，以字母或数字开头，最多 64 个字符"

func (s *server) dataLocation(name string) (*time.Location, error) {
	if name == "" {
		return s.dataLoc, nil
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return nil, fmt.Errorf("无法识别时区 %q", name)
	}
	return loc, nil
}

type dataIngestRequest struct {
	Dataset   string            `json:"dataset"`
	Records   []json.RawMessage `json:"records"`
	Record    json.RawMessage   `json:"record"`
	Replace   bool              `json:"replace"`
	DeleteIDs []string          `json:"delete_ids"`
	Timezone  string            `json:"timezone"`
}

var localTimeLayouts = []string{"2006-01-02 15:04:05", "2006-01-02T15:04:05", "2006-01-02 15:04", "2006-01-02T15:04", dateLayout}

// parseDataTime：ts 可以省略（用服务器接收时间）、RFC 3339、不带时区的本地时间（按 timezone 解释）、
// 日期，或 Unix 时间戳（秒或毫秒，可以带小数）。
func parseDataTime(v any, loc *time.Location, now time.Time) (time.Time, error) {
	var t time.Time
	switch x := v.(type) {
	case nil:
		return now, nil
	case json.Number:
		f, err := x.Float64()
		if err != nil {
			return t, errors.New("ts 不是合法的数字")
		}
		if math.Abs(f) >= 1e12 { // 毫秒
			t = time.UnixMilli(int64(f))
		} else {
			sec, frac := math.Modf(f)
			t = time.Unix(int64(sec), int64(frac*1e9))
		}
	case string:
		s := strings.TrimSpace(x)
		parsed, err := time.Parse(time.RFC3339Nano, s)
		for _, layout := range localTimeLayouts {
			if err == nil {
				break
			}
			parsed, err = time.ParseInLocation(layout, s, loc)
		}
		if err != nil {
			return t, fmt.Errorf("ts %q 应为 RFC 3339（如 2026-11-24T17:00:00+08:00）、YYYY-MM-DD HH:MM:SS、YYYY-MM-DD 或 Unix 时间戳", x)
		}
		t = parsed
	default:
		return t, errors.New("ts 应为时间字符串或 Unix 时间戳")
	}
	if t.Year() < 2000 || t.After(now.Add(366*24*time.Hour)) {
		return t, errors.New("ts 超出范围（应在 2000 年以后、一年以内）；Unix 时间戳用秒或毫秒都可以")
	}
	return t, nil
}

// parseDataRecord：记录是任意 JSON 对象；id、ts 是保留字段，其余字段原样保存。
func parseDataRecord(raw json.RawMessage, loc *time.Location, now time.Time) (*dataRecord, error) {
	if len(raw) > maxRecordBytes {
		return nil, fmt.Errorf("超过 %d KB", maxRecordBytes>>10)
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var fields map[string]any
	if err := decoder.Decode(&fields); err != nil || fields == nil {
		return nil, errors.New("应为 JSON 对象")
	}
	rec := &dataRecord{ReceivedAt: now.UTC()}
	switch id := fields["id"].(type) {
	case nil:
		rec.ID = newRecordID()
	case string:
		rec.ID = strings.TrimSpace(id)
	case json.Number:
		rec.ID = id.String()
	default:
		return nil, errors.New("id 应为字符串或数字")
	}
	if rec.ID == "" || len(rec.ID) > maxRecordIDLen {
		return nil, fmt.Errorf("id 不能为空，最多 %d 个字符", maxRecordIDLen)
	}
	ts, err := parseDataTime(fields["ts"], loc, now)
	if err != nil {
		return nil, err
	}
	rec.TS = ts.UTC()
	delete(fields, "id")
	delete(fields, "ts")
	if len(fields) > maxRecordFields {
		return nil, fmt.Errorf("字段最多 %d 个（嵌套对象里的不算）", maxRecordFields)
	}
	for name := range fields {
		if !fieldPattern.MatchString(name) {
			return nil, fmt.Errorf("字段名 %q 只能用字母、数字、下划线、短横线，最多 64 个字符", name)
		}
	}
	if len(fields) > 0 {
		rec.Fields = fields
	}
	return rec, rec.computeCanon()
}

func (s *server) dataIngest(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var req dataIngestRequest
	if err := decodeRequest(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体有误："+err.Error())
		return
	}
	if !datasetPattern.MatchString(req.Dataset) {
		writeError(w, http.StatusBadRequest, "invalid_dataset", datasetRule)
		return
	}
	raws := req.Records
	if len(req.Record) > 0 && !bytes.Equal(bytes.TrimSpace(req.Record), []byte("null")) {
		if len(raws) > 0 {
			writeError(w, http.StatusBadRequest, "bad_request", "record 和 records 只能用一个")
			return
		}
		raws = []json.RawMessage{req.Record}
	}
	switch {
	case len(raws) > maxIngestRecords || len(req.DeleteIDs) > maxIngestRecords:
		writeError(w, http.StatusBadRequest, "too_many_records", fmt.Sprintf("一次最多 %d 条记录、%d 个 delete_ids，请分批上报", maxIngestRecords, maxIngestRecords))
		return
	case len(raws) == 0 && !req.Replace && len(req.DeleteIDs) == 0:
		writeError(w, http.StatusBadRequest, "bad_request", "records 不能为空")
		return
	case req.Replace && len(req.DeleteIDs) > 0:
		writeError(w, http.StatusBadRequest, "bad_request", "replace 和 delete_ids 只能用一个")
		return
	}
	for _, id := range req.DeleteIDs {
		if id == "" || len(id) > maxRecordIDLen {
			writeError(w, http.StatusBadRequest, "bad_request", fmt.Sprintf("delete_ids 里的 id 不能为空，最多 %d 个字符", maxRecordIDLen))
			return
		}
	}
	loc, err := s.dataLocation(req.Timezone)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	now := s.now()
	records := make([]*dataRecord, 0, len(raws))
	for i, raw := range raws {
		rec, err := parseDataRecord(raw, loc, now)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid_record", fmt.Sprintf("第 %d 条记录：%v", i+1, err))
			return
		}
		rec.By = keyName
		records = append(records, rec)
	}
	res, err := s.data.ingest(req.Dataset, records, req.Replace, req.DeleteIDs, keyName, now)
	if errors.Is(err, errTooManySets) {
		writeError(w, http.StatusConflict, "too_many_datasets", fmt.Sprintf("数据集最多 %d 个，先清空不用的（replace 为 true、records 为空）", maxDatasets))
		return
	}
	if err != nil {
		log.Printf("保存数据集 %s 失败：%v", req.Dataset, err)
		writeError(w, http.StatusInternalServerError, "storage_error", "服务器保存数据失败")
		return
	}
	if res.Changed {
		log.Printf("数据集 %s：%s 上报 %d 条（新增 %d，更新 %d，删除 %d），现有 %d 条",
			req.Dataset, keyName, len(raws), res.Inserted, res.Updated, res.Deleted, res.Total)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "dataset": req.Dataset, "version": res.Version, "changed": res.Changed,
		"received": len(raws), "inserted": res.Inserted, "updated": res.Updated, "unchanged": res.Unchanged,
		"deleted": res.Deleted, "expired": res.Expired, "total": res.Total,
		"received_at": now.In(s.dataLoc).Format(time.RFC3339),
	})
}
