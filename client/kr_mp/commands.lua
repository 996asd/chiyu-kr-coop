-- Canonical Lockstep Command Queue & Table-Driven Executor
-- Shared across M0 (record/replay) and M1/M2 (LAN & Online Co-op).
local signal = require("hump.signal")
local GR = require("grid_db")
local E = require("entity_db")

local commands = {
    pending_by_tick = {}, -- [tick] = { cmd1, cmd2, ... }
    seq = 0,
    executing = false,
    orig_power_fire = {}, -- [1|2|3] = orig function
    orig_hero_ult_fire = nil, -- HeroUltimateButton.fire (FL 8.2.0 "a"/"s" slots)
    orig_c_swap_tower = nil,
    coop = nil,
    lockstep = nil,
}

function commands:set_mp(coop, lockstep)
    self.coop = coop
    self.lockstep = lockstep
end

local function q2(v)
    if not v then return 0 end
    return math.floor(v * 100 + 0.5) / 100
end

function commands.quantize(v)
    return q2(v)
end

-- Single source of truth for tower power upgrade cost (shared by hooks_gui_actions and TW_POWER).
function commands.get_tower_power_cost(entity, power, next_lvl)
    local ttype = entity and entity.tower and entity.tower.type
    if (ttype == "barracks_stage_19" or ttype == "update_1_hunter_outpost") and type(power.price) == "table" then
        return power.price[math.min(next_lvl, power.max_level)] or 0
    end
    return (next_lvl == 1) and power.price_base or power.price_inc
end

function commands:reset()
    self.pending_by_tick = {}
    self.seq = 0
    self.executing = false
end

function commands:enqueue(target_tick, cmd)
    self.seq = self.seq + 1
    cmd.tick = target_tick
    cmd.seq = self.seq
    if cmd.wx then cmd.wx = q2(cmd.wx) end
    if cmd.wy then cmd.wy = q2(cmd.wy) end

    local bucket = self.pending_by_tick[target_tick]
    if not bucket then
        bucket = {}
        self.pending_by_tick[target_tick] = bucket
    end
    bucket[#bucket + 1] = cmd
    return cmd
end

function commands:load_schedule(cmd_list)
    self:reset()
    for _, c in ipairs(cmd_list or {}) do
        local bucket = self.pending_by_tick[c.tick]
        if not bucket then
            bucket = {}
            self.pending_by_tick[c.tick] = bucket
        end
        bucket[#bucket + 1] = c
    end
end

function commands:flush_tick(tick, game_ref, boot_ref)
    local bucket = self.pending_by_tick[tick]
    if not bucket then
        return 0
    end
    self.pending_by_tick[tick] = nil

    local executed = 0
    self.executing = true
    for i = 1, #bucket do
        local cmd = bucket[i]
        local ok, err = pcall(self.execute, self, cmd, game_ref, boot_ref)
        if not ok then
            if boot_ref then
                boot_ref:log("CMD EXEC ERROR tick=%d op=%s err=%s", tick, tostring(cmd.op), tostring(err))
            end
        else
            executed = executed + 1
        end
    end
    self.executing = false
    return executed
end

local HANDLERS = {}

function HANDLERS.TW_UPGRADE(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.tower) then return end
    if ctx.mp_on then
        if not ctx.coop:can_control_tower(ctx.pid, e, "upgrade") then return end
        local price = ctx.coop:get_upgrade_price(e, cmd.arg)
        if not ctx.coop:can_afford(ctx.pid, price) then return end
        e.tower._mp_actor = ctx.pid
    end
    e.tower.upgrade_to = cmd.arg
    signal.emit("tower-built")
end

function HANDLERS.TW_SELL(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.tower) then return end
    if ctx.mp_on then
        if not ctx.coop:can_control_tower(ctx.pid, e, "sell") then return end
        e.tower._mp_actor = ctx.pid
    end
    e.tower.sell = true
end

function HANDLERS.TW_POWER(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    local power = e and e.powers and e.powers[cmd.arg]
    if not power then return end
    if ctx.mp_on and not ctx.coop:can_control_tower(ctx.pid, e, "power") then return end
    if power.level >= power.max_level then return end

    local next_lvl = power.level + 1
    local spent = commands.get_tower_power_cost(e, power, next_lvl)
    local ok_gold = ctx.mp_on and ctx.coop:can_afford(ctx.pid, spent) or (ctx.store.player_gold >= spent)
    if not ok_gold then return end

    power.level = next_lvl
    power.changed = true
    if ctx.mp_on then
        ctx.coop:spend_gold(ctx.pid, spent)
        ctx.store.player_gold = ctx.coop:get_canonical_gold()
    else
        ctx.store.player_gold = ctx.store.player_gold - spent
    end
    e.tower.spent = (e.tower.spent or 0) + spent
    if power.show_rally then
        e.tower.show_rally = true
    end
    signal.emit("tower-power-upgraded", e, power)
end

function HANDLERS.TW_RALLY(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.barrack) then return end
    if ctx.mp_on and not ctx.coop:can_control_tower(ctx.pid, e, "rally") then return end
    e.barrack.rally_pos = { x = cmd.wx, y = cmd.wy }
    e.barrack.rally_new = true
end

function HANDLERS.TW_BUY_SOLDIER(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.barrack) then return end
    if ctx.mp_on and not ctx.coop:can_control_tower(ctx.pid, e, "buy_soldier") then return end
    e._mp_actor = ctx.pid
    e.barrack.unit_bought = cmd.arg
end

function HANDLERS.TW_CHANGE_MODE(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.tower) then return end
    if ctx.mp_on and not ctx.coop:can_control_tower(ctx.pid, e, "mode") then return end
    e.change_mode = true
end

function HANDLERS.TW_SWAP(ctx, cmd)
    local e1 = ctx.store.entities[cmd.id1]
    local e2 = ctx.store.entities[cmd.id2]
    if not (e1 and e2 and e1 ~= e2) then return end
    if ctx.mp_on and (not ctx.coop:can_control_tower(ctx.pid, e1, "swap")
        or not ctx.coop:can_control_tower(ctx.pid, e2, "swap")) then
        return
    end
    local controller = E:create_entity("controller_tower_swap")
    controller.tower_1 = e1
    controller.tower_2 = e2
    ctx.game.simulation:insert_entity(controller)
end

function HANDLERS.TW_USER_SEL(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.user_selection) then return end
    if ctx.mp_on and not ctx.coop:can_control_tower(ctx.pid, e, "user_sel") then return end
    e._mp_actor = ctx.pid
    local us = e.user_selection
    local phase = cmd.phase
    if phase == "free" then
        us.in_progress = true; us.arg = cmd.arg; us.new_pos = nil
    elseif phase == "repair" then
        us.in_progress = true
    elseif phase == "point_start" then
        us.in_progress = true; us.new_pos = nil
    elseif phase == "buy_attack_instant" then
        us.arg = cmd.arg
    elseif phase == "buy_attack_start" then
        us.in_progress = true; us.arg = cmd.arg; us.new_pos = nil
    elseif phase == "point_confirm" then
        us.in_progress = false; us.new_pos = { x = cmd.wx, y = cmd.wy }
    elseif phase == "cancel" then
        us.in_progress = false; us.new_pos = nil
    elseif phase == "custom" then
        us.in_progress = true; us.arg = cmd.arg
    end
end

function HANDLERS.TW_FREE_HOLDER(ctx, cmd)
    local store = ctx.store
    local terrain_style = store.terrain_style or 1
    local max_holder_id = 0
    local function inspect_holder(ent)
        if ent and ent.tower and not ent._kr_mp_local then
            terrain_style = ent.tower.terrain_style or terrain_style
            max_holder_id = math.max(max_holder_id, tonumber(ent.tower.holder_id) or 0)
        end
    end
    for _, ent in pairs(store.entities) do inspect_holder(ent) end
    for _, ent in ipairs(store.pending_inserts or {}) do inspect_holder(ent) end
    local kr6_holder = terrain_style >= 46 and terrain_style <= 64 and terrain_style ~= 50
    local holder = E:create_entity(kr6_holder and "tower_holder_kr6" or "tower_holder")
    if not holder then return end
    holder.pos = { x = cmd.wx, y = cmd.wy }
    holder.tower.holder_id = tostring(max_holder_id + 1)
    holder.tower.terrain_style = terrain_style
    holder.tower.default_rally_pos = { x = cmd.wx, y = cmd.wy + 50 }
    local base_sprite = holder.render and holder.render.sprites and holder.render.sprites[1]
    if base_sprite and type(base_sprite.name) == "string" and string.find(base_sprite.name, "%%") then
        base_sprite.name = string.format(base_sprite.name, terrain_style)
    end
    ctx.game.simulation:insert_entity(holder)
end

function HANDLERS.HERO_RALLY(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if not (e and e.nav_rally and e.nav_grid) then return end
    if ctx.mp_on and not ctx.coop:can_control_hero(ctx.pid, e) then return end
    if not e.nav_grid.ignore_waypoints then
        e.nav_grid.waypoints = GR:find_waypoints(
            e.pos, e.nav_rally.pos, { x = cmd.wx, y = cmd.wy }, e.nav_grid.valid_terrains, true
        )
    end
    e.nav_rally.new = true
    e.nav_rally.pos = { x = cmd.wx, y = cmd.wy }
    e.nav_rally.center = { x = cmd.wx, y = cmd.wy }
end

function HANDLERS.REINF_RALLY(ctx, cmd)
    local store = ctx.store
    local targets = {}
    local sid = cmd.sid
    local e0 = cmd.id and store.entities[cmd.id]
    if not sid and e0 and e0.reinforcement and e0.reinforcement.squad_id then
        sid = e0.reinforcement.squad_id
    end
    if sid then
        for _, ee in pairs(store.entities) do
            if ee and not ee._kr_mp_local and ee.reinforcement and ee.reinforcement.squad_id == sid
                and ee.nav_rally and ee.nav_grid and not (ee.health and ee.health.dead) then
                targets[#targets + 1] = ee
            end
        end
        table.sort(targets, function(a, b) return (a.id or 0) < (b.id or 0) end)
    elseif e0 and e0.reinforcement and e0.nav_rally and e0.nav_grid and not (e0.health and e0.health.dead) then
        targets[1] = e0
    end
    for i = 1, #targets do
        local ee = targets[i]
        if not ee.nav_grid.ignore_waypoints then
            local wp = GR:find_waypoints(
                ee.pos, ee.nav_rally.pos, { x = cmd.wx, y = cmd.wy }, ee.nav_grid.valid_terrains, true
            )
            if not wp and ee.nav_rally.center then
                wp = GR:find_waypoints(
                    ee.pos, ee.nav_rally.center, { x = cmd.wx, y = cmd.wy }, ee.nav_grid.valid_terrains, true
                )
            end
            ee.nav_grid.waypoints = wp or {}
        end
        local ox = (ee.nav_rally.pos and ee.nav_rally.center) and (ee.nav_rally.pos.x - ee.nav_rally.center.x) or 0
        local oy = (ee.nav_rally.pos and ee.nav_rally.center) and (ee.nav_rally.pos.y - ee.nav_rally.center.y) or 0
        ee.nav_rally.new = true
        ee.nav_rally.center = { x = cmd.wx, y = cmd.wy }
        ee.nav_rally.pos = { x = cmd.wx + ox, y = cmd.wy + oy }
    end
end

function HANDLERS.POWER_FIRE(ctx, cmd)
    local gui = ctx.gui
    if not gui then return end
    if ctx.mp_on and not ctx.coop:can_use_power(ctx.pid, cmd.idx) then return end
    local btn = gui["power_" .. tostring(cmd.idx)]
    local orig_fn = (cmd.idx == "a" or cmd.idx == "s")
        and ctx.cmds.orig_hero_ult_fire
        or ctx.cmds.orig_power_fire[cmd.idx]
    if not (btn and orig_fn) then return end

    local slot_info = ctx.mp_on and ctx.coop:get_power_slot_info(cmd.idx) or nil
    local is_indep_reinf = (slot_info and slot_info.kind == "reinforcement") or (not slot_info and cmd.idx == 2)

    -- Bind per-player reinforcement selection & branch deterministically for this actor
    local prev_actor, prev_g4, prev_g5
    if ctx.mp_on and is_indep_reinf then
        prev_actor = ctx.coop._active_power_actor
        prev_g4 = ctx.coop._active_g4_branch
        prev_g5 = ctx.coop._active_g5_branch
        ctx.coop._active_power_actor = ctx.pid
        local spec = ctx.coop:get_player_reinf_spec(ctx.pid)
        ctx.coop._active_g4_branch = (spec and spec.gen == 4 and spec.branch) or nil
        ctx.coop._active_g5_branch = (spec and spec.gen == 5 and spec.branch) or nil
    end

    -- Deterministic squad_id tagging so G1-G4 reinforcements spawned in one cast move together
    local prev_reinf_sid = ctx.store._kr_mp_active_reinf_squad_id
    local prev_pending_n = type(ctx.store.pending_inserts) == "table" and #ctx.store.pending_inserts or 0
    local reinf_sid = nil
    if is_indep_reinf then
        ctx.store._kr_mp_reinf_squad_seq = (ctx.store._kr_mp_reinf_squad_seq or 0) + 1
        reinf_sid = 90000000 + ctx.store._kr_mp_reinf_squad_seq
        ctx.store._kr_mp_active_reinf_squad_id = reinf_sid
    end

    local fired_cd = nil
    local ok_p, err_p
    if ctx.mp_on and ctx.pid ~= ctx.coop.local_pid then
        -- Remote player fired power: never interrupt local targeting or local independent reinforcement cooldown
        local orig_set_mode = gui.set_mode
        local saved_btn_mode = btn.mode
        local saved_cd_time = btn.cooldown_time
        local saved_cd_start = btn.cooldown_view and btn.cooldown_view.start_ts
        local saved_cd_sy = btn.cooldown_view and btn.cooldown_view.scale and btn.cooldown_view.scale.y
        local saved_cd_hidden = btn.cooldown_view and btn.cooldown_view.hidden
        local saved_disabled = btn._disabled
        gui.set_mode = function() end
        ok_p, err_p = pcall(orig_fn, btn, cmd.wx, cmd.wy)
        gui.set_mode = orig_set_mode
        fired_cd = tonumber(btn.cooldown_time)
        if is_indep_reinf then
            local S_mod = require("sound_db")
            local orig_sq = S_mod and S_mod.queue
            if S_mod and orig_sq then S_mod.queue = function() end end
            if btn.set_mode then pcall(btn.set_mode, btn, saved_btn_mode) end
            if S_mod and orig_sq then S_mod.queue = orig_sq end
            btn.cooldown_time = saved_cd_time
            if btn.cooldown_view then
                btn.cooldown_view.start_ts = saved_cd_start
                if saved_cd_hidden ~= nil then btn.cooldown_view.hidden = saved_cd_hidden end
                if btn.cooldown_view.scale and saved_cd_sy ~= nil then btn.cooldown_view.scale.y = saved_cd_sy end
            end
            if saved_disabled ~= nil then btn._disabled = saved_disabled end
        end
    else
        ok_p, err_p = pcall(orig_fn, btn, cmd.wx, cmd.wy)
        fired_cd = tonumber(btn.cooldown_time)
    end

    if is_indep_reinf then
        ctx.store._kr_mp_active_reinf_squad_id = prev_reinf_sid
        local pend = ctx.store.pending_inserts
        if reinf_sid and type(pend) == "table" then
            for pi = prev_pending_n + 1, #pend do
                local pe = pend[pi]
                if pe and not pe._kr_mp_local and pe.reinforcement and not pe.reinforcement.squad_id then
                    pe.reinforcement.squad_id = reinf_sid
                end
            end
        end
    end
    if ctx.mp_on and is_indep_reinf then
        ctx.coop._active_power_actor = prev_actor
        ctx.coop._active_g4_branch = prev_g4
        ctx.coop._active_g5_branch = prev_g5
    end
    if not ok_p then error(err_p) end
    if ctx.mp_on then
        ctx.coop:on_power_fired(ctx.pid, cmd.idx, fired_cd or btn)
    end
end

function HANDLERS.SEND_WAVE(ctx)
    ctx.store.send_next_wave = true
end

function HANDLERS.CLICK_ENTITY(ctx, cmd)
    local e = ctx.store.entities[cmd.id]
    if e and e.ui and e.ui.can_click then
        e.ui.clicked = true
    end
end

function HANDLERS.SEND_GOLD(ctx, cmd)
    if ctx.mp_on then
        ctx.coop:transfer_gold(ctx.pid, cmd.amount or 50)
        ctx.store.player_gold = ctx.coop:get_canonical_gold()
    end
end

function HANDLERS.MAP_PING(ctx, cmd)
    if ctx.mp_on and cmd.wx and cmd.wy then
        ctx.coop:add_map_ping(ctx.pid, cmd.wx, cmd.wy)
    end
end

function HANDLERS.SYNC_PAUSE(ctx)
    if ctx.cmds.lockstep and ctx.cmds.lockstep:is_active() then
        ctx.cmds.lockstep:on_sync_pause_exec(ctx.pid)
    end
end

function HANDLERS.SYNC_DELAY(ctx, cmd)
    if ctx.cmds.lockstep and ctx.cmds.lockstep:is_active() then
        ctx.cmds.lockstep:on_sync_delay_exec(cmd.delay, ctx.pid)
    end
end

function commands:execute(cmd, game_ref, boot_ref)
    local store = game_ref and game_ref.store
    if not store then return end
    local handler = HANDLERS[cmd.op]
    if not handler then return end

    local coop = self.coop
    handler({
        cmds = self,
        game = game_ref,
        store = store,
        gui = game_ref.game_gui,
        boot = boot_ref,
        coop = coop,
        mp_on = coop ~= nil and coop:is_active(),
        pid = cmd.player or 1,
    }, cmd)
end

return commands
