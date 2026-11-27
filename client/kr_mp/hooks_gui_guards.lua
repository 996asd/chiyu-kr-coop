-- KR-MP GUI Simulation-Leak & Safety Guards
-- Prevents FL 8.2.0 UI popups, selection/hover helpers, PauseView, and DragEntityView
-- from mutating simulation state, consuming battle PRNG, or leaving stuck visual artifacts.
local commands = require("kr_mp.commands")
local prng = require("kr_mp.prng")
local stage_flow = require("kr_mp.stage_flow")

local M = {}

local ignored_td_eid = setmetatable({}, { __mode = "k" })

local function install_sim_field_guards(hooks, game_gui)
    if NotificationView then
        hooks.wrap_once(NotificationView, "show", "gui_guard", function(orig_noti_show)
            return function(self_nv, id, no_transition, force_show)
                if hooks:is_mp_active() or (hooks.replay and (hooks.replay:is_replaying() or hooks.replay.auto_verify)) then
                    return
                end
                return orig_noti_show(self_nv, id, no_transition, force_show)
            end
        end)
    end

    -- Preserve e.trigger_deselect across select_entity / PickView:update (prevents ray-tower lock DESYNC)
    hooks.wrap_once(game_gui, "select_entity", "td_sel", function(orig_sel_ent)
        return function(self_gui, e, ...)
            if not hooks:is_sync_active() then
                return orig_sel_ent(self_gui, e, ...)
            end
            local saved_td = e and e.trigger_deselect
            if e and e ~= self_gui.selected_entity then
                ignored_td_eid[self_gui] = saved_td and e.id or nil
            end
            local ok_s, r1, r2 = pcall(orig_sel_ent, self_gui, e, ...)
            if e then e.trigger_deselect = saved_td end
            if not ok_s then error(r1) end
            return r1, r2
        end
    end)

    hooks.wrap_once(PickView, "update", "td_upd", function(orig_pv_upd)
        return function(self_pv, dt)
            if not hooks:is_sync_active() then
                return orig_pv_upd(self_pv, dt)
            end
            local e = game_gui.selected_entity
            -- Auto-close stale TowerMenu/selection immediately when a tower/holder is upgraded, unblocked, sold, or removed
            if e and type(e.id) == "number" and e.id < hooks.LOCAL_ID_BASE then
                local st = game_gui.game and game_gui.game.store
                if st and st.entities and st.entities[e.id] ~= e then
                    game_gui:deselect_all()
                    e = game_gui.selected_entity
                end
            end
            local saved_td = e and e.trigger_deselect
            if e and not saved_td and ignored_td_eid[game_gui] == e.id then
                ignored_td_eid[game_gui] = nil
            end
            if e ~= nil and saved_td == true and ignored_td_eid[game_gui] == e.id then
                e.trigger_deselect = nil
            end
            local ok_u, err_u = pcall(orig_pv_upd, self_pv, dt)
            if e then e.trigger_deselect = saved_td end
            if not ok_u then error(err_u) end
        end
    end)

    -- Preserve entity.ui.hover_active & entity.ui.args across TowerMenuButton:on_enter/on_exit
    -- Prevents local mouse hover on Arcane Wizard (empowerment), Crossbow Fort (eagle), and KR6 aura towers
    -- from spawning simulation preview decals inside sim:do_tick on only one peer (causes immediate DESYNC!).
    if TowerMenuButton then
        for _, mname in ipairs({ "on_enter", "on_exit" }) do
            hooks.wrap_once(TowerMenuButton, mname, "hover_iso", function(orig_fn)
                return function(self_btn, ...)
                    if not hooks:is_sync_active() then
                        return orig_fn(self_btn, ...)
                    end
                    local ent = self_btn and self_btn.entity
                    local ui = ent and ent.ui
                    local saved_ha = ui and ui.hover_active
                    local saved_args = ui and ui.args
                    local ok_h, r1, r2 = pcall(orig_fn, self_btn, ...)
                    if ui then
                        ui.hover_active = saved_ha
                        ui.args = saved_args
                    end
                    if not ok_h then error(r1) end
                    return r1, r2
                end
            end)
        end
    end

    -- Preserve entity.user_selection.menu_shown across TowerMenu:show / hide
    if TowerMenu then
        hooks.wrap_once(TowerMenu, "show", "menu_shown", function(orig_tm_show)
            return function(self_tm, ...)
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
        end)

        hooks.wrap_once(TowerMenu, "hide", "menu_shown", function(orig_tm_hide)
            return function(self_tm, ...)
                if not hooks:is_sync_active() then
                    return orig_tm_hide(self_tm, ...)
                end
                local e = self_tm.entity or game_gui.selected_entity
                local saved_ms = e and e.user_selection and e.user_selection.menu_shown
                local ok_m, r1 = pcall(orig_tm_hide, self_tm, ...)
                if e and e.user_selection then
                    e.user_selection.menu_shown = saved_ms
                end
                if e and e.ui then
                    e.ui.hover_active = nil
                    e.ui.args = nil
                end
                if not ok_m then error(r1) end
                return r1
            end
        end)
    end

    -- Route user_selection cancellation in deselect_all through TW_USER_SEL(phase="cancel")
    hooks.wrap_once(game_gui, "deselect_all", "desel_cancel", function(orig_desel_all)
        return function(self_gui, ...)
            if not hooks:is_sync_active() or commands.executing then
                return orig_desel_all(self_gui, ...)
            end
            local e = self_gui.selected_entity
            local st = self_gui.game and self_gui.game.store
            local still_live = e and type(e.id) == "number" and st and st.entities and st.entities[e.id] == e
            local need_cancel = (still_live and e.user_selection ~= nil and e.user_selection.in_progress == true)
            local saved_inp = need_cancel and e.user_selection.in_progress or nil
            local saved_pos = need_cancel and e.user_selection.new_pos or nil
            local ok_d, r1 = pcall(orig_desel_all, self_gui, ...)
            if need_cancel and e and e.user_selection then
                e.user_selection.in_progress = saved_inp
                e.user_selection.new_pos = saved_pos
                hooks:submit_command({ op = "TW_USER_SEL", id = e.id, phase = "cancel" })
            end
            if not ok_d then error(r1) end
            return r1
        end
    end)
end

local function install_local_ui_isolation(hooks, game_gui)
    hooks.wrap_local_ui(game_gui, "show_clickable_hover")
    hooks.wrap_local_ui(game_gui, "show_ghost_hover")
    hooks.wrap_local_ui(game_gui, "select_entity")
    hooks.wrap_local_ui(game_gui, "block_random_power")
    hooks.wrap_local_ui(WaveFlag, "on_enter")
    hooks.wrap_local_ui(TowerMenuButton, "on_enter")
    hooks.wrap_local_ui(TowerMenuButton, "on_exit")
    hooks.wrap_local_ui(InfoBar, "show")
    hooks.wrap_local_ui(InfoBar, "update_stats")
    hooks.wrap_local_ui(TowerTooltip, "show")
    hooks.wrap_local_ui(TowerMenuTooltip, "show")
    hooks.wrap_local_ui(TowerMenu, "show")
end

local function install_coop_menu_guards(hooks, game_gui)
    if PauseView then
        hooks.wrap_once(PauseView, "show", "coop_pause", function(orig_pv_show)
            return function(self_pv, ...)
                local st = game_gui.game and game_gui.game.store
                local mp_on = hooks:is_mp_active()
                local saved_paused = st and st.paused
                local ok_p, r1 = pcall(orig_pv_show, self_pv, ...)
                if mp_on and st then st.paused = saved_paused end
                if not ok_p then error(r1) end
                return r1
            end
        end)

        hooks.wrap_once(PauseView, "hide", "coop_pause", function(orig_pv_hide)
            return function(self_pv, ...)
                local st = game_gui.game and game_gui.game.store
                local mp_on = hooks:is_mp_active()
                local ok_p, r1 = pcall(orig_pv_hide, self_pv, ...)
                if mp_on and st and hooks.lockstep and hooks.lockstep:is_active() then
                    st.paused = not (hooks.lockstep:is_running() or hooks.lockstep:is_catching_up())
                end
                if not ok_p then error(r1) end
                return r1
            end
        end)
    end

    if VictoryView then
        hooks.wrap_once(VictoryView, "show", "coop_victory", function(orig_vv_show)
            return function(self_vv, ...)
                prng:enter_visual()
                local ok_v, r1 = pcall(orig_vv_show, self_vv, ...)
                prng:exit_visual()
                if hooks:is_mp_active() then
                    stage_flow:on_victory_view_shown()
                end
                if not ok_v then error(r1) end
                return r1
            end
        end)
    end

    if DefeatView then
        hooks.wrap_once(DefeatView, "show", "coop_defeat", function(orig_dv_show)
            return function(self_dv, ...)
                prng:enter_visual()
                local ok_d, r1 = pcall(orig_dv_show, self_dv, ...)
                prng:exit_visual()
                if hooks:is_mp_active() then
                    stage_flow:on_defeat_view_shown()
                end
                if not ok_d then error(r1) end
                return r1
            end
        end)
    end

    hooks.wrap_once(game_gui, "restart_game", "coop_menu", function(orig_restart)
        return function(self_gui, ...)
            if hooks:is_mp_active() then
                local st = self_gui and self_gui.game and self_gui.game.store
                if st and st.game_outcome ~= nil then
                    stage_flow:request_restart()
                    return
                end
                if hooks.overlay then
                    hooks.overlay:show_toast("对局中无法单人重开，请点顶部「战桌」不断线返回备战换关或重开！", 3.5)
                end
                return
            end
            return orig_restart(self_gui, ...)
        end
    end)

    hooks.wrap_once(game_gui, "go_to_map", "coop_menu", function(orig_go_map)
        return function(self_gui, ...)
            if hooks:is_mp_active() and hooks.boot and hooks.boot.on_hud_action then
                local connected = hooks.boot.transport and hooks.boot.transport:is_connected()
                if connected and stage_flow:is_victory_auto_ready() then
                    if stage_flow:request_next() then
                        return
                    end
                end
                pcall(hooks.boot.on_hud_action, hooks.boot, connected and "mp_return_lobby" or "mp_leave")
                return
            end
            return orig_go_map(self_gui, ...)
        end
    end)
end

local function clear_drag_state(self_dv, game_gui)
    self_dv.is_pressing = false
    self_dv.selected_entity = nil
    self_dv.pressed_entity = nil
    if self_dv.disable_drag_line then
        self_dv:disable_drag_line()
    end
    if game_gui and game_gui.is_dragging and game_gui:is_dragging() then
        game_gui:set_mode(GUI_MODE_IDLE)
    end
end

local function install_drag_guards(hooks, game_gui)
    if DragEntityView then
        hooks.wrap_once(DragEntityView, "on_down", "drag_guard", function(orig_dv_down)
            return function(self_dv, button, x, y)
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
        end)

        hooks.wrap_once(DragEntityView, "on_up", "drag_guard", function(orig_dv_up)
            return function(self_dv, button, x, y)
                orig_dv_up(self_dv, button, x, y)
                if button == 1 then
                    self_dv.is_pressing = false
                    self_dv.selected_entity = nil
                    self_dv.pressed_entity = nil
                    if self_dv.disable_drag_line then self_dv:disable_drag_line() end
                end
            end
        end)

        hooks.wrap_once(DragEntityView, "update", "drag_guard", function(orig_dv_upd)
            return function(self_dv, dt)
                -- Cancel drag cleanly if pressed entity died/vanished mid-drag (prevents controller_path_direction 0/0 NaN)
                if self_dv.is_pressing and self_dv.pressed_entity then
                    local pe = self_dv.pressed_entity
                    local st = game_gui.game and game_gui.game.store
                    local gone = (not st or not st.entities or not pe.id or st.entities[pe.id] ~= pe)
                        or (pe.health and pe.health.dead)
                    if gone then
                        clear_drag_state(self_dv, game_gui)
                        return
                    end
                end
                -- Auto-clean orphaned cyan drag line if mouse button 1 is no longer held (desktop)
                if not IS_ANDROID and love and love.mouse and love.mouse.isDown and not love.mouse.isDown(1) then
                    local stuck_line = self_dv.path_direction and self_dv.path_direction.selected_entity ~= nil
                    if self_dv.is_pressing or stuck_line then
                        clear_drag_state(self_dv, game_gui)
                        return
                    end
                end
                return orig_dv_upd(self_dv, dt)
            end
        end)
    end

    hooks.wrap_once(game_gui, "deselect_entity", "drag_cleanup", function(orig_desel)
        return function(self_gui, ...)
            local r = orig_desel(self_gui, ...)
            if self_gui.drag_view and self_gui.drag_view.disable_drag_line
                and (not self_gui.is_dragging or not self_gui:is_dragging()) then
                self_gui.drag_view:disable_drag_line()
            end
            return r
        end
    end)
end

function M.install(hooks, game_gui)
    install_sim_field_guards(hooks, game_gui)
    install_local_ui_isolation(hooks, game_gui)
    install_coop_menu_guards(hooks, game_gui)
    install_drag_guards(hooks, game_gui)
end

return M
