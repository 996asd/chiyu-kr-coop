package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"strings"
	"time"
)

func (h *Hub) HandleMessage(c *Client, msg *IncomingMsg) {
	// PING/PONG doesn't even need the Hub lock!
	if msg.Type == "PING" {
		c.Send(map[string]any{"t": "PONG", "ts": msg.Ts})
		return
	}
	// BUG_REPORT persists JSON to disk under ReportStore's own lock so it NEVER stalls 60Hz match relay!
	if msg.Type == "BUG_REPORT" {
		h.handleBugReport(c, msg)
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	switch msg.Type {
	case "HELLO":
		h.onHelloLocked(c, msg)
	case "LIST_ROOMS":
		c.Send(map[string]any{"t": "ROOM_LIST", "rooms": h.buildRoomListLocked()})
	case "CREATE_ROOM":
		h.onCreateRoomLocked(c, msg)
	case "JOIN_ROOM":
		h.onJoinRoomLocked(c, msg)
	case "LEAVE_ROOM":
		h.handleDisconnectLocked(c, true)
	case "UPDATE_ROOM":
		h.onUpdateRoomLocked(c, msg)
	case "SET_GUEST":
		h.onSetGuestLocked(c, msg)
	case "START_MATCH":
		h.onStartMatchLocked(c, msg)
	case "LOAD_DONE":
		h.onLoadDoneLocked(c, msg)
	case "TURN":
		h.onTurnLocked(c, msg)
	case "SYNC_RESUME":
		h.onSyncResumeLocked(c, msg)
	case "SYNC_SPEED":
		h.onSyncSpeedLocked(c, msg)
	case "RECONNECT":
		h.onReconnectLocked(c, msg)
	case "RECONNECT_DONE":
		h.onReconnectDoneLocked(c, msg)
	case "VOICE":
		h.onVoiceLocked(c, msg)
	case "DESYNC_DIAG":
		h.onDesyncDiagLocked(c, msg)
	case "RETURN_LOBBY":
		h.onReturnLobbyLocked(c, msg)
	case "MATCH_FLOW":
		h.onMatchFlowLocked(c, msg)
	default:
		c.Send(map[string]any{"t": "ERROR", "msg": "Unknown message type: " + msg.Type})
	}
}

func (h *Hub) handleBugReport(c *Client, msg *IncomingMsg) {
	h.mu.Lock()
	rs := h.reports
	h.mu.Unlock()
	if rs == nil || !rs.Enabled() {
		c.Send(map[string]any{
			"t":   "BUG_REPORT_ERR",
			"msg": "当前公网中继服未开启云端报错收集，请改用「本地导出 (.json)」把文件发给作者。",
		})
		return
	}
	sum, err := rs.Save(c.remoteIP, msg.Note, msg.Report)
	if err != nil {
		log.Printf("[REPORT] Rejected upload from client %d (%s): %v", c.id, c.remoteIP, err)
		c.Send(map[string]any{
			"t":   "BUG_REPORT_ERR",
			"msg": err.Error(),
		})
		return
	}
	log.Printf("[REPORT] Saved #%s (%d bytes, level=%d, reason=%s, crash=%v, desync=%d) from %s",
		sum.Code, sum.Bytes, sum.LevelIdx, sum.Reason, sum.HasCrash, sum.DesyncTick, c.remoteIP)
	c.Send(map[string]any{
		"t":           "BUG_REPORT_OK",
		"code":        sum.Code,
		"bytes":       sum.Bytes,
		"received_at": sum.ReceivedAt,
	})
}

func (h *Hub) onReturnLobbyLocked(c *Client, msg *IncomingMsg) {
	if c.roomCode == "" || c.pid < 1 || c.pid > 2 {
		return
	}
	r, ok := h.rooms[c.roomCode]
	if !ok {
		return
	}
	r.Status = "lobby"
	r.MatchID = ""
	r.MatchCfgRaw = nil
	r.Turns = nil
	r.HighestCompleteTurn = 0
	r.Paused = false
	r.GameSpeed = 1
	r.UpdatedAt = time.Now()
	for pid := 1; pid <= 2; pid++ {
		if r.Seats[pid] != nil {
			r.Seats[pid].Loaded = false
			r.Seats[pid].CatchingUp = false
			r.Seats[pid].LastSentTurn = 0
			r.Seats[pid].Ready = true
		}
	}
	log.Printf("[ROOM %s] P%d triggered RETURN_LOBBY -> keeping TCP alive back in war table", r.Code, c.pid)
	p1Conn := r.Seats[1] != nil && r.Seats[1].Connected
	p2Conn := r.Seats[2] != nil && r.Seats[2].Connected
	p2Ready := p2Conn && r.Seats[2].Ready
	for pid := 1; pid <= 2; pid++ {
		if r.Seats[pid] != nil && r.Seats[pid].Connected && r.Seats[pid].Client != nil {
			otherConn := p2Conn
			otherReady := p2Ready
			if pid == 2 {
				otherConn = p1Conn
				otherReady = p1Conn
			}
			r.Seats[pid].Client.Send(map[string]any{
				"t":              "RETURN_LOBBY",
				"pid":            c.pid,
				"room":           r.RoomJSON,
				"peer_connected": otherConn,
				"peer_ready":     otherReady,
			})
		}
	}
}


func (h *Hub) onHelloLocked(c *Client, msg *IncomingMsg) {
	if msg.Proto != ProtocolVer {
		c.Send(map[string]any{
			"t":   "ERROR",
			"msg": fmt.Sprintf("Protocol mismatch! Server=%d Client=%d. Please update KR-MP MOD.", ProtocolVer, msg.Proto),
		})
		return
	}
	c.helloDone = true
	c.modVer = msg.ModVer
	c.flVer = msg.FLVer
	c.scriptHash = msg.ScriptHash
	c.tickLen = msg.TickLen
	if msg.Name != "" {
		c.name = sanitizeLabel(msg.Name, 24, fmt.Sprintf("Player-%d", c.id))
	} else if msg.PlayerName != "" {
		c.name = sanitizeLabel(msg.PlayerName, 24, fmt.Sprintf("Player-%d", c.id))
	} else if c.name == "" {
		c.name = fmt.Sprintf("Player-%d", c.id)
	}

	c.Send(map[string]any{
		"t":                  "SERVER_HELLO",
		"server_ver":         ServerVersion,
		"proto":              ProtocolVer,
		"voice_ok":           true,
		"guest_stage_ok":     true,
		"lobby_reconnect_ok": true,
		"direct_next_ok":     true,
		"report_ok":          h.ReportsEnabled(),
		"client_id":          c.id,
		"rooms":              h.buildRoomListLocked(),
	})
}

func (h *Hub) generateUniqueCodeLocked() string {
	for i := 0; i < 64; i++ {
		code := randomCode(4)
		if _, exists := h.rooms[code]; !exists {
			return code
		}
	}
	return randomCode(6)
}

func parseRoomMeta(raw json.RawMessage) RoomMeta {
	meta := RoomMeta{
		Name:            "KR-MP Online Room",
		LevelIdx:        101,
		LevelMode:       1,
		LevelDifficulty: 2,
		EconMode:        "independent",
		TowerMode:       "owned",
		Heroes:          []int{48, 49},
	}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &meta)
	}
	return meta
}

func (h *Hub) onCreateRoomLocked(c *Client, msg *IncomingMsg) {
	now := time.Now()
	if !c.lastCreateRoom.IsZero() && now.Sub(c.lastCreateRoom) < 2*time.Second {
		c.Send(map[string]any{"t": "ERROR", "msg": "创建房间过于频繁，请 2 秒后再试。"})
		return
	}
	if c.roomCode != "" {
		h.handleDisconnectLocked(c, true)
	}
	if len(h.rooms) >= h.maxRooms {
		c.Send(map[string]any{"t": "ERROR", "msg": "Server room limit reached; try again shortly."})
		return
	}
	if c.remoteIP != "" && !isLoopbackIP(c.remoteIP) {
		ipRooms := 0
		for _, r := range h.rooms {
			if r.HostIP == c.remoteIP {
				ipRooms++
			}
		}
		if ipRooms >= h.maxRoomsPerIP {
			c.Send(map[string]any{"t": "ERROR", "msg": "同一 IP 创建房间数量已达上限，请先关闭旧房间。"})
			return
		}
	}

	flVer := msg.FLVer
	if flVer == "" {
		flVer = c.flVer
	}
	modVer := msg.ModVer
	if modVer == "" {
		modVer = c.modVer
	}
	scriptHash := msg.ScriptHash
	if scriptHash == "" {
		scriptHash = c.scriptHash
	}
	tickLen := msg.TickLen
	if tickLen <= 0 {
		tickLen = c.tickLen
	}
	if tickLen <= 0 {
		tickLen = 1.0 / 60.0
	}

	hostName := msg.PlayerName
	if hostName == "" {
		hostName = c.name
	}
	hostName = sanitizeLabel(hostName, 24, "Player 1")
	c.name = hostName

	public := true
	if msg.Public != nil {
		public = *msg.Public
	}

	meta := parseRoomMeta(msg.Room)
	rawRoomName := strings.TrimSpace(msg.Name)
	if rawRoomName == "" {
		rawRoomName = meta.Name
	}
	roomName := sanitizeLabel(rawRoomName, 32, "KR-MP Co-op")

	roomJSON := msg.Room
	if len(roomJSON) == 0 {
		roomJSON, _ = json.Marshal(meta)
	}

	code := h.generateUniqueCodeLocked()
	token := randomToken()
	c.lastCreateRoom = now

	r := &Room{
		Code:       code,
		Name:       roomName,
		HostIP:     c.remoteIP,
		Password:   msg.Password,
		Public:     public,
		Status:     "lobby",
		CreatedAt:  now,
		UpdatedAt:  now,
		ModVer:     modVer,
		FLVer:      flVer,
		ScriptHash: scriptHash,
		TickLen:    tickLen,
		RoomJSON:   append(json.RawMessage(nil), roomJSON...),
		Meta:       meta,
		GameSpeed:  1,
	}
	r.Seats[1] = &Seat{
		Pid:       1,
		Name:      hostName,
		Token:     token,
		Client:    c,
		Connected: true,
		Ready:     true,
	}

	h.rooms[code] = r
	c.roomCode = code
	c.pid = 1

	log.Printf("[ROOM %s] Created by %s (public=%v pw=%v FL=%s hash=%s)",
		code, hostName, public, r.Password != "", r.FLVer, r.ScriptHash)

	c.Send(map[string]any{
		"t":         "ROOM_CREATED",
		"code":      code,
		"pid":       1,
		"token":     token,
		"room":      r.RoomJSON,
		"host_name": hostName,
		"public":    public,
		"has_pw":    r.Password != "",
	})
}

func (h *Hub) onJoinRoomLocked(c *Client, msg *IncomingMsg) {
	if c.roomCode != "" {
		h.handleDisconnectLocked(c, true)
	}
	code := strings.ToUpper(strings.TrimSpace(msg.Code))
	r, ok := h.rooms[code]
	if !ok {
		c.Send(map[string]any{"t": "ERROR", "msg": "Room not found: " + code})
		return
	}
	if r.Status != "lobby" {
		c.Send(map[string]any{"t": "ERROR", "msg": "Match already in progress! Use RECONNECT if you dropped."})
		return
	}
	if r.Seats[2] != nil && r.Seats[2].Connected {
		c.Send(map[string]any{"t": "ERROR", "msg": "Room is full (2/2)!"})
		return
	}
	if r.Password != "" && msg.Password != r.Password {
		c.Send(map[string]any{"t": "ERROR", "msg": "Incorrect room password!"})
		return
	}

	// Enforce version & core script hash integrity check before allowing join
	flVer := msg.FLVer
	if flVer == "" {
		flVer = c.flVer
	}
	modVer := msg.ModVer
	if modVer == "" {
		modVer = c.modVer
	}
	scriptHash := msg.ScriptHash
	if scriptHash == "" {
		scriptHash = c.scriptHash
	}
	tickLen := msg.TickLen
	if tickLen <= 0 {
		tickLen = c.tickLen
	}

	if r.FLVer != "" && flVer != "" && r.FLVer != flVer {
		c.Send(map[string]any{
			"t":   "ERROR",
			"msg": fmt.Sprintf("FL version mismatch! Room=%s Yours=%s", r.FLVer, flVer),
		})
		return
	}
	if r.ModVer != "" && modVer != "" && r.ModVer != modVer {
		c.Send(map[string]any{
			"t":   "ERROR",
			"msg": fmt.Sprintf("MOD version mismatch! Room=%s Yours=%s", r.ModVer, modVer),
		})
		return
	}
	if r.ScriptHash != "" && scriptHash != "" && r.ScriptHash != scriptHash {
		c.Send(map[string]any{
			"t":   "ERROR",
			"msg": fmt.Sprintf("FL core script hash mismatch! Room=%s Yours=%s (files differ!)", r.ScriptHash, scriptHash),
		})
		return
	}
	if tickLen > 0 && math.Abs(tickLen-r.TickLen) > 1e-4 {
		c.Send(map[string]any{
			"t":   "ERROR",
			"msg": "FPS/TICK_LENGTH mismatch! Launch both clients at 60 FPS.",
		})
		return
	}

	guestName := msg.PlayerName
	if guestName == "" {
		guestName = c.name
	}
	if guestName == "" {
		guestName = "Player 2"
	}
	c.name = guestName

	token := randomToken()
	r.Seats[2] = &Seat{
		Pid:       2,
		Name:      guestName,
		Token:     token,
		Client:    c,
		Connected: true,
		Ready:     true,
	}
	r.UpdatedAt = time.Now()
	c.roomCode = code
	c.pid = 2

	hostName := "Player 1"
	if r.Seats[1] != nil {
		hostName = r.Seats[1].Name
	}

	log.Printf("[ROOM %s] %s joined as P2", code, guestName)

	c.Send(map[string]any{
		"t":              "ROOM_JOINED",
		"code":           code,
		"pid":            2,
		"token":          token,
		"room":           r.RoomJSON,
		"host_name":      hostName,
		"guest_name":     guestName,
		"peer_connected": true,
		"peer_ready":     true,
	})
	if r.Seats[1] != nil && r.Seats[1].Client != nil {
		r.Seats[1].Client.Send(map[string]any{
			"t":          "PEER_JOINED",
			"pid":        2,
			"name":       guestName,
			"room":       r.RoomJSON,
			"peer_ready": true,
		})
	}
}

func (h *Hub) broadcastRoomStateLocked(r *Room) {
	p1Conn := r.Seats[1] != nil && r.Seats[1].Connected
	p2Conn := r.Seats[2] != nil && r.Seats[2].Connected
	p2Ready := p2Conn && r.Seats[2].Ready
	hostName := "Player 1"
	guestName := "Waiting for P2..."
	if r.Seats[1] != nil {
		hostName = r.Seats[1].Name
	}
	if r.Seats[2] != nil && r.Seats[2].Connected {
		guestName = r.Seats[2].Name
	}
	for pid := 1; pid <= 2; pid++ {
		if r.Seats[pid] != nil && r.Seats[pid].Connected && r.Seats[pid].Client != nil {
			otherConn := p2Conn
			otherReady := p2Ready
			if pid == 2 {
				otherConn = p1Conn
				otherReady = p1Conn
			}
			r.Seats[pid].Client.Send(map[string]any{
				"t":              "ROOM_STATE",
				"code":           r.Code,
				"room":           r.RoomJSON,
				"peer_connected": otherConn,
				"peer_ready":     otherReady,
				"host_connected": p1Conn,
				"guest_connected": p2Conn,
				"host_name":      hostName,
				"guest_name":     guestName,
			})
		}
	}
}

func (h *Hub) onUpdateRoomLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid != 1 || r.Status != "lobby" {
		return
	}
	if len(msg.Room) > 0 {
		r.RoomJSON = append(json.RawMessage(nil), msg.Room...)
		r.Meta = parseRoomMeta(r.RoomJSON)
		if r.Meta.Name != "" {
			r.Name = r.Meta.Name
		}
		r.UpdatedAt = time.Now()
		h.broadcastRoomStateLocked(r)
	}
}

func (h *Hub) onSetGuestLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid != 2 || r.Status != "lobby" || r.Seats[2] == nil {
		return
	}
	if msg.Ready != nil {
		r.Seats[2].Ready = *msg.Ready
	}
	if msg.HeroIdx != nil || msg.Reinf != "" || msg.LevelIdx != nil {
		// Patch heroes[1] (P2 hero), reinforcements[1] (P2 reinforcement), and/or level_idx in RoomJSON safely
		var roomMap map[string]any
		if err := json.Unmarshal(r.RoomJSON, &roomMap); err == nil {
			if msg.HeroIdx != nil {
				if heroes, ok := roomMap["heroes"].([]any); ok && len(heroes) >= 2 {
					heroes[1] = *msg.HeroIdx
					roomMap["heroes"] = heroes
				} else {
					h1 := 48
					if len(r.Meta.Heroes) >= 1 {
						h1 = r.Meta.Heroes[0]
					}
					roomMap["heroes"] = []int{h1, *msg.HeroIdx}
				}
			}
			if msg.Reinf != "" {
				reinfVal := sanitizeLabel(msg.Reinf, 40, "default_reinforcement")
				if reinfs, ok := roomMap["reinforcements"].([]any); ok && len(reinfs) >= 2 {
					reinfs[1] = reinfVal
					roomMap["reinforcements"] = reinfs
				} else {
					r1 := "default_reinforcement"
					if reinfs, ok := roomMap["reinforcements"].([]any); ok && len(reinfs) >= 1 {
						if s, ok := reinfs[0].(string); ok && s != "" {
							r1 = s
						}
					}
					roomMap["reinforcements"] = []string{r1, reinfVal}
				}
			}
			if msg.LevelIdx != nil && *msg.LevelIdx >= 1 && *msg.LevelIdx <= 999 {
				roomMap["level_idx"] = *msg.LevelIdx
			}
			if b, err := json.Marshal(roomMap); err == nil {
				r.RoomJSON = b
				r.Meta = parseRoomMeta(r.RoomJSON)
			}
		}
	}
	r.UpdatedAt = time.Now()
	h.broadcastRoomStateLocked(r)
}

