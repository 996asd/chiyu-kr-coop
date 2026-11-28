package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func sampleValidReport(levelIdx int, reason string) json.RawMessage {
	payload := map[string]any{
		"format":     "kr-mp-report-v1",
		"created_at": "2026-11-28 12:00:00",
		"reason":     reason,
		"env": map[string]any{
			"mod_version": "2.4.8",
			"fl_version":  "8.2.0",
			"os":          "Windows",
		},
		"match": map[string]any{
			"pid":        1,
			"level_idx":  levelIdx,
			"level_name": "测试关卡",
			"last_tick":  960,
			"desync": map[string]any{
				"tick":        960,
				"local_hash":  "AAAA1111",
				"remote_hash": "BBBB2222",
			},
		},
		"logs": []string{"[12:00:00][KR-MP] test log"},
	}
	b, _ := json.Marshal(payload)
	return json.RawMessage(b)
}

func TestReportStoreSaveListReadAndRollingEviction(t *testing.T) {
	dir := t.TempDir()
	store, err := NewReportStore(ReportStoreConfig{
		Dir:        dir,
		MaxFiles:   3,
		MaxBytes:   64 * 1024,
		MaxPerHour: 10,
	})
	if err != nil {
		t.Fatalf("NewReportStore failed: %v", err)
	}
	if !store.Enabled() {
		t.Fatalf("expected store enabled")
	}

	var codes []string
	for i := 1; i <= 5; i++ {
		sum, err := store.Save("127.0.0.1", "玩家备注第"+string(rune('0'+i))+"条", sampleValidReport(30+i, "desync"))
		if err != nil {
			t.Fatalf("Save #%d failed: %v", i, err)
		}
		if !strings.HasPrefix(sum.Code, "R-") || len(sum.Code) != 6 {
			t.Fatalf("unexpected ticket code format: %q", sum.Code)
		}
		codes = append(codes, sum.Code)
	}

	if store.Count() != 3 {
		t.Fatalf("expected rolling count=3, got %d", store.Count())
	}
	entries, _ := os.ReadDir(dir)
	jsonFiles := 0
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".json") {
			jsonFiles++
		}
	}
	if jsonFiles != 3 {
		t.Fatalf("expected 3 JSON files on disk after eviction, got %d", jsonFiles)
	}

	// Oldest two evicted; newest three readable via "#R-XXXX", lowercase, or bare 4-char code
	if _, _, err := store.ReadByCode(codes[0]); err == nil {
		t.Fatalf("expected evicted oldest code %s to fail", codes[0])
	}
	newest := codes[4]
	gotCode, raw, err := store.ReadByCode(" #" + strings.ToLower(newest[2:]) + " ")
	if err != nil || gotCode != newest {
		t.Fatalf("ReadByCode(%s) failed: code=%s err=%v", newest, gotCode, err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("stored report invalid JSON: %v", err)
	}
	ticket, ok := doc["ticket"].(map[string]any)
	if !ok || ticket["code"] != newest {
		t.Fatalf("stored report missing ticket metadata: %#v", doc["ticket"])
	}
	if doc["user_note"] != "玩家备注第5条" {
		t.Fatalf("unexpected user_note: %#v", doc["user_note"])
	}

	// Path traversal attempts MUST be rejected
	for _, bad := range []string{"../secret", "R-../1", "R-12", "R-1234567", "bad_code"} {
		if _, _, err := store.ReadByCode(bad); err == nil {
			t.Fatalf("expected path traversal / invalid code %q to be rejected", bad)
		}
	}

	// Reload from disk preserves index & lookup
	reloaded, err := NewReportStore(ReportStoreConfig{Dir: dir, MaxFiles: 3})
	if err != nil {
		t.Fatalf("reload failed: %v", err)
	}
	if reloaded.Count() != 3 {
		t.Fatalf("reloaded count=%d, want 3", reloaded.Count())
	}
	if _, _, err := reloaded.ReadByCode(newest); err != nil {
		t.Fatalf("reloaded store could not read %s: %v", newest, err)
	}
}

func TestReportStoreSecuritySizeFormatAndRateLimit(t *testing.T) {
	dir := t.TempDir()
	store, err := NewReportStore(ReportStoreConfig{
		Dir:        dir,
		MaxFiles:   10,
		MaxBytes:   2048,
		MaxPerHour: 2,
	})
	if err != nil {
		t.Fatalf("NewReportStore failed: %v", err)
	}

	// Oversized payload rejected
	big := json.RawMessage(`{"format":"kr-mp-report-v1","pad":"` + strings.Repeat("A", 3000) + `"}`)
	if _, err := store.Save("203.0.113.55", "", big); err == nil {
		t.Fatalf("expected oversized report to be rejected")
	}

	// Wrong format rejected
	if _, err := store.Save("203.0.113.55", "", json.RawMessage(`{"format":"evil-v9"}`)); err == nil {
		t.Fatalf("expected invalid format to be rejected")
	}

	// Malformed JSON rejected
	if _, err := store.Save("203.0.113.55", "", json.RawMessage(`{not-json`)); err == nil {
		t.Fatalf("expected malformed JSON to be rejected")
	}

	// Non-loopback IP rate limit: 2 allowed, 3rd blocked
	for i := 0; i < 2; i++ {
		if _, err := store.Save("203.0.113.55", "ok", sampleValidReport(101, "manual")); err != nil {
			t.Fatalf("upload %d should pass: %v", i+1, err)
		}
	}
	if _, err := store.Save("203.0.113.55", "spam", sampleValidReport(101, "manual")); err == nil {
		t.Fatalf("3rd upload from same public IP should be rate-limited")
	}
	// Different IP still succeeds
	if _, err := store.Save("198.51.100.8", "other", sampleValidReport(102, "manual")); err != nil {
		t.Fatalf("upload from distinct IP should pass: %v", err)
	}
}

func TestHubBugReportProtocolAndHTTPAuth(t *testing.T) {
	dir := t.TempDir()
	store, err := NewReportStore(ReportStoreConfig{
		Dir:        dir,
		MaxFiles:   20,
		MaxBytes:   256 * 1024,
		MaxPerHour: 5,
		AdminToken: "secret-admin-99",
	})
	if err != nil {
		t.Fatalf("NewReportStore failed: %v", err)
	}
	hub := NewHubWithLimits(50, 100, 10, 4, 60*time.Second)
	hub.SetReportStore(store)

	c := &Client{remoteIP: "198.51.100.77", hub: hub, sendCh: make(chan []byte, 16), done: make(chan struct{})}
	hub.TryRegisterClient(c)

	// 1. SERVER_HELLO advertises report_ok: true
	hub.HandleMessage(c, &IncomingMsg{Type: "HELLO", Proto: ProtocolVer})
	rawHello := <-c.sendCh
	var hello map[string]any
	_ = json.Unmarshal(rawHello, &hello)
	if hello["t"] != "SERVER_HELLO" || hello["report_ok"] != true {
		t.Fatalf("expected SERVER_HELLO report_ok=true, got %#v", hello)
	}

	// 2. Client sends BUG_REPORT outside any room -> gets BUG_REPORT_OK with R-XXXX
	hub.HandleMessage(c, &IncomingMsg{
		Type:   "BUG_REPORT",
		Note:   "第37关英雄开大不同步",
		Report: sampleValidReport(37, "desync"),
	})
	rawResp := <-c.sendCh
	var resp map[string]any
	_ = json.Unmarshal(rawResp, &resp)
	if resp["t"] != "BUG_REPORT_OK" {
		t.Fatalf("expected BUG_REPORT_OK, got %#v", resp)
	}
	code, _ := resp["code"].(string)
	if !strings.HasPrefix(code, "R-") {
		t.Fatalf("unexpected code: %q", code)
	}
	if _, err := os.Stat(filepath.Join(dir, store.List(1)[0].Filename)); err != nil {
		t.Fatalf("report file missing on disk: %v", err)
	}

	// 3. HTTP endpoints: remote without token -> 403; remote with Bearer token -> 200; loopback -> 200
	mux := http.NewServeMux()
	store.RegisterHTTP(mux)

	reqForbidden := httptest.NewRequest(http.MethodGet, "/reports", nil)
	reqForbidden.RemoteAddr = "203.0.113.99:5555"
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, reqForbidden)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for unauthenticated public /reports, got %d", rec.Code)
	}

	reqAuthed := httptest.NewRequest(http.MethodGet, "/reports/"+code, nil)
	reqAuthed.RemoteAddr = "203.0.113.99:5555"
	reqAuthed.Header.Set("Authorization", "Bearer secret-admin-99")
	rec2 := httptest.NewRecorder()
	mux.ServeHTTP(rec2, reqAuthed)
	if rec2.Code != http.StatusOK || !strings.Contains(rec2.Body.String(), `"kr-mp-report-v1"`) {
		t.Fatalf("expected 200 JSON for Bearer auth, got code=%d body=%s", rec2.Code, rec2.Body.String())
	}

	reqLocal := httptest.NewRequest(http.MethodGet, "/reports", nil)
	reqLocal.RemoteAddr = "127.0.0.1:43210"
	rec3 := httptest.NewRecorder()
	mux.ServeHTTP(rec3, reqLocal)
	if rec3.Code != http.StatusOK || !strings.Contains(rec3.Body.String(), code) {
		t.Fatalf("expected 200 listing containing %s for loopback, got code=%d", code, rec3.Code)
	}
}
