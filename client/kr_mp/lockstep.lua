-- KR-MP Deterministic Lockstep Synchronization Engine (M1 LAN + M2 Online Relay & Fast-Forward Reconnect)
local proto = require("kr_mp.proto")
local commands = require("kr_mp.commands")
local state_hash = require("kr_mp.state_hash")
local prng = require("kr_mp.prng")

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
    catchup_target_turn = 0,
    catchup_target_tick = 0,
    catchup_next_send = 0,
    reconnect_paused_after = false,

    -- Every-30-tick live checksum verification
    local_hashes = {},       -- [tick] = snap
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

local function deep_copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, val in pairs(v) do
        if type(k) ~= "function" and type(val) ~= "function" and type(val) ~= "userdata" and type(val) ~= "thread" then
            out[deep_copy(k, seen)] = deep_copy(val, seen)
        end
    end
    return out
end

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
    self.catchup_target_turn = 0
    self.catchup_target_tick = 0
    self.catchup_next_send = 0
    self.reconnect_paused_after = false
    self.local_hashes = {}
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
end

function lockstep:begin_reconnect(local_pid, cfg, rc)
    self:begin_loading(local_pid, cfg)
    self.reconnect_mode = true
    local target_turn = tonumber(rc.target_turn) or (self.input_delay_turns - 1)
    self.catchup_target_turn = target_turn
    self.catchup_target_tick = (target_turn + 1) * self.turn_ticks
    self.catchup_next_send = tonumber(rc.my_next_send_turn) or self.input_delay_turns
    self.reconnect_paused_after = (rc.paused == true)
    self.game_speed = (tonumber(rc.game_speed) == 2) and 2 or 1

    -- Pre-fill all finalized turns [0 .. target_turn] as empty, then overlay non-empty command turns
    for t = 0, target_turn do
        self.turns_received[t] = { [1] = {}, [2] = {} }
    end
    for _, ht in ipairs(rc.turns or {}) do
        local tid = tonumber(ht.turn)
        if tid and tid >= 0 and tid <= target_turn then
            local c1 = ht.c1 or {}
            local c2 = ht.c2 or {}
            self.turns_received[tid] = { [1] = c1, [2] = c2 }
            if #c1 > 0 or #c2 > 0 then
                self.history_nonempty[tid] = { c1 = deep_copy(c1), c2 = deep_copy(c2) }
            end
        end
    end
    self.highest_complete_turn = target_turn
    -- Restore any in-flight turns > target_turn already transmitted by either peer
    for _, et in ipairs(rc.extra_turns or {}) do
        local tid = tonumber(et.turn)
        local pid = tonumber(et.pid)
        if tid and pid then
            self:record_turn(tid, pid, et.cmds or {})
        end
    end

    self:log("RECONNECT prepared for P%d: target_turn=%d (target_tick=%d) next_send=%d non_empty=%d extra=%d",
        local_pid, target_turn, self.catchup_target_tick, self.catchup_next_send,
        #(rc.turns or {}), #(rc.extra_turns or {}))
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
    self:log("Fast-forward catch-up COMPLETE at tick=%d (target=%d) hash=%s! Flushing lookahead turns...",
        tick, self.catchup_target_tick, tostring(self.last_hash_hex))
    if self.hash_log_file then
        self.hash_log_file:flush()
    end
    self.reconnect_mode = false
    self.next_send_turn = self.catchup_next_send

    -- Flush any missing lookahead turns up through (catchup_target_turn + input_delay_turns)
    local want_through = self.catchup_target_turn + self.input_delay_turns
    while self.next_send_turn <= want_through do
        self:send_next_turn()
    end

    -- Hold briefly until server confirms both peers are ready and broadcasts PEER_RECONNECTED
    self.phase = "WAIT_RECONNECT"
    if game and game.store then
        game.store.paused = true
    end
    self.transport:send({
        t = "RECONNECT_DONE",
        pid = self.local_pid,
        tick = tick,
        hash = self.last_hash_hex,
    })
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

function lockstep:get_first_missing_remote_turn()
    local start_t = math.max(0, self.current_turn)
    local limit_t = math.max(start_t + 32, self.next_send_turn + 8)
    for t = start_t, limit_t do
        local b = self.turns_received[t]
        if not b or b[self.remote_pid] == nil then
            return t
        end
    end
    return limit_t + 1
end

function lockstep:collect_local_turns_since(from_turn)
    local out = {}
    local start_t = math.max(0, tonumber(from_turn) or 0)
    local end_t = self.next_send_turn - 1
    for t = start_t, end_t do
        local b = self.turns_received[t]
        local cmds = b and b[self.local_pid]
        if cmds == nil and t <= self.highest_complete_turn then
            local h = self.history_nonempty[t]
            cmds = h and (self.local_pid == 1 and h.c1 or h.c2) or {}
        end
        out[#out + 1] = { turn = t, cmds = cmds or {} }
    end
    return out
end

function lockstep:build_hot_resume_req()
    return {
        t = "HOT_RESUME_REQ",
        match_id = self.match_id,
        pid = self.local_pid,
        current_turn = self.current_turn,
        next_send_turn = self.next_send_turn,
        want_from_turn = self:get_first_missing_remote_turn(),
        my_turns = self:collect_local_turns_since(math.max(0, self.current_turn - 2)),
        tick = (game and game.store and game.store.tick) or 0,
        hash = self.last_hash_hex,
    }
end

function lockstep:handle_hot_resume_req(msg)
    if not self.active or self.local_pid ~= 1 then return false end
    if not self.match_id or msg.match_id ~= self.match_id then return false end
    if self.phase ~= "WAIT_RECONNECT" and self.phase ~= "RUNNING" and self.phase ~= "PAUSED" then
        return false
    end
    for _, item in ipairs(msg.my_turns or {}) do
        local tid = tonumber(item.turn)
        if tid then self:record_turn(tid, 2, item.cmds or {}) end
    end
    local want_from = tonumber(msg.want_from_turn) or math.max(0, self.current_turn)
    local host_turns = self:collect_local_turns_since(want_from)
    local peer_want = self:get_first_missing_remote_turn()
    local was_paused = (self.pre_disconnect_phase == "PAUSED")

    self.transport:send({
        t = "HOT_RESUME_OK",
        match_id = self.match_id,
        host_turns = host_turns,
        peer_want_from = peer_want,
        game_speed = self.game_speed,
        paused = was_paused,
    })

    self.phase = was_paused and "PAUSED" or "RUNNING"
    self.reconnect_deadline = 0
    self.direct_reconnect = false
    self.waiting_for_peer = false
    self.hot_resume_count = self.hot_resume_count + 1
    if game and game.store then game.store.paused = was_paused end
    self:log("DIRECT HOT_RESUME_OK! Sent %d missing P1 turns (from %d), peer_want=%d -> resuming %s",
        #host_turns, want_from, peer_want, self.phase)
    if self.overlay then
        self.overlay:show_toast("2P 无感热续传成功（0 读条），恢复实时联机！", 3.5)
    end
    return true
end

function lockstep:handle_hot_resume_ok(msg)
    if not self.active or self.local_pid ~= 2 then return false end
    if not self.match_id or msg.match_id ~= self.match_id then return false end
    for _, item in ipairs(msg.host_turns or {}) do
        local tid = tonumber(item.turn)
        if tid then self:record_turn(tid, 1, item.cmds or {}) end
    end
    local pwf = tonumber(msg.peer_want_from)
    if pwf and pwf < self.next_send_turn then
        local extra = self:collect_local_turns_since(pwf)
        for i = 1, #extra do
            self.transport:send({ t = "TURN", turn = extra[i].turn, pid = self.local_pid, cmds = extra[i].cmds })
        end
    end
    self.game_speed = (tonumber(msg.game_speed) == 2) and 2 or 1
    local was_paused = (msg.paused == true)
    self.phase = was_paused and "PAUSED" or "RUNNING"
    self.reconnect_deadline = 0
    self.direct_reconnect = false
    self.waiting_for_peer = false
    self.hot_resume_count = self.hot_resume_count + 1
    if game and game.store then game.store.paused = was_paused end
    self:log("DIRECT HOT_RESUME complete on P2! Received %d host turns -> resuming %s",
        #(msg.host_turns or {}), self.phase)
    if self.overlay then
        self.overlay:show_toast("樱花无感热续传成功（0 读条），继续战斗！", 3.5)
    end
    return true
end

function lockstep:handle_cold_reconnect_req(msg)
    if not self.active or self.local_pid ~= 1 or not self.match_cfg then return false end
    if not self.match_id or msg.match_id ~= self.match_id then return false end
    if self.phase ~= "WAIT_RECONNECT" and self.phase ~= "RUNNING" and self.phase ~= "PAUSED" then
        return false
    end
    if self.phase == "RUNNING" or self.phase == "PAUSED" then
        self.pre_disconnect_phase = self.phase
    end
    self.phase = "WAIT_RECONNECT"
    if game and game.store then game.store.paused = true end

    local target_turn = math.max(self.input_delay_turns - 1, self.highest_complete_turn)
    local hkeys = {}
    for tid in pairs(self.history_nonempty) do
        if type(tid) == "number" and tid >= 0 and tid <= target_turn then
            hkeys[#hkeys + 1] = tid
        end
    end
    table.sort(hkeys)
    local turns = {}
    for i = 1, #hkeys do
        local tid = hkeys[i]
        local h = self.history_nonempty[tid]
        turns[#turns + 1] = { turn = tid, c1 = h.c1, c2 = h.c2 }
    end

    local ekeys = {}
    for tid in pairs(self.turns_received) do
        if type(tid) == "number" and tid > target_turn then
            ekeys[#ekeys + 1] = tid
        end
    end
    table.sort(ekeys)
    local extra = {}
    for i = 1, #ekeys do
        local tid = ekeys[i]
        local b = self.turns_received[tid]
        for p = 1, 2 do
            if b and b[p] ~= nil then
                extra[#extra + 1] = { turn = tid, pid = p, cmds = b[p] }
            end
        end
    end

    local my_next_send = math.max(self.input_delay_turns, self.peer_max_sent_turn + 1)
    local now = (love and love.timer and love.timer.getTime()) or os.clock()
    self.reconnect_deadline = now + 90
    self:log("DIRECT COLD_RECONNECT accepted! target_turn=%d non_empty=%d extra=%d peer_next_send=%d",
        target_turn, #turns, #extra, my_next_send)
    self.transport:send({
        t = "RECONNECT_STATE",
        direct = true,
        match_id = self.match_id,
        pid = 2,
        cfg = self.match_cfg,
        target_turn = target_turn,
        turns = turns,
        extra_turns = extra,
        my_next_send_turn = my_next_send,
        game_speed = self.game_speed,
        paused = (self.pre_disconnect_phase == "PAUSED"),
    })
    if self.overlay then
        self.overlay:show_toast("2P 已重新接入，正在高速追帧追赶战局...", 8.0)
    end
    return true
end

function lockstep:handle_direct_reconnect_done(msg)
    if not self.active or self.local_pid ~= 1 then return false end
    if self.transport and self.transport:is_online() then return false end
    local was_paused = (self.pre_disconnect_phase == "PAUSED")
    self.transport:send({
        t = "PEER_RECONNECTED",
        pid = 2,
        paused = was_paused,
        game_speed = self.game_speed,
    })
    self.phase = was_paused and "PAUSED" or "RUNNING"
    self.reconnect_deadline = 0
    self.direct_reconnect = false
    self.waiting_for_peer = false
    self.cold_reconnect_count = self.cold_reconnect_count + 1
    if game and game.store then game.store.paused = was_paused end
    self:log("DIRECT RECONNECT_DONE from P2 at tick=%s hash=%s -> resuming %s!",
        tostring(msg.tick), tostring(msg.hash), self.phase)
    if self.overlay then
        self.overlay:show_toast("2P 追帧重连成功，恢复实时联机！", 4.0)
    end
    return true
end

function lockstep:get_reconnect_remaining()
    if self.phase ~= "WAIT_RECONNECT" or (self.reconnect_deadline or 0) <= 0 then
        return 0
    end
    local now = (love and love.timer and love.timer.getTime()) or os.clock()
    return math.max(0, math.ceil(self.reconnect_deadline - now))
end

function lockstep:update_timers(now)
    if not self.active or self.phase ~= "WAIT_RECONNECT" then return end
    if (self.reconnect_deadline or 0) > 0 and now >= self.reconnect_deadline then
        self.phase = "DISCONNECTED"
        self.reconnect_deadline = 0
        self.direct_reconnect = false
        if game and game.store then game.store.paused = true end
        self:close_hash_log()
        self:log("WAIT_RECONNECT grace window expired; match ended.")
        if self.overlay then
            self.overlay:show_toast("等待重连已超时，对局已结束，请点顶部「退出」返回大厅。", 10.0)
        end
    end
end

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
    if self.phase ~= "DESYNC" then
        self.phase = "DESYNC"
        local st = game and game.store
        if st then st.paused = true end
        local loc_snap = (rtick and self.local_hashes[rtick]) or (st and state_hash.compute(st, prng, self.coop))
        local loc_line = loc_snap and state_hash.format_line(loc_snap) or ""
        local ents_summary = st and state_hash.build_diag_summary(st, 18) or ""
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
    if not self.active then return end
    if can_reconnect then
        if self.phase == "RUNNING" or self.phase == "PAUSED" then
            self.pre_disconnect_phase = self.phase
        end
        local grace = tonumber(timeout_sec) or (is_direct and 180 or 300)
        local now = (love and love.timer and love.timer.getTime()) or os.clock()
        self.phase = "WAIT_RECONNECT"
        self.direct_reconnect = (is_direct == true)
        self.reconnect_deadline = now + grace
        if game and game.store then
            game.store.paused = true
        end
        self:log("Peer dropped (%s); holding match in WAIT_RECONNECT (%ds grace, direct=%s)",
            tostring(reason), grace, tostring(is_direct == true))
        if self.overlay then
            if is_direct then
                local msg = (self.local_pid == 1)
                    and string.format("连接中断（樱花波动/掉线），原地冻结等待 2P 热续传（保留 %d 秒）...", grace)
                    or string.format("连接中断（樱花波动），已原地冻结并每 2 秒自动重连房主（保留 %d 秒）...", grace)
                self.overlay:show_toast(msg, 10)
            else
                self.overlay:show_toast(string.format("队友已掉线，冻结保局等待重连（保留 %d 秒）...", grace), 15)
            end
        end
        return
    end

    self.phase = "DISCONNECTED"
    self.reconnect_deadline = 0
    self.direct_reconnect = false
    if game and game.store then
        game.store.paused = true
    end
    self:close_hash_log()
    self:log("Peer disconnected during match: %s", tostring(reason))
    if self.overlay then
        self.overlay:show_toast("联机连接已断开，请点击顶部「退出」返回大厅。", 10)
    end
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
        self.pending_hash_tick = tick
        self.pending_hash_hex = snap.hash
        self.pending_hash_snap = state_hash.format_line(snap)

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
        local ents_summary = st and state_hash.build_diag_summary(st, 18) or ""
        self:close_hash_log()
        self:log("!!! MP DESYNC DETECTED AT TICK %d !!! local=%s remote=%s", tick, loc.hash, rem)
        self:log("  LOCAL  SNAP: %s", loc_line)
        if rem_line then
            self:log("  REMOTE SNAP: %s", rem_line)
        end
        if ents_summary ~= "" then
            self:log("  LOCAL  ENTS: %s", ents_summary)
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
