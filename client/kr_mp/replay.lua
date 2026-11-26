-- M0 Deterministic Recorder, Replayer & Live Checksum Verifier
local prng = require("kr_mp.prng")
local state_hash = require("kr_mp.state_hash")
local commands = require("kr_mp.commands")

local replay = {
    mode = "IDLE", -- "IDLE" | "RECORDING" | "REPLAYING" | "VERIFIED_OK" | "DESYNC"
    pending_action = nil, -- "RECORD" | "REPLAY"
    seed = 123456,
    replay_speed = 1, -- 1 or 4 (toggled with F5 during replay)
    recorded_cmds = {},
    recorded_hashes = {},
    meta = nil,
    loaded_rep = nil,
    slot_snapshot = nil,
    last_hash_hex = "--------",
    hash_log_file = nil,
    verified_count = 0,
    total_checkpoints = 0,
    desync_info = nil,
    auto_verify = false,
    auto_stage = nil,
    boot = nil,
    overlay = nil,
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

local function serialize_lua(val, indent)
    indent = indent or ""
    local t = type(val)
    if t == "number" then
        if val ~= val then return "0" end
        return string.format("%.14g", val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local keys = {}
        local is_array = true
        local max_i = 0
        local count = 0
        for k in pairs(val) do
            count = count + 1
            if type(k) == "number" and k >= 1 and math.floor(k) == k then
                if k > max_i then max_i = k end
            else
                is_array = false
            end
            keys[#keys + 1] = k
        end
        if is_array and max_i == count and count > 0 then
            local parts = {}
            for i = 1, count do
                parts[i] = serialize_lua(val[i], indent .. "  ")
            end
            if #parts <= 6 and #indent > 4 then
                return "{ " .. table.concat(parts, ", ") .. " }"
            end
            return "{\n" .. indent .. "  " .. table.concat(parts, ",\n" .. indent .. "  ") .. "\n" .. indent .. "}"
        end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta ~= tb then return ta < tb end
            return a < b
        end)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            local ks
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                ks = k
            else
                ks = "[" .. serialize_lua(k, "") .. "]"
            end
            parts[#parts + 1] = indent .. "  " .. ks .. " = " .. serialize_lua(val[k], indent .. "  ")
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
    return "nil"
end

function replay:get_paths()
    local proto = require("kr_mp.proto")
    local base = proto.get_writable_dir()
    local rep_dir = os.getenv("KR_MP_REPLAY_DIR") or proto.path_join(base, "replays")
    local log_file = os.getenv("KR_MP_LOG_FILE")
    local log_dir = log_file and log_file:match("^(.*)[/\\][^/\\]+$") or proto.path_join(base, "logs")
    return {
        rep_file = proto.path_join(rep_dir, "last.rep"),
        rec_hash_log = proto.path_join(log_dir, "record_hashes.log"),
        rep_hash_log = proto.path_join(log_dir, "replay_hashes.log"),
    }
end

function replay:init(boot, overlay)
    self.boot = boot
    self.overlay = overlay
    self.auto_verify = (os.getenv("KR_MP_AUTO_VERIFY") == "1")
    self.auto_replay_saved = (os.getenv("KR_MP_AUTO_REPLAY_SAVED") == "1")
    if self.auto_verify then
        self.boot:log("AUTO_VERIFY mode enabled!")
    end
    if self.auto_replay_saved then
        self.boot:log("AUTO_REPLAY_SAVED mode enabled!")
        prng.on_trace = function(msg) self.boot:log("%s", msg) end
    end
end

function replay:get_mode()
    return self.mode
end

function replay:is_active()
    return self.mode == "RECORDING" or self.mode == "REPLAYING"
end

function replay:is_recording()
    return self.mode == "RECORDING"
end

function replay:is_replaying()
    return self.mode == "REPLAYING"
end

function replay:get_last_hash_hex()
    return self.last_hash_hex
end

function replay:get_cmd_count()
    if self.mode == "RECORDING" then
        return #self.recorded_cmds
    elseif self.loaded_rep and self.loaded_rep.commands then
        return #self.loaded_rep.commands
    end
    return 0
end

function replay:get_seed()
    return self.seed or 0
end

function replay:get_replay_speed()
    if self.auto_verify or self.auto_replay_saved then
        return 25
    end
    return self.replay_speed or 2
end

function replay:get_max_tick()
    if self.loaded_rep and self.loaded_rep.meta then
        return self.loaded_rep.meta.max_tick or 0
    end
    return 0
end

function replay:has_saved_replay()
    if self._has_saved_cached ~= nil then
        return self._has_saved_cached
    end
    local paths = self:get_paths()
    local f = io.open(paths.rep_file, "r")
    if f then
        f:close()
        self._has_saved_cached = true
        return true
    end
    self._has_saved_cached = false
    return false
end

function replay:cycle_replay_speed()
    if self.mode ~= "REPLAYING" then
        self.overlay:show_toast("Speed switch (F5) only works during REPLAY!", 2.5)
        return
    end
    if self.replay_speed == 1 then
        self.replay_speed = 2
    elseif self.replay_speed == 2 then
        self.replay_speed = 4
    else
        self.replay_speed = 1
    end
    self.boot:log("Replay speed changed to %dx", self.replay_speed)
    self.overlay:show_toast("Replay speed: " .. self.replay_speed .. "x", 2.5)
end

function replay:get_next_cmd_tick(cur_tick)
    if not self.loaded_rep or not self.loaded_rep.commands then return nil end
    for _, c in ipairs(self.loaded_rep.commands) do
        if c.tick and c.tick > cur_tick then
            return c.tick
        end
    end
    return nil
end

function replay:get_hud_extra()
    if self.mode == "REPLAYING" then
        local cur = (game and game.store and game.store.tick) or 0
        local max_t = self:get_max_tick()
        local pct = (max_t > 0) and math.floor(cur * 100 / max_t) or 0
        local nxt = self:get_next_cmd_tick(cur)
        local nxt_str = nxt and string.format(" NextCmd@%d", nxt) or " (End)"
        return string.format("| %d/%d (%d%%) OK:%d/%d%s",
            cur, max_t, pct, self.verified_count, self.total_checkpoints, nxt_str)
    elseif self.mode == "VERIFIED_OK" then
        return string.format("· 回放 100%% 匹配 %d/%d", self.verified_count, self.total_checkpoints)
    elseif self.mode == "DESYNC" and self.desync_info then
        return string.format("· 分叉 @ 帧 %d", self.desync_info.tick)
    elseif self.mode == "RECORDING" then
        return "· 录制中（按 F8 保存）"
    end
    return "· 按 F10 呼出双人联机战桌"
end

function replay:get_slot_override()
    if self.mode == "REPLAYING" or self.pending_action == "REPLAY" then
        if self.slot_snapshot then
            return deep_copy(self.slot_snapshot)
        end
    end
    return nil
end

function replay:close_hash_log()
    if self.hash_log_file then
        self.hash_log_file:flush()
        self.hash_log_file:close()
        self.hash_log_file = nil
    end
end

function replay:in_battle()
    return game ~= nil and game.store ~= nil and game.simulation ~= nil
        and main ~= nil and main.handler ~= nil and main.handler.active_item == game
end

function replay:start_record()
    if self.mode == "RECORDING" then
        self.overlay:show_toast("Already RECORDING! Click STOP & SAVE (F8) first.", 3)
        return
    end
    if not self:in_battle() then
        self.overlay:show_toast("Please enter a level first, then click REC START (F6)!", 3.5)
        return
    end

    self:close_hash_log()
    local storage = require("storage")
    local raw_slot = storage:load_slot(nil, true)
    self.slot_snapshot = raw_slot and deep_copy(raw_slot) or nil

    self.seed = (os.time() % 900000) + 100000
    self.pending_action = "RECORD"
    self.recorded_cmds = {}
    self.recorded_hashes = {}
    self.last_hash_hex = "--------"
    self.desync_info = nil

    self.boot:log("Triggering clean restart for RECORDING (seed=%d, level=%s)", self.seed, tostring(game.store.level_idx))
    game:restart()
end

local function ensure_parent_dir(file_path)
    local dir = tostring(file_path or ""):match("^(.*)[/\\][^/\\]+$")
    if not dir or #dir == 0 then return end
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi and ffi.os == "Windows" then
        pcall(function()
            ffi.cdef[[ int CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes); ]]
        end)
        pcall(ffi.C.CreateDirectoryA, dir, nil)
    elseif love and love.filesystem and love.filesystem.createDirectory then
        local leaf = dir:match("([^/\\]+)$")
        if leaf then pcall(love.filesystem.createDirectory, leaf) end
    end
end

function replay:save_recording(final_tick)
    local paths = self:get_paths()
    ensure_parent_dir(paths.rep_file)
    if self.meta then
        self.meta.max_tick = final_tick or (game and game.store and game.store.tick) or 0
    end
    local payload = {
        meta = self.meta,
        commands = self.recorded_cmds,
        hashes = self.recorded_hashes,
        slot_snapshot = self.slot_snapshot,
    }
    local f, err = io.open(paths.rep_file, "w")
    if not f then
        local proto = require("kr_mp.proto")
        local fallback = proto.path_join(proto.get_writable_dir(), "kr_mp_last.rep")
        f, err = io.open(fallback, "w")
        if f then paths.rep_file = fallback end
    end
    if not f then
        self.boot:log("ERROR saving replay file %s: %s", paths.rep_file, tostring(err))
        self.overlay:show_toast("ERROR saving replay: " .. tostring(err), 4)
        return false
    end
    f:write("-- KR-MP M0 Replay File\nreturn " .. serialize_lua(payload) .. "\n")
    f:flush()
    f:close()
    self._has_saved_cached = true
    self.boot:log("Saved replay: %s (ticks=%d, cmds=%d, checkpoints=%d)",
        paths.rep_file, self.meta and self.meta.max_tick or 0, #self.recorded_cmds, self:count_table(self.recorded_hashes))
    return true
end

function replay:count_table(t)
    local c = 0
    for _ in pairs(t or {}) do c = c + 1 end
    return c
end

function replay:stop_current()
    if self.mode == "RECORDING" then
        local ticks = (game and game.store and game.store.tick) or 0
        self:close_hash_log()
        local ok = self:save_recording(ticks)
        self.mode = "IDLE"
        if ok then
            self.overlay:show_toast(string.format("SAVED %d ticks (%d cmds)! Now click REPLAY (F7)!", ticks, #self.recorded_cmds), 6)
        end
    elseif self.mode == "REPLAYING" or self.mode == "VERIFIED_OK" or self.mode == "DESYNC" then
        self.boot:log("Stopping %s -> IDLE (resuming game)", tostring(self.mode))
        self:close_hash_log()
        self.mode = "IDLE"
        self.slot_snapshot = nil
        if game and game.store then
            game.store.paused = false
        end
        self.overlay:show_toast("Exited replay & resumed game.", 3)
    else
        self.overlay:show_toast("Already IDLE. Click REC START (F6) or REPLAY (F7).", 2.5)
    end
end

function replay:load_replay_file()
    local paths = self:get_paths()
    local fn, err = loadfile(paths.rep_file)
    if not fn then
        return nil, "Cannot read " .. paths.rep_file .. ": " .. tostring(err)
    end
    setfenv(fn, {})
    local ok, data = pcall(fn)
    if not ok or type(data) ~= "table" or not data.meta then
        return nil, "Corrupt replay file: " .. tostring(data)
    end
    return data, nil
end

function replay:start_replay()
    if not self:in_battle() then
        self.overlay:show_toast("Please enter the recorded level first, then click REPLAY (F7)!", 3.5)
        return
    end

    if self.mode == "RECORDING" then
        self:stop_current()
    end

    local rep, err = self:load_replay_file()
    if not rep then
        self.boot:log("Load replay failed: %s", tostring(err))
        self.overlay:show_toast("No replay found! Press F6 to record first.", 4)
        return
    end

    if game.store.level_idx ~= rep.meta.level_idx then
        self.overlay:show_toast(string.format("Replay is for Level %d (you are in Level %d)!",
            rep.meta.level_idx, game.store.level_idx or 0), 4.5)
        return
    end

    self:close_hash_log()
    self.loaded_rep = rep
    self.slot_snapshot = rep.slot_snapshot
    self.seed = rep.meta.seed
    self.replay_speed = 2
    self.verified_count = 0
    self.total_checkpoints = self:count_table(rep.hashes)
    self.desync_info = nil
    self.last_hash_hex = "--------"
    self.pending_action = "REPLAY"

    self.boot:log("Triggering clean restart for REPLAY (seed=%d, max_tick=%d, cmds=%d, checkpoints=%d)",
        self.seed, rep.meta.max_tick or 0, #(rep.commands or {}), self.total_checkpoints)
    game:restart()
end

function replay:on_before_sim_init(store)
    commands:reset()
    if self.pending_action == "RECORD" then
        self.pending_action = nil
        self.mode = "RECORDING"
        prng:seed_sim(self.seed)

        local paths = self:get_paths()
        self:close_hash_log()
        self.hash_log_file = io.open(paths.rec_hash_log, "w")

        self.meta = {
            fl_version = tostring(KR_FL_VERSION),
            level_idx = store.level_idx,
            level_mode = store.level_mode,
            level_difficulty = store.level_difficulty,
            tick_length = TICK_LENGTH,
            seed = self.seed,
            max_tick = 0,
        }
        if self.hash_log_file then
            self.hash_log_file:write(string.format("# RECORD seed=%d level=%d mode=%d diff=%d tick_length=%.12f\n",
                self.seed, store.level_idx or 0, store.level_mode or 0, store.level_difficulty or 0, TICK_LENGTH or 0))
            self.hash_log_file:flush()
        end
        self.boot:log("RECORDING started (seed=%d, tick_length=%.6f)", self.seed, TICK_LENGTH or 0)
        self.overlay:show_toast(string.format("RECORDING (Seed %d) - Play normally, press F8 when done", self.seed), 4.5)

    elseif self.pending_action == "REPLAY" then
        self.pending_action = nil
        self.mode = "REPLAYING"
        prng:seed_sim(self.seed)
        commands:load_schedule(self.loaded_rep.commands)

        local paths = self:get_paths()
        self:close_hash_log()
        self.hash_log_file = io.open(paths.rep_hash_log, "w")
        if self.hash_log_file then
            self.hash_log_file:write(string.format("# REPLAY seed=%d level=%d max_tick=%d tick_length=%.12f\n",
                self.seed, store.level_idx or 0, self.loaded_rep.meta.max_tick or 0, TICK_LENGTH or 0))
            self.hash_log_file:flush()
        end
        self.boot:log("REPLAYING started (seed=%d, max_tick=%d)", self.seed, self.loaded_rep.meta.max_tick or 0)
        self.overlay:show_toast("REPLAYING... Hands off! Press F5 for 4x speed, F8 to stop", 4.5)
    else
        -- Normal battle start (IDLE): still seed cleanly and reset state
        if self.mode ~= "IDLE" then
            self:close_hash_log()
            self.mode = "IDLE"
            self.slot_snapshot = nil
        end
        self.seed = (os.time() % 900000) + 100000
        prng:seed_sim(self.seed)
    end
end

function replay:on_after_sim_init(store)
    if self.auto_verify and not self.auto_stage then
        self.auto_stage = "TRIGGER_REC"
    elseif self.auto_replay_saved and not self.auto_stage then
        self.auto_stage = "TRIGGER_REPLAY"
    end
end

function replay:record_command(cmd)
    if self.mode ~= "RECORDING" or not game or not game.store then
        return false
    end
    local target_tick = (game.store.tick or 0) + 1
    local queued = commands:enqueue(target_tick, cmd)
    self.recorded_cmds[#self.recorded_cmds + 1] = deep_copy(queued)
    self.boot:log("REC CMD tick=%d seq=%d op=%s id=%s arg=%s pos=(%s,%s)",
        queued.tick, queued.seq, tostring(queued.op), tostring(queued.id or queued.idx or ""),
        tostring(queued.arg or queued.phase or ""), tostring(queued.wx or ""), tostring(queued.wy or ""))
    return true
end

function replay:on_tick_end(store)
    local tick = store.tick or 0

    if tick > 0 and tick % 30 == 0 then
        if self.mode == "RECORDING" then
            local snap = state_hash.compute(store, prng)
            self.last_hash_hex = snap.hash
            self.recorded_hashes[tick] = snap
            if self.hash_log_file then
                self.hash_log_file:write(state_hash.format_line(snap) .. "\n")
                self.hash_log_file:flush()
            end
        elseif self.mode == "REPLAYING" then
            local snap = state_hash.compute(store, prng)
            self.last_hash_hex = snap.hash
            if self.hash_log_file then
                self.hash_log_file:write(state_hash.format_line(snap) .. "\n")
                self.hash_log_file:flush()
            end

            local expected = self.loaded_rep and self.loaded_rep.hashes and self.loaded_rep.hashes[tick]
            if expected then
                if snap.hash ~= expected.hash then
                    self.mode = "DESYNC"
                    self.desync_info = { tick = tick, expected = expected, actual = snap }
                    store.paused = true
                    self:close_hash_log()
                    self.boot:log("!!! DESYNC DETECTED AT TICK %d !!!", tick)
                    self.boot:log("  EXPECTED: %s", state_hash.format_line(expected))
                    self.boot:log("  ACTUAL  : %s", state_hash.format_line(snap))
                    self:dump_entities_snapshot(store)
                    self.overlay:show_toast(string.format("DESYNC @ Tick %d! Exp:%s Got:%s", tick, expected.hash, snap.hash), 15)
                    if self.auto_verify or self.auto_replay_saved then
                        self.boot:log("AUTO_VERIFY_FAILED desync_tick=%d", tick)
                        love.event.quit()
                    end
                    return
                else
                    self.verified_count = self.verified_count + 1
                end
            end
        end
    end

    if self.mode == "REPLAYING" and self.loaded_rep and self.loaded_rep.meta then
        local max_tick = self.loaded_rep.meta.max_tick or 0
        if tick >= max_tick then
            self:close_hash_log()
            self.mode = "VERIFIED_OK"
            self.slot_snapshot = nil
            store.paused = true
            self.boot:log("REPLAY_VERIFIED_OK ticks=%d checkpoints=%d/%d cmds=%d",
                tick, self.verified_count, self.total_checkpoints, #(self.loaded_rep.commands or {}))
            self.overlay:show_toast(string.format("100%% DETERMINISTIC! %d/%d hashes matched (%d ticks)",
                self.verified_count, self.total_checkpoints, tick), 15)
            if self.auto_verify or self.auto_replay_saved then
                love.event.quit()
            end
        end
    end

    -- Auto-verify synthetic test driver (only active when KR_MP_AUTO_VERIFY=1)
    if self.auto_verify then
        self:step_auto_verify(store)
    end
end

function replay:dump_entities_snapshot(store)
    local E = require("entity_db")
    local ids = {}
    for id, e in pairs(store.entities) do
        if type(id) == "number" and e and not e._kr_mp_local and (e.enemy or e.soldier or e.hero or e.tower or e.bullet) then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    self.boot:log("  Live combat entities (%d), E.last_id=%s:", #ids, tostring(E and E.last_id))
    for i = 1, math.min(#ids, 25) do
        local e = store.entities[ids[i]]
        self.boot:log("    id=%d tpl=%s pos=(%.2f,%.2f) hp=%s ni=%s spent=%s",
            e.id, tostring(e.template_name),
            e.pos and e.pos.x or 0, e.pos and e.pos.y or 0,
            e.health and tostring(e.health.hp) or "-",
            e.nav_path and tostring(e.nav_path.ni) or "-",
            e.tower and tostring(e.tower.spent) or "-")
    end
end

function replay:on_game_destroy()
    if self.mode == "RECORDING" then
        self:stop_current()
    else
        self:close_hash_log()
        self.mode = "IDLE"
        self.slot_snapshot = nil
    end
end

function replay:on_keypressed(key)
    if key == "f6" then
        self.boot:log("KEYPRESS: f6 (mode=%s)", tostring(self.mode))
        self:start_record()
        return true
    elseif key == "f7" then
        self.boot:log("KEYPRESS: f7 (mode=%s)", tostring(self.mode))
        self:start_replay()
        return true
    elseif key == "f8" then
        self.boot:log("KEYPRESS: f8 (mode=%s)", tostring(self.mode))
        self:stop_current()
        return true
    elseif key == "f5" then
        self.boot:log("KEYPRESS: f5 (mode=%s)", tostring(self.mode))
        self:cycle_replay_speed()
        return true
    end
    return false
end

-- Automated self-verification test sequence (only runs when KR_MP_AUTO_VERIFY=1)
function replay:on_frame_update()
    if not self.auto_verify and not self.auto_replay_saved then return end
    if self.auto_stage == "TRIGGER_REC" and self:in_battle() then
        self.auto_stage = "REC_RUNNING"
        self:start_record()
    elseif self.auto_stage == "TRIGGER_REPLAY" and self:in_battle() then
        self.auto_stage = "REPLAY_RUNNING"
        self:start_replay()
    end
end

local function find_sorted_entities(store, pred)
    local out = {}
    for id, e in pairs(store.entities) do
        if type(id) == "number" and e and pred(e) then
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function replay:step_auto_verify(store)
    if self.mode ~= "RECORDING" or self.auto_stage ~= "REC_RUNNING" then
        return
    end
    local tick = store.tick
    local E = require("entity_db")

    if tick == 10 and game and game.game_gui then
        -- Actively stress-test local GUI hover/marker/ghost entities ONLY during RECORDING (never during REPLAY)
        local holders = find_sorted_entities(store, function(e)
            return e.tower and e.template_name and string.find(e.template_name, "tower_holder", 1, true) ~= nil
        end)
        if holders[1] then
            pcall(game.game_gui.show_clickable_hover, game.game_gui, holders[1])
            pcall(game.game_gui.hide_clickable_hover, game.game_gui)
            pcall(game.game_gui.show_clickable_hover, game.game_gui, holders[2] or holders[1])
        end
    elseif tick == 15 or tick == 25 or tick == 35 then
        local holders = find_sorted_entities(store, function(e)
            return e.tower and e.template_name and string.find(e.template_name, "tower_holder", 1, true) ~= nil
        end)
        local choice_idx = (tick == 15) and 1 or ((tick == 25) and 2 or 3)
        local tpl_choices = { "tower_build_archer", "tower_build_barrack", "tower_build_mage" }
        local target_tpl = tpl_choices[choice_idx]
        if holders[1] and E.entities[target_tpl] then
            self:record_command({ op = "TW_UPGRADE", id = holders[1].id, arg = target_tpl })
        end
    elseif tick == 40 then
        local heroes = find_sorted_entities(store, function(e) return e.hero and e.nav_rally end)
        for idx, h in ipairs(heroes) do
            self:record_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 20 * idx, wy = h.pos.y - 10 })
        end
    elseif tick == 45 then
        self:record_command({ op = "SEND_WAVE" })
    elseif tick == 300 then
        -- Also select a barrack during RECORDING to spawn entity_marker_controller + soldier decals
        if game and game.game_gui then
            local barracks = find_sorted_entities(store, function(e) return e.barrack ~= nil end)
            if barracks[1] then
                pcall(game.game_gui.select_entity, game.game_gui, barracks[1])
            end
            pcall(game.game_gui.show_ghost_hover, game.game_gui)
        end
        local heroes = find_sorted_entities(store, function(e) return e.hero end)
        if heroes[1] and game.game_gui and game.game_gui.power_2 then
            self:record_command({ op = "POWER_FIRE", idx = 2, wx = heroes[1].pos.x, wy = heroes[1].pos.y })
        end
    elseif tick == 600 then
        if game and game.game_gui then
            pcall(game.game_gui.hide_ghost_hover, game.game_gui)
            pcall(game.game_gui.deselect_entity, game.game_gui)
        end
    elseif tick == 900 then
        -- Upgrade first built archer tower if present and affordable
        local archers = find_sorted_entities(store, function(e)
            return e.tower and e.template_name == "tower_archer_1"
        end)
        if archers[1] and E.entities["tower_archer_2"] and (store.player_gold or 0) >= 110 then
            self:record_command({ op = "TW_UPGRADE", id = archers[1].id, arg = "tower_archer_2" })
        end
    elseif tick == 1200 then
        self:record_command({ op = "SEND_WAVE" })
    elseif tick == 1500 then
        -- Fire Power 1 (Hero 1 ultimate or lightning) on first live enemy if any
        local enemies = find_sorted_entities(store, function(e) return e.enemy and e.health and not e.health.dead end)
        local tgt = enemies[1]
        if tgt and game.game_gui and game.game_gui.power_1 then
            self:record_command({ op = "POWER_FIRE", idx = 1, wx = tgt.pos.x, wy = tgt.pos.y })
        end
    elseif tick == 1800 then
        -- Fire Power 3 (Hero 2 ultimate) if available
        local enemies = find_sorted_entities(store, function(e) return e.enemy and e.health and not e.health.dead end)
        local tgt = enemies[1]
        if tgt and game.game_gui and game.game_gui.power_3 then
            self:record_command({ op = "POWER_FIRE", idx = 3, wx = tgt.pos.x, wy = tgt.pos.y })
        end
    elseif tick == 2100 then
        -- Sell one built tower to stress sell + refund + holder respawn
        local built = find_sorted_entities(store, function(e)
            return e.tower and e.tower.can_be_sold and e.template_name and not string.find(e.template_name, "tower_holder", 1, true)
        end)
        if built[1] then
            self:record_command({ op = "TW_SELL", id = built[1].id })
        end
    elseif tick >= 3000 then
        -- Stop recording at tick 3000 (100 checkpoints) and immediately launch Replay!
        self:close_hash_log()
        self:save_recording(tick)
        self.mode = "IDLE"
        self.auto_stage = "TRIGGER_REPLAY"
    end
end

return replay
