package main

import (
	"fmt"
	"log"
	"sort"
	"strings"
	"time"
)

func (h *Hub) handleDisconnectLocked(c *Client, explicitLeave bool) {
	code := c.roomCode
	pid := c.pid
	c.roomCode = ""
	c.pid = 0

	r, ok := h.rooms[code]
	if !ok || pid < 1 || pid > 2 {
		return
	}
	seat := r.Seats[pid]
	if seat == nil || seat.Client != c {
		return
	}

	seat.Client = nil
	seat.Connected = false
	seat.Disconnected = time.Now()
	r.UpdatedAt = time.Now()

	otherPid := 3 - pid
	other := r.Seats[otherPid]

	// Case 1: Explicit LEAVE_ROOM -> immediate clean teardown (no reconnect window)
	if explicitLeave {
		if pid == 1 || r.Status != "lobby" {
			log.Printf("[ROOM %s] P%d left (status=%s explicit=true) -> closing room", code, pid, r.Status)
			if other != nil && other.Connected && other.Client != nil {
				other.Client.Send(map[string]any{
					"t":      "ROOM_CLOSED",
					"reason": fmt.Sprintf("P%d left the room.", pid),
				})
				other.Client.roomCode = ""
				other.Client.pid = 0
			}
			delete(h.rooms, code)
		} else {
			// Guest explicitly left lobby -> keep Host room open
			log.Printf("[ROOM %s] P2 explicitly left lobby; keeping room open for Host", code)
			r.Seats[2] = nil
			if other != nil && other.Connected && other.Client != nil {
				other.Client.Send(map[string]any{
					"t":   "PEER_LEFT",
					"pid": 2,
				})
				h.broadcastRoomStateLocked(r)
			}
		}
		return
	}

	// Case 2: Unexpected TCP drop while in lobby (e.g. SakuraFrp blip or post-match stall)
	// Hold the seat for lobbyReconnectGrace (30s) so the client can seamlessly auto-rejoin via RECONNECT.
	if r.Status == "lobby" {
		lobbyGrace := h.lobbyReconnectGrace
		if lobbyGrace <= 0 {
			lobbyGrace = defaultLobbyReconnectGrace
		}
		log.Printf("[ROOM %s] P%d TCP dropped in lobby; holding seat for %v", code, pid, lobbyGrace)
		h.broadcastRoomStateLocked(r)
		return
	}

	// Case 3: Unexpected mid-match TCP drop -> hold match in waiting_reconnect for fast-forward catch-up!
	r.Status = "waiting_reconnect"
	log.Printf("[ROOM %s] P%d dropped mid-match (highestCompleteTurn=%d); holding seat for %v",
		code, pid, r.HighestCompleteTurn, h.reconnectGrace)

	if other != nil && other.Connected && other.Client != nil {
		other.Client.Send(map[string]any{
			"t":             "PEER_DISCONNECTED",
			"pid":           pid,
			"can_reconnect": true,
			"timeout":       int(h.reconnectGrace.Seconds()),
		})
	}
}

func (h *Hub) onReconnectLocked(c *Client, msg *IncomingMsg) {
	if c.roomCode != "" {
		h.handleDisconnectLocked(c, true)
	}

	code := strings.ToUpper(strings.TrimSpace(msg.Code))
	r, ok := h.rooms[code]
	if !ok {
		c.Send(map[string]any{"t": "ERROR", "msg": "Reconnect failed: room " + code + " not found or expired."})
		return
	}
	isLobbyReconnect := (r.Status == "lobby" && len(r.MatchCfgRaw) == 0)
	if !isLobbyReconnect && len(r.MatchCfgRaw) == 0 {
		c.Send(map[string]any{"t": "ERROR", "msg": "Reconnect failed: match has not started."})
		return
	}
	pid := msg.Pid
	if pid != 1 && pid != 2 {
		c.Send(map[string]any{"t": "ERROR", "msg": "Reconnect failed: invalid player slot."})
		return
	}
	seat := r.Seats[pid]
	if seat == nil {
		c.Send(map[string]any{"t": "ERROR", "msg": "Reconnect failed: player seat empty."})
		return
	}
	if seat.Token != "" && msg.Token != seat.Token {
		c.Send(map[string]any{"t": "ERROR", "msg": "Reconnect failed: invalid session token."})
		return
	}

	// Version/script check
	if r.ScriptHash != "" && msg.ScriptHash != "" && r.ScriptHash != msg.ScriptHash {
		c.Send(map[string]any{"t": "ERROR", "msg": "Reconnect failed: FL script hash mismatch."})
		return
	}

	// If old zombie socket still attached, detach it cleanly
	if seat.Client != nil && seat.Client != c {
		seat.Client.roomCode = ""
		seat.Client.pid = 0
		seat.Client.Close()
	}

	seat.Client = c
	seat.Connected = true
	seat.Disconnected = time.Time{}
	c.roomCode = code
	c.pid = pid
	r.UpdatedAt = time.Now()

	if isLobbyReconnect {
		seat.CatchingUp = false
		seat.Loaded = false
		p1Conn := r.Seats[1] != nil && r.Seats[1].Connected
		p2Conn := r.Seats[2] != nil && r.Seats[2].Connected
		otherConn := p2Conn
		otherReady := p2Conn && r.Seats[2].Ready
		if pid == 2 {
			otherConn = p1Conn
			otherReady = p1Conn
		}
		hostName := "Player 1"
		guestName := "Waiting for P2..."
		if r.Seats[1] != nil {
			hostName = r.Seats[1].Name
		}
		if r.Seats[2] != nil && r.Seats[2].Connected {
			guestName = r.Seats[2].Name
		}
		log.Printf("[ROOM %s] P%d lobby RECONNECT accepted! peer_connected=%v", code, pid, otherConn)
		c.Send(map[string]any{
			"t":              "ROOM_REJOINED",
			"code":           code,
			"pid":            pid,
			"token":          seat.Token,
			"room":           r.RoomJSON,
			"host_name":      hostName,
			"guest_name":     guestName,
			"peer_connected": otherConn,
			"peer_ready":     otherReady,
		})
		h.broadcastRoomStateLocked(r)
		return
	}

	seat.CatchingUp = true
	seat.Loaded = true

	targetTurn := r.HighestCompleteTurn

	// Compact turn history: only transmit turns 0..targetTurn where at least one player had commands.
	// All omitted turns in [0..targetTurn] are deterministically empty ({}, {}).
	history := make([]HistoryTurn, 0, 128)
	for t := 0; t <= targetTurn; t++ {
		b := r.Turns[t]
		if b == nil {
			continue
		}
		e1 := isEmptyJSONArray(b.Cmds[1])
		e2 := isEmptyJSONArray(b.Cmds[2])
		if e1 && e2 {
			continue
		}
		ht := HistoryTurn{Turn: t}
		if !e1 {
			ht.C1 = b.Cmds[1]
		}
		if !e2 {
			ht.C2 = b.Cmds[2]
		}
		history = append(history, ht)
	}

	// Collect any turns > targetTurn already sent by either peer so nothing in flight is lost
	extraKeys := make([]int, 0, 8)
	for t := range r.Turns {
		if t > targetTurn {
			extraKeys = append(extraKeys, t)
		}
	}
	sort.Ints(extraKeys)
	extra := make([]ExtraTurn, 0, len(extraKeys)*2)
	for _, t := range extraKeys {
		b := r.Turns[t]
		for p := 1; p <= 2; p++ {
			if b.Cmds[p] != nil {
				extra = append(extra, ExtraTurn{
					Turn: t,
					Pid:  p,
					Cmds: b.Cmds[p],
				})
			}
		}
	}

	myNextSendTurn := seat.LastSentTurn + 1
	if myNextSendTurn < r.InputDelayTurns {
		myNextSendTurn = r.InputDelayTurns
	}

	log.Printf("[ROOM %s] P%d RECONNECT accepted! target_turn=%d non_empty_turns=%d extra=%d my_next_send=%d",
		code, pid, targetTurn, len(history), len(extra), myNextSendTurn)

	c.Send(map[string]any{
		"t":                 "RECONNECT_STATE",
		"code":              code,
		"pid":               pid,
		"token":             seat.Token,
		"cfg":               r.MatchCfgRaw,
		"target_turn":       targetTurn,
		"turns":             history,
		"extra_turns":       extra,
		"my_next_send_turn": myNextSendTurn,
		"game_speed":        r.GameSpeed,
		"paused":            r.Paused,
	})

	// Inform teammate that reconnection & fast-forward is in progress
	other := r.Seats[3-pid]
	if other != nil && other.Connected && other.Client != nil {
		other.Client.Send(map[string]any{
			"t":           "PEER_RECONNECTING",
			"pid":         pid,
			"target_turn": targetTurn,
		})
	}
}

func (h *Hub) onReconnectDoneLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid < 1 || c.pid > 2 || r.Seats[c.pid] == nil {
		return
	}
	r.Seats[c.pid].CatchingUp = false
	log.Printf("[ROOM %s] P%d RECONNECT_DONE at tick=%d hash=%s", r.Code, c.pid, msg.Tick, msg.Hash)

	bothReady := r.Seats[1] != nil && r.Seats[2] != nil &&
		r.Seats[1].Connected && r.Seats[2].Connected &&
		r.Seats[1].Loaded && r.Seats[2].Loaded &&
		!r.Seats[1].CatchingUp && !r.Seats[2].CatchingUp

	if bothReady {
		r.Status = "running"
		r.UpdatedAt = time.Now()
		log.Printf("[ROOM %s] Both peers synced after reconnect -> resuming live 60Hz lockstep!", r.Code)
		pkt := map[string]any{
			"t":          "PEER_RECONNECTED",
			"pid":        c.pid,
			"paused":     r.Paused,
			"game_speed": r.GameSpeed,
		}
		for pid := 1; pid <= 2; pid++ {
			if r.Seats[pid].Client != nil {
				r.Seats[pid].Client.Send(pkt)
			}
		}
	}
}
