-- KR-MP GUI Action Interception Hooks
-- Converts local combat inputs (powers, rally points, reinforcement drag, tower actions,
-- map pings, clickable props, wave calls, hotkeys) into deterministic lockstep commands.
local commands = require("kr_mp.commands")

local M = {}

local function power_deny_toast(hooks, idx, owner, reason)
    if not hooks.overlay then return end
    if reason == "host_cataclysm" then
        hooks.overlay:show_toast("天灾法术仅由 1P 房主操控！", 2.2)
    elseif reason == "hero_ult" then
        hooks.overlay:show_toast(string.format("那是 %dP 队友的英雄大招！", owner or 0), 2.2)
    elseif reason == "cooldown" then
        local info = hooks.coop and hooks.coop:get_power_slot_info(idx)
        local msg = (info and info.kind == "reinforcement") and "你的援军正在冷却中！" or "该法术正在冷却中！"
        hooks.overlay:show_toast(msg, 2.0)
    end
end

local function clamp_line_search(cx, cy, wx, wy, steps, check_fn)
    if check_fn(wx, wy) then
        return wx, wy
    end
    for it = 1, steps - 1 do
        local lx = commands.quantize((cx * it + wx * (steps - it)) / steps)
        local ly = commands.quantize((cy * it + wy * (steps - it)) / steps)
        if check_fn(lx, ly) then
            return lx, ly
        end
    end
    return nil, nil
end

local function install_power_and_hero_hooks(hooks, game_gui)
    local power_classes = { Power1Button, Power2Button, Power3Button }
    for idx = 1, 3 do
        local cls = power_classes[idx]
        if cls then
            hooks.wrap_once(cls, "fire", "gui_act", function(orig_fire)
                commands.orig_power_fire[idx] = orig_fire
                return function(self_btn, wx, wy)
                    if commands.executing or not hooks:is_sync_active() then
                        return orig_fire(self_btn, wx, wy)
                    end
                    if hooks.replay and hooks.replay:is_replaying() then return end
                    if hooks:is_mp_active() then
                        local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, idx)
                        if not ok_p then
                            game_gui:set_mode()
                            power_deny_toast(hooks, idx, owner, reason)
                            return
                        end
                    end
                    game_gui:set_mode()
                    hooks:submit_command({ op = "POWER_FIRE", idx = idx, wx = wx, wy = wy })
                end
            end)

            hooks.wrap_once(cls, "on_click", "gui_act", function(orig_pclick)
                return function(self_btn, button, x, y)
                    if hooks:is_mp_active() then
                        local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, idx)
                        if not ok_p then
                            power_deny_toast(hooks, idx, owner, reason)
                            return
                        end
                    end
                    return orig_pclick(self_btn, button, x, y)
                end
            end)
        end
    end

    if HeroUltimateButton then
        hooks.wrap_once(HeroUltimateButton, "fire", "gui_act", function(orig_hu_fire)
            commands.orig_hero_ult_fire = orig_hu_fire
            return function(self_btn, wx, wy)
                if commands.executing or not hooks:is_sync_active() then
                    return orig_hu_fire(self_btn, wx, wy)
                end
                if hooks.replay and hooks.replay:is_replaying() then return end
                local slot = self_btn.hero_slot or "a"
                if hooks:is_mp_active() then
                    local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, slot)
                    if not ok_p then
                        game_gui:set_mode()
                        power_deny_toast(hooks, slot, owner, reason)
                        return
                    end
                end
                game_gui:set_mode()
                hooks:submit_command({ op = "POWER_FIRE", idx = slot, wx = wx, wy = wy })
            end
        end)

        hooks.wrap_once(HeroUltimateButton, "on_click", "gui_act", function(orig_hu_click)
            return function(self_btn, button, x, y)
                local slot = self_btn.hero_slot or "a"
                if hooks:is_mp_active() then
                    local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, slot)
                    if not ok_p then
                        power_deny_toast(hooks, slot, owner, reason)
                        return
                    end
                end
                return orig_hu_click(self_btn, button, x, y)
            end
        end)
    end

    if HeroPortrait then
        hooks.wrap_once(HeroPortrait, "on_click", "gui_act", function(orig_hp_click)
            return function(self_hp, button, x, y)
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
        end)
    end
end

local function install_rally_hooks(hooks, game_gui, deps)
    local S, V, U, P, GR = deps.S, deps.V, deps.U, deps.P, deps.GR

    hooks.wrap_once(PickView, "rally_tower", "gui_act", function(orig_rally_tower)
        return function(self_pv, x, y)
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
            local fx, fy = clamp_line_search(e.pos.x, e.pos.y, wx, wy, 200, function(tx, ty)
                return U.is_inside_ellipse({ x = tx, y = ty }, rc, b.rally_range)
                    and (b.rally_anywhere or (P:valid_node_nearby(tx, ty, nil, NF_RALLY) and GR:cell_is_only(tx, ty, b.rally_terrains)))
            end)

            if fx and fy then
                S:queue("GUIPlaceRallyPoint")
                hooks:submit_command({ op = "TW_RALLY", id = e.id, wx = fx, wy = fy })
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
    end)

    local function make_nav_rally_check(e)
        return function(tx, ty)
            return (not e.nav_rally.requires_node_nearby or P:valid_node_nearby(tx, ty, nil, NF_RALLY))
                and GR:cell_is_only(tx, ty, e.nav_grid.valid_terrains_dest)
                and ((e.teleport and V.dist(tx, ty, e.pos.x, e.pos.y) > e.teleport.min_distance)
                    or e.nav_grid.ignore_waypoints
                    or GR:find_waypoints(e.pos, e.nav_rally.pos, { x = tx, y = ty }, e.nav_grid.valid_terrains, true))
        end
    end

    hooks.wrap_once(PickView, "rally_hero", "gui_act", function(orig_rally_hero)
        return function(self_pv, x, y)
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

            local steps = 200
            local lidx = game_gui.game and game_gui.game.store and game_gui.game.store.level_idx
            if lidx == 71 or lidx == 72 or (GS and GS.jnum4 and GS.last_level4 and lidx and lidx > GS.jnum4 and lidx <= GS.last_level4) then
                steps = 10
            end
            local fx, fy = clamp_line_search(e.pos.x, e.pos.y, wx, wy, steps, make_nav_rally_check(e))
            if fx and fy then
                hooks:submit_command({ op = "HERO_RALLY", id = e.id, wx = fx, wy = fy })
                game_gui:show_point_confirm(x, y)
                game_gui:deselect_entity()
                return true
            end
            game_gui:show_invalid_point_cross(x, y)
            return false
        end
    end)

    hooks.wrap_once(PickView, "rally_reinforcement", "gui_act", function(orig_rally_reinf)
        return function(self_pv, x, y)
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

            local fx, fy = clamp_line_search(e.pos.x, e.pos.y, wx, wy, 200, make_nav_rally_check(e))
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
    end)
end

local function can_place_free_holder_sync(deps, store, wx, wy)
    local E_gui, GR, P, bit = deps.E, deps.GR, deps.P, deps.bit
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

local function install_pick_and_tower_hooks(hooks, game_gui, deps)
    local S = deps.S

    hooks.wrap_once(PickView, "on_down", "gui_act", function(orig_pv_down)
        return function(self_pv, button, x, y)
            if not hooks:is_sync_active() then
                return orig_pv_down(self_pv, button, x, y)
            end
            if hooks.replay and hooks.replay:is_replaying() then return true end

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
                if can_place_free_holder_sync(deps, st, wx, wy) then
                    hooks:submit_command({ op = "TW_FREE_HOLDER", wx = wx, wy = wy })
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
                    hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "point_confirm", wx = wx, wy = wy })
                    game_gui:deselect_entity()
                    return true
                end
            elseif button == 1 and (game_gui.mode == GUI_MODE_IDLE or game_gui.mode == GUI_MODE_SWAP_TOWER) then
                -- Handle IDLE & SWAP_TOWER clicks directly so orig_pv_down NEVER mutates e.ui.clicked = true locally
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
                    local has_proxies = (type(e.ui.click_proxies) == "table" and #e.ui.click_proxies > 0)
                    local needs_click_sync = (not e.tower and not e.hero and not e.soldier and not e.enemy)
                        or (e.clicks_to_destroy ~= nil)
                        or (e.tap_decal ~= nil)
                        or (e.click_play ~= nil)
                        or has_proxies
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
    end)

    hooks.wrap_once(TowerMenuButton, "on_click", "gui_act", function(orig_tmb_click)
        return function(self_btn)
            if not hooks:is_sync_active() then
                return orig_tmb_click(self_btn)
            end
            if hooks.replay and hooks.replay:is_replaying() then return end
            if not self_btn.parent or self_btn.parent.tweening or self_btn.click_disabled then return end

            local item, entity = self_btn.item, self_btn.entity
            if not item or not entity then
                return orig_tmb_click(self_btn)
            end

            if hooks:is_mp_active() and not hooks.coop:can_control_tower(hooks.coop.local_pid, entity, item.action) then
                if hooks.overlay then
                    hooks.overlay:show_toast(string.format("这座塔归 %dP 队友所有（红蓝保护模式）！", entity._mp_owner or 0), 2.5)
                end
                game_gui:deselect_entity()
                return
            end

            if item.action == "tw_rally" or item.action == "tw_page" or item.action == "tw_add_holder" then
                return orig_tmb_click(self_btn)
            end

            self_btn:disable()
            local inhibit_sounds = false
            local new_mode

            if item.action == "tw_upgrade" or item.action == "tw_unblock" then
                hooks:submit_command({ op = "TW_UPGRADE", id = entity.id, arg = item.action_arg })
                game_gui:deselect_entity()
            elseif item.action == "tw_sell" then
                hooks:submit_command({ op = "TW_SELL", id = entity.id })
                game_gui:deselect_entity()
            elseif item.action == "upgrade_power" then
                local power = entity.powers and entity.powers[item.action_arg]
                local store = game_gui.game.store
                if power and power.level < power.max_level then
                    local cost = commands.get_tower_power_cost(entity, power, power.level + 1)
                    local avail = hooks:is_mp_active() and hooks.coop:get_local_display_gold() or store.player_gold
                    if avail >= cost then
                        hooks:submit_command({ op = "TW_POWER", id = entity.id, arg = item.action_arg })
                        game_gui:deselect_entity()
                    else
                        inhibit_sounds = true
                    end
                else
                    inhibit_sounds = true
                end
            elseif item.action == "tw_buy_soldier" then
                hooks:submit_command({ op = "TW_BUY_SOLDIER", id = entity.id, arg = item.action_arg })
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
                    hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "free", arg = item.action_arg })
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
                    hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "repair" })
                end
                self_btn.parent:hide()
            elseif item.action == "tw_point" then
                local e = game_gui.selected_entity
                if e and e.user_selection then
                    hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "point_start" })
                end
                game_gui:set_mode(GUI_MODE_SELECT_POINT)
                self_btn.parent:hide()
            elseif item.action == "tw_buy_attack" then
                local e = game_gui.selected_entity
                if e and e.user_selection then
                    if e.user_selection.ignore_point then
                        hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "buy_attack_instant", arg = item.action_arg })
                        game_gui:deselect_entity()
                    else
                        hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "buy_attack_start", arg = item.action_arg })
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
                    for _, sid in hooks.orig_pairs(item.sounds) do
                        S:queue(sid)
                    end
                end
            end
        end
    end)

    hooks.wrap_once(game_gui, "c_swap_tower", "gui_act", function(orig_swap)
        commands.orig_c_swap_tower = orig_swap
        return function(self_gui, e)
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
                hooks:submit_command({ op = "TW_SWAP", id1 = game_gui.swap_entity.id, id2 = e.id })
                game_gui:deselect_entity()
                game_gui.swap_entity = nil
                game_gui:set_mode(GUI_MODE_IDLE)
                game_gui:hide_ghost_hover()
            end
        end
    end)
end

local POW_HOTKEY_CHECKS = {
    { "pow_1", 1, "1" },
    { "pow_2", 2, "2" },
    { "pow_3", 3, "3" },
    { "pow_a", "a", "a" },
    { "pow_s", "s", "s" },
}

local function handle_mp_hotkey(hooks, self_gui, key, ks, ok_ss, ss_mod, match_sc)
    if key == "space" or (ks and key == ks.pause) then
        if hooks.lockstep then hooks.lockstep:request_toggle_pause() end
        return true
    end
    for i = 1, #POW_HOTKEY_CHECKS do
        local sc_name, slot_id, fallback_k = POW_HOTKEY_CHECKS[i][1], POW_HOTKEY_CHECKS[i][2], POW_HOTKEY_CHECKS[i][3]
        if match_sc(sc_name) or ((not ok_ss or not ss_mod or not ss_mod.matches) and key == fallback_k) then
            if slot_id == "a" or slot_id == "s" then return true end
            if slot_id == 3 then
                local ult_slot = hooks.coop.local_ult_slot
                if not ult_slot then return true end
                local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, ult_slot)
                if not ok_p then power_deny_toast(hooks, ult_slot, owner, reason); return true end
                if ult_slot == "a" and self_gui.power_a and not self_gui.power_a.hidden and not self_gui.power_a:is_disabled() then
                    self_gui.power_a:toggle_selection()
                    return true
                end
                break
            end
            local ok_p, owner, reason = hooks.coop:can_use_power(hooks.coop.local_pid, slot_id)
            if not ok_p then power_deny_toast(hooks, slot_id, owner, reason); return true end
            break
        end
    end
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
    return false
end

local function cycle_durax_clones(hooks, self_gui, ks)
    local st = self_gui.game and self_gui.game.store
    if not (st and st.entities) then return end
    local list = {}
    for _, ent in pairs(st.entities) do
        if ent and ent.template_name == "hero_durax_clone" and not ent._kr_mp_local
            and ent.ui and ent.ui.can_click and not (ent.health and ent.health.dead)
            and (not hooks:is_mp_active() or hooks.coop:can_control_hero(hooks.coop.local_pid, ent)) then
            list[#list + 1] = ent
        end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
    local sel_idx = nil
    for i = 1, #list do
        if list[i] == self_gui.selected_entity then sel_idx = i; break end
    end
    self_gui:deselect_entity()
    local next_idx = ((sel_idx or (ks and ks._last_durax_clone_idx) or 0) % #list) + 1
    if ks then ks._last_durax_clone_idx = next_idx end
    self_gui:select_entity(list[next_idx])
end

local function install_wave_and_hotkey_hooks(hooks, game_gui)
    if NextWaveButton then
        hooks.wrap_once(NextWaveButton, "on_click", "gui_act", function(orig_nw)
            return function(self_nw, button, x, y)
                if not hooks:is_sync_active() then return orig_nw(self_nw, button, x, y) end
                if hooks.replay and hooks.replay:is_replaying() then return end
                hooks:submit_command({ op = "SEND_WAVE" })
            end
        end)
    end

    if WaveFlag then
        hooks.wrap_once(WaveFlag, "on_click", "gui_act", function(orig_wf)
            return function(self_wf)
                if not hooks:is_sync_active() then return orig_wf(self_wf) end
                if hooks.replay and hooks.replay:is_replaying() then return end
                hooks:submit_command({ op = "SEND_WAVE" })
            end
        end)
    end

    hooks.wrap_once(game_gui, "keypressed", "gui_act", function(orig_gui_key)
        return function(self_gui, key, isrepeat)
            if not hooks:is_sync_active() then
                return orig_gui_key(self_gui, key, isrepeat)
            end
            if hooks.replay and hooks.replay:is_replaying() then
                if key == "escape" then return orig_gui_key(self_gui, key, isrepeat) end
                return false
            end
            local ks = self_gui.key_shortcuts
            local ok_ss, ss_mod = pcall(require, "shortcut_settings")
            local function match_sc(action_name)
                return ok_ss and ss_mod and ss_mod.matches and ks and ss_mod.matches(ks, action_name, key) == true
            end
            if hooks:is_mp_active() and handle_mp_hotkey(hooks, self_gui, key, ks, ok_ss, ss_mod, match_sc) then
                return true
            end
            if match_sc("durax_clone") then
                cycle_durax_clones(hooks, self_gui, ks)
                return true
            end
            local wave_key = (ks and ks.wave) or KEYPRESS_NEXTWAVE or "w"
            if (key == KEYPRESS_RETURN or (not DEBUG and key == wave_key) or match_sc("wave"))
                and self_gui.next_wave_button and not self_gui.next_wave_button:is_disabled() then
                hooks:submit_command({ op = "SEND_WAVE" })
                return true
            end
            return orig_gui_key(self_gui, key, isrepeat)
        end
    end)
end

function M.install(hooks, game_gui)
    local deps = {
        S = require("sound_db"),
        V = require("hump.vector-light"),
        U = require("utils"),
        P = require("path_db"),
        GR = require("grid_db"),
        E = require("entity_db"),
        bit = require("bit"),
    }
    install_power_and_hero_hooks(hooks, game_gui)
    install_rally_hooks(hooks, game_gui, deps)
    install_pick_and_tower_hooks(hooks, game_gui, deps)
    install_wave_and_hotkey_hooks(hooks, game_gui)
end

return M
