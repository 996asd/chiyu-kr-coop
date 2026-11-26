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
    _ui_scale = 1,
    _last_bar = nil,
    _last_toast_rect = nil,
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

function overlay:mousepressed(x, y, button)
    if not self.visible or button ~= 1 then
        return false
    end
    local s = self._ui_scale or 1
    local lx, ly = x / s, y / s
    for _, b in ipairs(self.buttons) do
        if lx >= b.x and lx <= b.x + b.w and ly >= b.y and ly <= b.y + b.h then
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

    local sw = (G.getWidth and G.getWidth()) or 960
    local sh = (G.getHeight and G.getHeight()) or 540
    local scale = ui.compute_hud_scale(sw, sh)
    self._ui_scale = scale
    local vsw = sw / scale

    local font_map = ui.make_font_map(scale)

    local s = self.state or {}
    local mode = s.mode or "IDLE"
    local tick = s.tick or 0
    local max_tick = s.max_tick or 0
    local catchup_target = s.mp_catchup_target or 0
    local hash_hex = s.last_hash or "--------"
    local sock_txt = s.socket_ok and "网络正常" or "网络异常"
    local extra = s.extra or ""

    local raw_mx, raw_my = 0, 0
    if love.mouse and love.mouse.getPosition then
        raw_mx, raw_my = love.mouse.getPosition()
    end
    local mx, my = raw_mx / scale, raw_my / scale

    local btns = {}
    local function add_btn(id, label, bx, by, bw, bh, style, extra_b)
        local btn = { id = id, label = label, x = bx, y = by, w = bw, h = bh, style = style or "wood", radius = 6 }
        if extra_b then
            for k, v in pairs(extra_b) do btn[k] = v end
        end
        btns[#btns + 1] = btn
    end

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")

    ui.begin_transform(scale, 0, 0)

    local x, y, w, h

    if s.mp_active then
        -- === 42px 铁皮手绘雕花木铁战地微章 HUD（高清等比自适应） ===
        local has_catchup_bar = (s.mp_phase == "CATCHING_UP" and catchup_target > 0)
        local is_alert = (s.mp_phase == "DESYNC" or s.mp_phase == "DISCONNECTED" or s.mp_phase == "WAIT_RECONNECT" or s.mp_waiting)
        local is_indep = (s.mp_econ == "independent")
        local show_marks_btn = (s.mp_tower_mode == "owned")
        local show_voice_btn = (s.mp_voice_ok == true)

        w = math.min(show_voice_btn and 542 or 488, vsw - 20)
        x = math.max(10, math.floor((vsw - w) / 2))
        if vsw >= 880 and x < 200 then x = 200 end
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
            { 255, 255, 255, 255 }, font_map.tiny_bold)
        cx = cx + 33

        -- Recessed Coin Ledger trough
        local gw = is_indep and 104 or 74
        G.setColor(24, 13, 6, 228)
        G.rectangle("fill", cx, cy + 1, gw, 23, 6, 6)
        G.setColor(148, 104, 48, 200)
        G.setLineWidth(1.2)
        G.rectangle("line", cx, cy + 1, gw, 23, 6, 6)
        ui.draw_coin_icon(cx + 11, cy + 12.5, 5.2)
        local g_ty = cy + 1 + (23 - ui.font_h(font_map.small_bold)) * 0.5
        if is_indep then
            ui.print_shadow(tostring(s.mp_g1 or 0), cx + 21, g_ty, T.p1_light, nil, nil, nil, font_map.small_bold)
            ui.text("|", cx + 56, g_ty, { 240, 210, 155, 110 }, font_map.small)
            ui.print_shadow(tostring(s.mp_g2 or 0), cx + 65, g_ty, T.p2_light, nil, nil, nil, font_map.small_bold)
        else
            ui.print_shadow(tostring(s.mp_g1 or 0), cx + 22, g_ty, T.gold_bright, nil, nil, nil, font_map.small_bold)
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

        if show_voice_btn then
            local v_mode = s.mp_voice_mode or "ptt"
            local my_talk = (is_p1 and s.mp_voice_p1_talk) or ((not is_p1) and s.mp_voice_p2_talk)
            local v_style = my_talk and "battle" or ((v_mode == "mute") and "crimson" or "wood")
            local v_fg = my_talk and { 255, 255, 240, 255 }
                or ((v_mode == "vad") and T.ok_bright or ((v_mode == "mute") and { 255, 220, 216, 255 } or T.gold_bright))
            add_btn("mp_voice_mode", s.mp_voice_label or "按V麦", cx, cy, 48, 24, v_style, {
                tiny = true, fg = v_fg,
            })
            cx = cx + 53
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
        local rtt_ty = cy + 1 + (23 - ui.font_h(font_map.tiny_bold)) * 0.5
        ui.print_shadow(string.format("%dms", rtt), pill_x + 19, rtt_ty, T.ok_bright, nil, nil, nil, font_map.tiny_bold)

        -- Alert / Catchup Row 2 (only shown when actually catching up or warning!)
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
            local wt = s.mp_waiting and "正在等待队友指令..." or phase_cn
            ui.print_shadow(string.format("%s · 帧 %d · 校验 #%s", wt, tick, hash_hex),
                x + 16, y + 43, T.gold_bright, w - 32, "center", nil, font_map.tiny_bold)
        end

        -- Hovering anywhere over the HUD bar gently reveals the Parchment Sync Telemetry Tooltip!
        local hud_hover = (mx >= x and mx <= x + w and my >= y and my <= y + h)
        if hud_hover and not has_catchup_bar and not is_alert then
            local tip_y = y + h + 5
            ui.draw_parchment_card(x + 24, tip_y, w - 48, 24, { radius = 6 })
            local net_lbl = s.mp_online and ("公网 #" .. tostring(s.mp_room_code or "----")) or "局域网 2P"
            local phase_cn = PHASE_LABELS[s.mp_phase] or tostring(s.mp_phase)
            ui.text(string.format("%s · %s · 校验√%d (#%s) · V按麦 · M闭麦 · Alt+左键打点",
                net_lbl, phase_cn, s.mp_sync_ok or 0, hash_hex),
                x + 28, tip_y + (24 - ui.font_h(font_map.tiny)) * 0.5, T.ink_text, font_map.tiny, w - 56, "center")
        elseif s.mp_voice_ok and (s.mp_voice_p1_talk or s.mp_voice_p2_talk) then
            -- Livestream Dual-Seat Speaking Bubbles right beneath the Battle HUD (zero corner overlap!)
            local bubble_y = y + h + 6
            local bw, bh = 166, 34
            local gap = 12
            local show1 = (s.mp_voice_p1_talk == true)
            local show2 = (s.mp_voice_p2_talk == true)
            local count = (show1 and 1 or 0) + (show2 and 1 or 0)
            local total_bw = count * bw + (count - 1) * gap
            local bx = math.floor(x + (w - total_bw) * 0.5)

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

                -- Mini framed hero portrait
                ui.draw_hero_big_portrait(hero_idx, px_b + 5, bubble_y + 3, 28, 28, {
                    radius = 5, pad = 1, border = T.gold_mid, border_w = 1.4,
                })
                ui.print_shadow(p1 and "1P 蓝方" or "2P 红方", px_b + 38, bubble_y + 4,
                    p1 and T.p1_light or T.p2_light, nil, nil, nil, font_map.tiny_bold)
                ui.print_shadow("正在语音...", px_b + 38, bubble_y + 18,
                    { 216, 255, 224, 240 }, nil, nil, nil, font_map.tiny)

                -- Live 5-bar broadcast equalizer
                ui.draw_voice_eq(px_b + bw - 38, bubble_y + 7, 30, 20, lvl, true,
                    { 122, 255, 168, 255 }, p1 and { 84, 206, 255, 235 } or { 255, 206, 108, 235 })
            end

            if show1 then
                draw_speaker_bubble(bx, 1, s.mp_hero1 or 53, s.mp_voice_p1_lvl or 0.6)
                bx = bx + bw + gap
            end
            if show2 then
                draw_speaker_bubble(bx, 2, s.mp_hero2 or 54, s.mp_voice_p2_lvl or 0.6)
            end
        end
    else
        -- === 单机 / 标题页 铁皮木框精简工具条（高清等比自适应） ===
        local has_replay_bar = (mode == "REPLAYING" and max_tick > 0)
        w = math.min(448, vsw - 20)
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

    -- Save HUD bar geometry so draw_toast() can anchor cleanly below it when lobby is closed
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
    if not lobby_open and not self.visible then
        self._last_toast_rect = nil
        return
    end

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
        or msg:find("至少", 1, true) or msg:find("最多", 1, true) or msg:find("不匹配", 1, true) then
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
            if type(wrapped) == "table" and #wrapped > 1 then
                nlines = #wrapped
            end
        end
        local fh = ui.font_h(tf)
        local th = math.max(28, math.ceil(nlines * fh + 11))
        local tx = math.floor((780 - tw) * 0.5)
        -- Dock cleanly onto the bottom dark-oak lip of the War-Table so ZERO interactive buttons,
        -- tower icons, hero cards, rules, or sub-modal choices are EVER covered!
        local max_ty = math.floor((sh - 6 - oy) / scale - th)
        local ty = math.min(476, max_ty)
        self._last_toast_rect = {
            x = ox + tx * scale,
            y = oy + ty * scale,
            w = tw * scale,
            h = th * scale,
        }

        -- Elevated warm dark-oak + parchment snackbar inside the War-Table
        G.setColor(0, 0, 0, math.floor(138 * alpha_mul))
        G.rectangle("fill", tx - 2, ty + 4, tw + 4, th + 3, 10, 10)
        ui.draw_vgrad_rect(tx, ty, tw, th, ca({ 56, 33, 16, 248 }), ca({ 34, 19, 9, 250 }), 9)
        -- Accent rim & subtle top bevel highlight
        G.setColor(255, 226, 174, math.floor(72 * alpha_mul))
        G.setLineWidth(1.2)
        G.line(tx + 9, ty + 2, tx + tw - 9, ty + 2)
        G.setColor(border_col[1], border_col[2], border_col[3], math.floor(245 * alpha_mul))
        G.setLineWidth(2.0)
        G.rectangle("line", tx, ty, tw, th, 9, 9)

        -- Glowing semantic indicator crystal on the left
        local dx = tx + pad_x + 3
        local dy = ty + th * 0.5
        G.setColor(accent[1], accent[2], accent[3], math.floor(78 * alpha_mul))
        G.circle("fill", dx, dy, 6.2)
        G.setColor(accent[1], accent[2], accent[3], math.floor(255 * alpha_mul))
        G.circle("fill", dx, dy, 3.6)

        -- Crisp bold message text
        local text_y = ty + (th - nlines * fh) * 0.5
        ui.print_shadow(msg, tx + pad_x + dot_space, text_y,
            ca({ 255, 246, 222, 255 }), inner_tw, (nlines == 1) and "center" or "left",
            ca({ 16, 8, 3, 220 }), tf)

        ui.end_transform()
    else
        -- Lobby is closed: anchor directly under the active HUD / Toolbar
        local bar = self._last_bar
        local sw, sh = G.getWidth(), G.getHeight()
        local scale = (bar and bar.scale) or ui.compute_hud_scale(sw, sh)
        local x = (bar and bar.x) or 10
        local y = (bar and (bar.y + bar.h + 8)) or 90
        local w = (bar and bar.w) or math.min(448, sw / scale - 20)
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
