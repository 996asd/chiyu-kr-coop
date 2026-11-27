package main

import (
	"bytes"
	"encoding/json"
)

const (
	ServerVersion = "2.3.1"
	ProtocolVer   = 3
)

// IncomingMsg is the flexible envelope decoded from newline-delimited JSON TCP frames.
// Complex Lua-originated fields (Room, Cfg, Cmds) are preserved verbatim as json.RawMessage
// so numeric keys, floats, and slot snapshots remain bit-for-bit untouched across relays.
type IncomingMsg struct {
	Type string `json:"t"`

	// Handshake / Keepalive
	Ts         float64 `json:"ts,omitempty"`
	Proto      int     `json:"proto,omitempty"`
	ModVer     string  `json:"mod_ver,omitempty"`
	FLVer      string  `json:"fl_ver,omitempty"`
	ScriptHash string  `json:"script_hash,omitempty"`
	TickLen    float64 `json:"tick_len,omitempty"`
	Name       string  `json:"name,omitempty"`
	PlayerName string  `json:"player_name,omitempty"`

	// Room creation / join / reconnect
	Code     string          `json:"code,omitempty"`
	Password string          `json:"password,omitempty"`
	Public   *bool           `json:"public,omitempty"`
	Token    string          `json:"token,omitempty"`
	Room     json.RawMessage `json:"room,omitempty"`

	// Guest settings
	Ready   *bool `json:"ready,omitempty"`
	HeroIdx *int  `json:"hero_idx,omitempty"`

	// Match lifecycle & lockstep turns
	Cfg   json.RawMessage `json:"cfg,omitempty"`
	Pid   int             `json:"pid,omitempty"`
	Turn  *int            `json:"turn,omitempty"`
	Cmds  json.RawMessage `json:"cmds,omitempty"`
	HT    *int            `json:"ht,omitempty"`
	HH    string          `json:"hh,omitempty"`
	HS    string          `json:"hs,omitempty"`
	Tick  int             `json:"tick,omitempty"`
	Hash  string          `json:"hash,omitempty"`
	Snap  string          `json:"snap,omitempty"`
	Ents  string          `json:"ents,omitempty"`
	Speed int             `json:"speed,omitempty"`

	// Ephemeral live voice chat frame (never stored in turn history)
	VoiceData  string `json:"d,omitempty"`
	VoiceLevel int    `json:"l,omitempty"`
}

// RoomMeta extracts searchable summary fields from Room JSON for the public lobby list.
type RoomMeta struct {
	Name            string `json:"name"`
	LevelIdx        int    `json:"level_idx"`
	LevelMode       int    `json:"level_mode"`
	LevelDifficulty int    `json:"level_difficulty"`
	EconMode        string `json:"econ_mode"`
	TowerMode       string `json:"tower_mode"`
	Heroes          []int  `json:"heroes"`
}

// MatchCfgMeta extracts turn timing parameters from START_MATCH cfg without modifying raw JSON.
type MatchCfgMeta struct {
	TurnTicks       int `json:"turn_ticks"`
	InputDelayTurns int `json:"input_delay_turns"`
	LevelIdx        int `json:"level_idx"`
	Seed            int `json:"seed"`
}

// RoomSummary is sent in ROOM_LIST for public room browsing.
type RoomSummary struct {
	Code            string `json:"code"`
	Name            string `json:"name"`
	HostName        string `json:"host_name"`
	LevelIdx        int    `json:"level_idx"`
	LevelDifficulty int    `json:"level_difficulty"`
	EconMode        string `json:"econ_mode"`
	TowerMode       string `json:"tower_mode"`
	Players         int    `json:"players"`
	MaxPlayers      int    `json:"max_players"`
	HasPassword     bool   `json:"has_password"`
	Status          string `json:"status"`
	FLVer           string `json:"fl_ver"`
	ModVer          string `json:"mod_ver"`
	ScriptHash      string `json:"script_hash"`
}

// HistoryTurn stores one finalized turn where both P1 and P2 commands exist.
type HistoryTurn struct {
	Turn int             `json:"turn"`
	C1   json.RawMessage `json:"c1,omitempty"`
	C2   json.RawMessage `json:"c2,omitempty"`
}

// ExtraTurn stores a single-peer turn beyond target_turn that was already transmitted before disconnect.
type ExtraTurn struct {
	Turn int             `json:"turn"`
	Pid  int             `json:"pid"`
	Cmds json.RawMessage `json:"cmds"`
}

// encodeLine encodes any outgoing message into a single compact JSON line with HTML escaping disabled.
func encodeLine(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func isEmptyJSONArray(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	return len(trimmed) == 0 || bytes.Equal(trimmed, []byte("[]")) || bytes.Equal(trimmed, []byte("null")) || bytes.Equal(trimmed, []byte("{}"))
}
