local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Unit verifier for:
--   1. Universal G1..G6 Draggable Reinforcements (nav_grid, deterministic squad_id, REINF_RALLY, SU rally execution)
--   2. Draggable Collapsed HUD Badge ("小标" click-to-expand vs drag-to-move, clamping, focus guard, persistence)
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local bit = require("bit")
TERRAIN_LAND = 1
TERRAIN_ICE = 4
TICK_LENGTH = 1 / 60

local pass_count = 0
local function check(cond, msg)
    if not cond then
        error("FAIL: " .. tostring(msg), 2)
    end
    pass_count = pass_count + 1
end

-- === Mock minimal FL 8.2.0 & LÖVE2D environment ===
local now_ts = 100.0
local mouse_x, mouse_y, mouse1_down = 0, 0, false
local win_w, win_h = 1280, 720
local sfx_log = {}

love = {
    timer = { getTime = function() return now_ts end },
    system = { getOS = function() return "Windows" end },
    mouse = {
        getPosition = function() return mouse_x, mouse_y end,
        isDown = function(b) return b == 1 and mouse1_down end,
    },
    graphics = {
        getWidth = function() return win_w end,
        getHeight = function() return win_h end,
        getFont = function() return nil end,
        setFont = function() end,
        getColor = function() return 255, 255, 255, 255 end,
        setColor = function() end,
        getBlendMode = function() return "alpha" end,
        setBlendMode = function() end,
        setLineWidth = function() end,
        push = function() end,
        pop = function() end,
        origin = function() end,
        setScissor = function() end,
        setShader = function() end,
        rectangle = function() end,
        line = function() end,
        circle = function() end,
        scale = function() end,
        translate = function() end,
        print = function() end,
        printf = function() end,
    },
    filesystem = { getSaveDirectory = function() return "C:/Users/work/.gemini/antigravity/brain/d306c676-234d-48be-a774-c79b4e318c0e/scratch" end },
}

package.loaded["hump.signal"] = { emit = function() end, register = function() end }
package.loaded["klua.macros"] = { clamp = function(a, b, v) return math.max(a, math.min(b, v)) end }
package.loaded["klua.log"] = { new = function() return { error = function() end, info = function() end } end }
package.loaded["sound_db"] = { queue = function() end }
package.loaded["kr_mp.fonts"] = { get_path = function() return "mock" end, get = function() return { getHeight = function() return 14 end, getWidth = function(_, s) return #(s or "") * 7 end } end }
package.loaded["kr_mp.ui_assets"] = {
    THEME = {
        wood_top = { 80, 48, 22, 245 }, wood_bot = { 48, 28, 12, 245 },
        gold_mid = { 188, 138, 56, 255 }, gold_bright = { 255, 224, 128, 255 },
        ink_dark = { 20, 12, 6, 255 }, ink_text = { 42, 24, 10, 255 },
        ok_bright = { 108, 244, 146, 255 },
        p1_top = { 40, 110, 210, 255 }, p1_border = { 120, 190, 255, 255 }, p1_light = { 150, 220, 255, 255 },
        p2_top = { 190, 44, 48, 255 }, p2_border = { 255, 130, 120, 255 }, p2_light = { 255, 165, 155, 255 },
        emerald_top = { 46, 178, 92, 255 }, emerald_bot = { 24, 112, 54, 255 },
        parchment_card = { 246, 232, 198, 250 }, parchment_card2 = { 228, 206, 166, 250 },
    },
    compute_hud_scale = function(sw, sh) return sw >= 1920 and 1.5 or 1.0 end,
    make_font_map = function()
        local f = { getHeight = function() return 12 end, getWidth = function(_, s) return #(s or "") * 7 end }
        return { tiny = f, tiny_bold = f, small = f, small_bold = f }
    end,
    font_h = function() return 12 end,
    font_w = function(_, s) return #(s or "") * 7 end,
    begin_transform = function() end,
    end_transform = function() end,
    draw_vgrad_rect = function() end,
    draw_brass_rivet = function() end,
    draw_pill = function() end,
    draw_coin_icon = function() end,
    draw_ping_dot = function() end,
    draw_parchment_card = function() end,
    draw_button = function() end,
    print_shadow = function() end,
    text = function() end,
    play_sfx = function(k) sfx_log[#sfx_log + 1] = k end,
}

local wp_calls = {}
local mock_GR = {
    waypoints_cache = {},
    find_waypoints = function(self, from, fallback, to, vt, force)
        wp_calls[#wp_calls + 1] = { from = from, fallback = fallback, to = to, vt = vt, force = force }
        if fallback and fallback.x == -999 then return nil end -- simulate fallback-only fail
        return { { x = to.x, y = to.y } }
    end,
}
package.loaded["grid_db"] = mock_GR

local mock_E = {
    last_id = 1,
    entities = {},
    clone_c = function(self, name)
        if name == "nav_grid" then
            return {
                valid_terrains = bit.bor(TERRAIN_LAND, TERRAIN_ICE),
                valid_terrains_dest = bit.bor(TERRAIN_LAND, TERRAIN_ICE),
                waypoints = {},
                ignore_waypoints = nil,
            }
        end
        return nil
    end,
    get_template = function(self, name) return self.entities[name] end,
}
package.loaded["entity_db"] = mock_E

-- Mock 3 FL script_utils variants (G1/G2/G3, G4 scripts_4, G4 kr4_reinforcement)
local rally_exec_log = {}
local function make_mock_su(tag)
    return {
        y_hero_new_rally = function(store, this)
            this.nav_rally.new = false
            this.pos.x = this.nav_rally.pos.x
            this.pos.y = this.nav_rally.pos.y
            rally_exec_log[#rally_exec_log + 1] = { tag = tag, id = this.id, x = this.pos.x, y = this.pos.y }
            return false
        end,
        y_soldier_melee_block_and_attacks = function(store, this)
            return false, "A_NO_TARGET"
        end,
        y_soldier_ranged_attacks = function(store, this)
            return false, "A_NO_TARGET"
        end,
        soldier_go_back_step = function(store, this)
            return false
        end,
    }
end
local su_base = make_mock_su("script_utils")
local su_4 = make_mock_su("script_utils_4")
local su_pld = make_mock_su("script_utils_pld")
package.loaded["script_utils"] = su_base
package.loaded["script_utils_4"] = su_4
package.loaded["script_utils_pld"] = su_pld

package.loaded["systems"] = {}
local mock_sim = {
    store = nil,
    systems_on_update = {},
    init = function(self, store) self.store = store end,
    insert_entity = function(self, e)
        self.store.entities[e.id] = e
    end,
    remove_entity = function(self, e)
        self.store.entities[e.id] = nil
    end,
    update = function() end,
    do_tick = function() end,
    prepare_render = function() end,
}
package.loaded["simulation"] = mock_sim

-- === Load real hooks_sim, commands, overlay, lobby_prefs ===
local hooks_sim = require("kr_mp.hooks_sim")
local commands = require("kr_mp.commands")
local overlay = require("kr_mp.overlay")

local wrapped_registry = {}
local mock_hooks = {
    orig_pairs = pairs,
    VISUAL_SYSTEMS = {},
    LOCAL_ID_BASE = 100000000,
    entity_ids = {},
    local_entity_depth = 0,
    sim_exec_depth = 0,
    boot = { log = function() end },
    coop = {
        active = true,
        local_pid = 1,
        max_tech = true,
        is_active = function(self) return self.active end,
        on_before_sim_init = function() end,
        on_after_sim_init = function() end,
        on_entity_inserted = function() end,
        can_use_power = function() return true end,
        get_power_slot_info = function() return { kind = "reinforcement" } end,
        get_player_reinf_spec = function() return { gen = 1 } end,
        with_power_context = function(_, _, fn) return pcall(fn) end,
        get_tick_reserved_gold = function() return 0 end,
        on_power_fired = function() end,
    },
    lockstep = { is_active = function() return true end, is_running = function() return true end },
    is_mp_active = function(self) return true end,
    is_sync_active = function(self) return true end,
    ensure_game_and_gui_hooks = function() end,
    add_entity_id = function(self, id) self.entity_ids[#self.entity_ids + 1] = id end,
    wrap_once = function(tbl, key, tag, builder)
        if type(tbl) ~= "table" or type(tbl[key]) ~= "function" then return false end
        local k = tostring(tbl) .. ":" .. tostring(key) .. ":" .. tostring(tag)
        if wrapped_registry[k] then return false end
        wrapped_registry[k] = true
        tbl[key] = builder(tbl[key])
        return true
    end,
    wrap_local_ui = function() end,
}

hooks_sim.install_simulation(mock_hooks)
local store = { tick = 120, tick_ts = 2.0, entities = {}, pending_inserts = {}, pending_removals = {} }
mock_sim:init(store, {})
commands:set_mp(mock_hooks.coop, mock_hooks.lockstep)

-- === PART 1 TESTS: Universal G1..G6 Draggable Reinforcements ===
local next_id = 100
local function make_reinf(tpl, x, y, cx, cy, has_native_ng, native_sid)
    next_id = next_id + 1
    local e = {
        id = next_id,
        template_name = tpl,
        pos = { x = x, y = y },
        soldier = {},
        reinforcement = { duration = 20, ts = 1.0, squad_id = native_sid },
        nav_rally = { pos = { x = x, y = y }, center = { x = cx, y = cy }, new = false, requires_node_nearby = true },
        health = { hp = 110, hp_max = 110, dead = false },
        ui = { can_click = true },
        sound_events = { insert = "ReinforcementTaunt" },
    }
    if has_native_ng then
        e.nav_grid = mock_E:clone_c("nav_grid")
    end
    return e
end

-- 1A. Simulate P1 casting G1 reinforcements (sync insert_entity) and P2 casting G4 (pending_inserts) on SAME tick & pixel
local spawned_g1 = {}
local spawned_g4 = {}
commands.orig_power_fire[2] = function(btn, wx, wy)
    if btn._kind == "g1" then
        for _, off in ipairs({ { 0, -20 }, { -20, 10 }, { 20, 10 } }) do
            local e = make_reinf("re1_legionnaire_ranged_1", wx + off[1], wy + off[2], wx, wy, false, nil)
            spawned_g1[#spawned_g1 + 1] = e
            mock_sim:insert_entity(e)
        end
    elseif btn._kind == "g4" then
        for _, off in ipairs({ { 10, -10 }, { -10, 10 } }) do
            local e = make_reinf("soldier_kr4_reinforcement_flaming_trident", wx + off[1], wy + off[2], wx, wy, false, nil)
            spawned_g4[#spawned_g4 + 1] = e
            store.pending_inserts[#store.pending_inserts + 1] = e
        end
        local pl = make_reinf("soldier_kr4_reinforcement_pit_lord", wx - 14, wy - 14, wx, wy, false, nil)
        spawned_g4[#spawned_g4 + 1] = pl
        store.pending_inserts[#store.pending_inserts + 1] = pl
    end
end

local fake_btn = { _kind = "g1", cooldown_time = 10 }
local fake_game = { store = store, simulation = mock_sim, game_gui = { power_2 = fake_btn, set_mode = function() end } }

commands:execute({ op = "POWER_FIRE", idx = 2, wx = 400, wy = 300, player = 1 }, fake_game, mock_hooks.boot)
fake_btn._kind = "g4"
commands:execute({ op = "POWER_FIRE", idx = 2, wx = 400, wy = 300, player = 2 }, fake_game, mock_hooks.boot)

-- Flush G4 pending inserts via sim:insert_entity
while #store.pending_inserts > 0 do
    mock_sim:insert_entity(table.remove(store.pending_inserts, 1))
end

check(#spawned_g1 == 3, "G1 spawned 3 soldiers")
check(#spawned_g4 == 3, "G4 spawned 2 tridents + 1 pit lord")

local g1_sid = spawned_g1[1].reinforcement.squad_id
local g4_sid = spawned_g4[1].reinforcement.squad_id
check(g1_sid and g1_sid >= 90000001, "G1 assigned deterministic squad_id")
check(g4_sid and g4_sid >= 90000002, "G4 assigned deterministic squad_id")
check(g1_sid ~= g4_sid, "P1 G1 and P2 G4 on same tick+pixel got DISTINCT squad_ids!")

for i = 1, 3 do
    local e = spawned_g1[i]
    check(e.nav_grid ~= nil and e.nav_grid.valid_terrains == bit.bor(TERRAIN_LAND, TERRAIN_ICE), "G1[" .. i .. "] has valid nav_grid")
    check(e._kr_mp_reinf_drag == true, "G1[" .. i .. "] marked _kr_mp_reinf_drag")
    check(e.reinforcement.squad_id == g1_sid, "G1[" .. i .. "] shares squad_id")
    check(e.sound_events.change_rally_point == "ReinforcementTaunt", "G1[" .. i .. "] got rally voice event")
end
for i = 1, 3 do
    local e = spawned_g4[i]
    check(e.nav_grid ~= nil, "G4[" .. i .. "] has nav_grid")
    check(e._kr_mp_reinf_drag == true, "G4[" .. i .. "] marked _kr_mp_reinf_drag")
    check(e.reinforcement.squad_id == g4_sid, "G4[" .. i .. "] shares squad_id")
end

-- 1B. Native G5 reinforcement keeps original squad_id and _kr_mp_reinf_drag == nil
local g5 = make_reinf("soldier_reinforcement_shadow_archer_01", 500, 350, 500, 350, true, 777)
mock_sim:insert_entity(g5)
check(g5.reinforcement.squad_id == 777, "G5 keeps native squad_id")
check(g5._kr_mp_reinf_drag == nil, "G5 not flagged _kr_mp_reinf_drag")

-- 1C. Local UI entity untouched
local loc_e = make_reinf("re1_preview", 10, 10, 10, 10, false, nil)
loc_e._kr_mp_local = true
mock_sim:insert_entity(loc_e)
check(loc_e.nav_grid == nil, "Local entity not given nav_grid")

-- 1D. Single-player fallback grouping (without POWER_FIRE) groups G2/G3 squad by (tick, center)
local sp1 = make_reinf("soldier_re_5_1", 210, 190, 200, 200, false, nil)
local sp2 = make_reinf("soldier_re_5_2", 190, 210, 200, 200, false, nil)
mock_sim:insert_entity(sp1)
mock_sim:insert_entity(sp2)
check(sp1.reinforcement.squad_id ~= nil and sp1.reinforcement.squad_id == sp2.reinforcement.squad_id, "Single-player G3 squad grouped deterministically")

-- 1E. Execute REINF_RALLY on G1 squad & verify formation offsets + SU rally walk
commands:execute({ op = "REINF_RALLY", id = spawned_g1[1].id, sid = g1_sid, wx = 600, wy = 320, player = 1 }, fake_game, mock_hooks.boot)
check(spawned_g1[1].nav_rally.new == true and spawned_g1[1].nav_rally.pos.x == 600 and spawned_g1[1].nav_rally.pos.y == 300, "G1[1] rallied with (0,-20) offset")
check(spawned_g1[2].nav_rally.new == true and spawned_g1[2].nav_rally.pos.x == 580 and spawned_g1[2].nav_rally.pos.y == 330, "G1[2] rallied with (-20,+10) offset")
check(spawned_g1[3].nav_rally.new == true and spawned_g1[3].nav_rally.pos.x == 620 and spawned_g1[3].nav_rally.pos.y == 330, "G1[3] rallied with (+20,+10) offset")
check(spawned_g4[1].nav_rally.new == false, "Unrelated G4 squad untouched by G1 rally")

-- Step G1 through SU.y_soldier_melee_block_and_attacks (matches all/scripts.lua & scripts_4.lua)
for i = 1, 3 do
    local brk = su_base.y_soldier_melee_block_and_attacks(store, spawned_g1[i])
    check(brk == true, "G1[" .. i .. "] melee hook intercepted and executed y_hero_new_rally")
    check(spawned_g1[i].nav_rally.new == false, "G1[" .. i .. "] cleared nav_rally.new")
end
check(spawned_g1[1].pos.x == 600 and spawned_g1[1].pos.y == 300, "G1[1] walked to rallied destination")
check(#rally_exec_log == 3, "All 3 G1 soldiers ran y_hero_new_rally")

-- Step G4 through script_utils_pld (matches kr4_reinforcement.update)
commands:execute({ op = "REINF_RALLY", id = spawned_g4[1].id, sid = g4_sid, wx = 700, wy = 400, player = 2 }, fake_game, mock_hooks.boot)
local brk4 = su_pld.y_soldier_melee_block_and_attacks(store, spawned_g4[1])
check(brk4 == true and spawned_g4[1].pos.x == 710 and spawned_g4[1].pos.y == 390, "G4 rallied via script_utils_pld")

-- Step melee-less ranged reinforcement through y_soldier_ranged_attacks
local brk_r = su_4.y_soldier_ranged_attacks(store, spawned_g4[2])
check(brk_r == true and spawned_g4[2].pos.x == 690 and spawned_g4[2].pos.y == 410, "Ranged-only fallback works via script_utils_4")

-- Expired reinforcement does NOT start walking
spawned_g4[3].reinforcement.ts = -50
local brk_exp = su_pld.y_soldier_melee_block_and_attacks(store, spawned_g4[3])
check(brk_exp == true and spawned_g4[3].nav_rally.new == false and spawned_g4[3].pos.x ~= 686, "Expired reinforcement cancels rally instead of walking")

-- Native G5 with nav_rally.new is NOT intercepted by SU hook (its own kr5 loop handles it)
g5.nav_rally.new = true
local brk_g5, st_g5 = su_base.y_soldier_melee_block_and_attacks(store, g5)
check(brk_g5 == false and st_g5 == "A_NO_TARGET" and g5.nav_rally.new == true, "Native G5 bypassed cleanly")

-- REINF_RALLY center fallback when nav_rally.pos is off-grid
spawned_g1[1].nav_rally.pos = { x = -999, y = 0 }
spawned_g1[1].nav_rally.center = { x = 600, y = 320 }
commands:execute({ op = "REINF_RALLY", id = spawned_g1[1].id, sid = g1_sid, wx = 640, wy = 350, player = 1 }, fake_game, mock_hooks.boot)
check(#spawned_g1[1].nav_grid.waypoints == 1, "REINF_RALLY fell back to nav_rally.center when pos off-grid")

-- === PART 2 TESTS: Draggable Collapsed HUD Badge ("小标") ===
local actions = {}
overlay:init(function(act, arg) actions[#actions + 1] = { act = act, arg = arg } end)
overlay:set_status({ mp_active = true, mp_pid = 1, mp_phase = "RUNNING", mp_rtt = 28, mp_g1 = 500, mp_g2 = 450 })

-- Initial full draw establishes _last_bar
overlay.visible = true
overlay.mini_x = nil
overlay.mini_y = nil
overlay:draw()
check(overlay._last_bar ~= nil, "Full HUD recorded _last_bar")

-- Collapse HUD -> draws mini badge
overlay.visible = false
overlay:draw()
local mr = overlay._mini_rect
check(mr ~= nil and mr.w == 58 and mr.h == 28, "Collapsed badge drawn with 58x28 rect")
check(mr.x >= 6 and mr.x <= win_w - 58 - 6, "Collapsed badge starts clamped in X")
check(mr.y >= 6 and mr.y <= win_h - 28 - 6, "Collapsed badge starts clamped in Y")

-- Hit detection (pixel + Android normalized)
check(overlay:is_point_over_hud(mr.x + 10, mr.y + 10) == true, "is_point_over_hud true inside mini badge")
check(overlay:is_point_over_hud(mr.x - 10, mr.y + 10) == false, "is_point_over_hud false outside mini badge")
check(overlay:is_point_over_hud((mr.x + 10) / win_w, (mr.y + 10) / win_h) == true, "is_point_over_hud supports Android normalized coords")

-- Right-click on badge does NOT consume
check(overlay:mousepressed(mr.x + 10, mr.y + 10, 2) == false, "Right-click passes through collapsed badge")
-- Left-click outside badge does NOT consume
check(overlay:mousepressed(10, 500, 1) == false, "Click outside collapsed badge passes through")

-- 2A. Click (with tiny 2px jitter) -> restores full HUD!
mouse1_down = true
check(overlay:mousepressed(mr.x + 15, mr.y + 12, 1) == true, "Left press on badge consumed")
check(overlay:mousemoved(mr.x + 17, mr.y + 13, 2, 1) == true, "Small jitter during press consumed")
mouse1_down = false
check(overlay:mousereleased(mr.x + 17, mr.y + 13, 1) == true, "Release on badge consumed")
check(overlay.visible == true, "Clicking badge expanded full HUD!")
check(actions[#actions] and actions[#actions].act == "show", "on_action('show') fired on click expand")

-- 2B. Drag (> 5px movement) -> moves badge, stays collapsed, triggers save!
overlay.visible = false
overlay:draw()
local sx, sy = overlay.mini_x, overlay.mini_y
mouse1_down = true
check(overlay:mousepressed(sx + 10, sy + 10, 1) == true, "Press to drag badge")
check(overlay:mousemoved(sx + 10 + 180, sy + 10 + 220, 180, 220) == true, "Drag move consumed")
check(overlay._mini_moved == true, "Drag threshold exceeded")
check(overlay.mini_x == sx + 180 and overlay.mini_y == sy + 220, "Badge moved to exact dragged coordinates")
mouse1_down = false
check(overlay:mousereleased(sx + 190, sy + 230, 1) == true, "Drag release consumed")
check(overlay.visible == false, "Dragging badge keeps HUD collapsed!")
check(actions[#actions] and actions[#actions].act == "hud_mini_moved", "on_action('hud_mini_moved') fired after drag")

-- 2C. Extreme off-screen drag clamps strictly inside viewport
mouse1_down = true
overlay:mousepressed(overlay.mini_x + 5, overlay.mini_y + 5, 1)
overlay:mousemoved(-5000, -5000, -5000, -5000)
check(overlay.mini_x == 6 and overlay.mini_y == 6, "Top-left clamping works")
overlay:mousemoved(99999, 99999, 99999, 99999)
check(overlay.mini_x == win_w - 58 - 6 and overlay.mini_y == win_h - 28 - 6, "Bottom-right clamping works")
mouse1_down = false
overlay:mousereleased(win_w, win_h, 1)

-- 2D. Alt-Tab / focus-loss guard clears stuck _mini_drag on draw()
mouse1_down = true
overlay:mousepressed(overlay.mini_x + 5, overlay.mini_y + 5, 1)
check(overlay._mini_drag == true, "Drag started")
mouse1_down = false -- lost mouseup off-window
overlay:draw()
check(overlay._mini_drag == false and overlay._consumed_down == false, "Focus-loss guard cleared stuck drag")

-- 2E. Toast still displays cleanly while collapsed
overlay:show_toast("测试悬浮提示", 3.0)
overlay:draw_toast(nil)
check(overlay._last_toast_rect ~= nil and overlay._last_toast_rect.w > 0, "Toast renders cleanly even while HUD is collapsed")

-- 2F. lobby_prefs round-trips hud_mini_x / hud_mini_y
local lobby_prefs = require("kr_mp.lobby_prefs")
local fake_lobby = {
    sakura_ip_input = "", lan_ip_input = "127.0.0.1", server_input = "",
    recent_addrs = {},
    room = { level_idx = 101, level_difficulty = 2, econ_mode = "independent", tower_mode = "owned", heroes = { 53, 54 }, towers = { 1, 2, 3 } },
    overlay = { mini_x = 321, mini_y = 456 },
    normalize_delay_turns = function(v) return v or 2 end,
    ensure_room_defaults = function() end,
}
lobby_prefs.save_prefs(fake_lobby)
local fake_lobby2 = {
    sakura_ip_input = "", lan_ip_input = "127.0.0.1", server_input = "",
    recent_addrs = {},
    room = { level_idx = 101, level_difficulty = 2, econ_mode = "independent", tower_mode = "owned", heroes = { 53, 54 }, towers = { 1, 2, 3 } },
    overlay = { mini_x = nil, mini_y = nil },
    normalize_delay_turns = function(v) return v or 2 end,
    ensure_room_defaults = function() end,
}
lobby_prefs.load_prefs(fake_lobby2)
check(fake_lobby2.overlay.mini_x == 321 and fake_lobby2.overlay.mini_y == 456, "lobby_prefs persisted & restored hud_mini_x/y")

print(string.format("ALL %d CHECKS PASSED!", pass_count))
