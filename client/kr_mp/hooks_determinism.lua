-- KR-MP Global Determinism Hooks
-- Ensures canonical iteration order (pairs/filter/SSO), dual entity ID spaces,
-- visual sound PRNG isolation, A* cache bypass, comic skip, and deterministic slot loading.
local prng = require("kr_mp.prng")

local M = {}

local function sorted_entities_pairs(hooks, entities)
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

local function sorted_waves_pairs(hooks, waves_tbl)
    local list = {}
    local n = 0
    for k in hooks.orig_pairs(waves_tbl) do
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

local function sorted_string_pairs(hooks, tbl)
    local list = {}
    local n = 0
    for k in hooks.orig_pairs(tbl) do
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

local function sorted_numeric_pairs(hooks, tbl)
    local list = {}
    local n = 0
    for k in hooks.orig_pairs(tbl) do
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

local function install_sso_hooks(hooks)
    local ok_sso, SSO = pcall(require, "klove.sso")
    if not ok_sso or type(SSO) ~= "table" then
        ok_sso, SSO = pcall(require, "sso")
    end
    if not ok_sso or type(SSO) ~= "table" then return end

    hooks.sso_ref = SSO
    hooks.wrap_once(SSO, "create", "det_sso", function(orig_sso_create)
        return function(self_s, name, x, y, w, h)
            -- Canonical fixed grid origin (0,0) during sync so different aspect ratios produce identical spatial buckets
            if hooks:is_sync_active() then
                return orig_sso_create(self_s, name, 0, 0, 2048, 1280)
            end
            return orig_sso_create(self_s, name, x, y, w, h)
        end
    end)

    hooks.wrap_once(SSO, "filter", "det_sso", function(orig_sso_filter)
        return function(self_s, out, name, x, y, range, filter_fn)
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
    end)
end

local function install_entity_db_hooks(hooks)
    local E = require("entity_db")
    if not E then return end
    local trace_ents = (os.getenv("KR_MP_TRACE_ENTITIES") == "1")

    hooks.wrap_once(E, "create_entity", "det_edb", function(orig_create_entity)
        return function(self_e, t)
            local use_local = (hooks.local_entity_depth > 0)
                or hooks.is_local_template(t)
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
    end)

    hooks.wrap_once(E, "clone_entity", "det_edb", function(orig_clone_entity)
        return function(self_e, e)
            local use_local = (hooks.local_entity_depth > 0)
                or (e and e._kr_mp_local)
                or hooks.is_local_template(e)
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
    end)

    hooks.wrap_once(E, "filter", "det_edb", function(orig_filter)
        return function(self_e, entities, ...)
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
    end)

    hooks.wrap_once(E, "filter_iter", "det_edb", function(orig_filter_iter)
        return function(self_e, entities, c1, c2, c3)
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
    end)
end

local function ensure_fl_slot_defaults(hooks, slot)
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

local function install_misc_determinism_hooks(hooks)
    -- Isolate sound_db RNG from battle simulation PRNG
    local S = require("sound_db")
    hooks.wrap_once(S, "queue", "det_sound", function(orig_s_queue)
        return function(...)
            prng:enter_visual()
            local r1, r2, r3 = orig_s_queue(...)
            prng:exit_visual()
            return r1, r2, r3
        end
    end)

    -- Disable cell-only GR.waypoints_cache so unquantized UI hover/validate never leaks into sim pathing
    local GR = require("grid_db")
    hooks.wrap_once(GR, "find_waypoints", "det_grid", function(orig_find_wp)
        return function(self_gr, from, from_fallback, to, valid_terrains, force_recalc)
            return orig_find_wp(self_gr, from, from_fallback, to, valid_terrains, true)
        end
    end)

    -- Auto-skip campaign intro comics in Co-op / Replay across ALL FL 8.2.0 generations (KR1..KR6)
    for _, lu_mod in ipairs({ "level_utils", "level_utils_5", "level_utils_57", "level_utils_6" }) do
        local ok_lu, LU = pcall(require, lu_mod)
        if ok_lu and LU then
            hooks.wrap_once(LU, "load_level", "det_comic", function(orig_load_level)
                return function(store, name)
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
            end)
        end
    end

    -- Hook storage:load_slot / save_slot so replay & Co-op inject exact initial hero/upgrade snapshot safely
    local storage = require("storage")
    hooks.wrap_once(storage, "load_slot", "det_storage", function(orig_load_slot)
        return function(self_s, idx, force)
            if hooks.coop then
                local mp_snap = hooks.coop:get_slot_override()
                if mp_snap then
                    return ensure_fl_slot_defaults(hooks, mp_snap)
                end
            end
            if hooks.replay then
                local snap = hooks.replay:get_slot_override()
                if snap then
                    return ensure_fl_slot_defaults(hooks, snap)
                end
            end
            return ensure_fl_slot_defaults(hooks, orig_load_slot(self_s, idx, force))
        end
    end)

    hooks.wrap_once(storage, "save_slot", "det_storage", function(orig_save_slot)
        return function(self_s, ...)
            if (hooks.coop and hooks.coop:is_active()) or (hooks.replay and hooks.replay:is_replaying()) then
                return true -- never overwrite disk save during Co-op or replay
            end
            return orig_save_slot(self_s, ...)
        end
    end)
end

function M.install(hooks)
    if hooks._determinism_installed then return end
    hooks._determinism_installed = true

    -- 1. Monotonic coroutine tagging
    local orig_co_create = hooks.orig_coroutine_create
    coroutine.create = function(fn)
        local co = orig_co_create(fn)
        hooks.co_counter = hooks.co_counter + 1
        hooks.co_seq[co] = hooks.co_counter
        return co
    end

    -- 2. SSO spatial index determinism
    install_sso_hooks(hooks)

    -- 3. Targeted deterministic pairs() for store.entities, waves_active, manual_wave_cos, SSO persistent_lists
    local orig_pairs = hooks.orig_pairs
    pairs = function(t)
        local st = hooks.active_store
        if st ~= nil then
            if t == st.entities then
                return sorted_entities_pairs(hooks, t)
            elseif t == st.waves_active then
                return sorted_waves_pairs(hooks, t)
            elseif t == st.manual_wave_cos then
                return sorted_string_pairs(hooks, t)
            end
            local sso = hooks.sso_ref
            if sso and sso.persistent_lists then
                local pl = sso.persistent_lists
                if t == pl.alive_enemies or t == pl.graveyards or t == pl.modifiers or t == pl.towers then
                    return sorted_numeric_pairs(hooks, t)
                end
            end
        end
        return orig_pairs(t)
    end

    -- 4. Entity DB dual ID space + deterministic filter
    install_entity_db_hooks(hooks)

    -- 5. Sound PRNG, Grid cache bypass, Comic skip, Storage snapshot override
    install_misc_determinism_hooks(hooks)
end

return M
