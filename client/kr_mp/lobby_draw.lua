-- KR-MP Lobby Main Renderer (V2 Ironhide Native Parchment & Hand-Hewn Oak War-Table)
-- Delegates modal screens to lobby_draw_modals.lua; keeps every draw section small & readable.
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")
local lobby_prefs = require("kr_mp.lobby_prefs")
local ui = require("kr_mp.ui_assets")
local modals = require("kr_mp.lobby_draw_modals")

local M = {}

local PACK_TAG_STYLES = {
    kr6 = { bg = { 24, 54, 108, 230 }, border = { 136, 198, 255, 225 }, fg = { 228, 246, 255, 255 }, era = "6代·创世" },
    kr5 = { bg = { 46, 26, 12, 220 },  border = { 218, 166, 78, 220 },  fg = { 255, 232, 164, 255 }, era = "5代·联盟" },
    kr4 = { bg = { 76, 22, 64, 225 },  border = { 224, 128, 212, 215 }, fg = { 255, 226, 250, 255 }, era = "4代·复仇" },
    kr3 = { bg = { 30, 64, 38, 225 },  border = { 132, 214, 148, 210 }, fg = { 232, 255, 236, 255 }, era = "3代·起源" },
    kr2 = { bg = { 98, 56, 18, 225 },  border = { 242, 186, 94, 215 },  fg = { 255, 240, 204, 255 }, era = "2代·前线" },
    kr1 = { bg = { 96, 30, 30, 225 },  border = { 236, 132, 126, 210 }, fg = { 255, 230, 226, 255 }, era = "1代·初代" },
}

local DIFF_STYLES = {
    [1] = { name = "休闲",   stars = "★☆☆",  col = { 42, 118, 56, 255 },  star_col = { 255, 236, 172, 255 } },
    [2] = { name = "普通",   stars = "★★☆",  col = { 168, 92, 24, 255 },  star_col = { 255, 236, 172, 255 } },
    [3] = { name = "老兵",   stars = "★★★",  col = { 158, 32, 32, 255 },  star_col = { 255, 236, 172, 255 } },
    [4] = { name = "不可能", stars = "★★★★", col = { 126, 24, 148, 255 }, star_col = { 242, 168, 255, 255 } },
}

local function get_stage_pack_info(level_idx)
    local info = catalog.get_stage_info(level_idx)
    if info and info.pack_id then return info.pack_id end
    local idx = tonumber(level_idx) or 101
    if idx >= 251 then return "kr6"
    elseif idx >= 150 then return "kr4"
    elseif idx >= 101 then return "kr5"
    elseif idx <= 22 or idx == 86 then return "kr3"
    elseif idx <= 44 or idx >= 77 then return "kr2"
    else return "kr1" end
end

local function get_stage_clean_title(level_idx)
    local short = catalog.get_stage_short(level_idx)
    local num, name = short:match("^(%d+)%s+(.+)$")
    if num and name then
        return string.format("第 %s 关 · %s", num, name)
    end
    return catalog.get_stage_label(level_idx)
end

local function resolve_banner_title(lobby)
    if lobby.sub_modal == "guide" then return "新手指南 · 1分钟开黑"
    elseif lobby.view == "home" then return "联机酒馆 · 冒险驿站"
    elseif lobby.sub_modal == "stages" then return "战役舆图 · 选择关卡"
    elseif lobby.sub_modal == "hero1" then return "英雄殿 · 选 1P 主将"
    elseif lobby.sub_modal == "hero2" then return "英雄殿 · 选 2P 队友"
    elseif lobby.sub_modal == "towers" then return "皇家军械库 · 59选12"
    elseif lobby.sub_modal == "voice" then return "语音调音 · 麦克风设置"
    end
    return "双人同盟 · 皇家战桌"
end

local function draw_home_lan(ctx, y)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local has_direct_rc = (lobby.saved_session ~= nil and lobby.saved_session.mode == "direct")
    if has_direct_rc then
        local s = lobby.saved_session
        add_btn("reconnect_direct",
            string.format("一键高速追帧重连上次樱花/局域网对局 (2P)  @  %s:%d", tostring(s.host), tonumber(s.port) or 17777),
            cx, y, cw, 30, "battle", { small = true })
        y = y + 36
    end

    local card_w = math.floor((cw - 14) / 2)
    local card_h = has_direct_rc and 152 or 166

    -- Left Contract: 1P Host
    ui.draw_parchment_card(cx, y, card_w, card_h, {
        top = { 236, 240, 232, 250 }, bot = { 228, 214, 178, 250 },
        border = T.p1_border, border_w = 2, thumbtack = true,
    })
    ui.draw_pill(cx + 14, y + 12, 168, 20, "1P 房主 · 蓝方旗帜 (热续传)", T.p1_top, T.p1_border, { 242, 250, 255, 255 }, fm.tiny_bold)
    ui.text("设立樱花 / 局域网战桌", cx + 14, y + 37, T.ink_text, fm.hero)
    ui.text("TCP 17777 零服务器直连；内置 180 秒樱花闪断热续传与 2P 闪退追帧重连。",
        cx + 14, y + 58, T.ink_sub, fm.tiny, card_w - 28, "left")
    add_btn("host_lan", "创建房间并备战", cx + 14, y + card_h - 66, card_w - 28, 32, "battle", { small = false })
    add_btn("join_local", "本机双开快速加入 (127.0.0.1)", cx + 14, y + card_h - 28, card_w - 28, 21, "parchment", { tiny = true })

    -- Right Contract: 2P Guest / SakuraFrp Smart Paste + Carrier Switch
    local rx = cx + card_w + 14
    ui.draw_parchment_card(rx, y, card_w, card_h, {
        top = { 250, 238, 226, 250 }, bot = { 234, 212, 176, 250 },
        border = T.p2_border, border_w = 2, thumbtack = true,
    })
    ui.draw_pill(rx + 14, y + 12, 146, 20, "2P 队友 · 樱花一键直连", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, fm.tiny_bold)
    ui.text("粘贴樱花 / 局域网地址直连", rx + 14, y + 37, T.ink_text, fm.hero)

    local ip_disp = lobby.ip_input
    if #ip_disp > 32 then ip_disp = "..." .. ip_disp:sub(-29) end
    local ip_w = card_w - 28 - 64
    add_btn("ip_box", ip_disp .. (lobby.focused_field == "ip" and "|" or ""), rx + 14, y + 61, ip_w, 27, "input", {
        small = true, focused = (lobby.focused_field == "ip"),
    })
    add_btn("paste_ip", "粘贴", rx + 14 + ip_w + 6, y + 61, 58, 27, "wood", { small = true })

    if lobby_prefs.is_sakura_addr(lobby.ip_input) then
        local cur_c = lobby_prefs.get_sakura_carrier(lobby.ip_input)
        local cw3 = math.floor((card_w - 28 - 10) / 3)
        local cy3 = y + 92
        local carriers = {
            { id = "default", lbl = "默认线" },
            { id = "dx",      lbl = "电信(dx)" },
            { id = "yd",      lbl = "移动(yd)" },
        }
        for ci, cinfo in ipairs(carriers) do
            local act = (cur_c == cinfo.id)
            add_btn("sakura_carrier", cinfo.lbl, rx + 14 + (ci - 1) * (cw3 + 5), cy3, cw3, 20,
                act and "azure" or "parchment", { tiny = true, carrier = cinfo.id })
        end
    else
        ui.text("复制整行樱花日志点「粘贴」(Ctrl+V) 自动提取并识别电信/移动线路！", rx + 14, y + 93, T.ink_muted, fm.tiny, card_w - 28, "left")
    end

    local lan_connecting = (not lobby.transport:is_online()) and lobby.transport:is_connecting()
    add_btn("join_ip", lan_connecting and "正在连接房主..." or "立即直连队友战桌", rx + 14, y + card_h - 42, card_w - 28, 33, "crimson", { small = false })

    y = y + card_h + 10

    -- Bottom Dark-Oak Tavern Notice Board (Recent SakuraFrp Addresses + LAN Auto-Discovery)
    local tray_h = (py + ph - 22) - y
    ui.draw_armory_tray(cx, y, cw, tray_h, 9)
    local rec = lobby.recent_addrs or {}
    local list_top = y + 32
    if #rec > 0 then
        ui.print_shadow("最近樱花/直连：", cx + 14, y + 10, T.gold_bright, nil, nil, nil, fm.tiny_bold)
        local rx_c = cx + 114
        local max_chip_w = math.floor((cw - 128 - (#rec - 1) * 6) / #rec)
        for ri = 1, #rec do
            local addr = rec[ri]
            local disp = (#addr > 26) and ("..." .. addr:sub(-23)) or addr
            add_btn("use_recent_addr", disp, rx_c + (ri - 1) * (max_chip_w + 6), y + 7, max_chip_w, 22, "wood", {
                tiny = true, addr = addr,
            })
        end
        list_top = y + 58
        local rooms = lobby.transport:get_lan_rooms()
        ui.draw_ping_dot(cx + 18, y + 43, 12, #rooms > 0)
        ui.print_shadow(string.format("附近局域网自动发现 (UDP 17778 · %d 个房间)", #rooms),
            cx + 30, y + 36, { 238, 212, 162, 235 }, nil, nil, nil, fm.tiny_bold)
    else
        local rooms = lobby.transport:get_lan_rooms()
        ui.draw_ping_dot(cx + 18, y + 18, 12, #rooms > 0)
        ui.print_shadow(string.format("酒馆布告栏 · 自动扫描附近局域网战桌 (UDP 17778 · %d 个房间)", #rooms),
            cx + 30, y + 11, T.gold_bright, nil, nil, nil, fm.small_bold)
    end

    local rooms = lobby.transport:get_lan_rooms()
    if #rooms == 0 then
        local empty_y = list_top + math.max(8, math.floor((y + tray_h - list_top - 24) * 0.42))
        ui.text("暂未扫描到同 Wi-Fi 房间 · 同局域网请等待房主开房；异地远程请直接使用右上樱花映射直连（内置热续传）。",
            cx + 22, empty_y, { 232, 206, 158, 220 }, fm.small, cw - 44, "center")
    else
        local max_lan = math.max(1, math.floor((y + tray_h - list_top - 6) / 46))
        for idx = 1, math.min(#rooms, max_lan) do
            local r = rooms[idx]
            local ry = list_top + (idx - 1) * 46
            ui.draw_parchment_card(cx + 12, ry, cw - 24, 41, { radius = 6 })
            ui.draw_stage_thumb(r.level_idx, cx + 18, ry + 4, 56, 33, { radius = 4, pad = 1, border = { 108, 72, 32, 235 } })
            ui.text(string.format("%s  ·  %s", tostring(r.name), get_stage_clean_title(r.level_idx)), cx + 84, ry + 5, T.ink_text, fm.main_bold)
            ui.text(string.format("%s:%d  ·  %d/2 勇士等待中", tostring(r.ip), tonumber(r.port) or 17777, tonumber(r.players) or 1), cx + 84, ry + 23, T.ink_sub, fm.tiny)
            add_btn("join_lan_room", "揭榜加入", cx + cw - 110, ry + 6, 86, 28, "battle", { small = true, room = r })
        end
    end
end

local function draw_home_online(ctx, y)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local is_connecting = lobby.transport:is_online() and lobby.transport:is_connecting()

    if lobby.saved_session and lobby.saved_session.mode ~= "direct" then
        local s = lobby.saved_session
        add_btn("reconnect_last",
            string.format("一键高速追帧重连：房间 #%s (%dP)  @  %s", tostring(s.code), tonumber(s.pid) or 2, tostring(s.server)),
            cx, y, cw, 32, "battle", { small = true })
        y = y + 40
    end

    ui.draw_parchment_card(cx, y, cw, 44, { radius = 7 })
    ui.text("中继服：", cx + 12, y + 14, T.ink_text, fm.small_bold)
    local sx = cx + 64
    local sw_in = cw - 64 - 224
    local srv_disp = lobby.server_input
    if #srv_disp > 40 then srv_disp = "..." .. srv_disp:sub(-37) end
    add_btn("server_box", srv_disp .. (lobby.focused_field == "server" and "|" or ""), sx, y + 7, sw_in, 28, "input", {
        small = true, focused = (lobby.focused_field == "server"),
    })
    add_btn("paste_server", "粘贴", sx + sw_in + 6, y + 7, 48, 28, "wood", { small = true })
    local conn_lbl = lobby.server_connected and ("已连 " .. lobby.transport:get_rtt_ms() .. "ms")
        or (is_connecting and "连接中..." or "连接")
    add_btn("connect_server", conn_lbl, sx + sw_in + 60, y + 7, 86, 28,
        lobby.server_connected and "battle" or (is_connecting and "wood" or "azure"), { small = true })
    add_btn("refresh_online", "刷新", sx + sw_in + 152, y + 7, 58, 28, "parchment", { small = true })
    y = y + 52

    local lw = math.floor(cw * 0.54)
    local rw = cw - lw - 12
    local rx = cx + lw + 12

    ui.draw_parchment_card(cx, y, lw, 92, { border = T.p1_border, border_w = 1.8, thumbtack = true })
    ui.text("1P 房主 · 创建公网合作房", cx + 12, y + 8, T.p1_border, fm.small_bold)
    local pw_empty = (#lobby.pw_input == 0)
    local pw_disp = (pw_empty and "房间密码(选填)" or lobby.pw_input) .. (lobby.focused_field == "pw" and "|" or "")
    local pw_w = lw - 122
    add_btn("pw_box", pw_disp, cx + 12, y + 28, pw_w, 25, "input", {
        small = true, placeholder = pw_empty and (lobby.focused_field ~= "pw"), focused = (lobby.focused_field == "pw"),
    })
    add_btn("toggle_public", lobby.room_public and "公开大厅" or "仅房间码", cx + 18 + pw_w, y + 28, 92, 25, "parchment", { tiny = true })
    add_btn("create_online", "创建公网房间", cx + 12, y + 58, lw - 24, 26, "azure", { small = true })

    ui.draw_parchment_card(rx, y, rw, 92, { border = T.p2_border, border_w = 1.8, thumbtack = true })
    ui.text("2P 队友 · 凭房间码加入", rx + 12, y + 8, T.p2_border, fm.small_bold)
    local code_empty = (#lobby.code_input == 0)
    local code_disp = (code_empty and "输入4位房间码(如 A1B2)" or lobby.code_input) .. (lobby.focused_field == "code" and "|" or "")
    add_btn("code_box", code_disp, rx + 12, y + 28, rw - 24, 25, "input", {
        small = true, placeholder = code_empty and (lobby.focused_field ~= "code"), focused = (lobby.focused_field == "code"),
    })
    add_btn("join_code", "凭房间码进房", rx + 12, y + 58, rw - 24, 26, "crimson", { small = true })
    y = y + 100

    local tray_h = (py + ph - 22) - y
    ui.draw_armory_tray(cx, y, cw, tray_h, 9)
    ui.draw_ping_dot(cx + 18, y + 17, lobby.transport:get_rtt_ms(), lobby.server_connected)
    ui.print_shadow(string.format("公开在线房间大厅 (%d 个房间)", #lobby.online_rooms), cx + 30, y + 10, T.gold_bright, nil, nil, nil, fm.small_bold)

    if is_connecting then
        ui.text("正在后台探测公网中继服（不卡界面），也可直接修改上方服务器地址后点「连接」。",
            cx + 22, y + math.floor(tray_h * 0.44), { 246, 224, 174, 225 }, fm.small, cw - 44, "center")
    elseif not lobby.server_connected then
        ui.text("尚未连接中继服 · 点上方「连接」接入；或自开 kr-mp-server + 樱花映射 TCP 17780 享 5 分钟追帧重连。",
            cx + 22, y + math.floor(tray_h * 0.44), { 232, 206, 158, 220 }, fm.small, cw - 44, "center")
    elseif #lobby.online_rooms == 0 then
        ui.text("已连接服务器！当前暂无公开房间，可点左上「创建公网房间」或「刷新」。",
            cx + 22, y + math.floor(tray_h * 0.46), { 232, 206, 158, 220 }, fm.small, cw - 44, "center")
    else
        local max_show = math.max(1, math.floor((tray_h - 34) / 38))
        for idx = 1, math.min(#lobby.online_rooms, max_show) do
            local r = lobby.online_rooms[idx]
            local ry = y + 32 + (idx - 1) * 38
            ui.draw_parchment_card(cx + 12, ry, cw - 24, 33, { radius = 5 })
            ui.draw_pill(cx + 18, ry + 6, 56, 20, "#" .. tostring(r.code), T.wood_mid, T.ink_dark, T.gold_bright, fm.tiny_bold)
            local pw_tag = r.has_password and " [需密码]" or ""
            ui.text(string.format("%s  ·  %s  (%d/2)%s",
                tostring(r.name), get_stage_clean_title(r.level_idx), tonumber(r.players) or 1, pw_tag),
                cx + 82, ry + 9, T.ink_text, fm.small_bold)
            add_btn("join_online_room", "加入", cx + cw - 92, ry + 4, 70, 24, "battle", { small = true, room = r })
        end
    end
end

local function draw_home(ctx)
    local lobby, G, T, cx, cw, py, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.font_map, ctx.add_btn
    local y = py + 42
    local is_lan = (lobby.net_tab == "lan")
    add_btn("tab_lan", "樱花映射 / 局域网直连", cx, y, 178, 28, is_lan and "wood" or "parchment", { small = true, active = is_lan })
    add_btn("tab_online", "公网中继服 (多房大厅)", cx + 186, y, 166, 28, (not is_lan) and "wood" or "parchment", { small = true, active = not is_lan })

    local upd_lbl, upd_w, upd_style
    if updater.ota_applied then
        upd_lbl, upd_w, upd_style = "重启生效 √", 92, "battle"
    elseif updater.ota_updating then
        upd_lbl, upd_w, upd_style = updater.ota_progress_text or "热更新中...", 98, "azure"
    elseif updater.ota_ready then
        local nchg = updater.ota_changed_files and #updater.ota_changed_files or 0
        upd_lbl = (updater.latest_version and updater.is_newer(updater.latest_version, proto.MOD_VERSION))
            and ("热更新 v" .. tostring(updater.latest_version))
            or string.format("一键热更(%d)", nchg)
        upd_w, upd_style = 108, "battle"
    elseif updater.has_update then
        upd_lbl, upd_w, upd_style = "下载新版 v" .. tostring(updater.latest_version), 112, "battle"
    elseif updater.checking then
        upd_lbl, upd_w, upd_style = "检查中...", 76, "parchment"
    else
        upd_lbl, upd_w, upd_style = "检查更新", 76, "parchment"
    end
    add_btn("check_update", upd_lbl, cx + cw - upd_w, y + 1, upd_w, 26, upd_style, { tiny = true })
    local guide_w = 78
    add_btn("open_guide", "新手教程", cx + cw - upd_w - guide_w - 6, y + 1, guide_w, 26,
        (not lobby.seen_guide) and "azure" or "parchment", { tiny = true, tab = 1 })
    ui.text(string.format("FL %s · v%s · F10", tostring(KR_FL_VERSION), proto.MOD_VERSION),
        cx + 354, y + 7, T.ink_muted, fm.tiny, cw - 360 - upd_w - guide_w - 8, "right")

    y = y + 36
    G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], 130)
    G.setLineWidth(1)
    G.line(cx, y, cx + cw, y)
    y = y + 10

    if is_lan then
        draw_home_lan(ctx, y)
    else
        draw_home_online(ctx, y)
    end
end

local function draw_room_hero_card(ctx, pid, x, y, w, h, is_host)
    local lobby, G, T, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.font_map, ctx.add_btn
    local is_p1 = (pid == 1)
    local top_c = is_p1 and T.p1_top or T.p2_top
    local bot_c = is_p1 and T.p1_bot or T.p2_bot
    local brd_c = is_p1 and T.p1_border or T.p2_border
    local lgt_c = is_p1 and T.p1_light or T.p2_light
    local hero_idx = lobby.room.heroes[pid]

    G.setColor(34, 18, 6, 72)
    G.rectangle("fill", x + 2, y + 4, w, h, 10, 10)
    ui.draw_vgrad_rect(x, y, w, h, top_c, bot_c, 10)
    G.setColor(is_p1 and 168 or 255, is_p1 and 222 or 180, is_p1 and 255 or 175, is_p1 and 78 or 76)
    G.setLineWidth(1.5)
    G.line(x + 10, y + 2, x + w - 10, y + 2)
    G.setColor(brd_c[1], brd_c[2], brd_c[3], 255)
    G.setLineWidth(2.2)
    G.rectangle("line", x, y, w, h, 10, 10)

    ui.print_shadow(is_p1 and "1P 蓝方主将" or "2P 红方协防", x + 10, y + 6, lgt_c, nil, nil, nil, fm.tiny_bold)
    if is_p1 then
        ui.draw_pill(x + w - 44, y + 4, 36, 17, "房主", { 12, 26, 48, 175 }, nil, T.gold_bright, fm.tiny_bold)
    end

    local hp_x, hp_y, hp_w, hp_h = x + 8, y + 24, w - 16, 152
    ui.draw_hero_big_portrait(hero_idx, hp_x, hp_y, hp_w, hp_h, {
        radius = 7, pad = 2,
        bg = is_p1 and { 16, 34, 58, 255 } or { 44, 12, 14, 255 },
        border = T.gold_mid, border_w = 2,
    })
    ui.draw_vgrad_rect(hp_x + 2, hp_y + hp_h - 46, hp_w - 4, 44,
        is_p1 and { 10, 22, 38, 0 } or { 36, 8, 10, 0 },
        is_p1 and { 8, 18, 32, 232 } or { 32, 6, 8, 232 }, 4)
    ui.print_shadow(catalog.get_hero_label(hero_idx), hp_x + 8, hp_y + hp_h - 36, T.gold_bright, nil, nil, nil, fm.hero)
    ui.print_shadow("英雄 #" .. tostring(hero_idx), hp_x + 8, hp_y + hp_h - 17, lgt_c, nil, nil, nil, fm.tiny)

    if lobby.voice and lobby.voice.supported then
        local v_talk, v_lvl = lobby.voice:get_seat_state(pid, lobby.local_pid)
        if v_talk or (lobby.local_pid == pid and v_lvl > 0.06 and lobby.voice.mode ~= "mute") then
            G.setColor(is_p1 and 10 or 44, is_p1 and 26 or 12, is_p1 and 44 or 14, 215)
            G.rectangle("fill", hp_x + hp_w - 44, hp_y + hp_h - 24, 38, 18, 5, 5)
            if is_p1 then
                G.setColor(v_talk and 92 or 120, v_talk and 242 or 178, v_talk and 148 or 230, 220)
            else
                G.setColor(v_talk and 106 or 236, v_talk and 244 or 162, v_talk and 148 or 156, 220)
            end
            G.setLineWidth(1.2)
            G.rectangle("line", hp_x + hp_w - 44, hp_y + hp_h - 24, 38, 18, 5, 5)
            ui.draw_voice_eq(hp_x + hp_w - 40, hp_y + hp_h - 22, 30, 14, v_lvl, v_talk,
                is_p1 and { 118, 255, 168, 255 } or { 255, 226, 118, 255 },
                is_p1 and { 84, 206, 255, 230 } or { 255, 132, 128, 235 })
        end
        if v_talk then
            ui.draw_speaking_glow(x, y, w, h, 10,
                is_p1 and { 92, 242, 152, 255 } or { 112, 244, 148, 255 }, v_lvl)
        end
    end

    if is_p1 then
        if is_host then
            add_btn("open_hero1", "更换 1P 主将", x + 8, y + 182, w - 16, 26, "azure", { small = true })
        else
            ui.draw_pill(x + 12, y + 184, w - 24, 22, "房主主控主将",
                { 14, 34, 62, 185 }, { 112, 178, 238, 130 }, T.p1_light, fm.tiny_bold)
        end
    else
        add_btn("open_hero2", "更换 2P 英雄", x + 8, y + 182, w - 16, 26, "crimson", { small = true })
        local rdy_ok = lobby.peer_connected and ((is_host and lobby.peer_ready) or (not is_host and lobby.local_ready))
        local seal_st = (not lobby.peer_connected) and "waiting" or (rdy_ok and "ready" or "joined")
        ui.draw_wax_seal(x + w - 28, y + 28, 28, seal_st, fm)
    end
end

local function draw_room_center_column(ctx, mid_x, y, mid_w, is_host)
    local lobby, T, fm, add_btn = ctx.lobby, ctx.T, ctx.font_map, ctx.add_btn
    ui.draw_parchment_card(mid_x, y, mid_w, 148, {
        top = { 255, 250, 238, 255 }, bot = { 238, 218, 174, 255 },
        border = { 138, 94, 40, 245 }, border_w = 2, thumbtack = true, radius = 9,
    })
    local mp_x, mp_y, mp_w, mp_h = mid_x + 8, y + 10, mid_w - 16, 128
    ui.draw_stage_thumb(lobby.room.level_idx, mp_x, mp_y, mp_w, mp_h, {
        radius = 6, pad = 1, bg = { 42, 26, 12, 255 }, border = { 88, 56, 24, 255 }, border_w = 1.8,
    })
    ui.draw_vgrad_rect(mp_x + 1, mp_y + mp_h - 52, mp_w - 2, 51, { 24, 12, 4, 0 }, { 22, 10, 4, 235 }, 4)
    local pks = PACK_TAG_STYLES[get_stage_pack_info(lobby.room.level_idx)] or PACK_TAG_STYLES.kr5
    ui.draw_pill(mp_x + 7, mp_y + 7, 68, 19, pks.era, pks.bg, pks.border, pks.fg, fm.tiny_bold)
    if is_host then
        add_btn("open_stages", string.format("切换地图 (%d关)", catalog.TOTAL_STAGES or 201),
            mp_x + mp_w - 114, mp_y + 6, 108, 22, "wood", { tiny = true })
    end
    local df_info = DIFF_STYLES[lobby.room.level_difficulty] or DIFF_STYLES[2]
    ui.print_shadow("出征战役目标", mp_x + 10, mp_y + mp_h - 40, { 255, 224, 152, 245 }, nil, nil, nil, fm.tiny)
    ui.print_shadow(get_stage_clean_title(lobby.room.level_idx), mp_x + 10, mp_y + mp_h - 23, { 255, 248, 224, 255 }, nil, nil, nil, fm.hero)
    ui.print_shadow(df_info.stars, mp_x + mp_w - 72, mp_y + mp_h - 22, df_info.star_col or T.gold_bright, 64, "right", nil, fm.small_bold)

    local ry_rules, rh_rules = y + 158, 56
    local rw_rule = math.floor((mid_w - 14) / 3)
    local econ_short = (lobby.room.econ_mode == "independent") and "独立 50/50" or "共享金库"
    local tower_short = (lobby.room.tower_mode == "owned") and "红蓝保护" or "自由共享"

    if is_host then
        add_btn("diff_cycle", "战役难度\n" .. df_info.name, mid_x, ry_rules, rw_rule, rh_rules, "parchment", { small = true, fg = df_info.col })
        add_btn("econ_toggle", "军费账本\n" .. econ_short, mid_x + rw_rule + 7, ry_rules, rw_rule, rh_rules, "parchment", { small = true })
        add_btn("tower_toggle", "防御塔权\n" .. tower_short, mid_x + (rw_rule + 7) * 2, ry_rules, rw_rule, rh_rules, "parchment", { small = true })
    else
        local ro_rules = {
            { t = "战役难度", v = df_info.name, col = df_info.col },
            { t = "军费账本", v = econ_short, col = T.ink_text },
            { t = "防御塔权", v = tower_short, col = T.ink_text },
        }
        for i, rr in ipairs(ro_rules) do
            local rx_r = mid_x + (i - 1) * (rw_rule + 7)
            ui.draw_parchment_card(rx_r, ry_rules, rw_rule, rh_rules, { radius = 7 })
            ui.text(rr.t, rx_r, ry_rules + 9, T.ink_muted, fm.tiny, rw_rule, "center")
            ui.text(rr.v, rx_r, ry_rules + 28, rr.col, fm.small_bold, rw_rule, "center")
        end
    end
end

local function draw_room_armory_tray(ctx, y, is_host)
    local lobby, G, T, cx, cw, mx, my, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.cx, ctx.cw, ctx.mx, ctx.my, ctx.font_map, ctx.add_btn
    local tray_h = 92
    ui.draw_armory_tray(cx, y, cw, tray_h, 9)
    local deck = lobby.room.towers or catalog.DEFAULT_TOWERS
    local icon_sz, icon_gap = 50, 9
    local total_tw = 12 * icon_sz + 11 * icon_gap
    local row_x = cx + math.floor((cw - total_tw) * 0.5)
    local row_y = y + 34
    local hovered_tw_name = nil

    for i = 1, 12 do
        local tid = deck[i]
        local ix = row_x + (i - 1) * (icon_sz + icon_gap)
        local is_hov = (tid ~= nil and mx >= ix and mx <= ix + icon_sz and my >= row_y and my <= row_y + icon_sz)
        local dy_lift = is_hov and -3 or 0
        if is_hov then hovered_tw_name = catalog.get_tower_name(tid) end

        G.setColor(22, 12, 6, 245)
        G.rectangle("fill", ix, row_y + dy_lift, icon_sz, icon_sz, 7, 7)
        if tid then
            ui.draw_tower_icon(tid, ix, row_y + dy_lift, icon_sz, icon_sz, {
                radius = 7, pad = 2, bg = { 32, 18, 9, 250 },
                border = is_hov and T.gold_bright or { 128, 86, 42, 235 },
                border_w = is_hov and 2.2 or 1.4,
            })
        else
            G.setColor(92, 62, 32, 125)
            G.setLineWidth(1.2)
            G.rectangle("line", ix, row_y, icon_sz, icon_sz, 7, 7)
        end
    end

    ui.print_shadow(string.format("随军防御塔军械盘 (%d/12)", #deck), cx + 14, y + 8, T.gold_bright, nil, nil, nil, fm.small_bold)
    ui.draw_pill(cx + 186, y + 7, 178, 19,
        hovered_tw_name and ("当前检阅：" .. hovered_tw_name) or "悬停纹章检阅防御塔",
        { 18, 10, 4, 175 }, { 196, 148, 72, 115 },
        hovered_tw_name and T.gold_bright or { 228, 202, 154, 215 }, fm.tiny)

    if is_host then
        add_btn("open_guide", "新手教程", cx + cw - 208, y + 5, 76, 23, "parchment", { tiny = true, tab = 2 })
        add_btn("open_towers", string.format("配置 %d 选 12", catalog.TOTAL_TOWERS or 59), cx + cw - 126, y + 5, 114, 23, "wood", { tiny = true })
    else
        add_btn("open_guide", "新手教程", cx + cw - 196, y + 5, 76, 23, "parchment", { tiny = true, tab = 2 })
        ui.draw_pill(cx + cw - 114, y + 7, 102, 19, "房主配置卡组",
            { 18, 10, 4, 165 }, { 164, 122, 64, 115 }, { 224, 198, 152, 210 }, fm.tiny)
    end
    return tray_h
end

local function draw_room(ctx)
    local lobby, G, T, cx, cw, py, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.font_map, ctx.add_btn
    lobby.ensure_room_defaults(lobby.room)
    local is_host = (lobby.role == "host")
    local rtt = lobby.transport:get_rtt_ms()
    local d_turns = lobby.normalize_delay_turns(lobby.room.input_delay_turns)
    local delay_lbl = lobby.DELAY_LABELS[d_turns] or "缓冲:局域网100ms"
    local marks_on = (lobby.coop == nil) or (lobby.coop.show_tower_marks ~= false)

    -- Row 1: Top Status, Voice Strip, Delay & Tower Marks
    local y = py + 40
    ui.draw_ping_dot(cx + 8, y + 12, rtt, lobby.peer_connected)
    ui.text(lobby.peer_connected and "同盟已集结 (2/2)" or "等待 2P 入阵 (1/2)", cx + 20, y + 5, T.ink_text, fm.small_bold)

    local net_info, net_style, net_fg
    local port_drifted = is_host and (not lobby.transport:is_online()) and lobby.transport:is_port_drifted()
    if lobby.transport:is_online() then
        net_info = string.format("#%s (点复制) · %dms", tostring(lobby.online_room_code or "----"), rtt)
        net_style = "parchment"
    elseif port_drifted then
        net_info = string.format("警告!端口:%d!", lobby.transport:get_port())
        net_style = "crimson"
        net_fg = { 255, 244, 218, 255 }
    elseif is_host then
        net_info = string.format("TCP:%d (复制) · %dms", lobby.transport:get_port(), rtt)
        net_style = "parchment"
    else
        net_info = string.format("直连 (复制) · %dms", rtt)
        net_style = "parchment"
    end
    local info_w = is_host and 166 or 154
    add_btn("copy_net_info", net_info, cx + 136, y, info_w, 24, net_style, {
        tiny = true, fg = net_fg or T.ink_sub,
    })

    if lobby.voice then
        local v_ok, v_mode, v_talk = lobby.voice.supported, lobby.voice.mode, lobby.voice.local_talking
        local v_style = (v_ok and v_talk) and "battle" or ((v_ok and v_mode ~= "mute") and "wood" or "parchment")
        local v_fg = (v_mode == "mute" or not v_ok) and { 158, 42, 42, 255 }
            or ((v_mode == "vad") and { 196, 255, 206, 255 } or { 255, 240, 198, 255 })
        local vx = cx + 136 + info_w + 6
        add_btn("voice_cycle", lobby.voice:get_mode_lobby_label(), vx, y, 98, 24, v_style, {
            tiny = true, fg = v_talk and { 255, 255, 242, 255 } or v_fg,
        })
        add_btn("open_voice_mixer", "调音", vx + 102, y, 42, 24, "azure", { tiny = true })
        local aux_lbl, aux_style, aux_fg
        if lobby.peer_connected then
            local pm = lobby.voice.peer_muted
            aux_lbl = pm and "已静" or "听筒"
            aux_style = pm and "crimson" or "parchment"
            aux_fg = pm and { 255, 236, 232, 255 } or { 42, 118, 56, 255 }
        else
            local st = lobby.voice.self_test
            aux_lbl = st and "试麦√" or "试麦"
            aux_style = st and "battle" or "parchment"
            aux_fg = st and { 255, 255, 238, 255 } or T.ink_text
        end
        add_btn("voice_aux", aux_lbl, vx + 148, y, 46, 24, aux_style, { tiny = true, fg = aux_fg })
    end

    if is_host then
        add_btn("delay_cycle", delay_lbl, cx + cw - 216, y, 122, 24, "parchment", { tiny = true, active = (d_turns >= 4) })
    else
        ui.draw_pill(cx + cw - 216, y + 1, 122, 22, delay_lbl,
            { 238, 218, 174, 240 }, { 154, 114, 58, 180 }, T.ink_text, fm.tiny)
    end
    add_btn("toggle_tower_marks", marks_on and "塔底徽记:开" or "塔底徽记:关", cx + cw - 88, y, 88, 24,
        marks_on and "wood" or "parchment", { tiny = true, fg = marks_on and { 226, 255, 218, 255 } or T.ink_sub })

    y = y + 29
    G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], 145)
    G.setLineWidth(1)
    G.line(cx, y, cx + cw, y)
    y = y + 7

    -- Row 2: 3-Column Heroic Stage
    local hero_w, stage_h = 190, 216
    local mid_w = cw - hero_w * 2 - 24
    local mid_x = cx + hero_w + 12
    local c2x = mid_x + mid_w + 12

    draw_room_hero_card(ctx, 1, cx, y, hero_w, stage_h, is_host)
    draw_room_center_column(ctx, mid_x, y, mid_w, is_host)
    draw_room_hero_card(ctx, 2, c2x, y, hero_w, stage_h, is_host)

    y = y + stage_h + 10
    local tray_h = draw_room_armory_tray(ctx, y, is_host)
    y = y + tray_h + 11

    -- Row 4: Start / Ready CTA + Leave Button
    local cta_h, close_w = 42, 122
    if is_host then
        local can_start = lobby.peer_connected
        add_btn("start_match", can_start and "出征守关！" or "等待 2P 队友加入...",
            cx, y, cw - close_w - 12, cta_h, "battle", { large = true, disabled = not can_start, radius = 9 })
        add_btn("leave_room", "关闭房间", cx + cw - close_w, y, close_w, cta_h, "crimson", { radius = 9 })
    else
        add_btn("toggle_ready", lobby.local_ready and "已就绪 · 等待房主开局" or "点击准备就绪！",
            cx, y, cw - close_w - 12, cta_h, "battle", { large = true, radius = 9 })
        add_btn("leave_room", "离开房间", cx + cw - close_w, y, close_w, cta_h, "crimson", { radius = 9 })
    end
end

function M.draw(lobby)
    if not lobby.open or not love.graphics then return end

    local G = love.graphics
    local T = ui.THEME
    local sw, sh = G.getWidth(), G.getHeight()
    local scale = ui.compute_lobby_scale(sw, sh)
    local pw, ph = 780, 486
    local ox = math.floor((sw - pw * scale) * 0.5)
    local oy = math.max(math.floor(28 * scale), math.floor((sh - ph * scale) * 0.5 + 12 * scale))
    local px, py = 0, 0

    lobby._ui_scale = scale
    lobby._ui_ox = ox
    lobby._ui_oy = oy

    local font_map = ui.make_font_map(scale)
    local raw_mx, raw_my = 0, 0
    if love.mouse and love.mouse.getPosition then
        raw_mx, raw_my = love.mouse.getPosition()
    end
    local mx, my = (raw_mx - ox) / scale, (raw_my - oy) / scale

    local btns = {}
    local function add_btn(id, label, x, y, w, h, style, extra)
        local b = { id = id, label = label, x = x, y = y, w = w, h = h, style = style or "wood" }
        if extra then
            for k, v in pairs(extra) do b[k] = v end
        end
        btns[#btns + 1] = b
    end

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")

    G.setColor(T.backdrop[1], T.backdrop[2], T.backdrop[3], T.backdrop[4])
    G.rectangle("fill", 0, 0, sw, sh)

    ui.begin_transform(scale, ox, oy)
    ui.draw_ironhide_war_table(px, py, pw, ph, resolve_banner_title(lobby), font_map.banner)
    add_btn("close", "×", px + pw - 22, py - 10, 32, 30, "crimson", { large = true, radius = 8 })

    local ctx = {
        lobby = lobby, G = G, T = T,
        px = px, py = py, pw = pw, ph = ph,
        cx = px + 25, cw = pw - 50,
        mx = mx, my = my,
        font_map = font_map, add_btn = add_btn,
    }

    if lobby.sub_modal == "guide" then
        modals.draw_guide(ctx)
    elseif lobby.view == "home" then
        draw_home(ctx)
    elseif lobby.sub_modal == "stages" then
        modals.draw_stages(ctx)
    elseif lobby.sub_modal == "hero1" or lobby.sub_modal == "hero2" then
        modals.draw_heroes(ctx)
    elseif lobby.sub_modal == "towers" then
        modals.draw_towers(ctx)
    elseif lobby.sub_modal == "voice" and lobby.voice then
        modals.draw_voice(ctx)
    else
        draw_room(ctx)
    end

    lobby.buttons = btns
    local allow_hover = not proto.is_android()
    for _, b in ipairs(btns) do
        if not b.no_draw then
            local hover = allow_hover and (mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h)
            ui.draw_button(b, hover, font_map)
        end
    end

    ui.end_transform()
    G.pop()
end

return M
