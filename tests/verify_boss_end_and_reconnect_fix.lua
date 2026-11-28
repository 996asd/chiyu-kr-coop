local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Unit verifier for v2.4.7:
-- 1) Post-boss custom_game_outcome suppression in Co-op (level37 kr2_end & all 26 ending stages)
-- 2) Nil-window crash guard for screen_credits:destroy() & screen_comics:destroy()
-- 3) Director item_done_callback Co-op escape guard + stage_flow non-game countdown guard
-- 4) Direct COLD_RECONNECT & HOT_RESUME_REQ seamless fallback into Host War Table + stale session cleanup
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

-- Minimal stubs for FL 8.2.0 globals & modules
KR_FL_VERSION = "8.2.0"
TICK_LENGTH = 1 / 60
local fake_now = 100.0
love = {
    timer = { getTime = function() return fake_now end },
    filesystem = { getSaveDirectory = function() return _KR_REPO end },
    system = { getOS = function() return "Windows" end },
    graphics = nil,
}

local emitted_signals = {}
local signal_handlers = {}
package.loaded["hump.signal"] = {
    register = function(ev, fn)
        signal_handlers[ev] = signal_handlers[ev] or {}
        table.insert(signal_handlers[ev], fn)
    end,
    emit = function(ev, ...)
        emitted_signals[#emitted_signals + 1] = ev
        for _, fn in ipairs(signal_handlers[ev] or {}) do fn(...) end
    end,
}
package.loaded["klua.macros"] = { clamp = function(lo, hi, v) return math.max(lo, math.min(hi, v)) end }
package.loaded["klua.log"] = { new = function() return { error = function() end, info = function() end, debug = function() end } end }
package.loaded["klove.image_db"] = { unload_atlas = function() end, purge_atlas = function() end }
package.loaded["klove.font_db"] = {}
package.loaded["entity_db"] = {
    entities = {},
    create_entity = function(_, name) return { id = 1, template_name = name } end,
    get_template = function() return nil end,
    filter = function(_, t) return {} end,
    filter_iter = function(_, t) return pairs(t) end,
}
package.loaded["grid_db"] = { find_waypoints = function() return {} end }
package.loaded["sound_db"] = { queue = function() end, stop_all = function() end, resume = function() end, unload_group = function() end }
package.loaded["storage"] = {
    active_slot_idx = 1,
    load_slot = function() return { heroes = { status = {} }, upgrades = {}, levels = {} } end,
    save_slot = function() return true end,
    set_active_slot = function(self, i) self.active_slot_idx = i end,
}
package.loaded["kr_mp.fonts"] = { get = function() return {} end, get_path = function() return "stub" end }

-- Stub FL screen_credits & screen_comics with original nil-window crash behavior
local credits_destroy_calls = 0
local comics_destroy_calls = 0
package.loaded["screen_credits"] = {
    window = nil,
    destroy = function(self)
        credits_destroy_calls = credits_destroy_calls + 1
        self.window:destroy() -- crashes if self.window == nil!
        self.window = nil
    end,
}
package.loaded["screen_comics"] = {
    window = nil,
    destroy = function(self)
        comics_destroy_calls = comics_destroy_calls + 1
        self.window:destroy()
        self.window = nil
    end,
}

-- Stub director
local done_cb_calls = {}
director = {
    active_item = nil,
    next_item_name = nil,
    next_item_args = nil,
    item_done_callback = function(self, item_name, outcome)
        done_cb_calls[#done_cb_calls + 1] = { item = item_name, outcome = outcome }
        if outcome and outcome.next_item_name then
            self.next_item_name = outcome.next_item_name
        end
    end,
    unload_item = function(self, item, async)
        if item and item.destroy then item:destroy() end
        return true
    end,
}
package.loaded["director"] = director

-- Stub GUI classes
PickView = { update = function() end }
TowerMenuButton = { on_enter = function() end, on_exit = function() end }
TowerMenu = { show = function() end, hide = function() end }
WaveFlag = { on_enter = function() end }
InfoBar = { show = function() end, update_stats = function() end }
TowerTooltip = { show = function() end }
TowerMenuTooltip = { show = function() end }
PauseView = { show = function() end, hide = function() end }
VictoryView = { show = function(self) self._shown = true end }
DefeatView = { show = function(self) self._shown = true end }
DragEntityView = { on_down = function() end, on_up = function() end, update = function() end }

local hooks = require("kr_mp.hooks")
local hooks_det = require("kr_mp.hooks_determinism")
local hooks_guards = require("kr_mp.hooks_gui_guards")
local stage_flow = require("kr_mp.stage_flow")
local coop = require("kr_mp.coop")
local lockstep = require("kr_mp.lockstep")
local lobby = require("kr_mp.lobby_ui")
local lobby_net = require("kr_mp.lobby_net")
local proto = require("kr_mp.proto")

local boot_logs = {}
local stub_boot = { log = function(_, fmt, ...) boot_logs[#boot_logs + 1] = string.format(fmt, ...) end }
local toasts = {}
local stub_overlay = {
    show_toast = function(_, msg) toasts[#toasts + 1] = msg end,
    clear_toast = function() end,
}

hooks.boot = stub_boot
hooks.overlay = stub_overlay
hooks.coop = { is_active = function() return true end, is_slot_override_bypassed = function() return false end, get_slot_override = function() return nil end }
hooks.replay = { is_active = function() return false end, is_replaying = function() return false end, get_slot_override = function() return nil end }

hooks_det.install(hooks)

-- === TEST 1: screen_credits & screen_comics nil-window destroy guard ===
local kr2_end_mock = {
    item_name = "kr2_end",
    destroy = function()
        package.loaded["screen_comics"]:destroy()
        package.loaded["screen_credits"]:destroy()
    end,
}
local ok_unload, err_unload = pcall(director.unload_item, director, kr2_end_mock, false)
check(ok_unload == true, "Unloading kr2_end while screen_credits.window==nil must NOT crash: " .. tostring(err_unload))
check(credits_destroy_calls == 0 and comics_destroy_calls == 0, "Safe destroy skips uninitialized nil window")

-- When initialized (window ~= nil), original destroy runs cleanly
local win_destroyed = 0
package.loaded["screen_credits"].window = { destroy = function() win_destroyed = win_destroyed + 1 end }
package.loaded["screen_comics"].window = { destroy = function() win_destroyed = win_destroyed + 1 end }
local ok_u2 = pcall(director.unload_item, director, kr2_end_mock, false)
check(ok_u2 == true and win_destroyed == 2, "Initialized screen_credits & screen_comics still destroy cleanly")
check(package.loaded["screen_credits"].window == nil and package.loaded["screen_comics"].window == nil, "Windows cleared after destroy")

-- === TEST 2: game_gui:victory() suppresses custom_game_outcome (kr2_end) in Co-op ===
local done_cb_triggered = false
local mock_vv = setmetatable({ _shown = false }, { __index = VictoryView })
local mock_game = {
    item_name = "game",
    store = {
        level_idx = 37,
        paused = false,
        game_outcome = { victory = true, stars = 3 },
        custom_game_outcome = { next_item_name = "kr2_end" },
    },
    done_callback = function(out)
        done_cb_triggered = out
    end,
}
game = mock_game
main = { handler = director }
director.active_item = mock_game

local mock_gui = {
    game = mock_game,
    victoryview = mock_vv,
    select_entity = function() end,
    deselect_all = function() end,
    deselect_entity = function() end,
    show_clickable_hover = function() end,
    show_ghost_hover = function() end,
    block_random_power = function() end,
    restart_game = function() end,
    go_to_map = function() end,
    victory = function(self_g)
        self_g.game.store.paused = true
        if self_g.game.store.custom_game_outcome then
            self_g.game.done_callback(self_g.game.store.custom_game_outcome)
        else
            self_g.victoryview:show()
        end
    end,
}

hooks_guards.install(hooks, mock_gui)
stage_flow:init(stub_boot, nil, hooks.coop, nil, stub_overlay)
stage_flow:reset()

emitted_signals = {}
mock_gui:victory()
check(done_cb_triggered == false, "Co-op level37 victory must NOT jump to kr2_end via done_callback")
check(mock_vv._shown == true, "Co-op level37 victory must show VictoryView instead")
check(mock_game.store.custom_game_outcome == nil, "custom_game_outcome cleared on Co-op victory")
local saw_hide_curtains = false
for _, s in ipairs(emitted_signals) do if s == "hide-curtains" then saw_hide_curtains = true end end
check(saw_hide_curtains == true, "Co-op victory emits hide-curtains for boss levels like 111/130")
check(stage_flow.active == true and stage_flow.next_level_idx == 38, "stage_flow activated with next=38 on level37 VictoryView")

-- Single-player mode must preserve custom_game_outcome
hooks.coop = { is_active = function() return false end, is_slot_override_bypassed = function() return false end, get_slot_override = function() return nil end }
mock_vv._shown = false
done_cb_triggered = false
mock_game.store.custom_game_outcome = { next_item_name = "kr2_end" }
mock_gui:victory()
check(type(done_cb_triggered) == "table" and done_cb_triggered.next_item_name == "kr2_end", "Single-player victory still transitions to kr2_end")
check(mock_vv._shown == false, "Single-player custom_game_outcome skips VictoryView as original")

-- === TEST 3: director:item_done_callback Co-op escape guard ===
hooks.coop = { is_active = function() return true end }
done_cb_calls = {}
director.next_item_name = nil
director:item_done_callback("game", { next_item_name = "kr2_end" })
director:item_done_callback("game", { next_item_name = "boss_fight_8_end" })
director:item_done_callback("game", { next_item_name = "kr1_fa" })
director:item_done_callback("game", { next_item_name = "map" })
check(#done_cb_calls == 0 and director.next_item_name == nil, "Co-op blocks unexpected game -> *_end / kr1_fa / map escape")

hooks.coop = { is_active = function() return false end }
director:item_done_callback("game", { next_item_name = "kr2_end" })
check(#done_cb_calls == 1 and director.next_item_name == "kr2_end", "Single-player director item_done_callback works unchanged")

-- === TEST 4: stage_flow:update pauses when active_item ~= game ===
local chain_calls = {}
local fake_lb_sf = {
    role = "host",
    peer_connected = true,
    is_room_link_alive = function() return true end,
    launch_chain_stage = function(_, lvl, reason, by)
        chain_calls[#chain_calls + 1] = { lvl = lvl, reason = reason, by = by }
        return true
    end,
}
local fake_coop_sf = { is_active = function() return true end, cfg = { level_idx = 37, auto_next_stage = true } }
stage_flow:init(stub_boot, fake_lb_sf, fake_coop_sf, { phase = "RUNNING", is_catching_up = function() return false end }, stub_overlay)
stage_flow:on_outcome("victory", { level_idx = 37, game_outcome = { stars = 3 } })
stage_flow:on_victory_view_shown()

director.active_item = kr2_end_mock
local cd_before = stage_flow.countdown
for _ = 1, 50 do stage_flow:update(0.2) end
check(stage_flow.countdown == cd_before and #chain_calls == 0, "stage_flow:update never advances countdown off 'game' screen")

director.active_item = mock_game
for _ = 1, 40 do stage_flow:update(0.2) end
check(#chain_calls == 1 and chain_calls[1].lvl == 38, "stage_flow:update chains cleanly to level 38 once on 'game' screen")

-- === TEST 5: coop:leave_match() clears stray non-game screen (e.g. kr2_end / map) back to slots ===
director.active_item = kr2_end_mock
director.next_item_name = nil
coop.active = true
coop:leave_match()
check(director.next_item_name == "slots", "coop:leave_match resets stray non-game screen back to slots")

-- === TEST 6: Direct COLD_RECONNECT & HOT_RESUME_REQ seamless fallback into Host War Table ===
local function make_mock_transport(is_online)
    local sent = {}
    local dropped = {}
    local closed_cnt = 0
    return {
        sent = sent,
        dropped = dropped,
        is_online = function() return is_online == true end,
        is_connected = function() return true end,
        is_connecting = function() return false end,
        get_rtt_ms = function() return 25 end,
        get_port = function() return 17777 end,
        is_port_drifted = function() return false end,
        update_advert = function() end,
        send = function(_, msg) sent[#sent + 1] = msg; return true end,
        drop_peer_socket = function(_, r) dropped[#dropped + 1] = r end,
        close = function() closed_cnt = closed_cnt + 1 end,
        get_closed_cnt = function() return closed_cnt end,
        start_lan_scan = function() end,
        stop_lan_scan = function() end,
    }
end

-- 6A: Host restarted into War Table (level 38), P2 sends COLD_RECONNECT -> Host seamlessly welcomes P2!
local host_tr = make_mock_transport(false)
lobby.boot = stub_boot
lobby.overlay = stub_overlay
lobby.transport = host_tr
lobby.coop = { is_active = function() return false end }
lobby.lockstep = {
    on_message = function() return false end,
    handle_cold_reconnect_req = function() return false end,
    handle_hot_resume_req = function() return false end,
}
lobby.role = "host"
lobby.local_pid = 1
lobby.view = "room"
lobby.peer_connected = false
lobby.peer_ready = false
lobby.room.level_idx = 38

lobby:on_message({
    t = "COLD_RECONNECT",
    match_id = "old-crash-match",
    pid = 2,
    proto = proto.PROTOCOL_VER,
    fl_ver = "8.2.0",
    script_hash = proto.compute_script_hash(),
    tick_len = 1 / 60,
    name = "Player 2",
})
check(lobby.peer_connected == true and lobby.peer_ready == true, "Host accepts COLD_RECONNECT into War Table when match ended")
check(#host_tr.dropped == 0, "Host does NOT drop P2 socket on COLD_RECONNECT War Table fallback")
check(host_tr.sent[1] and host_tr.sent[1].t == "WELCOME" and host_tr.sent[1].fallback_from_reconnect == true, "Host sends WELCOME with fallback_from_reconnect=true")
check(host_tr.sent[1].room and host_tr.sent[1].room.level_idx == 38, "Host WELCOME syncs level 38 to P2")

-- 6B: Host restarted into War Table, P2 stuck in old match sends HOT_RESUME_REQ -> Host seamlessly welcomes P2!
local host_tr2 = make_mock_transport(false)
lobby.transport = host_tr2
lobby.peer_connected = false
lobby.peer_ready = false
lockstep.match_id = "old-match-id"
lockstep.local_pid = 2
local hot_req = lockstep:build_hot_resume_req()
check(hot_req.proto == proto.PROTOCOL_VER and hot_req.fl_ver == "8.2.0" and hot_req.script_hash ~= nil, "build_hot_resume_req includes proto/fl_ver/script_hash")
lobby:on_message(hot_req)
check(lobby.peer_connected == true and #host_tr2.dropped == 0, "Host accepts HOT_RESUME_REQ into War Table without dropping P2")
check(host_tr2.sent[1] and host_tr2.sent[1].t == "WELCOME" and host_tr2.sent[1].fallback_from_reconnect == true, "Host responds to stale HOT_RESUME_REQ with fallback WELCOME")

-- 6C: P2 receives WELCOME(fallback_from_reconnect=true) while still stuck in old Co-op battle -> cleanly leaves old battle, clears saved_session, opens Host War Table at level 38!
local p2_tr = make_mock_transport(false)
local leave_called = 0
local saved_cleared = 0
lobby.transport = p2_tr
lobby.role = "client"
lobby.local_pid = 2
lobby.view = "home"
lobby.open = false
lobby.room.level_idx = 37
lobby.saved_session = { mode = "direct", host = "frp.test", port = 17777, match_id = "old-match" }
lobby._pending_session_reconnect = true
lobby.direct_auto_retry = { host = "frp.test", port = 17777, attempt = 3, next_try_ts = 999 }
lobby.coop = {
    is_active = function() return true end,
    leave_match = function() leave_called = leave_called + 1 end,
}
local orig_clear_sess = lobby.clear_saved_session
lobby.clear_saved_session = function(self)
    saved_cleared = saved_cleared + 1
    self.saved_session = nil
end

lobby:on_message({
    t = "WELCOME",
    pid = 2,
    room = { level_idx = 38, heroes = { 98, 45 }, towers = { 1, 2, 3 }, auto_next_stage = true },
    fallback_from_reconnect = true,
})
check(leave_called == 1, "P2 exits stale Co-op match when fallback WELCOME arrives")
check(saved_cleared == 1 and lobby.saved_session == nil, "P2 clears stale direct saved_session on fallback WELCOME")
check(lobby.direct_auto_retry == nil and lobby._pending_session_reconnect == false, "P2 stops auto-retry loop on fallback WELCOME")
check(lobby.view == "room" and lobby.open == true and lobby.room.level_idx == 38, "P2 opens War Table synced to Host level 38")

-- 6D: If COLD_RECONNECT still gets ERROR (e.g. Host busy in another match), P2 clears stale saved_session & resets role="none"
local p2_tr2 = make_mock_transport(false)
lobby.transport = p2_tr2
lobby.role = "client"
lobby.view = "home"
lobby.peer_connected = true
lobby.saved_session = { mode = "direct", host = "frp.test", port = 17777, match_id = "stale" }
lobby._pending_session_reconnect = true
lobby.coop = { is_active = function() return false end }
lobby:on_message({ t = "ERROR", msg = "直连追帧重连失败：房主对局已结束或局号不匹配。" })
check(lobby._pending_session_reconnect == false and lobby.saved_session == nil, "Stale session cleared when COLD_RECONNECT receives ERROR")
check(lobby.role == "none" and lobby.peer_connected == false and p2_tr2.get_closed_cnt() == 1, "P2 resets role/socket cleanly on home-screen reconnect ERROR")

-- 6E: peer_disconnected while client on home screen resets role="none" cleanly
local p2_tr3 = make_mock_transport(false)
lobby.transport = p2_tr3
lobby.role = "client"
lobby.view = "home"
lobby.lockstep = { is_active = function() return false end }
lobby_net.dispatch_transport_events(lobby, { { type = "peer_disconnected", reason = "closed" } }, 105.0)
check(lobby.role == "none" and p2_tr3.get_closed_cnt() == 1, "Home-screen client disconnect resets role to none")

-- 6F: host_start_match does NOT save_prefs if transport:send fails
local save_calls = 0
local orig_save_prefs = lobby.save_prefs
lobby.save_prefs = function() save_calls = save_calls + 1 end
lobby.role = "host"
lobby.peer_connected = true
lobby.coop = { build_host_slot_snapshot = function() return {} end, prepare_match = function() end }
local fail_tr = make_mock_transport(false)
fail_tr.send = function() return false end
lobby.transport = fail_tr
local ok_start = lobby:host_start_match(true)
check(ok_start == false and save_calls == 0, "host_start_match does NOT persist prefs when START_MATCH send fails")

lobby.save_prefs = orig_save_prefs
lobby.clear_saved_session = orig_clear_sess

print(string.format("verify_boss_end_and_reconnect_fix: %d PASS, %d FAIL", pass_cnt, fail_cnt))
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end
