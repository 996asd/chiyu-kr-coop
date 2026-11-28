local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Unit verifier for Seamless Auto-Next-Stage, Direct Chaining, In-Place Restart & Stale-Packet Isolation
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local pass_cnt, fail_cnt = 0, 0
local function check(cond, name)
    if cond then
        pass_cnt = pass_cnt + 1
    else
        fail_cnt = fail_cnt + 1
        print("FAIL: " .. tostring(name))
    end
end

-- Minimal stubs for LÖVE / FL environment
local sim_clock = 100.0
local tmp_dir = "C:/Users/work/.gemini/antigravity/brain/d306c676-234d-48be-a774-c79b4e318c0e/scratch/auto_next_tmp"
os.execute('mkdir "' .. tmp_dir:gsub("/", "\\") .. '" 2>nul')

love = {
    timer = { getTime = function() return sim_clock end },
    filesystem = {
        getSourceBaseDirectory = function() return tmp_dir end,
        getSaveDirectory = function() return tmp_dir end,
    },
    graphics = {
        getWidth = function() return 1280 end,
        getHeight = function() return 720 end,
    },
    mouse = { getPosition = function() return 0, 0 end },
    system = { getOS = function() return "Windows" end },
}
KR_FL_VERSION = "8.2.0"
TICK_LENGTH = 1 / 60

-- Stub hump.signal, entity_db, klua.macros, storage, sound_db
local sig_map = {}
package.loaded["hump.signal"] = {
    register = function(name, fn)
        sig_map[name] = sig_map[name] or {}
        table.insert(sig_map[name], fn)
    end,
    emit = function(name, ...)
        for _, fn in ipairs(sig_map[name] or {}) do fn(...) end
    end,
}
package.loaded["entity_db"] = {
    entities = {},
    get_template = function() return nil end,
    filter_iter = function() return function() return nil end end,
}
package.loaded["klua.macros"] = {
    round = function(x) return math.floor(x + 0.5) end,
}
package.loaded["grid_db"] = {}
package.loaded["storage"] = {
    load_slot = function() return { heroes = { selected = "hero_vesper", status = {} }, upgrades = {}, bag = {}, seen = {} } end,
    create_slot = function() return true end,
    set_active_slot = function() return true end,
}
local sound_stopped = 0
package.loaded["sound_db"] = {
    stop_all = function() sound_stopped = sound_stopped + 1 end,
    resume = function() end,
    queue = function() end,
}

local catalog = require("kr_mp.catalog")
local stage_flow = require("kr_mp.stage_flow")
local lockstep = require("kr_mp.lockstep")
local coop = require("kr_mp.coop")
local lobby = require("kr_mp.lobby_ui")
local lobby_prefs = require("kr_mp.lobby_prefs")
local lobby_input = require("kr_mp.lobby_input")
local hooks_gui_guards = require("kr_mp.hooks_gui_guards")

-- 1. Verify catalog.get_next_stage_idx across ALL 6 generations including non-contiguous IDs and pack ends
check(catalog.get_next_stage_idx(45) == 46, "KR1 45 -> 46")
check(catalog.get_next_stage_idx(75) == 76, "KR1 75 -> 76")
check(catalog.get_next_stage_idx(76) == nil, "KR1 finale 76 -> nil")
check(catalog.get_next_stage_idx(22) == 86, "KR3 non-contiguous 22 -> 86")
check(catalog.get_next_stage_idx(86) == nil, "KR3 finale 86 -> nil")
check(catalog.get_next_stage_idx(44) == 77, "KR2 non-contiguous 44 -> 77")
check(catalog.get_next_stage_idx(80) == 87, "KR2 non-contiguous 80 -> 87")
check(catalog.get_next_stage_idx(91) == nil, "KR2 finale 91 -> nil")
check(catalog.get_next_stage_idx(101) == 102, "KR5 101 -> 102")
check(catalog.get_next_stage_idx(142) == nil, "KR5 finale 142 -> nil")
check(catalog.get_next_stage_idx(150) == 151, "KR4 150 -> 151")
check(catalog.get_next_stage_idx(201) == nil, "KR4 finale 201 -> nil")
check(catalog.get_next_stage_idx(251) == 252, "KR6 251 -> 252")
check(catalog.get_next_stage_idx(271) == nil, "KR6 finale 271 -> nil")
check(catalog.get_next_stage_idx(9999) == nil, "unknown stage -> nil")

-- 2. Verify lockstep stale-packet guard during LOADING & match_id filtering
local sent_pkts = {}
local fake_transport = {
    _online = false,
    _connected = true,
    is_online = function(self) return self._online end,
    is_connected = function(self) return self._connected end,
    is_connecting = function() return false end,
    get_rtt_ms = function() return 12 end,
    get_server_addr = function() return "127.0.0.1:17780" end,
    update_advert = function() end,
    send = function(self, pkt) sent_pkts[#sent_pkts + 1] = pkt; return true end,
    close = function() end,
}
local last_toast = nil
local fake_overlay = {
    voice_panel_open = false,
    show_toast = function(self, m) last_toast = m end,
    clear_toast = function() end,
}
local fake_boot = {
    log = function() end,
    transport = fake_transport,
    hud_actions = {},
    on_hud_action = function(self, id) self.hud_actions[#self.hud_actions + 1] = id end,
}

lockstep:init(fake_boot, fake_transport, coop, fake_overlay)
lockstep:begin_loading(1, { match_id = "match-B", level_idx = 46, seed = 222, turn_ticks = 3, input_delay_turns = 2 })
check(lockstep.phase == "LOADING", "lockstep begins in LOADING")
-- Stale TURN from match-A during LOADING must be ignored
lockstep:on_message({ t = "TURN", turn = 500, pid = 2, cmds = { { op = "PING" } } })
check(lockstep.turns_received[500] == nil, "stale TURN ignored during LOADING")
check(lockstep.peer_max_sent_turn == 1, "peer_max_sent_turn unaffected by stale TURN")
-- Stale LOAD_DONE from match-A must be ignored
lockstep:on_message({ t = "LOAD_DONE", pid = 2, match_id = "match-A" })
check(lockstep.remote_loaded == false, "stale LOAD_DONE(match-A) ignored")
-- Matching LOAD_DONE(match-B) accepted
lockstep:on_message({ t = "LOAD_DONE", pid = 2, match_id = "match-B" })
check(lockstep.remote_loaded == true, "matching LOAD_DONE(match-B) accepted")
sent_pkts = {}
lockstep:on_local_loaded()
check(lockstep.phase == "RUNNING", "both loaded -> RUNNING")
check(#sent_pkts == 2 and sent_pkts[1].t == "LOAD_DONE" and sent_pkts[1].match_id == "match-B", "LOAD_DONE carries match_id")
check(sent_pkts[2].t == "BEGIN_SIM" and sent_pkts[2].match_id == "match-B", "BEGIN_SIM carries match_id")

-- 3. Wire coop, lobby, stage_flow for full Direct Mode auto-next-stage flow
game = {
    item_name = "game",
    store = { level_idx = 45, paused = false, game_outcome = { victory = true, stars = 3 }, entities = {} },
    game_gui = { combat_stats_view = { hidden = true }, victoryview = { hidden = false }, defeatview = { hidden = true } },
}
main = { handler = { active_item = game } }

coop:init(fake_boot, lockstep, fake_overlay)
lobby.boot = fake_boot
lobby.transport = fake_transport
lobby.lockstep = lockstep
lobby.coop = coop
lobby.overlay = fake_overlay
lobby.role = "host"
lobby.local_pid = 1
lobby.peer_connected = true
lobby.peer_ready = true
lobby.open = false
lobby.room.level_idx = 45
lobby.room.auto_next_stage = true
stage_flow:init(fake_boot, lobby, coop, lockstep, fake_overlay)

-- Simulate active Match #1 on level 45
coop.active = true
coop.local_pid = 1
coop.cfg = { level_idx = 45, auto_next_stage = true, heroes = { 53, 54 }, towers = { 1, 2 } }
lockstep.active = true
lockstep.phase = "RUNNING"

-- Emit game-victory signal -> stage_flow prepares next=46, waits for VictoryView:show()
package.loaded["hump.signal"].emit("game-victory", game.store)
check(stage_flow.outcome == "victory", "game-victory sets outcome=victory")
check(stage_flow.cur_level_idx == 45, "cur_level_idx=45")
check(stage_flow.next_level_idx == 46, "next_level_idx=46")
check(stage_flow.active == false, "waits for VictoryView:show before banner appears")

stage_flow:on_victory_view_shown()
check(stage_flow.active == true, "VictoryView:show activates banner")
check(stage_flow.countdown == 6.0, "starts 6s countdown")
check(stage_flow:is_victory_auto_ready() == true, "is_victory_auto_ready true")

-- Combat Stats open pauses countdown!
game.game_gui.combat_stats_view.hidden = false
stage_flow:update(0.25)
check(stage_flow.auto_paused_stats == true and stage_flow.countdown == 6.0, "CombatStatsView pauses countdown")
game.game_gui.combat_stats_view.hidden = true

-- Tick down 6.0s -> Host auto-launches level 46 directly WITHOUT opening lobby!
sent_pkts = {}
sound_stopped = 0
for _ = 1, 25 do
    stage_flow:update(0.25)
end
check(lobby.open == false, "Direct auto-next does NOT open lobby UI")
check(lobby.room.level_idx == 46, "room.level_idx updated to 46")
check(sound_stopped >= 1, "sound stopped cleanly on stage switch")
check(#sent_pkts >= 1 and sent_pkts[1].t == "START_MATCH" and sent_pkts[1].direct_chain == true and sent_pkts[1].cfg.level_idx == 46, "Host sent direct START_MATCH for level 46")
check(coop._pending_launch_args ~= nil and coop._pending_launch_args.level_idx == 46, "coop scheduled level 46 launch")
check(main.handler.next_item_name == "slots", "coop bounces cleanly through slots while active_item==game")

-- 4. Test 2P Cancel-Auto sync & Manual Next via MATCH_FLOW
coop.active = true
coop.cfg = { level_idx = 46, auto_next_stage = true }
lockstep.phase = "RUNNING"
game.store.level_idx = 46
stage_flow:on_outcome("victory", game.store)
stage_flow:on_victory_view_shown()
check(stage_flow.next_level_idx == 47, "46 -> 47")
-- Receive cancel_auto from 2P
stage_flow:on_message({ t = "MATCH_FLOW", pid = 2, action = "cancel_auto" })
check(stage_flow.auto_canceled == true and stage_flow.countdown == 0, "MATCH_FLOW cancel_auto stops countdown")
check(stage_flow:is_victory_auto_ready() == false, "auto_ready false after cancel")
-- Receive manual next from 2P
sent_pkts = {}
stage_flow:on_message({ t = "MATCH_FLOW", pid = 2, action = "next", level_idx = 47 })
check(#sent_pkts >= 1 and sent_pkts[1].t == "START_MATCH" and sent_pkts[1].cfg.level_idx == 47, "2P MATCH_FLOW next launches level 47")

-- 5. Test Old Online Server Fallback (server_direct_next_ok == false)
fake_transport._online = true
lobby.server_connected = true
lobby.server_direct_next_ok = false
lobby.online_reconnecting_room = false
lobby.open = false
sent_pkts = {}
local ok_old = lobby:launch_chain_stage(48, "next", 1)
check(ok_old == true, "Old online server launch_chain_stage succeeds")
check(lobby._pending_chain_stage ~= nil and lobby._pending_chain_stage.level_idx == 48, "pending chain stage queued")
check(#sent_pkts == 1 and sent_pkts[1].t == "RETURN_LOBBY", "Old online server sends silent RETURN_LOBBY")
-- Simulate old server echoing RETURN_LOBBY back to Host
sent_pkts = {}
lobby:on_return_lobby(1, { level_idx = 47, heroes = { 53, 54 }, towers = { 1, 2 } }, { peer_connected = true, peer_ready = true })
check(lobby.open == false, "Old server silent bounce does NOT open lobby on Host")
check(lobby.room.level_idx == 48, "Old server silent bounce sets level 48")
check(#sent_pkts == 2 and sent_pkts[1].t == "UPDATE_ROOM" and sent_pkts[2].t == "START_MATCH" and sent_pkts[2].cfg.level_idx == 48, "Old server bounce sends UPDATE_ROOM + START_MATCH(48)")

-- 6. Test New Online Server Direct Chain (server_direct_next_ok == true)
lobby.server_direct_next_ok = true
sent_pkts = {}
local ok_new = lobby:launch_chain_stage(49, "next", 1)
check(ok_new == true, "New online server direct chain succeeds")
check(lobby._pending_chain_stage == nil, "New online server needs no RETURN_LOBBY bounce")
check(#sent_pkts == 1 and sent_pkts[1].t == "START_MATCH" and sent_pkts[1].direct_chain == true and sent_pkts[1].cfg.level_idx == 49, "New online server sends START_MATCH directly")

-- 7. Test hooks_gui_guards integration (VictoryView Continue -> next stage; DefeatView Restart -> in-place restart)
local wrapped_reg = {}
local fake_hooks = {
    boot = fake_boot,
    overlay = fake_overlay,
    coop = coop,
    lockstep = lockstep,
    is_mp_active = function() return true end,
    is_sync_active = function() return true end,
    wrap_local_ui = function() end,
    wrap_once = function(tbl, key, tag, builder)
        if type(tbl) == "table" and type(tbl[key]) == "function" then
            tbl[key] = builder(tbl[key])
            return true
        end
        return false
    end,
}
VictoryView = { show = function() end }
DefeatView = { show = function() end }
PickView = { update = function() end }
local fake_gui = {
    game = game,
    select_entity = function() end,
    deselect_all = function() end,
    deselect_entity = function() end,
    restart_game = function() end,
    go_to_map = function() end,
}
hooks_gui_guards.install(fake_hooks, fake_gui)

-- Victory Continue goes directly to next stage when auto_next_stage is ON
fake_transport._online = false
coop.cfg = { level_idx = 50, auto_next_stage = true }
game.store.level_idx = 50
game.store.game_outcome = { victory = true, stars = 3 }
stage_flow:reset()
VictoryView:show()
check(stage_flow.active == true and stage_flow.next_level_idx == 51, "Wrapped VictoryView:show initializes stage_flow(50->51)")
sent_pkts = {}
fake_boot.hud_actions = {}
fake_gui:go_to_map()
check(#fake_boot.hud_actions == 0, "Victory Continue did NOT trigger mp_return_lobby")
check(#sent_pkts == 1 and sent_pkts[1].t == "START_MATCH" and sent_pkts[1].cfg.level_idx == 51, "Victory Continue jumped directly to level 51")

-- Defeat Restart triggers in-place restart of level 51; Defeat Quit triggers mp_return_lobby
coop.cfg = { level_idx = 51, auto_next_stage = true }
game.store.level_idx = 51
game.store.game_outcome = { victory = false }
stage_flow:reset()
DefeatView:show()
check(stage_flow.active == true and stage_flow.outcome == "defeat", "Wrapped DefeatView:show sets outcome=defeat")
sent_pkts = {}
fake_gui:restart_game()
check(#sent_pkts == 1 and sent_pkts[1].t == "START_MATCH" and sent_pkts[1].cfg.level_idx == 51, "Defeat Restart directly restarted level 51")

stage_flow:reset()
DefeatView:show()
fake_boot.hud_actions = {}
fake_gui:go_to_map()
check(#fake_boot.hud_actions == 1 and fake_boot.hud_actions[1] == "mp_return_lobby", "Defeat Quit returns to War Table")

-- 8. Test War Table toggle_auto_next button + prefs persistence
lobby.role = "host"
lobby.room.auto_next_stage = true
lobby_input.handle_button(lobby, { id = "toggle_auto_next" })
check(lobby.room.auto_next_stage == false, "toggle_auto_next toggles to false")
lobby_prefs.save_prefs(lobby)
lobby.room.auto_next_stage = true
lobby_prefs.load_prefs(lobby)
check(lobby.room.auto_next_stage == false, "prefs persists auto_next_stage=false")
lobby_input.handle_button(lobby, { id = "toggle_auto_next" })
check(lobby.room.auto_next_stage == true, "toggle_auto_next toggles back to true")

print(string.format("AUTO_NEXT_STAGE_VERIFIER: %d PASS, %d FAIL", pass_cnt, fail_cnt))
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end
