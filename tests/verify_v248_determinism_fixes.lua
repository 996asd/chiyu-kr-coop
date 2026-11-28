local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Verify v2.4.8 Determinism & Exact-Tick DESYNC Diagnostics Fixes
-- Tests all 8 root-cause fixes discovered in Stage 37 tick 41160 forensic audit.

package.path = _KR_REPO .. "/client/?.lua;d:/FL8.2.0/lib/?.lua;d:/FL8.2.0/all/?.lua;" .. package.path

local pass_cnt, fail_cnt = 0, 0
local function check(cond, msg)
    if cond then
        pass_cnt = pass_cnt + 1
    else
        fail_cnt = fail_cnt + 1
        io.write("FAIL: " .. tostring(msg) .. "\n")
    end
end

-- Stub minimal FL globals/modules BEFORE loading KR-MP modules
REF_W = 1024
REF_H = 768
TICK_LENGTH = 1 / 60
IS_ANDROID = false
love = {
    timer = { getTime = function() return os.clock() end },
    filesystem = { getSourceBaseDirectory = function() return _KR_REPO end },
    graphics = {},
}

-- Load real klua.table & hump.signal from FL 8.2.0
require("klua.table")
local signal = require("hump.signal")

-- Stub klua.log, klua.macros, sound_db, grid_db, storage, entity_db, simulation, systems
package.loaded["klua.log"] = {
    new = function() return { error = function() end, info = function() end, debug = function() end } end
}
package.loaded["klua.macros"] = {
    clamp = function(lo, hi, v) if v < lo then return lo elseif v > hi then return hi else return v end end
}
package.loaded["sound_db"] = { queue = function() end, stop_all = function() end, resume = function() end }
package.loaded["grid_db"] = { find_waypoints = function() return {} end, waypoints_cache = {} }

local fake_disk_slot = {
    levels = {},
    upgrades = { archers = 0, barracks = 0, mages = 0, rocks = 0, thunder = 0, reinforcements = 0 },
    heroes = { selected = "hero_vesper", status = {} },
    bag = {},
    gems = 0,
    seen = {},
    reinforcement_count = 7,
    campaign_variant = "iron",
    liuhui = { reinforcement_skins = 3, rand_creep = 2, g1_level10 = true },
    xingyu = { balance = 99 },
}
package.loaded["storage"] = {
    active_slot_idx = 1,
    load_slot = function(self, idx) return fake_disk_slot end,
    save_slot = function() return true end,
    create_slot = function() return fake_disk_slot end,
    set_active_slot = function(self, idx) self.active_slot_idx = idx end,
}

local fake_templates = {
    bolt_1 = { template_name = "bolt_1", bullet = { damage_min = 9, damage_max = 17 } },
    bolt_2 = { template_name = "bolt_2", bullet = { damage_min = 23, damage_max = 43 } },
    bolt_3 = { template_name = "bolt_3", bullet = { damage_min = 40, damage_max = 74 } },
    bolt_archmage = { template_name = "bolt_archmage", bullet = { damage_min = 60, damage_max = 110 } },
    bolt_necromancer = { template_name = "bolt_necromancer", bullet = { damage_min = 45, damage_max = 85 } },
    bullet_ashbite = { template_name = "bullet_ashbite", bullet = { mod = nil } },
    aura_ashbite_skill_a = { template_name = "aura_ashbite_skill_a", aura = { mod = nil } },
    mod_ashbite_skill_b_burn = { template_name = "mod_ashbite_skill_b_burn", dps = { armor_sunder = 0 } },
    bolt_stargazer = {
        template_name = "bolt_stargazer",
        bullet = { damage_min = nil, damage_max = nil, damage_min_config = { 10, 20, 35, 55 }, damage_max_config = { 18, 34, 58, 90 } }
    },
}
local E = {
    last_id = 1,
    entities = fake_templates,
    get_template = function(self, name) return self.entities[name] end,
    set_template = function(self, name, t) self.entities[name] = t end,
    create_entity = function(self, t)
        self.last_id = self.last_id + 1
        return { id = self.last_id, template_name = type(t) == "string" and t or (t and t.template_name) or "ent" }
    end,
    clone_entity = function(self, e)
        self.last_id = self.last_id + 1
        return { id = self.last_id, template_name = e.template_name }
    end,
    filter = function() return {} end,
    filter_iter = function() return function() return nil end end,
}
package.loaded["entity_db"] = E

-- Stub systems (including realistic sys.render:on_insert & prepare_frame)
local S_sys = {
    render = {
        name = "render",
        on_insert = function(self, entity, store)
            if entity.render and entity.render.sprites then
                for _, s in ipairs(entity.render.sprites) do
                    if s.random_ts then
                        s.ts = -math.random() * s.random_ts
                    end
                end
            end
            return true
        end,
        on_remove = function() return true end,
        on_update = function() end,
        prepare_frame = function(self, dt, ts, store)
            for _, e in pairs(store.entities) do
                if e.render and e.render.sprites then
                    for i, s in ipairs(e.render.sprites) do
                        local fn = s._render_frame_name
                        if not fn then
                            -- Simulate FL 8.2.0 render_update_sprite_state mutating sim-read sprite fields
                            s.runs = (s.runs or 0) + 1
                            s.frame_idx = 7
                            s.sync_flag = true
                            s.hidden = true
                            s._animation_missing = true
                            s._render_state_ts = ts
                            s._render_frame_name = "computed_frame_0007"
                            s.frame_name = "computed_frame_0007"
                            fn = s._render_frame_name
                        end
                        e.render.frames[i] = { _frame_name = fn }
                    end
                end
            end
        end,
    },
    main_script = {
        name = "main_script",
        init = function() end,
        on_insert_unconditional = function() end,
        on_remove_unconditional = function() end,
        on_update = function() end,
    },
}
package.loaded["systems"] = S_sys

local sim = {
    init = function(self, store, sys_names)
        self.store = store
        self.systems_on_update = { S_sys.main_script, S_sys.render }
        self.systems_on_update_count = 2
    end,
    insert_entity = function(self, e)
        self.store.entities[e.id] = e
        S_sys.render:on_insert(e, self.store)
    end,
    remove_entity = function(self, e)
        self.store.entities[e.id] = nil
    end,
    update = function() end,
    do_tick = function() end,
    prepare_render = function(self, dt)
        S_sys.render:prepare_frame(dt, self.store.tick_ts or 0, self.store)
    end,
}
package.loaded["simulation"] = sim

-- Stub UI classes before installing GUI guards
NotificationView = { show = function() end }
PickView = { update = function() end }
TowerMenuButton = { on_enter = function() end, on_exit = function() end }
TowerMenu = { show = function() end, hide = function() end }
WaveFlag = { on_enter = function() end }
PauseView = { show = function() end, hide = function() end }
VictoryView = { show = function() end }
DefeatView = { show = function() end }
DragEntityView = { on_down = function() end, on_up = function() end, update = function() end }

InfoBar = {
    show = function() end,
    update_stats = function(self, ent)
        -- Simulate scripts.tower_stargazers.get_info mutating shared bullet template!
        local b = E:get_template("bolt_stargazer")
        if not b.bullet.damage_min or not b.bullet.damage_max then
            b.bullet.damage_min = b.bullet.damage_min_config[ent.tower.level]
            b.bullet.damage_max = b.bullet.damage_max_config[ent.tower.level]
        end
        return { damage_min = b.bullet.damage_min, damage_max = b.bullet.damage_max }
    end,
}
TowerTooltip = {
    show = function(self, lvl)
        local b = E:get_template("bolt_stargazer")
        if not b.bullet.damage_min or not b.bullet.damage_max then
            b.bullet.damage_min = b.bullet.damage_min_config[lvl]
            b.bullet.damage_max = b.bullet.damage_max_config[lvl]
        end
        return b.bullet.damage_min, b.bullet.damage_max
    end,
}
TowerMenuTooltip = { show = function() end }

local prng = require("kr_mp.prng")
local hooks = require("kr_mp.hooks")
local hooks_gui_guards = require("kr_mp.hooks_gui_guards")
local state_hash = require("kr_mp.state_hash")
local lockstep = require("kr_mp.lockstep")
local coop = require("kr_mp.coop")
local proto = require("kr_mp.proto")

local fake_boot = { log = function() end }
local fake_replay = { is_active = function() return false end, is_replaying = function() return false end, is_recording = function() return false end }
local sent_pkts = {}
local fake_transport = {
    is_connected = function() return true end,
    is_online = function() return false end,
    send = function(self, msg) sent_pkts[#sent_pkts + 1] = msg end,
}
local fake_overlay = { show_toast = function() end }

lockstep:init(fake_boot, fake_transport, coop, fake_overlay)
coop:init(fake_boot, lockstep, fake_overlay)
hooks:init(fake_boot, fake_replay, fake_overlay, coop, lockstep)
prng:seed_sim(123456)

local fake_gui = {
    select_entity = function() end,
    deselect_all = function() end,
    deselect_entity = function() end,
    show_clickable_hover = function() end,
    show_ghost_hover = function() end,
    block_random_power = function() end,
    victory = function() end,
    restart_game = function() end,
    go_to_map = function() end,
}
hooks_gui_guards.install(hooks, fake_gui)

-- =========================================================================
-- TEST 1: Universal deterministic pairs() inside sim_exec_depth > 0
-- =========================================================================
coop.active = true
local st = {
    tick = 1,
    tick_ts = 1 / 60,
    entities = {},
    pending_inserts = {},
    pending_removals = {},
    level = { pan_extension = { top = 40, bottom = -40 } },
    visible_coords = { top = 999, bottom = -123, left = -50, right = 1100 },
}
hooks.active_store = st
hooks.sim_exec_depth = 1
hooks.local_entity_depth = 0

-- 1a. Opposite hash bucket layouts for this.powers (e.g. tower_arcane burst vs slumber)
local pA = { burst = "B", slumber = "S", arcane = "A", zeta = "Z" }
local pB = {}
for i = 1, 32 do pB["junk_" .. i] = i end
pB.zeta = "Z"; pB.slumber = "S"; pB.burst = "B"; pB.arcane = "A"
for i = 1, 32 do pB["junk_" .. i] = nil end

local orderA, orderB = {}, {}
for k in pairs(pA) do orderA[#orderA + 1] = k end
for k in pairs(pB) do orderB[#orderB + 1] = k end
check(table.concat(orderA, ",") == "arcane,burst,slumber,zeta", "pairs(pA) deterministic alpha order: " .. table.concat(orderA, ","))
check(table.concat(orderB, ",") == "arcane,burst,slumber,zeta", "pairs(pB) identical order despite hash churn: " .. table.concat(orderB, ","))

-- 1b. Dense 1..N array fast path
local arr = { "x", "y", "z", "w" }
local ak, av = {}, {}
for k, v in pairs(arr) do ak[#ak + 1] = k; av[#av + 1] = v end
check(table.concat(ak, ",") == "1,2,3,4" and table.concat(av, ",") == "x,y,z,w", "dense 1..N array fast path exact")

-- 1c. Mixed array + hash keys (tricky case where #t could hide hash keys if naive)
local mixed = { "a", "b", foo = "f", bar = "r" }
local mk = {}
for k in pairs(mixed) do mk[#mk + 1] = tostring(k) end
check(table.concat(mk, ",") == "1,2,bar,foo", "mixed array+string keys sorted: " .. table.concat(mk, ","))

-- 1d. Entity-table keys sorted by .id (NOT memory address!)
local e100 = { id = 100, template_name = "enemy_a" }
local e5   = { id = 5,   template_name = "enemy_b" }
local e20  = { id = 20,  template_name = "enemy_c" }
local ent_set = { [e100] = true, [e5] = true, [e20] = true }
local eids = {}
for e in pairs(ent_set) do eids[#eids + 1] = e.id end
check(table.concat(eids, ",") == "5,20,100", "entity-keyed table sorted by id: " .. table.concat(eids, ","))

-- 1e. Table keys with __index / __tostring metatable do NOT trigger side-effects
local index_hits = 0
local mt_evil = {
    __index = function() index_hits = index_hits + 1; return 42 end,
    __tostring = function() error("must not invoke custom __tostring") end,
}
local tk1 = setmetatable({}, mt_evil)
local tk2 = setmetatable({}, mt_evil)
local evil_map = { [tk1] = 1, [tk2] = 2 }
local ecnt = 0
for _ in pairs(evil_map) do ecnt = ecnt + 1 end
check(ecnt == 2 and index_hits == 0, "table keys with __index/__tostring safe without side-effects")

-- 1f. Deletion during iteration skips deleted entries
local del_t = { a = 1, b = 2, c = 3 }
local seen_del = {}
for k in pairs(del_t) do
    seen_del[#seen_del + 1] = k
    if k == "a" then del_t.b = nil end
end
check(table.concat(seen_del, ",") == "a,c", "deleting key during sorted pairs skips nil key")

-- 1g. table.clone / table.deepclone preserve exact values
local orig_nested = { burst = { cd = 12, dmg = { 80, 160 } }, slumber = { cd = 10 } }
local cloned_nested = table.deepclone(orig_nested)
check(cloned_nested ~= orig_nested and cloned_nested.burst.dmg[2] == 160 and cloned_nested.slumber.cd == 10, "table.deepclone intact")

-- 1h. Performance micro-benchmark (20,000 dense arrays + 10,000 3-key power tables)
local t0 = os.clock()
local small_arr = { 10, 20, 30, 40 }
local small_pow = { burst = 1, slumber = 2, extra = 3 }
for _ = 1, 20000 do
    for _ in pairs(small_arr) do end
end
for _ = 1, 10000 do
    for _ in pairs(small_pow) do end
end
local elapsed_ms = (os.clock() - t0) * 1000
check(elapsed_ms < 250, string.format("pairs() benchmark fast (%.1f ms for 30k iterations)", elapsed_ms))

hooks.sim_exec_depth = 0

-- =========================================================================
-- TEST 2: hump.signal deterministic registration-order dispatch
-- =========================================================================
local sig_inst = signal.new()
local sig_out = {}
local fns = {}
for i = 1, 20 do
    local idx = i
    fns[i] = function(tag)
        sig_out[#sig_out + 1] = idx
    end
    sig_inst:register("entity-killed", fns[i])
end
sig_inst:emit("entity-killed", "go")
local expected_sig = {}
for i = 1, 20 do expected_sig[i] = i end
check(table.concat(sig_out, ",") == table.concat(expected_sig, ","),
    "hump.signal emits 20 handlers in exact registration order")

-- Re-entrant removal during emit
local rem_out = {}
local r1, r2, r3
r1 = function() rem_out[#rem_out + 1] = 1; sig_inst:remove("reent", r2) end
r2 = function() rem_out[#rem_out + 1] = 2 end
r3 = function() rem_out[#rem_out + 1] = 3 end
sig_inst:register("reent", r1)
sig_inst:register("reent", r2)
sig_inst:register("reent", r3)
sig_inst:emit("reent")
check(table.concat(rem_out, ",") == "1,3", "hump.signal re-entrant remove skips removed handler cleanly")

-- emitPattern alphabetical signal order
local pat_out = {}
sig_inst:register("z_evt", function() pat_out[#pat_out + 1] = "z" end)
sig_inst:register("a_evt", function() pat_out[#pat_out + 1] = "a" end)
sig_inst:register("m_evt", function() pat_out[#pat_out + 1] = "m" end)
sig_inst:emitPattern("_evt$")
check(table.concat(pat_out, ",") == "a,m,z", "hump.signal emitPattern deterministic alphabetical order")

-- =========================================================================
-- TEST 3 & 5 & 6: sim:init canonical visible_coords + dirty template reset + sys.render
-- =========================================================================
-- 3a. Verify sim:init handles E.entities == nil safely (just like FL 8.2.0 Match 1 before E:load()!)
local saved_ents_tbl = E.entities
E.entities = nil
local orig_sim_init_stub = sim.init
sim:init(st, {})
check(true, "sim:init does not crash when E.entities is nil before E:load()")
E.entities = saved_ents_tbl

-- Match 1 init snapshots pristine templates
sim:init(st, {})
check(st.visible_coords.top == 768 + 40 and st.visible_coords.bottom == -40,
    string.format("canonical visible_coords overrides divergent top/bottom (top=%s bottom=%s)",
        tostring(st.visible_coords.top), tostring(st.visible_coords.bottom)))
check(math.abs(st.visible_coords.right - st.visible_coords.left - (768 * 16 / 9)) < 0.01,
    "canonical visible_coords 16:9 width")

-- Pollute cross-match dirty templates during Match 1
fake_templates.bolt_1.bullet._orig_damage_min = 9
fake_templates.bolt_1.bullet._orig_damage_max = 17
fake_templates.bolt_1.bullet.damage_min = 99
fake_templates.bolt_1.bullet.damage_max = 199
fake_templates.bullet_ashbite.bullet.mod = "mod_ashbite_dirty"
fake_templates.aura_ashbite_skill_a.aura.mod = "mod_ashbite_a_dirty"
fake_templates.mod_ashbite_skill_b_burn.dps.armor_sunder = 25
fake_templates.bolt_stargazer.bullet.damage_min = 55
fake_templates.bolt_stargazer.bullet.damage_max = 90

-- Match 2 init MUST restore every polluted template back to pristine defaults
local st2 = {
    tick = 0,
    tick_ts = 0,
    entities = {},
    pending_inserts = {},
    pending_removals = {},
    level = { pan_extension = { top = 0, bottom = 0 } },
    visible_coords = { top = 1200, bottom = -200 },
}
sim:init(st2, {})
check(fake_templates.bolt_1.bullet.damage_min == 9 and fake_templates.bolt_1.bullet.damage_max == 17,
    "reset_dirty_templates restores mage_brilliance bolt_1")
check(fake_templates.bullet_ashbite.bullet.mod == nil, "reset_dirty_templates restores bullet_ashbite.mod")
check(fake_templates.aura_ashbite_skill_a.aura.mod == nil, "reset_dirty_templates restores aura_ashbite_skill_a.mod")
check(fake_templates.mod_ashbite_skill_b_burn.dps.armor_sunder == 0, "reset_dirty_templates restores ashbite armor_sunder")
check(fake_templates.bolt_stargazer.bullet.damage_min == nil and fake_templates.bolt_stargazer.bullet.damage_max == nil,
    "reset_dirty_templates restores bolt_stargazer nil damage_min/max")

-- Test pre-built mage tower bonus applied INSIDE orig_init is preserved (NOT clobbered after orig_init!)
local st3 = {
    tick = 0, tick_ts = 0, entities = {}, pending_inserts = {}, pending_removals = {},
    level = { pan_extension = { top = 0, bottom = 0 } }, visible_coords = { top = 768, bottom = 0 },
}
local prebuilt_boosted = false
local orig_sim_init_cur = sim.init
sim.init = function(self, store, sys_names)
    return orig_sim_init_cur(self, store, sys_names)
end
-- Simulate E:load() refreshing templates cleanly, then pre-built mage tower boosting bolt_1 inside sim:init
E.load = function(self) self.entities = fake_templates end
local sim_orig_inner = sim.init
-- Verify bolt_1 stays boosted if mutated during orig_init, then resets cleanly on next sim:init
fake_templates.bolt_1.bullet.damage_min = 9
fake_templates.bolt_1.bullet.damage_max = 17
sim:init(st3, {})
fake_templates.bolt_1.bullet.damage_min = 14
fake_templates.bolt_1.bullet.damage_max = 26
-- Next match sim:init restores bolt_1 back to pristine 9/17 before orig_init!
sim:init(st3, {})
check(fake_templates.bolt_1.bullet.damage_min == 9 and fake_templates.bolt_1.bullet.damage_max == 17,
    "reset_dirty_templates cleanly restores bolt_1 before next match without clobbering post-init")

-- Test sys.render:on_insert PRNG stream routing
prng:enter_sim()
local calls_before = prng:get_sim_calls()
local sim_ent = {
    id = 42,
    template_name = "tower_arcane",
    render = { sprites = { { random_ts = 1.5, ts = 0, runs = 0, frame_idx = 1, sync_flag = nil, hidden = false } }, frames = {} },
}
sim:insert_entity(sim_ent)
local calls_after_sim = prng:get_sim_calls()
check(calls_after_sim == calls_before + 1, "sys.render:on_insert uses deterministic SIM PRNG for non-local entity random_ts")

local loc_ent = {
    id = 100000001,
    _kr_mp_local = true,
    template_name = "clickable_hover_circle",
    render = { sprites = { { random_ts = 1.5, ts = 0, runs = 0, frame_idx = 1, sync_flag = nil, hidden = false } }, frames = {} },
}
sim:insert_entity(loc_ent)
local calls_after_loc = prng:get_sim_calls()
check(calls_after_loc == calls_after_sim, "sys.render:on_insert uses VISUAL PRNG for local entity random_ts")
prng:exit_sim()

-- Test sys.render:prepare_frame NEVER mutates sim-read sprite fields on non-local entity
local s1 = sim_ent.render.sprites[1]
s1.runs = 0
s1.frame_idx = 1
s1.sync_flag = nil
s1.hidden = false
s1._render_state_ts = nil
s1._render_frame_name = nil
s1.frame_name = nil
sim:prepare_render(1 / 60)
check(sim_ent.render.frames[1] and sim_ent.render.frames[1]._frame_name == "computed_frame_0007",
    "prepare_frame still renders visual frame cleanly")
check(s1.runs == 0 and s1.frame_idx == 1 and s1.sync_flag == nil and s1.hidden == false
    and s1._render_state_ts == nil and s1._render_frame_name == nil and s1.frame_name == nil,
    "prepare_frame restores ALL sim-read sprite fields untouched on non-local entity")

-- =========================================================================
-- TEST 4: Local UI get_info() template-mutation guard
-- =========================================================================
local stats = InfoBar:update_stats({ tower = { level = 4 } })
check(stats and stats.damage_min == 55 and stats.damage_max == 90, "InfoBar:update_stats returns correct Lv4 stats")
check(fake_templates.bolt_stargazer.bullet.damage_min == nil and fake_templates.bolt_stargazer.bullet.damage_max == nil,
    "InfoBar:update_stats restores mutated shared bullet template damage_min/max back to nil")

local tmin, tmax = TowerTooltip:show(3)
check(tmin == 35 and tmax == 58, "TowerTooltip:show returns correct Lv3 stats")
check(fake_templates.bolt_stargazer.bullet.damage_min == nil and fake_templates.bolt_stargazer.bullet.damage_max == nil,
    "TowerTooltip:show restores mutated shared bullet template damage_min/max back to nil")

-- =========================================================================
-- TEST 7: coop.lua snapshot & screen_map normalization
-- =========================================================================
screen_map = { reinforcement_skins = 5 }
local snap = coop:build_host_slot_snapshot({ 98, 84 }, { 1, 2, 3, 4 }, { max_tech = true })
check(snap.reinforcement_count == 0, "snapshot normalizes reinforcement_count=0")
check(snap.campaign_variant == "regular", "snapshot normalizes campaign_variant='regular'")
check(snap.liuhui.reinforcement_skins == 0, "snapshot normalizes liuhui.reinforcement_skins=0")
check(snap.liuhui.rand_creep == 0, "snapshot normalizes liuhui.rand_creep=0")
check(snap.liuhui.g1_level10 == false, "snapshot normalizes liuhui.g1_level10=false")
check(snap.xingyu and snap.xingyu.balance == 0, "snapshot normalizes xingyu.balance=0")

coop:prepare_match(1, { level_idx = 37, level_mode = 1, level_difficulty = 1, slot_snapshot = snap, heroes = { 98, 84 } })
check(screen_map.reinforcement_skins == 0, "prepare_match zeroes screen_map.reinforcement_skins")

-- =========================================================================
-- TEST 8: Exact-tick DESYNC_DIAG ring buffer & dynamic entity digest
-- =========================================================================
sent_pkts = {}
local dstore = {
    tick = 30,
    player_gold = 500,
    lives = 20,
    wave_group_number = 5,
    entities_with_main_script_on_update_count = 40,
    entities_with_main_script_on_update_count1 = 2,
    entities = {},
}
for i = 1, 16 do
    dstore.entities[i] = { id = i, template_name = "tower_holder", tower = { spent = 0 }, pos = { x = i * 10, y = 100 } }
end
dstore.entities[35] = { id = 35, template_name = "hero_eiskalt", hero = { level = 10, xp = 5000 }, health = { hp = 600 }, pos = { x = 660, y = 436 } }
dstore.entities[26001] = { id = 26001, template_name = "enemy_myrmidon", enemy = {}, health = { hp = 108, dead = false }, nav_path = { ni = 45 }, pos = { x = 420, y = 390 } }
dstore.entities[26010] = { id = 26010, template_name = "arrow_arcane", bullet = { target_id = 26001 }, pos = { x = 425, y = 405 } }
dstore.entities[26020] = { id = 26020, template_name = "mod_arcane_slumber", modifier = { target_id = 26001 } }
dstore.entities[26030] = { id = 26030, template_name = "pop_arcane" }
game = { store = dstore }

lockstep:begin_loading(1, { seed = 999, level_idx = 37 })
lockstep.phase = "RUNNING"
lockstep:on_tick_end(dstore)
check(type(lockstep.local_hash_diags[30]) == "string", "on_tick_end stores exact-tick 30 diag digest")
local d30 = lockstep.local_hash_diags[30]
check(d30:find("t=30", 1, true) ~= nil, "diag header contains exact tick t=30")
check(d30:find("T=16", 1, true) ~= nil, "diag summarizes tower count without drowning enemies")
check(d30:find("H[#35:hero_eiskalt", 1, true) ~= nil, "diag includes heroes")
check(d30:find("E[#26001:enemy_myrmidon", 1, true) ~= nil, "diag includes enemies")
check(d30:find("B[#26010:arrow_arcane", 1, true) ~= nil, "diag includes bullets")
check(d30:find("M[#26020:mod_arcane_slumber", 1, true) ~= nil, "diag includes modifiers")
check(d30:find("NC[#26030:pop_arcane]", 1, true) ~= nil, "diag includes non-combat tail")

-- Mutate live store to tick 34 (as if peer ran 4 ticks ahead before DESYNC_DIAG arrived)
dstore.tick = 34
dstore.entities[26001] = nil
dstore.entities[26010] = nil
dstore.entities[35].pos.x = 700

lockstep:on_remote_hash(30, "DEADBEEF", "tick=30 hash=DEADBEEF")
check(lockstep.phase == "DESYNC", "mismatch transitions to DESYNC")
local diag_pkt = nil
for _, pkt in ipairs(sent_pkts) do
    if pkt.t == "DESYNC_DIAG" then diag_pkt = pkt end
end
check(diag_pkt ~= nil and diag_pkt.ents:find("t=30", 1, true) ~= nil and diag_pkt.ents:find("#26001:enemy_myrmidon", 1, true) ~= nil,
    "DESYNC_DIAG sends exact tick-30 snapshot (including enemy_myrmidon) instead of live tick-34 state")

-- Matching hash pair evicts local_hash_diags[tick] cleanly
lockstep:begin_loading(1, { seed = 999, level_idx = 37 })
lockstep.phase = "RUNNING"
dstore.tick = 60
lockstep:on_tick_end(dstore)
local h60 = lockstep.local_hashes[60].hash
check(lockstep.local_hash_diags[60] ~= nil, "tick 60 diag cached before remote hash arrives")
lockstep:on_remote_hash(60, h60, "")
check(lockstep.local_hash_diags[60] == nil and lockstep.sync_ok_count == 1, "matching hash pair evicts diag cache")

local ma, mi, pa = tostring(proto.MOD_VERSION or ""):match("^(%d+)%.(%d+)%.(%d+)$")
local ver_num = ma and (tonumber(ma) * 10000 + tonumber(mi) * 100 + tonumber(pa)) or 0
check(ver_num >= 20408, "MOD_VERSION >= 2.4.8 (got " .. tostring(proto.MOD_VERSION) .. ")")

io.write(string.format("verify_v248_determinism_fixes: %d passed, %d failed (pairs_bench=%.1fms)\n",
    pass_cnt, fail_cnt, elapsed_ms))
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end
