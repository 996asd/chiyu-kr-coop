package main

import (
	"bytes"
	"encoding/json"
	"log"
	"time"
)

func (h *Hub) onStartMatchLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid != 1 {
		c.Send(map[string]any{"t": "ERROR", "msg": "Only host can start the match."})
		return
	}
	if r.Status != "lobby" && r.Status != "running" && r.Status != "loading" {
		c.Send(map[string]any{"t": "ERROR", "msg": "Match cannot start while waiting for reconnect."})
		return
	}
	if r.Seats[2] == nil || !r.Seats[2].Connected {
		c.Send(map[string]any{"t": "ERROR", "msg": "Wait for P2 to join first!"})
		return
	}
	if len(msg.Cfg) == 0 {
		c.Send(map[string]any{"t": "ERROR", "msg": "Missing match cfg."})
		return
	}

	cfgMeta := MatchCfgMeta{TurnTicks: 3, InputDelayTurns: 2}
	_ = json.Unmarshal(msg.Cfg, &cfgMeta)
	if cfgMeta.TurnTicks <= 0 {
		cfgMeta.TurnTicks = 3
	}
	if cfgMeta.InputDelayTurns <= 0 {
		cfgMeta.InputDelayTurns = 2
	}

	// Keep room metadata synced with latest chained stage
	if cfgMeta.LevelIdx >= 1 && cfgMeta.LevelIdx <= 999 {
		var roomMap map[string]any
		if err := json.Unmarshal(r.RoomJSON, &roomMap); err == nil {
			roomMap["level_idx"] = cfgMeta.LevelIdx
			if b, err := json.Marshal(roomMap); err == nil {
				r.RoomJSON = b
				r.Meta = parseRoomMeta(r.RoomJSON)
			}
		}
	}

	r.MatchID = cfgMeta.MatchID
	r.MatchCfgRaw = append(json.RawMessage(nil), msg.Cfg...)
	r.TurnTicks = cfgMeta.TurnTicks
	r.InputDelayTurns = cfgMeta.InputDelayTurns
	r.Turns = make(map[int]*TurnBucket, 512)
	emptyArr := json.RawMessage("[]")
	for t := 0; t < r.InputDelayTurns; t++ {
		r.Turns[t] = &TurnBucket{
			Cmds: [3]json.RawMessage{nil, emptyArr, emptyArr},
		}
	}
	r.HighestCompleteTurn = r.InputDelayTurns - 1
	r.Paused = false
	r.GameSpeed = 1
	r.Status = "loading"
	r.UpdatedAt = time.Now()

	for pid := 1; pid <= 2; pid++ {
		r.Seats[pid].Loaded = false
		r.Seats[pid].CatchingUp = false
		r.Seats[pid].LastSentTurn = r.InputDelayTurns - 1
	}

	log.Printf("[ROOM %s] START_MATCH level=%d seed=%d turn_ticks=%d delay=%d",
		r.Code, cfgMeta.LevelIdx, cfgMeta.Seed, r.TurnTicks, r.InputDelayTurns)

	pkt := map[string]any{
		"t":               "START_MATCH",
		"code":            r.Code,
		"cfg":             r.MatchCfgRaw,
		"reconnect_grace": int(h.reconnectGrace.Seconds()),
	}
	for pid := 1; pid <= 2; pid++ {
		if r.Seats[pid].Client != nil {
			r.Seats[pid].Client.Send(pkt)
		}
	}
}

func (h *Hub) onLoadDoneLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid < 1 || c.pid > 2 || r.Seats[c.pid] == nil {
		return
	}
	if msg.MatchID != "" && r.MatchID != "" && msg.MatchID != r.MatchID {
		return
	}
	r.Seats[c.pid].Loaded = true
	log.Printf("[ROOM %s] P%d LOAD_DONE", r.Code, c.pid)

	if r.Status == "loading" && r.Seats[1] != nil && r.Seats[2] != nil && r.Seats[1].Loaded && r.Seats[2].Loaded {
		r.Status = "running"
		r.UpdatedAt = time.Now()
		log.Printf("[ROOM %s] Both loaded -> broadcasting BEGIN_SIM!", r.Code)
		pkt := map[string]any{"t": "BEGIN_SIM"}
		if r.MatchID != "" {
			pkt["match_id"] = r.MatchID
		}
		for pid := 1; pid <= 2; pid++ {
			if r.Seats[pid].Connected && r.Seats[pid].Client != nil {
				r.Seats[pid].Client.Send(pkt)
			}
		}
	}
}

func (h *Hub) onTurnLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid < 1 || c.pid > 2 || msg.Turn == nil {
		return
	}
	if r.Status == "loading" || r.Turns == nil {
		return
	}

	turnID := *msg.Turn
	pid := c.pid
	rawCmds := msg.Cmds
	if len(bytes.TrimSpace(rawCmds)) == 0 {
		rawCmds = json.RawMessage("[]")
	}

	bucket, exists := r.Turns[turnID]
	if !exists {
		bucket = &TurnBucket{}
		r.Turns[turnID] = bucket
	}
	// Preserve first canonical turn submission for determinism
	if bucket.Cmds[pid] == nil {
		bucket.Cmds[pid] = append(json.RawMessage(nil), rawCmds...)
		// Check if SYNC_PAUSE occurred inside cmds to track room paused hint
		if bytes.Contains(rawCmds, []byte(`"SYNC_PAUSE"`)) {
			r.Paused = true
		}
	}
	if turnID > r.Seats[pid].LastSentTurn {
		r.Seats[pid].LastSentTurn = turnID
	}

	// Advance HighestCompleteTurn contiguously while both P1 & P2 exist
	for {
		next := r.HighestCompleteTurn + 1
		b, ok := r.Turns[next]
		if ok && b.Cmds[1] != nil && b.Cmds[2] != nil {
			r.HighestCompleteTurn = next
		} else {
			break
		}
	}

	// Immediately relay to the other peer if connected (and not still waiting for RECONNECT_STATE)
	otherPid := 3 - pid
	other := r.Seats[otherPid]
	if other != nil && other.Connected && other.Client != nil {
		relay := map[string]any{
			"t":    "TURN",
			"turn": turnID,
			"pid":  pid,
			"cmds": bucket.Cmds[pid],
		}
		if msg.HT != nil && msg.HH != "" {
			relay["ht"] = *msg.HT
			relay["hh"] = msg.HH
			if msg.HS != "" {
				relay["hs"] = msg.HS
			}
		}
		other.Client.Send(relay)
	}
}

func (h *Hub) onSyncResumeLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid < 1 || c.pid > 2 {
		return
	}
	r.Paused = false
	other := r.Seats[3-c.pid]
	if other != nil && other.Connected && other.Client != nil {
		other.Client.Send(map[string]any{
			"t":   "SYNC_RESUME",
			"pid": c.pid,
		})
	}
}

func (h *Hub) onSyncSpeedLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid < 1 || c.pid > 2 {
		return
	}
	spd := msg.Speed
	if spd != 1 && spd != 2 {
		spd = 1
	}
	r.GameSpeed = spd
	pkt := map[string]any{
		"t":     "SYNC_SPEED",
		"pid":   c.pid,
		"speed": spd,
	}
	for pid := 1; pid <= 2; pid++ {
		if r.Seats[pid] != nil && r.Seats[pid].Connected && r.Seats[pid].Client != nil {
			r.Seats[pid].Client.Send(pkt)
		}
	}
}


func (h *Hub) onMatchFlowLocked(c *Client, msg *IncomingMsg) {
	if c.roomCode == "" || c.pid < 1 || c.pid > 2 {
		return
	}
	if msg.Action != "next" && msg.Action != "restart" && msg.Action != "cancel_auto" {
		return
	}
	r, ok := h.rooms[c.roomCode]
	if !ok {
		return
	}
	other := r.Seats[3-c.pid]
	if other == nil || !other.Connected || other.Client == nil {
		return
	}
	pkt := map[string]any{
		"t":      "MATCH_FLOW",
		"pid":    c.pid,
		"action": msg.Action,
	}
	if msg.LevelIdx != nil && *msg.LevelIdx >= 1 && *msg.LevelIdx <= 999 {
		pkt["level_idx"] = *msg.LevelIdx
	}
	other.Client.Send(pkt)
}

func (h *Hub) onVoiceLocked(c *Client, msg *IncomingMsg) {
	if c.roomCode == "" || c.pid < 1 || c.pid > 2 {
		return
	}
	if len(msg.VoiceData) == 0 || len(msg.VoiceData) > 2048 {
		return
	}
	r, ok := h.rooms[c.roomCode]
	if !ok {
		return
	}
	other := r.Seats[3-c.pid]
	if other == nil || !other.Connected || other.Client == nil {
		return
	}
	other.Client.SendDropIfBusy(map[string]any{
		"t":   "VOICE",
		"pid": c.pid,
		"d":   msg.VoiceData,
		"l":   msg.VoiceLevel,
	})
}

func (h *Hub) onDesyncDiagLocked(c *Client, msg *IncomingMsg) {
	if c.roomCode == "" || c.pid < 1 || c.pid > 2 {
		return
	}
	r, ok := h.rooms[c.roomCode]
	if !ok {
		return
	}
	other := r.Seats[3-c.pid]
	if other == nil || !other.Connected || other.Client == nil {
		return
	}
	other.Client.Send(map[string]any{
		"t":    "DESYNC_DIAG",
		"pid":  c.pid,
		"tick": msg.Tick,
		"hash": msg.Hash,
		"snap": msg.Snap,
		"ents": msg.Ents,
	})
}

