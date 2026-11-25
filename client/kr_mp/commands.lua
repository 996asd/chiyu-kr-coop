-- Canonical Lockstep Command Queue & Executor
-- Shared across M0 (record/replay) and M1/M2 (LAN & Online Co-op).
local signal = require("hump.signal")
local GR = require("grid_db")
local E = require("entity_db")

local commands = {
    pending_by_tick = {}, -- [tick] = { cmd1, cmd2, ... }
    seq = 0,
    executing = false,
    orig_power_fire = {}, -- [1|2|3] = orig function
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

function commands:execute(cmd, game_ref, boot_ref)
    local store = game_ref and game_ref.store
    local gui = game_ref and game_ref.game_gui
    if not store then return end

    local op = cmd.op
    local coop = self.coop
    local mp_on = coop and coop:is_active()
    local pid = cmd.player or 1

    if op == "TW_UPGRADE" then
        local e = store.entities[cmd.id]
        if e and e.tower then
            if mp_on then
                if not coop:can_control_tower(pid, e, "upgrade") then return end
                local price = coop:get_upgrade_price(e, cmd.arg)
                if not coop:can_afford(pid, price) then return end
                e.tower._mp_actor = pid
            end
            e.tower.upgrade_to = cmd.arg
            signal.emit("tower-built")
        end

    elseif op == "TW_SELL" then
        local e = store.entities[cmd.id]
        if e and e.tower then
            if mp_on then
                if not coop:can_control_tower(pid, e, "sell") then return end
                e.tower._mp_actor = pid
            end
            e.tower.sell = true
        end

    elseif op == "TW_POWER" then
        local e = store.entities[cmd.id]
        if e and e.powers and e.powers[cmd.arg] then
            if mp_on and not coop:can_control_tower(pid, e, "power") then return end
            local power = e.powers[cmd.arg]
            if power.level < power.max_level then
                local spent = (power.level == 0) and power.price_base or power.price_inc
                local ok_gold = mp_on and coop:can_afford(pid, spent) or (store.player_gold >= spent)
                if ok_gold then
                    power.level = power.level + 1
                    power.changed = true
                    if mp_on then
                        coop:spend_gold(pid, spent)
                        store.player_gold = coop:get_canonical_gold()
                    else
                        store.player_gold = store.player_gold - spent
                    end
                    e.tower.spent = (e.tower.spent or 0) + spent
                    if power.show_rally then
                        e.tower.show_rally = true
                    end
                    signal.emit("tower-power-upgraded", e, power)
                end
            end
        end

    elseif op == "TW_RALLY" then
        local e = store.entities[cmd.id]
        if e and e.barrack then
            if mp_on and not coop:can_control_tower(pid, e, "rally") then return end
            e.barrack.rally_pos = { x = cmd.wx, y = cmd.wy }
            e.barrack.rally_new = true
        end

    elseif op == "TW_BUY_SOLDIER" then
        local e = store.entities[cmd.id]
        if e and e.barrack then
            if mp_on and not coop:can_control_tower(pid, e, "buy_soldier") then return end
            e._mp_actor = pid
            e.barrack.unit_bought = cmd.arg
        end

    elseif op == "TW_CHANGE_MODE" then
        local e = store.entities[cmd.id]
        if e and e.tower then
            if mp_on and not coop:can_control_tower(pid, e, "mode") then return end
            e.change_mode = true
        end

    elseif op == "TW_SWAP" then
        local e1 = store.entities[cmd.id1]
        local e2 = store.entities[cmd.id2]
        if e1 and e2 and e1 ~= e2 then
            if mp_on and (not coop:can_control_tower(pid, e1, "swap") or not coop:can_control_tower(pid, e2, "swap")) then
                return
            end
            local controller = E:create_entity("controller_tower_swap")
            controller.tower_1 = e1
            controller.tower_2 = e2
            game_ref.simulation:insert_entity(controller)
        end

    elseif op == "TW_USER_SEL" then
        local e = store.entities[cmd.id]
        if e and e.user_selection then
            if mp_on and not coop:can_control_tower(pid, e, "user_sel") then return end
            e._mp_actor = pid
            local phase = cmd.phase
            if phase == "free" then
                e.user_selection.in_progress = true
                e.user_selection.arg = cmd.arg
                e.user_selection.new_pos = nil
            elseif phase == "repair" then
                e.user_selection.in_progress = true
            elseif phase == "point_start" then
                e.user_selection.in_progress = true
                e.user_selection.new_pos = nil
            elseif phase == "buy_attack_instant" then
                e.user_selection.arg = cmd.arg
            elseif phase == "buy_attack_start" then
                e.user_selection.in_progress = true
                e.user_selection.arg = cmd.arg
                e.user_selection.new_pos = nil
            elseif phase == "point_confirm" then
                e.user_selection.in_progress = false
                e.user_selection.new_pos = { x = cmd.wx, y = cmd.wy }
            end
        end

    elseif op == "HERO_RALLY" then
        local e = store.entities[cmd.id]
        if e and e.nav_rally and e.nav_grid then
            if mp_on and not coop:can_control_hero(pid, e) then return end
            if not e.nav_grid.ignore_waypoints then
                e.nav_grid.waypoints = GR:find_waypoints(
                    e.pos,
                    e.nav_rally.pos,
                    { x = cmd.wx, y = cmd.wy },
                    e.nav_grid.valid_terrains,
                    true
                )
            end
            e.nav_rally.new = true
            e.nav_rally.pos = { x = cmd.wx, y = cmd.wy }
            e.nav_rally.center = { x = cmd.wx, y = cmd.wy }
        end

    elseif op == "POWER_FIRE" then
        if gui then
            if mp_on and not coop:can_use_power(pid, cmd.idx) then return end
            local btn = gui["power_" .. tostring(cmd.idx)]
            local orig_fn = self.orig_power_fire[cmd.idx]
            if btn and orig_fn then
                if mp_on and pid ~= coop.local_pid then
                    -- Remote player fired power: never interrupt local player's targeting mode,
                    -- and for Power 2 (Reinforcements) keep local player's cooldown independent!
                    local orig_set_mode = gui.set_mode
                    local saved_btn_mode = btn.mode
                    local saved_cd_start = btn.cooldown_view and btn.cooldown_view.start_ts
                    local saved_cd_sy = btn.cooldown_view and btn.cooldown_view.scale and btn.cooldown_view.scale.y
                    gui.set_mode = function() end
                    local ok_p, err_p = pcall(orig_fn, btn, cmd.wx, cmd.wy)
                    gui.set_mode = orig_set_mode
                    if cmd.idx == 2 then
                        if btn.set_mode then pcall(btn.set_mode, btn, saved_btn_mode) end
                        if btn.cooldown_view then
                            btn.cooldown_view.start_ts = saved_cd_start
                            if btn.cooldown_view.scale and saved_cd_sy ~= nil then
                                btn.cooldown_view.scale.y = saved_cd_sy
                            end
                        end
                    end
                    if not ok_p then error(err_p) end
                else
                    orig_fn(btn, cmd.wx, cmd.wy)
                end
                if mp_on then
                    coop:on_power_fired(pid, cmd.idx, btn)
                end
            end
        end

    elseif op == "SEND_WAVE" then
        store.send_next_wave = true

    elseif op == "CLICK_ENTITY" then
        local e = store.entities[cmd.id]
        if e and e.ui and e.ui.can_click then
            e.ui.clicked = true
        end

    elseif op == "SEND_GOLD" then
        if mp_on then
            coop:transfer_gold(pid, cmd.amount or 50)
            store.player_gold = coop:get_canonical_gold()
        end

    elseif op == "MAP_PING" then
        if mp_on and cmd.wx and cmd.wy then
            coop:add_map_ping(pid, cmd.wx, cmd.wy)
        end

    elseif op == "SYNC_PAUSE" then
        if self.lockstep and self.lockstep:is_active() then
            self.lockstep:on_sync_pause_exec(pid)
        end
    end
end

return commands
