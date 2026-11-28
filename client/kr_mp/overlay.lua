-- KR-MP 42px 铁皮手绘雕花木铁战地微章 HUD（V2 精雕版 · 自适应高清缩放 + 零调试噪音 + 悬停展开校验羊皮纸条）
local proto = require("kr_mp.proto")
local ui = require("kr_mp.ui_assets")

local overlay = {
    visible = true,
    toast = nil,
    toast_until = 0,
    state = {},
    buttons = {},
    on_action = nil,
    _consumed_down = false,
    _ptt_btn_down = false,
    _ui_scale = 1,
    _last_bar = nil,
    _last_voice_panel = nil,
    _last_toast_rect = nil,
    _wait_banner_until = 0,
    _leave_confirm_until = 0,
    voice_panel_open = false,
    -- Movable collapsed floating badge ("小标") state (logical HUD coordinates)
    mini_x = nil,
    mini_y = nil,
    _mini_rect = nil,
    _mini_drag = false,
    _mini_moved = false,
    _mini_start_lx = 0,
    _mini_start_ly = 0,
    _mini_orig_x = 0,
    _mini_orig_y = 0,
}

local MINI_W, MINI_H = 58, 28
local MINI_DRAG_THRESH = 5

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
end

function overlay:show_toast(msg, duration)
    self.toast = tostring(msg)
    self.toast_until = (love.timer and love.timer.getTime() or 0) + (duration or 2.5)
end

function overlay:clear_toast()
    self.toast = nil
    self.toast_until = 0
    self._last_toast_rect = nil
end

function overlay:dismiss_toast_at(x, y)
    local r = self._last_toast_rect
    if not r or not self.toast then return false end
    local now = love.timer and love.timer.getTime() or 0
    if (self.toast_until or 0) <= now then
        self._last_toast_rect = nil
        return false
    end
    if x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h then
        self:clear_toast()
        return true
    end
    return false
end

function overlay:set_status(state)
    self.state = state or {}
end

local function clamp_mini_pos(self, mx, my, vsw, vsh)
    local max_x = math.max(6, math.floor((vsw or 960) - MINI_W - 6))
    local max_y = math.max(6, math.floor((vsh or 540) - MINI_H - 6))
    local x = math.max(6, math.min(max_x, math.floor((mx or 10) + 0.5)))
    local y = math.max(6, math.min(max_y, math.floor((my or 10) + 0.5)))
    return x, y
end

function overlay:get_mini_rect(vsw, vsh)
    if self.mini_x == nil or self.mini_y == nil then
        local bar = self._last_bar
        local def_x = bar and (bar.x + bar.w - MINI_W) or 10
        local def_y = bar and (bar.y + 4) or 10
        self.mini_x, self.mini_y = clamp_mini_pos(self, def_x, def_y, vsw, vsh)
    else
        self.mini_x, self.mini_y = clamp_mini_pos(self, self.mini_x, self.mini_y, vsw, vsh)
    end
    local r = { x = self.mini_x, y = self.mini_y, w = MINI_W, h = MINI_H }
    self._mini_rect = r
    return r
end

local function normalize_screen_xy(x, y)
    if x >= 0 and x <= 1 and y >= 0 and y <= 1 and love and love.graphics then
        x = x * (love.graphics.getWidth() or 1)
        y = y * (love.graphics.getHeight() or 1)
    end
    return x, y
end

function overlay:is_point_over_hud(x, y)
    x, y = normalize_screen_xy(x, y)
    local s = self._ui_scale or 1
    local lx, ly = x / s, y / s
    if not self.visible then
        local mr = self._mini_rect
        return mr ~= nil and lx >= mr.x and lx <= mr.x + mr.w and ly >= mr.y and ly <= mr.y + mr.h
    end
    for _, b in ipairs(self.buttons) do
        if lx >= b.x and lx <= b.x + b.w and ly >= b.y and ly <= b.y + b.h then
            return true
        end
    end
    local bar = self._last_bar
    if bar and lx >= bar.x and lx <= bar.x + bar.w and ly >= bar.y and ly <= bar.y + bar.h then
        return true
    end
    local vp = self.voice_panel_open and self._last_voice_panel or nil
    if vp and lx >= vp.x and lx <= vp.x + vp.w and ly >= vp.y and ly <= vp.y + vp.h then
        return true
    end
    return false
end

function overlay:mousepressed(x, y, button)
    if not self.visible then
        if button ~= 1 then return false end
        local mr = self._mini_rect
        if not mr then return false end
        local s = self._ui_scale or 1
        local lx, ly = x / s, y / s
        if lx >= mr.x and lx <= mr.x + mr.w and ly >= mr.y and ly <= mr.y + mr.h then
            self._mini_drag = true
            self._mini_moved = false
            self._consumed_down = true
            self._mini_start_lx = lx
            self._mini_start_ly = ly
            self._mini_orig_x = mr.x
            self._mini_orig_y = mr.y
            return true
        end
        return false
    end
    if button ~= 1 and button ~= 2 then
        return false
    end
    local s = self._ui_scale or 1
    local lx, ly = x / s, y / s
    for _, b in ipairs(self.buttons) do
        if lx >= b.x and lx <= b.x + b.w and ly >= b.y and ly <= b.y + b.h then
            if button == 2 then
                if b.id == "mp_send_gold" then
                    ui.play_sfx("coin")
                    if self.on_action then self.on_action("mp_send_gold", 200) end
                    return true
                end
                return false
            end
            self._consumed_down = true
            if b.id == "mp_voice_ptt" then
                self._ptt_btn_down = true
                ui.play_sfx("click")
                if self.on_action then self.on_action("mp_voice_ptt_down") end
                return true
            elseif b.id == "mp_voice_panel" then
                self.voice_panel_open = not self.voice_panel_open
                ui.play_sfx(self.voice_panel_open and "open" or "close")
                return true
            elseif b.id == "mp_voice_panel_close" then
                self.voice_panel_open = false
                ui.play_sfx("close")
                return true
            elseif b.id == "mp_send_gold" then
                ui.play_sfx("coin")
                local shift = love and love.keyboard and love.keyboard.isDown
                    and (love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift"))
                if self.on_action then self.on_action("mp_send_gold", shift and 200 or 50) end
                return true
            elseif b.id == "mp_leave" then
                local now = (love and love.timer and love.timer.getTime()) or 0
                if now < (self._leave_confirm_until or 0) then
                    self._leave_confirm_until = 0
                    ui.play_sfx("close")
                    if self.on_action then self.on_action("mp_leave") end
                else
                    self._leave_confirm_until = now + 3.0
                    ui.play_sfx("click")
                    self:show_toast("再点一次「确认?」将彻底断开退出（若仅需换关请点「战桌」）", 3.0)
                end
                return true
            elseif b.id == "mp_abort_reconnect" then
                self._leave_confirm_until = 0
                ui.play_sfx("close")
                if self.on_action then self.on_action("mp_leave") end
                return true
            elseif b.id == "mp_return_lobby" then
                self._leave_confirm_until = 0
                ui.play_sfx("tab")
            else
                ui.play_sfx("click")
            end
            if self.on_action then
                local arg = b.arg
                if b.slider_min ~= nil and b.slider_max ~= nil then
                    local frac = math.max(0, math.min(1, (lx - b.x) / math.max(1, b.w)))
                    arg = b.slider_min + frac * (b.slider_max - b.slider_min)
                end
                self.on_action(b.id, arg)
            end
            return true
        end
    end
    if button == 1 and self.voice_panel_open then
        local vp = self._last_voice_panel
        if vp and lx >= vp.x and lx <= vp.x + vp.w and ly >= vp.y and ly <= vp.y + vp.h then
            self._consumed_down = true
            return true
        end
        self.voice_panel_open = false
    end
    return false
end

function overlay:mousemoved(x, y, dx, dy)
    if not self._mini_drag then return false end
    local s = self._ui_scale or 1
    local lx, ly = x / s, y / s
    local off_x, off_y = lx - self._mini_start_lx, ly - self._mini_start_ly
    if not self._mini_moved and (math.abs(off_x) >= MINI_DRAG_THRESH or math.abs(off_y) >= MINI_DRAG_THRESH) then
        self._mini_moved = true
    end
    if self._mini_moved then
        local sw = (love and love.graphics and love.graphics.getWidth and love.graphics.getWidth()) or 960
        local sh = (love and love.graphics and love.graphics.getHeight and love.graphics.getHeight()) or 540
        local nx, ny = clamp_mini_pos(self, self._mini_orig_x + off_x, self._mini_orig_y + off_y, sw / s, sh / s)
        self.mini_x, self.mini_y = nx, ny
        if self._mini_rect then
            self._mini_rect.x, self._mini_rect.y = nx, ny
        end
    end
    return true
end

function overlay:mousereleased(x, y, button)
    if self._mini_drag and button == 1 then
        local was_moved = self._mini_moved
        self._mini_drag = false
        self._mini_moved = false
        self._consumed_down = false
        if not was_moved then
            self.visible = true
            ui.play_sfx("open")
            if self.on_action then self.on_action("show") end
        elseif self.on_action then
            self.on_action("hud_mini_moved")
        end
        return true
    end
    if self._ptt_btn_down and button == 1 then
        self._ptt_btn_down = false
        self._consumed_down = false
        if self.on_action then self.on_action("mp_voice_ptt_up") end
        return true
    end
    if self._consumed_down and button == 1 then
        self._consumed_down = false
        return true
    end
    return false
end

local function draw_collapsed_badge(self, G, T, font_map, s, vsw, vsh, mx, my)
    if self._mini_drag and (not proto.is_android()) and love and love.mouse and love.mouse.isDown and not love.mouse.isDown(1) then
        self._mini_drag, self._mini_moved, self._consumed_down = false, false, false
    end
    local mr = self:get_mini_rect(vsw, vsh)
    local bx, by, bw, bh = mr.x, mr.y, mr.w, mr.h
    local hover = (not proto.is_android()) and (mx >= bx and mx <= bx + bw and my >= by and my <= by + bh)
    local drag_on = self._mini_drag and self._mini_moved

    local top_c, bot_c = T.wood_top, T.wood_bot
    local rim_c = (hover or drag_on) and T.gold_bright or T.gold_mid
    if s.mp_active then
        if s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED" then
            top_c, bot_c, rim_c = { 172, 36, 34, 246 }, { 102, 18, 18, 246 }, { 255, 168, 152, 255 }
        elseif s.mp_phase == "WAIT_RECONNECT" then
            top_c, bot_c = { 166, 102, 24, 246 }, { 102, 58, 12, 246 }
        elseif s.mp_phase == "CATCHING_UP" then
            top_c, bot_c = { 30, 96, 142, 246 }, { 16, 56, 92, 246 }
        elseif s.mp_phase == "PAUSED" then
            top_c, bot_c = { 48, 92, 54, 244 }, { 28, 58, 32, 244 }
        end
    end

    G.setColor(0, 0, 0, drag_on and 145 or 106)
    G.rectangle("fill", bx - 1, by + (drag_on and 4 or 3), bw + 2, bh + 1, 9, 9)
    ui.draw_vgrad_rect(bx, by, bw, bh, top_c, bot_c, 8)
    G.setColor(255, 224, 166, (hover or drag_on) and 126 or 78)
    G.setLineWidth(1.2)
    G.line(bx + 8, by + 2, bx + bw - 8, by + 2)
    G.setColor(rim_c[1], rim_c[2], rim_c[3], (hover or drag_on) and 255 or 218)
    G.setLineWidth((hover or drag_on) and 2.0 or 1.6)
    G.rectangle("line", bx, by, bw, bh, 8, 8)

    local ty = by + (bh - ui.font_h(font_map.tiny_bold)) * 0.5
    if s.mp_active then
        local ok_link = (s.mp_phase ~= "DISCONNECTED" and s.mp_phase ~= "WAIT_RECONNECT" and s.mp_phase ~= "DESYNC")
        ui.draw_ping_dot(bx + 12, by + bh * 0.5, s.mp_rtt or 0, ok_link)
        local is_p1 = (s.mp_pid == 1)
        local lbl = (s.mp_phase == "PAUSED") and "暂停" or (is_p1 and "1P" or "2P")
        local fg = (s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED") and { 255, 236, 176, 255 }
            or (is_p1 and T.p1_light or T.p2_light)
        ui.print_shadow(lbl, bx + 20, ty, fg, bw - 24, "center", nil, font_map.tiny_bold)
    else
        G.setColor(T.ok_bright[1], T.ok_bright[2], T.ok_bright[3], 230)
        G.circle("fill", bx + 11, by + bh * 0.5, 3.2)
        ui.print_shadow("联机", bx + 17, ty, T.gold_bright, bw - 20, "center", nil, font_map.tiny_bold)
    end
    self.buttons = {}
end

local function draw_voice_popover(self, G, T, font_map, s, vsw, x, y, w, h, voice_btn_cx, ptt_btn_offset_y, is_mob, add_btn)
    local pw_v, ph_v = 286, 152
    local px_v = math.floor((voice_btn_cx or (x + w * 0.6)) - pw_v * 0.5)
    px_v = math.max(8, math.min(vsw - pw_v - 8, px_v))
    local py_v = y + h + 6 + ptt_btn_offset_y
    self._last_voice_panel = { x = px_v, y = py_v, w = pw_v, h = ph_v }

    G.setColor(0, 0, 0, 128)
    G.rectangle("fill", px_v - 2, py_v + 4, pw_v + 4, ph_v + 3, 10, 10)
    ui.draw_vgrad_rect(px_v, py_v, pw_v, ph_v, T.wood_top, T.wood_bot, 9)
    G.setColor(255, 218, 156, 82)
    G.setLineWidth(1.3)
    G.line(px_v + 10, py_v + 2, px_v + pw_v - 10, py_v + 2)
    G.setColor(T.ink_dark[1], T.ink_dark[2], T.ink_dark[3], 255)
    G.setLineWidth(2.0)
    G.rectangle("line", px_v, py_v, pw_v, ph_v, 9, 9)

    ui.print_shadow("语音调音台", px_v + 12, py_v + 7, T.gold_bright, nil, nil, nil, font_map.small_bold)
    local loc_lvl = math.max(0, math.min(1, tonumber(s.mp_voice_local_lvl) or 0))
    local mtr_x, mtr_y, mtr_w, mtr_h = px_v + 92, py_v + 11, 96, 8
    G.setColor(20, 11, 5, 225)
    G.rectangle("fill", mtr_x, mtr_y, mtr_w, mtr_h, 4, 4)
    if loc_lvl > 0.02 then
        G.setColor(94, 232, 142, 230)
        G.rectangle("fill", mtr_x + 1, mtr_y + 1, math.max(2, math.floor((mtr_w - 2) * loc_lvl)), mtr_h - 2, 3, 3)
    end
    G.setColor(148, 104, 48, 175)
    G.setLineWidth(1)
    G.rectangle("line", mtr_x, mtr_y, mtr_w, mtr_h, 4, 4)
    add_btn("mp_voice_panel_close", "×", px_v + pw_v - 28, py_v + 5, 20, 20, "crimson", { tiny = true, radius = 5 })

    local function draw_vol_row(ry, label, val, vmin, vmax, muted_flag, id_down, id_set, id_up, fill_top, fill_bot, extra_w)
        ui.print_shadow(label, px_v + 12, ry + 4, { 244, 224, 186, 255 }, nil, nil, nil, font_map.tiny_bold)
        local bx0 = px_v + 60
        add_btn(id_down, "-", bx0, ry, 22, 22, "wood", { tiny = true, radius = 5 })
        local bar_x = bx0 + 26
        local bar_w = pw_v - 60 - 26 - 26 - 12 - (extra_w or 0)
        local bar_y, bar_h = ry + 3, 16
        local frac = muted_flag and 0 or math.max(0, math.min(1, (val - vmin) / math.max(0.01, vmax - vmin)))
        G.setColor(22, 12, 5, 235)
        G.rectangle("fill", bar_x, bar_y, bar_w, bar_h, 5, 5)
        local fw = math.floor((bar_w - 2) * frac)
        if fw > 1 then
            ui.draw_vgrad_rect(bar_x + 1, bar_y + 1, fw, bar_h - 2, fill_top, fill_bot, 4)
        end
        G.setColor(168, 122, 56, 205)
        G.setLineWidth(1.1)
        G.rectangle("line", bar_x, bar_y, bar_w, bar_h, 5, 5)
        local pct_txt = muted_flag and "已静音" or string.format("%d%%", math.floor(val * 100 + 0.5))
        ui.print_shadow(pct_txt, bar_x, bar_y + (bar_h - ui.font_h(font_map.tiny_bold)) * 0.5,
            { 255, 250, 234, 255 }, bar_w, "center", nil, font_map.tiny_bold)
        add_btn(id_set, "", bar_x, ry, bar_w, 22, "slider_hit", {
            slider_min = vmin, slider_max = vmax, no_draw = true,
        })
        add_btn(id_up, "+", bar_x + bar_w + 4, ry, 22, 22, "wood", { tiny = true, radius = 5 })
        return bar_x + bar_w + 30
    end

    draw_vol_row(py_v + 33, "我的麦", tonumber(s.mp_voice_mic_gain) or 1.0, 0.4, 2.0, s.mp_voice_mode == "mute",
        "mp_voice_mic_down", "mp_voice_mic_set", "mp_voice_mic_up", T.emerald_top, T.emerald_bot, 0)
    local peer_m = (s.mp_voice_peer_muted == true)
    local mute_x = draw_vol_row(py_v + 61, "队友音", tonumber(s.mp_voice_peer_vol) or 1.0, 0.0, 1.8, peer_m,
        "mp_voice_peer_down", "mp_voice_peer_set", "mp_voice_peer_up",
        { 84, 186, 255, 255 }, { 34, 112, 188, 255 }, 44)
    add_btn("mp_voice_peer_mute", peer_m and "恢复" or "静音", mute_x, py_v + 61, 40, 22,
        peer_m and "crimson" or "wood", { tiny = true, radius = 5 })

    local v_mode, mx0, mw0 = s.mp_voice_mode or "ptt", px_v + 60, 68
    ui.print_shadow("收音", px_v + 12, py_v + 94, { 244, 224, 186, 255 }, nil, nil, nil, font_map.tiny_bold)
    local m_items = { { "ptt", is_mob and "按住讲" or "按V麦" }, { "vad", "自由麦" }, { "mute", "闭麦" } }
    for i, mi in ipairs(m_items) do
        local mst = (v_mode == mi[1]) and ((mi[1] == "mute") and "crimson" or "battle") or "wood"
        add_btn("mp_voice_set_mode", mi[2], mx0 + (i - 1) * (mw0 + 5), py_v + 90, mw0, 23, mst, { tiny = true, arg = mi[1], radius = 5 })
    end
    local v_ind = s.mp_voice_style or "compact"
    ui.print_shadow("说话标", px_v + 12, py_v + 123, { 244, 224, 186, 255 }, nil, nil, nil, font_map.tiny_bold)
    local s_items = { { "compact", "极简微标" }, { "off", "关闭提示" }, { "card", "醒目大卡" } }
    for i, si in ipairs(s_items) do
        add_btn("mp_voice_style_set", si[2], mx0 + (i - 1) * (mw0 + 5), py_v + 119, mw0, 23,
            (v_ind == si[1]) and "azure" or "wood", { tiny = true, arg = si[1], radius = 5 })
    end
end

local function draw_voice_speaking_indicators(G, T, font_map, s, x, y, w, h, ptt_btn_offset_y)
    local v_ind = s.mp_voice_style or "compact"
    local show1 = (s.mp_voice_p1_talk == true)
    local show2 = (s.mp_voice_p2_talk == true)
    local count = (show1 and 1 or 0) + (show2 and 1 or 0)
    if count <= 0 then return end

    if v_ind == "compact" then
        local chip_y = y + h + 4 + ptt_btn_offset_y
        local cw_c, ch_c, gap_c = 56, 17, 6
        local cx_c = math.floor(x + (w - (count * cw_c + (count - 1) * gap_c)) * 0.5)
        local t_now = love.timer and love.timer.getTime() or 0

        local function draw_compact_chip(px_c, pid_c, lvl_c)
            local p1 = (pid_c == 1)
            local dot_col = p1 and { 104, 206, 255, 220 } or { 255, 134, 130, 220 }
            local txt_col = p1 and { 188, 232, 255, 230 } or { 255, 204, 202, 230 }
            G.setColor(16, 12, 9, 148)
            G.rectangle("fill", px_c, chip_y, cw_c, ch_c, 8, 8)
            G.setColor(dot_col[1], dot_col[2], dot_col[3], 130)
            G.setLineWidth(1.0)
            G.rectangle("line", px_c, chip_y, cw_c, ch_c, 8, 8)
            G.setColor(dot_col[1], dot_col[2], dot_col[3], 225)
            G.circle("fill", px_c + 8, chip_y + ch_c * 0.5, 2.5)
            ui.text(p1 and "1P" or "2P", px_c + 14, chip_y + (ch_c - ui.font_h(font_map.tiny_bold)) * 0.5,
                txt_col, font_map.tiny_bold)
            local lv = math.max(0.15, math.min(1.0, tonumber(lvl_c) or 0.4))
            for bi = 1, 3 do
                local wave = 0.55 + 0.45 * math.abs(math.sin(t_now * 9.0 + bi * 1.4))
                local bh_b = math.max(2, math.floor((ch_c - 6) * lv * wave + 0.5))
                G.setColor(dot_col[1], dot_col[2], dot_col[3], 200)
                G.rectangle("fill", px_c + 36 + (bi - 1) * 5, chip_y + math.floor((ch_c - bh_b) * 0.5), 2.5, bh_b, 1, 1)
            end
        end

        if show1 then draw_compact_chip(cx_c, 1, s.mp_voice_p1_lvl or 0.5); cx_c = cx_c + cw_c + gap_c end
        if show2 then draw_compact_chip(cx_c, 2, s.mp_voice_p2_lvl or 0.5) end
    elseif v_ind == "card" then
        local bubble_y = y + h + 6 + ptt_btn_offset_y
        local bw, bh, gap = 166, 34, 12
        local bx = math.floor(x + (w - (count * bw + (count - 1) * gap)) * 0.5)

        local function draw_speaker_bubble(px_b, pid_b, hero_idx, lvl)
            local p1 = (pid_b == 1)
            local top_col = p1 and { 26, 62, 108, 238 } or { 112, 26, 28, 238 }
            local bot_col = p1 and { 16, 38, 68, 242 } or { 68, 14, 16, 242 }
            local rim_col = p1 and { 104, 214, 255, 245 } or { 255, 142, 136, 245 }
            G.setColor(0, 0, 0, 118)
            G.rectangle("fill", px_b - 1, bubble_y + 3, bw + 2, bh + 1, 9, 9)
            ui.draw_vgrad_rect(px_b, bubble_y, bw, bh, top_col, bot_col, 8)
            ui.draw_speaking_glow(px_b, bubble_y, bw, bh, 8, { 98, 246, 152, 255 }, lvl)
            G.setColor(rim_col[1], rim_col[2], rim_col[3], 220)
            G.setLineWidth(1.4)
            G.rectangle("line", px_b, bubble_y, bw, bh, 8, 8)
            ui.draw_hero_big_portrait(hero_idx, px_b + 5, bubble_y + 3, 28, 28, {
                radius = 5, pad = 1, border = T.gold_mid, border_w = 1.4,
            })
            ui.print_shadow(p1 and "1P 蓝方" or "2P 红方", px_b + 38, bubble_y + 4,
                p1 and T.p1_light or T.p2_light, nil, nil, nil, font_map.tiny_bold)
            ui.print_shadow("正在语音...", px_b + 38, bubble_y + 18,
                { 216, 255, 224, 240 }, nil, nil, nil, font_map.tiny)
            ui.draw_voice_eq(px_b + bw - 38, bubble_y + 7, 30, 20, lvl, true,
                { 122, 255, 168, 255 }, p1 and { 84, 206, 255, 235 } or { 255, 206, 108, 235 })
        end

        if show1 then draw_speaker_bubble(bx, 1, s.mp_hero1 or 53, s.mp_voice_p1_lvl or 0.6); bx = bx + bw + gap end
        if show2 then draw_speaker_bubble(bx, 2, s.mp_hero2 or 54, s.mp_voice_p2_lvl or 0.6) end
    end
end

local function draw_battle_status_row(G, T, font_map, s, x, y, w, is_p1, has_catchup_bar, is_alert, show_wait_alert, add_btn)
    local tick = s.tick or 0
    local catchup_target = s.mp_catchup_target or 0
    local hash_hex = s.last_hash or "--------"
    if has_catchup_bar then
        local px_b, py_b, pw_b, ph_b = x + 16, y + 44, w - 32, 14
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
        ui.print_shadow(string.format("高速追帧重连 %d / %d 帧", tick, catchup_target),
            px_b, py_b + (ph_b - ui.font_h(font_map.tiny_bold)) * 0.5, { 255, 250, 230, 255 }, pw_b, "center", nil, font_map.tiny_bold)
    elseif is_alert then
        local phase_cn = PHASE_LABELS[s.mp_phase] or tostring(s.mp_phase)
        if s.mp_phase == "WAIT_RECONNECT" then
            local rem = tonumber(s.mp_reconnect_remain) or 0
            local rmsg
            if s.mp_direct_reconnect and not is_p1 then
                rmsg = string.format("樱花断线保护 · 每2秒自动热续传中 (剩余 %ds) · 帧 %d", rem, tick)
            elseif rem > 0 then
                rmsg = string.format("等待队友热续传/重连 (剩余 %ds) · 帧 %d", rem, tick)
            else
                rmsg = string.format("%s · 帧 %d · 校验 #%s", phase_cn, tick, hash_hex)
            end
            ui.print_shadow(rmsg, x + 16, y + 43, T.gold_bright, w - 98, "left", nil, font_map.tiny_bold)
            add_btn("mp_abort_reconnect", "放弃等待", x + w - 80, y + 39, 64, 20, "crimson", { tiny = true })
        else
            local wt = show_wait_alert and "网络波动，正在等待队友指令..." or phase_cn
            ui.print_shadow(string.format("%s · 帧 %d · 校验 #%s", wt, tick, hash_hex),
                x + 16, y + 43, T.gold_bright, w - 32, "center", nil, font_map.tiny_bold)
        end
    end
end

local function draw_battle_hud(self, G, T, font_map, s, vsw, mx, my, add_btn)
    local catchup_target = s.mp_catchup_target or 0
    local has_catchup_bar = (s.mp_phase == "CATCHING_UP" and catchup_target > 0)
    -- Debounce brief 16~450ms network micro-jitter so the Battle HUD NEVER flashes/strobes!
    local now_hud = (love.timer and love.timer.getTime()) or 0
    if s.mp_waiting and (s.mp_wait_secs or 0) >= 0.50 then
        self._wait_banner_until = now_hud + 0.35
    elseif not s.mp_waiting and (self._wait_banner_until or 0) <= now_hud then
        self._wait_banner_until = 0
    end
    local show_wait_alert = (s.mp_waiting and (s.mp_wait_secs or 0) >= 0.50) or (now_hud < (self._wait_banner_until or 0))
    local is_alert = (s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED" or s.mp_phase == "WAIT_RECONNECT" or show_wait_alert)
    local is_indep = (s.mp_econ == "independent")
    local show_marks_btn = (s.mp_tower_mode == "owned")
    local show_voice_btn = (s.mp_voice_ok == true)
    if not show_voice_btn then self.voice_panel_open = false end

    local w = math.min(show_voice_btn and 634 or 538, vsw - 16)
    local x = math.max(8, math.floor((vsw - w) / 2))
    if vsw >= 920 and x < 180 then x = 180 end
    local y = 7
    local h = has_catchup_bar and 66 or (is_alert and 64 or 42)

    -- Hanging chains + drop shadow + carved oak plaque
    G.setColor(24, 22, 20, 235)
    G.rectangle("fill", x + 32, 0, 4, y + 2)
    G.rectangle("fill", x + w - 36, 0, 4, y + 2)
    G.setColor(126, 134, 144, 210)
    G.rectangle("fill", x + 33, 0, 2, y + 1)
    G.rectangle("fill", x + w - 35, 0, 2, y + 1)
    G.setColor(0, 0, 0, 112)
    G.rectangle("fill", x - 2, y + 4, w + 4, h + 3, 11, 11)

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
    ui.draw_brass_rivet(x + 9, y + 21, 3.2)
    ui.draw_brass_rivet(x + w - 9, y + 21, 3.2)

    -- Top row controls
    local cx, cy = x + 17, y + 8
    local is_p1 = (s.mp_pid == 1)
    ui.draw_pill(cx, cy + 2, 28, 21, is_p1 and "1P" or "2P",
        is_p1 and T.p1_top or T.p2_top,
        is_p1 and T.p1_border or T.p2_border,
        { 255, 255, 255, 255 }, font_map.tiny_bold)
    cx = cx + 33

    local gw = is_indep and 98 or 70
    G.setColor(24, 13, 6, 228)
    G.rectangle("fill", cx, cy + 1, gw, 23, 6, 6)
    G.setColor(148, 104, 48, 200)
    G.setLineWidth(1.2)
    G.rectangle("line", cx, cy + 1, gw, 23, 6, 6)
    ui.draw_coin_icon(cx + 10, cy + 12.5, 5.0)
    local g_ty = cy + 1 + (23 - ui.font_h(font_map.small_bold)) * 0.5
    if is_indep then
        ui.print_shadow(tostring(s.mp_g1 or 0), cx + 19, g_ty, T.p1_light, nil, nil, nil, font_map.small_bold)
        ui.text("|", cx + 52, g_ty, { 240, 210, 155, 110 }, font_map.small)
        ui.print_shadow(tostring(s.mp_g2 or 0), cx + 60, g_ty, T.p2_light, nil, nil, nil, font_map.small_bold)
    else
        ui.print_shadow(tostring(s.mp_g1 or 0), cx + 21, g_ty, T.gold_bright, nil, nil, nil, font_map.small_bold)
    end
    cx = cx + gw + 5

    if is_indep then
        add_btn("mp_send_gold", "转50", cx, cy, 38, 24, "wood", { tiny = true, fg = T.gold_bright })
        cx = cx + 42
    end
    local spd = s.mp_speed or 1
    add_btn("mp_speed", string.format("%dx", spd), cx, cy, 28, 24, (spd == 2) and "battle" or "wood", { tiny = true })
    cx = cx + 32
    local is_paused = (s.mp_phase == "PAUSED")
    add_btn("mp_pause", is_paused and "继续" or "暂停", cx, cy, 36, 24, is_paused and "battle" or "wood", { tiny = true })
    cx = cx + 40
    if show_marks_btn then
        local m_on = (s.mp_tower_marks ~= false)
        add_btn("mp_tower_marks", "塔标", cx, cy, 34, 24, "wood", {
            tiny = true, fg = m_on and T.ok_bright or { 196, 174, 140, 150 },
        })
        cx = cx + 38
    end

    local voice_btn_cx = nil
    if show_voice_btn then
        local v_mode = s.mp_voice_mode or "ptt"
        local my_talk = (is_p1 and s.mp_voice_p1_talk) or ((not is_p1) and s.mp_voice_p2_talk)
        local v_style = (v_mode == "mute") and "crimson" or "wood"
        local v_fg = my_talk and T.ok_bright
            or ((v_mode == "vad") and { 196, 246, 206, 255 } or ((v_mode == "mute") and { 255, 220, 216, 255 } or T.gold_bright))
        voice_btn_cx = cx + 44
        add_btn("mp_voice_mode", s.mp_voice_label or "按V麦", cx, cy, 50, 24, v_style, { tiny = true, fg = v_fg })
        cx = cx + 54
        add_btn("mp_voice_panel", "调音", cx, cy, 32, 24, self.voice_panel_open and "azure" or "wood", {
            tiny = true, fg = self.voice_panel_open and { 242, 250, 255, 255 } or T.gold_bright,
        })
        cx = cx + 36
    end

    add_btn("mp_return_lobby", "战桌", cx, cy, 36, 24, "azure", { tiny = true })
    cx = cx + 40
    local leave_arm = now_hud < (self._leave_confirm_until or 0)
    add_btn("mp_leave", leave_arm and "确认?" or "退出", cx, cy, 36, 24, "crimson", {
        tiny = true, fg = leave_arm and { 255, 248, 136, 255 } or nil,
    })
    cx = cx + 40
    add_btn("hide", "隐", cx, cy, 22, 24, "wood", { tiny = true })

    local rtt, d_ms = s.mp_rtt or 0, tonumber(s.mp_delay_ms) or 100
    local pill_w = 78
    local pill_x = x + w - 15 - pill_w
    G.setColor(22, 12, 5, 225)
    G.rectangle("fill", pill_x, cy + 1, pill_w, 23, 6, 6)
    G.setColor(is_p1 and 188 or 136, is_p1 and 138 or 94, is_p1 and 62 or 44, 210)
    G.setLineWidth(1.2)
    G.rectangle("line", pill_x, cy + 1, pill_w, 23, 6, 6)
    ui.draw_ping_dot(pill_x + 9, cy + 12.5, rtt, s.mp_phase ~= "DISCONNECTED" and s.mp_phase ~= "WAIT_RECONNECT")
    local rtt_ty = cy + 1 + (23 - ui.font_h(font_map.tiny_bold)) * 0.5
    ui.print_shadow(string.format("%d·%d", rtt, d_ms), pill_x + 16, rtt_ty, T.ok_bright, pill_w - 18, "center", nil, font_map.tiny_bold)
    add_btn("mp_cycle_delay", "", pill_x, cy, pill_w, 24, "wood", { no_draw = true })

    draw_battle_status_row(G, T, font_map, s, x, y, w, is_p1, has_catchup_bar, is_alert, show_wait_alert, add_btn)

    local is_mob = proto.is_android()
    local hud_hover = (not is_mob) and (mx >= x and mx <= x + w and my >= y and my <= y + h)
    local ptt_btn_offset_y = 0
    if is_mob and s.mp_voice_ok and s.mp_voice_mode == "ptt" and not has_catchup_bar and not is_alert then
        local ptt_w, ptt_h = 114, 28
        add_btn("mp_voice_ptt", s.mp_voice_ptt and "正在讲话..." or "按住说话",
            math.floor(x + (w - ptt_w) * 0.5), y + h + 6, ptt_w, ptt_h,
            s.mp_voice_ptt and "battle" or "azure", { small = true, radius = 8 })
        ptt_btn_offset_y = ptt_h + 6
    end

    self._last_voice_panel = nil
    if self.voice_panel_open and show_voice_btn then
        draw_voice_popover(self, G, T, font_map, s, vsw, x, y, w, h, voice_btn_cx, ptt_btn_offset_y, is_mob, add_btn)
    elseif hud_hover and not has_catchup_bar and not is_alert then
        local tip_y = y + h + 5
        ui.draw_parchment_card(x + 12, tip_y, w - 24, 24, { radius = 6 })
        local net_lbl = s.mp_online and ("公网 #" .. tostring(s.mp_room_code or "----")) or "樱花/局域网"
        local phase_cn = PHASE_LABELS[s.mp_phase] or tostring(s.mp_phase)
        ui.text(string.format("%s · %s · √%d · 转50(右键转200) · 右侧点延迟切缓冲 · 战桌不退房",
            net_lbl, phase_cn, s.mp_sync_ok or 0),
            x + 16, tip_y + (24 - ui.font_h(font_map.tiny)) * 0.5, T.ink_text, font_map.tiny, w - 32, "center")
    elseif s.mp_voice_ok and (s.mp_voice_p1_talk or s.mp_voice_p2_talk) then
        draw_voice_speaking_indicators(G, T, font_map, s, x, y, w, h, ptt_btn_offset_y)
    end
    return x, y, w, h
end

local function draw_idle_or_replay_hud(G, T, font_map, s, vsw, add_btn)
    local mode = s.mode or "IDLE"
    local tick, max_tick = s.tick or 0, s.max_tick or 0
    local sock_txt = s.socket_ok and "网络正常" or "网络异常"
    local extra = s.extra or ""
    local has_replay_bar = (mode == "REPLAYING" and max_tick > 0)
    local w = math.min(448, vsw - 20)
    local x, y = 10, 10
    local h = has_replay_bar and 88 or 72

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
        { 152, 34, 28, 245 }, T.gold_mid, T.gold_bright, font_map.tiny_bold)
    local st_ty = y + 7 + (19 - ui.font_h(font_map.tiny)) * 0.5
    ui.print_shadow(string.format("%s · %s %s", m_cn, sock_txt, extra), x + 108, st_ty, { 255, 242, 206, 245 }, nil, nil, nil, font_map.tiny)

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
        local is_mob = proto.is_android()
        local bh, rw, hw = is_mob and 28 or 26, is_mob and 72 or 78, is_mob and 72 or 74
        add_btn("lobby", is_mob and "联机大厅" or "联机大厅 (F10)", bx, by, 134, bh, "battle", { small = true })
        add_btn("record", is_mob and "录制" or "录制 (F6)", bx + 142, by, rw, bh, "crimson", { small = true })
        local nx = bx + 150 + rw
        if s.has_replay then
            add_btn("replay", is_mob and "回放" or "回放 (F7)", nx, by, rw, bh, "azure", { small = true })
            nx = nx + rw + 8
        end
        add_btn("hide", is_mob and "隐藏" or "隐藏 (F9)", nx, by, hw, bh, "wood", { small = true })
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
    return x, y, w, h
end

function overlay:draw()
    if not love.graphics then return end

    local G, T = love.graphics, ui.THEME
    local prev_font = G.getFont()
    local r, g, b, a = G.getColor()
    local prev_blend = G.getBlendMode()
    local sw = (G.getWidth and G.getWidth()) or 960
    local sh = (G.getHeight and G.getHeight()) or 540
    local scale = ui.compute_hud_scale(sw, sh)
    self._ui_scale = scale
    local vsw, vsh = sw / scale, sh / scale
    local font_map = ui.make_font_map(scale)
    local s = self.state or {}
    local raw_mx, raw_my = 0, 0
    if love.mouse and love.mouse.getPosition then raw_mx, raw_my = love.mouse.getPosition() end
    local mx, my = raw_mx / scale, raw_my / scale

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")
    ui.begin_transform(scale, 0, 0)

    if not self.visible then
        draw_collapsed_badge(self, G, T, font_map, s, vsw, vsh, mx, my)
        ui.end_transform()
        G.pop()
        if prev_font then G.setFont(prev_font) end
        G.setColor(r, g, b, a)
        G.setBlendMode(prev_blend)
        return
    end

    local btns = {}
    local function add_btn(id, label, bx, by, bw, bh, style, extra_b)
        local btn = { id = id, label = label, x = bx, y = by, w = bw, h = bh, style = style or "wood", radius = 6 }
        if extra_b then for k, v in pairs(extra_b) do btn[k] = v end end
        btns[#btns + 1] = btn
    end

    local x, y, w, h
    if s.mp_active then
        x, y, w, h = draw_battle_hud(self, G, T, font_map, s, vsw, mx, my, add_btn)
    else
        x, y, w, h = draw_idle_or_replay_hud(G, T, font_map, s, vsw, add_btn)
    end

    self.buttons = btns
    local allow_hover = not proto.is_android()
    for _, btn in ipairs(btns) do
        if not btn.no_draw then
            local hover = allow_hover and (mx >= btn.x and mx <= btn.x + btn.w and my >= btn.y and my <= btn.y + btn.h)
            ui.draw_button(btn, hover, font_map)
        end
    end

    self._last_bar = { x = x, y = y, w = w, h = h, scale = scale }
    ui.end_transform()

    G.pop()
    if prev_font then G.setFont(prev_font) end
    G.setColor(r, g, b, a)
    G.setBlendMode(prev_blend)
end

-- Always-on-top contextual Toast renderer (docked below Lobby War-Table rim so zero choices are ever covered, or below HUD when closed)
function overlay:draw_toast(lobby)
    if not self.toast or not love.graphics then
        self._last_toast_rect = nil
        return
    end
    local now = love.timer and love.timer.getTime() or 0
    local remain = (self.toast_until or 0) - now
    if remain <= 0 then
        self._last_toast_rect = nil
        return
    end

    local lobby_open = (lobby ~= nil and lobby.open == true)

    local G = love.graphics
    local T = ui.THEME
    local prev_font = G.getFont()
    local r, g, b, a = G.getColor()
    local prev_blend = G.getBlendMode()

    local alpha_mul = math.max(0, math.min(1, remain / 0.25))
    local function ca(col, override_a)
        return { col[1], col[2], col[3], math.floor((override_a or col[4] or 255) * alpha_mul) }
    end

    -- Semantic accent color based on toast text
    local msg = self.toast
    local accent = { 234, 174, 58, 255 } -- warm gold (info)
    local border_col = { 164, 114, 42, 255 }
    if msg:find("失败", 1, true) or msg:find("拒绝", 1, true) or msg:find("超时", 1, true)
        or msg:find("异常", 1, true) or msg:find("断开", 1, true) or msg:find("未找到", 1, true)
        or msg:find("为空", 1, true) or msg:find("请先", 1, true) or msg:find("请等待", 1, true)
        or msg:find("至少", 1, true) or msg:find("最多", 1, true) or msg:find("不匹配", 1, true)
        or msg:find("警告", 1, true) or msg:find("被占用", 1, true) then
        accent = { 226, 74, 68, 255 }
        border_col = { 176, 54, 48, 255 }
    elseif msg:find("已连接", 1, true) or msg:find("已创建", 1, true) or msg:find("已加入", 1, true)
        or msg:find("已粘贴", 1, true) or msg:find("就绪", 1, true) or msg:find("已开启", 1, true)
        or msg:find("已恢复", 1, true) or msg:find("已切至", 1, true) or msg:find("已是最新", 1, true) then
        accent = { 62, 198, 108, 255 }
        border_col = { 54, 138, 72, 255 }
    end

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")

    if lobby_open then
        -- Anchor cleanly INSIDE the bottom-center of the Lobby War-Table!
        local sw, sh = G.getWidth(), G.getHeight()
        local scale = lobby._ui_scale or ui.compute_lobby_scale(sw, sh)
        local ox = lobby._ui_ox or math.floor((sw - 780 * scale) * 0.5)
        local oy = lobby._ui_oy or math.floor((sh - 486 * scale) * 0.5 + 12 * scale)
        local font_map = ui.make_font_map(scale)
        local tf = font_map.small_bold or font_map.small

        ui.begin_transform(scale, ox, oy)

        local max_w = 640
        local pad_x = 18
        local dot_space = 16
        local text_w = ui.font_w(tf, msg)
        local tw = math.max(240, math.min(max_w, math.ceil(text_w + pad_x * 2 + dot_space + 10)))
        local inner_tw = tw - pad_x * 2 - dot_space

        local nlines = 1
        if tf and tf.getWrap then
            local _, wrapped = tf:getWrap(msg, math.max(80, math.floor(inner_tw * scale)))
            if type(wrapped) == "table" and #wrapped > 1 then nlines = #wrapped end
        end
        local fh = ui.font_h(tf)
        local th = math.max(28, math.ceil(nlines * fh + 11))
        local tx = math.floor((780 - tw) * 0.5)
        local ty = math.min(476, math.floor((sh - 6 - oy) / scale - th))
        self._last_toast_rect = { x = ox + tx * scale, y = oy + ty * scale, w = tw * scale, h = th * scale }

        G.setColor(0, 0, 0, math.floor(138 * alpha_mul))
        G.rectangle("fill", tx - 2, ty + 4, tw + 4, th + 3, 10, 10)
        ui.draw_vgrad_rect(tx, ty, tw, th, ca({ 56, 33, 16, 248 }), ca({ 34, 19, 9, 250 }), 9)
        G.setColor(255, 226, 174, math.floor(72 * alpha_mul))
        G.setLineWidth(1.2)
        G.line(tx + 9, ty + 2, tx + tw - 9, ty + 2)
        G.setColor(border_col[1], border_col[2], border_col[3], math.floor(245 * alpha_mul))
        G.setLineWidth(2.0)
        G.rectangle("line", tx, ty, tw, th, 9, 9)

        local dx, dy = tx + pad_x + 3, ty + th * 0.5
        G.setColor(accent[1], accent[2], accent[3], math.floor(78 * alpha_mul))
        G.circle("fill", dx, dy, 6.2)
        G.setColor(accent[1], accent[2], accent[3], math.floor(255 * alpha_mul))
        G.circle("fill", dx, dy, 3.6)

        ui.print_shadow(msg, tx + pad_x + dot_space, ty + (th - nlines * fh) * 0.5,
            ca({ 255, 246, 222, 255 }), inner_tw, (nlines == 1) and "center" or "left", ca({ 16, 8, 3, 220 }), tf)
        ui.end_transform()
    else
        -- Lobby is closed: anchor directly under the active HUD / Toolbar (or top-center when collapsed)
        local bar = self.visible and self._last_bar or nil
        local sw, sh = G.getWidth(), G.getHeight()
        local scale = (bar and bar.scale) or self._ui_scale or ui.compute_hud_scale(sw, sh)
        local vsw = sw / scale
        local w = (bar and bar.w) or math.min(448, vsw - 20)
        local x = (bar and bar.x) or math.max(10, math.floor((vsw - w) * 0.5))
        local y = (bar and (bar.y + bar.h + 8)) or 10
        local font_map = ui.make_font_map(scale)
        local tf = font_map.small

        ui.begin_transform(scale, 0, 0)

        local nlines = 1
        if tf and tf.getWrap then
            local _, wrapped = tf:getWrap(msg, math.max(60, math.floor((w - 20) * scale)))
            if type(wrapped) == "table" and #wrapped > 1 then
                nlines = #wrapped
            end
        end
        local fh = ui.font_h(tf)
        local th = math.max(28, math.ceil(nlines * fh + 12))
        self._last_toast_rect = { x = x * scale, y = y * scale, w = w * scale, h = th * scale }
        ui.draw_parchment_card(x, y, w, th, {
            top = ca(T.parchment_card),
            bot = ca(T.parchment_card2),
            radius = 7,
            border = ca(border_col, 255),
            border_w = 1.8,
        })
        ui.text(msg, x + 10, y + (th - nlines * fh) * 0.5, ca(T.ink_text), tf, w - 20, "center")

        ui.end_transform()
    end

    G.pop()
    if prev_font then G.setFont(prev_font) end
    G.setColor(r, g, b, a)
    G.setBlendMode(prev_blend)
end

return overlay
