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
	lvl := 142
	hub.HandleMessage(guest, &IncomingMsg{Type: "SET_GUEST", HeroIdx: &h2, Reinf: "reinforcement_g5_royal", LevelIdx: &lvl})

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
	if int(roomMap["level_idx"].(float64)) != 142 || r.Meta.LevelIdx != 142 {
		t.Fatalf("unexpected level_idx after guest stage pick: map=%v meta=%d", roomMap["level_idx"], r.Meta.LevelIdx)
	}
}

func TestLobbyReconnectAndExplicitLeave(t *testing.T) {
	hub := NewHubWithLimits(50, 100, 10, 4, 60*time.Second)
	hub.lobbyReconnectGrace = 2 * time.Second
	mkClient := func(ip string) *Client {
		c := &Client{remoteIP: ip, hub: hub, sendCh: make(chan []byte, 32), done: make(chan struct{})}
		hub.TryRegisterClient(c)
		return c
	}
	drainLast := func(c *Client) map[string]any {
		var last []byte
		for {
			select {
			case b := <-c.sendCh:
				last = b
			default:
				if len(last) == 0 {
					return nil
				}
				var m map[string]any
				_ = json.Unmarshal(last, &m)
				return m
			}
		}
	}

	host := mkClient("127.0.0.1")
	guest := mkClient("127.0.0.1")
	hub.HandleMessage(host, &IncomingMsg{
		Type: "CREATE_ROOM",
		Name: "ReconnectLobby",
		Room: json.RawMessage(`{"name":"ReconnectLobby","level_idx":101,"heroes":[53,54]}`),
	})
	code := host.roomCode
	r := hub.rooms[code]
	hostToken := r.Seats[1].Token
	hub.HandleMessage(guest, &IncomingMsg{Type: "JOIN_ROOM", Code: code})
	drainLast(host)
	drainLast(guest)

	// Unexpected TCP drop by Host in lobby must hold the room and notify P2 peer_connected=false
	hub.UnregisterClient(host)
	if hub.rooms[code] == nil {
		t.Fatalf("room %s should be held during lobby reconnect grace", code)
	}
	gMsg := drainLast(guest)
	if gMsg == nil || gMsg["t"] != "ROOM_STATE" || gMsg["peer_connected"] != false {
		t.Fatalf("expected ROOM_STATE peer_connected=false for guest, got %#v", gMsg)
	}

	// Host reconnects cleanly into lobby with saved token
	host2 := mkClient("127.0.0.1")
	hub.HandleMessage(host2, &IncomingMsg{Type: "RECONNECT", Code: code, Pid: 1, Token: hostToken})
	if host2.roomCode != code || host2.pid != 1 {
		t.Fatalf("host2 failed to rejoin lobby room: code=%s pid=%d", host2.roomCode, host2.pid)
	}
	var sawRejoined bool
	for {
		select {
		case b := <-host2.sendCh:
			var m map[string]any
			_ = json.Unmarshal(b, &m)
			if m["t"] == "ROOM_REJOINED" && m["peer_connected"] == true {
				sawRejoined = true
			}
		default:
			goto doneRead
		}
	}
doneRead:
	if !sawRejoined {
		t.Fatalf("host2 did not receive ROOM_REJOINED with peer_connected=true")
	}

	// Explicit LEAVE_ROOM by guest keeps Host room open
	hub.HandleMessage(guest, &IncomingMsg{Type: "LEAVE_ROOM"})
	if hub.rooms[code] == nil || r.Seats[2] != nil {
		t.Fatalf("guest explicit LEAVE_ROOM should keep host room open and clear P2 seat")
	}

	// Explicit LEAVE_ROOM by host closes room immediately
	hub.HandleMessage(host2, &IncomingMsg{Type: "LEAVE_ROOM"})
	if hub.rooms[code] != nil {
		t.Fatalf("host explicit LEAVE_ROOM should close room immediately")
	}
}

func TestDirectChainNextStageAndMatchFlow(t *testing.T) {
	hub := NewHubWithLimits(50, 100, 10, 4, 60*time.Second)
	mkClient := func() *Client {
		c := &Client{remoteIP: "127.0.0.1", hub: hub, sendCh: make(chan []byte, 32), done: make(chan struct{})}
		hub.TryRegisterClient(c)
		return c
	}
	drainAll := func(c *Client) []map[string]any {
		var out []map[string]any
		for {
			select {
			case b := <-c.sendCh:
				var m map[string]any
				_ = json.Unmarshal(b, &m)
				out = append(out, m)
			default:
				return out
			}
		}
	}

	host := mkClient()
	guest := mkClient()

	// SERVER_HELLO advertises direct_next_ok
	hub.HandleMessage(host, &IncomingMsg{Type: "HELLO", Proto: ProtocolVer})
	msgs := drainAll(host)
	if len(msgs) == 0 || msgs[0]["t"] != "SERVER_HELLO" || msgs[0]["direct_next_ok"] != true {
		t.Fatalf("expected SERVER_HELLO with direct_next_ok=true, got %#v", msgs)
	}

	hub.HandleMessage(host, &IncomingMsg{
		Type: "CREATE_ROOM",
		Name: "ChainRoom",
		Room: json.RawMessage(`{"name":"ChainRoom","level_idx":45,"heroes":[53,54]}`),
	})
	code := host.roomCode
	hub.HandleMessage(guest, &IncomingMsg{Type: "JOIN_ROOM", Code: code})
	drainAll(host)
	drainAll(guest)

	// Start Match #1 (level 45)
	hub.HandleMessage(host, &IncomingMsg{
		Type: "START_MATCH",
		Cfg:  json.RawMessage(`{"match_id":"m1","level_idx":45,"seed":111,"turn_ticks":3,"input_delay_turns":2}`),
	})
	hub.HandleMessage(host, &IncomingMsg{Type: "LOAD_DONE", Pid: 1, MatchID: "m1"})
	hub.HandleMessage(guest, &IncomingMsg{Type: "LOAD_DONE", Pid: 2, MatchID: "m1"})
	r := hub.rooms[code]
	if r.Status != "running" || r.MatchID != "m1" {
		t.Fatalf("expected running m1, got status=%s match_id=%s", r.Status, r.MatchID)
	}
	drainAll(host)
	drainAll(guest)

	// Guest sends MATCH_FLOW next -> relayed to Host
	nxt := 46
	hub.HandleMessage(guest, &IncomingMsg{Type: "MATCH_FLOW", Pid: 2, Action: "next", LevelIdx: &nxt})
	hMsgs := drainAll(host)
	if len(hMsgs) != 1 || hMsgs[0]["t"] != "MATCH_FLOW" || hMsgs[0]["action"] != "next" || int(hMsgs[0]["level_idx"].(float64)) != 46 {
		t.Fatalf("expected relayed MATCH_FLOW to host, got %#v", hMsgs)
	}

	// Host directly chains START_MATCH (level 46, m2) while r.Status == "running" (NO RETURN_LOBBY!)
	hub.HandleMessage(host, &IncomingMsg{
		Type:        "START_MATCH",
		DirectChain: true,
		Cfg:         json.RawMessage(`{"match_id":"m2","level_idx":46,"seed":222,"turn_ticks":3,"input_delay_turns":2}`),
	})
	if r.Status != "loading" || r.MatchID != "m2" || r.Meta.LevelIdx != 46 {
		t.Fatalf("direct chain failed: status=%s match_id=%s level=%d", r.Status, r.MatchID, r.Meta.LevelIdx)
	}
	drainAll(host)
	drainAll(guest)

	// Late trailing TURN from Match #1 while loading m2 must be silently dropped
	staleTurn := 650
	hub.HandleMessage(guest, &IncomingMsg{Type: "TURN", Pid: 2, Turn: &staleTurn, Cmds: json.RawMessage(`[]`)})
	if r.Turns[650] != nil || len(drainAll(host)) != 0 {
		t.Fatalf("stale TURN during loading must be dropped")
	}

	// Stale LOAD_DONE from m1 must be ignored; m2 LOAD_DONE starts m2 with match_id=m2
	hub.HandleMessage(guest, &IncomingMsg{Type: "LOAD_DONE", Pid: 2, MatchID: "m1"})
	if r.Seats[2].Loaded {
		t.Fatalf("stale LOAD_DONE(m1) should have been ignored")
	}
	hub.HandleMessage(host, &IncomingMsg{Type: "LOAD_DONE", Pid: 1, MatchID: "m2"})
	hub.HandleMessage(guest, &IncomingMsg{Type: "LOAD_DONE", Pid: 2, MatchID: "m2"})
	if r.Status != "running" {
		t.Fatalf("expected running after m2 LOAD_DONE, got %s", r.Status)
	}
	bMsgs := drainAll(guest)
	if len(bMsgs) != 1 || bMsgs[0]["t"] != "BEGIN_SIM" || bMsgs[0]["match_id"] != "m2" {
		t.Fatalf("expected BEGIN_SIM(m2), got %#v", bMsgs)
	}
}
