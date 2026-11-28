local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Comprehensive verifier for Android/Mobile all-desktop/game_gui.lua:3599 nil-slot crash & match-exit fixes
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function check(cond, msg)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print("FAIL: " .. tostring(msg))
    end
end

-- Minimal stubs for FL 8.2.0 modules required by hooks / coop / lobby_ui
local created_dirs = {}
local disk_slots = {}
local saved_writes = {}

love = {
    timer = { getTime = function() return 100 end },
    filesystem = {
        createDirectory = function(d) created_dirs[d] = true; return true end,
        getSourceBaseDirectory = function() return _KR_REPO end,
        getSaveDirectory = function() return _KR_REPO end,
        read = function() return nil end,
    },
    system = { getOS = function() return "Android" end },
    graphics = { getWidth = function() return 1280 end, getHeight = function() return 720 end },
    keyboard = { isDown = function() return false end, setTextInput = function() end },
}
IS_ANDROID = true
TICK_LENGTH = 1 / 60
KR_FL_VERSION = "8.2.0"
GUI_MODE_IDLE = 1
GUI_MODE_SELECT_POINT = 2
GUI_MODE_SWAP_TOWER = 3

local function clone_tbl(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = clone_tbl(v) end
    return r
end
table.deepclone = clone_tbl

local fake_storage = {
    active_slot_idx = nil,
    slot = nil,
}
function fake_storage:load_slot(idx, force)
    idx = idx or self.active_slot_idx
    if not idx then return nil end
    local d = disk_slots[idx]
    return d and clone_tbl(d) or nil
end
function fake_storage:save_slot(data_table, idx, should_sync)
    idx = idx or self.active_slot_idx
    if not idx or not data_table then return nil end
    disk_slots[idx] = clone_tbl(data_table)
    saved_writes[#saved_writes + 1] = { idx = idx, data = clone_tbl(data_table) }
    return true
end
function fake_storage:create_slot(idx)
    local tpl = {
        levels = {},
        upgrades = { archers = 0, barracks = 0, mages = 0, rocks = 0, thunder = 0, reinforcements = 0 },
        heroes = { selected = "hero_vesper", status = { hero_vesper = { xp = 0, skills = {} } } },
        bag = {},
        gems = 0,
        _from_create = idx,
    }
    self:save_slot(tpl, idx, true)
    return self:load_slot(idx)
end
function fake_storage:set_active_slot(idx)
    if not idx then return end
    if not self:load_slot(idx) then return end
    self.active_slot_idx = idx
end

package.loaded["storage"] = fake_storage
package.loaded["data.slot_template"] = {
    levels = {},
    upgrades = { archers = 0, barracks = 0, mages = 0, rocks = 0, thunder = 0, reinforcements = 0 },
    heroes = { selected = "hero_vesper", status = { hero_vesper = { xp = 0, skills = {} } } },
    bag = {},
    gems = 0,
}
package.loaded["hump.signal"] = { register = function() end, emit = function() end }
package.loaded["entity_db"] = {
    entities = {},
    last_id = 1,
    create_entity = function(self, t) self.last_id = self.last_id + 1; return { id = self.last_id, template_name = t } end,
    clone_entity = function(self, e) self.last_id = self.last_id + 1; return { id = self.last_id, template_name = e.template_name } end,
    filter = function() return {} end,
    filter_iter = function() return function() return nil end end,
    get_template = function() return nil end,
}
package.loaded["klua.macros"] = { round = function(x) return math.floor(x + 0.5) end, clamp = function(a, b, x) return math.max(a, math.min(b, x)) end }
package.loaded["sound_db"] = { queue = function() end, stop_all = function() end, resume = function() end }
package.loaded["grid_db"] = { find_waypoints = function() return nil end, waypoints_cache = {} }
package.loaded["simulation"] = { init = function() end, insert_entity = function() end, remove_entity = function() end, update = function() end, do_tick = function() end }
package.loaded["hump.vector-light"] = { dist = function() return 0 end }
package.loaded["utils"] = { is_inside_ellipse = function() return true end }
package.loaded["path_db"] = { valid_node_nearby = function() return true end }
package.loaded["kr_mp.fonts"] = { get = function() return {} end, get_path = function() return "" end }
package.loaded["kr_mp.ui_assets"] = { play_sfx = function() end, THEME = {}, compute_hud_scale = function() return 1 end, make_font_map = function() return {} end }

PickView = { on_down = function() end, update = function() end, rally_tower = function() end, rally_hero = function() end, rally_reinforcement = function() end }
TowerMenuButton = { on_click = function() end, on_enter = function() end, on_exit = function() end }
TowerMenu = { show = function() end, hide = function() end }
PauseView = { show = function() end, hide = function() end }
VictoryView = { show = function() end }
DefeatView = { show = function() end }
InfoBar = { show = function() end, update_stats = function() end }
TowerTooltip = { show = function() end }
TowerMenuTooltip = { show = function() end }
WaveFlag = { on_enter = function() end, on_click = function() end }
Power1Button = { fire = function() end, on_click = function() end }
Power2Button = { fire = function() end, on_click = function() end }
Power3Button = { fire = function() end, on_click = function() end }

local coop = require("kr_mp.coop")
local hooks = require("kr_mp.hooks")
local stage_flow = require("kr_mp.stage_flow")

local mock_boot = { log = function() end, transport = { is_connected = function() return false end }, actions = {} }
function mock_boot:on_hud_action(act)
    self.actions[#self.actions + 1] = act
    if act == "mp_leave" and self.lobby then self.lobby:leave_room() end
    if act == "mp_return_lobby" and self.lobby then self.lobby:return_to_lobby() end
end
local mock_overlay = { show_toast = function() end, voice_panel_open = false }
local mock_lockstep = {
    active = false,
    phase = "RUNNING",
    reset = function(self) self.active = false; self.phase = "IDLE" end,
    begin_loading = function(self) self.active = true; self.phase = "LOADING" end,
    begin_reconnect = function(self) self.active = true; self.phase = "LOADING" end,
    is_active = function(self) return self.active end,
    is_running = function(self) return self.phase == "RUNNING" end,
    is_catching_up = function(self) return false end,
}

coop:init(mock_boot, mock_lockstep, mock_overlay)
hooks:init(mock_boot, nil, mock_overlay, coop, mock_lockstep)

local function make_sample_cfg()
    return {
        match_id = "test-001",
        level_idx = 101,
        level_mode = 1,
        level_difficulty = 2,
        seed = 123456,
        econ_mode = "independent",
        tower_mode = "owned",
        heroes = { 53, 54 },
        towers = { 1, 2, 3, 4 },
        slot_snapshot = {
            levels = {},
            upgrades = { archers = 5, barracks = 5, mages = 5, rocks = 5, thunder = 5, reinforcements = 5 },
            heroes = { selected = "hero_vesper", status = { hero_vesper = { xp = 0, skills = {} } } },
            bag = {},
            gems = 0,
            _is_coop_snap = true,
        },
    }
end

-- === TEST 1: Fresh Android 2P phone (Slot 2 & 3 exist, Slot 1 missing, active_slot_idx == nil) ===
disk_slots = {
    [2] = { levels = { [1] = { stars = 2 } }, upgrades = {}, heroes = { status = { hero_vesper = { xp = 100 } } }, _slot_tag = 2 },
    [3] = { levels = { [1] = { stars = 3 } }, upgrades = {}, heroes = { status = { hero_vesper = { xp = 200 } } }, _slot_tag = 3 },
}
saved_writes = {}
fake_storage.active_slot_idx = nil
main = { handler = { active_item = { item_name = "slots" }, next_item_name = nil, next_item_args = nil } }
game = { item_name = "game", store = { paused = false, main_heroes = { { template_name = "hero_vesper", hero = { xp = 50 } } } } }

coop:prepare_match(2, make_sample_cfg())
check(fake_storage.active_slot_idx == 2, "TEST 1: Android 2P picks existing Slot 2 instead of phantom Slot 1 (got " .. tostring(fake_storage.active_slot_idx) .. ")")
check(disk_slots[1] == nil, "TEST 1: Did not pollute empty Slot 1 on Android")
local in_match_slot = fake_storage:load_slot()
check(in_match_slot and in_match_slot._is_coop_snap == true, "TEST 1: During active Co-op, storage:load_slot() still returns Co-op snapshot")
local writes_before = #saved_writes
fake_storage:save_slot({ tampered = true })
check(#saved_writes == writes_before and disk_slots[2]._slot_tag == 2, "TEST 1: Co-op save_slot suppression preserves real Slot 2 on disk")

-- Leave match while active_item == game -> must auto-exit to slots AND restore real Slot 2
main.handler.active_item = game
main.handler.next_item_name = nil
game.game_gui = { pauseview = { hidden = false } }
coop:leave_match()
check(coop:is_active() == false, "TEST 1: coop.active cleared after leave_match")
check(main.handler.next_item_name == "slots", "TEST 1: leave_match transitions game -> slots (got " .. tostring(main.handler.next_item_name) .. ")")
check(game.game_gui.pauseview.hidden == true, "TEST 1: leave_match hides PauseView")
local post_slot = fake_storage:load_slot()
check(post_slot and post_slot._slot_tag == 2, "TEST 1: Post-match storage:load_slot() returns real Slot 2 (never nil!)")
check(fake_storage:load_slot(1) == nil, "TEST 1: Explicit storage:load_slot(1) still returns nil for empty Slot 1 (screen_slots safe)")

-- === TEST 2: Completely empty save dir (Slots 1, 2, 3 all missing) -> 2P creates real Slot 1 even with coop.active=true ===
disk_slots = {}
saved_writes = {}
created_dirs = {}
fake_storage.active_slot_idx = nil
main.handler.active_item = { item_name = "slots" }
main.handler.next_item_name = nil
coop:prepare_match(2, make_sample_cfg())
check(created_dirs["fl_save"] == true, "TEST 2: Ensures fl_save directory created when all slots empty")
check(disk_slots[1] ~= nil and disk_slots[1]._from_create == 1, "TEST 2: Actually wrote real Slot 1 to disk despite coop.active=true")
check(fake_storage.active_slot_idx == 1, "TEST 2: active_slot_idx set to real Slot 1")
coop:leave_match()
local real_s1 = fake_storage:load_slot()
check(real_s1 ~= nil and real_s1._from_create == 1, "TEST 2: Post-match storage:load_slot() loads real Slot 1 cleanly")

-- === TEST 3: User already active on Slot 3 -> build_host_slot_snapshot & prepare_match preserve Slot 3 ===
disk_slots = {
    [3] = { levels = {}, upgrades = {}, heroes = { status = { hero_vesper = { xp = 999 } } }, _slot_tag = 3 },
}
fake_storage.active_slot_idx = 3
local snap = coop:build_host_slot_snapshot({ 53, 54 }, { 1, 2, 3 }, { max_tech = true })
check(fake_storage.active_slot_idx == 3, "TEST 3: build_host_slot_snapshot preserves user's active Slot 3")
check(disk_slots[1] == nil, "TEST 3: build_host_slot_snapshot does not create unwanted Slot 1 when Slot 3 exists")
check(type(snap) == "table" and snap.liuhui_hero.usedoublehero == true, "TEST 3: snapshot valid")
coop:prepare_match(1, make_sample_cfg())
check(fake_storage.active_slot_idx == 3, "TEST 3: prepare_match preserves active Slot 3")
-- Chained prepare_match while coop.active == true still preserves Slot 3
coop:prepare_match(1, make_sample_cfg())
check(fake_storage.active_slot_idx == 3, "TEST 3: Chained prepare_match preserves active Slot 3")
coop:leave_match()

-- === TEST 4: Worst-case defense-in-depth (all disk slots deleted/nil & active_slot_idx=nil) -> game_gui.lua:3599 NEVER crashes! ===
disk_slots = {}
saved_writes = {}
fake_storage.active_slot_idx = nil
local function fl_save_active_hero_xp(store)
    local slot = fake_storage:load_slot()
    for _, hero in ipairs(store.main_heroes) do
        local status = hero and hero.hero and slot.heroes and slot.heroes.status and slot.heroes.status[hero.template_name]
        if status then
            status.xp = math.max(status.xp or 0, hero.hero.xp or 0)
        end
    end
    fake_storage:save_slot(slot)
    return slot
end
local ok_xp, res_slot = pcall(fl_save_active_hero_xp, game.store)
check(ok_xp == true, "TEST 4: Exact FL game_gui.lua:3599 save_active_hero_xp succeeds with zero crash even when all disk slots missing")
check(type(res_slot) == "table" and res_slot._kr_mp_fallback == true, "TEST 4: Active-slot load returns synthetic fallback slot")
check(#saved_writes == 0, "TEST 4: Synthetic fallback slot is NOT persisted to disk")
check(fake_storage:load_slot(1) == nil and fake_storage:load_slot(2) == nil, "TEST 4: Explicit slot probes still return nil")

-- === TEST 5: Active-slot repair when active_slot_idx=1 (missing) but Slot 2 exists ===
disk_slots = {
    [2] = { levels = {}, upgrades = {}, heroes = { status = { hero_vesper = { xp = 10 } } }, _slot_tag = 2 },
}
fake_storage.active_slot_idx = 1
local repaired = fake_storage:load_slot()
check(repaired and repaired._slot_tag == 2, "TEST 5: Missing active_slot_idx=1 auto-repairs to existing Slot 2")
check(fake_storage.active_slot_idx == 2, "TEST 5: active_slot_idx updated to 2")

-- === TEST 6: Mobile Pause -> Quit exact flow (disconnected + VictoryView/PauseView separation + double tap safety) ===
local orig_go_to_map_calls = 0
local fake_gui = {
    game = game,
    pauseview = { hidden = false },
    select_entity = function() end,
    deselect_all = function() end,
    deselect_entity = function() end,
    show_clickable_hover = function() end,
    show_ghost_hover = function() end,
    block_random_power = function() end,
    c_swap_tower = function() end,
    keypressed = function() end,
    restart_game = function() end,
    go_to_map = function(self_gui)
        orig_go_to_map_calls = orig_go_to_map_calls + 1
        fl_save_active_hero_xp(self_gui.game.store)
    end,
}
game.game_gui = fake_gui
hooks:install_gui_hooks(fake_gui)

local lobby = require("kr_mp.lobby_ui")
local sent_msgs = {}
local mock_transport = {
    connected = false,
    online = true,
    send_ok = true,
    is_connected = function(self) return self.connected end,
    is_online = function(self) return self.online end,
    send = function(self, m)
        if not self.send_ok then return false end
        sent_msgs[#sent_msgs + 1] = m
        return true
    end,
    close = function() end,
    start_lan_scan = function() end,
    stop_lan_scan = function() end,
}
lobby.boot = mock_boot
lobby.transport = mock_transport
lobby.lockstep = mock_lockstep
lobby.coop = coop
lobby.overlay = mock_overlay
lobby.save_prefs = function() end
lobby.clear_saved_session = function() end
lobby.refresh_online_rooms = function() end
mock_boot.lobby = lobby
mock_boot.transport = mock_transport
stage_flow:init(mock_boot, lobby, coop, mock_lockstep, mock_overlay)

-- Simulate disconnected mobile 2P in active match with PauseView open
disk_slots = {}
fake_storage.active_slot_idx = nil
coop:prepare_match(2, make_sample_cfg())
main.handler.active_item = game
main.handler.next_item_name = nil
fake_gui.pauseview.hidden = false
lobby.open = false
mock_transport.connected = false

fake_gui:go_to_map()
check(coop:is_active() == false, "TEST 6: Disconnected Pause->Quit cleanly leaves Co-op match on first tap")
check(fake_gui.pauseview.hidden == true, "TEST 6: Disconnected Pause->Quit hides PauseView")
check(main.handler.next_item_name == "slots", "TEST 6: Disconnected Pause->Quit transitions game -> slots")
check(lobby.open == true, "TEST 6: Disconnected Pause->Quit opens Lobby")
check(orig_go_to_map_calls == 0, "TEST 6: First tap intercepted cleanly without calling vanilla go_to_map")

-- Even if user somehow double-taps Pause->Quit right after coop.active becomes false:
local ok_2nd = pcall(fake_gui.go_to_map, fake_gui)
check(ok_2nd == true and orig_go_to_map_calls == 1, "TEST 6: Second tap after leaving match succeeds with ZERO nil-slot crash")

-- === TEST 7: Connected Pause->Quit when VictoryView auto-next is ready should NOT hijack into request_next ===
coop:prepare_match(1, make_sample_cfg())
lobby.role = "host"
lobby.peer_connected = true
mock_transport.connected = true
mock_transport.online = false
mock_transport.send_ok = true
stage_flow.outcome = "victory"
stage_flow.next_level_idx = 102
stage_flow.auto_enabled = true
stage_flow.auto_canceled = false
stage_flow.launching = false
fake_gui.pauseview.hidden = false
main.handler.active_item = game
main.handler.next_item_name = nil
mock_boot.actions = {}
fake_gui:go_to_map()
check(stage_flow.launching == false, "TEST 7: Pause->Quit while pauseview open does not trigger next-stage chain")
check(mock_boot.actions[1] == "mp_return_lobby", "TEST 7: Pause->Quit routes to mp_return_lobby")

-- === TEST 8: Online return_to_lobby when transport:send fails falls back to leave_room & exits game ===
coop:prepare_match(2, make_sample_cfg())
mock_transport.online = true
mock_transport.connected = true
mock_transport.send_ok = false
main.handler.active_item = game
main.handler.next_item_name = nil
lobby.open = false
local ret_ok = lobby:return_to_lobby()
check(ret_ok == false, "TEST 8: return_to_lobby returns false when send fails")
check(coop:is_active() == false, "TEST 8: Failed send falls back to leave_room -> coop inactive")
check(main.handler.next_item_name == "slots", "TEST 8: Failed send still exits game -> slots")
check(lobby.open == true, "TEST 8: Failed send opens lobby")

-- === TEST 9: Reloaded game_gui table automatically gets re-hooked ===
local new_gui = {
    game = game,
    pauseview = { hidden = true },
    select_entity = function() end,
    deselect_all = function() end,
    deselect_entity = function() end,
    show_clickable_hover = function() end,
    show_ghost_hover = function() end,
    block_random_power = function() end,
    c_swap_tower = function() end,
    keypressed = function() end,
    restart_game = function() end,
    go_to_map = function() error("should be intercepted!") end,
}
game.game_gui = new_gui
hooks:ensure_game_and_gui_hooks()
check(hooks._hooked_gui == new_gui, "TEST 9: ensure_game_and_gui_hooks detects and re-hooks reloaded game_gui table")
coop:prepare_match(2, make_sample_cfg())
mock_transport.connected = false
local ok_rehook = pcall(new_gui.go_to_map, new_gui)
check(ok_rehook == true, "TEST 9: Reloaded game_gui:go_to_map is properly intercepted")

print(string.format("MOBILE NIL-SLOT FIX VERIFIER: %d PASS, %d FAIL", pass, fail))
if fail > 0 then error("suite failed: " .. tostring(fail) .. " failures") end
