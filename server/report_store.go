package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultReportMaxFiles   = 200
	defaultReportMaxBytes   = 512 * 1024 // 512 KB hard cap per bug report
	defaultReportMaxPerHour = 6          // Per non-loopback IP hourly upload cap
	expectedReportFormat    = "kr-mp-report-v1"
)

// ReportStoreConfig configures server-side storage & abuse protection for Layer 3 bug reports.
type ReportStoreConfig struct {
	Dir        string
	MaxFiles   int
	MaxBytes   int
	MaxPerHour int
	AdminToken string
}

// ReportSummary holds lightweight searchable metadata extracted from a stored kr-mp-report-v1 JSON.
type ReportSummary struct {
	Code       string `json:"code"`
	Filename   string `json:"filename"`
	ReceivedAt string `json:"received_at"`
	Bytes      int    `json:"bytes"`
	ModVer     string `json:"mod_ver,omitempty"`
	Reason     string `json:"reason,omitempty"`
	LevelIdx   int    `json:"level_idx,omitempty"`
	LevelName  string `json:"level_name,omitempty"`
	DesyncTick int    `json:"desync_tick,omitempty"`
	HasCrash   bool   `json:"has_crash,omitempty"`
	Note       string `json:"note,omitempty"`
	OS         string `json:"os,omitempty"`
}

// ReportStore persists player-submitted bug reports with rolling eviction, size limits, and per-IP rate limiting.
type ReportStore struct {
	mu         sync.Mutex
	dir        string
	maxFiles   int
	maxBytes   int
	maxPerHour int
	adminToken string
	rateHits   map[string][]time.Time
	index      []ReportSummary   // newest-first
	byCode     map[string]string // normalized code (e.g. "R-4K9A") -> filename
}

// NewReportStore initializes a ReportStore. An empty Dir disables server-side report collection.
func NewReportStore(cfg ReportStoreConfig) (*ReportStore, error) {
	dir := strings.TrimSpace(cfg.Dir)
	if cfg.MaxFiles <= 0 {
		cfg.MaxFiles = defaultReportMaxFiles
	}
	if cfg.MaxBytes <= 0 {
		cfg.MaxBytes = defaultReportMaxBytes
	}
	if cfg.MaxPerHour <= 0 {
		cfg.MaxPerHour = defaultReportMaxPerHour
	}
	s := &ReportStore{
		dir:        dir,
		maxFiles:   cfg.MaxFiles,
		maxBytes:   cfg.MaxBytes,
		maxPerHour: cfg.MaxPerHour,
		adminToken: strings.TrimSpace(cfg.AdminToken),
		rateHits:   make(map[string][]time.Time),
		byCode:     make(map[string]string),
	}
	if dir == "" {
		return s, nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("create report dir %q: %w", dir, err)
	}
	s.loadExistingLocked()
	return s, nil
}

func (s *ReportStore) Enabled() bool {
	return s != nil && s.dir != ""
}

func (s *ReportStore) Dir() string {
	if s == nil {
		return ""
	}
	return s.dir
}

func (s *ReportStore) Count() int {
	if s == nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.index)
}

// normalizeReportCode validates & canonicalizes a ticket code (e.g. "#R-4k9a" or "4k9a" -> "R-4K9A").
// Strict ASCII whitelist prevents any path traversal.
func normalizeReportCode(raw string) (string, bool) {
	c := strings.ToUpper(strings.TrimSpace(raw))
	c = strings.TrimPrefix(c, "#")
	if len(c) == 4 && isAlphaNumUpper(c) {
		c = "R-" + c
	}
	if !strings.HasPrefix(c, "R-") {
		return "", false
	}
	body := c[2:]
	if len(body) < 4 || len(body) > 6 || !isAlphaNumUpper(body) {
		return "", false
	}
	return c, true
}

func isAlphaNumUpper(s string) bool {
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		ch := s[i]
		isDigit := ch >= '0' && ch <= '9'
		isUpper := ch >= 'A' && ch <= 'Z'
		if !isDigit && !isUpper {
			return false
		}
	}
	return true
}

func extractReportSummary(code, fname string, receivedAt string, size int, doc map[string]any) ReportSummary {
	sum := ReportSummary{
		Code:       code,
		Filename:   fname,
		ReceivedAt: receivedAt,
		Bytes:      size,
	}
	if r, ok := doc["reason"].(string); ok {
		sum.Reason = sanitizeLabel(r, 32, "")
	}
	if n, ok := doc["user_note"].(string); ok {
		sum.Note = sanitizeLabel(n, 160, "")
	}
	if env, ok := doc["env"].(map[string]any); ok {
		if v, ok := env["mod_version"].(string); ok {
			sum.ModVer = sanitizeLabel(v, 24, "")
		}
		if o, ok := env["os"].(string); ok {
			sum.OS = sanitizeLabel(o, 24, "")
		}
	}
	if crash, ok := doc["crash"].(map[string]any); ok {
		if tb, ok := crash["traceback"].(string); ok && len(strings.TrimSpace(tb)) > 0 {
			sum.HasCrash = true
		}
	}
	if m, ok := doc["match"].(map[string]any); ok {
		if lvl, ok := m["level_idx"].(float64); ok {
			sum.LevelIdx = int(lvl)
		}
		if ln, ok := m["level_name"].(string); ok {
			sum.LevelName = sanitizeLabel(ln, 48, "")
		}
		if d, ok := m["desync"].(map[string]any); ok {
			if tk, ok := d["tick"].(float64); ok {
				sum.DesyncTick = int(tk)
			}
		}
	}
	if ticket, ok := doc["ticket"].(map[string]any); ok {
		if ts, ok := ticket["received_at"].(string); ok && ts != "" {
			sum.ReceivedAt = ts
		}
	}
	return sum
}

func (s *ReportStore) loadExistingLocked() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	type fileRec struct {
		name string
		code string
		mod  time.Time
		size int
	}
	var recs []fileRec
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasPrefix(name, "R-") || !strings.HasSuffix(name, ".json") {
			continue
		}
		us := strings.IndexByte(name, '_')
		if us <= 2 {
			continue
		}
		code, ok := normalizeReportCode(name[:us])
		if !ok {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		recs = append(recs, fileRec{
			name: name,
			code: code,
			mod:  info.ModTime(),
			size: int(info.Size()),
		})
	}
	// Sort newest-first (by filename timestamp / modtime)
	sort.Slice(recs, func(i, j int) bool {
		if !recs[i].mod.Equal(recs[j].mod) {
			return recs[i].mod.After(recs[j].mod)
		}
		return recs[i].name > recs[j].name
	})

	s.index = nil
	s.byCode = make(map[string]string)
	for _, rec := range recs {
		fullPath := filepath.Join(s.dir, rec.name)
		data, err := os.ReadFile(fullPath)
		if err != nil {
			continue
		}
		var doc map[string]any
		if err := json.Unmarshal(data, &doc); err != nil {
			continue
		}
		sum := extractReportSummary(rec.code, rec.name, rec.mod.Format(time.RFC3339), len(data), doc)
		s.index = append(s.index, sum)
		s.byCode[rec.code] = rec.name
	}
	s.pruneLocked()
}

func (s *ReportStore) checkRateLimitLocked(remoteIP string, now time.Time) error {
	if remoteIP == "" {
		return nil
	}
	cutoff := now.Add(-1 * time.Hour)
	// Prevent unbounded map growth under IP spray
	if len(s.rateHits) > 4096 {
		for k, times := range s.rateHits {
			kept := times[:0]
			for _, ts := range times {
				if ts.After(cutoff) {
					kept = append(kept, ts)
				}
			}
			if len(kept) == 0 {
				delete(s.rateHits, k)
			} else {
				s.rateHits[k] = kept
			}
		}
	}
	prev := s.rateHits[remoteIP]
	kept := prev[:0]
	for _, ts := range prev {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	capLimit := s.maxPerHour
	if isLoopbackIP(remoteIP) {
		capLimit = s.maxPerHour * 10
		if capLimit < 60 {
			capLimit = 60
		}
	}
	if len(kept) >= capLimit {
		s.rateHits[remoteIP] = kept
		return fmt.Errorf("上传过于频繁（每小时上限 %d 份），请稍后再试或使用本地导出 (.json)", capLimit)
	}
	s.rateHits[remoteIP] = append(kept, now)
	return nil
}

func (s *ReportStore) generateUniqueCodeLocked() string {
	for i := 0; i < 64; i++ {
		c := "R-" + randomCode(4)
		if _, exists := s.byCode[c]; !exists {
			return c
		}
	}
	return "R-" + randomCode(6)
}

func (s *ReportStore) pruneLocked() {
	for len(s.index) > s.maxFiles {
		oldest := s.index[len(s.index)-1]
		s.index = s.index[:len(s.index)-1]
		if cur, ok := s.byCode[oldest.Code]; ok && cur == oldest.Filename {
			delete(s.byCode, oldest.Code)
		}
		_ = os.Remove(filepath.Join(s.dir, oldest.Filename))
	}
}

// Save validates, annotates with a unique 6-char ticket code (e.g. R-4K9A), writes atomically, and enforces rolling quota.
func (s *ReportStore) Save(remoteIP, note string, rawReport json.RawMessage) (*ReportSummary, error) {
	if !s.Enabled() {
		return nil, errors.New("当前服务器未启用云端报错收集")
	}
	trimmed := bytes.TrimSpace(rawReport)
	if len(trimmed) == 0 {
		return nil, errors.New("报错报告内容为空")
	}
	if len(trimmed) > s.maxBytes {
		return nil, fmt.Errorf("报错报告体积 (%d KB) 超出服务器上限 (%d KB)，请使用本地导出 (.json)",
			(len(trimmed)+1023)/1024, s.maxBytes/1024)
	}

	var doc map[string]any
	if err := json.Unmarshal(trimmed, &doc); err != nil {
		return nil, errors.New("报错报告 JSON 格式损坏")
	}
	if fmtStr, _ := doc["format"].(string); fmtStr != expectedReportFormat {
		return nil, fmt.Errorf("不支持的报告格式: %q", fmtStr)
	}

	cleanNote := sanitizeLabel(note, 160, "")
	if cleanNote != "" {
		doc["user_note"] = cleanNote
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	if err := s.checkRateLimitLocked(remoteIP, now); err != nil {
		return nil, err
	}

	code := s.generateUniqueCodeLocked()
	receivedAt := now.Format(time.RFC3339)
	doc["ticket"] = map[string]any{
		"code":        code,
		"received_at": receivedAt,
		"server_ver":  ServerVersion,
	}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(doc); err != nil {
		return nil, fmt.Errorf("序列化报告失败: %w", err)
	}
	payload := buf.Bytes()

	fname := fmt.Sprintf("%s_%s.json", code, now.Format("20060102_150405"))
	dstPath := filepath.Join(s.dir, fname)
	tmpPath := filepath.Join(s.dir, "."+fname+".tmp")
	if err := os.WriteFile(tmpPath, payload, 0o644); err != nil {
		return nil, fmt.Errorf("写入服务器磁盘失败: %w", err)
	}
	if err := os.Rename(tmpPath, dstPath); err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("保存报告文件失败: %w", err)
	}

	sum := extractReportSummary(code, fname, receivedAt, len(payload), doc)
	s.index = append([]ReportSummary{sum}, s.index...)
	s.byCode[code] = fname
	s.pruneLocked()
	return &sum, nil
}

// List returns the latest up to limit summaries in newest-first order.
func (s *ReportStore) List(limit int) []ReportSummary {
	if s == nil {
		return nil
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n := len(s.index)
	if n > limit {
		n = limit
	}
	out := make([]ReportSummary, n)
	copy(out, s.index[:n])
	return out
}

// ReadByCode fetches the raw JSON bytes of a stored report by ticket code (e.g. "R-4K9A" or "#R-4K9A" or "4K9A").
func (s *ReportStore) ReadByCode(rawCode string) (string, []byte, error) {
	if !s.Enabled() {
		return "", nil, os.ErrNotExist
	}
	code, ok := normalizeReportCode(rawCode)
	if !ok {
		return "", nil, errors.New("invalid report code format")
	}
	s.mu.Lock()
	fname, exists := s.byCode[code]
	s.mu.Unlock()
	if !exists || fname == "" {
		return code, nil, os.ErrNotExist
	}
	data, err := os.ReadFile(filepath.Join(s.dir, fname))
	if err != nil {
		return code, nil, err
	}
	return code, data, nil
}

func (s *ReportStore) authorizeHTTP(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if isLoopbackIP(host) {
		return true
	}
	if s.adminToken == "" {
		return false
	}
	got := ""
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if strings.HasPrefix(auth, "Bearer ") {
		got = strings.TrimSpace(auth[len("Bearer "):])
	} else if q := strings.TrimSpace(r.URL.Query().Get("token")); q != "" {
		got = q
	}
	if len(got) != len(s.adminToken) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(s.adminToken)) == 1
}

// RegisterHTTP mounts optional admin inspection endpoints (/reports and /reports/<CODE>) on the server's HTTP mux.
// By default (no -report-admin-token), access is strictly restricted to loopback (127.0.0.1 / ::1).
func (s *ReportStore) RegisterHTTP(mux *http.ServeMux) {
	if mux == nil || s == nil {
		return
	}
	mux.HandleFunc("/reports", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !s.authorizeHTTP(r) {
			http.Error(w, "forbidden (loopback or valid admin token required)", http.StatusForbidden)
			return
		}
		limit := 50
		if q := r.URL.Query().Get("limit"); q != "" {
			if v, err := strconv.Atoi(q); err == nil && v > 0 {
				limit = v
			}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		enc := json.NewEncoder(w)
		enc.SetEscapeHTML(false)
		_ = enc.Encode(map[string]any{
			"enabled": s.Enabled(),
			"count":   s.Count(),
			"reports": s.List(limit),
		})
	})

	mux.HandleFunc("/reports/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !s.authorizeHTTP(r) {
			http.Error(w, "forbidden (loopback or valid admin token required)", http.StatusForbidden)
			return
		}
		rawCode := strings.TrimPrefix(r.URL.Path, "/reports/")
		code, data, err := s.ReadByCode(rawCode)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				http.Error(w, "report not found: "+code, http.StatusNotFound)
			} else {
				http.Error(w, "bad report code", http.StatusBadRequest)
			}
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.Header().Set("Content-Disposition", fmt.Sprintf("inline; filename=%q", code+".json"))
		_, _ = w.Write(data)
		log.Printf("[REPORT] HTTP served #%s (%d bytes) to %s", code, len(data), r.RemoteAddr)
	})
}
