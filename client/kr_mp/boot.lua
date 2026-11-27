-- KR-MP Bootstrap Module (M0 Determinism + M1 LAN + M2 Online Relay & Fast-Forward Reconnect)
local overlay = require("kr_mp.overlay")
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")

local boot = {
    initialized = false,
    source = nil,
    socket_ok = false,
    socket_info = "",
    script_hash = "00000000",
    log_file = nil,
    smoke_frames = 0,
    smoke_mode = false,
    transport = nil,
    coop = nil,
    lockstep = nil,
    lobby = nil,
    replay = nil,
    hooks = nil,
}

local function get_base_dir()
    return proto.get_writable_dir()
end

function boot:log(fmt, ...)
    local msg = string.format(fmt, ...)
    local ts = os.date("%H:%M:%S")
    local line = string.format("[%s][KR-MP] %s", ts, msg)
    print(line)
    if self.log_file then
        self.log_file:write(line .. "\n")
        self.log_file:flush()
    end
end

function boot:check_luasocket()
    local ok, socket = pcall(require, "socket")
    if not ok or not socket then
        self.socket_ok = false
        self.socket_info = "require('socket') failed: " .. tostring(socket)
        self:log("LuaSocket CHECK FAILED: %s", self.socket_info)
        return false
    end

    local tcp_ok, tcp_err = pcall(function()
        local s = assert(socket.tcp())
        assert(s:bind("127.0.0.1", 0))
        local ip, port = s:getsockname()
        s:close()
        return ip .. ":" .. tostring(port)
    end)

    local udp_ok, udp_err = pcall(function()
        local u = assert(socket.udp())
        assert(u:setsockname("127.0.0.1", 0))
        local ip, port = u:getsockname()
        u:close()
        return ip .. ":" .. tostring(port)
    end)

    self.socket_ok = tcp_ok and udp_ok
    self.socket_info = string.format("ver=%s tcp=%s(%s) udp=%s(%s)",
        tostring(socket._VERSION), tostring(tcp_ok), tostring(tcp_err), tostring(udp_ok), tostring(udp_err))
    self:log("LuaSocket CHECK: ok=%s | %s", tostring(self.socket_ok), self.socket_info)
    return self.socket_ok
end

function boot:wrap_love_callbacks()
    if self._love_wrapped then return end
    self._love_wrapped = true

    local orig_draw = love.draw
    love.draw = function(...)
        if orig_draw then orig_draw(...) end
        if self.coop and self.coop:is_active() then
            self.coop:draw_world_overlays()
        end
        overlay:draw()
        if self.lobby then
            self.lobby:draw()
        end
        overlay:draw_toast(self.lobby)
    end

    local orig_update = love.update
    love.update = function(dt, ...)
        if self.lobby then
            self.lobby:update(dt)
        end
        if self.sakura then
            self.sakura:update(dt, self.lobby)
        end
        if self.server_host then
            self.server_host:update(dt, self.lobby)
        end
        if self.voice then
            self.voice:update(dt, self.lobby, self.coop)
        end
        if orig_update then orig_update(dt, ...) end
        self:on_update(dt)
    end

    local orig_keypressed = love.keypressed
    love.keypressed = function(key, scancode, isrepeat, ...)
        if self:on_keypressed(key, isrepeat) then
            return
        end
        if orig_keypressed then
            return orig_keypressed(key, scancode, isrepeat, ...)
        end
    end

    local orig_textinput = love.textinput
    love.textinput = function(t, ...)
        if self.lobby and self.lobby:textinput(t) then
            return
        end
        if orig_textinput then
            return orig_textinput(t, ...)
        end
    end

    local orig_mousepressed = love.mousepressed
    love.mousepressed = function(x, y, button, istouch, ...)
        if self.lobby and self.lobby:mousepressed(x, y, button) then
            return
        end
        if overlay:mousepressed(x, y, button) then
            return
        end
        if orig_mousepressed then
            return orig_mousepressed(x, y, button, istouch, ...)
        end
    end

    local orig_mousereleased = love.mousereleased
    love.mousereleased = function(x, y, button, istouch, ...)
        if self.lobby and self.lobby:mousereleased(x, y, button) then
            return
        end
        if overlay:mousereleased(x, y, button) then
            return
        end
        if orig_mousereleased then
            return orig_mousereleased(x, y, button, istouch, ...)
        end
    end

    -- Android touchscreen safety: swallow raw touch gestures while Lobby is open or HUD consumed a touch press
    local orig_touchpressed = love.touchpressed
    love.touchpressed = function(id, x, y, dx, dy, pressure, ...)
        if self.lobby and self.lobby.open then
            return
        end
        if overlay:is_point_over_hud(x, y) then
            return
        end
        if orig_touchpressed then
            return orig_touchpressed(id, x, y, dx, dy, pressure, ...)
        end
    end

    local orig_touchmoved = love.touchmoved
    love.touchmoved = function(id, x, y, dx, dy, pressure, ...)
        if self.lobby and self.lobby.open then
            return
        end
        if overlay._consumed_down then
            return
        end
        if orig_touchmoved then
            return orig_touchmoved(id, x, y, dx, dy, pressure, ...)
        end
    end

    local orig_touchreleased = love.touchreleased
    love.touchreleased = function(id, x, y, dx, dy, pressure, ...)
        if self.lobby and self.lobby.open then
            return
        end
        if overlay._consumed_down then
            return
        end
        if orig_touchreleased then
            return orig_touchreleased(id, x, y, dx, dy, pressure, ...)
        end
    end

    local orig_quit = love.quit
    love.quit = function(...)
        self:log("Shutting down KR-MP...")
        if self.sakura then
            self.sakura:shutdown()
        end
        if self.server_host then
            self.server_host:shutdown()
        end
        if self.voice then
            self.voice:shutdown()
        end
        -- Do NOT send LEAVE_ROOM on window close so Online matches retain their 300s reconnect window!
        if self.transport then
            self.transport:close()
        end
        if self.lockstep then
            self.lockstep:close_hash_log()
        end
        if self.log_file then
            self.log_file:flush()
            self.log_file:close()
            self.log_file = nil
        end
        if orig_quit then return orig_quit(...) end
    end

    local orig_errhand = love.errhand
    love.errhand = function(msg)
        local tb = debug.traceback(tostring(msg), 2)
        self:log("!!! LUA CRASH !!!\n%s", tb)
        if self.log_file then
            self.log_file:flush()
            self.log_file:close()
            self.log_file = nil
        end
        if self.smoke_mode or (os.getenv("KR_MP_AUTO_VERIFY") == "1")
            or (os.getenv("KR_MP_AUTO_COOP") ~= nil)
            or (os.getenv("KR_MP_AUTO_M2") ~= nil)
            or (os.getenv("KR_MP_AUTO_SAKURA") ~= nil) then
            os.exit(1)
        end
        if orig_errhand then return orig_errhand(msg) end
    end
end

function boot:on_update(dt)
    if self.hooks and self.hooks.on_update then
        self.hooks:on_update(dt)
    end

    local mp_active = self.coop and self.coop:is_active() or false
    local local_pid = (self.coop and self.coop:is_active() and self.coop.local_pid)
        or (self.lobby and self.lobby.local_pid) or 1
    local v1_talk, v1_lvl = false, 0
    local v2_talk, v2_lvl = false, 0
    if self.voice then
        v1_talk, v1_lvl = self.voice:get_seat_state(1, local_pid)
        v2_talk, v2_lvl = self.voice:get_seat_state(2, local_pid)
    end
    local h1_idx = (self.coop and self.coop.cfg and self.coop.cfg.heroes and self.coop.cfg.heroes[1])
        or (self.lobby and self.lobby.room and self.lobby.room.heroes and self.lobby.room.heroes[1]) or 53
    local h2_idx = (self.coop and self.coop.cfg and self.coop.cfg.heroes and self.coop.cfg.heroes[2])
        or (self.lobby and self.lobby.room and self.lobby.room.heroes and self.lobby.room.heroes[2]) or 54

    local ls_waiting = (self.lockstep and self.lockstep.waiting_for_peer) == true
    local ls_wait_secs = 0
    if ls_waiting and self.lockstep and (self.lockstep.wait_start_ts or 0) > 0 then
        local now_t = love and love.timer and love.timer.getTime and love.timer.getTime() or 0
        ls_wait_secs = math.max(0, now_t - self.lockstep.wait_start_ts)
    end

    local st = {
        mp_active = mp_active,
        mp_online = self.transport and self.transport:is_online() or false,
        mp_room_code = self.lobby and self.lobby.online_room_code or nil,
        mp_pid = self.coop and self.coop.local_pid or 1,
        mp_econ = self.coop and self.coop.econ_mode or "independent",
        mp_tower_mode = self.coop and self.coop.tower_mode or "owned",
        mp_tower_marks = (self.coop == nil) or (self.coop.show_tower_marks ~= false),
        mp_g1 = self.coop and self.coop:get_player_gold(1) or 0,
        mp_g2 = self.coop and self.coop:get_player_gold(2) or 0,
        mp_rtt = self.transport and self.transport:get_rtt_ms() or 0,
        mp_delay_ms = self.lockstep and math.floor((self.lockstep.input_delay_turns or 2) * (self.lockstep.turn_ticks or 3) * (1000 / 60) + 0.5) or 100,
        mp_phase = self.lockstep and self.lockstep.phase or "IDLE",
        mp_reconnect_remain = self.lockstep and self.lockstep.get_reconnect_remaining and self.lockstep:get_reconnect_remaining() or 0,
        mp_direct_reconnect = self.lockstep and self.lockstep.direct_reconnect == true or false,
        mp_speed = self.lockstep and self.lockstep.game_speed or 1,
        mp_sync_ok = self.lockstep and self.lockstep.sync_ok_count or 0,
        mp_waiting = ls_waiting,
        mp_wait_secs = ls_wait_secs,
        mp_catchup_target = self.lockstep and self.lockstep.catchup_target_tick or 0,
        mp_voice_ok = self.voice and self.voice.supported or false,
        mp_voice_mode = self.voice and self.voice.mode or "mute",
        mp_voice_label = self.voice and self.voice:get_mode_short() or "麦:无",
        mp_voice_ptt = self.voice and self.voice.ptt_held or false,
        mp_voice_mic_gain = self.voice and self.voice.mic_gain or 1.0,
        mp_voice_peer_vol = self.voice and (self.voice.peer_muted and 0 or (self.voice.peer_volume or 1.0)) or 1.0,
        mp_voice_peer_muted = self.voice and self.voice.peer_muted or false,
        mp_voice_style = self.voice and self.voice.indicator_style or "compact",
        mp_voice_style_label = self.voice and self.voice:get_indicator_style_label() or "极简",
        mp_voice_local_lvl = self.voice and self.voice.local_level or 0,
        mp_voice_p1_talk = v1_talk,
        mp_voice_p1_lvl = v1_lvl,
        mp_voice_p2_talk = v2_talk,
        mp_voice_p2_lvl = v2_lvl,
        mp_hero1 = h1_idx,
        mp_hero2 = h2_idx,

        mode = self.replay and self.replay:get_mode() or "IDLE",
        tick = (game and game.store and game.store.tick) or 0,
        max_tick = self.replay and self.replay:get_max_tick() or 0,
        replay_speed = self.replay and self.replay:get_replay_speed() or 1,
        has_replay = self.replay and self.replay:has_saved_replay() or false,
        last_hash = mp_active
            and (self.lockstep and self.lockstep.last_hash_hex or "--------")
            or (self.replay and self.replay:get_last_hash_hex() or "--------"),
        socket_ok = self.socket_ok,
        cmd_count = self.replay and self.replay:get_cmd_count() or 0,
        seed = mp_active
            and (self.coop and self.coop.cfg and self.coop.cfg.seed or 0)
            or (self.replay and self.replay:get_seed() or 0),
        extra = self.replay and self.replay:get_hud_extra() or "",
    }
    overlay:set_status(st)

    if self.smoke_mode then
        self.smoke_frames = self.smoke_frames + 1
        if self.smoke_frames >= 5 then
            self:log("SMOKE_TEST_PASSED frames=%d fl_version=%s", self.smoke_frames, tostring(KR_FL_VERSION))
            love.event.quit()
        end
    end
end

function boot:on_keypressed(key, isrepeat)
    if isrepeat then return false end
    -- Global quick voice mute hotkey (M) when in room or battle & not typing into an input field
    local typing = (self.lobby ~= nil and self.lobby.open == true and self.lobby.focused_field ~= nil)
    local in_voice_ctx = (self.coop and self.coop:is_active()) or (self.lobby and self.lobby.view == "room")
    if not typing and in_voice_ctx and self.voice and self.voice.supported then
        if key == "m" then
            self.voice:toggle_mute()
            if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
            overlay:show_toast(self.voice:get_mode_toast(), 2.0)
            return true
        elseif key == "v" and self.voice.mode == "ptt" and not (self.lobby and self.lobby.open) then
            return true
        end
    end
    if self.lobby and self.lobby:keypressed(key) then
        return true
    end
    if key == "f9" then
        overlay.visible = not overlay.visible
        return true
    end
    if not (self.coop and self.coop:is_active()) then
        if self.replay and self.replay.on_keypressed then
            if self.replay:on_keypressed(key) then
                return true
            end
        end
    end
    return false
end

function boot:on_hud_action(action_id, arg)
    self:log("HUD ACTION: %s", tostring(action_id))
    if action_id == "hide" then
        overlay.visible = not overlay.visible
        if not overlay.visible then overlay.voice_panel_open = false end
    elseif action_id == "lobby" and self.lobby then
        self.lobby:toggle()
    elseif action_id == "mp_send_gold" and self.lockstep and self.lockstep:is_active() then
        local amt = (tonumber(arg) == 200) and 200 or 50
        self.lockstep:queue_local_command({ op = "SEND_GOLD", amount = amt })
    elseif action_id == "mp_cycle_delay" and self.lockstep and self.lockstep:is_active() then
        self.lockstep:request_cycle_delay()
    elseif action_id == "mp_return_lobby" and self.lobby then
        overlay.voice_panel_open = false
        self.lobby:return_to_lobby()
    elseif action_id == "mp_speed" and self.lockstep and self.lockstep:is_active() then
        self.lockstep:request_toggle_speed()
    elseif action_id == "mp_pause" and self.lockstep and self.lockstep:is_active() then
        self.lockstep:request_toggle_pause()
    elseif action_id == "mp_tower_marks" and self.coop then
        self.coop.show_tower_marks = not self.coop.show_tower_marks
        if self.lobby and self.lobby.save_prefs then
            self.lobby:save_prefs()
        end
        overlay:show_toast(self.coop.show_tower_marks and "已开启：防御塔底座红蓝归属标志" or "已关闭：防御塔归属标志（纯净画面，仅对你自己生效）", 2.0)
    elseif action_id == "mp_voice_mode" and self.voice then
        if not self.voice.supported then
            overlay:show_toast("当前环境不支持内置语音连麦。", 2.2)
        else
            self.voice:cycle_mode()
            if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
            overlay:show_toast(self.voice:get_mode_toast(), 2.4)
        end
    elseif action_id == "mp_voice_set_mode" and self.voice and type(arg) == "string" then
        if self.voice.supported then
            self.voice:set_mode(arg)
            if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
        end
    elseif action_id == "mp_voice_mic_down" and self.voice then
        self.voice:step_mic_gain(-0.2)
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_mic_up" and self.voice then
        self.voice:step_mic_gain(0.2)
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_mic_set" and self.voice and tonumber(arg) then
        self.voice:set_mic_gain(tonumber(arg))
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_peer_down" and self.voice then
        self.voice:step_peer_volume(-0.2)
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_peer_up" and self.voice then
        self.voice:step_peer_volume(0.2)
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_peer_set" and self.voice and tonumber(arg) then
        self.voice:set_peer_volume(tonumber(arg))
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_peer_mute" and self.voice then
        self.voice:toggle_peer_mute()
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_style_set" and self.voice and type(arg) == "string" then
        self.voice:set_indicator_style(arg)
        if self.lobby and self.lobby.save_prefs then self.lobby:save_prefs() end
    elseif action_id == "mp_voice_ptt_down" and self.voice then
        self.voice:set_touch_ptt(true)
    elseif action_id == "mp_voice_ptt_up" and self.voice then
        self.voice:set_touch_ptt(false)
    elseif action_id == "mp_leave" and self.lobby then
        overlay.voice_panel_open = false
        self.lobby:leave_room()
    elseif action_id == "record" and self.replay then
        self.replay:start_record()
    elseif action_id == "replay" and self.replay then
        self.replay:start_replay()
    elseif action_id == "stop" and self.replay then
        self.replay:stop_current()
    elseif action_id == "speed" and self.replay then
        self.replay:cycle_replay_speed()
    end
end

function boot:init(source)
    if self.initialized then
        return self
    end
    self.initialized = true
    self.source = source or "unknown"
    self.smoke_mode = (os.getenv("KR_MP_SMOKE_TEST") == "1")

    -- Lock deterministic 60Hz sim tick on Android high-refresh phones (120Hz/144Hz)
    if proto.is_android() then
        if DRAW_FPS ~= 60 then
            DRAW_FPS = 60
            TICK_LENGTH = 1 / 60
        end
        if main and main.params and main.params.fps ~= 60 then
            main.params.fps = 60
        end
    end

    local base = get_base_dir()
    local env_log = os.getenv("KR_MP_LOG_FILE")
    local log_path = env_log or proto.path_join(base, "kr_mp.log")
    -- Keep previous run's log as kr_mp_prev.log so crash stacks survive a restart before collecting bug report
    if not env_log then
        local prev_in = io.open(log_path, "rb")
        if prev_in then
            local prev_data = prev_in:read("*a")
            prev_in:close()
            if prev_data and #prev_data > 0 then
                local prev_out = io.open(proto.path_join(base, "kr_mp_prev.log"), "wb")
                if prev_out then
                    prev_out:write(prev_data)
                    prev_out:close()
                end
            end
        end
    end
    self.log_file = io.open(log_path, "w")
    self.script_hash = proto.compute_script_hash()

    local os_name = (love and love.system and love.system.getOS and love.system.getOS()) or "unknown"
    local lv_str = "?"
    if love and love.getVersion then
        local maj, min, rev = love.getVersion()
        lv_str = string.format("%s.%s.%s", tostring(maj), tostring(min), tostring(rev))
    end
    self:log("=== KR-MP v%s Booting (entry=%s, os=%s, love=%s, FL=%s, hash=%s, font=%s) ===",
        proto.MOD_VERSION, self.source, os_name, lv_str, tostring(KR_FL_VERSION), self.script_hash, fonts.get_path())
    self:log("Base dir: %s | Save dir: %s", base,
        (love.filesystem and love.filesystem.getSaveDirectory and love.filesystem.getSaveDirectory()) or "?")

    overlay:init(function(action_id, arg)
        self:on_hud_action(action_id, arg)
    end)
    self:check_luasocket()
    self:wrap_love_callbacks()

    -- Load M0 Replay + M1/M2 Co-op Networking & Lockstep modules
    local ok_r, replay_mod = pcall(require, "kr_mp.replay")
    if ok_r and replay_mod then
        self.replay = replay_mod
        pcall(replay_mod.init, replay_mod, self, overlay)
    else
        self:log("ERROR loading kr_mp.replay: %s", tostring(replay_mod))
    end

    local ok_t, transport_mod = pcall(require, "kr_mp.transport")
    local ok_c, coop_mod = pcall(require, "kr_mp.coop")
    local ok_l, lockstep_mod = pcall(require, "kr_mp.lockstep")
    local ok_lb, lobby_mod = pcall(require, "kr_mp.lobby_ui")
    local ok_v, voice_mod = pcall(require, "kr_mp.voice")
    local ok_sk, sakura_mod = pcall(require, "kr_mp.sakura")
    local ok_sh, server_host_mod = pcall(require, "kr_mp.server_host")

    if ok_t and ok_c and ok_l and ok_lb then
        self.transport = transport_mod
        self.coop = coop_mod
        self.lockstep = lockstep_mod
        self.lobby = lobby_mod
        self.transport:init(self)
        if ok_v and voice_mod then
            self.voice = voice_mod
            pcall(voice_mod.init, voice_mod, self, self.transport)
            self.lobby.voice = self.voice
        else
            self:log("ERROR loading kr_mp.voice: %s", tostring(voice_mod))
        end
        if ok_sk and sakura_mod then
            self.sakura = sakura_mod
            pcall(sakura_mod.init, sakura_mod, self, overlay)
            self.lobby.sakura = self.sakura
        else
            self:log("ERROR loading kr_mp.sakura: %s", tostring(sakura_mod))
        end
        if ok_sh and server_host_mod then
            self.server_host = server_host_mod
            pcall(server_host_mod.init, server_host_mod, self, overlay)
            self.lobby.server_host = self.server_host
        else
            self:log("ERROR loading kr_mp.server_host: %s", tostring(server_host_mod))
        end
        self.coop:init(self, self.lockstep, overlay)
        self.lockstep:init(self, self.transport, self.coop, overlay)
        self.lobby:init(self, self.transport, self.lockstep, self.coop, overlay)
        self:log("M2 Co-op modules loaded (LAN+Online Transport + SakuraFrp + Lockstep Reconnect + Co-op + Lobby + Voice).")
    else
        self:log("ERROR loading M2 modules: t=%s c=%s l=%s lb=%s",
            tostring(transport_mod), tostring(coop_mod), tostring(lockstep_mod), tostring(lobby_mod))
    end

    local ok_h, hooks_mod = pcall(require, "kr_mp.hooks")
    if ok_h and hooks_mod then
        self.hooks = hooks_mod
        local ok_hi, hi_err = pcall(hooks_mod.init, hooks_mod, self, self.replay, overlay, self.coop, self.lockstep)
        if not ok_hi then self:log("ERROR hooks:init: %s", tostring(hi_err)) end
    else
        self:log("ERROR loading kr_mp.hooks: %s", tostring(hooks_mod))
    end

    if proto.is_android() then
        overlay:show_toast("王国保卫战 FL 联机补丁已就绪！点左上角「联机大厅」即可双人开黑！", 4.5)
    else
        overlay:show_toast("王国保卫战 FL 联机补丁已就绪！点击「联机大厅 (F10)」即可双人联机！", 5)
    end
    self:log("KR-MP v%s initialization complete.", proto.MOD_VERSION)
    return self
end

custom_script = custom_script or {}
function custom_script:init()
    boot:init("custom_script")
end

return boot
