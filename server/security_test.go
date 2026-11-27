package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestReadLineLimitedAntiOOM(t *testing.T) {
	// Normal short line
	r := bufio.NewReaderSize(strings.NewReader("{\"t\":\"PING\"}\n"), 16)
	line, err := readLineLimited(r, 128)
	if err != nil || string(line) != "{\"t\":\"PING\"}\n" {
		t.Fatalf("short line failed: err=%v line=%q", err, string(line))
	}

	// Multi-chunk line under limit
	payload := strings.Repeat("a", 100) + "\n"
	r = bufio.NewReaderSize(strings.NewReader(payload), 16)
	line, err = readLineLimited(r, 128)
	if err != nil || len(line) != 101 {
		t.Fatalf("multi-chunk failed: err=%v len=%d", err, len(line))
	}

	// Oversized garbage stream without newline MUST abort immediately at limit
	flood := bytes.Repeat([]byte("X"), 4096)
	r = bufio.NewReaderSize(bytes.NewReader(flood), 64)
	_, err = readLineLimited(r, 256)
	if !errors.Is(err, errFrameTooLarge) {
		t.Fatalf("expected errFrameTooLarge, got %v", err)
	}
}

func TestPerIPLimitsAndSakuraLoopbackExemption(t *testing.T) {
	hub := NewHubWithLimits(50, 100, 2, 2, 60*time.Second)

	// Non-loopback IP capped at maxPerIP=2
	c1 := &Client{remoteIP: "203.0.113.10", hub: hub, sendCh: make(chan []byte, 8), done: make(chan struct{})}
	c2 := &Client{remoteIP: "203.0.113.10", hub: hub, sendCh: make(chan []byte, 8), done: make(chan struct{})}
	c3 := &Client{remoteIP: "203.0.113.10", hub: hub, sendCh: make(chan []byte, 8), done: make(chan struct{})}
	if _, reason := hub.TryRegisterClient(c1); reason != "" {
		t.Fatalf("c1 unexpected reject: %s", reason)
	}
	if _, reason := hub.TryRegisterClient(c2); reason != "" {
		t.Fatalf("c2 unexpected reject: %s", reason)
	}
	if _, reason := hub.TryRegisterClient(c3); reason == "" {
		t.Fatalf("c3 should have been rejected by per-IP cap")
	}
	hub.UnregisterClient(c1)
	if _, reason := hub.TryRegisterClient(c3); reason != "" {
		t.Fatalf("c3 should succeed after c1 disconnected: %s", reason)
	}

	// Loopback (SakuraFrp 17780 local reverse proxy) must NOT be blocked by maxPerIP=2
	for i := 0; i < 6; i++ {
		lc := &Client{remoteIP: "127.0.0.1", hub: hub, sendCh: make(chan []byte, 8), done: make(chan struct{})}
		if _, reason := hub.TryRegisterClient(lc); reason != "" {
			t.Fatalf("loopback client %d should be exempt from per-IP cap, got: %s", i, reason)
		}
	}
}

func TestCreateRoomCooldownPerIPCapAndSanitize(t *testing.T) {
	if got := sanitizeLabel("  \r\n测试房\x00名  ", 4, "fb"); got != "测试房名" {
		t.Fatalf("sanitizeLabel mismatch: got %q", got)
	}
	if got := sanitizeLabel("   \t\r\n ", 8, "fallback"); got != "fallback" {
		t.Fatalf("sanitizeLabel fallback mismatch: got %q", got)
	}

	hub := NewHubWithLimits(50, 100, 10, 2, 60*time.Second)
	mkClient := func(ip string) *Client {
		c := &Client{remoteIP: ip, hub: hub, sendCh: make(chan []byte, 16), done: make(chan struct{})}
		hub.TryRegisterClient(c)
		return c
	}

	c1 := mkClient("198.51.100.5")
	hub.HandleMessage(c1, &IncomingMsg{Type: "CREATE_ROOM", Name: "Room1\r\nBad"})
	if c1.roomCode == "" {
		t.Fatalf("c1 failed to create first room")
	}
	// Immediate second CREATE_ROOM from same client hits 2s cooldown
	oldCode := c1.roomCode
	hub.HandleMessage(c1, &IncomingMsg{Type: "CREATE_ROOM", Name: "RoomSpam"})
	if c1.roomCode != oldCode {
		t.Fatalf("expected cooldown to prevent immediate second CREATE_ROOM")
	}

	// Second & third distinct clients from same public IP: maxRoomsPerIP=2 allows c2, blocks c3
	c2 := mkClient("198.51.100.5")
	hub.HandleMessage(c2, &IncomingMsg{Type: "CREATE_ROOM", Name: "Room2"})
	if c2.roomCode == "" {
		t.Fatalf("c2 should succeed within maxRoomsPerIP=2")
	}
	c3 := mkClient("198.51.100.5")
	hub.HandleMessage(c3, &IncomingMsg{Type: "CREATE_ROOM", Name: "Room3"})
	if c3.roomCode != "" {
		t.Fatalf("c3 should be blocked by maxRoomsPerIP=2, got room %s", c3.roomCode)
	}
}

func TestSetGuestReinfPatch(t *testing.T) {
	hub := NewHubWithLimits(50, 100, 10, 4, 60*time.Second)
	mkClient := func(ip string) *Client {
		c := &Client{remoteIP: ip, hub: hub, sendCh: make(chan []byte, 16), done: make(chan struct{})}
		hub.TryRegisterClient(c)
		return c
	}
	host := mkClient("127.0.0.1")
	guest := mkClient("127.0.0.1")
	hub.HandleMessage(host, &IncomingMsg{
		Type: "CREATE_ROOM",
		Name: "ReinfTest",
		Room: json.RawMessage(`{"name":"ReinfTest","heroes":[53,54],"reinforcements":["reinforcement_g4_dark","default_reinforcement"],"cataclysm":"fireball_g6","max_tech":true}`),
	})
	if host.roomCode == "" {
		t.Fatalf("host failed to create room")
	}
	hub.HandleMessage(guest, &IncomingMsg{Type: "JOIN_ROOM", Code: host.roomCode})
	if guest.roomCode != host.roomCode {
		t.Fatalf("guest failed to join room")
	}
	h2 := 65
	hub.HandleMessage(guest, &IncomingMsg{Type: "SET_GUEST", HeroIdx: &h2, Reinf: "reinforcement_g5_royal"})

	r := hub.rooms[host.roomCode]
	var roomMap map[string]any
	if err := json.Unmarshal(r.RoomJSON, &roomMap); err != nil {
		t.Fatalf("unmarshal room JSON failed: %v", err)
	}
	reinfs, ok := roomMap["reinforcements"].([]any)
	if !ok || len(reinfs) != 2 || reinfs[0] != "reinforcement_g4_dark" || reinfs[1] != "reinforcement_g5_royal" {
		t.Fatalf("unexpected reinforcements after SET_GUEST: %#v", roomMap["reinforcements"])
	}
	heroes, ok := roomMap["heroes"].([]any)
	if !ok || len(heroes) != 2 || int(heroes[1].(float64)) != 65 {
		t.Fatalf("unexpected heroes after SET_GUEST: %#v", roomMap["heroes"])
	}
}
