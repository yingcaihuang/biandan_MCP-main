package main

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// QueryRequest：POST /v1/schedule 的请求体。所有字段都可以省略。
type QueryRequest struct {
	Start             string   `json:"start"`
	End               string   `json:"end"`
	Days              int      `json:"days"`
	Status            string   `json:"status"`
	ListIDs           []string `json:"list_ids"`
	IncludeUndated    *bool    `json:"include_undated"`
	IncludeEmptyLists bool     `json:"include_empty_lists"`
	GroupBy           string   `json:"group_by"`
	Fields            string   `json:"fields"`
	Limit             int      `json:"limit"`
	IfVersion         string   `json:"if_version"`
}

const (
	defaultLimit = 500
	maxLimit     = 2000
	maxRangeDays = 400
)

type appliedQuery struct {
	Start          string   `json:"start,omitempty"`
	End            string   `json:"end,omitempty"`
	Status         string   `json:"status"`
	ListIDs        []string `json:"list_ids,omitempty"`
	IncludeUndated bool     `json:"include_undated"`
	GroupBy        string   `json:"group_by"`
	Fields         string   `json:"fields"`
	Limit          int      `json:"limit"`
}

type outItem struct {
	Item
	ListName string `json:"list_name"`
	Overdue  bool   `json:"overdue"`
}

// compactItem：fields=compact 时每条日程只返回这些字段，给内存小的设备用。
type compactItem struct {
	OccurrenceID string `json:"occurrence_id"`
	Title        string `json:"title"`
	ListID       string `json:"list_id"`
	StartDate    string `json:"start_date,omitempty"`
	EndDate      string `json:"end_date,omitempty"`
	StartTime    string `json:"start_time,omitempty"`
	EndTime      string `json:"end_time,omitempty"`
	AllDay       bool   `json:"all_day"`
	Undated      bool   `json:"undated"`
	Status       string `json:"status"`
	Overdue      bool   `json:"overdue"`
	Important    bool   `json:"important"`
	Urgent       bool   `json:"urgent"`
}

type Group struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Color string `json:"color,omitempty"`
	Total int    `json:"total"`
	Count int    `json:"count"`
	Items []any  `json:"items"`
}

type QueryResponse struct {
	OK             bool         `json:"ok"`
	Version        string       `json:"version"`
	GeneratedAt    string       `json:"generated_at,omitempty"`
	ReceivedAt     string       `json:"received_at"`
	DataAgeSeconds int64        `json:"data_age_seconds"`
	Timezone       string       `json:"timezone"`
	Today          string       `json:"today"`
	Query          appliedQuery `json:"query"`
	Total          int          `json:"total"`
	Returned       int          `json:"returned"`
	Truncated      bool         `json:"truncated"`
	Groups         []Group      `json:"groups"`
}

var weekdays = [...]string{"周日", "周一", "周二", "周三", "周四", "周五", "周六"}

// resolveDay：空、today、tomorrow、yesterday 或 YYYY-MM-DD。
func resolveDay(text string, today time.Time) (string, error) {
	switch strings.ToLower(strings.TrimSpace(text)) {
	case "":
		return "", nil
	case "today":
		return today.Format(dateLayout), nil
	case "tomorrow":
		return today.AddDate(0, 0, 1).Format(dateLayout), nil
	case "yesterday":
		return today.AddDate(0, 0, -1).Format(dateLayout), nil
	}
	day, err := time.Parse(dateLayout, strings.TrimSpace(text))
	if err != nil {
		return "", fmt.Errorf("日期要写成 YYYY-MM-DD、today、tomorrow 或 yesterday：%q", text)
	}
	return day.Format(dateLayout), nil
}

func addDays(day string, n int) string {
	t, _ := time.Parse(dateLayout, day)
	return t.AddDate(0, 0, n).Format(dateLayout)
}

func daysBetween(a, b string) int {
	ta, _ := time.Parse(dateLayout, a)
	tb, _ := time.Parse(dateLayout, b)
	return int(tb.Sub(ta).Hours() / 24)
}

func dateName(day string) string {
	t, err := time.Parse(dateLayout, day)
	if err != nil {
		return day
	}
	return fmt.Sprintf("%d月%d日 %s", int(t.Month()), t.Day(), weekdays[t.Weekday()])
}

// isOverdue：未完成、有日期、结束日期早于今天。
func isOverdue(item *Item, today string) bool {
	return !item.Undated && item.Status == "pending" && item.EndDate != "" && item.EndDate < today
}

// lessItem：有日期的在前，按开始日期、全天优先、开始时刻、标题排；无日期的放最后。
func lessItem(a, b *Item) bool {
	if a.Undated != b.Undated {
		return !a.Undated
	}
	if a.StartDate != b.StartDate {
		return a.StartDate < b.StartDate
	}
	if a.AllDay != b.AllDay {
		return a.AllDay
	}
	if a.StartTime != b.StartTime {
		return a.StartTime < b.StartTime
	}
	if a.Title != b.Title {
		return a.Title < b.Title
	}
	return a.OccurrenceID < b.OccurrenceID
}

func lower(text string) string { return strings.ToLower(strings.TrimSpace(text)) }

func runQuery(st *stored, req QueryRequest, now time.Time) (*QueryResponse, error) {
	todayTime := now.In(st.loc)
	today := todayTime.Format(dateLayout)
	q := appliedQuery{Status: lower(req.Status), GroupBy: lower(req.GroupBy), Fields: lower(req.Fields), Limit: req.Limit}

	if q.Status == "" {
		q.Status = "all"
	}
	if q.Status != "all" && !statuses[q.Status] {
		return nil, fmt.Errorf("status 只能是 all、pending、completed、abandoned")
	}
	if q.GroupBy == "" {
		q.GroupBy = "list"
	}
	if q.GroupBy != "list" && q.GroupBy != "date" && q.GroupBy != "none" {
		return nil, fmt.Errorf("group_by 只能是 list、date、none")
	}
	if q.Fields == "" {
		q.Fields = "full"
	}
	if q.Fields != "full" && q.Fields != "compact" {
		return nil, fmt.Errorf("fields 只能是 full、compact")
	}
	switch {
	case q.Limit < 0:
		return nil, fmt.Errorf("limit 不能是负数")
	case q.Limit == 0:
		q.Limit = defaultLimit
	case q.Limit > maxLimit:
		q.Limit = maxLimit
	}

	start, err := resolveDay(req.Start, todayTime)
	if err != nil {
		return nil, err
	}
	end, err := resolveDay(req.End, todayTime)
	if err != nil {
		return nil, err
	}
	if req.Days < 0 || req.Days > maxRangeDays {
		return nil, fmt.Errorf("days 要在 1–%d 之间", maxRangeDays)
	}
	if req.Days > 0 {
		if end != "" {
			return nil, fmt.Errorf("end 和 days 只能给一个")
		}
		if start == "" {
			start = today
		}
		end = addDays(start, req.Days-1)
	}
	if start == "" && end != "" {
		return nil, fmt.Errorf("给了 end 时也要给 start")
	}
	if start != "" && end == "" {
		end = start
	}
	if start != "" {
		if end < start {
			return nil, fmt.Errorf("end 不能早于 start")
		}
		if daysBetween(start, end)+1 > maxRangeDays {
			return nil, fmt.Errorf("日期范围最多 %d 天", maxRangeDays)
		}
	}
	q.Start, q.End = start, end
	// 不限日期时默认带上无日期的日程；限定日期时默认不带。
	q.IncludeUndated = start == ""
	if req.IncludeUndated != nil {
		q.IncludeUndated = *req.IncludeUndated
	}
	wanted := map[string]bool{}
	for _, id := range req.ListIDs {
		if id = strings.TrimSpace(id); id != "" && !wanted[id] {
			wanted[id] = true
			q.ListIDs = append(q.ListIDs, id)
		}
	}

	snap := st.Snapshot
	var matched []*Item
	for i := range snap.Items {
		item := &snap.Items[i]
		if q.Status != "all" && item.Status != q.Status {
			continue
		}
		if len(wanted) > 0 && !wanted[item.ListID] {
			continue
		}
		if item.Undated {
			if !q.IncludeUndated {
				continue
			}
		} else if start != "" && (item.StartDate > end || item.EndDate < start) {
			continue
		}
		matched = append(matched, item)
	}
	sort.SliceStable(matched, func(i, j int) bool { return lessItem(matched[i], matched[j]) })
	returned := matched
	if len(returned) > q.Limit {
		returned = returned[:q.Limit]
	}

	render := func(item *Item) any {
		overdue := isOverdue(item, today)
		if q.Fields == "compact" {
			return compactItem{
				OccurrenceID: item.OccurrenceID, Title: item.Title, ListID: item.ListID,
				StartDate: item.StartDate, EndDate: item.EndDate, StartTime: item.StartTime, EndTime: item.EndTime,
				AllDay: item.AllDay, Undated: item.Undated, Status: item.Status, Overdue: overdue,
				Important: item.Important, Urgent: item.Urgent,
			}
		}
		return outItem{Item: *item, ListName: st.listNames[item.ListID], Overdue: overdue}
	}

	groups := []Group{}
	index := map[string]int{}
	addGroup := func(id, name, color string) {
		index[id] = len(groups)
		groups = append(groups, Group{ID: id, Name: name, Color: color, Items: []any{}})
	}
	var keyOf func(*Item) string
	switch q.GroupBy {
	case "list":
		keyOf = func(item *Item) string { return item.ListID }
		for _, list := range snap.Lists {
			if len(wanted) == 0 || wanted[list.ID] {
				addGroup(list.ID, list.Name, list.Color)
			}
		}
	case "date":
		// 跨天的日程归到范围内的第一天。
		keyOf = func(item *Item) string {
			if item.Undated {
				return "undated"
			}
			if start != "" && item.StartDate < start {
				return start
			}
			return item.StartDate
		}
	default:
		keyOf = func(*Item) string { return "all" }
		addGroup("all", "全部", "")
	}
	for _, item := range matched {
		key := keyOf(item)
		if _, ok := index[key]; !ok {
			switch {
			case key == "undated":
				addGroup(key, "无日期", "")
			case q.GroupBy == "date":
				addGroup(key, dateName(key), "")
			default:
				addGroup(key, key, "")
			}
		}
		groups[index[key]].Total++
	}
	for _, item := range returned {
		group := &groups[index[keyOf(item)]]
		group.Count++
		group.Items = append(group.Items, render(item))
	}
	if q.GroupBy == "list" && !req.IncludeEmptyLists {
		kept := groups[:0]
		for _, group := range groups {
			if group.Total > 0 {
				kept = append(kept, group)
			}
		}
		groups = kept
	}

	age := int64(now.Sub(st.ReceivedAt) / time.Second)
	if age < 0 {
		age = 0
	}
	return &QueryResponse{
		OK: true, Version: st.Version, GeneratedAt: snap.GeneratedAt,
		ReceivedAt: st.ReceivedAt.In(st.loc).Format(time.RFC3339), DataAgeSeconds: age,
		Timezone: snap.Timezone, Today: today, Query: q,
		Total: len(matched), Returned: len(returned), Truncated: len(returned) < len(matched),
		Groups: groups,
	}, nil
}

// listSummary：POST /v1/lists 里每个分类的信息和数量。
type listSummary struct {
	List
	Total   int `json:"total"`
	Pending int `json:"pending"`
	Overdue int `json:"overdue"`
}

func listSummaries(st *stored, now time.Time) []listSummary {
	today := now.In(st.loc).Format(dateLayout)
	out := make([]listSummary, len(st.Snapshot.Lists))
	index := map[string]int{}
	for i, list := range st.Snapshot.Lists {
		out[i].List = list
		index[list.ID] = i
	}
	for i := range st.Snapshot.Items {
		item := &st.Snapshot.Items[i]
		position, ok := index[item.ListID]
		if !ok {
			continue
		}
		out[position].Total++
		if item.Status == "pending" {
			out[position].Pending++
		}
		if isOverdue(item, today) {
			out[position].Overdue++
		}
	}
	return out
}
