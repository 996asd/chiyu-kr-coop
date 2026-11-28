package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"math/big"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	roomCodeAlphabet           = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
	defaultLobbyReconnectGrace = 30 * time.Second
)

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
	HostIP     string
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
	MatchID             string
	MatchCfgRaw         json.RawMessage
	TurnTicks           int
	InputDelayTurns     int
	Turns               map[int]*TurnBucket
	HighestCompleteTurn int
	Paused              bool
	GameSpeed           int
}

type Hub struct {
	mu                  sync.Mutex
	rooms               map[string]*Room
	clients             map[*Client]bool
	ipConns             map[string]int
	nextClientID        int64
	maxRooms            int
	maxConns            int
	maxPerIP            int
	maxRoomsPerIP       int
	reconnectGrace      time.Duration
	lobbyReconnectGrace time.Duration
	startedAt           time.Time
	reports             *ReportStore
}

func NewHub(maxRooms int, reconnectGrace time.Duration) *Hub {
	return NewHubWithLimits(maxRooms, 500, 16, 4, reconnectGrace)
}

func NewHubWithLimits(maxRooms, maxConns, maxPerIP, maxRoomsPerIP int, reconnectGrace time.Duration) *Hub {
	if maxRooms <= 0 {
		maxRooms = 200
	}
	if maxConns <= 0 {
		maxConns = 500
	}
	if maxPerIP <= 0 {
		maxPerIP = 16
	}
	if maxRoomsPerIP <= 0 {
		maxRoomsPerIP = 4
	}
	return &Hub{
		rooms:               make(map[string]*Room),
		clients:             make(map[*Client]bool),
		ipConns:             make(map[string]int),
		maxRooms:            maxRooms,
		maxConns:            maxConns,
		maxPerIP:            maxPerIP,
		maxRoomsPerIP:       maxRoomsPerIP,
		reconnectGrace:      reconnectGrace,
		lobbyReconnectGrace: defaultLobbyReconnectGrace,
		startedAt:           time.Now(),
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

func sanitizeLabel(s string, maxRunes int, fallback string) string {
	var b strings.Builder
	count := 0
	for _, r := range strings.TrimSpace(s) {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if count >= maxRunes {
			break
		}
		b.WriteRune(r)
		count++
	}
	out := strings.TrimSpace(b.String())
	if out == "" {
		return fallback
	}
	return out
}

func (h *Hub) TryRegisterClient(c *Client) (int64, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.clients) >= h.maxConns {
		return 0, "global connection limit reached"
	}
	if c.remoteIP != "" && !isLoopbackIP(c.remoteIP) {
		if h.ipConns[c.remoteIP] >= h.maxPerIP {
			return 0, "per-IP connection limit reached"
		}
		h.ipConns[c.remoteIP]++
	}
	h.nextClientID++
	c.id = h.nextClientID
	h.clients[c] = true
	return c.id, ""
}

func (h *Hub) RegisterClient(c *Client) int64 {
	id, _ := h.TryRegisterClient(c)
	return id
}

func (h *Hub) UnregisterClient(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.clients[c] {
		delete(h.clients, c)
		if c.remoteIP != "" && !isLoopbackIP(c.remoteIP) {
			if h.ipConns[c.remoteIP] > 1 {
				h.ipConns[c.remoteIP]--
			} else {
				delete(h.ipConns, c.remoteIP)
			}
		}
	}
	if c.roomCode != "" {
		h.handleDisconnectLocked(c, false)
	}
}

func (h *Hub) SetReportStore(store *ReportStore) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.reports = store
}

func (h *Hub) ReportsEnabled() bool {
	return h.reports != nil && h.reports.Enabled()
}

func (h *Hub) Stats() map[string]any {
	h.mu.Lock()
	activeMatches := 0
	for _, r := range h.rooms {
		if r.Status != "lobby" {
			activeMatches++
		}
	}
	stats := map[string]any{
		"server_ver":      ServerVersion,
		"proto":           ProtocolVer,
		"uptime_sec":      int(time.Since(h.startedAt).Seconds()),
		"clients":         len(h.clients),
		"rooms":           len(h.rooms),
		"active_matches":  activeMatches,
		"reports_enabled": h.ReportsEnabled(),
	}
	rs := h.reports
	h.mu.Unlock()
	if rs != nil && rs.Enabled() {
		stats["reports_count"] = rs.Count()
	}
	return stats
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
			lobbyGrace := h.lobbyReconnectGrace
			if lobbyGrace <= 0 {
				lobbyGrace = defaultLobbyReconnectGrace
			}
			if !p1Conn && !p2Conn && now.Sub(r.UpdatedAt) > lobbyGrace {
				delete(h.rooms, code)
				log.Printf("[HUB] Cleaned empty lobby room %s", code)
				continue
			}
			if !p1Conn && r.Seats[1] != nil && !r.Seats[1].Disconnected.IsZero() && now.Sub(r.Seats[1].Disconnected) > lobbyGrace {
				log.Printf("[HUB] Lobby room %s host reconnect grace expired; closing room", code)
				if r.Seats[2] != nil && r.Seats[2].Connected && r.Seats[2].Client != nil {
					r.Seats[2].Client.Send(map[string]any{
						"t":      "ROOM_CLOSED",
						"reason": "Host disconnected",
					})
					r.Seats[2].Client.roomCode = ""
					r.Seats[2].Client.pid = 0
				}
				delete(h.rooms, code)
				continue
			}
			if !p2Conn && r.Seats[2] != nil && !r.Seats[2].Disconnected.IsZero() && now.Sub(r.Seats[2].Disconnected) > lobbyGrace {
				log.Printf("[HUB] Lobby room %s P2 reconnect grace expired; releasing P2 seat", code)
				r.Seats[2] = nil
				if r.Seats[1] != nil && r.Seats[1].Connected && r.Seats[1].Client != nil {
					r.Seats[1].Client.Send(map[string]any{
						"t":   "PEER_LEFT",
						"pid": 2,
					})
					h.broadcastRoomStateLocked(r)
				}
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

