-- KR-MP Deterministic Lockstep Synchronization Engine (M1 LAN + M2 Online Relay & Fast-Forward Reconnect)
local proto = require("kr_mp.proto")
local commands = require("kr_mp.commands")
local state_hash = require("kr_mp.state_hash")
local prng = require("kr_mp.prng")
local ls_reconnect = require("kr_mp.lockstep_reconnect")

local lockstep = {
    boot = nil,
    transport = nil,
    coop = nil,
    overlay = nil,

    active = false,
    phase = "IDLE", -- "IDLE" | "LOADING" | "CATCHING_UP" | "WAIT_RECONNECT" | "RUNNING" | "PAUSED" | "DESYNC" | "DISCONNECTED"
    local_pid = 1,
    remote_pid = 2,

    turn_ticks = proto.TURN_TICKS,
    input_delay_turns = proto.INPUT_DELAY_TURNS,
    game_speed = 1, -- 1 or 2 (synchronized across both peers)

    current_turn = 0,
    next_send_turn = 0,
    turn_merged = {},     -- [turn] = true
    turns_received = {},  -- [turn] = { [1] = cmds, [2] = cmds }
    local_cmd_buf = {},
    local_seq = 0,

    waiting_for_peer = false,
    wait_start_ts = 0,

    local_loaded = false,
    remote_loaded = false,

    -- M2 / SakuraFrp Direct Dual-Tier Reconnect state
    match_id = nil,
    match_cfg = nil,
    history_nonempty = {},     -- [turn] = { c1 = cmds, c2 = cmds } for Direct Cold Reconnect
    highest_complete_turn = -1,
    peer_max_sent_turn = -1,
    pre_disconnect_phase = "RUNNING",
    reconnect_deadline = 0,
    direct_reconnect = false,
    hot_resume_count = 0,
    cold_reconnect_count = 0,
    reconnect_mode = false,
    blackbox_replay = false,
    blackbox_expected_hashes = nil,
    blackbox_matched = 0,
    blackbox_mismatches = 0,
    catchup_target_turn = 0,
    catchup_target_tick = 0,
    catchup_next_send = 0,
    reconnect_paused_after = false,

    -- Every-30-tick live checksum verification
    local_hashes = {},       -- [tick] = snap
    local_hash_diags = {},   -- [tick] = exact-tick compact entity digest (cleared on match)
    remote_hashes = {},      -- [tick] = hash_hex
    remote_hash_snaps = {},  -- [tick] = formatted snap string (when provided)
    pending_hash_tick = nil,
    pending_hash_hex = nil,
    pending_hash_snap = nil,
    sync_ok_count = 0,
    last_hash_hex = "--------",
    desync_info = nil,
    desync_diag_sent = false,
    hash_log_file = nil,
}

local deep_copy = proto.deep_copy

function lockstep:init(boot, transport, coop, overlay)
    self.boot = boot
    self.transport = transport
    self.coop = coop
    self.overlay = overlay
end

function lockstep:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[LOCKSTEP] " .. fmt, ...)
    end
end

function lockstep:is_active()
    return self.active
end

function lockstep:is_running()
    return self.active and self.phase == "RUNNING"
end

function lockstep:is_catching_up()
    return self.active and self.phase == "CATCHING_UP"
end

function lockstep:is_paused()
    return self.active and self.phase == "PAUSED"
end

function lockstep:close_hash_log()
    if self.hash_log_file then
        self.hash_log_file:flush()
        self.hash_log_file:close()
        self.hash_log_file = nil
    end
end

function lockstep:reset()
    if self.active and not self.blackbox_replay and self.boot and self.boot.diagnostics then
        self.boot.diagnostics:on_match_end(self.phase, self)
    end
    self:close_hash_log()
    self.active = false
    self.phase = "IDLE"
    self.game_speed = 1
    self.current_turn = 0
    self.next_send_turn = 0
    self.turn_merged = {}
    self.turns_received = {}
    self.local_cmd_buf = {}
    self.local_seq = 0
    self.waiting_for_peer = false
    self.local_loaded = false
    self.remote_loaded = false
    self.match_id = nil
    self.match_cfg = nil
    self.history_nonempty = {}
    self.highest_complete_turn = -1
    self.peer_max_sent_turn = -1
    self.pre_disconnect_phase = "RUNNING"
    self.reconnect_deadline = 0
    self.direct_reconnect = false
    self.hot_resume_count = 0
    self.cold_reconnect_count = 0
    self.reconnect_mode = false
    self.blackbox_replay = false
    self.blackbox_expected_hashes = nil
    self.blackbox_matched = 0
    self.blackbox_mismatches = 0
    self.catchup_target_turn = 0
    self.catchup_target_tick = 0
    self.catchup_next_send = 0
    self.reconnect_paused_after = false
    self.local_hashes = {}
    self.local_hash_diags = {}
    self.remote_hashes = {}
    self.remote_hash_snaps = {}
    self.pending_hash_tick = nil
    self.pending_hash_hex = nil
    self.pending_hash_snap = nil
    self.sync_ok_count = 0
    self.last_hash_hex = "--------"
    self.desync_info = nil
    self.desync_diag_sent = false
end

function lockstep:begin_loading(local_pid, cfg)
    self:reset()
    self.active = true
    self.phase = "LOADING"
    self.local_pid = local_pid
    self.remote_pid = (local_pid == 1) and 2 or 1
    self.turn_ticks = (cfg and cfg.turn_ticks) or proto.TURN_TICKS
    self.input_delay_turns = (cfg and cfg.input_delay_turns) or proto.INPUT_DELAY_TURNS
    self.game_speed = 1
    self.match_id = cfg and cfg.match_id or nil
    if local_pid == 1 and not (self.transport and self.transport:is_online()) and cfg then
        self.match_cfg = deep_copy(cfg)
    end

    -- Pre-seed initial empty turns 0 .. (input_delay_turns - 1) for both peers
    for t = 0, self.input_delay_turns - 1 do
        self.turns_received[t] = { [1] = {}, [2] = {} }
    end
    self.highest_complete_turn = self.input_delay_turns - 1
    self.peer_max_sent_turn = self.input_delay_turns - 1
    self.current_turn = 0
    self.next_send_turn = self.input_delay_turns

    -- Open per-player hash log for post-match verification & community bug-report collection
    local log_file = os.getenv("KR_MP_LOG_FILE")
    local base_dir = proto.get_writable_dir()
    local log_dir = (log_file and log_file:match("^(.*)[/\\][^/\\]+$")) or base_dir
    local default_hpath = log_file
        and proto.path_join(log_dir, string.format("mp_p%d_hashes.log", self.local_pid))
        or proto.path_join(base_dir, "kr_mp_hashes.log")
    local hpath = os.getenv("KR_MP_HASH_LOG_FILE") or default_hpath
    self.hash_log_file = io.open(hpath, "w")
    if self.hash_log_file then
        self.hash_log_file:write(string.format("# MP P%d seed=%d level=%d econ=%s tower=%s tick_length=%.12f\n",
            self.local_pid, cfg.seed or 0, cfg.level_idx or 0, tostring(cfg.econ_mode), tostring(cfg.tower_mode), TICK_LENGTH or 0))
        self.hash_log_file:flush()
    end

    self:log("Loading match as P%d (turn_ticks=%d, delay_turns=%d, seed=%d, online=%s)",
        self.local_pid, self.turn_ticks, self.input_delay_turns, cfg.seed or 0,
        tostring(self.transport and self.transport:is_online()))
    if self.boot and self.boot.diagnostics then
        local net_mode = (self.transport and self.transport:is_online()) and "online"
            or ((self.boot.lobby and self.boot.lobby.net_tab) or "lan")
        self.boot.diagnostics:on_match_start(local_pid, cfg, false, net_mode)
    end
end

function lockstep:begin_reconnect(local_pid, cfg, rc)
    return ls_reconnect.begin_reconnect(self, local_pid, cfg, rc)
end

function lockstep:on_local_loaded()
    if not self.active or self.phase ~= "LOADING" then return end
    if self.local_loaded then return end
    self.local_loaded = true

    if self.reconnect_mode then
        self.phase = "CATCHING_UP"
        self.waiting_for_peer = false
        if game and game.store then
            game.store.paused = false
        end
        self:log("Reconnect sim initialized (P%d). Fast-forwarding to tick %d...", self.local_pid, self.catchup_target_tick)
        if self.overlay then
            self.overlay:show_toast(string.format("断线重连中：正在高速追帧至第 %d 帧...", self.catchup_target_tick), 5.0)
        end
        return
    end

    self:log("Local sim initialized (P%d). Sending LOAD_DONE.", self.local_pid)
    self.transport:send({ t = "LOAD_DONE", pid = self.local_pid, match_id = self.match_id })
    self:try_start_running()
end

function lockstep:on_remote_loaded(pid)
    if not self.active or self.phase ~= "LOADING" then return end
    self.remote_loaded = true
    self:log("Remote peer P%d finished loading.", tonumber(pid) or self.remote_pid)
    self:try_start_running()
end

function lockstep:try_start_running()
    if self.phase ~= "LOADING" then return end
    -- In Online mode, the Go server is the authoritative load barrier and broadcasts BEGIN_SIM to both peers
    if self.transport and self.transport:is_online() then
        return
    end
    if self.local_pid == 1 and self.local_loaded and self.remote_loaded then
        self:log("Both peers loaded! Broadcasting BEGIN_SIM.")
        self.transport:send({ t = "BEGIN_SIM", match_id = self.match_id })
        self:start_running()
    end
end

function lockstep:start_running()
    if not self.active or self.phase ~= "LOADING" then return end
    self.phase = "RUNNING"
    self.waiting_for_peer = false
    if game and game.store then
        game.store.paused = false
    end
    self:log("LOCKSTEP RUNNING! (P%d)", self.local_pid)
    if self.overlay then
        self.overlay:show_toast(string.format("双人合作开局！你是 %dP（%s）",
            self.local_pid, self.local_pid == 1 and "蓝方" or "红方"), 4.5)
    end
end

function lockstep:finish_catchup(tick)
    return ls_reconnect.finish_catchup(self, tick)
end

function lockstep:queue_local_command(cmd)
    if not self.active then
        return false
    end
    if self.phase == "PAUSED" then
        if cmd and cmd.op ~= "MAP_PING" then
            if self.overlay then
                self.overlay:show_toast("对局已暂停，请先点击顶部「继续」或按空格恢复后再操作！", 2.0)
            end
            return false
        end
    elseif self.phase ~= "RUNNING" then
        return false
    end
    self.local_seq = self.local_seq + 1
    local c = deep_copy(cmd)
    c.player = self.local_pid
    c.seq = self.local_seq
    if c.wx then c.wx = commands.quantize(c.wx) end
    if c.wy then c.wy = commands.quantize(c.wy) end
    self.local_cmd_buf[#self.local_cmd_buf + 1] = c
    self:log("QUEUE LOCAL op=%s pid=%d seq=%d (for turn %d)",
        tostring(c.op), c.player, c.seq, self.next_send_turn)
    return true
end

function lockstep:request_toggle_pause()
    if not self.active then return end
    if self.phase == "RUNNING" then
        self:queue_local_command({ op = "SYNC_PAUSE" })
    elseif self.phase == "PAUSED" then
        self.transport:send({ t = "SYNC_RESUME", pid = self.local_pid })
        self:on_sync_resume(self.local_pid)
    end
end

function lockstep:request_toggle_speed()
    if not self.active then return end
    if self.phase ~= "RUNNING" and self.phase ~= "PAUSED" then return end
    local new_speed = (self.game_speed == 1) and 2 or 1
    self.transport:send({ t = "SYNC_SPEED", pid = self.local_pid, speed = new_speed })
    if not (self.transport and self.transport:is_online()) then
        self:on_sync_speed(new_speed, self.local_pid)
    end
end

function lockstep:on_sync_speed(speed, by_pid)
    local spd = (tonumber(speed) == 2) and 2 or 1
    self.game_speed = spd
    self:log("Match speed set to %dx by P%d", spd, tonumber(by_pid) or 0)
    if self.overlay then
        self.overlay:show_toast(string.format("同步倍速已切换为 %dx（由 %dP 触发）", spd, tonumber(by_pid) or 0), 2.5)
    end
end

function lockstep:on_sync_pause_exec(by_pid)
    if not self.active then return end
    -- Never freeze during historical fast-forward catch-up
    if self.phase == "CATCHING_UP" then return end
    if self.phase ~= "RUNNING" then return end
    self.phase = "PAUSED"
    if game and game.store then
        game.store.paused = true
    end
    self:log("Match PAUSED by P%d at tick %d", tonumber(by_pid) or 0, (game and game.store and game.store.tick) or 0)
    if self.overlay then
        self.overlay:show_toast(string.format("对局已暂停（由 %dP 触发，点击“继续对局”恢复）", tonumber(by_pid) or 0), 4)
    end
end

function lockstep:on_sync_resume(by_pid)
    if not self.active or self.phase ~= "PAUSED" then return end
    self.phase = "RUNNING"
    if game and game.store then
        game.store.paused = false
    end
    self:log("Match RESUMED by P%d", tonumber(by_pid) or 0)
    if self.overlay then
        self.overlay:show_toast(string.format("对局已恢复（由 %dP 触发）", tonumber(by_pid) or 0), 2.5)
    end
end

local function clamp_delay_turns(v)
    local n = tonumber(v) or proto.INPUT_DELAY_TURNS
    if n >= 6 then return 6 end
    if n >= 4 then return 4 end
    if n >= 3 then return 3 end
    return 2
end

function lockstep:record_turn(turn_id, pid, cmds)
    if turn_id == nil or pid == nil then return end
    local bucket = self.turns_received[turn_id]
    if not bucket then
        bucket = {}
        self.turns_received[turn_id] = bucket
    end
    -- Preserve first canonical turn submission for determinism
    if bucket[pid] == nil then
        bucket[pid] = cmds or {}
    end
    if pid == self.remote_pid and turn_id > self.peer_max_sent_turn then
        self.peer_max_sent_turn = turn_id
    end
    while true do
        local nxt = self.highest_complete_turn + 1
        local b = self.turns_received[nxt]
        if b and b[1] ~= nil and b[2] ~= nil then
            self.highest_complete_turn = nxt
            if (type(b[1]) == "table" and #b[1] > 0) or (type(b[2]) == "table" and #b[2] > 0) then
                self.history_nonempty[nxt] = { c1 = deep_copy(b[1]), c2 = deep_copy(b[2]) }
            end
        else
            break
        end
    end
end

function lockstep:request_cycle_delay()
    if not self.active or self.local_pid ~= 1 then
        if self.overlay and self.local_pid ~= 1 then
            self.overlay:show_toast("仅 1P 房主可在局内切换输入缓冲档位。", 2.0)
        end
        return false
    end
    if self.phase ~= "RUNNING" then return false end
    local cur = clamp_delay_turns(self.input_delay_turns)
    local nxt = (cur == 2) and 3 or ((cur == 3) and 4 or ((cur == 4) and 6 or 2))
    return self:queue_local_command({ op = "SYNC_DELAY", delay = nxt })
end

function lockstep:on_sync_delay_exec(delay_turns, by_pid)
    if not self.active then return end
    local d = clamp_delay_turns(delay_turns)
    self.input_delay_turns = d
    local ms = d * self.turn_ticks * (1000 / 60)
    self:log("Live input_delay_turns changed to %d (%dms) by P%d at tick %d",
        d, math.floor(ms + 0.5), tonumber(by_pid) or 0, (game and game.store and game.store.tick) or 0)
    if self.phase ~= "CATCHING_UP" and self.overlay then
        self.overlay:show_toast(string.format("输入缓冲已热切为 %dms（%d 回合 · 晚高峰防卡顿）", math.floor(ms + 0.5), d), 2.5)
    end
end

-- === Reconnect, Hot-Resume & Grace Timer Methods (delegated to lockstep_reconnect.lua) ===

function lockstep:get_first_missing_remote_turn() return ls_reconnect.get_first_missing_remote_turn(self) end
function lockstep:collect_local_turns_since(from_turn) return ls_reconnect.collect_local_turns_since(self, from_turn) end
function lockstep:build_hot_resume_req() return ls_reconnect.build_hot_resume_req(self) end
function lockstep:handle_hot_resume_req(msg) return ls_reconnect.handle_hot_resume_req(self, msg) end
function lockstep:handle_hot_resume_ok(msg) return ls_reconnect.handle_hot_resume_ok(self, msg) end
function lockstep:handle_cold_reconnect_req(msg) return ls_reconnect.handle_cold_reconnect_req(self, msg) end
function lockstep:handle_direct_reconnect_done(msg) return ls_reconnect.handle_direct_reconnect_done(self, msg) end
function lockstep:get_reconnect_remaining() return ls_reconnect.get_reconnect_remaining(self) end
function lockstep:update_timers(now) return ls_reconnect.update_timers(self, now) end

function lockstep:send_next_turn()
    local turn_id = self.next_send_turn
    self.next_send_turn = turn_id + 1

    local cmds = self.local_cmd_buf
    self.local_cmd_buf = {}

    self:record_turn(turn_id, self.local_pid, cmds)

    local pkt = {
        t = "TURN",
        turn = turn_id,
        pid = self.local_pid,
        cmds = cmds,
    }
    if self.pending_hash_tick and self.pending_hash_hex then
        pkt.ht = self.pending_hash_tick
        pkt.hh = self.pending_hash_hex
        if self.pending_hash_snap then
            pkt.hs = self.pending_hash_snap
        end
        self.pending_hash_tick = nil
        self.pending_hash_hex = nil
        self.pending_hash_snap = nil
    end
    self.transport:send(pkt)
end

local MSG_HANDLERS = {}

function MSG_HANDLERS.LOAD_DONE(self, msg)
    if msg.match_id and self.match_id and msg.match_id ~= self.match_id then
        return true
    end
    self:on_remote_loaded(msg.pid)
    return true
end

function MSG_HANDLERS.BEGIN_SIM(self, msg)
    if msg.match_id and self.match_id and msg.match_id ~= self.match_id then
        return true
    end
    self:start_running()
    return true
end

function MSG_HANDLERS.SYNC_RESUME(self, msg)
    if self.phase ~= "LOADING" then self:on_sync_resume(msg.pid) end
    return true
end

function MSG_HANDLERS.SYNC_SPEED(self, msg)
    if self.phase ~= "LOADING" then self:on_sync_speed(msg.speed, msg.pid) end
    return true
end

function MSG_HANDLERS.PEER_DISCONNECTED(self, msg)
    self:on_peer_disconnected("peer_dropped", msg.can_reconnect == true, msg.timeout)
    return true
end

function MSG_HANDLERS.PEER_RECONNECTING(self, msg)
    self:log("Peer P%d reconnecting & fast-forwarding (target_turn=%s)...",
        tonumber(msg.pid) or self.remote_pid, tostring(msg.target_turn))
    if self.overlay then
        self.overlay:show_toast(string.format("%dP 队友正在高速追帧重连中...", tonumber(msg.pid) or self.remote_pid), 8)
    end
    return true
end

function MSG_HANDLERS.PEER_RECONNECTED(self, msg)
    self.game_speed = (tonumber(msg.game_speed) == 2) and 2 or 1
    self.reconnect_deadline = 0
    self.direct_reconnect = false
    if msg.paused then
        self.phase = "PAUSED"
        if game and game.store then game.store.paused = true end
    else
        self.phase = "RUNNING"
        if game and game.store then game.store.paused = false end
    end
    self.waiting_for_peer = false
    self.cold_reconnect_count = self.cold_reconnect_count + 1
    self:log("PEER_RECONNECTED! Resuming live 60Hz lockstep (phase=%s speed=%dx)", self.phase, self.game_speed)
    if self.overlay then
        self.overlay:show_toast(string.format("%dP 重连追帧成功，恢复实时联机！", tonumber(msg.pid) or 0), 4.5)
    end
    return true
end

function MSG_HANDLERS.RECONNECT_DONE(self, msg)
    if self.local_pid == 1 and not (self.transport and self.transport:is_online()) then
        return self:handle_direct_reconnect_done(msg)
    end
    return false
end

function MSG_HANDLERS.TURN(self, msg)
    if self.phase == "LOADING" then return true end
    local turn_id = tonumber(msg.turn)
    local pid = tonumber(msg.pid)
    if turn_id ~= nil and pid ~= nil then
        self:record_turn(turn_id, pid, msg.cmds or {})
        if msg.ht and msg.hh then
            self:on_remote_hash(tonumber(msg.ht), tostring(msg.hh), msg.hs)
        end
    end
    return true
end

function MSG_HANDLERS.DESYNC_DIAG(self, msg)
    if self.phase == "LOADING" then return true end
    local rtick = tonumber(msg.tick)
    local rpid = tonumber(msg.pid) or self.remote_pid
    self:log("  REMOTE DIAG (P%s tick=%s): %s", tostring(rpid), tostring(rtick or "?"), tostring(msg.snap or ""))
    if msg.ents and msg.ents ~= "" then
        self:log("  REMOTE ENTS: %s", tostring(msg.ents))
    end
    if self.boot and self.boot.diagnostics then
        self.boot.diagnostics:on_desync({
            tick = rtick,
            remote_hash = msg.hash,
            remote_snap = msg.snap,
            remote_ents = msg.ents,
            detected_by = "peer",
        }, self)
    end
    if self.phase ~= "DESYNC" then
        self.phase = "DESYNC"
        local st = game and game.store
        if st then st.paused = true end
        local loc_snap = (rtick and self.local_hashes[rtick]) or (st and state_hash.compute(st, prng, self.coop))
        local loc_line = loc_snap and state_hash.format_line(loc_snap) or ""
        local ents_summary = (rtick and self.local_hash_diags[rtick]) or (st and state_hash.build_diag_summary(st, 24) or "")
        local loc_hex = loc_snap and loc_snap.hash or tostring(self.last_hash_hex)
        self.desync_info = {
            tick = rtick or (st and st.tick) or 0,
            local_hash = loc_hex,
            remote_hash = tostring(msg.hash or "?"),
            snap = loc_snap,
            remote_snap = msg.snap,
        }
        self:close_hash_log()
        self:log("!!! MP DESYNC REPORTED BY PEER AT TICK %s !!! local=%s", tostring(rtick or "?"), loc_hex)
        if loc_line ~= "" then self:log("  LOCAL  SNAP: %s", loc_line) end
        if ents_summary ~= "" then self:log("  LOCAL  ENTS: %s", ents_summary) end
        if self.boot and self.boot.diagnostics then
            self.boot.diagnostics:on_desync({
                tick = rtick or (st and st.tick) or 0,
                local_hash = loc_hex,
                remote_hash = tostring(msg.hash or "?"),
                local_snap = loc_line,
                remote_snap = msg.snap,
                local_ents = ents_summary,
                remote_ents = msg.ents,
                detected_by = "peer",
            }, self)
        end
        if not self.desync_diag_sent and self.transport and self.transport:is_connected() then
            self.desync_diag_sent = true
            pcall(self.transport.send, self.transport, {
                t = "DESYNC_DIAG",
                pid = self.local_pid,
                tick = rtick or (st and st.tick) or 0,
                hash = loc_hex,
                snap = loc_line,
                ents = ents_summary,
            })
        end
        if self.overlay then
            self.overlay:show_toast(string.format("画面同步异常（第 %s 帧，队友先检出）· 已暂停保护，请双方点「退出」重开", tostring(rtick or "?")), 20)
        end
    end
    return true
end

function lockstep:on_message(msg)
    if not self.active or not msg then return false end
    local handler = MSG_HANDLERS[msg.t]
    if handler then return handler(self, msg) end
    return false
end

function lockstep:on_peer_disconnected(reason, can_reconnect, timeout_sec, is_direct)
    return ls_reconnect.on_peer_disconnected(self, reason, can_reconnect, timeout_sec, is_direct)
end

function lockstep:merge_turn_into_commands(turn_id)
    if self.turn_merged[turn_id] then return end
    self.turn_merged[turn_id] = true

    local bucket = self.turns_received[turn_id]
    if not bucket then return end
    local exec_tick = turn_id * self.turn_ticks + 1

    -- Strictly deterministic merge order: P1 commands first, then P2 commands
    for pid = 1, 2 do
        local list = bucket[pid]
        if list then
            for i = 1, #list do
                local c = deep_copy(list[i])
                c.player = pid
                commands:enqueue(exec_tick, c)
            end
        end
    end

    -- Keep 32-turn sliding window so in-flight turns survive SakuraFrp hot-resume
    local old = turn_id - 32
    if old >= 0 then
        self.turns_received[old] = nil
        self.turn_merged[old] = nil
    end
end

-- Called by sim.update before executing tick `next_tick` (= store.tick + 1)
function lockstep:can_step_tick(next_tick)
    if not self.active then return true end
    if self.phase ~= "RUNNING" and self.phase ~= "CATCHING_UP" then return false end

    local turn_id = math.floor((next_tick - 1) / self.turn_ticks)
    local is_turn_start = ((next_tick - 1) % self.turn_ticks == 0)

    if is_turn_start then
        local bucket = self.turns_received[turn_id]
        if not bucket or bucket[1] == nil or bucket[2] == nil then
            if not self.waiting_for_peer then
                self.waiting_for_peer = true
                self.wait_start_ts = love.timer and love.timer.getTime() or 0
            end
            return false
        end
        self.waiting_for_peer = false
        self.current_turn = turn_id
        self:merge_turn_into_commands(turn_id)
    end
    return true
end

-- Called inside sim:do_tick() right after all systems ran (while store.player_gold is still canonical!)
function lockstep:on_tick_end(store)
    if not self.active then return end
    local tick = store.tick or 0

    -- 1. Every 30 ticks compute deterministic checksum & schedule transmission to peer
    if tick > 0 and tick % 30 == 0 then
        local snap = state_hash.compute(store, prng, self.coop)
        self.last_hash_hex = snap.hash
        self.local_hashes[tick] = snap
        self.local_hash_diags[tick] = state_hash.build_diag_summary(store, 24)
        local stale_cutoff = tick - 300
        if stale_cutoff > 0 then
            for dtick in pairs(self.local_hash_diags) do
                if type(dtick) == "number" and dtick <= stale_cutoff then
                    self.local_hash_diags[dtick] = nil
                end
            end
        end
        self.pending_hash_tick = tick
        self.pending_hash_hex = snap.hash
        self.pending_hash_snap = state_hash.format_line(snap)
        if self.boot and self.boot.diagnostics and not self.blackbox_replay then
            self.boot.diagnostics:on_hash_checkpoint(snap, self.pending_hash_snap)
        end
        if self.blackbox_replay and self.blackbox_expected_hashes and self.blackbox_expected_hashes[tick] then
            local exp_h = self.blackbox_expected_hashes[tick]
            if snap.hash == exp_h then
                self.blackbox_matched = (self.blackbox_matched or 0) + 1
            else
                self.blackbox_mismatches = (self.blackbox_mismatches or 0) + 1
                self:log("!!! BLACKBOX HASH DIFF AT TICK %d !!! replay=%s report=%s", tick, snap.hash, exp_h)
                self:log("  REPLAY SNAP: %s", self.pending_hash_snap)
                self:log("  REPLAY ENTS: %s", tostring(self.local_hash_diags[tick] or ""))
            end
        end

        if self.hash_log_file then
            self.hash_log_file:write(self.pending_hash_snap .. "\n")
            if tick % 300 == 0 then
                self.hash_log_file:flush()
            end
        end

        if self.remote_hashes[tick] then
            self:verify_hash_pair(tick)
        end
    end

    -- 2. At the end of each turn boundary, either finish catch-up or maintain dynamic lookahead window
    if tick > 0 and tick % self.turn_ticks == 0 then
        if self.phase == "CATCHING_UP" then
            if tick >= self.catchup_target_tick then
                self:finish_catchup(tick)
            end
        elseif self.phase == "RUNNING" then
            local completed_turn = math.floor(tick / self.turn_ticks) - 1
            local want_through = completed_turn + self.input_delay_turns
            while self.next_send_turn <= want_through do
                self:send_next_turn()
            end
        end
    end
end

function lockstep:on_remote_hash(tick, remote_hex, remote_snap)
    if not tick or not remote_hex then return end
    self.remote_hashes[tick] = remote_hex
    if type(remote_snap) == "string" and remote_snap ~= "" then
        self.remote_hash_snaps[tick] = remote_snap
    end
    if self.local_hashes[tick] then
        self:verify_hash_pair(tick)
    end
end

function lockstep:verify_hash_pair(tick)
    local loc = self.local_hashes[tick]
    local rem = self.remote_hashes[tick]
    if not loc or not rem then return end

    if loc.hash == rem then
        self.sync_ok_count = self.sync_ok_count + 1
        self.local_hashes[tick] = nil
        self.local_hash_diags[tick] = nil
        self.remote_hashes[tick] = nil
        self.remote_hash_snaps[tick] = nil
    else
        self.phase = "DESYNC"
        local loc_line = state_hash.format_line(loc)
        local rem_line = self.remote_hash_snaps[tick]
        self.desync_info = { tick = tick, local_hash = loc.hash, remote_hash = rem, snap = loc, remote_snap = rem_line }
        local st = game and game.store
        if st then
            st.paused = true
        end
        local ents_summary = self.local_hash_diags[tick] or (st and state_hash.build_diag_summary(st, 24) or "")
        self:close_hash_log()
        self:log("!!! MP DESYNC DETECTED AT TICK %d !!! local=%s remote=%s", tick, loc.hash, rem)
        self:log("  LOCAL  SNAP: %s", loc_line)
        if rem_line then
            self:log("  REMOTE SNAP: %s", rem_line)
        end
        if ents_summary ~= "" then
            self:log("  LOCAL  ENTS: %s", ents_summary)
        end
        if self.boot and self.boot.diagnostics then
            self.boot.diagnostics:on_desync({
                tick = tick,
                local_hash = loc.hash,
                remote_hash = rem,
                local_snap = loc_line,
                remote_snap = rem_line,
                local_ents = ents_summary,
                detected_by = "local",
            }, self)
        end
        if not self.desync_diag_sent and self.transport and self.transport:is_connected() then
            self.desync_diag_sent = true
            pcall(self.transport.send, self.transport, {
                t = "DESYNC_DIAG",
                pid = self.local_pid,
                tick = tick,
                hash = loc.hash,
                snap = loc_line,
                ents = ents_summary,
            })
        end
        if self.overlay then
            self.overlay:show_toast(string.format("画面同步异常（第 %d 帧，非掉线）· 已暂停保护，请双方点「退出」重开 (本地:%s 队友:%s)", tick, loc.hash, rem), 20)
        end
    end
end

return lockstep
