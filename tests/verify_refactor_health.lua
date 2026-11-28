local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Unit verifier for P1+P2+P3 anti-spaghetti refactoring
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local pass_cnt, fail_cnt = 0, 0
local function check(cond, msg)
    if cond then
        pass_cnt = pass_cnt + 1
    else
        fail_cnt = fail_cnt + 1
        print("FAIL: " .. tostring(msg))
    end
end

-- 1. win_util shared helpers & WinINet source compile check
local win_util = require("kr_mp.win_util")
check(type(win_util.is_windows) == "function", "win_util.is_windows exists")
check(win_util.is_ascii_path("D:\\FL8.2.0\\kr_mp"), "win_util.is_ascii_path true on ascii")
check(not win_util.is_ascii_path("D:\\中文\\kr_mp"), "win_util.is_ascii_path false on utf8")
check(not win_util.is_ascii_path(""), "win_util.is_ascii_path false on empty")
check(type(win_util.now_sec()) == "number", "win_util.now_sec returns number")
check(#win_util.ascii_cache_dirs() >= 1, "win_util.ascii_cache_dirs non-empty")
local fn_wi, err_wi = loadstring(win_util.WININET_THREAD_GET_SRC .. "\nreturn kr_wininet_get")
check(type(fn_wi) == "function", "WININET_THREAD_GET_SRC compiles cleanly: " .. tostring(err_wi))

-- 2. voice_codec: Base64 roundtrip + bit-identical IMA-ADPCM between Lua array and FFI ptr!
local codec = require("kr_mp.voice_codec")
local ffi = require("ffi")
local bit = require("bit")
local sample_str = "KR-MP\0\1\2\255hello world 12345"
check(codec.b64_decode(codec.b64_encode(sample_str)) == sample_str, "voice_codec b64 roundtrip")
check(codec.b64_encode("") == "", "voice_codec b64 empty")

local pcm_arr = {}
local pcm_ptr = ffi.new("int16_t[?]", codec.FRAME_SAMPLES)
for i = 0, codec.FRAME_SAMPLES - 1 do
    local v = math.floor(math.sin(i * 0.13) * 14000)
    pcm_arr[i + 1] = v
    pcm_ptr[i] = v
end
local st_arr = { hp_x = 0.0, hp_y = 0.0, step_idx = 0 }
local st_ptr = { hp_x = 0.0, hp_y = 0.0, step_idx = 0 }
local bin_arr, rms_arr = codec.encode_pcm_array(st_arr, pcm_arr, 1.2)
local out_buf = ffi.new("uint8_t[?]", 4 + codec.FRAME_SAMPLES / 2)
local filt_buf = ffi.new("int16_t[?]", codec.FRAME_SAMPLES)
local bin_ptr, rms_ptr = codec.encode_pcm_ptr(st_ptr, ffi, bit, pcm_ptr, codec.FRAME_SAMPLES, 1.2, out_buf, filt_buf)
check(bin_arr == bin_ptr, "IMA-ADPCM Android array vs Windows FFI ptr are BIT-IDENTICAL!")
check(math.abs(rms_arr - rms_ptr) < 1e-9, "RMS identical across backends")
check(st_arr.step_idx == st_ptr.step_idx, "ADPCM step_idx state identical")

local dec_ptr = ffi.new("int16_t[?]", codec.FRAME_SAMPLES)
local ns_ptr, dec_rms = codec.decode_to_pcm_ptr(ffi, bit, bin_ptr, dec_ptr, 1.0)
check(ns_ptr == codec.FRAME_SAMPLES and dec_rms > 0.1, "decode_to_pcm_ptr decodes full frame")

local sd_samples = {}
local fake_sd = { setSample = function(_, idx, v) sd_samples[idx] = v end }
local ns_sd = codec.decode_to_sounddata(bin_arr, 1.0, fake_sd)
check(ns_sd == codec.FRAME_SAMPLES, "decode_to_sounddata decodes full frame")
local max_diff = 0
for i = 0, codec.FRAME_SAMPLES - 1 do
    local d = math.abs((dec_ptr[i] / 32768.0) - (sd_samples[i] or 0))
    if d > max_diff then max_diff = d end
end
check(max_diff < 1e-4, "Decoded PCM matches SoundData across Windows & Android (max_diff=" .. tostring(max_diff) .. ")")

-- Also verify voice_winmm worker script compiles cleanly!
local voice_winmm = require("kr_mp.voice_winmm")
local fn_vw, err_vw = loadstring(voice_winmm.WORKER_CODE)
check(type(fn_vw) == "function", "voice_winmm.WORKER_CODE compiles cleanly: " .. tostring(err_vw))

-- Verify server_host & sakura_workers worker strings compile cleanly!
local server_host = require("kr_mp.server_host")
local fn_sh, err_sh = loadstring(server_host._DL_WORKER_CODE)
check(type(fn_sh) == "function", "server_host._DL_WORKER_CODE compiles cleanly: " .. tostring(err_sh))
check(not server_host._DL_WORKER_CODE:find("2%.4%.5"), "server_host no longer hardcodes version 2.4.5")

local sakura_workers = require("kr_mp.sakura_workers")
local fn_sw, err_sw = loadstring(sakura_workers.INSTALLER_WORKER_CODE)
check(type(fn_sw) == "function", "sakura_workers.INSTALLER_WORKER_CODE compiles cleanly: " .. tostring(err_sw))

-- 3. tcp_stream: anti-HoL voice queue + newline JSON framing + PING/PONG + watchdog
package.loaded["socket"] = {
    gettime = function() return 100.0 end,
    tcp = function() return nil, "mock" end,
    select = function() return {}, {} end,
    dns = { toip = function() return "127.0.0.1" end },
}
local tcp_stream = require("kr_mp.tcp_stream")
local sent_chunks = {}
local fake_sock = {
    send = function(_, chunk, off)
        sent_chunks[#sent_chunks + 1] = chunk:sub(off)
        return #chunk
    end,
    recv_list = { '{"t":"PING","ts":99.5}\n{"t":"HELLO","name":"P2"}\n', nil },
    recv_i = 0,
    receive = function(self)
        self.recv_i = self.recv_i + 1
        local d = self.recv_list[self.recv_i]
        if d then return d, nil, nil end
        return nil, "timeout", nil
    end,
}
local conn = {
    state = "connected",
    boot = { lockstep = { waiting_for_peer = true } },
    voice_dropped = 0,
    last_ping_ts = 100.0,
    last_recv_ts = 100.0,
    last_poll_ts = 100.0,
    rtt_ms = 0,
}
tcp_stream.reset_io_buffers(conn)
function conn:send(m) return tcp_stream.send(self, fake_sock, m) end

-- When lockstep waiting, VOICE is dropped while TURN goes through!
check(conn:send({ t = "VOICE", d = "abc" }) == false, "tcp_stream drops VOICE when lockstep waiting")
check(conn.voice_dropped == 1, "tcp_stream increments voice_dropped")
check(conn:send({ t = "TURN", turn = 1 }) == true, "tcp_stream sends TURN even when lockstep waiting")
check(#sent_chunks == 1 and sent_chunks[1]:find('"TURN"'), "TURN flushed immediately")

-- Pump receive handles PING->PONG auto-reply + dispatches HELLO
local evs = {}
local disc = tcp_stream.pump_connected(conn, function() return fake_sock end, 100.0, evs, {})
check(disc == nil, "pump_connected stays alive")
check(#evs == 1 and evs[1].type == "msg" and evs[1].msg.t == "HELLO", "pump_connected framed HELLO")
check(#sent_chunks == 2 and sent_chunks[2]:find('"PONG"'), "pump_connected auto-replied PONG")

-- Watchdog triggers after WATCHDOG_SEC silence
local wd_called = false
local disc2 = tcp_stream.pump_connected(conn, function() return fake_sock end, 100.0 + tcp_stream.WATCHDOG_SEC + 0.1, {}, {
    on_watchdog = function() wd_called = true end,
})
check(disc2 == "watchdog_timeout" and wd_called, "tcp_stream watchdog fires cleanly")

-- 4. coop context guards restore state even on error!
package.loaded["hump.signal"] = { emit = function() end }
package.loaded["klua.macros"] = { clamp = function(a, b, v) return math.max(a, math.min(b, v)) end }
package.loaded["klua.log"] = { new = function() return { error = function() end, info = function() end } end }
package.loaded["klove.image_db"] = {}
package.loaded["klove.font_db"] = {}
package.loaded["entity_db"] = { entities = {}, get_template = function() return nil end }
package.loaded["grid_db"] = { find_waypoints = function() return {} end }
package.loaded["sound_db"] = { queue = function() end }
package.loaded["kr_mp.fonts"] = { get_path = function() return "mock" end, get = function() return {} end }
local coop = require("kr_mp.coop")
coop.active = true
coop.local_pid = 1
coop.econ_mode = "independent"
coop._tick_reserved_gold = { [1] = 100, [2] = 250 }
check(coop:get_tick_reserved_gold(1) == 100 and coop:get_tick_reserved_gold(2) == 250, "coop get_tick_reserved_gold independent")
coop.econ_mode = "shared"
check(coop:get_tick_reserved_gold(1) == 350, "coop get_tick_reserved_gold shared")

local ok_boom = coop:with_power_context(2, function()
    check(coop:get_active_power_actor() == 2, "with_power_context binds actor=2")
    error("simulated_boom")
end)
check(ok_boom == false, "with_power_context catches error")
check(coop:get_active_power_actor() == 1, "with_power_context restores actor after error")
check(coop:get_active_g4_branch() == nil and coop:get_active_g5_branch() == nil, "with_power_context restores branches after error")

local ok_g5 = coop:with_g5_branch("dark", function()
    check(coop:get_active_g5_branch() == "dark", "with_g5_branch binds dark")
    error("boom_g5")
end)
check(ok_g5 == false and coop:get_active_g5_branch() == nil, "with_g5_branch restores nil after error")

local ok_sb = pcall(coop.with_slot_bypass, coop, function()
    check(coop:is_slot_override_bypassed() == true, "with_slot_bypass sets bypass")
    error("boom_sb")
end)
check(ok_sb == false and coop:is_slot_override_bypassed() == false, "with_slot_bypass restores false after error")
coop.active = false

-- 5. lobby_net delegation preserves all public lobby methods + table-driven transport dispatch
local lobby = require("kr_mp.lobby_ui")
local lobby_net = require("kr_mp.lobby_net")
for _, m in ipairs({
    "is_room_link_alive", "exit_dead_online_room", "broadcast_room_state",
    "host_lan_room", "on_lan_connected", "reconnect_direct_session", "join_lan_room",
    "on_online_connected", "flush_pending_online_action", "connect_online_server",
    "ensure_online_connected", "refresh_online_rooms", "send_create_online_room",
    "create_online_room", "send_join_online_room", "join_online_room",
    "send_reconnect_online", "reconnect_online_session", "leave_room",
}) do
    check(type(lobby[m]) == "function", "lobby:" .. m .. " preserved")
end
local got_msg = nil
lobby.on_message = function(_, msg) got_msg = msg end
lobby_net.dispatch_transport_events(lobby, { { type = "msg", msg = { t = "PING_TEST" } } }, 10)
check(got_msg and got_msg.t == "PING_TEST", "lobby_net.dispatch_transport_events routes msg")

-- 6. boot table-driven HUD_ACTIONS + lockstep table-driven MSG_HANDLERS
local boot = require("kr_mp.boot")
local ls = require("kr_mp.lockstep")
local sp_called = false
boot.lockstep = { is_active = function() return true end, request_toggle_speed = function() sp_called = true end }
boot:on_hud_action("mp_speed")
check(sp_called, "boot:on_hud_action table-driven mp_speed works")

ls.active = true
ls.match_id = "m1"
ls.phase = "LOADING"
local loaded_pid = nil
ls.on_remote_loaded = function(_, pid) loaded_pid = pid end
check(ls:on_message({ t = "LOAD_DONE", match_id = "m1", pid = 2 }) == true, "lockstep:on_message LOAD_DONE returns true")
check(loaded_pid == 2, "lockstep:on_message table-driven LOAD_DONE dispatches")
check(ls:on_message({ t = "UNKNOWN_OP" }) == false, "lockstep:on_message returns false for unknown")
ls.active = false

print(string.format("REFACTOR VERIFIER DONE: %d PASS, %d FAIL", pass_cnt, fail_cnt))
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end
