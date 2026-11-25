-- KR-MP 42px 铁皮手绘雕花木铁战地微章 HUD（V2 精雕版 · 零调试噪音 + 悬停展开校验羊皮纸条）
local fonts = require("kr_mp.fonts")
local proto = require("kr_mp.proto")
local ui = require("kr_mp.ui_assets")

local overlay = {
    visible = true,
    toast = nil,
    toast_until = 0,
    font = nil,
    font_small = nil,
    font_tiny = nil,
    state = {},
    buttons = {},
    on_action = nil,
    _consumed_down = false,
}

local PHASE_LABELS = {
    IDLE = "待机",
    LOADING = "加载关卡中",
    CATCHING_UP = "高速追帧中",
    WAIT_RECONNECT = "等待队友重连",
    RUNNING = "联机中",
    PAUSED = "已暂停",
    DESYNC = "同步异常!",
    DISCONNECTED = "已断线",
}

local MODE_LABELS = {
    IDLE = "单机待机",
    RECORDING = "录制中",
    REPLAYING = "回放校验中",
    VERIFIED_OK = "校验100%通过",
    DESYNC = "回放分叉!",
}

function overlay:init(on_action)
    self.on_action = on_action
    self.font = fonts.get(13)
    self.font_small = fonts.get(12)
    self.font_tiny = fonts.get(11)
end

function overlay:show_toast(msg, duration)
    self.toast = tostring(msg)
    self.toast_until = (love.timer and love.timer.getTime() or 0) + (duration or 4.0)
end

function overlay:set_status(state)
    self.state = state or {}
end

function overlay:mousepressed(x, y, button)
    if not self.visible or button ~= 1 then
        return false
    end
    for _, b in ipairs(self.buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            self._consumed_down = true
            if b.id == "mp_send_gold" then
                ui.play_sfx("coin")
            elseif b.id == "mp_leave" then
                ui.play_sfx("close")
            else
                ui.play_sfx("click")
            end
            if self.on_action then
                self.on_action(b.id)
            end
            return true
        end
    end
    return false
end

function overlay:mousereleased(x, y, button)
    if self._consumed_down and button == 1 then
        self._consumed_down = false
        return true
    end
    return false
end

function overlay:draw()
    if not self.visible or not love.graphics then
        return
    end

    local G = love.graphics
    local T = ui.THEME
    local prev_font = G.getFont()
    local r, g, b, a = G.getColor()
    local prev_blend = G.getBlendMode()

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")
    if not self.font then self.font = fonts.get(13) end
    if not self.font_small then self.font_small = fonts.get(12) end
    if not self.font_tiny then self.font_tiny = fonts.get(11) end

    local font_map = {
        main  = self.font,
        small = self.font_small,
        tiny  = self.font_tiny,
    }

    local s = self.state or {}
    local mode = s.mode or "IDLE"
    local tick = s.tick or 0
    local max_tick = s.max_tick or 0
    local catchup_target = s.mp_catchup_target or 0
    local hash_hex = s.last_hash or "--------"
    local sock_txt = s.socket_ok and "网络正常" or "网络异常"
    local cmds = s.cmd_count or 0
    local extra = s.extra or ""

    local sw = (G.getWidth and G.getWidth()) or 920
    local mx, my = 0, 0
    if love.mouse and love.mouse.getPosition then
        mx, my = love.mouse.getPosition()
    end

    local btns = {}
    local function add_btn(id, label, bx, by, bw, bh, style, extra_b)
        local btn = { id = id, label = label, x = bx, y = by, w = bw, h = bh, style = style or "wood", radius = 6 }
        if extra_b then
            for k, v in pairs(extra_b) do btn[k] = v end
        end
        btns[#btns + 1] = btn
    end

    local x, y, w, h

    if s.mp_active then
        -- === 42px 铁皮手绘雕花木铁战地微章 HUD ===
        local has_catchup_bar = (s.mp_phase == "CATCHING_UP" and catchup_target > 0)
        local is_alert = (s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED" or s.mp_phase == "WAIT_RECONNECT" or s.mp_waiting)
        local is_indep = (s.mp_econ == "independent")
        local show_marks_btn = (s.mp_tower_mode == "owned")

        w = math.min(488, sw - 20)
        x = math.max(10, math.floor((sw - w) / 2))
        if sw >= 880 and x < 220 then x = 220 end
        y = 7
        h = has_catchup_bar and 66 or (is_alert and 62 or 42)

        -- Twin subtle iron hanging chains anchored to top window edge
        G.setColor(24, 22, 20, 235)
        G.rectangle("fill", x + 32, 0, 4, y + 2)
        G.rectangle("fill", x + w - 36, 0, 4, y + 2)
        G.setColor(126, 134, 144, 210)
        G.rectangle("fill", x + 33, 0, 2, y + 1)
        G.rectangle("fill", x + w - 35, 0, 2, y + 1)

        -- Drop shadow
        G.setColor(0, 0, 0, 112)
        G.rectangle("fill", x - 2, y + 4, w + 4, h + 3, 11, 11)

        -- Main carved oak / alert timber plaque
        local top_c, bot_c = T.wood_top, T.wood_bot
        if s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED" then
            top_c, bot_c = { 164, 34, 32, 248 }, { 96, 18, 18, 248 }
        elseif s.mp_phase == "WAIT_RECONNECT" then
            top_c, bot_c = { 162, 98, 24, 248 }, { 98, 56, 12, 248 }
        elseif s.mp_phase == "CATCHING_UP" then
            top_c, bot_c = { 28, 92, 136, 248 }, { 16, 54, 88, 248 }
        end
        ui.draw_vgrad_rect(x, y, w, h, top_c, bot_c, 10)
        G.setColor(255, 218, 156, 86)
        G.setLineWidth(1.5)
        G.line(x + 10, y + 2, x + w - 10, y + 2)
        G.setColor(T.ink_dark[1], T.ink_dark[2], T.ink_dark[3], 255)
        G.setLineWidth(2.4)
        G.rectangle("line", x, y, w, h, 10, 10)

        -- Flanking micro brass rivets
        ui.draw_brass_rivet(x + 9, y + 21, 3.2)
        ui.draw_brass_rivet(x + w - 9, y + 21, 3.2)

        -- Single sleek top row (y + 8, h = 25)
        local cx = x + 17
        local cy = y + 8
        local is_p1 = (s.mp_pid == 1)
        ui.draw_pill(cx, cy + 2, 28, 21, is_p1 and "1P" or "2P",
            is_p1 and T.p1_top or T.p2_top,
            is_p1 and T.p1_border or T.p2_border,
            { 255, 255, 255, 255 }, self.font_tiny)
        cx = cx + 33

        -- Recessed Coin Ledger trough
        local gw = is_indep and 104 or 74
        G.setColor(24, 13, 6, 228)
        G.rectangle("fill", cx, cy + 1, gw, 23, 6, 6)
        G.setColor(148, 104, 48, 200)
        G.setLineWidth(1.2)
        G.rectangle("line", cx, cy + 1, gw, 23, 6, 6)
        ui.draw_coin_icon(cx + 11, cy + 12.5, 5.2)
        if self.font_small then G.setFont(self.font_small) end
        if is_indep then
            ui.print_shadow(tostring(s.mp_g1 or 0), cx + 21, cy + 5, T.p1_light)
            G.setColor(240, 210, 155, 110)
            G.print("|", cx + 56, cy + 5)
            ui.print_shadow(tostring(s.mp_g2 or 0), cx + 65, cy + 5, T.p2_light)
        else
            ui.print_shadow(tostring(s.mp_g1 or 0), cx + 22, cy + 5, T.gold_bright)
        end
        cx = cx + gw + 6

        -- Tactile compact wood/emerald action buttons
        if is_indep then
            add_btn("mp_send_gold", "转50", cx, cy, 42, 24, "wood", { tiny = true, fg = T.gold_bright })
            cx = cx + 47
        end
        local spd = s.mp_speed or 1
        add_btn("mp_speed", string.format("%dx", spd), cx, cy, 32, 24, (spd == 2) and "battle" or "wood", { tiny = true })
        cx = cx + 37

        local is_paused = (s.mp_phase == "PAUSED")
        add_btn("mp_pause", is_paused and "继续" or "暂停", cx, cy, 40, 24, is_paused and "battle" or "wood", { tiny = true })
        cx = cx + 45

        if show_marks_btn then
            local m_on = (s.mp_tower_marks ~= false)
            add_btn("mp_tower_marks", "塔标", cx, cy, 38, 24, "wood", {
                tiny = true,
                fg = m_on and T.ok_bright or { 196, 174, 140, 150 },
            })
            cx = cx + 43
        end

        add_btn("mp_leave", "退出", cx, cy, 38, 24, "crimson", { tiny = true })
        cx = cx + 43
        add_btn("hide", "隐", cx, cy, 24, 24, "wood", { tiny = true })

        -- Right-anchored Emerald Latency Crystal
        local rtt = s.mp_rtt or 0
        local pill_w = 56
        local pill_x = x + w - 16 - pill_w
        G.setColor(22, 12, 5, 225)
        G.rectangle("fill", pill_x, cy + 1, pill_w, 23, 6, 6)
        G.setColor(136, 94, 44, 195)
        G.setLineWidth(1.2)
        G.rectangle("line", pill_x, cy + 1, pill_w, 23, 6, 6)
        ui.draw_ping_dot(pill_x + 11, cy + 12.5, rtt, s.mp_phase ~= "DISCONNECTED" and s.mp_phase ~= "WAIT_RECONNECT")
        if self.font_tiny then G.setFont(self.font_tiny) end
        ui.print_shadow(string.format("%dms", rtt), pill_x + 19, cy + 6, T.ok_bright)

        -- Alert / Catchup Row 2 (only shown when actually catching up or warning!)
        if has_catchup_bar then
            local px_b, py_b, pw_b, ph_b = x + 16, y + 44, w - 32, 13
            local frac = math.max(0, math.min(1, tick / math.max(1, catchup_target)))
            G.setColor(16, 10, 5, 235)
            G.rectangle("fill", px_b, py_b, pw_b, ph_b, 4, 4)
            local fw = math.floor(pw_b * frac)
            if fw > 0 then
                ui.draw_vgrad_rect(px_b, py_b, fw, ph_b, T.emerald_top, T.emerald_bot, 4)
            end
            G.setColor(T.gold_mid[1], T.gold_mid[2], T.gold_mid[3], 210)
            G.setLineWidth(1.1)
            G.rectangle("line", px_b, py_b, pw_b, ph_b, 4, 4)
            if self.font_tiny then G.setFont(self.font_tiny) end
            ui.print_shadow(string.format("高速追帧重连 %d / %d 帧", tick, catchup_target),
                px_b, py_b, { 255, 250, 230, 255 }, pw_b, "center")
        elseif is_alert then
            local phase_cn = PHASE_LABELS[s.mp_phase] or tostring(s.mp_phase)
            local wt = s.mp_waiting and "正在等待队友指令..." or phase_cn
            if self.font_tiny then G.setFont(self.font_tiny) end
            ui.print_shadow(string.format("%s · 帧 %d · 校验 #%s", wt, tick, hash_hex),
                x + 16, y + 43, T.gold_bright, w - 32, "center")
        end

        -- Hovering anywhere over the HUD bar gently reveals the Parchment Sync Telemetry Tooltip!
        local hud_hover = (mx >= x and mx <= x + w and my >= y and my <= y + h)
        if hud_hover and not has_catchup_bar and not is_alert then
            local tip_y = y + h + 5
            ui.draw_parchment_card(x + 28, tip_y, w - 56, 24, { radius = 6 })
            local net_lbl = s.mp_online and ("公网 #" .. tostring(s.mp_room_code or "----")) or "局域网 2P"
            local phase_cn = PHASE_LABELS[s.mp_phase] or tostring(s.mp_phase)
            if self.font_tiny then G.setFont(self.font_tiny) end
            G.setColor(T.ink_text[1], T.ink_text[2], T.ink_text[3], 255)
            G.printf(string.format("%s · %s · 60Hz 校验√%d (#%s) · 帧%d · Alt+左键打点",
                net_lbl, phase_cn, s.mp_sync_ok or 0, hash_hex, tick),
                x + 32, tip_y + 5, w - 64, "center")
        end
    else
        -- === 单机 / 标题页 铁皮木框精简工具条 ===
        local has_replay_bar = (mode == "REPLAYING" and max_tick > 0)
        w = math.min(448, sw - 20)
        x, y = 10, 10
        h = has_replay_bar and 88 or 72

        G.setColor(0, 0, 0, 102)
        G.rectangle("fill", x - 2, y + 4, w + 4, h + 3, 11, 11)
        ui.draw_vgrad_rect(x, y, w, h, T.wood_top, T.wood_bot, 10)
        G.setColor(255, 218, 156, 82)
        G.setLineWidth(1.5)
        G.line(x + 10, y + 2, x + w - 10, y + 2)
        G.setColor(T.ink_dark[1], T.ink_dark[2], T.ink_dark[3], 255)
        G.setLineWidth(2.4)
        G.rectangle("line", x, y, w, h, 10, 10)
        ui.draw_brass_rivet(x + 9, y + 10, 3)
        ui.draw_brass_rivet(x + w - 9, y + 10, 3)

        local m_cn = MODE_LABELS[mode] or mode
        ui.draw_pill(x + 18, y + 7, 84, 19, "KR-MP v" .. proto.MOD_VERSION,
            { 152, 34, 28, 245 }, T.gold_mid, T.gold_bright, self.font_tiny)
        if self.font_tiny then G.setFont(self.font_tiny) end
        ui.print_shadow(string.format("%s · %s %s", m_cn, sock_txt, extra), x + 108, y + 10, { 255, 242, 206, 245 })

        local bx, by = x + 16, y + 34
        if mode == "RECORDING" then
            add_btn("stop", "停止并保存 (F8)", bx, by, 128, 26, "crimson", { small = true })
            add_btn("hide", "隐藏 (F9)", bx + 136, by, 76, 26, "wood", { small = true })
        elseif mode == "REPLAYING" then
            local sp = s.replay_speed or 1
            add_btn("speed", string.format("倍速:%dx (F5)", sp), bx, by, 106, 26, (sp > 1) and "battle" or "azure", { small = true })
            add_btn("stop", "停止回放 (F8)", bx + 114, by, 104, 26, "crimson", { small = true })
            add_btn("hide", "隐藏 (F9)", bx + 226, by, 76, 26, "wood", { small = true })
        elseif mode == "VERIFIED_OK" or mode == "DESYNC" then
            add_btn("stop", "返回游戏 (F8)", bx, by, 114, 26, "battle", { small = true })
            add_btn("replay", "重放 (F7)", bx + 122, by, 86, 26, "azure", { small = true })
            add_btn("record", "重录 (F6)", bx + 216, by, 86, 26, "crimson", { small = true })
        else
            add_btn("lobby", "联机大厅 (F10)", bx, by, 134, 26, "battle", { small = true })
            add_btn("record", "录制 (F6)", bx + 142, by, 78, 26, "crimson", { small = true })
            local nx = bx + 228
            if s.has_replay then
                add_btn("replay", "回放 (F7)", nx, by, 78, 26, "azure", { small = true })
                nx = nx + 86
            end
            add_btn("hide", "隐藏 (F9)", nx, by, 74, 26, "wood", { small = true })
        end

        if has_replay_bar then
            local px_b, py_b, pw_b, ph_b = x + 16, y + 68, w - 32, 11
            local frac = math.max(0, math.min(1, tick / math.max(1, max_tick)))
            G.setColor(16, 10, 5, 235)
            G.rectangle("fill", px_b, py_b, pw_b, ph_b, 4, 4)
            local fw = math.floor(pw_b * frac)
            if fw > 0 then
                ui.draw_vgrad_rect(px_b, py_b, fw, ph_b, { 84, 212, 255, 255 }, { 38, 128, 198, 255 }, 4)
            end
            G.setColor(T.gold_mid[1], T.gold_mid[2], T.gold_mid[3], 200)
            G.setLineWidth(1)
            G.rectangle("line", px_b, py_b, pw_b, ph_b, 4, 4)
        end
    end

    -- Render all clickable HUD buttons
    self.buttons = btns
    for _, btn in ipairs(btns) do
        local hover = (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
        ui.draw_button(btn, hover, font_map)
    end

    -- Ironhide Aged-Parchment Toast Notification Banner
    local now = love.timer and love.timer.getTime() or 0
    if self.toast and now < self.toast_until then
        local ty = y + h + 8
        if self.font_small then G.setFont(self.font_small) end
        ui.draw_parchment_card(x, ty, w, 28, {
            radius = 7, border = { 138, 92, 34, 255 }, border_w = 1.8,
        })
        G.setColor(T.ink_text[1], T.ink_text[2], T.ink_text[3], 255)
        G.printf(self.toast, x + 10, ty + 6, w - 20, "center")
    end

    G.pop()
    if prev_font then G.setFont(prev_font) end
    G.setColor(r, g, b, a)
    G.setBlendMode(prev_blend)
end

return overlay
