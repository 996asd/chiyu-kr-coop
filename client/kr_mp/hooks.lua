-- KR-MP Runtime Hook Layer for Kingdom Rush FL 8.2.0
-- Zero modification to original exe; attaches cleanly at runtime via UH.lua.
local prng = require("kr_mp.prng")
local commands = require("kr_mp.commands")

local LOCAL_ID_BASE = 100000000
local LOCAL_UI_TEMPLATES = {
    clickable_hover_circle_controller = true,
    clickable_hover_circle = true,
    tower_ghost_hover_controller = true,
    tower_ghost_hover = true,
    entity_marker_controller = true,
    controller_path_direction = true,
    decal_path_hero_movement = true,
    path_marching_ants_controller = true,
    decal_path_marching_ant = true,
}

local function is_local_template(t)
    local name = (type(t) == "string") and t or (type(t) == "table" and t.template_name) or ""
    if LOCAL_UI_TEMPLATES[name] then return true end
    if name:sub(1, 20) == "decal_entity_marker_" then return true end
    if name:find("path_direction", 1, true) then return true end
    if name:find("clickable_hover", 1, true) then return true end
    if name:find("tower_ghost_hover", 1, true) then return true end
    return false
end

-- Entities whose main_script must NEVER enter FL 8.2.0's swap-remove simulation main_script array:
-- 1) pure local UI controllers/markers (_kr_mp_local / LOCAL_ID_BASE), and
-- 2) pure visual particle_system emitters that expire at render FPS via visual PRNG.
local function is_isolated_main_script_entity(e)
    if not e then return false end
    if e._kr_mp_local then return true end
    if type(e.id) == "number" and e.id >= LOCAL_ID_BASE then return true end
    if is_local_template(e) then return true end
    if e.particle_system
        and not e.enemy and not e.soldier and not e.hero and not e.tower
        and not e.bullet and not e.modifier and not e.health and not e.aura then
        return true
    end
    return false
end

local hooks = {
    boot = nil,
    replay = nil,
    overlay = nil,
    coop = nil,
    lockstep = nil,
    installed_core = false,
    installed_gui = false,
    active_store = nil,
    sso_ref = nil,
    entity_ids = {},
    co_seq = setmetatable({}, { __mode = "k" }),
    co_counter = 0,
    sim_exec_depth = 0,
    local_entity_depth = 0,
    local_entity_id = LOCAL_ID_BASE,
}

function hooks:is_mp_active()
    return self.coop ~= nil and self.coop:is_active()
end

function hooks:is_sync_active()
    return self:is_mp_active() or (self.replay ~= nil and self.replay:is_active())
end

function hooks:submit_command(cmd)
    if self:is_mp_active() and self.lockstep then
        return self.lockstep:queue_local_command(cmd)
    elseif self.replay then
        return self.replay:record_command(cmd)
    end
    return false
end

local VISUAL_SYSTEMS = {
    particle_system = true,
    render = true,
    sound_events = true,
    texts = true,
    seen_tracker = true,
    performance_monitor = true,
}

local orig_pairs = pairs
local orig_coroutine_create = coroutine.create

local function add_entity_id(id)
    if type(id) ~= "number" then return end
    local ids = hooks.entity_ids
    local n = #ids
    if n == 0 or id > ids[n] then
        ids[n + 1] = id
    else
        ids[n + 1] = id
        table.sort(ids)
    end
end

local function compact_entity_ids(entities)
    local ids = hooks.entity_ids
    local out = {}
    local j = 0
    local prev = nil
    for i = 1, #ids do
        local id = ids[i]
        if id ~= prev and entities[id] ~= nil then
            j = j + 1
            out[j] = id
            prev = id
        end
    end
    hooks.entity_ids = out
end

-- Deterministic sorted-ID iterator for store.entities
local function sorted_entities_pairs(entities)
    local ids = hooks.entity_ids
    local idx = 0
    local n = #ids
    local function iter()
        while idx < n do
            idx = idx + 1
            local id = ids[idx]
            local e = entities[id]
            if e ~= nil then
                return id, e
            end
        end
        return nil
    end
    return iter, entities, nil
end

-- Deterministic coroutine-creation-order iterator for store.waves_active
local function sorted_waves_pairs(waves_tbl)
    local list = {}
    local n = 0
    for k in orig_pairs(waves_tbl) do
        n = n + 1
        list[n] = k
    end
    table.sort(list, function(a, b)
        return (hooks.co_seq[a] or 0) < (hooks.co_seq[b] or 0)
    end)
    local idx = 0
    local function iter()
        idx = idx + 1
        local k = list[idx]
        if k ~= nil then
            return k, waves_tbl[k]
        end
        return nil
    end
    return iter, waves_tbl, nil
end

-- Deterministic alphabetical iterator for string-keyed maps like store.manual_wave_cos
local function sorted_string_pairs(tbl)
    local list = {}
    local n = 0
    for k in orig_pairs(tbl) do
        n = n + 1
        list[n] = k
    end
    table.sort(list, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local idx = 0
    local function iter()
        idx = idx + 1
        local k = list[idx]
        if k ~= nil then
            return k, tbl[k]
        end
        return nil
    end
    return iter, tbl, nil
end

-- Deterministic ascending numeric-key iterator (for FL 8.2.0 SSO persistent_lists: alive_enemies/graveyards/modifiers)
local function sorted_numeric_pairs(tbl)
    local list = {}
    local n = 0
    for k in orig_pairs(tbl) do
        n = n + 1
        list[n] = k
    end
    table.sort(list, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == "number" and tb == "number" then
            return a < b
        end
        return tostring(a) < tostring(b)
    end)
    local idx = 0
    local function iter()
        idx = idx + 1
        local k = list[idx]
        if k ~= nil then
            return k, tbl[k]
        end
        return nil
    end
    return iter, tbl, nil
end

function hooks:install_global_determinism()
    -- 1. Monotonic coroutine tagging
    coroutine.create = function(fn)
        local co = orig_coroutine_create(fn)
        hooks.co_counter = hooks.co_counter + 1
        hooks.co_seq[co] = hooks.co_counter
        return co
    end

    -- 1b. Hook FL 8.2.0 SSO (Spatial Search Optimization) so persistent_lists & spatial grid filter are 100% deterministic across resolutions
    local ok_sso, SSO = pcall(require, "klove.sso")
    if not ok_sso or type(SSO) ~= "table" then
        ok_sso, SSO = pcall(require, "sso")
    end
    if ok_sso and type(SSO) == "table" then
        hooks.sso_ref = SSO
        if SSO.create and not SSO._kr_mp_wrapped then
            SSO._kr_mp_wrapped = true
            local orig_sso_create = SSO.create
            SSO.create = function(self_s, name, x, y, w, h)
                -- Use canonical fixed grid origin (0,0) during sync so different window aspect ratios produce identical spatial buckets
                if hooks:is_sync_active() then
                    return orig_sso_create(self_s, name, 0, 0, 2048, 1280)
                end
                return orig_sso_create(self_s, name, x, y, w, h)
            end
            if SSO.filter then
                local orig_sso_filter = SSO.filter
                SSO.filter = function(self_s, out, name, x, y, range, filter_fn)
                    local prev_n = (type(out) == "table") and #out or 0
                    local r = orig_sso_filter(self_s, out, name, x, y, range, filter_fn)
                    if hooks:is_sync_active() and type(out) == "table" then
                        local new_n = #out
                        if new_n - prev_n > 1 then
                            if prev_n == 0 then
                                table.sort(out, function(a, b)
                                    return (a and a.id or 0) < (b and b.id or 0)
                                end)
                            else
                                local slice = {}
                                for i = prev_n + 1, new_n do
                                    slice[#slice + 1] = out[i]
                                end
                                table.sort(slice, function(a, b)
                                    return (a and a.id or 0) < (b and b.id or 0)
                                end)
                                for i = 1, #slice do
                                    out[prev_n + i] = slice[i]
                                end
                            end
                        end
                    end
                    return r
                end
            end
        end
    end

    -- 2. Targeted deterministic pairs() for store.entities, store.waves_active, store.manual_wave_cos, and FL 8.2.0 SSO persistent_lists
    pairs = function(t)
        local st = hooks.active_store
        if st ~= nil then
            if t == st.entities then
                return sorted_entities_pairs(t)
            elseif t == st.waves_active then
                return sorted_waves_pairs(t)
            elseif t == st.manual_wave_cos then
                return sorted_string_pairs(t)
            end
            local sso = hooks.sso_ref
            if sso and sso.persistent_lists then
                local pl = sso.persistent_lists
                if t == pl.alive_enemies or t == pl.graveyards or t == pl.modifiers or t == pl.towers then
                    return sorted_numeric_pairs(t)
                end
            end
        end
        return orig_pairs(t)
    end

    -- 3. Deterministic entity_db:filter, entity_db:filter_iter, and isolated local UI entity IDs
    local E = require("entity_db")
    local trace_ents = (os.getenv("KR_MP_TRACE_ENTITIES") == "1")
    if E and E.create_entity and not E._kr_mp_id_wrapped then
        E._kr_mp_id_wrapped = true
        local orig_create_entity = E.create_entity
        E.create_entity = function(self_e, t)
            local use_local = (hooks.local_entity_depth > 0)
                or is_local_template(t)
                or (hooks.sim_exec_depth == 0 and hooks:is_sync_active())
            if use_local then
                local saved_last_id = self_e.last_id
                local out = orig_create_entity(self_e, t)
                self_e.last_id = saved_last_id
                if out then
                    hooks.local_entity_id = hooks.local_entity_id + 1
                    out.id = hooks.local_entity_id
                    out._kr_mp_local = true
                end
                if trace_ents and hooks.active_store and hooks.boot then
                    hooks.boot:log("TRACE_ENT [LOCAL] tick=%d mode=%s tpl=%s id=%s last_id=%s sim_d=%d loc_d=%d",
                        hooks.active_store.tick or 0, hooks.replay and hooks.replay:get_mode() or "?",
                        tostring(out and out.template_name or t), tostring(out and out.id),
                        tostring(self_e.last_id), hooks.sim_exec_depth, hooks.local_entity_depth)
                end
                return out
            end
            local out = orig_create_entity(self_e, t)
            if trace_ents and hooks.active_store and hooks.boot and (hooks.active_store.tick or 0) >= 290 and (hooks.active_store.tick or 0) <= 400 then
                hooks.boot:log("TRACE_ENT [SIM]   tick=%d mode=%s tpl=%s id=%s last_id=%s sim_d=%d loc_d=%d",
                    hooks.active_store.tick or 0, hooks.replay and hooks.replay:get_mode() or "?",
                    tostring(out and out.template_name or t), tostring(out and out.id),
                    tostring(self_e.last_id), hooks.sim_exec_depth, hooks.local_entity_depth)
            end
            return out
        end

        local orig_clone_entity = E.clone_entity
        E.clone_entity = function(self_e, e)
            local use_local = (hooks.local_entity_depth > 0)
                or (e and e._kr_mp_local)
                or is_local_template(e)
                or (hooks.sim_exec_depth == 0 and hooks:is_sync_active())
            if use_local then
                local saved_last_id = self_e.last_id
                local saved_eid = e and e.id
                local out = orig_clone_entity(self_e, e)
                self_e.last_id = saved_last_id
                if e and saved_eid ~= nil then
                    e.id = saved_eid
                end
                if out then
                    hooks.local_entity_id = hooks.local_entity_id + 1
                    out.id = hooks.local_entity_id
                    out._kr_mp_local = true
                end
                return out
            end
            return orig_clone_entity(self_e, e)
        end
    end

    local orig_filter = E.filter
    E.filter = function(self_e, entities, ...)
        local st = hooks.active_store
        if st and entities == st.entities then
            local comps = { ... }
            local ncomp = #comps
            local result = {}
            local ids = hooks.entity_ids
            local r = 0
            for i = 1, #ids do
                local e = entities[ids[i]]
                if e then
                    local ok = true
                    for c = 1, ncomp do
                        if not e[comps[c]] then
                            ok = false
                            break
                        end
                    end
                    if ok then
                        r = r + 1
                        result[r] = e
                    end
                end
            end
            return result
        end
        return orig_filter(self_e, entities, ...)
    end

    local orig_filter_iter = E.filter_iter
    E.filter_iter = function(self_e, entities, c1, c2, c3)
        local st = hooks.active_store
        if st and entities == st.entities then
            local ids = hooks.entity_ids
            local idx = 0
            local n = #ids
            local function next_e()
                while idx < n do
                    idx = idx + 1
                    local id = ids[idx]
                    local e = entities[id]
                    if e then
                        if (not c1 or e[c1]) and (not c2 or e[c2]) and (not c3 or e[c3]) then
                            return id, e
                        end
                    end
                end
                return nil
            end
            return next_e, entities, nil
        end
        return orig_filter_iter(self_e, entities, c1, c2, c3)
    end

    -- 4. Isolate sound_db RNG from battle simulation PRNG
    local S = require("sound_db")
    if S and S.queue and not S._kr_mp_wrapped then
        S._kr_mp_wrapped = true
        local orig_s_queue = S.queue
        S.queue = function(...)
            prng:enter_visual()
            local r1, r2, r3 = orig_s_queue(...)
            prng:exit_visual()
            return r1, r2, r3
        end
    end

    -- 4b. Disable cell-only GR.waypoints_cache so unquantized UI hover/validate never leaks into sim pathing
    local GR = require("grid_db")
    if GR and GR.find_waypoints and not GR._kr_mp_wrapped then
        GR._kr_mp_wrapped = true
        local orig_find_wp = GR.find_waypoints
        GR.find_waypoints = function(self_gr, from, from_fallback, to, valid_terrains, force_recalc)
            return orig_find_wp(self_gr, from, from_fallback, to, valid_terrains, true)
        end
    end

    -- 4c. Auto-skip campaign intro comics in Co-op / Replay across ALL FL 8.2.0 generations (KR1..KR6!)
    for _, lu_mod in ipairs({ "level_utils", "level_utils_5", "level_utils_57", "level_utils_6" }) do
        local ok_lu, LU = pcall(require, lu_mod)
        if ok_lu and LU and LU.load_level and not LU._kr_mp_wrapped then
            LU._kr_mp_wrapped = true
            local orig_load_level = LU.load_level
            LU.load_level = function(store, name)
                local lvl = orig_load_level(store, name)
                if lvl then
                    if lvl._kr_mp_orig_comic_idx == nil and lvl.show_comic_idx ~= nil then
                        lvl._kr_mp_orig_comic_idx = lvl.show_comic_idx
                    end
                    if hooks:is_sync_active() then
                        lvl.show_comic_idx = nil
                    elseif lvl._kr_mp_orig_comic_idx ~= nil then
                        lvl.show_comic_idx = lvl._kr_mp_orig_comic_idx
                    end
                end
                return lvl
            end
        end
    end

    -- 5. Hook storage:load_slot / save_slot so replay restores exact initial hero/upgrade state safely
    -- Also ensures FL 8.2.0 default fields exist when booting straight into a level (-level N).
    local function ensure_fl_slot_defaults(slot)
        if not slot or type(slot) ~= "table" then return slot end
        local want_double = (os.getenv("KR_MP_AUTO_DOUBLE_HERO") == "1")
        if slot.liuhui_hero == nil then
            slot.liuhui_hero = {
                usedoublehero = want_double,
                herolist = { [1] = 53, [2] = 54 },
                rallylist = { 53, 54, 55, 56 },
            }
        else
            if slot.liuhui_hero.usedoublehero == nil then slot.liuhui_hero.usedoublehero = want_double end
            if want_double then slot.liuhui_hero.usedoublehero = true end
            if slot.liuhui_hero.herolist == nil then slot.liuhui_hero.herolist = { [1] = 53, [2] = 54 } end
            if slot.liuhui_hero.rallylist == nil then slot.liuhui_hero.rallylist = { 53, 54, 55, 56 } end
        end
        if slot.liuhui == nil then
            slot.liuhui = {
                use3tower = true,
                use3tower_count = 0,
                tower_generations = { true, true, true, true, true },
                impossiblerate = 1.5,
                cheat = false,
                cheat5 = false,
                cheat6 = false,
                cheat5_special = false,
                cheat5_dragon = false,
                cheathero = false,
                rand_hero = 0,
                rand_tower = 0,
                hero_auto_rally = false,
                g3_hprate = false,
                balance = false,
                enemy_count = 1,
                g5_hero_dark_count = 2,
                cp_mode = false,
            }
        else
            if slot.liuhui.use3tower_count == nil then slot.liuhui.use3tower_count = 0 end
            if slot.liuhui.tower_generations == nil then
                slot.liuhui.tower_generations = { true, true, true, true, true }
            end
            if hooks:is_sync_active() then
                slot.liuhui.rand_hero = 0
                slot.liuhui.rand_tower = 0
                slot.liuhui.hero_auto_rally = false
            end
        end
        if slot.towers == nil or #slot.towers == 0 then
            slot.towers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }
        end
        if slot.tower_pick == nil or slot.tower_pick > #slot.towers then
            slot.tower_pick = #slot.towers
        end
        if screen_map == nil then
            screen_map = { user_data = slot }
        elseif screen_map.user_data == nil then
            screen_map.user_data = slot
        end
        return slot
    end

    local storage = require("storage")
    if storage and not storage._kr_mp_wrapped then
        storage._kr_mp_wrapped = true
        local orig_load_slot = storage.load_slot
        storage.load_slot = function(self_s, idx, force)
            if hooks.coop then
                local mp_snap = hooks.coop:get_slot_override()
                if mp_snap then
                    return ensure_fl_slot_defaults(mp_snap)
                end
            end
            if hooks.replay then
                local snap = hooks.replay:get_slot_override()
                if snap then
                    return ensure_fl_slot_defaults(snap)
                end
            end
            return ensure_fl_slot_defaults(orig_load_slot(self_s, idx, force))
        end

        local orig_save_slot = storage.save_slot
        storage.save_slot = function(self_s, ...)
            if (hooks.coop and hooks.coop:is_active()) or (hooks.replay and hooks.replay:is_replaying()) then
                return true -- never overwrite disk save during Co-op or replay
            end
            return orig_save_slot(self_s, ...)
        end
    end
end

function hooks:install_simulation_hooks()
    local sim = require("simulation")
    if not sim or sim._kr_mp_wrapped then return end
    sim._kr_mp_wrapped = true

    local km = require("klua.macros")
    local E = require("entity_db")
    local orig_init = sim.init
    local orig_insert = sim.insert_entity
    local orig_remove = sim.remove_entity
    local orig_update = sim.update

    sim.init = function(self_sim, store, system_names)
        hooks:ensure_game_and_gui_hooks()
        hooks.boot:log("sim:init called (level=%s, mode=%s, diff=%s)",
            tostring(store and store.level_idx), tostring(store and store.level_mode), tostring(store and store.level_difficulty))
        hooks.active_store = store
        hooks.entity_ids = {}
        hooks.co_counter = 0
        hooks.local_entity_depth = 0
        hooks.local_entity_id = LOCAL_ID_BASE
        if E then
            E.last_id = 1
        end
        local GR_init = require("grid_db")
        if GR_init and GR_init.waypoints_cache then
            GR_init.waypoints_cache = {}
        end

        if hooks:is_mp_active() then
            commands:reset()
            hooks.coop:on_before_sim_init(store)
        elseif hooks.replay then
            hooks.replay:on_before_sim_init(store)
        end

        -- Canonicalize simulation visible_coords to standard 16:9 during sync so different monitor/window
        -- aspect ratios (16:9 vs 16:10 vs 3:2 vs 4:3) compute identical path_db start/end nodes & level bounds!
        if hooks:is_sync_active() and store then
            local ref_w = REF_W or 1024
            local ref_h = REF_H or 768
            local canon_w = ref_h * 16 / 9
            local panext = store.level and store.level.pan_extension
            local cur_vc = store.visible_coords
            store.visible_coords = {
                top = (cur_vc and cur_vc.top) or ((panext and panext.top or 0) + ref_h),
                bottom = (cur_vc and cur_vc.bottom) or (panext and panext.bottom or 0),
                left = (ref_w - canon_w) / 2,
                right = ref_w + (canon_w - ref_w) / 2,
            }
        end

        -- Wrap visual systems' callbacks once so they never consume battle PRNG or sim entity IDs
        local S_sys = require("systems")
        for sname, _ in orig_pairs(VISUAL_SYSTEMS) do
            local sys = S_sys[sname]
            if sys and not sys._kr_mp_vis_wrapped then
                sys._kr_mp_vis_wrapped = true
                for _, fn_name in ipairs({
                    "on_insert", "on_remove", "on_insert_unconditional", "on_remove_unconditional",
                    "on_queue", "on_dequeue", "on_render_update", "prepare_frame"
                }) do
                    if sys[fn_name] then
                        local orig_fn = sys[fn_name]
                        sys[fn_name] = function(...)
                            hooks.local_entity_depth = hooks.local_entity_depth + 1
                            prng:enter_visual()
                            local ok_v, a, b = pcall(orig_fn, ...)
                            prng:exit_visual()
                            hooks.local_entity_depth = hooks.local_entity_depth - 1
                            if not ok_v then error(a) end
                            return a, b
                        end
                    end
                end
            end
        end

        -- Wrap FL 8.2.0 simulation:prepare_render so render/particle updates stay in visual+local isolation
        if self_sim.prepare_render and not self_sim._kr_mp_prep_wrapped then
            self_sim._kr_mp_prep_wrapped = true
            local orig_prep = self_sim.prepare_render
            self_sim.prepare_render = function(s_self, dt_arg)
                hooks.local_entity_depth = hooks.local_entity_depth + 1
                prng:enter_visual()
                local ok_p, err_p = pcall(orig_prep, s_self, dt_arg)
                prng:exit_visual()
                hooks.local_entity_depth = hooks.local_entity_depth - 1
                if not ok_p then error(err_p) end
            end
        end

        -- Guard FL 8.2.0 item_medical_kit so lives are added deterministically inside sim tick
        -- instead of game_gui's wall-clock timer:after(fly_time) callback!
        local med_tpl = E and E.entities and E.entities["controller_item_medical_kit"]
        if med_tpl and med_tpl.main_script and med_tpl.main_script.insert and not med_tpl.main_script._kr_mp_med_wrapped then
            med_tpl.main_script._kr_mp_med_wrapped = true
            local orig_med_ins = med_tpl.main_script.insert
            med_tpl.main_script.insert = function(this_m, st_m)
                if hooks:is_sync_active() and st_m then
                    local hcnt = tonumber(this_m.hearts) or 3
                    st_m.lives = (st_m.lives or 0) + hcnt
                    local saved_hearts = this_m.hearts
                    this_m.hearts = 0
                    local ok_m, res_m = pcall(orig_med_ins, this_m, st_m)
                    this_m.hearts = saved_hearts
                    if not ok_m then error(res_m) end
                    return res_m
                end
                return orig_med_ins(this_m, st_m)
            end
        end

        -- Guard simulation-only systems so _kr_mp_local UI entities NEVER enter SSO/events/count_groups/upgrades/health
        local SIM_SKIP_LOCAL_SYS = { "sso_post", "events", "count_groups", "game_upgrades", "game_upgrades_6", "health" }
        for _, sname in ipairs(SIM_SKIP_LOCAL_SYS) do
            local sys = S_sys[sname]
            if sys and not sys._kr_mp_locskip_wrapped then
                sys._kr_mp_locskip_wrapped = true
                for _, fn_name in ipairs({ "on_insert", "on_remove", "on_insert_unconditional", "on_remove_unconditional", "on_queue", "on_dequeue" }) do
                    if sys[fn_name] then
                        local orig_fn = sys[fn_name]
                        local is_bool_gate = (fn_name == "on_insert" or fn_name == "on_remove")
                        sys[fn_name] = function(self_s, entity, ...)
                            if entity and entity._kr_mp_local then
                                return is_bool_gate and true or nil
                            end
                            return orig_fn(self_s, entity, ...)
                        end
                    end
                end
            end
        end

        -- Wrap sys.main_script completely so:
        -- 1) Local UI controllers & pure visual particle emitters NEVER enter FL 8.2.0's swap-remove sim arrays
        --    (otherwise hovering/selecting any tower or hero scrambles combat coroutine order on remove -> DESYNC!).
        -- 2) Pure simulation main_script entities ALWAYS run in canonical ascending e.id order during sync.
        local ms = S_sys.main_script
        if ms and not ms._kr_mp_local_wrapped then
            ms._kr_mp_local_wrapped = true
            local log_ms = require("klua.log"):new("systems")
            local orig_ms_init = ms.init
            local orig_ms_ins_u = ms.on_insert_unconditional
            local orig_ms_rem_u = ms.on_remove_unconditional

            local function ensure_local_ms_lists(st)
                if not st._kr_mp_local_ms_list then
                    st._kr_mp_local_ms_list = {}
                    st._kr_mp_local_ms_index = {}
                    st._kr_mp_local_ms_count = 0
                    st._kr_mp_local_ms_list1 = {}
                    st._kr_mp_local_ms_index1 = {}
                    st._kr_mp_local_ms_count1 = 0
                end
            end

            local function local_ms_register(st, entity)
                local s = entity and entity.main_script
                if not s or not s.update then return end
                ensure_local_ms_lists(st)
                if s.type == 1 then
                    if st._kr_mp_local_ms_index1[entity.id] then return end
                    local c = st._kr_mp_local_ms_count1 + 1
                    st._kr_mp_local_ms_count1 = c
                    st._kr_mp_local_ms_list1[c] = entity
                    st._kr_mp_local_ms_index1[entity.id] = c
                else
                    if st._kr_mp_local_ms_index[entity.id] then return end
                    local c = st._kr_mp_local_ms_count + 1
                    st._kr_mp_local_ms_count = c
                    st._kr_mp_local_ms_list[c] = entity
                    st._kr_mp_local_ms_index[entity.id] = c
                end
            end

            local function local_ms_unregister(st, entity)
                if not entity or not entity.id or not st._kr_mp_local_ms_list then return false end
                local idx1 = st._kr_mp_local_ms_index1[entity.id]
                if idx1 then
                    local c = st._kr_mp_local_ms_count1
                    local last_e = st._kr_mp_local_ms_list1[c]
                    st._kr_mp_local_ms_list1[idx1] = last_e
                    if last_e then st._kr_mp_local_ms_index1[last_e.id] = idx1 end
                    st._kr_mp_local_ms_list1[c] = nil
                    st._kr_mp_local_ms_index1[entity.id] = nil
                    st._kr_mp_local_ms_count1 = c - 1
                    return true
                end
                local idx = st._kr_mp_local_ms_index[entity.id]
                if idx then
                    local c = st._kr_mp_local_ms_count
                    local last_e = st._kr_mp_local_ms_list[c]
                    st._kr_mp_local_ms_list[idx] = last_e
                    if last_e then st._kr_mp_local_ms_index[last_e.id] = idx end
                    st._kr_mp_local_ms_list[c] = nil
                    st._kr_mp_local_ms_index[entity.id] = nil
                    st._kr_mp_local_ms_count = c - 1
                    return true
                end
                return false
            end

            local function sort_ms_array_by_id(arr, idx_map, cnt)
                if not arr or not cnt or cnt <= 1 then return end
                -- Ensure strict dense 1..cnt before table.sort
                arr[cnt + 1] = nil
                table.sort(arr, function(a, b)
                    return (a and a.id or 0) < (b and b.id or 0)
                end)
                if idx_map then
                    for k in orig_pairs(idx_map) do idx_map[k] = nil end
                    for i = 1, cnt do
                        local e = arr[i]
                        if e and e.id then idx_map[e.id] = i end
                    end
                end
            end

            ms.init = function(self_ms, st)
                local res = orig_ms_init and orig_ms_init(self_ms, st)
                st._kr_mp_local_ms_list = {}
                st._kr_mp_local_ms_index = {}
                st._kr_mp_local_ms_count = 0
                st._kr_mp_local_ms_list1 = {}
                st._kr_mp_local_ms_index1 = {}
                st._kr_mp_local_ms_count1 = 0
                st._kr_mp_ms_dirty = false
                st._kr_mp_ms1_dirty = false
                return res
            end

            if orig_ms_ins_u then
                ms.on_insert_unconditional = function(self_ms, entity, st)
                    if is_isolated_main_script_entity(entity) then
                        local_ms_register(st, entity)
                        return
                    end
                    orig_ms_ins_u(self_ms, entity, st)
                    local s = entity and entity.main_script
                    if s and s.update then
                        if s.type == 1 then
                            st._kr_mp_ms1_dirty = true
                        else
                            st._kr_mp_ms_dirty = true
                        end
                    end
                end
            end

            if orig_ms_rem_u then
                ms.on_remove_unconditional = function(self_ms, entity, st)
                    if local_ms_unregister(st, entity) then
                        return
                    end
                    local s = entity and entity.main_script
                    if s and s.update then
                        if s.type == 1 then
                            st._kr_mp_ms1_dirty = true
                        else
                            st._kr_mp_ms_dirty = true
                        end
                    end
                    return orig_ms_rem_u(self_ms, entity, st)
                end
            end

            ms.on_update = function(self_ms, dt, ts, st)
                local mp_on = hooks:is_mp_active()
                local sync_on = hooks:is_sync_active()
                local function step_coro_entity(e, force_local)
                    local s = e and e.main_script
                    if not s or not s.update then return end
                    local is_loc = force_local or e._kr_mp_local or is_isolated_main_script_entity(e)
                    if is_loc then
                        hooks.local_entity_depth = hooks.local_entity_depth + 1
                        prng:enter_visual()
                    end
                    if not s.co and s.runs ~= 0 then
                        s.runs = s.runs - 1
                        s.co = coroutine.create(s.update)
                    end
                    if s.co then
                        local prev_dom = st._dominant_entity
                        st._dominant_entity = e
                        local co = s.co
                        local gold_before = (mp_on and not is_loc) and (st.player_gold or 0) or 0
                        local success, err = coroutine.resume(co, e, st, s)
                        if mp_on and not is_loc then
                            local gdelta = (st.player_gold or 0) - gold_before
                            if gdelta ~= 0 then
                                hooks.coop:on_system_gold_delta(st, gdelta, e._mp_actor or e._mp_owner or 1)
                            end
                        end
                        if (not success and s.co == co) or coroutine.status(co) == "dead" then
                            if s.co == co then
                                s.co = nil
                            end
                        end
                        if not success and err ~= nil and err ~= "cannot resume dead coroutine" then
                            log_ms.error("Error running coro: %s", debug.traceback(co, tostring(err)))
                            if s.on_error then
                                st._dominant_entity = e
                                local cleaned, cleanup_err = pcall(s.on_error, e, st, s)
                                if not cleaned then
                                    log_ms.error("Error cleaning up %s: %s", tostring(e.template_name), tostring(cleanup_err))
                                end
                            end
                        end
                        st._dominant_entity = prev_dom
                    end
                    if is_loc then
                        prng:exit_visual()
                        hooks.local_entity_depth = hooks.local_entity_depth - 1
                    end
                end

                local function step_direct_entity(e, force_local)
                    local s = e and e.main_script
                    if not s or not s.update then return end
                    local is_loc = force_local or e._kr_mp_local or is_isolated_main_script_entity(e)
                    if is_loc then
                        hooks.local_entity_depth = hooks.local_entity_depth + 1
                        prng:enter_visual()
                    end
                    local prev_dom = st._dominant_entity
                    st._dominant_entity = e
                    local gold_before = (mp_on and not is_loc) and (st.player_gold or 0) or 0
                    s.update(e, st, s)
                    if mp_on and not is_loc then
                        local gdelta = (st.player_gold or 0) - gold_before
                        if gdelta ~= 0 then
                            hooks.coop:on_system_gold_delta(st, gdelta, e._mp_actor or e._mp_owner or 1)
                        end
                    end
                    st._dominant_entity = prev_dom
                    if is_loc then
                        prng:exit_visual()
                        hooks.local_entity_depth = hooks.local_entity_depth - 1
                    end
                end

                if st.entities_with_main_script_on_update then
                    local cnt = st.entities_with_main_script_on_update_count or #st.entities_with_main_script_on_update
                    if sync_on and st._kr_mp_ms_dirty then
                        sort_ms_array_by_id(st.entities_with_main_script_on_update, st.entities_with_main_script_on_update_index, cnt)
                        st._kr_mp_ms_dirty = false
                    end
                    for i = 1, cnt do
                        local e = st.entities_with_main_script_on_update[i]
                        if e then step_coro_entity(e, false) end
                    end
                    local list1 = st.entities_with_main_script_on_update1
                    if list1 then
                        local cnt1 = st.entities_with_main_script_on_update_count1 or #list1
                        if sync_on and st._kr_mp_ms1_dirty then
                            sort_ms_array_by_id(list1, st.entities_with_main_script_on_update_index1, cnt1)
                            st._kr_mp_ms1_dirty = false
                        end
                        for i = 1, cnt1 do
                            local e = list1[i]
                            if e then step_direct_entity(e, false) end
                        end
                    end
                    -- Run isolated local UI controllers & visual-particle scripts AFTER all sim scripts
                    local loc_list = st._kr_mp_local_ms_list
                    if loc_list then
                        local lcnt = st._kr_mp_local_ms_count or 0
                        for i = 1, lcnt do
                            local e = loc_list[i]
                            if e then step_coro_entity(e, true) end
                        end
                    end
                    local loc_list1 = st._kr_mp_local_ms_list1
                    if loc_list1 then
                        local lcnt1 = st._kr_mp_local_ms_count1 or 0
                        for i = 1, lcnt1 do
                            local e = loc_list1[i]
                            if e then step_direct_entity(e, true) end
                        end
                    end
                else
                    for _, e in E:filter_iter(st.entities, "main_script") do
                        step_coro_entity(e, false)
                    end
                end
            end
        end

        hooks.sim_exec_depth = hooks.sim_exec_depth + 1
        prng:enter_sim()
        local ok, err = pcall(orig_init, self_sim, store, system_names)
        prng:exit_sim()
        hooks.sim_exec_depth = hooks.sim_exec_depth - 1
        if not ok then
            error(err)
        end

        -- Rebuild initial sorted entity_ids from any entities inserted directly during init
        hooks.entity_ids = {}
        for id in orig_pairs(store.entities) do
            if type(id) == "number" then
                hooks.entity_ids[#hooks.entity_ids + 1] = id
            end
        end
        table.sort(hooks.entity_ids)

        if hooks:is_mp_active() then
            hooks.coop:on_after_sim_init(store)
        elseif hooks.replay then
            hooks.replay:on_after_sim_init(store)
        end
    end

    sim.insert_entity = function(self_sim, e)
        local is_local = e and e._kr_mp_local
        local st = self_sim.store
        local saved_cnt = is_local and st and st.entity_count or nil
        local saved_max = is_local and st and st.entity_max or nil
        if is_local then
            hooks.local_entity_depth = hooks.local_entity_depth + 1
            prng:enter_visual()
        end
        local ok_i, err_i = pcall(orig_insert, self_sim, e)
        if is_local then
            if st and saved_cnt ~= nil then
                st.entity_count = saved_cnt
                st.entity_max = saved_max
            end
            prng:exit_visual()
            hooks.local_entity_depth = hooks.local_entity_depth - 1
        end
        if not ok_i then error(err_i) end
        if self_sim.store == hooks.active_store and e and e.id and self_sim.store.entities[e.id] == e then
            add_entity_id(e.id)
            if hooks:is_mp_active() and e.hero then
                hooks.coop:on_entity_inserted(e)
            end
        end
    end

    sim.remove_entity = function(self_sim, e)
        local is_local = e and e._kr_mp_local
        local st = self_sim.store
        local saved_cnt = is_local and st and st.entity_count or nil
        local saved_max = is_local and st and st.entity_max or nil
        if is_local then
            hooks.local_entity_depth = hooks.local_entity_depth + 1
            prng:enter_visual()
        end
        local ok_r, err_r = pcall(orig_remove, self_sim, e)
        if is_local then
            if st and saved_cnt ~= nil then
                st.entity_count = saved_cnt
                st.entity_max = saved_max
            end
            prng:exit_visual()
            hooks.local_entity_depth = hooks.local_entity_depth - 1
        end
        if not ok_r then error(err_r) end
    end

    sim.update = function(self_sim, dt)
        local d = self_sim.store
        if not d then return end
        if d.paused and not d.step then
            return
        end

        if hooks:is_mp_active() and hooks.lockstep then
            if hooks.lockstep:is_catching_up() then
                -- Wait until director finishes transitioning active_item to game before fast-forwarding
                if main and main.handler and main.handler.active_item ~= game then
                    return
                end
                -- Fast-forward reconnect: advance up to 30 exact ticks per rendered frame
                for _ = 1, 30 do
                    if d.paused or not hooks.lockstep:is_catching_up() then break end
                    if not hooks.lockstep:can_step_tick((d.tick or 0) + 1) then break end
                    d.dt = TICK_LENGTH
                    d.to = 0
                    self_sim:do_tick()
                end
                d.step = false
                return
            end
            if not hooks.lockstep:is_running() then
                return
            end
            local fast_test = (os.getenv("KR_MP_AUTO_COOP_FAST") == "1")
            if fast_test then
                for _ = 1, 15 do
                    if d.paused or not hooks.lockstep:is_running() then break end
                    if not hooks.lockstep:can_step_tick((d.tick or 0) + 1) then break end
                    d.dt = TICK_LENGTH
                    d.to = 0
                    self_sim:do_tick()
                end
                d.step = false
                return
            end
            local spd = hooks.lockstep.game_speed or 1
            d.dt = TICK_LENGTH
            d.to = d.to + dt * spd
            local stepped = 0
            while d.to >= TICK_LENGTH and stepped < spd do
                if d.paused or not hooks.lockstep:is_running() then break end
                if hooks.lockstep:can_step_tick((d.tick or 0) + 1) then
                    d.to = d.to - TICK_LENGTH
                    self_sim:do_tick()
                    d.step = false
                    stepped = stepped + 1
                else
                    -- Waiting for remote peer's turn packet; clamp accumulator so we don't burst-spike
                    d.to = TICK_LENGTH
                    break
                end
            end
            if d.to > TICK_LENGTH then
                d.to = TICK_LENGTH
            end
            return
        end

        if hooks.replay and hooks.replay:is_replaying() then
            local speed = hooks.replay:get_replay_speed()
            if speed > 1 then
                -- Fast-forward replay: advance multiple exact ticks per rendered frame
                for _ = 1, speed do
                    if d.paused or not hooks.replay:is_replaying() then break end
                    d.dt = TICK_LENGTH
                    d.to = 0
                    self_sim:do_tick()
                end
                d.step = false
                return
            end
            -- 1x replay: fixed timestep accumulation, keeping d.dt & d.ts deterministic
            d.dt = TICK_LENGTH
            d.to = d.to + dt
            if d.to > TICK_LENGTH then
                d.to = km.clamp(0, TICK_LENGTH, d.to - TICK_LENGTH)
                self_sim:do_tick()
                d.step = false
            end
            return
        end

        if hooks.replay and hooks.replay:is_recording() then
            if hooks.replay.auto_verify then
                -- High-speed deterministic ticks during automated self-verify
                for _ = 1, 25 do
                    if d.paused or not hooks.replay:is_recording() then break end
                    d.dt = TICK_LENGTH
                    d.to = 0
                    self_sim:do_tick()
                end
                d.step = false
                return
            end
            d.dt = TICK_LENGTH
            d.to = d.to + dt
            if d.to > TICK_LENGTH then
                d.to = km.clamp(0, TICK_LENGTH, d.to - TICK_LENGTH)
                self_sim:do_tick()
                d.step = false
            end
            return
        end

        return orig_update(self_sim, dt)
    end

    sim.do_tick = function(self_sim, tick_length)
        local d = self_sim.store
        hooks.sim_exec_depth = hooks.sim_exec_depth + 1
        prng:enter_sim()

        local ok_tick, err_tick = pcall(function()
            local mp_on = hooks:is_mp_active()
            local tl = TICK_LENGTH
            d.tick = d.tick + 1
            d.tick_ts = d.tick * tl
            d.ts = d.tick_ts

            if mp_on then
                hooks.coop:on_tick_begin(d)
            end

            -- 1. Flush tick-synchronized player commands BEFORE pending_inserts/systems
            commands:flush_tick(d.tick, game, hooks.boot)

            -- 2. Standard entity insert/remove flush (uses FL 8.2.0 flush_pending_entities when available)
            if self_sim.flush_pending_entities then
                self_sim:flush_pending_entities()
            else
                while #d.pending_inserts > 0 do
                    local e = table.remove(d.pending_inserts, 1)
                    self_sim:insert_entity(e)
                end
                while #d.pending_removals > 0 do
                    local e = table.remove(d.pending_removals, 1)
                    self_sim:remove_entity(e)
                end
            end

            -- 3. Run all simulation systems in exact order; isolate visual systems & account Co-op gold deltas
            local sys_cnt = self_sim.systems_on_update_count or #self_sim.systems_on_update
            for i = 1, sys_cnt do
                local sys = self_sim.systems_on_update[i]
                if VISUAL_SYSTEMS[sys.name] then
                    hooks.local_entity_depth = hooks.local_entity_depth + 1
                    prng:enter_visual()
                    local ok_vs, err_vs = pcall(sys.on_update, sys, tl, d.tick_ts, d)
                    prng:exit_visual()
                    hooks.local_entity_depth = hooks.local_entity_depth - 1
                    if not ok_vs then error(err_vs) end
                elseif mp_on and sys.name == "tower_upgrade" then
                    hooks.coop:before_tower_upgrade(d)
                    sys:on_update(tl, d.tick_ts, d)
                    hooks.coop:after_tower_upgrade(d)
                elseif mp_on and sys.name ~= "main_script" then
                    local gold_before = d.player_gold or 0
                    sys:on_update(tl, d.tick_ts, d)
                    local gdelta = (d.player_gold or 0) - gold_before
                    if gdelta ~= 0 then
                        hooks.coop:on_system_gold_delta(d, gdelta, nil)
                    end
                else
                    sys:on_update(tl, d.tick_ts, d)
                end
            end

            -- 4. Lazy compact entity_ids if too many deleted tombstones accumulated
            if #hooks.entity_ids > (d.entity_count or 0) * 2 + 128 then
                compact_entity_ids(d.entities)
            end

            -- 5. Record / Verify checksum every 30 ticks (while store.player_gold is still canonical!)
            if mp_on and hooks.lockstep then
                hooks.lockstep:on_tick_end(d)
                hooks.coop:on_tick_end(d)
            elseif hooks.replay then
                hooks.replay:on_tick_end(d)
            end
        end)

        prng:exit_sim()
        hooks.sim_exec_depth = hooks.sim_exec_depth - 1
        if not ok_tick then
            error(err_tick)
        end
    end

    hooks.boot:log("Simulation hooks installed successfully.")
end

function hooks:ensure_game_and_gui_hooks()
    if game and not self.installed_game then
        self:install_game_hooks(game)
    end
    local gui = (game and game.game_gui) or package.loaded["game_gui"]
    if gui and not self.installed_gui then
        self:install_gui_hooks(gui)
    end
end

function hooks:install_game_hooks(g)
    if not g or g._kr_mp_wrapped then return end
    g._kr_mp_wrapped = true
    self.installed_game = true

    local orig_game_init = g.init
    g.init = function(self_g, ...)
        orig_game_init(self_g, ...)
        hooks:install_gui_hooks(self_g.game_gui or package.loaded["game_gui"])
        if hooks.coop and hooks.coop:is_active() then
            hooks.coop:on_game_ready()
        end
    end

    local orig_game_restart = g.restart
    g.restart = function(self_g, ...)
        orig_game_restart(self_g, ...)
        hooks:install_gui_hooks(self_g.game_gui or package.loaded["game_gui"])
        if hooks.coop and hooks.coop:is_active() then
            hooks.coop:on_game_ready()
        end
    end

    local orig_game_update = g.update
    g.update = function(self_g, dt)
        if hooks:is_sync_active() then
            -- Bypass FL's local q/e/r/x/z keyboard speed hacks during deterministic record/replay or Co-op
            self_g.simulation:update(dt)
            if self_g.simulation.prepare_render then
                self_g.simulation:prepare_render(dt)
            end
            self_g.game_gui:update(dt)
            return
        end
        return orig_game_update(self_g, dt)
    end

    local orig_game_destroy = g.destroy
    g.destroy = function(self_g, ...)
        if hooks.replay then
            hooks.replay:on_game_destroy()
        end
        return orig_game_destroy(self_g, ...)
    end

    hooks.boot:log("Game hooks installed successfully (lazy).")
end

function hooks:install_gui_hooks(gui)
    if self.installed_gui then return end
    gui = gui or (game and game.game_gui) or package.loaded["game_gui"]
    if not gui or not PickView or not TowerMenuButton then return end
    self.installed_gui = true

    local game_gui = gui
    local S = require("sound_db")
    local V = require("hump.vector-light")
    local U = require("utils")
    local P = require("path_db")
    local GR = require("grid_db")
    local bit = require("bit")

    -- 1. Hook Power1/2/3Button:fire + Hero/Power Co-op ownership guards (dynamic FL 8.2.0 power_selection aware!)
    local function power_deny_toast(idx, owner, reason)
        if not hooks.overlay then return end
        if reason == "hero_ult" then
            hooks.overlay:show_toast(string.format("那是 %dP 队友的英雄大招！", owner or 0), 2.2)
        elseif reason == "cooldown" then
            local info = hooks.coop and hooks.coop:get_power_slot_info(idx)
            local msg = (info and info.kind == "reinforcement") and "你的援军正在冷却中！" or "该法术正在冷却中！"
            hooks.overlay:show_toast(msg, 2.0)
        end
    end

    local power_classes = { Power1Button, Power2Button, Power3Button }
    for idx = 1, 3 do
        local cls = power_classes[idx]
        if cls and cls.fire then
            local orig_fire = cls.fire
            commands.orig_power_fire[idx] = orig_fire
            cls.fire = function(self_btn, wx, wy)
                if commands.executing or not hooks:is_sync_active() then
                    return orig_fire(self_btn, wx, wy)
                end
                if hooks.replay and hooks.replay:is_replaying() then
                    return
                end
                if hooks:is_mp_active() then
                    local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, idx)
                    if not ok_p then
                        game_gui:set_mode()
                        power_deny_toast(idx, owner, reason)
                        return
                    end
                end
                game_gui:set_mode()
                hooks:submit_command({
                    op = "POWER_FIRE",
                    idx = idx,
                    wx = wx,
                    wy = wy,
                })
            end
        end
        if cls and cls.on_click then
            local orig_pclick = cls.on_click
            cls.on_click = function(self_btn, button, x, y)
                if hooks:is_mp_active() then
                    local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, idx)
                    if not ok_p then
                        power_deny_toast(idx, owner, reason)
                        return
                    end
                end
                return orig_pclick(self_btn, button, x, y)
            end
        end
    end

    -- 1b. Hook FL 8.2.0 HeroUltimateButton ("a" / "s" dynamic overflow hero ultimate slots)
    if HeroUltimateButton and HeroUltimateButton.fire then
        local orig_hu_fire = HeroUltimateButton.fire
        commands.orig_hero_ult_fire = orig_hu_fire
        HeroUltimateButton.fire = function(self_btn, wx, wy)
            if commands.executing or not hooks:is_sync_active() then
                return orig_hu_fire(self_btn, wx, wy)
            end
            if hooks.replay and hooks.replay:is_replaying() then return end
            local slot = self_btn.hero_slot or "a"
            if hooks:is_mp_active() then
                local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, slot)
                if not ok_p then
                    game_gui:set_mode()
                    power_deny_toast(slot, owner, reason)
                    return
                end
            end
            game_gui:set_mode()
            hooks:submit_command({
                op = "POWER_FIRE",
                idx = slot,
                wx = wx,
                wy = wy,
            })
        end
    end
    if HeroUltimateButton and HeroUltimateButton.on_click then
        local orig_hu_click = HeroUltimateButton.on_click
        HeroUltimateButton.on_click = function(self_btn, button, x, y)
            local slot = self_btn.hero_slot or "a"
            if hooks:is_mp_active() then
                local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, slot)
                if not ok_p then
                    power_deny_toast(slot, owner, reason)
                    return
                end
            end
            return orig_hu_click(self_btn, button, x, y)
        end
    end

    if HeroPortrait and HeroPortrait.on_click then
        local orig_hp_click = HeroPortrait.on_click
        HeroPortrait.on_click = function(self_hp, button, x, y)
            if hooks:is_mp_active() then
                local e = game_gui:entity_by_id(self_hp.hero_id)
                if e and not hooks.coop:can_control_hero(hooks.coop.local_pid, e) then
                    if hooks.overlay then
                        local other = (hooks.coop.local_pid == 1) and 2 or 1
                        hooks.overlay:show_toast(string.format("那是 %dP 队友的英雄！", other), 2.0)
                    end
                    return
                end
            end
            return orig_hp_click(self_hp, button, x, y)
        end
    end

    -- 2. Hook PickView:rally_tower
    local orig_rally_tower = PickView.rally_tower
    PickView.rally_tower = function(self_pv, x, y)
        if not hooks:is_sync_active() then
            return orig_rally_tower(self_pv, x, y)
        end
        if hooks.replay and hooks.replay:is_replaying() then return false end

        local wx, wy = game_gui:u2g({ x = x, y = y })
        wx, wy = commands.quantize(wx), commands.quantize(wy)
        local e = game_gui.selected_entity
        if not e or not e.barrack then return false end
        if hooks:is_mp_active() and not hooks.coop:can_control_tower(hooks.coop.local_pid, e, "rally") then
            if hooks.overlay then hooks.overlay:show_toast("Owned by teammate!", 2.0) end
            game_gui:hide_rally_range()
            game_gui:deselect_entity()
            return false
        end
        local b = e.barrack
        local rc = { x = e.pos.x + e.tower.range_offset.x, y = e.pos.y + e.tower.range_offset.y }

        local function check_tower_rally(tx, ty)
            return U.is_inside_ellipse({ x = tx, y = ty }, rc, b.rally_range)
                and (b.rally_anywhere or (P:valid_node_nearby(tx, ty, nil, NF_RALLY) and GR:cell_is_only(tx, ty, b.rally_terrains)))
        end

        local fx, fy = nil, nil
        if check_tower_rally(wx, wy) then
            fx, fy = wx, wy
        else
            -- FL 8.2.0 smooth nearest-valid-point line clamp
            local cx, cy = e.pos.x, e.pos.y
            for it = 1, 199 do
                local lx = commands.quantize((cx * it + wx * (200 - it)) / 200)
                local ly = commands.quantize((cy * it + wy * (200 - it)) / 200)
                if check_tower_rally(lx, ly) then
                    fx, fy = lx, ly
                    break
                end
            end
        end

        if fx and fy then
            S:queue("GUIPlaceRallyPoint")
            hooks:submit_command({
                op = "TW_RALLY",
                id = e.id,
                wx = fx,
                wy = fy,
            })
            if game_gui.g2u then
                local ux, uy = game_gui:g2u({ x = fx, y = fy })
                game_gui:show_rally_flag(ux, uy)
            else
                game_gui:show_rally_flag(x, y)
            end
            game_gui:hide_rally_range()
            game_gui:deselect_entity()
            return true
        end
        game_gui:show_invalid_point_cross(x, y)
        return false
    end

    -- 3. Hook PickView:rally_hero
    local orig_rally_hero = PickView.rally_hero
    PickView.rally_hero = function(self_pv, x, y)
        if not hooks:is_sync_active() then
            return orig_rally_hero(self_pv, x, y)
        end
        if hooks.replay and hooks.replay:is_replaying() then return false end

        local wx, wy = game_gui:u2g({ x = x, y = y })
        wx, wy = commands.quantize(wx), commands.quantize(wy)
        local e = game_gui.selected_entity
        if not e or not e.nav_rally or not e.nav_grid then return false end
        if hooks:is_mp_active() and not hooks.coop:can_control_hero(hooks.coop.local_pid, e) then
            if hooks.overlay then
                local other = (hooks.coop.local_pid == 1) and 2 or 1
                hooks.overlay:show_toast(string.format("那是 %dP 队友的英雄！", other), 2.0)
            end
            game_gui:deselect_entity()
            return false
        end

        local function check_hero_rally(tx, ty)
            return (not e.nav_rally.requires_node_nearby or P:valid_node_nearby(tx, ty, nil, NF_RALLY))
                and GR:cell_is_only(tx, ty, e.nav_grid.valid_terrains_dest)
                and ((e.teleport and V.dist(tx, ty, e.pos.x, e.pos.y) > e.teleport.min_distance)
                    or e.nav_grid.ignore_waypoints
                    or GR:find_waypoints(e.pos, e.nav_rally.pos, { x = tx, y = ty }, e.nav_grid.valid_terrains, true))
        end

        local fx, fy = nil, nil
        if check_hero_rally(wx, wy) then
            fx, fy = wx, wy
        else
            local search_point = 200
            local lidx = game_gui.game and game_gui.game.store and game_gui.game.store.level_idx
            if lidx == 71 or lidx == 72 or (GS and GS.jnum4 and GS.last_level4 and lidx and lidx > GS.jnum4 and lidx <= GS.last_level4) then
                search_point = 10
            end
            local cx, cy = e.pos.x, e.pos.y
            for it = 1, search_point - 1 do
                local lx = commands.quantize((cx * it + wx * (search_point - it)) / search_point)
                local ly = commands.quantize((cy * it + wy * (search_point - it)) / search_point)
                if check_hero_rally(lx, ly) then
                    fx, fy = lx, ly
                    break
                end
            end
        end

        if fx and fy then
            hooks:submit_command({
                op = "HERO_RALLY",
                id = e.id,
                wx = fx,
                wy = fy,
            })
            game_gui:show_point_confirm(x, y)
            game_gui:deselect_entity()
            return true
        end
        game_gui:show_invalid_point_cross(x, y)
        return false
    end

    -- 3b. Hook PickView:rally_reinforcement (CRITICAL: FL 8.2.0 DragEntityView allows dragging reinforcements!)
    if PickView.rally_reinforcement then
        local orig_rally_reinf = PickView.rally_reinforcement
        PickView.rally_reinforcement = function(self_pv, x, y)
            if not hooks:is_sync_active() then
                return orig_rally_reinf(self_pv, x, y)
            end
            if hooks.replay and hooks.replay:is_replaying() then return false end

            local wx, wy = game_gui:u2g({ x = x, y = y })
            wx, wy = commands.quantize(wx), commands.quantize(wy)
            local e = game_gui.selected_entity
            if not e or not e.reinforcement or not e.nav_rally or not e.nav_grid or (e.health and e.health.dead) then
                return false
            end

            local function check_reinf_rally(tx, ty)
                return (not e.nav_rally.requires_node_nearby or P:valid_node_nearby(tx, ty, nil, NF_RALLY))
                    and GR:cell_is_only(tx, ty, e.nav_grid.valid_terrains_dest)
                    and ((e.teleport and V.dist(tx, ty, e.pos.x, e.pos.y) > e.teleport.min_distance)
                        or e.nav_grid.ignore_waypoints
                        or GR:find_waypoints(e.pos, e.nav_rally.pos, { x = tx, y = ty }, e.nav_grid.valid_terrains, true))
            end

            local fx, fy = nil, nil
            if check_reinf_rally(wx, wy) then
                fx, fy = wx, wy
            else
                local cx, cy = e.pos.x, e.pos.y
                for it = 1, 199 do
                    local lx = commands.quantize((cx * it + wx * (200 - it)) / 200)
                    local ly = commands.quantize((cy * it + wy * (200 - it)) / 200)
                    if check_reinf_rally(lx, ly) then
                        fx, fy = lx, ly
                        break
                    end
                end
            end

            if fx and fy then
                hooks:submit_command({
                    op = "REINF_RALLY",
                    id = e.id,
                    sid = e.reinforcement.squad_id,
                    wx = fx,
                    wy = fy,
                })
                if game_gui.g2u then
                    local ux, uy = game_gui:g2u({ x = fx, y = fy })
                    game_gui:show_point_confirm(ux, uy)
                else
                    game_gui:show_point_confirm(x, y)
                end
                game_gui:deselect_entity()
                return true
            end
            game_gui:show_invalid_point_cross(x, y)
            return false
        end
    end

    -- 4. Hook PickView:on_down (Alt+Click Map Ping + free_holder validation + SELECT_POINT + NEVER mutate e.ui.clicked locally!)
    local E_gui = require("entity_db")
    local function can_place_free_holder_sync(store, wx, wy)
        if not store or not E_gui then return false end
        local tpl = E_gui:get_template("tower_holder")
        local rect = tpl and tpl.ui and tpl.ui.click_rect
        if not rect then return true end
        local rx, ry, rw, rh = rect.pos.x, rect.pos.y, rect.size.x, rect.size.y
        local asp = ASPECT or 0.7
        local tmask = bit.bor(TERRAIN_LAND, TERRAIN_ICE)
        local pts = {
            { wx + rx + rw * 0.5, wy + ry + rh * 0.5 },
            { wx + rx + rw * 0.5, wy + ry + 0.5 * (1 - asp) * rh },
            { wx + rx + rw * 0.5, wy + ry + 0.5 * (1 + asp) * rh },
            { wx + rx,            wy + ry + rh * 0.5 },
            { wx + rx + rw,       wy + ry + rh * 0.5 },
        }
        for i = 1, #pts do
            local px, py = pts[i][1], pts[i][2]
            if not (GR:cell_is(px, py, tmask) and GR:cell_is_only(px, py, tmask) and not P:valid_node_nearby(px, py, nil, NF_RALLY)) then
                return false
            end
        end
        local cx, cy = wx + rx, wy + ry
        local function overlaps(ent)
            if not ent or ent._kr_mp_local or ent.enemy or ent.soldier or not ent.pos or not ent.ui or not ent.ui.click_rect then
                return false
            end
            local o = ent.ui.click_rect
            local ox, oy, ow, oh = ent.pos.x + o.pos.x, ent.pos.y + o.pos.y, o.size.x, o.size.y
            return cx < ox + ow and cx + rw > ox and cy < oy + oh and cy + rh > oy
        end
        for _, ent in pairs(store.entities) do
            if overlaps(ent) then return false end
        end
        for _, ent in ipairs(store.pending_inserts or {}) do
            if overlaps(ent) then return false end
        end
        return true
    end

    local orig_pv_down = PickView.on_down
    PickView.on_down = function(self_pv, button, x, y)
        if not hooks:is_sync_active() then
            return orig_pv_down(self_pv, button, x, y)
        end
        if hooks.replay and hooks.replay:is_replaying() then
            return true
        end
        -- Co-op Map Ping: Alt + Left Click anywhere on battlefield
        if button == 1 and hooks:is_mp_active() and love.keyboard
            and (love.keyboard.isDown("lalt") or love.keyboard.isDown("ralt")) then
            local wx, wy = game_gui:u2g({ x = x, y = y })
            hooks:submit_command({
                op = "MAP_PING",
                wx = commands.quantize(wx),
                wy = commands.quantize(wy),
            })
            return true
        end
        if button == 1 and game_gui.mode == "free_holder" then
            local wx, wy = game_gui:u2g({ x = x, y = y })
            wx, wy = commands.quantize(wx), commands.quantize(wy)
            local st = game_gui.game and game_gui.game.store
            if can_place_free_holder_sync(st, wx, wy) then
                hooks:submit_command({
                    op = "TW_FREE_HOLDER",
                    wx = wx,
                    wy = wy,
                })
                game_gui:show_point_confirm(x, y)
                game_gui:set_mode()
                S:queue("GUIPlaceRallyPoint")
            else
                game_gui:show_invalid_point_cross(x, y)
            end
            return true
        elseif button == 1 and game_gui.mode == GUI_MODE_SELECT_POINT then
            local wx, wy = game_gui:u2g({ x = x, y = y })
            wx, wy = commands.quantize(wx), commands.quantize(wy)
            local e = game_gui.selected_entity
            if e and e.user_selection then
                if e.user_selection.can_select_point_fn
                    and not e.user_selection.can_select_point_fn(e, wx, wy, game_gui.game.store) then
                    game_gui:show_invalid_point_cross(x, y)
                    return true
                end
                hooks:submit_command({
                    op = "TW_USER_SEL",
                    id = e.id,
                    phase = "point_confirm",
                    wx = wx,
                    wy = wy,
                })
                game_gui:deselect_entity()
                return true
            end
        elseif button == 1 and (game_gui.mode == GUI_MODE_IDLE or game_gui.mode == GUI_MODE_SWAP_TOWER) then
            -- Handle all IDLE & SWAP_TOWER clicks directly so orig_pv_down NEVER mutates e.ui.clicked = true locally!
            local wx, wy = game_gui:u2g({ x = x, y = y })
            local e = game_gui:entity_at_pos(wx, wy)
            if e and e.hero and hooks:is_mp_active() and not hooks.coop:can_control_hero(hooks.coop.local_pid, e) then
                if hooks.overlay then
                    local other = (hooks.coop.local_pid == 1) and 2 or 1
                    hooks.overlay:show_toast(string.format("那是 %dP 队友的英雄！", other), 2.0)
                end
                return true
            end
            if e and e.ui and e.ui.can_click then
                local needs_click_sync = (not e.tower and not e.hero and not e.soldier and not e.enemy)
                    or (e.clicks_to_destroy ~= nil)
                    or (e.tap_decal ~= nil)
                    or (e.click_play ~= nil)
                if needs_click_sync then
                    hooks:submit_command({ op = "CLICK_ENTITY", id = e.id })
                end
                if e ~= game_gui.selected_entity then
                    game_gui:select_entity(e)
                elseif not e.enemy then
                    game_gui:deselect_entity()
                end
            else
                game_gui:deselect_entity()
            end
            return true
        end
        return orig_pv_down(self_pv, button, x, y)
    end

    -- 5. Hook TowerMenuButton:on_click
    local orig_tmb_click = TowerMenuButton.on_click
    TowerMenuButton.on_click = function(self_btn)
        if not hooks:is_sync_active() then
            return orig_tmb_click(self_btn)
        end
        if hooks.replay and hooks.replay:is_replaying() then return end
        if not self_btn.parent or self_btn.parent.tweening or self_btn.click_disabled then
            return
        end

        local item, entity = self_btn.item, self_btn.entity
        if not item or not entity then
            return orig_tmb_click(self_btn)
        end

        -- Enforce Red/Blue Tower Ownership in Co-op "owned" mode before taking action
        if hooks:is_mp_active() and not hooks.coop:can_control_tower(hooks.coop.local_pid, entity, item.action) then
            if hooks.overlay then
                hooks.overlay:show_toast(string.format("这座塔归 %dP 队友所有（红蓝保护模式）！", entity._mp_owner or 0), 2.5)
            end
            game_gui:deselect_entity()
            return
        end

        -- Pure UI mode transitions (no simulation mutation yet) pass straight through
        if item.action == "tw_rally" or item.action == "tw_page" or item.action == "tw_add_holder" then
            return orig_tmb_click(self_btn)
        end

        self_btn:disable()
        local inhibit_sounds = false
        local new_mode

        if item.action == "tw_upgrade" or item.action == "tw_unblock" then
            hooks:submit_command({
                op = "TW_UPGRADE",
                id = entity.id,
                arg = item.action_arg,
            })
            game_gui:deselect_entity()

        elseif item.action == "tw_sell" then
            hooks:submit_command({
                op = "TW_SELL",
                id = entity.id,
            })
            game_gui:deselect_entity()

        elseif item.action == "upgrade_power" then
            local power = entity.powers and entity.powers[item.action_arg]
            local store = game_gui.game.store
            if power and power.level < power.max_level then
                local next_lvl = power.level + 1
                local ttype = entity.tower and entity.tower.type
                local cost
                if (ttype == "barracks_stage_19" or ttype == "update_1_hunter_outpost") and type(power.price) == "table" then
                    cost = power.price[math.min(next_lvl, power.max_level)] or 0
                else
                    cost = (next_lvl == 1) and power.price_base or power.price_inc
                end
                local avail = hooks:is_mp_active() and hooks.coop:get_local_display_gold() or store.player_gold
                if avail >= cost then
                    hooks:submit_command({
                        op = "TW_POWER",
                        id = entity.id,
                        arg = item.action_arg,
                    })
                    self_btn.parent:hide()
                else
                    inhibit_sounds = true
                end
            else
                inhibit_sounds = true
            end

        elseif item.action == "tw_buy_soldier" then
            hooks:submit_command({
                op = "TW_BUY_SOLDIER",
                id = entity.id,
                arg = item.action_arg,
            })
            game_gui:deselect_entity()

        elseif item.action == "tw_change_mode" then
            local e = game_gui.selected_entity
            if e and e.tower then
                hooks:submit_command({ op = "TW_CHANGE_MODE", id = e.id })
                if e.tower_upgrade_persistent_data then
                    new_mode = e.tower_upgrade_persistent_data.current_mode == 0 and 1 or 0
                end
                game_gui:deselect_entity()
            end
            self_btn.parent:hide()

        elseif item.action == "tw_swap_mode" then
            local e = game_gui.selected_entity
            if e and e.tower then
                hooks:submit_command({ op = "TW_CHANGE_MODE", id = e.id })
                game_gui:deselect_entity()
            end
            game_gui.swap_entity = e
            game_gui:set_mode(GUI_MODE_SWAP_TOWER)
            game_gui:show_ghost_hover()
            self_btn.parent:hide()

        elseif item.action == "tw_free_action" then
            local e = game_gui.selected_entity
            if e and e.user_selection then
                hooks:submit_command({
                    op = "TW_USER_SEL",
                    id = e.id,
                    phase = "free",
                    arg = item.action_arg,
                })
            end
            self_btn.parent:hide()

        elseif item.action == "tw_custom_no_close" or item.action == "tw_custom_close" then
            local e = game_gui.selected_entity
            if e and e.user_selection then
                hooks:submit_command({
                    op = "TW_USER_SEL",
                    id = e.id,
                    phase = "custom",
                    arg = (item.action_arg ~= "" and item.action_arg or nil),
                })
            end
            if item.action == "tw_custom_close" then
                game_gui:deselect_entity()
            elseif game_gui.towertooltip and game_gui.towertooltip.show then
                game_gui.towertooltip:show(e, item)
            end

        elseif item.action == "tw_repair" then
            local e = game_gui.selected_entity
            if e and e.user_selection then
                hooks:submit_command({
                    op = "TW_USER_SEL",
                    id = e.id,
                    phase = "repair",
                })
            end
            self_btn.parent:hide()

        elseif item.action == "tw_point" then
            local e = game_gui.selected_entity
            if e and e.user_selection then
                hooks:submit_command({
                    op = "TW_USER_SEL",
                    id = e.id,
                    phase = "point_start",
                })
            end
            game_gui:set_mode(GUI_MODE_SELECT_POINT)
            self_btn.parent:hide()

        elseif item.action == "tw_buy_attack" then
            local e = game_gui.selected_entity
            if e and e.user_selection then
                if e.user_selection.ignore_point then
                    hooks:submit_command({
                        op = "TW_USER_SEL",
                        id = e.id,
                        phase = "buy_attack_instant",
                        arg = item.action_arg,
                    })
                    game_gui:deselect_entity()
                else
                    hooks:submit_command({
                        op = "TW_USER_SEL",
                        id = e.id,
                        phase = "buy_attack_start",
                        arg = item.action_arg,
                    })
                    game_gui:set_mode(GUI_MODE_SELECT_POINT)
                    self_btn.parent:hide()
                end
            else
                game_gui:deselect_entity()
            end
        else
            return orig_tmb_click(self_btn)
        end

        if item.sounds and not inhibit_sounds then
            if item.action == "tw_change_mode" and #item.sounds > 1 and new_mode then
                S:queue(item.sounds[new_mode + 1])
            else
                for _, sid in orig_pairs(item.sounds) do
                    S:queue(sid)
                end
            end
        end
    end

    -- 6. Hook game_gui:c_swap_tower
    local orig_swap = game_gui.c_swap_tower
    commands.orig_c_swap_tower = orig_swap
    game_gui.c_swap_tower = function(self_gui, e)
        if not hooks:is_sync_active() then
            return orig_swap(self_gui, e)
        end
        if hooks.replay and hooks.replay:is_replaying() then return end
        if e and game_gui.swap_entity and e ~= game_gui.swap_entity then
            if hooks:is_mp_active() and (not hooks.coop:can_control_tower(hooks.coop.local_pid, e, "swap")
                or not hooks.coop:can_control_tower(hooks.coop.local_pid, game_gui.swap_entity, "swap")) then
                if hooks.overlay then hooks.overlay:show_toast("Cannot swap teammate's tower!", 2.5) end
                game_gui:deselect_entity()
                game_gui.swap_entity = nil
                game_gui:set_mode(GUI_MODE_IDLE)
                game_gui:hide_ghost_hover()
                return
            end
            hooks:submit_command({
                op = "TW_SWAP",
                id1 = game_gui.swap_entity.id,
                id2 = e.id,
            })
            game_gui:deselect_entity()
            game_gui.swap_entity = nil
            game_gui:set_mode(GUI_MODE_IDLE)
            game_gui:hide_ghost_hover()
        end
    end

    -- 7. Hook NextWaveButton & WaveFlag & Wave/Pause Hotkeys
    if NextWaveButton and NextWaveButton.on_click then
        local orig_nw = NextWaveButton.on_click
        NextWaveButton.on_click = function(self_nw, button, x, y)
            if not hooks:is_sync_active() then
                return orig_nw(self_nw, button, x, y)
            end
            if hooks.replay and hooks.replay:is_replaying() then return end
            hooks:submit_command({ op = "SEND_WAVE" })
        end
    end

    if WaveFlag and WaveFlag.on_click then
        local orig_wf = WaveFlag.on_click
        WaveFlag.on_click = function(self_wf)
            if not hooks:is_sync_active() then
                return orig_wf(self_wf)
            end
            if hooks.replay and hooks.replay:is_replaying() then return end
            hooks:submit_command({ op = "SEND_WAVE" })
        end
    end

    local orig_gui_key = game_gui.keypressed
    game_gui.keypressed = function(self_gui, key, isrepeat)
        if hooks:is_sync_active() then
            if hooks.replay and hooks.replay:is_replaying() then
                if key == "escape" then
                    return orig_gui_key(self_gui, key, isrepeat)
                end
                return false
            end
            local ks = self_gui.key_shortcuts
            local ok_ss, ss_mod = pcall(require, "shortcut_settings")
            local function match_sc(action_name)
                return ok_ss and ss_mod and ss_mod.matches and ks and ss_mod.matches(ks, action_name, key) == true
            end
            if hooks:is_mp_active() then
                -- Route pause hotkey through synchronized Co-op pause
                if key == "space" or (ks and key == ks.pause) then
                    if hooks.lockstep then hooks.lockstep:request_toggle_pause() end
                    return true
                end
                -- Dynamic FL 8.2.0 power hotkey ownership guard (works with custom keybinds & any spell/hero combo!)
                local pow_checks = {
                    { "pow_1", 1, "1" },
                    { "pow_2", 2, "2" },
                    { "pow_3", 3, "3" },
                    { "pow_a", "a", "a" },
                    { "pow_s", "s", "s" },
                }
                for i = 1, #pow_checks do
                    local sc_name, slot_id, fallback_k = pow_checks[i][1], pow_checks[i][2], pow_checks[i][3]
                    if match_sc(sc_name) or ((not ok_ss or not ss_mod or not ss_mod.matches) and key == fallback_k) then
                        local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, slot_id)
                        if not ok_p then
                            power_deny_toast(slot_id, owner, reason)
                            return true
                        end
                        break
                    end
                end
                -- Prevent hero_cycle hotkey from cycling onto teammate's hero
                local hero_cycle_key = (ok_ss and ss_mod and ss_mod.key and ss_mod.key(ks, "hero_cycle", 1, KEYPRESS_HERO_MAIN)) or KEYPRESS_HERO_MAIN
                if hero_cycle_key and key == hero_cycle_key then
                    local my_hid = hooks.coop.hero_ids[hooks.coop.local_pid]
                    local my_h = my_hid and self_gui.game and self_gui.game.store and self_gui.game.store.entities[my_hid]
                    if my_h and not (my_h.health and my_h.health.dead) then
                        if self_gui.selected_entity == my_h then
                            self_gui:deselect_entity()
                        else
                            self_gui:deselect_all()
                            self_gui:select_entity(my_h)
                        end
                    end
                    return true
                end
            end
            -- Intercept durax_clone hotkey so it NEVER sets e.ui.clicked = true locally & respects Co-op hero ownership!
            if match_sc("durax_clone") then
                local st = self_gui.game and self_gui.game.store
                if st and st.entities then
                    local list = {}
                    for _, ent in pairs(st.entities) do
                        if ent and ent.template_name == "hero_durax_clone" and not ent._kr_mp_local
                            and ent.ui and ent.ui.can_click and not (ent.health and ent.health.dead)
                            and (not hooks:is_mp_active() or hooks.coop:can_control_hero(hooks.coop.local_pid, ent)) then
                            list[#list + 1] = ent
                        end
                    end
                    table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
                    if #list > 0 then
                        local sel_idx = nil
                        for i = 1, #list do
                            if list[i] == self_gui.selected_entity then sel_idx = i; break end
                        end
                        self_gui:deselect_entity()
                        local next_idx = ((sel_idx or (ks and ks._last_durax_clone_idx) or 0) % #list) + 1
                        if ks then ks._last_durax_clone_idx = next_idx end
                        self_gui:select_entity(list[next_idx])
                    end
                end
                return true
            end
            -- Intercept early-wave hotkeys during recording or Co-op (incl. FL 8.2.0 shortcut_settings & 'w')
            local wave_key = (ks and ks.wave) or KEYPRESS_NEXTWAVE or "w"
            if (key == KEYPRESS_RETURN or (not DEBUG and key == wave_key) or match_sc("wave"))
                and self_gui.next_wave_button and not self_gui.next_wave_button:is_disabled() then
                hooks:submit_command({ op = "SEND_WAVE" })
                return true
            end
        end
        return orig_gui_key(self_gui, key, isrepeat)
    end

    -- 8. Suppress blocking tutorial/new-enemy popups during automated replay or Co-op
    if NotificationView and NotificationView.show then
        local orig_noti_show = NotificationView.show
        NotificationView.show = function(self_nv, id, no_transition, force_show)
            if hooks:is_mp_active() or (hooks.replay and (hooks.replay:is_replaying() or hooks.replay.auto_verify)) then
                return
            end
            return orig_noti_show(self_nv, id, no_transition, force_show)
        end
    end

    -- 9a. Preserve simulation fields that FL 8.2.0 UI mutates locally (trigger_deselect, user_selection.menu_shown, user_selection.in_progress)
    if game_gui.select_entity and not game_gui._kr_mp_td_sel_wrapped then
        game_gui._kr_mp_td_sel_wrapped = true
        local orig_sel_ent = game_gui.select_entity
        game_gui.select_entity = function(self_gui, e, ...)
            if not hooks:is_sync_active() then
                return orig_sel_ent(self_gui, e, ...)
            end
            local saved_td = e and e.trigger_deselect
            if e and e ~= self_gui.selected_entity then
                self_gui._kr_mp_ignored_td_eid = saved_td and e.id or nil
            end
            local ok_s, r1, r2 = pcall(orig_sel_ent, self_gui, e, ...)
            if e then e.trigger_deselect = saved_td end
            if not ok_s then error(r1) end
            return r1, r2
        end
    end

    if PickView and PickView.update and not PickView._kr_mp_td_upd_wrapped then
        PickView._kr_mp_td_upd_wrapped = true
        local orig_pv_upd = PickView.update
        PickView.update = function(self_pv, dt)
            if not hooks:is_sync_active() then
                return orig_pv_upd(self_pv, dt)
            end
            local e = game_gui.selected_entity
            local saved_td = e and e.trigger_deselect
            if e and not saved_td and game_gui._kr_mp_ignored_td_eid == e.id then
                game_gui._kr_mp_ignored_td_eid = nil
            end
            local masked = (e ~= nil and saved_td == true and game_gui._kr_mp_ignored_td_eid == e.id)
            if masked then
                e.trigger_deselect = nil
            end
            local ok_u, err_u = pcall(orig_pv_upd, self_pv, dt)
            if e then
                e.trigger_deselect = saved_td
            end
            if not ok_u then error(err_u) end
        end
    end

    if TowerMenu and not TowerMenu._kr_mp_menu_shown_wrapped then
        TowerMenu._kr_mp_menu_shown_wrapped = true
        if TowerMenu.show then
            local orig_tm_show = TowerMenu.show
            TowerMenu.show = function(self_tm, ...)
                if not hooks:is_sync_active() then
                    return orig_tm_show(self_tm, ...)
                end
                local e = game_gui.selected_entity
                local saved_ms = e and e.user_selection and e.user_selection.menu_shown
                local ok_m, r1 = pcall(orig_tm_show, self_tm, ...)
                if e and e.user_selection then
                    e.user_selection.menu_shown = saved_ms
                end
                if not ok_m then error(r1) end
                return r1
            end
        end
        if TowerMenu.hide then
            local orig_tm_hide = TowerMenu.hide
            TowerMenu.hide = function(self_tm, ...)
                if not hooks:is_sync_active() then
                    return orig_tm_hide(self_tm, ...)
                end
                local e = self_tm.entity or game_gui.selected_entity
                local saved_ms = e and e.user_selection and e.user_selection.menu_shown
                local ok_m, r1 = pcall(orig_tm_hide, self_tm, ...)
                if e and e.user_selection then
                    e.user_selection.menu_shown = saved_ms
                end
                if not ok_m then error(r1) end
                return r1
            end
        end
    end

    if game_gui.deselect_all and not game_gui._kr_mp_desel_all_wrapped then
        game_gui._kr_mp_desel_all_wrapped = true
        local orig_desel_all = game_gui.deselect_all
        game_gui.deselect_all = function(self_gui, ...)
            if not hooks:is_sync_active() or commands.executing then
                return orig_desel_all(self_gui, ...)
            end
            local e = self_gui.selected_entity
            local need_cancel = (e ~= nil and e.user_selection ~= nil and e.user_selection.in_progress == true)
            local saved_inp = need_cancel and e.user_selection.in_progress or nil
            local saved_pos = need_cancel and e.user_selection.new_pos or nil
            local ok_d, r1 = pcall(orig_desel_all, self_gui, ...)
            if need_cancel and e and e.user_selection then
                e.user_selection.in_progress = saved_inp
                e.user_selection.new_pos = saved_pos
                hooks:submit_command({
                    op = "TW_USER_SEL",
                    id = e.id,
                    phase = "cancel",
                })
            end
            if not ok_d then error(r1) end
            return r1
        end
    end

    -- 9b. Isolate pure-UI display/hover/stats/boss-power-block helpers so they never steal simulation E.last_id or Battle PRNG
    local function wrap_local_ui_method(tbl, method_name)
        if not tbl or type(tbl[method_name]) ~= "function" then return end
        local flag = "_kr_mp_locwrap_" .. method_name
        if tbl[flag] then return end
        tbl[flag] = true
        local orig_fn = tbl[method_name]
        tbl[method_name] = function(...)
            hooks.local_entity_depth = hooks.local_entity_depth + 1
            prng:enter_visual()
            local ok_u, r1, r2, r3 = pcall(orig_fn, ...)
            prng:exit_visual()
            hooks.local_entity_depth = hooks.local_entity_depth - 1
            if not ok_u then error(r1) end
            return r1, r2, r3
        end
    end

    wrap_local_ui_method(game_gui, "show_clickable_hover")
    wrap_local_ui_method(game_gui, "show_ghost_hover")
    wrap_local_ui_method(game_gui, "select_entity")
    wrap_local_ui_method(game_gui, "block_random_power")
    wrap_local_ui_method(WaveFlag, "on_enter")
    wrap_local_ui_method(TowerMenuButton, "on_enter")
    wrap_local_ui_method(TowerMenuButton, "on_exit")
    wrap_local_ui_method(InfoBar, "show")
    wrap_local_ui_method(InfoBar, "update_stats")
    wrap_local_ui_method(TowerTooltip, "show")
    wrap_local_ui_method(TowerMenuTooltip, "show")
    wrap_local_ui_method(TowerMenu, "show")

    -- 9c. Guard PauseView / restart_game / go_to_map during Co-op so opening Options never freezes peer or leaks coop.active!
    if PauseView and not PauseView._kr_mp_pause_wrapped then
        PauseView._kr_mp_pause_wrapped = true
        if PauseView.show then
            local orig_pv_show = PauseView.show
            PauseView.show = function(self_pv, ...)
                local st = game_gui.game and game_gui.game.store
                local mp_on = hooks:is_mp_active()
                local saved_paused = st and st.paused
                local ok_p, r1 = pcall(orig_pv_show, self_pv, ...)
                if mp_on and st then
                    st.paused = saved_paused
                end
                if not ok_p then error(r1) end
                return r1
            end
        end
        if PauseView.hide then
            local orig_pv_hide = PauseView.hide
            PauseView.hide = function(self_pv, ...)
                local st = game_gui.game and game_gui.game.store
                local mp_on = hooks:is_mp_active()
                local ok_p, r1 = pcall(orig_pv_hide, self_pv, ...)
                if mp_on and st and hooks.lockstep and hooks.lockstep:is_active() then
                    st.paused = not (hooks.lockstep:is_running() or hooks.lockstep:is_catching_up())
                end
                if not ok_p then error(r1) end
                return r1
            end
        end
    end
    if game_gui.restart_game and not game_gui._kr_mp_restart_wrapped then
        game_gui._kr_mp_restart_wrapped = true
        local orig_restart = game_gui.restart_game
        game_gui.restart_game = function(self_gui, ...)
            if hooks:is_mp_active() then
                if hooks.overlay then
                    hooks.overlay:show_toast("联机模式无法单人重开，请双方点顶部「退出」返回大厅重开！", 3.5)
                end
                return
            end
            return orig_restart(self_gui, ...)
        end
    end
    if game_gui.go_to_map and not game_gui._kr_mp_map_wrapped then
        game_gui._kr_mp_map_wrapped = true
        local orig_go_map = game_gui.go_to_map
        game_gui.go_to_map = function(self_gui, ...)
            if hooks:is_mp_active() and hooks.boot and hooks.boot.on_hud_action then
                pcall(hooks.boot.on_hud_action, hooks.boot, "mp_leave")
            end
            return orig_go_map(self_gui, ...)
        end
    end

    -- 10. Fix FL 8.2.0 DragEntityView stuck cyan dashed line & prevent dragging teammate's hero/tower in Co-op
    if DragEntityView and not DragEntityView._kr_mp_drag_wrapped then
        DragEntityView._kr_mp_drag_wrapped = true
        if DragEntityView.on_down then
            local orig_dv_down = DragEntityView.on_down
            DragEntityView.on_down = function(self_dv, button, x, y)
                orig_dv_down(self_dv, button, x, y)
                if hooks:is_mp_active() and self_dv.is_pressing and self_dv.pressed_entity then
                    local pe = self_dv.pressed_entity
                    local deny = false
                    if pe.hero and not hooks.coop:can_control_hero(hooks.coop.local_pid, pe) then
                        deny = true
                    elseif pe.soldier and pe.soldier.tower_id and game_gui.game and game_gui.game.store then
                        local tw = game_gui.game.store.entities[pe.soldier.tower_id]
                        if tw and not hooks.coop:can_control_tower(hooks.coop.local_pid, tw, "rally") then
                            deny = true
                        end
                    end
                    if deny then
                        self_dv.is_pressing = false
                        self_dv.pressed_entity = nil
                        self_dv.selected_entity = nil
                        if self_dv.disable_drag_line then self_dv:disable_drag_line() end
                    end
                end
            end
        end
        if DragEntityView.on_up then
            local orig_dv_up = DragEntityView.on_up
            DragEntityView.on_up = function(self_dv, button, x, y)
                orig_dv_up(self_dv, button, x, y)
                if button == 1 then
                    self_dv.is_pressing = false
                    self_dv.selected_entity = nil
                    self_dv.pressed_entity = nil
                    if self_dv.disable_drag_line then
                        self_dv:disable_drag_line()
                    end
                end
            end
        end
        if DragEntityView.update then
            local orig_dv_upd = DragEntityView.update
            DragEntityView.update = function(self_dv, dt)
                -- Cancel drag cleanly if pressed entity died or was removed mid-drag (prevents controller_path_direction 0/0 NaN!)
                if self_dv.is_pressing and self_dv.pressed_entity then
                    local pe = self_dv.pressed_entity
                    local st = game_gui.game and game_gui.game.store
                    local gone = (not st or not st.entities or not pe.id or st.entities[pe.id] ~= pe)
                        or (pe.health and pe.health.dead)
                    if gone then
                        self_dv.is_pressing = false
                        self_dv.selected_entity = nil
                        self_dv.pressed_entity = nil
                        if self_dv.disable_drag_line then self_dv:disable_drag_line() end
                        if game_gui and game_gui.is_dragging and game_gui:is_dragging() then
                            game_gui:set_mode(GUI_MODE_IDLE)
                        end
                        return
                    end
                end
                -- Auto-clean orphaned cyan drag line if mouse button 1 is no longer held (desktop)
                if not IS_ANDROID and love and love.mouse and love.mouse.isDown and not love.mouse.isDown(1) then
                    local stuck_line = self_dv.path_direction and self_dv.path_direction.selected_entity ~= nil
                    if self_dv.is_pressing or stuck_line then
                        self_dv.is_pressing = false
                        self_dv.selected_entity = nil
                        self_dv.pressed_entity = nil
                        if self_dv.disable_drag_line then
                            self_dv:disable_drag_line()
                        end
                        if game_gui and game_gui.is_dragging and game_gui:is_dragging() then
                            game_gui:set_mode(GUI_MODE_IDLE)
                        end
                        return
                    end
                end
                return orig_dv_upd(self_dv, dt)
            end
        end
    end
    if game_gui.deselect_entity and not game_gui._kr_mp_desel_drag_wrapped then
        game_gui._kr_mp_desel_drag_wrapped = true
        local orig_desel = game_gui.deselect_entity
        game_gui.deselect_entity = function(self_gui, ...)
            local r = orig_desel(self_gui, ...)
            if self_gui.drag_view and self_gui.drag_view.disable_drag_line
                and (not self_gui.is_dragging or not self_gui:is_dragging()) then
                self_gui.drag_view:disable_drag_line()
            end
            return r
        end
    end

    hooks.boot:log("GUI command hooks installed successfully.")
end

function hooks:on_update(dt)
    if main and main.handler then
        local ai = main.handler.active_item and main.handler.active_item.item_name or "nil"
        local qi = main.handler.queued_item and main.handler.queued_item.item_name or "nil"
        local key = ai .. "->" .. qi
        if key ~= self._last_screen_key then
            self._last_screen_key = key
            self.boot:log("DIRECTOR state: active=%s queued=%s", ai, qi)
        end
    end
    if self.coop and self.coop.try_launch_pending then
        self.coop:try_launch_pending()
    end
    if not self.installed_game or not self.installed_gui then
        self:ensure_game_and_gui_hooks()
    end
    if self.replay and self.replay.on_frame_update then
        self.replay:on_frame_update()
    end
end

function hooks:init(boot, replay, overlay, coop, lockstep)
    if self.installed_core then return end
    self.installed_core = true
    self.boot = boot
    self.replay = replay
    self.overlay = overlay
    self.coop = coop
    self.lockstep = lockstep
    commands:set_mp(coop, lockstep)

    prng:install()
    self:install_global_determinism()
    self:install_simulation_hooks()
end

return hooks
