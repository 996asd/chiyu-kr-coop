local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Comprehensive verifier for tower upgrade hover-DESYNC & 6 latent Co-op fixes
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

-- Stubs for FL 8.2.0 modules
local emitted_signals = {}
local sig_handlers = {}
package.loaded["hump.signal"] = {
    register = function(name, fn)
        sig_handlers[name] = sig_handlers[name] or {}
        table.insert(sig_handlers[name], fn)
    end,
    emit = function(name, ...)
        emitted_signals[#emitted_signals + 1] = { name = name, args = { ... } }
        for _, fn in ipairs(sig_handlers[name] or {}) do fn(...) end
    end,
}
package.loaded["klua.macros"] = {
    round = function(x) return math.floor(x + 0.5) end,
    clamp = function(a, b, v) return math.max(a, math.min(b, v)) end,
}
package.loaded["kr_mp.fonts"] = { get = function() return nil end }
package.loaded["kr_mp.ui_assets"] = {
    THEME = {},
    play_sfx = function() end,
    compute_hud_scale = function() return 1 end,
    make_font_map = function() return {} end,
}
package.loaded["grid_db"] = {
    find_waypoints = function() return {} end,
    cell_is_only = function() return true end,
    cell_is = function() return true end,
}
package.loaded["path_db"] = { valid_node_nearby = function() return true end }
package.loaded["sound_db"] = { queue = function() end, stop_all = function() end, resume = function() end }
package.loaded["hump.vector-light"] = { dist = function() return 10 end }
package.loaded["utils"] = { is_inside_ellipse = function() return true end }
package.loaded["storage"] = {
    load_slot = function() return {} end,
    save_slot = function() return true end,
    create_slot = function() return {} end,
    set_active_slot = function() end,
}
package.loaded["systems"] = { main_script = { init = function() end, on_insert_unconditional = function() end, on_remove_unconditional = function() end, on_update = function() end } }

local fake_templates = {
    tower_arcane_wizard_lvl4 = { tower = { type = "arcane_wizard5", price = 280 } },
    tower_build_archer = { tower = { type = "build_animation", price = 0 }, build_name = "tower_archer_1" },
    tower_archer_1 = { tower = { type = "archer", price = 70 } },
    tower_holder = { tower = { type = "holder", price = 0 } },
    soldier_merc = { unit = { price = 120 } },
    controller_tower_swap = { template_name = "controller_tower_swap" },
    decal_tower_arcane_wizard_empowerment_preview = { template_name = "decal_tower_arcane_wizard_empowerment_preview" },
    decal_crossbow_eagle_preview = { template_name = "decal_crossbow_eagle_preview" },
    decal_custom_future_preview = { template_name = "decal_custom_future_preview" },
    normal_tower = { template_name = "normal_tower", tower = { type = "mage", price = 100 } },
}
local fake_E = {
    last_id = 10,
    entities = fake_templates,
    get_template = function(self, name) return fake_templates[name] end,
    create_entity = function(self, name)
        self.last_id = self.last_id + 1
        local tpl = fake_templates[name] or {}
        return { id = self.last_id, template_name = name, tower = tpl.tower and { type = tpl.tower.type, price = tpl.tower.price } or nil }
    end,
    clone_entity = function(self, e)
        self.last_id = self.last_id + 1
        return { id = self.last_id, template_name = e.template_name }
    end,
    filter = function() return {} end,
    filter_iter = function(self, entities, comp)
        local keys = {}
        for k, v in pairs(entities) do
            if type(k) == "number" and v and (not comp or v[comp]) then keys[#keys + 1] = k end
        end
        table.sort(keys)
        local i = 0
        return function()
            i = i + 1
            local k = keys[i]
            if k then return k, entities[k] end
        end
    end,
}
package.loaded["entity_db"] = fake_E

local inserted_entities = {}
local fake_sim = {
    store = nil,
    init = function(self, store) self.store = store end,
    insert_entity = function(self, e)
        self.store.entities[e.id] = e
        self.store.entity_count = (self.store.entity_count or 0) + 1
        inserted_entities[#inserted_entities + 1] = e
    end,
    remove_entity = function(self, e)
        self.store.entities[e.id] = nil
        self.store.entity_count = math.max(0, (self.store.entity_count or 1) - 1)
    end,
    update = function() end,
    do_tick = function() end,
    prepare_render = function() end,
}
package.loaded["simulation"] = fake_sim

-- Globals used by hooks_gui_actions / hooks_gui_guards
GUI_MODE_IDLE = "idle"
GUI_MODE_SWAP_TOWER = "swap"
GUI_MODE_SELECT_POINT = "select_point"
TICK_LENGTH = 1 / 60
IS_ANDROID = false
love = { keyboard = { isDown = function() return false end }, mouse = { isDown = function() return false end } }

local submitted_cmds = {}
local hooks = require("kr_mp.hooks")
local commands = require("kr_mp.commands")
local coop = require("kr_mp.coop")
local state_hash = require("kr_mp.state_hash")
local prng = require("kr_mp.prng")

local fake_boot = { log = function() end }
hooks:init(fake_boot, nil, nil, coop, nil)
hooks.submit_command = function(self, cmd)
    submitted_cmds[#submitted_cmds + 1] = cmd
    return true
end

-- Activate coop
coop.active = true
coop.local_pid = 2
coop.econ_mode = "independent"
coop.tower_mode = "owned"
coop.gold = { [1] = 700, [2] = 240 }
coop.shared_gold = 940

-- === TEST 1: Local preview template isolation & E.last_id protection ===
check(hooks.is_local_template("decal_tower_arcane_wizard_empowerment_preview"), "arcane preview is local template")
check(hooks.is_local_template("decal_crossbow_eagle_preview"), "crossbow eagle preview is local template")
check(hooks.is_local_template("decal_tower_wizard_empowerment_preview"), "kr6 wizard preview is local template")
check(hooks.is_local_template("decal_archers_skill_b_preview"), "kr6 archers skill_b preview is local template")
check(hooks.is_local_template("decal_balloon_eagle_preview"), "balloon eagle preview is local template")
check(hooks.is_local_template("royal_archers_decal_preview_controller"), "royal archers preview controller is local template")
check(hooks.is_local_template("decal_custom_future_preview"), "future decal_*_preview pattern is local template")
check(not hooks.is_local_template("normal_tower"), "normal tower is NOT local template")

hooks.sim_exec_depth = 1 -- simulate inside sim:do_tick!
local before_id = fake_E.last_id
local prev_ent = fake_E:create_entity("decal_tower_arcane_wizard_empowerment_preview")
check(prev_ent._kr_mp_local == true, "preview decal forced _kr_mp_local even inside sim:do_tick")
check(prev_ent.id >= hooks.LOCAL_ID_BASE, "preview decal assigned in LOCAL_ID_BASE")
check(fake_E.last_id == before_id, "preview decal did NOT increment E.last_id")
local sim_ent = fake_E:create_entity("normal_tower")
check(not sim_ent._kr_mp_local and sim_ent.id == before_id + 1, "normal sim entity increments E.last_id normally")
hooks.sim_exec_depth = 0

-- === TEST 2: TowerMenuButton:on_enter / on_exit hover_active & args isolation + TowerMenu:hide cleanup ===
local store = { entities = {}, entity_count = 0, tick = 1110, player_gold = 940, lives = 20, wave_group_number = 0 }
fake_sim.store = store
hooks.active_store = store

local arcane = { id = 41, template_name = "tower_arcane_wizard_lvl4", tower = { type = "arcane_wizard5", spent = 760 }, ui = { can_click = true }, _mp_owner = 2 }
store.entities[41] = arcane

PickView = {
    update = function(self, dt) end,
    on_down = function(self, btn, x, y) return true end,
    rally_tower = function() return false end,
    rally_hero = function() return false end,
    rally_reinforcement = function() return false end,
}
TowerMenuButton = {
    on_enter = function(self)
        if self.entity and self.entity.ui then
            self.entity.ui.hover_active = true
            self.entity.ui.args = self.item.action_arg
        end
    end,
    on_exit = function(self)
        if self.entity and self.entity.ui then
            self.entity.ui.hover_active = nil
            self.entity.ui.args = nil
        end
    end,
    on_click = function(self) end,
}
TowerMenu = {
    show = function(self) end,
    hide = function(self) end,
}
WaveFlag = { on_enter = function() end, on_click = function() end }
InfoBar = { show = function() end, update_stats = function() end }
TowerTooltip = { show = function() end }
TowerMenuTooltip = { show = function() end }

local desel_all_calls = 0
local desel_ent_calls = 0
local fake_gui = {
    mode = GUI_MODE_IDLE,
    selected_entity = arcane,
    game = { store = store, simulation = fake_sim },
    u2g = function(self, p) return p.x, p.y end,
    entity_at_pos = function() return nil end,
    show_clickable_hover = function() end,
    show_ghost_hover = function() end,
    block_random_power = function() end,
    c_swap_tower = function() end,
    keypressed = function() end,
    restart_game = function() end,
    go_to_map = function() end,
    select_entity = function(self, e) self.selected_entity = e end,
    deselect_entity = function(self)
        desel_ent_calls = desel_ent_calls + 1
        self.selected_entity = nil
    end,
    deselect_all = function(self)
        desel_all_calls = desel_all_calls + 1
        if self.selected_entity and self.selected_entity.user_selection then
            self.selected_entity.user_selection.in_progress = false
        end
        self.selected_entity = nil
    end,
}
game = { store = store, simulation = fake_sim, game_gui = fake_gui }

hooks:install_gui_hooks(fake_gui)

local btn_emp = { entity = arcane, item = { action = "upgrade_power", action_arg = "empowerment" }, parent = { tweening = false, hide = function() end }, disable = function() end }
TowerMenuButton.on_enter(btn_emp)
check(arcane.ui.hover_active == nil, "TowerMenuButton:on_enter did NOT leak hover_active onto sim entity")
check(arcane.ui.args == nil, "TowerMenuButton:on_enter did NOT leak ui.args onto sim entity")
TowerMenuButton.on_exit(btn_emp)
check(arcane.ui.hover_active == nil and arcane.ui.args == nil, "TowerMenuButton:on_exit leaves hover_active/args nil")

-- Even if somehow hover_active was set before hide, TowerMenu:hide clears it
arcane.ui.hover_active = true
arcane.ui.args = "empowerment"
TowerMenu.hide({ entity = arcane })
check(arcane.ui.hover_active == nil and arcane.ui.args == nil, "TowerMenu:hide clears stale hover_active/args")

-- === TEST 3: PickView:update auto-deselects removed/upgraded entity without bogus TW_USER_SEL cancel ===
local old_holder = { id = 8, template_name = "tower_holder_blocked_underground", tower = { type = "holder_blocked_underground" }, user_selection = { in_progress = true } }
fake_gui.selected_entity = old_holder
-- old_holder is NOT in store.entities[8] (it was unblocked/replaced!)
submitted_cmds = {}
desel_all_calls = 0
PickView.update({}, 0.016)
check(desel_all_calls == 1, "PickView:update auto-deselected removed entity")
check(fake_gui.selected_entity == nil, "selected_entity cleared after auto-deselect")
check(#submitted_cmds == 0, "auto-deselect of removed entity did NOT emit bogus TW_USER_SEL cancel")

-- Test upgrade_power click calls deselect_entity (so 1 click re-opens menu cleanly)
arcane.powers = { empowerment = { level = 0, max_level = 3, price_base = 200, price_inc = 150 } }
fake_gui.selected_entity = arcane
desel_ent_calls = 0
submitted_cmds = {}
TowerMenuButton.on_click(btn_emp)
check(#submitted_cmds == 1 and submitted_cmds[1].op == "TW_POWER", "upgrade_power submits TW_POWER")
check(desel_ent_calls == 1 and fake_gui.selected_entity == nil, "upgrade_power calls deselect_entity cleanly")

-- === TEST 4: coop:get_upgrade_price honors upgrade_price_multiplier ===
local disc_tower = { tower = { type = "arcane_wizard5", upgrade_price_multiplier = 0.85 } }
-- 280 * 0.85 = 238 -> ceil = 238 -> floor(238/10)*10 = 230
check(coop:get_upgrade_price(disc_tower, "tower_arcane_wizard_lvl4") == 230, "get_upgrade_price applies 0.85 multiplier (280 -> 230)")
local full_tower = { tower = { type = "arcane_wizard5" } }
check(coop:get_upgrade_price(full_tower, "tower_arcane_wizard_lvl4") == 280, "get_upgrade_price without multiplier stays 280")
local unblk_holder = { tower = { type = "holder_blocked_underground", upgrade_price_multiplier = 0.5 }, tower_holder = { unblock_price = 200 } }
check(coop:get_upgrade_price(unblk_holder, "tower_holder") == 100, "get_upgrade_price applies multiplier to unblock_price")

-- === TEST 5: Same-tick atomic spend reservation, duplicate-upgrade guard, and personal gold checks ===
coop.econ_mode = "independent"
coop.gold = { [1] = 700, [2] = 100 } -- 2P only has 100 gold, 1P has 700 gold (canonical=800)
coop:on_tick_begin(store)
check(store.player_gold == 800, "canonical gold = 800 at tick begin")

local h1 = { id = 50, template_name = "tower_holder", tower = { type = "holder", spent = 0 } }
local h2 = { id = 51, template_name = "tower_holder", tower = { type = "holder", spent = 0 } }
store.entities[50] = h1
store.entities[51] = h2

-- 2P tries to build two 70g towers on SAME tick with only 100g: first succeeds, second rejected!
commands:execute({ op = "TW_UPGRADE", id = 50, arg = "tower_build_archer", player = 2 }, game, fake_boot)
check(h1.tower.upgrade_to == "tower_build_archer" and h1.tower._mp_actor == 2, "first 70g tower upgrade accepted for 2P")
commands:execute({ op = "TW_UPGRADE", id = 51, arg = "tower_build_archer", player = 2 }, game, fake_boot)
check(h2.tower.upgrade_to == nil, "second same-tick 70g tower upgrade rejected for 2P (only 30g left after reservation)")

-- 1P tries to overwrite h1 on same tick while h1 already has upgrade_to set: rejected!
commands:execute({ op = "TW_UPGRADE", id = 50, arg = "tower_arcane_wizard_lvl4", player = 1 }, game, fake_boot)
check(h1.tower.upgrade_to == "tower_build_archer" and h1.tower._mp_actor == 2, "simultaneous TW_UPGRADE on same holder does NOT overwrite first actor")

-- 2P (only 30g unreserved, 100g total) tries to buy 120g soldier while canonical gold is 800g: rejected!
local b1 = { id = 52, template_name = "tower_barrack", tower = { type = "barrack" }, barrack = {}, _mp_owner = 2 }
store.entities[52] = b1
commands:execute({ op = "TW_BUY_SOLDIER", id = 52, arg = "soldier_merc", player = 2 }, game, fake_boot)
check(b1.barrack.unit_bought == nil, "TW_BUY_SOLDIER checks personal gold (rejects 120g when 2P has 100g even if canonical=800g)")

-- 2P tries to trigger paid repair (150g) while only having 100g: rejected!
local r1 = { id = 53, template_name = "tower_broken", tower = { type = "tower_broken" }, user_selection = {}, repair = { cost = 150, active = false }, _mp_owner = 2 }
store.entities[53] = r1
commands:execute({ op = "TW_USER_SEL", id = 53, phase = "repair", player = 2 }, game, fake_boot)
check(r1.user_selection.in_progress == nil, "TW_USER_SEL(repair) checks personal gold (rejects 150g for 2P)")

-- 1P (700g) CAN repair 150g tower they own
r1._mp_owner = 1
commands:execute({ op = "TW_USER_SEL", id = 53, phase = "repair", player = 1 }, game, fake_boot)
check(r1.user_selection.in_progress == true and r1._mp_actor == 1, "TW_USER_SEL(repair) succeeds when actor can afford 150g")

-- === TEST 6: controller_tower_swap & royal_archers_tower_combination preserve _mp_owner ===
local swap_t1 = { id = 60, tower = { type = "ghost", holder_id = "1" }, _mp_owner = 1 }
local swap_t2 = { id = 61, tower = { type = "mage", holder_id = "2" }, _mp_owner = 2 }
store._dominant_entity = { template_name = "controller_tower_swap_overseer", tower_1 = swap_t1, tower_2 = swap_t2 }
local new_t1_at_2 = { id = 62, template_name = "tower_ghost", tower = { type = "ghost", holder_id = "2" } }
local new_t2_at_1 = { id = 63, template_name = "tower_mage", tower = { type = "mage", holder_id = "1" } }
local new_holder_at_1 = { id = 64, template_name = "tower_holder", tower = { type = "holder", holder_id = "1" } }
fake_sim:insert_entity(new_t1_at_2)
fake_sim:insert_entity(new_t2_at_1)
fake_sim:insert_entity(new_holder_at_1)
check(new_t1_at_2._mp_owner == 1, "controller_tower_swap preserves tower_1 _mp_owner=1 at new slot")
check(new_t2_at_1._mp_owner == 2, "controller_tower_swap preserves tower_2 _mp_owner=2 at new slot")
check(new_holder_at_1._mp_owner == nil, "controller_tower_swap leaves empty holder unowned")

store._dominant_entity = { template_name = "royal_archers_tower_combination_controller", tower_1 = swap_t2, tower_2 = swap_t1 }
local combo_t = { id = 65, template_name = "tower_royal_combo", tower = { type = "royal_combo", holder_id = "2" } }
fake_sim:insert_entity(combo_t)
check(combo_t._mp_owner == 2, "royal_archers_tower_combination_controller preserves tower_1 _mp_owner=2")
store._dominant_entity = nil

-- === TEST 7: click_proxies forwarding on locked/webbed towers ===
local web_proxy = { id = 70, ui = { can_click = true, clicked = nil } }
local webbed_tower = { id = 71, tower = { type = "archer" }, ui = { can_click = true, click_proxies = { web_proxy } } }
store.entities[70] = web_proxy
store.entities[71] = webbed_tower
fake_gui.entity_at_pos = function() return webbed_tower end
submitted_cmds = {}
PickView.on_down({}, 1, 100, 100)
check(#submitted_cmds == 1 and submitted_cmds[1].op == "CLICK_ENTITY" and submitted_cmds[1].id == 71, "PickView:on_down syncs CLICK_ENTITY for tower with click_proxies")
commands:execute(submitted_cmds[1], game, fake_boot)
check(web_proxy.ui.clicked == true, "HANDLERS.CLICK_ENTITY forwards click to click_proxies")

-- === TEST 8: state_hash skips preview local entity and diag summary reports non-combat entities ===
local nc_ent = { id = 80, template_name = "level_boss_controller" }
fake_sim:insert_entity(nc_ent)
fake_sim:insert_entity(prev_ent)
local h1_snap = state_hash.compute(store, prng, coop)
fake_sim:remove_entity(prev_ent)
local h2_snap = state_hash.compute(store, prng, coop)
check(h1_snap.hash == h2_snap.hash and h1_snap.ents == h2_snap.ents, "local preview decal has ZERO impact on state_hash & ents")
local diag = state_hash.build_diag_summary(store, 18)
check(diag:find("nc=1", 1, true) ~= nil and diag:find("#80:level_boss_controller", 1, true) ~= nil, "diag summary includes non-combat entity tail: " .. diag)

print(string.format("VERIFY_TOWER_AUDIT: PASS=%d FAIL=%d", pass, fail))
assert(fail == 0, "Some tower audit checks failed!")
