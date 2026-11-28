-- KR-MP Simulation & Game Lifecycle Hooks
-- Manages canonical 16:9 visible_coords, visual system isolation, deterministic main_script
-- ordering, medical kit sync, 60Hz lockstep stepping, and game init/update/destroy lifecycle.
local prng = require("kr_mp.prng")
local commands = require("kr_mp.commands")

local M = {}

local function canonicalize_visible_coords(store)
    if not store then return end
    local ref_w = REF_W or 1024
    local ref_h = REF_H or 768
    local canon_w = ref_h * 16 / 9
    local panext = store.level and store.level.pan_extension
    store.visible_coords = {
        top = (panext and panext.top or 0) + ref_h,
        bottom = (panext and panext.bottom or 0),
        left = (ref_w - canon_w) / 2,
        right = ref_w + (canon_w - ref_w) / 2,
    }
end

local clean_tpl_backups = nil

local MAGE_BRILLIANCE_BULLETS = { "bolt_1", "bolt_2", "bolt_3", "bolt_archmage", "bolt_necromancer" }

local function snapshot_clean_templates(hooks, E)
    if not E or type(E.entities) ~= "table" or type(E.get_template) ~= "function" then return end
    local bk = {
        _entities_ref = E.entities,
        mage_bullets = {},
        ashbite = {},
        cfg_bullets = {},
    }
    for _, bn in ipairs(MAGE_BRILLIANCE_BULLETS) do
        local t = E:get_template(bn)
        if t and t.bullet then
            bk.mage_bullets[bn] = {
                min = t.bullet._orig_damage_min or t.bullet.damage_min,
                max = t.bullet._orig_damage_max or t.bullet.damage_max,
            }
        end
    end
    local ba = E:get_template("bullet_ashbite")
    if ba and ba.bullet then
        bk.ashbite.bullet_mod = ba.bullet.mod
        bk.ashbite.has_bullet = true
    end
    local aa = E:get_template("aura_ashbite_skill_a")
    if aa and aa.aura then
        bk.ashbite.aura_mod = aa.aura.mod
        bk.ashbite.has_aura = true
    end
    local ma = E:get_template("mod_ashbite_skill_b_burn")
    if ma and ma.dps then
        bk.ashbite.armor_sunder = ma.dps.armor_sunder
        bk.ashbite.has_mod = true
    end
    for name, t in hooks.orig_pairs(E.entities) do
        if type(t) == "table" and type(t.bullet) == "table"
            and (t.bullet.damage_min_config ~= nil or t.bullet.damage_max_config ~= nil) then
            bk.cfg_bullets[name] = {
                min = t.bullet.damage_min,
                max = t.bullet.damage_max,
            }
        end
    end
    clean_tpl_backups = bk
end

-- Restore pristine shared template fields before sim:init so cross-match in-place mutations
-- (mage_brilliance, hero_ashbite talents, get_info bullets) never leak across matches/restarts,
-- while never overwriting upgrades or pre-built mage towers applied during orig_init.
local function reset_dirty_templates(hooks, E)
    if not E or type(E.entities) ~= "table" or type(E.get_template) ~= "function" then return end
    if not clean_tpl_backups or clean_tpl_backups._entities_ref ~= E.entities then
        snapshot_clean_templates(hooks, E)
    end
    if not clean_tpl_backups then return end
    for _, bn in ipairs(MAGE_BRILLIANCE_BULLETS) do
        local t = E:get_template(bn)
        local bk = clean_tpl_backups.mage_bullets[bn]
        if t and t.bullet and bk then
            t.bullet.damage_min = bk.min
            t.bullet.damage_max = bk.max
            t.bullet._orig_damage_min = bk.min
            t.bullet._orig_damage_max = bk.max
        end
    end
    if clean_tpl_backups.ashbite.has_bullet then
        local ba = E:get_template("bullet_ashbite")
        if ba and ba.bullet then ba.bullet.mod = clean_tpl_backups.ashbite.bullet_mod end
    end
    if clean_tpl_backups.ashbite.has_aura then
        local aa = E:get_template("aura_ashbite_skill_a")
        if aa and aa.aura then aa.aura.mod = clean_tpl_backups.ashbite.aura_mod end
    end
    if clean_tpl_backups.ashbite.has_mod then
        local ma = E:get_template("mod_ashbite_skill_b_burn")
        if ma and ma.dps then ma.dps.armor_sunder = clean_tpl_backups.ashbite.armor_sunder end
    end
    for name, bk in hooks.orig_pairs(clean_tpl_backups.cfg_bullets) do
        local t = E:get_template(name)
        if t and t.bullet then
            t.bullet.damage_min = bk.min
            t.bullet.damage_max = bk.max
        end
    end
end

-- Dedicated deterministic wrapper for sys.render:
-- 1) on_insert uses sim PRNG for non-local entities (so s.random_ts stays 100% synced), visual PRNG for local ones.
-- 2) prepare_frame runs at render FPS and must NEVER mutate simulation-read sprite fields (runs/frame_idx/sync_flag/hidden).
local function wrap_render_system(hooks, S_sys, E)
    local rsys = S_sys and S_sys.render
    if not rsys then return end
    hooks.wrap_once(rsys, "on_insert", "det_render", function(orig_ins)
        return function(self_r, entity, store)
            local is_loc = not entity or entity._kr_mp_local or hooks.is_isolated_main_script_entity(entity)
            if is_loc then
                hooks.local_entity_depth = hooks.local_entity_depth + 1
                prng:enter_visual()
                local ok_r, res_r = pcall(orig_ins, self_r, entity, store)
                prng:exit_visual()
                hooks.local_entity_depth = hooks.local_entity_depth - 1
                if not ok_r then error(res_r) end
                return res_r
            end
            return orig_ins(self_r, entity, store)
        end
    end)

    hooks.wrap_once(rsys, "prepare_frame", "det_render", function(orig_pf)
        return function(self_r, dt, ts, store)
            if not (hooks:is_sync_active() and store and store.entities) then
                return orig_pf(self_r, dt, ts, store)
            end
            local saved = nil
            local sn = 0
            for id, e in hooks.orig_pairs(store.entities) do
                if type(id) == "number" and id < hooks.LOCAL_ID_BASE and e and not e._kr_mp_local and e.render and e.render.sprites then
                    local sprites = e.render.sprites
                    for i = 1, #sprites do
                        local s = sprites[i]
                        if s and s._render_frame_name == nil then
                            if not saved then saved = {} end
                            sn = sn + 1
                            saved[sn] = {
                                s = s,
                                runs = s.runs,
                                frame_idx = s.frame_idx,
                                sync_flag = s.sync_flag,
                                hidden = s.hidden,
                                anim_missing = s._animation_missing,
                                state_ts = s._render_state_ts,
                                frame_name = s.frame_name,
                            }
                        end
                    end
                end
            end
            local ok_p, err_p = pcall(orig_pf, self_r, dt, ts, store)
            if saved then
                for i = 1, sn do
                    local r = saved[i]
                    local s = r.s
                    s.runs = r.runs
                    s.frame_idx = r.frame_idx
                    s.sync_flag = r.sync_flag
                    s.hidden = r.hidden
                    s._animation_missing = r.anim_missing
                    s._render_state_ts = r.state_ts
                    s._render_frame_name = nil
                    s.frame_name = r.frame_name
                end
            end
            if not ok_p then error(err_p) end
        end
    end)
end

local function wrap_visual_systems(hooks, S_sys)
    local cb_names = {
        "on_insert", "on_remove", "on_insert_unconditional", "on_remove_unconditional",
        "on_queue", "on_dequeue", "on_render_update", "prepare_frame",
    }
    for sname, _ in hooks.orig_pairs(hooks.VISUAL_SYSTEMS) do
        local sys = S_sys[sname]
        if sys then
            for _, fn_name in ipairs(cb_names) do
                hooks.wrap_once(sys, fn_name, "vis_sys", function(orig_fn)
                    return function(...)
                        hooks.local_entity_depth = hooks.local_entity_depth + 1
                        prng:enter_visual()
                        local ok_v, a, b = pcall(orig_fn, ...)
                        prng:exit_visual()
                        hooks.local_entity_depth = hooks.local_entity_depth - 1
                        if not ok_v then error(a) end
                        return a, b
                    end
                end)
            end
        end
    end
end

local function wrap_medical_kit(hooks, E)
    local med_tpl = E and E.entities and E.entities["controller_item_medical_kit"]
    if not med_tpl or not med_tpl.main_script then return end
    hooks.wrap_once(med_tpl.main_script, "insert", "med_kit", function(orig_med_ins)
        return function(this_m, st_m)
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
    end)
end

local function wrap_g5_reinforcements(hooks, E)
    local g5_tpl = E and E.entities and E.entities["power_reinforcements_control_g5"]
    if not g5_tpl or not g5_tpl.main_script then return end
    hooks.wrap_once(g5_tpl.main_script, "insert", "g5_reinf_br", function(orig_g5_ins)
        return function(this_g5, st_g5, script_g5)
            local br = hooks:is_mp_active() and hooks.coop.max_tech
                and (this_g5._mp_g5_branch or hooks.coop:get_active_g5_branch()) or nil
            if br == "dark" or br == "royal" then
                local saved_re1 = E.entities["re_current_1"]
                local saved_re2 = E.entities["re_current_2"]
                local ok_g, res_g = hooks.coop:with_g5_branch(br, function()
                    if br == "dark" then
                        local t_sa = E:get_template("soldier_reinforcement_shadow_archer_01")
                        if t_sa then E:set_template("re_current_1", t_sa) end
                    else
                        local t_rm1 = E:get_template("soldier_reinforcement_rebel_militia_01")
                        local t_rm2 = E:get_template("soldier_reinforcement_rebel_militia_02")
                        if t_rm1 then E:set_template("re_current_1", t_rm1) end
                        if t_rm2 then E:set_template("re_current_2", t_rm2) end
                    end
                    return orig_g5_ins(this_g5, st_g5, script_g5)
                end)
                if saved_re1 then E.entities["re_current_1"] = saved_re1 end
                if saved_re2 then E.entities["re_current_2"] = saved_re2 end
                if not ok_g then error(res_g) end
                return res_g
            end
            return orig_g5_ins(this_g5, st_g5, script_g5)
        end
    end)
end

-- Universal G1-G4 draggable reinforcements: FL 8.2.0 only gives G5/G6 reinforcements `nav_grid`,
-- `squad_id`, and `nav_rally.new` rally handling. Granting canonical `nav_grid` + deterministic
-- `squad_id` on insert and handling `nav_rally.new` via SU makes ALL G1..G6 squads draggable.
local function preserve_tower_swap_owner(st, e)
    if not (st and e and e.tower and not e._kr_mp_local and not e._mp_owner) then return end
    local dom = st._dominant_entity
    if not dom or type(dom.template_name) ~= "string" then return end
    local dname = dom.template_name
    if dname == "controller_tower_swap" or dname == "controller_tower_swap_overseer" then
        local t1, t2 = dom.tower_1, dom.tower_2
        local hid = e.tower.holder_id
        if t1 and t2 and t1.tower and t2.tower and hid ~= nil then
            if hid == t2.tower.holder_id and t1._mp_owner and e.tower.type ~= "holder" then
                e._mp_owner = t1._mp_owner
            elseif hid == t1.tower.holder_id and t2._mp_owner and e.tower.type ~= "holder" then
                e._mp_owner = t2._mp_owner
            end
        end
    elseif dname == "royal_archers_tower_combination_controller" then
        local t1 = dom.tower_1
        if t1 and t1._mp_owner and e.tower.type ~= "holder" then
            e._mp_owner = t1._mp_owner
        end
    end
end

local function ensure_draggable_reinforcement(store, e, E)
    if not (e and not e._kr_mp_local and e.reinforcement and e.soldier and e.nav_rally) then
        return
    end
    if not e.nav_grid then
        local ng = E and E.clone_c and E:clone_c("nav_grid") or nil
        if ng then
            e.nav_grid = ng
        else
            local ok_b, bit_mod = pcall(require, "bit")
            local tmask = (ok_b and bit_mod and bit_mod.bor)
                and bit_mod.bor(TERRAIN_LAND or 1, TERRAIN_ICE or 4)
                or ((TERRAIN_LAND or 1) + (TERRAIN_ICE or 4))
            e.nav_grid = {
                valid_terrains = tmask,
                valid_terrains_dest = tmask,
                waypoints = {},
                ignore_waypoints = nil,
            }
        end
        e._kr_mp_reinf_drag = true
        if e.sound_events and not e.sound_events.change_rally_point and e.sound_events.insert then
            e.sound_events.change_rally_point = e.sound_events.insert
        end
    end
    if not e.reinforcement.squad_id and store then
        if store._kr_mp_active_reinf_squad_id then
            e.reinforcement.squad_id = store._kr_mp_active_reinf_squad_id
        else
            local c = e.nav_rally.center or e.pos
            local key = string.format("%d:%d:%d",
                store.tick or 0,
                math.floor(((c and c.x) or 0) * 100 + 0.5),
                math.floor(((c and c.y) or 0) * 100 + 0.5))
            if store._kr_mp_reinf_squad_key ~= key then
                store._kr_mp_reinf_squad_seq = (store._kr_mp_reinf_squad_seq or 0) + 1
                store._kr_mp_reinf_squad_key = key
                store._kr_mp_reinf_squad_cur = 90000000 + store._kr_mp_reinf_squad_seq
            end
            e.reinforcement.squad_id = store._kr_mp_reinf_squad_cur
        end
    end
end

local function handle_augmented_reinf_rally(SU_mod, store, this)
    if not (this and this._kr_mp_reinf_drag and this.nav_rally and this.nav_rally.new and this.nav_grid) then
        return false
    end
    if this.health and this.health.dead then
        this.nav_rally.new = false
        return false
    end
    while this.nav_rally.new do
        if this.health and this.health.dead then
            this.nav_rally.new = false
            return true
        end
        if this.reinforcement and this.reinforcement.duration
            and (store.tick_ts - (this.reinforcement.ts or 0) > this.reinforcement.duration) then
            this.nav_rally.new = false
            return true
        end
        if SU_mod.y_hero_new_rally(store, this) then
            return true
        end
    end
    return true
end

local function wrap_reinf_drag_script_utils(hooks)
    local orig_pairs = hooks.orig_pairs
    for mod_name, SU_mod in orig_pairs(package.loaded) do
        if type(mod_name) == "string" and mod_name:find("^script_utils")
            and type(SU_mod) == "table" and type(SU_mod.y_hero_new_rally) == "function" then
            hooks.wrap_once(SU_mod, "y_soldier_melee_block_and_attacks", "reinf_drag", function(orig_melee)
                return function(store, this, ...)
                    if handle_augmented_reinf_rally(SU_mod, store, this) then
                        return true
                    end
                    return orig_melee(store, this, ...)
                end
            end)
            hooks.wrap_once(SU_mod, "y_soldier_ranged_attacks", "reinf_drag", function(orig_ranged)
                return function(store, this, ...)
                    if handle_augmented_reinf_rally(SU_mod, store, this) then
                        return true
                    end
                    return orig_ranged(store, this, ...)
                end
            end)
            hooks.wrap_once(SU_mod, "soldier_go_back_step", "reinf_drag", function(orig_back)
                return function(store, this, ...)
                    if handle_augmented_reinf_rally(SU_mod, store, this) then
                        return true
                    end
                    return orig_back(store, this, ...)
                end
            end)
        end
    end
end

local function wrap_sim_skip_local_systems(hooks, S_sys)
    local sim_skip_sys = { "sso_post", "events", "count_groups", "game_upgrades", "game_upgrades_6", "health" }
    local cb_names = { "on_insert", "on_remove", "on_insert_unconditional", "on_remove_unconditional", "on_queue", "on_dequeue" }
    for _, sname in ipairs(sim_skip_sys) do
        local sys = S_sys[sname]
        if sys then
            for _, fn_name in ipairs(cb_names) do
                local is_bool_gate = (fn_name == "on_insert" or fn_name == "on_remove")
                hooks.wrap_once(sys, fn_name, "skip_local", function(orig_fn)
                    return function(self_s, entity, ...)
                        if entity and entity._kr_mp_local then
                            return is_bool_gate and true or nil
                        end
                        return orig_fn(self_s, entity, ...)
                    end
                end)
            end
        end
    end
end

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

local function sort_ms_array_by_id(orig_pairs, arr, idx_map, cnt)
    if not arr or not cnt or cnt <= 1 then return end
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

-- Wrap sys.main_script so local UI/particle emitters never enter swap-remove sim arrays,
-- and pure simulation main_script entities always execute in canonical ascending e.id order.
local function wrap_main_script_system(hooks, S_sys, E)
    local ms = S_sys.main_script
    if not ms then return end

    local log_ms = require("klua.log"):new("systems")
    local orig_pairs = hooks.orig_pairs

    hooks.wrap_once(ms, "init", "ms_iso", function(orig_ms_init)
        return function(self_ms, st)
            local res = orig_ms_init(self_ms, st)
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
    end)

    hooks.wrap_once(ms, "on_insert_unconditional", "ms_iso", function(orig_ms_ins_u)
        return function(self_ms, entity, st)
            if hooks.is_isolated_main_script_entity(entity) then
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
    end)

    hooks.wrap_once(ms, "on_remove_unconditional", "ms_iso", function(orig_ms_rem_u)
        return function(self_ms, entity, st)
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
    end)

    hooks.wrap_once(ms, "on_update", "ms_iso", function()
        return function(self_ms, dt, ts, st)
            local mp_on = hooks:is_mp_active()
            local sync_on = hooks:is_sync_active()

            local function step_coro_entity(e, force_local)
                local s = e and e.main_script
                if not s or not s.update then return end
                local is_loc = force_local or e._kr_mp_local or hooks.is_isolated_main_script_entity(e)
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
                        if s.co == co then s.co = nil end
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
                local is_loc = force_local or e._kr_mp_local or hooks.is_isolated_main_script_entity(e)
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
                    sort_ms_array_by_id(orig_pairs, st.entities_with_main_script_on_update, st.entities_with_main_script_on_update_index, cnt)
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
                        sort_ms_array_by_id(orig_pairs, list1, st.entities_with_main_script_on_update_index1, cnt1)
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
                    for i = 1, (st._kr_mp_local_ms_count or 0) do
                        local e = loc_list[i]
                        if e then step_coro_entity(e, true) end
                    end
                end
                local loc_list1 = st._kr_mp_local_ms_list1
                if loc_list1 then
                    for i = 1, (st._kr_mp_local_ms_count1 or 0) do
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
    end)
end

local function step_mp_update(hooks, self_sim, d, dt)
    if hooks.lockstep:is_catching_up() then
        if main and main.handler and main.handler.active_item ~= game then
            return
        end
        local max_step = 30
        if hooks.lockstep.blackbox_replay then
            local env_sp = tonumber(os.getenv("KR_MP_BLACKBOX_SPEED"))
            if env_sp and env_sp >= 1 then
                max_step = math.min(60, math.floor(env_sp))
            end
        end
        for _ = 1, max_step do
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
    if os.getenv("KR_MP_AUTO_COOP_FAST") == "1" then
        -- Cap to 8 ticks/frame (<=160 turns/s @ 60fps) so fast CPUs stay safely below Go server's 200 msg/s rate limit
        for _ = 1, 8 do
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
            -- Waiting for remote peer's turn packet; clamp accumulator to prevent burst-spikes
            d.to = TICK_LENGTH
            break
        end
    end
    if d.to > TICK_LENGTH then
        d.to = TICK_LENGTH
    end
end

local function step_replay_update(hooks, self_sim, d, dt, km)
    if hooks.replay:is_replaying() then
        local speed = hooks.replay:get_replay_speed()
        if speed > 1 then
            for _ = 1, speed do
                if d.paused or not hooks.replay:is_replaying() then break end
                d.dt = TICK_LENGTH
                d.to = 0
                self_sim:do_tick()
            end
            d.step = false
            return true
        end
        d.dt = TICK_LENGTH
        d.to = d.to + dt
        if d.to > TICK_LENGTH then
            d.to = km.clamp(0, TICK_LENGTH, d.to - TICK_LENGTH)
            self_sim:do_tick()
            d.step = false
        end
        return true
    end
    if hooks.replay:is_recording() then
        if hooks.replay.auto_verify then
            for _ = 1, 25 do
                if d.paused or not hooks.replay:is_recording() then break end
                d.dt = TICK_LENGTH
                d.to = 0
                self_sim:do_tick()
            end
            d.step = false
            return true
        end
        d.dt = TICK_LENGTH
        d.to = d.to + dt
        if d.to > TICK_LENGTH then
            d.to = km.clamp(0, TICK_LENGTH, d.to - TICK_LENGTH)
            self_sim:do_tick()
            d.step = false
        end
        return true
    end
    return false
end

function M.install_simulation(hooks)
    local sim = require("simulation")
    if not sim then return end

    local km = require("klua.macros")
    local E = require("entity_db")

    local installed = hooks.wrap_once(sim, "init", "sim_core", function(orig_init)
        return function(self_sim, store, system_names)
            hooks:ensure_game_and_gui_hooks()
            hooks.boot:log("sim:init called (level=%s, mode=%s, diff=%s)",
                tostring(store and store.level_idx), tostring(store and store.level_mode), tostring(store and store.level_difficulty))
            hooks.active_store = store
            hooks.entity_ids = {}
            hooks.co_counter = 0
            hooks.local_entity_depth = 0
            hooks.local_entity_id = hooks.LOCAL_ID_BASE
            if E then E.last_id = 1 end

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

            if E and type(E.load) == "function" then
                hooks.wrap_once(E, "load", "tpl_clean_snap", function(orig_eload)
                    return function(self_e, ...)
                        local res = orig_eload(self_e, ...)
                        snapshot_clean_templates(hooks, self_e)
                        return res
                    end
                end)
            end

            if hooks:is_sync_active() then
                canonicalize_visible_coords(store)
                reset_dirty_templates(hooks, E)
            end

            local S_sys = require("systems")
            wrap_visual_systems(hooks, S_sys)
            wrap_render_system(hooks, S_sys, E)
            hooks.wrap_local_ui(self_sim, "prepare_render")
            wrap_medical_kit(hooks, E)
            wrap_g5_reinforcements(hooks, E)
            wrap_reinf_drag_script_utils(hooks)
            wrap_sim_skip_local_systems(hooks, S_sys)
            wrap_main_script_system(hooks, S_sys, E)

            hooks.sim_exec_depth = hooks.sim_exec_depth + 1
            prng:enter_sim()
            local ok, err = pcall(orig_init, self_sim, store, system_names)
            prng:exit_sim()
            hooks.sim_exec_depth = hooks.sim_exec_depth - 1
            if not ok then error(err) end

            -- Re-attach template & script_utils hooks AFTER orig_init (E:load() creates/reloads E.entities & script_utils)
            wrap_medical_kit(hooks, E)
            wrap_g5_reinforcements(hooks, E)
            wrap_reinf_drag_script_utils(hooks)

            -- Rebuild initial sorted entity_ids from any entities inserted directly during init
            hooks.entity_ids = {}
            for id in hooks.orig_pairs(store.entities) do
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
    end)
    if not installed then return end

    hooks.wrap_once(sim, "insert_entity", "sim_core", function(orig_insert)
        return function(self_sim, e)
            local is_local = e and e._kr_mp_local
            local st = self_sim.store
            local saved_cnt = is_local and st and st.entity_count or nil
            local saved_max = is_local and st and st.entity_max or nil
            if is_local then
                hooks.local_entity_depth = hooks.local_entity_depth + 1
                prng:enter_visual()
            else
                ensure_draggable_reinforcement(st, e, E)
                if hooks:is_mp_active() then
                    preserve_tower_swap_owner(st, e)
                end
                hooks.sso_mutation_gen = (hooks.sso_mutation_gen or 0) + 1
            end
            local ok_i, err_i = pcall(orig_insert, self_sim, e)
            if is_local then
                if st and saved_cnt ~= nil then
                    st.entity_count = saved_cnt
                    st.entity_max = saved_max
                end
                prng:exit_visual()
                hooks.local_entity_depth = hooks.local_entity_depth - 1
            else
                hooks.sso_mutation_gen = (hooks.sso_mutation_gen or 0) + 1
            end
            if not ok_i then error(err_i) end
            if self_sim.store == hooks.active_store and e and e.id and self_sim.store.entities[e.id] == e then
                hooks:add_entity_id(e.id)
                if hooks:is_mp_active() and e.hero then
                    hooks.coop:on_entity_inserted(e)
                end
            end
        end
    end)

    hooks.wrap_once(sim, "remove_entity", "sim_core", function(orig_remove)
        return function(self_sim, e)
            local is_local = e and e._kr_mp_local
            local st = self_sim.store
            local saved_cnt = is_local and st and st.entity_count or nil
            local saved_max = is_local and st and st.entity_max or nil
            if is_local then
                hooks.local_entity_depth = hooks.local_entity_depth + 1
                prng:enter_visual()
            else
                hooks.sso_mutation_gen = (hooks.sso_mutation_gen or 0) + 1
            end
            local ok_r, err_r = pcall(orig_remove, self_sim, e)
            if is_local then
                if st and saved_cnt ~= nil then
                    st.entity_count = saved_cnt
                    st.entity_max = saved_max
                end
                prng:exit_visual()
                hooks.local_entity_depth = hooks.local_entity_depth - 1
            else
                hooks.sso_mutation_gen = (hooks.sso_mutation_gen or 0) + 1
            end
            if not ok_r then error(err_r) end
        end
    end)

    hooks.wrap_once(sim, "update", "sim_core", function(orig_update)
        return function(self_sim, dt)
            local d = self_sim.store
            if not d then return end
            if d.paused and not d.step then return end

            if hooks:is_mp_active() and hooks.lockstep then
                step_mp_update(hooks, self_sim, d, dt)
                return
            end
            if hooks.replay and step_replay_update(hooks, self_sim, d, dt, km) then
                return
            end
            return orig_update(self_sim, dt)
        end
    end)

    hooks.wrap_once(sim, "do_tick", "sim_core", function()
        return function(self_sim)
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

                -- 2. Standard entity insert/remove flush
                if self_sim.flush_pending_entities then
                    self_sim:flush_pending_entities()
                else
                    while #d.pending_inserts > 0 do
                        self_sim:insert_entity(table.remove(d.pending_inserts, 1))
                    end
                    while #d.pending_removals > 0 do
                        self_sim:remove_entity(table.remove(d.pending_removals, 1))
                    end
                end

                -- 3. Run all simulation systems in exact order; isolate visual systems & account Co-op gold deltas
                local sys_cnt = self_sim.systems_on_update_count or #self_sim.systems_on_update
                for i = 1, sys_cnt do
                    local sys = self_sim.systems_on_update[i]
                    if hooks.VISUAL_SYSTEMS[sys.name] then
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
                    hooks:compact_entity_ids(d.entities)
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
            if not ok_tick then error(err_tick) end
        end
    end)

    hooks.boot:log("Simulation hooks installed successfully.")
end

function M.install_game(hooks, g)
    if not g then return end
    local ok = hooks.wrap_once(g, "init", "game_core", function(orig_game_init)
        return function(self_g, ...)
            orig_game_init(self_g, ...)
            local gui = self_g.game_gui or package.loaded["game_gui"]
            hooks:install_gui_hooks(gui)
            if hooks.coop and hooks.coop:is_active() then
                hooks.coop:on_game_gui_ready(gui)
                hooks.coop:on_game_ready()
            end
        end
    end)
    if not ok then return end
    hooks.installed_game = true

    hooks.wrap_once(g, "restart", "game_core", function(orig_game_restart)
        return function(self_g, ...)
            orig_game_restart(self_g, ...)
            local gui = self_g.game_gui or package.loaded["game_gui"]
            hooks:install_gui_hooks(gui)
            if hooks.coop and hooks.coop:is_active() then
                hooks.coop:on_game_gui_ready(gui)
                hooks.coop:on_game_ready()
            end
        end
    end)

    hooks.wrap_once(g, "update", "game_core", function(orig_game_update)
        return function(self_g, dt)
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
    end)

    hooks.wrap_once(g, "destroy", "game_core", function(orig_game_destroy)
        return function(self_g, ...)
            if hooks.replay then
                hooks.replay:on_game_destroy()
            end
            return orig_game_destroy(self_g, ...)
        end
    end)

    hooks.boot:log("Game hooks installed successfully (lazy).")
end

return M
