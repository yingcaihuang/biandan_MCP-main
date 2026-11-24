package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	maxPushBody  = 16 << 20
	maxQueryBody = 16 << 10
)

type server struct {
	keys   *keyring
	store  *store
	fails  *windowLimiter // 每个 IP 认证失败次数
	reads  *windowLimiter // 每把读取密钥的请求数
	pushes *windowLimiter // 每把推送密钥的请求数
	now    func() time.Time
	mux    *http.ServeMux
}

func newServer(keysPath, dataDir string) (*server, error) {
	keys, err := newKeyring(keysPath)
	if err != nil {
		return nil, err
	}
	st, err := newStore(dataDir)
	if err != nil {
		return nil, err
	}
	s := &server{
		keys:   keys,
		store:  st,
		fails:  newLimiter(20, 10*time.Minute),
		reads:  newLimiter(120, time.Minute),
		pushes: newLimiter(60, time.Minute),
		now:    time.Now,
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/health", s.health)
	mux.HandleFunc("/v1/push", s.authed("push", s.pushes, maxPushBody, s.push))
	mux.HandleFunc("/v1/schedule", s.authed("read", s.reads, maxQueryBody, s.schedule))
	mux.HandleFunc("/v1/lists", s.authed("read", s.reads, maxQueryBody, s.lists))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "没有这个接口")
	})
	s.mux = mux
	return s, nil
}

// ServeHTTP：nginx 转发时去掉了 /biandan/api 前缀；直接带前缀访问也能用。
func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if rest, ok := strings.CutPrefix(r.URL.Path, "/biandan/api"); ok && strings.HasPrefix(rest, "/") {
		r = r.Clone(r.Context())
		r.URL.Path = rest
		r.URL.RawPath = ""
	}
	s.mux.ServeHTTP(w, r)
}

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	data, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		data = []byte(`{"ok":false,"error":{"code":"internal","message":"生成响应失败"}}`)
	}
	data = append(data, '\n')
	header := w.Header()
	header.Set("Content-Type", "application/json; charset=utf-8")
	header.Set("Content-Length", strconv.Itoa(len(data)))
	header.Set("Cache-Control", "no-store")
	header.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": apiError{Code: code, Message: message}})
}

// clientIP：只用来给认证失败计数。本服务只给本机 nginx 转发，来源是回环地址时：
// 经 ESA 时 X-Forwarded-For 第一个是设备的地址（X-Real-IP 是 ESA 节点），否则取 X-Real-IP。
// 这个头可以伪造，但只影响限流计数；密钥是 256 位随机数，限流不是防爆破的唯一手段。
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		first, _, _ := strings.Cut(r.Header.Get("X-Forwarded-For"), ",")
		if first = strings.TrimSpace(first); net.ParseIP(first) != nil {
			return first
		}
		if real := strings.TrimSpace(r.Header.Get("X-Real-IP")); real != "" {
			return real
		}
	}
	return host
}

func bearer(r *http.Request) string {
	value := strings.TrimSpace(r.Header.Get("Authorization"))
	if len(value) < 7 || !strings.EqualFold(value[:7], "Bearer ") {
		return ""
	}
	return strings.TrimSpace(value[7:])
}

// decodeRequest：空请求体按全部默认值；不认识的字段报错，方便发现拼写错误。
func decodeRequest(body []byte, target any) error {
	if len(bytes.TrimSpace(body)) == 0 {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra json.RawMessage
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return errors.New("请求体里只能有一个 JSON 对象")
	}
	return nil
}

type authedHandler func(w http.ResponseWriter, r *http.Request, keyName string, body []byte)

// authed：只收 POST；校验 Bearer 密钥和角色；限流；读取有大小上限的请求体。
func (s *server) authed(role string, limiter *windowLimiter, maxBody int64, next authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "这个接口只接受 POST")
			return
		}
		now := s.now()
		ip := clientIP(r)
		if s.fails.exceeded(ip, now) {
			w.Header().Set("Retry-After", strconv.Itoa(s.fails.retryAfter(ip, now)))
			writeError(w, http.StatusTooManyRequests, "too_many_failures", "认证失败次数太多，请稍后再试")
			return
		}
		name, ok := s.keys.match(role, bearer(r))
		if !ok {
			s.fails.add(ip, now)
			log.Printf("%s %s 来自 %s：密钥无效", r.Method, r.URL.Path, ip)
			w.Header().Set("WWW-Authenticate", `Bearer realm="biandan"`)
			writeError(w, http.StatusUnauthorized, "unauthorized", "缺少密钥或密钥无效")
			return
		}
		limitKey := role + "/" + name
		if !limiter.allow(limitKey, now) {
			w.Header().Set("Retry-After", strconv.Itoa(limiter.retryAfter(limitKey, now)))
			writeError(w, http.StatusTooManyRequests, "rate_limited", "请求太频繁，请稍后再试")
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		if err != nil {
			var tooLarge *http.MaxBytesError
			if errors.As(err, &tooLarge) {
				writeError(w, http.StatusRequestEntityTooLarge, "payload_too_large", "请求体太大")
			} else {
				writeError(w, http.StatusBadRequest, "bad_request", "读取请求体失败")
			}
			return
		}
		next(w, r, name, body)
	}
}

func (s *server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, HEAD, POST")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "只接受 GET 或 POST")
		return
	}
	result := map[string]any{"ok": true, "service": "biandan-api", "version": buildVersion, "has_data": false}
	if cur := s.store.get(); cur != nil {
		result["has_data"] = true
		result["data_age_seconds"] = int64(s.now().Sub(cur.ReceivedAt) / time.Second)
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *server) push(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var snap Snapshot
	if err := json.Unmarshal(body, &snap); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "请求体不是合法的 JSON："+err.Error())
		return
	}
	if err := normalize(&snap); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_snapshot", err.Error())
		return
	}
	st, changed, err := s.store.put(&snap, keyName, s.now())
	if err != nil {
		log.Printf("保存快照失败：%v", err)
		writeError(w, http.StatusInternalServerError, "storage_error", "服务器保存数据失败")
		return
	}
	if changed {
		log.Printf("收到 %s 推送：%d 个分类，%d 条日程，版本 %s", keyName, len(snap.Lists), len(snap.Items), st.Version)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "version": st.Version, "changed": changed,
		"lists": len(snap.Lists), "items": len(snap.Items),
		"received_at": st.ReceivedAt.In(st.loc).Format(time.RFC3339),
	})
}

func (s *server) current(w http.ResponseWriter) *stored {
	cur := s.store.get()
	if cur == nil {
		writeError(w, http.StatusServiceUnavailable, "no_data", "还没有收到便单推送的数据")
	}
	return cur
}

func notModified(w http.ResponseWriter, version string) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "not_modified": true, "version": version})
}

func (s *server) schedule(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var req QueryRequest
	if err := decodeRequest(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体有误："+err.Error())
		return
	}
	cur := s.current(w)
	if cur == nil {
		return
	}
	if req.IfVersion != "" && req.IfVersion == cur.Version {
		notModified(w, cur.Version)
		return
	}
	result, err := runQuery(cur, req, s.now())
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, result)
}

type listsRequest struct {
	IfVersion string `json:"if_version"`
}

func (s *server) lists(w http.ResponseWriter, r *http.Request, keyName string, body []byte) {
	var req listsRequest
	if err := decodeRequest(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "请求体有误："+err.Error())
		return
	}
	cur := s.current(w)
	if cur == nil {
		return
	}
	if req.IfVersion != "" && req.IfVersion == cur.Version {
		notModified(w, cur.Version)
		return
	}
	now := s.now()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok": true, "version": cur.Version, "timezone": cur.Snapshot.Timezone,
		"today": now.In(cur.loc).Format(dateLayout),
		"lists": listSummaries(cur, now),
	})
}
