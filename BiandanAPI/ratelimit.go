package main

import (
	"sync"
	"time"
)

// windowLimiter：固定时间窗计数，每个键在 span 内最多 limit 次。
type windowLimiter struct {
	mu    sync.Mutex
	limit int
	span  time.Duration
	hits  map[string]*window
}

type window struct {
	start time.Time
	n     int
}

const maxLimiterKeys = 10000

func newLimiter(limit int, span time.Duration) *windowLimiter {
	return &windowLimiter{limit: limit, span: span, hits: map[string]*window{}}
}

func (l *windowLimiter) current(key string, now time.Time) *window {
	w := l.hits[key]
	if w == nil || now.Sub(w.start) >= l.span {
		if len(l.hits) >= maxLimiterKeys {
			l.prune(now)
		}
		w = &window{start: now}
		l.hits[key] = w
	}
	return w
}

func (l *windowLimiter) prune(now time.Time) {
	for key, w := range l.hits {
		if now.Sub(w.start) >= l.span {
			delete(l.hits, key)
		}
	}
	if len(l.hits) >= maxLimiterKeys {
		clear(l.hits)
	}
}

// exceeded：这个键在当前窗口里已经用满，不计数。
func (l *windowLimiter) exceeded(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.current(key, now).n >= l.limit
}

func (l *windowLimiter) add(key string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.current(key, now).n++
}

// allow：没用满就计一次并放行。
func (l *windowLimiter) allow(key string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	w := l.current(key, now)
	if w.n >= l.limit {
		return false
	}
	w.n++
	return true
}

// retryAfter：当前窗口还剩几秒，至少 1。
func (l *windowLimiter) retryAfter(key string, now time.Time) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	left := l.span - now.Sub(l.current(key, now).start)
	if left < time.Second {
		return 1
	}
	return int(left / time.Second)
}
