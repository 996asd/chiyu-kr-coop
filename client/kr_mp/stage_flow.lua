-- KR-MP Seamless Post-Victory Auto-Next-Stage & In-Place Restart Controller
-- Lets 1P & 2P chain directly into the next campaign stage (or restart after defeat/victory)
-- without bouncing back to the War Table lobby UI.
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")
local ui = require("kr_mp.ui_assets")

local AUTO_NEXT_DELAY = 6.0
local VICTORY_FALLBACK_SHOW = 3.5

local stage_flow = {
    boot = nil,
    lobby = nil,
    coop = nil,
    lockstep = nil,
    overlay = nil,

    active = false,
    outcome = nil, -- nil | "victory" | "defeat"
    outcome_ts = 0,
    cur_level_idx = nil,
    next_level_idx = nil,
    stars = 0,

    auto_enabled = true,
    auto_canceled = false,
    auto_paused_stats = false,
    countdown = 0,
    launching = false,
    launching_reason = nil,
    _guest_nudge_sent = false,

    buttons = {},
    _consumed_down = false,
    _ui_scale = 1,
    _last_panel = nil,
}

function stage_flow:init(boot, lobby, coop, lockstep, overlay)
    self.boot = boot
    self.lobby = lobby
    self.coop = coop
    self.lockstep = lockstep
    self.overlay = overlay
end

function stage_flow:reset()
    self.active = false
    self.outcome = nil
    self.outcome_ts = 0
    self.cur_level_idx = nil
    self.next_level_idx = nil
    self.stars = 0
    self.auto_enabled = true
    self.auto_canceled = false
    self.auto_paused_stats = false
    self.countdown = 0
    self.launching = false
    self.launching_reason = nil
    self._guest_nudge_sent = false
    self.buttons = {}
    self._consumed_down = false
    self._last_panel = nil
end

function stage_flow:is_victory_auto_ready()
    return self.outcome == "victory"
        and self.next_level_idx ~= nil
        and self.auto_enabled == true
        and not self.auto_canceled
end

local function now_sec()
    return (love and love.timer and love.timer.getTime and love.timer.getTime()) or os.clock()
end

local function is_combat_stats_open()
    local gui = game and game.game_gui
    local csv = gui and gui.combat_stats_view
    return csv ~= nil and csv.hidden == false
end

local function is_link_ready(self)
    local lb = self.lobby
    if not lb then return false end
    if not lb.peer_connected then return false end
    if lb.is_room_link_alive and not lb:is_room_link_alive() then return false end
    if self.lockstep and (self.lockstep.phase == "WAIT_RECONNECT" or self.lockstep.phase == "DISCONNECTED") then
        return false
    end
    return true
end

function stage_flow:on_outcome(kind, store)
    if not (self.coop and self.coop:is_active()) then return end
    if self.lockstep and self.lockstep:is_catching_up() then return end
    local lvl = (store and store.level_idx) or (self.coop.cfg and self.coop.cfg.level_idx) or 101
    self.outcome = kind
    self.outcome_ts = now_sec()
    self.cur_level_idx = tonumber(lvl) or 101
    self.launching = false
    self.launching_reason = nil
    self._guest_nudge_sent = false
    self.auto_canceled = false
    self.auto_paused_stats = false
    if kind == "victory" then
        self.stars = (store and store.game_outcome and tonumber(store.game_outcome.stars)) or 3
        self.next_level_idx = catalog.get_next_stage_idx(self.cur_level_idx)
        self.auto_enabled = (self.coop.cfg == nil) or (self.coop.cfg.auto_next_stage ~= false)
        self.countdown = (self.auto_enabled and self.next_level_idx) and AUTO_NEXT_DELAY or 0
        self.active = false -- reveal cleanly when VictoryView:show() opens (or after fallback)
    else
        self.stars = 0
        self.next_level_idx = nil
        self.auto_enabled = false
        self.countdown = 0
        self.active = true
    end
    if self.boot then
        self.boot:log("[STAGE_FLOW] Match outcome=%s level=%d next=%s auto=%s",
            tostring(kind), self.cur_level_idx, tostring(self.next_level_idx), tostring(self.auto_enabled))
    end
end

function stage_flow:on_victory_view_shown()
    if not (self.coop and self.coop:is_active()) then return end
    if self.outcome ~= "victory" then
        self:on_outcome("victory", game and game.store)
    end
    self.active = true
    if self.auto_enabled and self.next_level_idx and not self.auto_canceled and not self.launching then
        self.countdown = AUTO_NEXT_DELAY
    end
end

function stage_flow:on_defeat_view_shown()
    if not (self.coop and self.coop:is_active()) then return end
    if self.outcome ~= "defeat" then
        self:on_outcome("defeat", game and game.store)
    end
    self.active = true
end

function stage_flow:send_flow_msg(action, target_level)
    local lb = self.lobby
    if not (lb and lb.transport and lb.transport:is_connected()) then return false end
    return lb.transport:send({
        t = "MATCH_FLOW",
        pid = lb.local_pid or 1,
        action = action,
        level_idx = target_level,
    }) == true
end

function stage_flow:request_next()
    if self.launching or not self.next_level_idx then return false end
    local lb = self.lobby
    if not lb then return false end
    if not is_link_ready(self) then
        if self.overlay then
            self.overlay:show_toast("队友或网络连接暂未就绪，稍后再试或点「返回战桌」！", 3.0)
        end
        return false
    end
    if lb.role == "host" then
        self.launching = true
        self.launching_reason = "next"
        return lb:launch_chain_stage(self.next_level_idx, "next", 1)
    else
        if lb.transport and lb.transport:is_online() and lb.server_direct_next_ok ~= true then
            if self.overlay then
                self.overlay:show_toast("当前公网服为旧版，请等待 1P 房主自动连战（或重启更新服务端）！", 3.5)
            end
            return false
        end
        self.launching = true
        self.launching_reason = "next"
        self:send_flow_msg("next", self.next_level_idx)
        if self.overlay then
            self.overlay:show_toast("已向房主发起连战请求：下一关 " .. catalog.get_stage_label(self.next_level_idx), 2.5)
        end
        return true
    end
end

function stage_flow:request_restart()
    if self.launching then return false end
    local cur = self.cur_level_idx or (self.coop and self.coop.cfg and self.coop.cfg.level_idx)
    if not cur then return false end
    local lb = self.lobby
    if not lb then return false end
    if not is_link_ready(self) then
        if self.overlay then
            self.overlay:show_toast("队友或网络连接暂未就绪，无法重开本关！", 3.0)
        end
        return false
    end
    if lb.role == "host" then
        self.launching = true
        self.launching_reason = "restart"
        return lb:launch_chain_stage(cur, "restart", 1)
    else
        if lb.transport and lb.transport:is_online() and lb.server_direct_next_ok ~= true then
            if self.overlay then
                self.overlay:show_toast("当前公网服为旧版，请由 1P 房主点击重开本关或返回战桌！", 3.5)
            end
            return false
        end
        self.launching = true
        self.launching_reason = "restart"
        self:send_flow_msg("restart", cur)
        if self.overlay then
            self.overlay:show_toast("已向房主发起原地重开本关请求...", 2.5)
        end
        return true
    end
end

function stage_flow:request_cancel_auto()
    if self.auto_canceled then return end
    self.auto_canceled = true
    self.countdown = 0
    local lb = self.lobby
    if lb and (not lb.transport:is_online() or lb.server_direct_next_ok == true) then
        self:send_flow_msg("cancel_auto", self.cur_level_idx)
    end
    if self.overlay then
        self.overlay:show_toast("已取消自动下一关，可自由查看统计，稍后点「进入下一关」或「返回战桌」。", 2.8)
    end
end

function stage_flow:on_message(msg)
    if not msg or msg.t ~= "MATCH_FLOW" then return false end
    local lb = self.lobby
    if not lb then return true end
    local act = msg.action
    local by_pid = tonumber(msg.pid) or (lb.local_pid == 1 and 2 or 1)

    if act == "cancel_auto" then
        self.auto_canceled = true
        self.countdown = 0
        if self.overlay then
            self.overlay:show_toast(string.format("%dP 已暂停自动下一关，可查看统计或手动继续。", by_pid), 2.8)
        end
        return true
    end

    if lb.role ~= "host" then return true end
    if act == "next" and not self.launching then
        local target = tonumber(msg.level_idx) or self.next_level_idx
        if target and target >= 1 and target <= 999 then
            self.launching = true
            self.launching_reason = "next"
            lb:launch_chain_stage(target, "next", by_pid)
        end
    elseif act == "restart" and not self.launching then
        local target = tonumber(msg.level_idx) or self.cur_level_idx or (lb.room and lb.room.level_idx)
        if target and target >= 1 and target <= 999 then
            self.launching = true
            self.launching_reason = "restart"
            lb:launch_chain_stage(target, "restart", by_pid)
        end
    end
    return true
end

function stage_flow:update(dt)
    if not (self.coop and self.coop:is_active()) then
        if self.active or self.outcome then self:reset() end
        return
    end
    -- Never advance hidden auto-next countdown while director is outside the 'game' screen
    -- (e.g. during loading transitions or any non-game screen where the countdown bar is invisible).
    if main and main.handler and main.handler.active_item ~= game then
        return
    end
    -- Fallback reveal if a custom stage triggers game-victory without VictoryView:show()
    if self.outcome == "victory" and not self.active and self.outcome_ts > 0 then
        if (now_sec() - self.outcome_ts) >= VICTORY_FALLBACK_SHOW then
            self.active = true
        end
    end
    if not self.active or self.outcome ~= "victory" then return end
    if self.launching or not self.auto_enabled or self.auto_canceled or not self.next_level_idx then
        return
    end
    if is_combat_stats_open() then
        self.auto_paused_stats = true
        return
    end
    self.auto_paused_stats = false
    if not is_link_ready(self) then return end

    self.countdown = math.max(0, (self.countdown or 0) - math.min(dt or 0, 0.25))
    if self.countdown <= 0 then
        local lb = self.lobby
        if lb and lb.role == "host" then
            self.launching = true
            self.launching_reason = "next"
            lb:launch_chain_stage(self.next_level_idx, "next", 1)
        elseif lb and lb.role == "client" and not self._guest_nudge_sent then
            self._guest_nudge_sent = true
            self.launching = true
            self.launching_reason = "next"
            if not lb.transport:is_online() or lb.server_direct_next_ok == true then
                self:send_flow_msg("next", self.next_level_idx)
            end
        end
    end
end

local function normalize_xy(x, y)
    if x >= 0 and x <= 1 and y >= 0 and y <= 1 and love and love.graphics then
        x = x * (love.graphics.getWidth() or 1)
        y = y * (love.graphics.getHeight() or 1)
    end
    return x, y
end

function stage_flow:is_point_over(x, y)
    if not self.active or not self._last_panel then return false end
    if self.lobby and self.lobby.open then return false end
    x, y = normalize_xy(x, y)
    local s = self._ui_scale or 1
    local lx, ly = x / s, y / s
    local p = self._last_panel
    return lx >= p.x and lx <= p.x + p.w and ly >= p.y and ly <= p.y + p.h
end

function stage_flow:mousepressed(x, y, button)
    if not self.active or button ~= 1 then return false end
    if self.lobby and self.lobby.open then return false end
    local s = self._ui_scale or 1
    local lx, ly = x / s, y / s
    for _, b in ipairs(self.buttons) do
        if lx >= b.x and lx <= b.x + b.w and ly >= b.y and ly <= b.y + b.h then
            self._consumed_down = true
            if b.id == "sf_next" then
                ui.play_sfx("start")
                self:request_next()
            elseif b.id == "sf_restart" then
                ui.play_sfx("start")
                self:request_restart()
            elseif b.id == "sf_cancel" then
                ui.play_sfx("click")
                self:request_cancel_auto()
            elseif b.id == "sf_lobby" then
                ui.play_sfx("tab")
                if self.boot and self.boot.on_hud_action then
                    self.boot:on_hud_action("mp_return_lobby")
                end
            end
            return true
        end
    end
    local p = self._last_panel
    if p and lx >= p.x and lx <= p.x + p.w and ly >= p.y and ly <= p.y + p.h then
        self._consumed_down = true
        return true
    end
    return false
end

function stage_flow:mousereleased(x, y, button)
    if self._consumed_down and button == 1 then
        self._consumed_down = false
        return true
    end
    return false
end

function stage_flow:draw()
    if not love or not love.graphics then return end
    if self.lobby and self.lobby.open then
        self._last_panel = nil
        return
    end
    local G, T = love.graphics, ui.THEME
    local sw, sh = G.getWidth(), G.getHeight()
    local scale = ui.compute_hud_scale(sw, sh)
    self._ui_scale = scale
    local vsw, vsh = sw / scale, sh / scale
    local fm = ui.make_font_map(scale)

    -- 1. Smooth dark-oak transition cover during the 1-frame game -> slots -> game bounce (zero save-slots flash!)
    local pending = self.coop and self.coop:is_active() and self.coop._pending_launch_args or nil
    if pending and main and main.handler and main.handler.active_item ~= game then
        self._last_panel = nil
        self.buttons = {}
        G.push("all")
        G.origin()
        G.setScissor()
        G.setShader()
        G.setBlendMode("alpha")
        ui.begin_transform(scale, 0, 0)
        G.setColor(16, 10, 6, 245)
        G.rectangle("fill", 0, 0, vsw, vsh)
        local cw, ch = math.min(430, vsw - 40), 92
        local cx, cy = math.floor((vsw - cw) * 0.5), math.floor((vsh - ch) * 0.5)
        ui.draw_vgrad_rect(cx, cy, cw, ch, T.wood_top, T.wood_bot, 12)
        G.setColor(T.gold_mid[1], T.gold_mid[2], T.gold_mid[3], 235)
        G.setLineWidth(2.2)
        G.rectangle("line", cx, cy, cw, ch, 12, 12)
        local title = (self.launching_reason == "restart") and "正在原地重开本关..." or "正在自动前往下一关..."
        ui.print_shadow(title, cx, cy + 18, T.gold_bright, cw, "center", nil, fm.title)
        ui.print_shadow(catalog.get_stage_label(pending.level_idx), cx, cy + 50,
            { 246, 232, 198, 245 }, cw, "center", nil, fm.small_bold)
        ui.end_transform()
        G.pop()
        return
    end

    if not self.active or not (self.coop and self.coop:is_active()) then
        self._last_panel = nil
        self.buttons = {}
        return
    end
    if not main or not main.handler or main.handler.active_item ~= game then
        self._last_panel = nil
        self.buttons = {}
        return
    end

    local raw_mx, raw_my = 0, 0
    if love.mouse and love.mouse.getPosition then raw_mx, raw_my = love.mouse.getPosition() end
    local mx, my = raw_mx / scale, raw_my / scale

    local has_next = (self.outcome == "victory" and self.next_level_idx ~= nil)
    local counting = has_next and self.auto_enabled and not self.auto_canceled and not self.launching
    local btns = {}
    local function add_btn(id, label, bx, by, bw, bh, style)
        btns[#btns + 1] = { id = id, label = label, x = bx, y = by, w = bw, h = bh, style = style or "wood", tiny = true, radius = 6 }
    end

    local pw = math.min(has_next and 568 or 472, vsw - 24)
    local ph = counting and 56 or 48
    local px = math.floor((vsw - pw) * 0.5)
    local py = math.max(58, math.floor(vsh - ph - 10))
    self._last_panel = { x = px, y = py, w = pw, h = ph }

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")
    ui.begin_transform(scale, 0, 0)

    G.setColor(0, 0, 0, 128)
    G.rectangle("fill", px - 2, py + 4, pw + 4, ph + 3, 11, 11)
    ui.draw_vgrad_rect(px, py, pw, ph, T.wood_top, T.wood_bot, 10)
    G.setColor(255, 222, 162, 86)
    G.setLineWidth(1.4)
    G.line(px + 10, py + 2, px + pw - 10, py + 2)
    G.setColor(T.gold_mid[1], T.gold_mid[2], T.gold_mid[3], 228)
    G.setLineWidth(2.0)
    G.rectangle("line", px, py, pw, ph, 10, 10)
    ui.draw_brass_rivet(px + 9, py + 24, 3.0)
    ui.draw_brass_rivet(px + pw - 9, py + 24, 3.0)

    local by = py + 11
    local bh = 26
    local right_x = px + pw - 18
    if self.launching then
        add_btn("sf_lobby", "返回战桌", right_x - 66, by, 66, bh, "azure")
        right_x = right_x - 74
    elseif has_next then
        add_btn("sf_lobby", "返回战桌", right_x - 66, by, 66, bh, "azure")
        right_x = right_x - 72
        if counting then
            add_btn("sf_cancel", "取消自动", right_x - 66, by, 66, bh, "wood")
            right_x = right_x - 72
            add_btn("sf_next", "立即下一关", right_x - 78, by, 78, bh, "battle")
            right_x = right_x - 86
        else
            add_btn("sf_next", "进入下一关", right_x - 78, by, 78, bh, "battle")
            right_x = right_x - 86
        end
    else
        add_btn("sf_lobby", "返回战桌", right_x - 66, by, 66, bh, "azure")
        right_x = right_x - 72
        add_btn("sf_restart", "重开本关", right_x - 72, by, 72, bh, "battle")
        right_x = right_x - 80
    end

    local tx = px + 18
    local tw = math.max(80, right_x - tx)
    local msg, col
    if self.launching then
        local lbl = (self.launching_reason == "restart")
            and ("正在原地重开：" .. catalog.get_stage_label(self.cur_level_idx))
            or ("正在同步进入下一关：" .. catalog.get_stage_label(self.next_level_idx))
        msg, col = lbl, T.ok_bright
    elseif has_next then
        local nxt_lbl = catalog.get_stage_label(self.next_level_idx)
        if counting and self.auto_paused_stats then
            msg, col = "已暂停倒计时（查看统计中）· 下一关：" .. nxt_lbl, T.gold_bright
        elseif counting and not is_link_ready(self) then
            msg, col = "连接波动，等待恢复后自动进入：" .. nxt_lbl, T.gold_bright
        elseif counting then
            local sec = math.max(1, math.ceil(self.countdown or 0))
            msg, col = string.format("通关连战！%ds 后自动下一关：%s", sec, nxt_lbl), T.gold_bright
        else
            msg, col = "通关胜利！下一关：" .. nxt_lbl, { 246, 234, 202, 255 }
        end
    elseif self.outcome == "victory" then
        msg, col = "恭喜通关本代全部战役！可重开本关或回战桌换世代", T.gold_bright
    else
        msg, col = "防线失守！可直接原地重开本关，或返回战桌换阵", { 255, 212, 186, 255 }
    end

    local ty = py + (48 - ui.font_h(fm.small_bold)) * 0.5
    ui.print_shadow(msg, tx, ty, col, tw, "left", nil, fm.small_bold)

    if counting then
        local bx_p, by_p, bw_p, bh_p = px + 16, py + ph - 9, pw - 32, 4
        local frac = math.max(0, math.min(1, (self.countdown or 0) / AUTO_NEXT_DELAY))
        G.setColor(20, 12, 6, 230)
        G.rectangle("fill", bx_p, by_p, bw_p, bh_p, 2, 2)
        local fw = math.floor(bw_p * (1 - frac))
        if fw > 0 then
            ui.draw_vgrad_rect(bx_p, by_p, fw, bh_p, T.emerald_top, T.emerald_bot, 2)
        end
    end

    self.buttons = btns
    local allow_hover = not proto.is_android()
    for _, b in ipairs(btns) do
        local hover = allow_hover and (mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h)
        ui.draw_button(b, hover, fm)
    end

    ui.end_transform()
    G.pop()
end

return stage_flow
