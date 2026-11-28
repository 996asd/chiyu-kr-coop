local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
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

-- Minimal Love2D graphics / timer / mouse mocks
local mock_time = 100.0
love = {
    timer = { getTime = function() return mock_time end },
    system = { getOS = function() return "Windows" end },
    mouse = { getPosition = function() return 0, 0 end },
    graphics = setmetatable({
        getWidth = function() return 1280 end,
        getHeight = function() return 720 end,
        newFont = function(sz)
            return {
                getWidth = function(_, s) return #(tostring(s or "")) * (sz or 12) * 0.55 end,
                getHeight = function() return (sz or 12) * 1.2 end,
            }
        end,
    }, {
        __index = function() return function() end end,
    }),
    filesystem = {
        getSourceBaseDirectory = function() return "D:/FL8.2.0" end,
        getSaveDirectory = function() return "D:/FL8.2.0" end,
        exists = function() return false end,
        isFile = function() return false end,
    },
}

-- 1. Test fast batch game unload hook in hooks_determinism.lua
local ua_calls, ug_calls, purge_calls = {}, {}, 0
local mock_idb = {
    unload_atlas = function(self, name, scale, defer)
        ua_calls[#ua_calls + 1] = { name = name, scale = scale, defer = defer }
    end,
    purge_atlas = function(self)
        purge_calls = purge_calls + 1
    end,
}
local mock_sdb = {
    unload_group = function(self, name, defer)
        ug_calls[#ug_calls + 1] = { name = name, defer = defer }
    end,
}
package.loaded["klove.image_db"] = mock_idb
package.loaded["sound_db"] = mock_sdb
package.loaded["hump.signal"] = { register = function() end, emit = function() end }
package.loaded["entity_db"] = { get_template = function() return nil end, entities = {} }
package.loaded["grid_db"] = {}
package.loaded["storage"] = { load_slot = function() return {} end }
package.loaded["klua.vector"] = { v = function(x, y) return { x = x, y = y } end }
package.loaded["klua.macros"] = { clamp = function(a, b, c) return math.max(a, math.min(b, c)) end }
package.loaded["sound_db"].queue = function() end
local unload_should_fail = false
director = {
    unload_item = function(self, item, async)
        mock_idb:unload_atlas("g1", 1.0)
        mock_idb:unload_atlas("g2", 1.0)
        mock_sdb:unload_group("s1")
        mock_sdb:unload_group("s2")
        if unload_should_fail then error("boom") end
        return true
    end,
}
local orig_ua_ref = mock_idb.unload_atlas
local orig_ug_ref = mock_sdb.unload_group

local hooks = require("kr_mp.hooks")
hooks.boot = { log = function() end }
hooks:install_global_determinism()

local ok_res = director:unload_item({ item_name = "game" }, nil)
check(ok_res == true, "fast unload returns true")
check(#ua_calls == 2 and ua_calls[1].defer == true and ua_calls[2].defer == true, "all unload_atlas calls receive defer_purge=true")
check(#ug_calls == 2 and ug_calls[1].defer == true and ug_calls[2].defer == true, "all unload_group calls receive defer_gc=true")
check(purge_calls == 1, "purge_atlas called exactly once after batch unload")
check(mock_idb.unload_atlas == orig_ua_ref and mock_sdb.unload_group == orig_ug_ref, "original db unload methods restored")

-- Ensure error path still restores original functions
unload_should_fail = true
local ok_err = pcall(director.unload_item, director, { item_name = "game" }, nil)
check(ok_err == false, "unload error propagates")
check(mock_idb.unload_atlas == orig_ua_ref and mock_sdb.unload_group == orig_ug_ref, "original db methods restored on error")
unload_should_fail = false

-- 2. Test Lobby zombie-room guard, auto-reconnect, RETURN_LOBBY ternary fix, and 2P stage selection
local lobby = require("kr_mp.lobby_ui")
local lobby_draw = require("kr_mp.lobby_draw")
local lobby_input = require("kr_mp.lobby_input")

local sent_msgs = {}
local toasts = {}
local mock_connected = true
local mock_online = true
local mock_connecting = false

local mock_transport = {
    is_online = function() return mock_online end,
    is_connected = function() return mock_connected end,
    is_connecting = function() return mock_connecting end,
    get_rtt_ms = function() return 25 end,
    get_port = function() return 17777 end,
    is_port_drifted = function() return false end,
    update_advert = function() end,
    close = function() mock_connected = false end,
    connect_online = function(_, addr, port, silent)
        mock_connecting = true
        return true, "connecting"
    end,
    send = function(_, msg)
        if not mock_connected then return false end
        sent_msgs[#sent_msgs + 1] = msg
        return true
    end,
    poll = function() return {} end,
}

lobby.boot = { log = function() end }
lobby.transport = mock_transport
lobby.overlay = {
    show_toast = function(_, msg) toasts[#toasts + 1] = msg end,
    clear_toast = function() end,
}
lobby.coop = {
    is_active = function() return false end,
    leave_match = function() end,
    build_host_slot_snapshot = function() return {} end,
    prepare_match = function() end,
    show_tower_marks = true,
}
lobby.lockstep = { is_active = function() return false end, on_message = function() return false end }
lobby.save_prefs = function() end
lobby.save_session = function() end
lobby.clear_saved_session = function() end
lobby.refresh_online_rooms = function() end

-- 2a. RETURN_LOBBY peer_connected=false must NOT become true (Lua ternary bug check)
lobby.view = "room"
lobby.role = "host"
lobby.server_connected = true
lobby:on_return_lobby(1, { level_idx = 101 }, { peer_connected = false, peer_ready = false })
check(lobby.peer_connected == false, "on_return_lobby preserves peer_connected=false")
check(lobby.peer_ready == false, "on_return_lobby preserves peer_ready=false")

lobby:on_return_lobby(1, { level_idx = 101 }, { peer_connected = true, peer_ready = true })
check(lobby.peer_connected == true and lobby.peer_ready == true, "on_return_lobby sets peer_connected=true when both online")

-- 2b. Online server_disconnected while in room must clear peer_connected and block sends (no zombie room!)
lobby.online_room_code = "QEXK"
lobby.online_token = "tok123"
lobby.local_pid = 1
lobby.role = "host"
lobby.view = "room"
lobby.server_connected = true
lobby.peer_connected = true
lobby.peer_ready = true
mock_online = true
mock_connected = false
mock_transport.poll = function() return { { type = "server_disconnected", reason = "watchdog_timeout" } } end
lobby:update(0.016)
mock_transport.poll = function() return {} end

check(lobby.server_connected == false, "server_disconnected clears server_connected")
check(lobby.peer_connected == false, "server_disconnected clears peer_connected (no zombie 2/2)")
check(lobby.online_reconnecting_room == true, "server_disconnected in room triggers online_reconnecting_room")
check(lobby:is_room_link_alive() == false, "is_room_link_alive is false during reconnect")

sent_msgs = {}
check(lobby:broadcast_room_state() == false, "broadcast_room_state returns false when disconnected")
check(lobby:host_start_match() == false, "host_start_match refuses to launch when disconnected")
check(#sent_msgs == 0, "zero messages sent into dead socket")

-- Room UI renders cleanly during reconnect and disables start_match
lobby.open = true
lobby_draw.draw(lobby)
local start_btn
for _, b in ipairs(lobby.buttons) do
    if b.id == "start_match" then start_btn = b end
end
check(start_btn ~= nil and start_btn.disabled == true, "start_match button disabled while reconnecting")

-- 2c. ROOM_REJOINED restores room cleanly
mock_connected = true
lobby.server_connected = true
lobby:on_message({
    t = "ROOM_REJOINED",
    code = "QEXK",
    pid = 1,
    token = "tok123",
    room = { level_idx = 142, heroes = { 53, 93 } },
    peer_connected = true,
    peer_ready = true,
    guest_name = "Player 2",
})
check(lobby.online_reconnecting_room == false, "ROOM_REJOINED clears online_reconnecting_room")
check(lobby.peer_connected == true and lobby.room.level_idx == 142, "ROOM_REJOINED restores peer_connected and room level")
check(lobby:is_room_link_alive() == true, "is_room_link_alive is true after ROOM_REJOINED")

-- 2d. ERROR during _pending_lobby_reconnect exits zombie room cleanly to home
lobby._pending_lobby_reconnect = true
lobby.online_reconnecting_room = true
lobby:on_message({ t = "ERROR", msg = "Reconnect failed: room expired" })
check(lobby.view == "home" and lobby.role == "none" and lobby.online_reconnecting_room == false, "ERROR on lobby reconnect exits zombie room cleanly to home")

-- 2e. 2P Stage Picker UI + Legacy Online Guard + Modern Online + LAN Sync
lobby.view = "room"
lobby.role = "client"
lobby.local_pid = 2
lobby.peer_connected = true
lobby.local_ready = true
lobby.server_connected = true
lobby.room = { level_idx = 101, heroes = { 53, 54 }, reinforcements = { "default_reinforcement", "default_reinforcement" }, max_tech = true }
mock_online = true
mock_connected = true

lobby.open = true
lobby_draw.draw(lobby)
local stage_btn
for _, b in ipairs(lobby.buttons) do
    if b.id == "open_stages" then stage_btn = b end
end
check(stage_btn ~= nil, "2P room renders open_stages button")
check(stage_btn.x >= 0 and stage_btn.x + stage_btn.w <= 780 and stage_btn.y >= 0 and stage_btn.y + stage_btn.h <= 486, "2P open_stages button within 780x486 bounds")

-- Click open_stages as 2P
lobby_input.handle_button(lobby, { id = "open_stages" })
check(lobby.sub_modal == "stages", "2P can open stages modal")

-- Online legacy server (guest_stage_ok = false) blocks cleanly with warning
lobby.server_guest_stage_ok = false
sent_msgs = {}
lobby_input.handle_button(lobby, { id = "pick_stage", level_idx = 142 })
check(#sent_msgs == 0 and lobby.room.level_idx == 101, "legacy online server warns and does not silently pretend stage changed")

-- Modern online server (guest_stage_ok = true) sends SET_GUEST with level_idx
lobby.server_guest_stage_ok = true
lobby_input.handle_button(lobby, { id = "pick_stage", level_idx = 142 })
check(#sent_msgs == 1 and sent_msgs[1].t == "SET_GUEST" and sent_msgs[1].level_idx == 142, "2P pick_stage sends SET_GUEST with level_idx=142")
check(lobby.room.level_idx == 142 and lobby.sub_modal == nil, "2P room level updated and modal closed")

-- Unrelated 2P toggle_ready does NOT include level_idx (avoids race overwrite)
sent_msgs = {}
lobby:toggle_ready(false)
check(#sent_msgs == 1 and sent_msgs[1].t == "SET_GUEST" and sent_msgs[1].level_idx == nil, "toggle_ready SET_GUEST omits level_idx")

-- LAN Host receives SET_GUEST with level_idx=251 and updates + broadcasts
mock_online = false
lobby.role = "host"
lobby.local_pid = 1
lobby.peer_connected = true
lobby.room.level_idx = 101
sent_msgs = {}
toasts = {}
lobby:on_message({ t = "SET_GUEST", level_idx = 251, ready = true })
check(lobby.room.level_idx == 251, "LAN Host applies 2P level_idx=251")
check(#sent_msgs == 1 and sent_msgs[1].t == "ROOM_STATE" and sent_msgs[1].room.level_idx == 251, "LAN Host broadcasts ROOM_STATE with 2P new level")
check(#toasts >= 1 and toasts[#toasts]:find("2P", 1, true) ~= nil, "LAN Host shows toast when 2P changes level")

-- Online Host receives ROOM_STATE with new level_idx -> shows toast
mock_online = true
lobby.role = "host"
lobby.room.level_idx = 101
toasts = {}
lobby:on_message({ t = "ROOM_STATE", room = { level_idx = 260, heroes = { 53, 54 } }, peer_connected = true, peer_ready = true })
check(lobby.room.level_idx == 260, "Online Host updates room.level_idx from ROOM_STATE")
check(#toasts >= 1 and toasts[#toasts]:find("2P", 1, true) ~= nil, "Online Host shows toast on 2P stage change")

print(string.format("SUMMARY: %d PASS, %d FAIL", pass_cnt, fail_cnt))
io.stdout:flush()
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end
