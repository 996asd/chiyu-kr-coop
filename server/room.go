package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"math/big"
	"sort"
	"strings"
	"sync"
	"time"
)

const roomCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

type Seat struct {
	Pid          int
	Name         string
	Token        string
	Client       *Client
	Connected    bool
	Ready        bool
	Loaded       bool
	CatchingUp   bool
	LastSentTurn int
	Disconnected time.Time
}

type TurnBucket struct {
	Cmds [3]json.RawMessage // index 1 = P1, index 2 = P2
}

type Room struct {
	Code       string
	Name       string
	Password   string
	Public     bool
	Status     string // "lobby" | "loading" | "running" | "waiting_reconnect"
	CreatedAt  time.Time
	UpdatedAt  time.Time

	// Version & determinism lock
	ModVer     string
	FLVer      string
	ScriptHash string
	TickLen    float64

	// Lobby room settings (raw JSON + parsed summary)
	RoomJSON json.RawMessage
	Meta     RoomMeta

	// Seats: index 1 = P1 (Host), index 2 = P2 (Guest)
	Seats [3]*Seat

	// Active match lockstep cache for fast-forward reconnect
	MatchCfgRaw         json.RawMessage
	TurnTicks           int
	InputDelayTurns     int
	Turns               map[int]*TurnBucket
	HighestCompleteTurn int
	Paused              bool
	GameSpeed           int
}

type Hub struct {
	mu             sync.Mutex
	rooms          map[string]*Room
	clients        map[*Client]bool
	nextClientID   int64
	maxRooms       int
	reconnectGrace time.Duration
	startedAt      time.Time
}

func NewHub(maxRooms int, reconnectGrace time.Duration) *Hub {
	return &Hub{
		rooms:          make(map[string]*Room),
		clients:        make(map[*Client]bool),
		maxRooms:       maxRooms,
		reconnectGrace: reconnectGrace,
		startedAt:      time.Now(),
	}
}

func randomCode(length int) string {
	b := make([]byte, length)
	max := big.NewInt(int64(len(roomCodeAlphabet)))
	for i := 0; i < length; i++ {
		n, err := rand.Int(rand.Reader, max)
		if err != nil {
			b[i] = roomCodeAlphabet[i%len(roomCodeAlphabet)]
		} else {
			b[i] = roomCodeAlphabet[n.Int64()]
		}
	}
	return string(b)
}

func randomToken() string {
	buf := make([]byte, 12)
	_, _ = rand.Read(buf)
	return hex.EncodeToString(buf)
}

func (h *Hub) RegisterClient(c *Client) int64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.nextClientID++
	c.id = h.nextClientID
	h.clients[c] = true
	return c.id
}

func (h *Hub) UnregisterClient(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, c)
	if c.roomCode != "" {
		h.handleDisconnectLocked(c, false)
	}
}

func (h *Hub) Stats() map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	activeMatches := 0
	for _, r := range h.rooms {
		if r.Status != "lobby" {
			activeMatches++
		}
	}
	return map[string]any{
		"server_ver":     ServerVersion,
		"proto":          ProtocolVer,
		"uptime_sec":     int(time.Since(h.startedAt).Seconds()),
		"clients":        len(h.clients),
		"rooms":          len(h.rooms),
		"active_matches": activeMatches,
	}
}

func (h *Hub) RunJanitor(stop <-chan struct{}) {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			h.cleanupExpiredRooms()
		}
	}
}

func (h *Hub) cleanupExpiredRooms() {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := time.Now()
	for code, r := range h.rooms {
		p1Conn := r.Seats[1] != nil && r.Seats[1].Connected
		p2Conn := r.Seats[2] != nil && r.Seats[2].Connected

		if r.Status == "lobby" {
			if !p1Conn && !p2Conn && now.Sub(r.UpdatedAt) > 10*time.Second {
				delete(h.rooms, code)
				log.Printf("[HUB] Cleaned empty lobby room %s", code)
			}
			continue
		}

		// In active match / waiting_reconnect: expire if any seat exceeded grace window or both gone too long
		expired := false
		for pid := 1; pid <= 2; pid++ {
			s := r.Seats[pid]
			if s != nil && !s.Connected && !s.Disconnected.IsZero() && now.Sub(s.Disconnected) > h.reconnectGrace {
				expired = true
			}
		}
		if expired {
			log.Printf("[HUB] Room %s reconnect grace expired; closing room", code)
			for pid := 1; pid <= 2; pid++ {
				if r.Seats[pid] != nil && r.Seats[pid].Client != nil {
					r.Seats[pid].Client.Send(map[string]any{
						"t":      "ROOM_CLOSED",
						"reason": "Reconnect window expired",
					})
					r.Seats[pid].Client.roomCode = ""
					r.Seats[pid].Client.pid = 0
				}
			}
			delete(h.rooms, code)
		}
	}
}

func (h *Hub) buildRoomListLocked() []RoomSummary {
	list := make([]RoomSummary, 0, len(h.rooms))
	for _, r := range h.rooms {
		if !r.Public || r.Status != "lobby" {
			continue
		}
		players := 0
		hostName := "Host"
		if r.Seats[1] != nil && r.Seats[1].Connected {
			players++
			hostName = r.Seats[1].Name
		}
		if r.Seats[2] != nil && r.Seats[2].Connected {
			players++
		}
		if players == 0 {
			continue
		}
		name := r.Name
		if name == "" {
			name = r.Meta.Name
		}
		if name == "" {
			name = "KR-MP Room " + r.Code
		}
		list = append(list, RoomSummary{
			Code:            r.Code,
			Name:            name,
			HostName:        hostName,
			LevelIdx:        r.Meta.LevelIdx,
			LevelDifficulty: r.Meta.LevelDifficulty,
			EconMode:        r.Meta.EconMode,
			TowerMode:       r.Meta.TowerMode,
			Players:         players,
			MaxPlayers:      2,
			HasPassword:     r.Password != "",
			Status:          r.Status,
			FLVer:           r.FLVer,
			ModVer:          r.ModVer,
			ScriptHash:      r.ScriptHash,
		})
	}
	sort.Slice(list, func(i, j int) bool {
		return list[i].Code < list[j].Code
	})
	return list
}

func (h *Hub) HandleMessage(c *Client, msg *IncomingMsg) {
	// PING/PONG doesn't even need the Hub lock!
	if msg.Type == "PING" {
		c.Send(map[string]any{"t": "PONG", "ts": msg.Ts})
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
	default:
		c.Send(map[string]any{"t": "ERROR", "msg": "Unknown message type: " + msg.Type})
	}
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
		c.name = msg.Name
	} else if msg.PlayerName != "" {
		c.name = msg.PlayerName
	} else if c.name == "" {
		c.name = fmt.Sprintf("Player-%d", c.id)
	}

	c.Send(map[string]any{
		"t":          "SERVER_HELLO",
		"server_ver": ServerVersion,
		"proto":      ProtocolVer,
		"voice_ok":   true,
		"client_id":  c.id,
		"rooms":      h.buildRoomListLocked(),
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
	if c.roomCode != "" {
		h.handleDisconnectLocked(c, true)
	}
	if len(h.rooms) >= h.maxRooms {
		c.Send(map[string]any{"t": "ERROR", "msg": "Server room limit reached; try again shortly."})
		return
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
	if hostName == "" {
		hostName = "Player 1"
	}
	c.name = hostName

	public := true
	if msg.Public != nil {
		public = *msg.Public
	}

	meta := parseRoomMeta(msg.Room)
	roomName := strings.TrimSpace(msg.Name)
	if roomName == "" {
		roomName = meta.Name
	}
	if roomName == "" {
		roomName = "KR-MP Co-op"
	}

	roomJSON := msg.Room
	if len(roomJSON) == 0 {
		roomJSON, _ = json.Marshal(meta)
	}

	code := h.generateUniqueCodeLocked()
	token := randomToken()
	now := time.Now()

	r := &Room{
		Code:       code,
		Name:       roomName,
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
	peerConn := r.Seats[2] != nil && r.Seats[2].Connected
	peerReady := r.Seats[2] != nil && r.Seats[2].Ready
	hostName := "Player 1"
	guestName := "Waiting for P2..."
	if r.Seats[1] != nil {
		hostName = r.Seats[1].Name
	}
	if r.Seats[2] != nil && r.Seats[2].Connected {
		guestName = r.Seats[2].Name
	}
	pkt := map[string]any{
		"t":              "ROOM_STATE",
		"code":           r.Code,
		"room":           r.RoomJSON,
		"peer_connected": peerConn,
		"peer_ready":     peerReady,
		"host_name":      hostName,
		"guest_name":     guestName,
	}
	for pid := 1; pid <= 2; pid++ {
		if r.Seats[pid] != nil && r.Seats[pid].Connected && r.Seats[pid].Client != nil {
			r.Seats[pid].Client.Send(pkt)
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
	if msg.HeroIdx != nil {
		// Patch heroes[1] (second element = P2 hero) in RoomJSON safely
		var roomMap map[string]any
		if err := json.Unmarshal(r.RoomJSON, &roomMap); err == nil {
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
			if b, err := json.Marshal(roomMap); err == nil {
				r.RoomJSON = b
				r.Meta = parseRoomMeta(r.RoomJSON)
			}
		}
	}
	r.UpdatedAt = time.Now()
	h.broadcastRoomStateLocked(r)
}

func (h *Hub) onStartMatchLocked(c *Client, msg *IncomingMsg) {
	r, ok := h.rooms[c.roomCode]
	if !ok || c.pid != 1 {
		c.Send(map[string]any{"t": "ERROR", "msg": "Only host can start the match."})
		return
	}
	if r.Status != "lobby" {
		c.Send(map[string]any{"t": "ERROR", "msg": "Match already started."})
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
	r.Seats[c.pid].Loaded = true
	log.Printf("[ROOM %s] P%d LOAD_DONE", r.Code, c.pid)

	if r.Status == "loading" && r.Seats[1] != nil && r.Seats[2] != nil && r.Seats[1].Loaded && r.Seats[2].Loaded {
		r.Status = "running"
		r.UpdatedAt = time.Now()
		log.Printf("[ROOM %s] Both loaded -> broadcasting BEGIN_SIM!", r.Code)
		pkt := map[string]any{"t": "BEGIN_SIM"}
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
	if r.Turns == nil {
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

	// Case 1: In lobby OR explicit LEAVE_ROOM -> clean teardown (no reconnect window)
	if r.Status == "lobby" || explicitLeave {
		if pid == 1 || explicitLeave {
			log.Printf("[ROOM %s] P%d left (status=%s explicit=%v) -> closing room", code, pid, r.Status, explicitLeave)
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
			// Guest left while in lobby -> keep Host room open
			log.Printf("[ROOM %s] P2 left lobby; keeping room open for Host", code)
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

	// Case 2: Unexpected mid-match TCP drop -> hold match in waiting_reconnect for fast-forward catch-up!
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
	if len(r.MatchCfgRaw) == 0 {
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
	seat.CatchingUp = true
	seat.Loaded = true
	seat.Disconnected = time.Time{}
	c.roomCode = code
	c.pid = pid
	r.UpdatedAt = time.Now()

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
