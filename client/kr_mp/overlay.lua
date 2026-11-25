-- KR-MP 顶层中文 HUD 覆盖层（使用 FL 4.1.0 内置 HarmonyOS Sans SC 简体中文字体）
local fonts = require("kr_mp.fonts")
local proto = require("kr_mp.proto")

local overlay = {
    visible = true,
    toast = nil,
    toast_until = 0,
    font = nil,
    font_small = nil,
    state = {},
    buttons = {},
    on_action = nil,
    _consumed_down = false,
}

local PHASE_LABELS = {
    IDLE = "待机",
    LOADING = "加载关卡中",
    CATCHING_UP = "高速追帧重连中",
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
end

function overlay:show_toast(msg, duration)
    self.toast = tostring(msg)
    self.toast_until = (love.timer and love.timer.getTime() or 0) + (duration or 4.0)
end

function overlay:set_status(state)
    self.state = state or {}
end

local function build_buttons(s, x, y, w)
    local btns = {}
    local bx = x + 8
    local by = y + 46
    local bh = 25
    local gap = 6

    local function add_btn(id, label, bw, bg)
        btns[#btns + 1] = {
            id = id,
            label = label,
            x = bx,
            y = by,
            w = bw,
            h = bh,
            bg = bg,
        }
        bx = bx + bw + gap
    end

    if s.mp_active then
        local other = (s.mp_pid == 1) and "2P" or "1P"
        if s.mp_econ == "independent" then
            add_btn("mp_send_gold", "转50金→" .. other, 92, { 195, 135, 25, 240 })
        end
        local spd = s.mp_speed or 1
        local slbl = string.format("倍速: %dx", spd)
        local sbg = (spd == 2) and { 25, 155, 115, 240 } or { 58, 78, 108, 240 }
        add_btn("mp_speed", slbl, 76, sbg)

        local plbl = (s.mp_phase == "PAUSED") and "继续对局" or "暂停对局"
        local pbg = (s.mp_phase == "PAUSED") and { 35, 150, 75, 240 } or { 55, 100, 175, 240 }
        add_btn("mp_pause", plbl, 78, pbg)
        add_btn("mp_leave", "退出联机", 78, { 175, 50, 50, 235 })
        add_btn("hide", "隐藏(F9)", 74, { 60, 68, 82, 220 })
        return btns
    end

    local mode = s.mode or "IDLE"
    if mode == "RECORDING" then
        add_btn("stop", "停止并保存 (F8)", 130, { 205, 95, 20, 235 })
        add_btn("hide", "隐藏 (F9)", 78, { 60, 68, 82, 220 })
    elseif mode == "REPLAYING" then
        local sp = s.replay_speed or 1
        local sp_lbl = string.format("回放倍速: %dx (F5)", sp)
        local sp_bg = (sp > 1) and { 20, 155, 115, 235 } or { 45, 105, 175, 235 }
        add_btn("speed", sp_lbl, 136, sp_bg)
        add_btn("stop", "停止回放 (F8)", 118, { 185, 55, 55, 235 })
        add_btn("hide", "隐藏 (F9)", 78, { 60, 68, 82, 220 })
    elseif mode == "VERIFIED_OK" or mode == "DESYNC" then
        add_btn("stop", "返回游戏 (F8)", 120, { 35, 135, 70, 235 })
        add_btn("replay", "重新回放 (F7)", 120, { 35, 100, 175, 235 })
        add_btn("record", "重新录制 (F6)", 115, { 175, 45, 45, 235 })
    else
        add_btn("lobby", "联机大厅 (F10)", 126, { 30, 135, 95, 240 })
        add_btn("record", "录制 (F6)", 82, { 175, 50, 50, 230 })
        if s.has_replay then
            add_btn("replay", "回放 (F7)", 82, { 35, 105, 180, 230 })
        end
        add_btn("hide", "隐藏 (F9)", 78, { 60, 68, 82, 220 })
    end

    return btns
end

function overlay:mousepressed(x, y, button)
    if not self.visible or button ~= 1 then
        return false
    end
    for _, b in ipairs(self.buttons) do
        if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
            self._consumed_down = true
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
    if self.font then G.setFont(self.font) end

    local s = self.state or {}
    local mode = s.mode or "IDLE"
    local tick = s.tick or 0
    local max_tick = s.max_tick or 0
    local catchup_target = s.mp_catchup_target or 0
    local hash_hex = s.last_hash or "--------"
    local sock_txt = s.socket_ok and "网络正常" or "网络异常"
    local cmds = s.cmd_count or 0
    local seed = s.seed or 0
    local extra = s.extra or ""

    local sw = (G.getWidth and G.getWidth()) or 920
    local pad = 8
    local w, x, y
    if s.mp_active then
        -- Top-center compact HUD in Co-op so native top-left Lives/Gold/Wave & top-right buttons stay visible
        w = math.min(460, sw - 20)
        x = math.max(10, math.floor((sw - w) / 2))
        y = 6
    else
        w = math.min(500, sw - 20)
        x, y = 10, 10
    end
    local has_replay_bar = (not s.mp_active and mode == "REPLAYING" and max_tick > 0)
    local has_catchup_bar = (s.mp_active and s.mp_phase == "CATCHING_UP" and catchup_target > 0)
    local h = (has_replay_bar or has_catchup_bar) and 98 or 80

    self.buttons = build_buttons(s, x, y, w)

    -- Panel background
    if s.mp_active then
        if s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED" then
            G.setColor(175, 20, 20, 240)
        elseif s.mp_phase == "WAIT_RECONNECT" then
            G.setColor(155, 92, 18, 235)
        elseif s.mp_phase == "CATCHING_UP" then
            G.setColor(18, 92, 145, 235)
        elseif s.mp_pid == 1 then
            G.setColor(18, 52, 105, 225)
        else
            G.setColor(105, 24, 34, 225)
        end
    elseif mode == "RECORDING" then
        G.setColor(115, 20, 20, 215)
    elseif mode == "REPLAYING" then
        G.setColor(18, 65, 125, 220)
    elseif mode == "VERIFIED_OK" then
        G.setColor(18, 115, 52, 230)
    elseif mode == "DESYNC" then
        G.setColor(175, 18, 18, 240)
    else
        G.setColor(15, 20, 30, 198)
    end
    G.rectangle("fill", x, y, w, h, 6, 6)

    G.setColor(255, 255, 255, 145)
    G.rectangle("line", x, y, w, h, 6, 6)

    -- Status lines
    local line1, line2
    if s.mp_active then
        local who = (s.mp_pid == 1) and "1P(蓝方)" or "2P(红方)"
        local net_tag = s.mp_online
            and ("公网 #" .. tostring(s.mp_room_code or "----"))
            or "局域网 2P"
        local gold_txt = (s.mp_econ == "independent")
            and string.format("1P:%d金 2P:%d金", s.mp_g1 or 0, s.mp_g2 or 0)
            or string.format("共享:%d金", s.mp_g1 or 0)
        local wait_txt = s.mp_waiting and " [等待队友]" or ""
        local phase_cn = PHASE_LABELS[s.mp_phase] or tostring(s.mp_phase)
        line1 = string.format("[%s] 你是%s | %s | 延迟:%dms | 已校验:%d%s",
            net_tag, who, gold_txt, s.mp_rtt or 0, s.mp_sync_ok or 0, wait_txt)
        if has_catchup_bar then
            line2 = string.format("状态:%s (%d/%d 帧) | 校验:%s", phase_cn, tick, catchup_target, hash_hex)
        else
            line2 = string.format("状态:%s | %dx倍速 | 帧:%d | 校验:%s | Alt+左键:地图打点",
                phase_cn, s.mp_speed or 1, tick, hash_hex)
        end
    else
        local m_cn = MODE_LABELS[mode] or mode
        line1 = string.format("[KR-MP v%s] %s | %s | 帧:%d | 指令:%d | 种子:%d",
            proto.MOD_VERSION, m_cn, sock_txt, tick, cmds, seed)
        line2 = string.format("每30帧校验:%s %s", hash_hex, extra)
    end

    G.setColor(255, 255, 255, 255)
    G.print(line1, x + pad, y + 6)
    G.setColor(220, 238, 255, 245)
    G.print(line2, x + pad, y + 24)

    -- Clickable buttons
    local mx, my = 0, 0
    if love.mouse and love.mouse.getPosition then
        mx, my = love.mouse.getPosition()
    end
    if self.font_small then G.setFont(self.font_small) end
    for _, btn in ipairs(self.buttons) do
        local hover = (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
        local bg = btn.bg
        if hover then
            G.setColor(math.min(255, bg[1] + 30), math.min(255, bg[2] + 30), math.min(255, bg[3] + 30), 250)
        else
            G.setColor(bg[1], bg[2], bg[3], bg[4])
        end
        G.rectangle("fill", btn.x, btn.y, btn.w, btn.h, 4, 4)
        G.setColor(255, 255, 255, hover and 220 or 120)
        G.rectangle("line", btn.x, btn.y, btn.w, btn.h, 4, 4)
        G.setColor(255, 255, 255, 255)
        G.printf(btn.label, btn.x, btn.y + 4, btn.w, "center")
    end

    -- Progress bar for Replay or Fast-Forward Reconnect
    if has_replay_bar or has_catchup_bar then
        local px, py = x + pad, y + 78
        local pw, ph = w - pad * 2, 12
        local denom = has_catchup_bar and catchup_target or max_tick
        local frac = math.max(0, math.min(1, tick / math.max(1, denom)))
        G.setColor(10, 20, 35, 220)
        G.rectangle("fill", px, py, pw, ph, 3, 3)
        if has_catchup_bar then
            G.setColor(95, 235, 165, 245)
        else
            G.setColor(70, 220, 255, 240)
        end
        G.rectangle("fill", px, py, math.floor(pw * frac), ph, 3, 3)
        G.setColor(255, 255, 255, 140)
        G.rectangle("line", px, py, pw, ph, 3, 3)
    end

    -- Toast banner
    local now = love.timer and love.timer.getTime() or 0
    if self.toast and now < self.toast_until then
        local ty = y + h + 6
        if self.font then G.setFont(self.font) end
        G.setColor(0, 0, 0, 228)
        G.rectangle("fill", x, ty, w, 28, 5, 5)
        G.setColor(255, 225, 110, 255)
        G.rectangle("line", x, ty, w, 28, 5, 5)
        G.setColor(255, 240, 150, 255)
        G.print(self.toast, x + pad, ty + 6)
    end

    G.pop()
    if prev_font then G.setFont(prev_font) end
    G.setColor(r, g, b, a)
    G.setBlendMode(prev_blend)
end

return overlay
