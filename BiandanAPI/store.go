package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	snapshotFormat  = "biandan-schedule"
	snapshotVersion = 1
	dateLayout      = "2006-01-02"
	clockLayout     = "15:04"
	maxLists        = 1000
	maxItems        = 50000
	defaultListID   = "1"
)

// Snapshot：App 推送的完整日程快照。
type Snapshot struct {
	Format      string `json:"format"`
	Version     int    `json:"version"`
	GeneratedAt string `json:"generated_at"`
	Timezone    string `json:"timezone"`
	Device      string `json:"device,omitempty"`
	Lists       []List `json:"lists"`
	Items       []Item `json:"items"`
}

// List：便单里的分类。
type List struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Color     string `json:"color,omitempty"`
	Order     int    `json:"order"`
	IsDefault bool   `json:"is_default"`
}

// Item：一次日程（执行实例）。重复日程每一次是一条。
type Item struct {
	OccurrenceID string    `json:"occurrence_id"`
	TaskID       string    `json:"task_id"`
	ListID       string    `json:"list_id"`
	Title        string    `json:"title"`
	Remark       string    `json:"remark,omitempty"`
	Subtasks     []string  `json:"subtasks,omitempty"`
	Undated      bool      `json:"undated"`
	AllDay       bool      `json:"all_day"`
	StartDate    string    `json:"start_date,omitempty"`
	EndDate      string    `json:"end_date,omitempty"`
	StartTime    string    `json:"start_time,omitempty"`
	EndTime      string    `json:"end_time,omitempty"`
	Status       string    `json:"status"`
	CompletedAt  string    `json:"completed_at,omitempty"`
	Important    bool      `json:"important"`
	Urgent       bool      `json:"urgent"`
	Quadrant     int       `json:"quadrant"`
	QuadrantName string    `json:"quadrant_name"`
	Collected    bool      `json:"collected"`
	Repeating    bool      `json:"repeating"`
	Habit        bool      `json:"habit"`
	RepeatRule   string    `json:"repeat_rule,omitempty"`
	Location     string    `json:"location,omitempty"`
	Reminder     *Reminder `json:"reminder,omitempty"`
	Source       *Source   `json:"source"`
}

type Reminder struct {
	Date string `json:"date,omitempty"`
	Time string `json:"time,omitempty"`
}

// Source：日程从哪里来。biandan 是在便单（华为账号）里直接建的，其余是导入的。
type Source struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

var (
	colorPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}$`)
	sourceKinds  = map[string]bool{"biandan": true, "caldav": true, "url": true, "file": true, "system": true}
	statuses     = map[string]bool{"pending": true, "completed": true, "abandoned": true}
)

func validDate(s string) bool {
	if len(s) != len(dateLayout) {
		return false
	}
	_, err := time.Parse(dateLayout, s)
	return err == nil
}

func validClock(s string) bool {
	if len(s) != len(clockLayout) {
		return false
	}
	_, err := time.Parse(clockLayout, s)
	return err == nil
}

// quadrant：1 重要且紧急，2 重要但不紧急，3 不重要但紧急，4 不重要且不紧急（与便单四象限一致）。
func quadrant(important, urgent bool) (int, string) {
	switch {
	case important && urgent:
		return 1, "重要且紧急"
	case important:
		return 2, "重要但不紧急"
	case urgent:
		return 3, "不重要但紧急"
	default:
		return 4, "不重要且不紧急"
	}
}

// normalize 检查推送来的快照，并补齐缺省值。出错时返回给推送方看的中文说明。
func normalize(s *Snapshot) error {
	if s.Format != snapshotFormat {
		return fmt.Errorf("format 应为 %q", snapshotFormat)
	}
	if s.Version != snapshotVersion {
		return fmt.Errorf("不支持快照版本 %d，只支持 %d", s.Version, snapshotVersion)
	}
	if s.Timezone == "" {
		s.Timezone = "Asia/Shanghai"
	}
	if _, err := time.LoadLocation(s.Timezone); err != nil {
		return fmt.Errorf("无法识别时区 %q", s.Timezone)
	}
	if s.GeneratedAt != "" {
		if _, err := time.Parse(time.RFC3339, s.GeneratedAt); err != nil {
			return fmt.Errorf("generated_at 应为 RFC 3339 时间")
		}
	}
	if len(s.Lists) > maxLists {
		return fmt.Errorf("分类最多 %d 个", maxLists)
	}
	if len(s.Items) > maxItems {
		return fmt.Errorf("日程最多 %d 条", maxItems)
	}

	listIDs := map[string]bool{}
	defaultID := ""
	for i := range s.Lists {
		list := &s.Lists[i]
		list.ID = strings.TrimSpace(list.ID)
		if list.ID == "" {
			return fmt.Errorf("第 %d 个分类缺少 id", i+1)
		}
		if listIDs[list.ID] {
			return fmt.Errorf("分类 id %q 重复", list.ID)
		}
		listIDs[list.ID] = true
		if list.Name == "" {
			list.Name = "未命名"
		}
		if list.Color != "" && !colorPattern.MatchString(list.Color) {
			return fmt.Errorf("分类 %q 的颜色应为 #RRGGBB", list.ID)
		}
		if list.IsDefault {
			if defaultID != "" {
				list.IsDefault = false
			} else {
				defaultID = list.ID
			}
		}
	}
	// 找不到所属分类的日程归到默认分类；快照里没有默认分类时补一个「未分类」。
	fallbackList := func() string {
		if defaultID == "" {
			defaultID = defaultListID
			if !listIDs[defaultID] {
				s.Lists = append(s.Lists, List{ID: defaultID, Name: "未分类", Color: "#B9B09C", Order: -1, IsDefault: true})
				listIDs[defaultID] = true
			} else {
				for i := range s.Lists {
					if s.Lists[i].ID == defaultID {
						s.Lists[i].IsDefault = true
					}
				}
			}
		}
		return defaultID
	}

	seen := map[string]bool{}
	for i := range s.Items {
		item := &s.Items[i]
		if item.OccurrenceID == "" {
			return fmt.Errorf("第 %d 条日程缺少 occurrence_id", i+1)
		}
		if seen[item.OccurrenceID] {
			return fmt.Errorf("日程 occurrence_id %q 重复", item.OccurrenceID)
		}
		seen[item.OccurrenceID] = true
		if !listIDs[item.ListID] {
			item.ListID = fallbackList()
		}
		if !statuses[item.Status] {
			return fmt.Errorf("日程 %q 的 status 只能是 pending、completed、abandoned", item.OccurrenceID)
		}
		if item.StartDate == "" {
			item.Undated = true
		}
		if item.Undated {
			item.StartDate, item.EndDate, item.StartTime, item.EndTime, item.AllDay = "", "", "", "", false
		} else {
			if !validDate(item.StartDate) || (item.EndDate != "" && !validDate(item.EndDate)) {
				return fmt.Errorf("日程 %q 的日期应为 YYYY-MM-DD", item.OccurrenceID)
			}
			if item.EndDate == "" || item.EndDate < item.StartDate {
				item.EndDate = item.StartDate
			}
			if item.AllDay {
				item.StartTime, item.EndTime = "", ""
			} else if (item.StartTime != "" && !validClock(item.StartTime)) || (item.EndTime != "" && !validClock(item.EndTime)) {
				return fmt.Errorf("日程 %q 的时刻应为 HH:MM", item.OccurrenceID)
			}
			if !item.AllDay && item.StartTime == "" && item.EndTime == "" {
				item.AllDay = true
			}
		}
		item.Quadrant, item.QuadrantName = quadrant(item.Important, item.Urgent)
		if item.Source == nil || item.Source.Kind == "" {
			item.Source = &Source{Kind: "biandan", Name: "便单"}
		} else if !sourceKinds[item.Source.Kind] {
			return fmt.Errorf("日程 %q 的 source.kind 只能是 biandan、caldav、url、file、system", item.OccurrenceID)
		}
		if item.Reminder != nil && item.Reminder.Date == "" && item.Reminder.Time == "" {
			item.Reminder = nil
		}
	}
	sort.SliceStable(s.Lists, func(i, j int) bool {
		if s.Lists[i].Order != s.Lists[j].Order {
			return s.Lists[i].Order < s.Lists[j].Order
		}
		return s.Lists[i].ID < s.Lists[j].ID
	})
	return nil
}

// stored：服务端保存的最新一份快照。
type stored struct {
	Version    string    `json:"version"`
	ReceivedAt time.Time `json:"received_at"`
	PushedBy   string    `json:"pushed_by"`
	Snapshot   *Snapshot `json:"snapshot"`

	loc       *time.Location
	listNames map[string]string
}

func prepare(st *stored) error {
	loc, err := time.LoadLocation(st.Snapshot.Timezone)
	if err != nil {
		return err
	}
	st.loc = loc
	st.listNames = make(map[string]string, len(st.Snapshot.Lists))
	for _, list := range st.Snapshot.Lists {
		st.listNames[list.ID] = list.Name
	}
	return nil
}

// versionOf：快照内容的 SHA-256 前 16 位十六进制。内容不变，版本号就不变。
// generated_at 和 device 每次推送都可能不同，不算进版本号，否则 if_version 永远对不上。
func versionOf(s *Snapshot) (string, error) {
	content := *s
	content.GeneratedAt, content.Device = "", ""
	data, err := json.Marshal(&content)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:8]), nil
}

type store struct {
	dir string
	mu  sync.RWMutex
	cur *stored
}

func newStore(dir string) (*store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建数据目录 %s：%w", dir, err)
	}
	s := &store{dir: dir}
	data, err := os.ReadFile(s.file())
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("读取 %s：%w", s.file(), err)
	}
	var st stored
	if err := json.Unmarshal(data, &st); err != nil || st.Snapshot == nil {
		log.Printf("已保存的快照读不出来，等下一次推送：%v", err)
		return s, nil
	}
	if err := normalize(st.Snapshot); err != nil {
		log.Printf("已保存的快照格式不对，等下一次推送：%v", err)
		return s, nil
	}
	if err := prepare(&st); err != nil {
		log.Printf("已保存的快照时区不对，等下一次推送：%v", err)
		return s, nil
	}
	s.cur = &st
	return s, nil
}

func (s *store) file() string { return filepath.Join(s.dir, "snapshot.json") }

func (s *store) get() *stored {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cur
}

// put 保存一份已经 normalize 过的快照。内容没变也会更新接收时间（App 定时推送当心跳）。
func (s *store) put(snap *Snapshot, by string, now time.Time) (*stored, bool, error) {
	version, err := versionOf(snap)
	if err != nil {
		return nil, false, err
	}
	st := &stored{Version: version, ReceivedAt: now.UTC(), PushedBy: by, Snapshot: snap}
	if err := prepare(st); err != nil {
		return nil, false, err
	}
	data, err := json.Marshal(st)
	if err != nil {
		return nil, false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	changed := s.cur == nil || s.cur.Version != version
	if err := writeAtomic(s.file(), data); err != nil {
		return nil, false, err
	}
	s.cur = st
	return st, changed, nil
}

// writeAtomic：先写同目录的临时文件并刷盘，再改名替换，中途断电也不会留下半个文件。
func writeAtomic(path string, data []byte) error {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}
