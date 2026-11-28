-- KR-MP Lockstep Reconnect, SakuraFrp Hot-Resume & Offline Black-Box Catch-Up
-- Extracted from lockstep.lua to keep lockstep core <= 850 lines and cohesive.
local proto = require("kr_mp.proto")
local deep_copy = proto.deep_copy

local M = {}

function M.begin_reconnect(self, local_pid, cfg, rc)
    self:begin_loading(local_pid, cfg)
    self.reconnect_mode = true
    self.blackbox_replay = (rc.blackbox == true)
    if self.blackbox_replay then
        self.blackbox_expected_hashes = rc.expected_hashes or {}
        self.blackbox_matched = 0
        self.blackbox_mismatches = 0
        if self.boot and self.boot.diagnostics then
            self.boot.diagnostics.active_match = nil
        end
    elseif self.boot and self.boot.diagnostics then
        self.boot.diagnostics:mark_reconnect(true)
    end
    local target_turn = tonumber(rc.target_turn) or (self.input_delay_turns - 1)
    local stop_tick = (self.blackbox_replay and tonumber(rc.stop_tick)) or ((target_turn + 1) * self.turn_ticks)
    if self.blackbox_replay then
        local min_turn = math.ceil(stop_tick / math.max(1, self.turn_ticks)) + 1
        if min_turn > target_turn then target_turn = min_turn end
    end
    self.catchup_target_turn = target_turn
    self.catchup_target_tick = stop_tick
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

function M.finish_catchup(self, tick)
    if self.blackbox_replay then
        self:log("BLACKBOX_REPLAY_COMPLETE tick=%d target=%d hash=%s matched=%d diffs=%d",
            tick, self.catchup_target_tick, tostring(self.last_hash_hex),
            self.blackbox_matched or 0, self.blackbox_mismatches or 0)
        self:close_hash_log()
        self.reconnect_mode = false
        self.phase = "PAUSED"
        if game and game.store then game.store.paused = true end
        if self.overlay then
            self.overlay:show_toast(string.format("黑匣子复现完成！停在第 %d 帧（匹配 %d / 差异 %d），详见日志",
                tick, self.blackbox_matched or 0, self.blackbox_mismatches or 0), 10.0)
        end
        if os.getenv("KR_MP_BLACKBOX_AUTO_EXIT") == "1" and love and love.event and love.event.quit then
            love.event.quit()
        end
        return
    end
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

function M.get_first_missing_remote_turn(self)
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

function M.collect_local_turns_since(self, from_turn)
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

function M.build_hot_resume_req(self)
    return {
        t = "HOT_RESUME_REQ",
        match_id = self.match_id,
        pid = self.local_pid,
        proto = proto.PROTOCOL_VER,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        current_turn = self.current_turn,
        next_send_turn = self.next_send_turn,
        want_from_turn = self:get_first_missing_remote_turn(),
        my_turns = self:collect_local_turns_since(math.max(0, self.current_turn - 2)),
        tick = (game and game.store and game.store.tick) or 0,
        hash = self.last_hash_hex,
    }
end

function M.handle_hot_resume_req(self, msg)
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

function M.handle_hot_resume_ok(self, msg)
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

function M.handle_cold_reconnect_req(self, msg)
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

function M.handle_direct_reconnect_done(self, msg)
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

function M.get_reconnect_remaining(self)
    if self.phase ~= "WAIT_RECONNECT" or (self.reconnect_deadline or 0) <= 0 then
        return 0
    end
    local now = (love and love.timer and love.timer.getTime()) or os.clock()
    return math.max(0, math.ceil(self.reconnect_deadline - now))
end

function M.update_timers(self, now)
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

function M.on_peer_disconnected(self, reason, can_reconnect, timeout_sec, is_direct)
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

return M
