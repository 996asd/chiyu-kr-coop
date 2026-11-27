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
    local cur_vc = store.visible_coords
    store.visible_coords = {
        top = (cur_vc and cur_vc.top) or ((panext and panext.top or 0) + ref_h),
        bottom = (cur_vc and cur_vc.bottom) or (panext and panext.bottom or 0),
        left = (ref_w - canon_w) / 2,
        right = ref_w + (canon_w - ref_w) / 2,
    }
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
                and (this_g5._mp_g5_branch or hooks.coop._active_g5_branch) or nil
            if br == "dark" or br == "royal" then
                local prev_br = hooks.coop._active_g5_branch
                local saved_re1 = E.entities["re_current_1"]
                local saved_re2 = E.entities["re_current_2"]
                hooks.coop._active_g5_branch = br
                if br == "dark" then
                    local t_sa = E:get_template("soldier_reinforcement_shadow_archer_01")
                    if t_sa then E:set_template("re_current_1", t_sa) end
                else
                    local t_rm1 = E:get_template("soldier_reinforcement_rebel_militia_01")
                    local t_rm2 = E:get_template("soldier_reinforcement_rebel_militia_02")
                    if t_rm1 then E:set_template("re_current_1", t_rm1) end
                    if t_rm2 then E:set_template("re_current_2", t_rm2) end
                end
                local ok_g, res_g = pcall(orig_g5_ins, this_g5, st_g5, script_g5)
                if saved_re1 then E.entities["re_current_1"] = saved_re1 end
                if saved_re2 then E.entities["re_current_2"] = saved_re2 end
                hooks.coop._active_g5_branch = prev_br
                if not ok_g then error(res_g) end
                return res_g
            end
            return orig_g5_ins(this_g5, st_g5, script_g5)
        end
    end)
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
    if os.getenv("KR_MP_AUTO_COOP_FAST") == "1" then
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

            if hooks:is_sync_active() then
                canonicalize_visible_coords(store)
            end

            local S_sys = require("systems")
            wrap_visual_systems(hooks, S_sys)
            hooks.wrap_local_ui(self_sim, "prepare_render")
            wrap_medical_kit(hooks, E)
            wrap_g5_reinforcements(hooks, E)
            wrap_sim_skip_local_systems(hooks, S_sys)
            wrap_main_script_system(hooks, S_sys, E)

            hooks.sim_exec_depth = hooks.sim_exec_depth + 1
            prng:enter_sim()
            local ok, err = pcall(orig_init, self_sim, store, system_names)
            prng:exit_sim()
            hooks.sim_exec_depth = hooks.sim_exec_depth - 1
            if not ok then error(err) end

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
