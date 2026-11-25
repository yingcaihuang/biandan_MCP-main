package main

// 通用数据上报的存储。其它程序按「数据集」上报任意字段的 JSON 记录（例如 token 统计），
// 和日程快照完全独立：密钥角色、接口、存储文件都分开。
//
// 每个数据集一个追加写的日志 <数据目录>/datasets/<名称>.log，每行一次变更（删掉哪些 id、写入哪些记录），
// 启动时依次重放。日志比数据大很多时压缩成一行完整数据。最后一行写坏（断电）时丢掉这一行，其余照常读出，
// 并立即压缩，把坏掉的尾巴去掉。

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxDatasets      = 100
	maxRecordsPerSet = 100000
	maxIngestRecords = 5000
	maxIngestBody    = 8 << 20
	maxRecordBytes   = 16 << 10
	maxRecordFields  = 100
	maxRecordIDLen   = 128
)

var (
	datasetPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_.-]{0,63}$`)
	fieldPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)
	errTooManySets = errors.New("数据集太多")
)

// dataRecord：一条上报的记录。Fields 是除 id、ts 以外的全部字段，原样保存（数字保留原来的写法）。
type dataRecord struct {
	ID         string         `json:"id"`
	TS         time.Time      `json:"ts"`
	Fields     map[string]any `json:"fields,omitempty"`
	By         string         `json:"by,omitempty"`
	ReceivedAt time.Time      `json:"received_at"`

	canon string // ts 和字段的规范写法，用来判断重复上报的内容有没有变
}

func (r *dataRecord) computeCanon() error {
	data, err := json.Marshal(r.Fields)
	if err != nil {
		return err
	}
	r.canon = strconv.FormatInt(r.TS.UnixNano(), 10) + " " + string(data)
	return nil
}

// dataOp：日志里的一行。先 Replace（清空），再删 Delete，再写 Records；Version 是执行完以后的版本号。
type dataOp struct {
	Version string        `json:"version"`
	At      time.Time     `json:"at"`
	Replace bool          `json:"replace,omitempty"`
	Delete  []string      `json:"delete,omitempty"`
	Records []*dataRecord `json:"records,omitempty"`
	// 这次上报的时间和密钥名称。内容没变的上报也记一行，压缩时保留，重启后最后上报时间不会退回。
	ReportAt *time.Time `json:"report_at,omitempty"`
	By       string     `json:"by,omitempty"`
}

type dataSet struct {
	name       string
	version    string
	records    map[string]*dataRecord // 只整体替换，不原地修改，读的一方拿到后可以不加锁遍历
	lastReport time.Time
	lastBy     string
	logRecords int // 日志里累计写过的记录和删除数，用来决定什么时候压缩
}

func (d *dataSet) apply(op *dataOp) error {
	if op.Replace {
		d.records = make(map[string]*dataRecord, len(op.Records))
	}
	for _, id := range op.Delete {
		delete(d.records, id)
	}
	for _, r := range op.Records {
		if r == nil || r.ID == "" {
			return errors.New("记录缺少 id")
		}
		if err := r.computeCanon(); err != nil {
			return err
		}
		d.records[r.ID] = r
		if r.ReceivedAt.After(d.lastReport) {
			d.lastReport, d.lastBy = r.ReceivedAt, r.By
		}
	}
	if op.ReportAt != nil && op.ReportAt.After(d.lastReport) {
		d.lastReport, d.lastBy = op.ReportAt.UTC(), op.By
	}
	d.version = op.Version
	d.logRecords += len(op.Records) + len(op.Delete) + 1
	return nil
}

// dataView：给查询用的只读视图。
type dataView struct {
	Name       string
	Version    string
	Records    map[string]*dataRecord
	LastReport time.Time
	LastBy     string
}

type dataStore struct {
	dir        string
	retention  time.Duration // 0 表示不按时间清理
	maxRecords int
	mu         sync.RWMutex
	sets       map[string]*dataSet
}

func newDataStore(dir string, retention time.Duration) (*dataStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建数据目录 %s：%w", dir, err)
	}
	s := &dataStore{dir: dir, retention: retention, maxRecords: maxRecordsPerSet, sets: map[string]*dataSet{}}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("读取 %s：%w", dir, err)
	}
	now := time.Now()
	for _, entry := range entries {
		name, ok := strings.CutSuffix(entry.Name(), ".log")
		if !ok || entry.IsDir() || !datasetPattern.MatchString(name) {
			continue
		}
		set, clean, err := s.load(name)
		if err != nil {
			return nil, fmt.Errorf("读取数据集 %s：%w", name, err)
		}
		evicted := s.evict(set.records, now)
		if len(set.records) == 0 {
			if clean {
				_ = os.Remove(s.file(name))
			} else {
				// 一条都没读出来：留着原文件以便手工恢复，不再当数据集加载
				broken := s.file(name) + ".broken-" + now.Format("20060102-150405")
				log.Printf("数据集 %s 的日志读不出数据，已改名为 %s", name, broken)
				_ = os.Rename(s.file(name), broken)
			}
			continue
		}
		s.sets[name] = set
		if !clean || evicted > 0 {
			if err := s.compact(set, now); err != nil {
				if !clean {
					return nil, fmt.Errorf("整理数据集 %s 写坏的日志：%w", name, err)
				}
				log.Printf("整理数据集 %s 的日志失败：%v", name, err)
			}
		}
	}
	return s, nil
}

func (s *dataStore) file(name string) string { return filepath.Join(s.dir, name+".log") }

// load 重放日志。clean=false 表示中途有读不出来的地方（只用了前面的部分）。
func (s *dataStore) load(name string) (*dataSet, bool, error) {
	f, err := os.Open(s.file(name))
	if err != nil {
		return nil, false, err
	}
	defer f.Close()
	set := &dataSet{name: name, records: map[string]*dataRecord{}}
	decoder := json.NewDecoder(bufio.NewReaderSize(f, 1<<20))
	decoder.UseNumber()
	for n := 1; ; n++ {
		var op dataOp
		err := decoder.Decode(&op)
		if errors.Is(err, io.EOF) {
			return set, true, nil
		}
		if err == nil {
			err = set.apply(&op)
		}
		if err != nil {
			log.Printf("数据集 %s 的日志第 %d 条读不出来，只用前面的：%v", name, n, err)
			return set, false, nil
		}
	}
}

func sortedRecords(m map[string]*dataRecord) []*dataRecord {
	out := make([]*dataRecord, 0, len(m))
	for _, r := range m {
		out = append(out, r)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].TS.Equal(out[j].TS) {
			return out[i].TS.Before(out[j].TS)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// evict 删掉超过保留期的记录；超过条数上限时删掉 ts 最早的。返回删了几条。
func (s *dataStore) evict(m map[string]*dataRecord, now time.Time) int {
	removed := 0
	if s.retention > 0 {
		cutoff := now.Add(-s.retention)
		for id, r := range m {
			if r.TS.Before(cutoff) {
				delete(m, id)
				removed++
			}
		}
	}
	if extra := len(m) - s.maxRecords; extra > 0 {
		for _, r := range sortedRecords(m)[:extra] {
			delete(m, r.ID)
			removed++
		}
	}
	return removed
}

type ingestResult struct {
	Version   string
	Changed   bool
	Inserted  int
	Updated   int
	Unchanged int
	Deleted   int // 原有记录里这次没了的（delete_ids、replace、超出上限被挤掉的）
	Expired   int // 上报的记录本身就超过保留期，没有保存
	Total     int
}

// ingest 写入一批已经校验过的记录。同一 id 覆盖旧记录；内容没变不写盘。
// replace=true 时这批记录就是数据集的全部内容；结果为空时删除整个数据集。
func (s *dataStore) ingest(name string, incoming []*dataRecord, replace bool, deleteIDs []string, by string, now time.Time) (ingestResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var res ingestResult
	existing := s.sets[name]
	set := existing
	if set == nil {
		set = &dataSet{name: name, records: map[string]*dataRecord{}}
	}

	batch := make(map[string]*dataRecord, len(incoming))
	order := make([]string, 0, len(incoming))
	var cutoff time.Time
	if s.retention > 0 {
		cutoff = now.Add(-s.retention)
	}
	for _, r := range incoming {
		if !cutoff.IsZero() && r.TS.Before(cutoff) {
			res.Expired++
			continue
		}
		if _, dup := batch[r.ID]; !dup {
			order = append(order, r.ID)
		}
		batch[r.ID] = r // 同一批里重复的 id，后面的为准
	}

	var final map[string]*dataRecord
	if replace {
		final = make(map[string]*dataRecord, len(batch))
	} else {
		final = maps.Clone(set.records)
		for _, id := range deleteIDs {
			delete(final, id)
		}
	}
	for _, id := range order {
		r, old := batch[id], set.records[id]
		switch {
		case old == nil:
			res.Inserted++
			final[id] = r
		case old.canon == r.canon:
			res.Unchanged++
			final[id] = old
		default:
			res.Updated++
			final[id] = r
		}
	}
	s.evict(final, now)

	reportAt := now.UTC()
	op := &dataOp{At: reportAt, ReportAt: &reportAt, By: by}
	for id := range set.records {
		if _, ok := final[id]; !ok {
			op.Delete = append(op.Delete, id)
		}
	}
	for id, r := range final {
		if set.records[id] != r {
			op.Records = append(op.Records, r)
		}
	}
	res.Deleted, res.Total = len(op.Delete), len(final)
	if len(op.Delete) == 0 && len(op.Records) == 0 {
		res.Version = set.version
		if existing != nil {
			// 内容没变：只记一行上报时间，失败也不影响数据，只记日志
			reportAt := now.UTC()
			line, err := json.Marshal(&dataOp{Version: set.version, At: reportAt, ReportAt: &reportAt, By: by})
			if err == nil {
				err = appendLine(s.file(name), line)
			}
			if err != nil {
				log.Printf("记录数据集 %s 的上报时间失败：%v", name, err)
			} else {
				existing.logRecords++
			}
			existing.lastReport, existing.lastBy = reportAt, by
			if existing.logRecords > 2*len(existing.records)+1000 {
				if err := s.compact(existing, now); err != nil {
					log.Printf("压缩数据集 %s 的日志失败（不影响数据）：%v", name, err)
				}
			}
		}
		return res, nil
	}
	if existing == nil && len(s.sets) >= maxDatasets {
		return res, errTooManySets
	}
	if len(final) == 0 {
		if err := os.Remove(s.file(name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return res, err
		}
		delete(s.sets, name)
		res.Changed = true
		return res, nil
	}

	sort.Strings(op.Delete)
	sort.Slice(op.Records, func(i, j int) bool { return op.Records[i].ID < op.Records[j].ID })
	version, err := nextDataVersion(set.version, op)
	if err != nil {
		return res, err
	}
	op.Version = version
	line, err := json.Marshal(op)
	if err != nil {
		return res, err
	}
	if err := appendLine(s.file(name), line); err != nil {
		return res, err
	}
	set.records, set.version = final, version
	set.lastReport, set.lastBy = reportAt, by
	set.logRecords += len(op.Records) + len(op.Delete) + 1
	s.sets[name] = set
	res.Changed, res.Version = true, version
	if set.logRecords > 2*len(final)+1000 {
		if err := s.compact(set, now); err != nil {
			log.Printf("压缩数据集 %s 的日志失败（不影响数据）：%v", name, err)
		}
	}
	return res, nil
}

// nextDataVersion：上一个版本号加这次变更内容的 SHA-256 前 16 位十六进制。
func nextDataVersion(prev string, op *dataOp) (string, error) {
	data, err := json.Marshal(op)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	h.Write([]byte(prev))
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil)[:8]), nil
}

// appendLine 追加一行并刷盘；写到一半失败时截回原来的长度，不留半行。
func appendLine(path string, line []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	_, err = f.Write(append(line, '\n'))
	if err == nil {
		err = f.Sync()
	}
	if err != nil {
		_ = f.Truncate(info.Size())
		f.Close()
		return err
	}
	return f.Close()
}

// compact 把整个数据集写成一行，原子替换日志。
func (s *dataStore) compact(set *dataSet, now time.Time) error {
	records := sortedRecords(set.records)
	op := &dataOp{Version: set.version, At: now.UTC(), Replace: true, Records: records}
	if !set.lastReport.IsZero() {
		reportAt := set.lastReport.UTC()
		op.ReportAt, op.By = &reportAt, set.lastBy
	}
	line, err := json.Marshal(op)
	if err != nil {
		return err
	}
	if err := writeAtomic(s.file(set.name), append(line, '\n')); err != nil {
		return err
	}
	set.logRecords = len(records) + 1
	return nil
}

func (d *dataSet) view() *dataView {
	return &dataView{Name: d.name, Version: d.version, Records: d.records, LastReport: d.lastReport, LastBy: d.lastBy}
}

func (s *dataStore) view(name string) *dataView {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if set := s.sets[name]; set != nil {
		return set.view()
	}
	return nil
}

func (s *dataStore) views() []*dataView {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*dataView, 0, len(s.sets))
	for _, set := range s.sets {
		out = append(out, set.view())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

func (s *dataStore) count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.sets)
}

func newRecordID() string {
	raw := make([]byte, 8)
	_, _ = rand.Read(raw)
	return "auto-" + hex.EncodeToString(raw)
}
