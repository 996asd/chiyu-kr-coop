-- KR-MP Lobby Main Renderer (V2 Ironhide Native Parchment & Hand-Hewn Oak War-Table)
-- Delegates modal screens to lobby_draw_modals.lua; keeps every draw section small & readable.
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")
local lobby_prefs = require("kr_mp.lobby_prefs")
local ui = require("kr_mp.ui_assets")
local modals = require("kr_mp.lobby_draw_modals")
local sakura_modal = require("kr_mp.lobby_draw_sakura")
local server_modal = require("kr_mp.lobby_draw_server")

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
    elseif lobby.sub_modal == "sakura" then return "樱花映射助手 · SakuraFrp"
    elseif lobby.sub_modal == "server_host" then return "一键开服助手 · 自建公网大厅"
    elseif lobby.view == "home" then return "联机酒馆 · 冒险驿站"
    elseif lobby.sub_modal == "stages" then return "战役舆图 · 选择关卡"
    elseif lobby.sub_modal == "hero1" then return "英雄殿 · 选 1P 主将"
    elseif lobby.sub_modal == "hero2" then return "英雄殿 · 选 2P 队友"
    elseif lobby.sub_modal == "towers" then return "皇家军械库 · 59选12"
    elseif lobby.sub_modal == "voice" then return "语音调音 · 麦克风设置"
    end
    return "双人同盟 · 皇家战桌"
end

local function mask_if_private(lobby, addr)
    if lobby.privacy_mask and lobby.sakura and type(addr) == "string" and #addr > 0 then
        return lobby.sakura.mask_addr(addr)
    end
    return tostring(addr or "")
end

local function draw_direct_reconnect_banner(ctx, y)
    local lobby, cx, cw, add_btn = ctx.lobby, ctx.cx, ctx.cw, ctx.add_btn
    if lobby.saved_session ~= nil and lobby.saved_session.mode == "direct" then
        local s = lobby.saved_session
        local rc_addr = mask_if_private(lobby, tostring(s.host) .. ":" .. tostring(tonumber(s.port) or 17777))
        add_btn("reconnect_direct",
            string.format("一键高速追帧重连上次对局 (2P)  @  %s", rc_addr),
            cx, y, cw, 30, "battle", { small = true })
        return y + 36, true
    end
    return y, false
end

local function draw_home_sakura(ctx, y)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local sk = lobby.sakura
    local has_direct_rc
    y, has_direct_rc = draw_direct_reconnect_banner(ctx, y)

    local card_w = math.floor((cw - 14) / 2)
    local card_h = has_direct_rc and 144 or 154
    local main_btn_h = has_direct_rc and 31 or 32
    local main_btn_y = y + card_h - (has_direct_rc and 38 or 40)
    local sk_disp, sk_copy, sk_p2p = nil, nil, false
    if sk then sk_disp, sk_copy, sk_p2p = sk:get_host_share_addr(proto.DEFAULT_TCP_PORT) end

    -- Left Contract: 1P Host (Clean, Symmetric, No Duplicate Buttons)
    ui.draw_parchment_card(cx, y, card_w, card_h, {
        top = { 236, 240, 232, 250 }, bot = { 228, 214, 178, 250 },
        border = T.p1_border, border_w = 2, thumbtack = true,
    })
    ui.draw_pill(cx + 14, y + 10, 142, 20, "1P 房主 · 蓝方旗帜", T.p1_top, T.p1_border, { 242, 250, 255, 255 }, fm.tiny_bold)
    if sk_disp then
        ui.draw_pill(cx + card_w - 110, y + 10, 96, 20, "已识别隧道 √", { 38, 128, 62, 240 }, { 26, 86, 40, 255 }, { 248, 255, 244, 255 }, fm.tiny_bold)
    else
        ui.draw_pill(cx + card_w - 102, y + 10, 88, 20, "180s 热续传", { 72, 54, 34, 215 }, { 148, 114, 62, 200 }, T.gold_bright, fm.tiny_bold)
    end
    ui.text("设立樱花直连战桌", cx + 14, y + 35, T.ink_text, fm.hero)
    if sk_disp then
        local s_line = "已自动抓取隧道：" .. mask_if_private(lobby, sk_disp)
        if #s_line > 34 then s_line = s_line:sub(1, 33) .. ".." end
        ui.text(s_line, cx + 14, y + 59, { 34, 108, 48, 255 }, fm.small_bold, card_w - 28, "left")
        ui.text(sk_p2p and "已启用免费 P2P 优先，2.6 秒不通自动回退樱花中继；点下方「复制地址」发给队友。"
            or "在下方控制中心一键复制地址发给队友，点下方绿按钮即可开房备战。",
            cx + 14, y + 80, T.ink_muted, fm.tiny, card_w - 28, "left")
    else
        ui.text("在下方启动樱花并开启 TCP 17777 隧道，再点下方建房；内置 180 秒闪断无感热续传与追帧重连。",
            cx + 14, y + 58, T.ink_sub, fm.tiny, card_w - 28, "left")
    end
    add_btn("host_lan", "创建樱花房间并备战", cx + 14, main_btn_y, card_w - 28, main_btn_h, "battle", { small = false })

    -- Right Contract: 2P Guest (Mirror-Aligned with Left Main CTA)
    local rx = cx + card_w + 14
    ui.draw_parchment_card(rx, y, card_w, card_h, {
        top = { 250, 238, 226, 250 }, bot = { 234, 212, 176, 250 },
        border = T.p2_border, border_w = 2, thumbtack = true,
    })
    ui.draw_pill(rx + 14, y + 10, 148, 20, "2P 队友 · 樱花一键直连", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, fm.tiny_bold)
    add_btn("toggle_privacy", lobby.privacy_mask and "防窥:开" or "防窥:关", rx + card_w - 76, y + 9, 62, 22,
        lobby.privacy_mask and "azure" or "parchment", { tiny = true })
    ui.text("粘贴樱花地址加入战桌", rx + 14, y + 35, T.ink_text, fm.hero)

    local sk_raw_in = lobby.sakura_ip_input or ""
    local sk_empty = (#sk_raw_in == 0)
    local sk_focused = (lobby.focused_field == "sakura_ip")
    local sk_shown = sk_empty and "粘贴樱花地址 (如 frp-xxx.com:12345)"
        or (sk_focused and sk_raw_in or mask_if_private(lobby, sk_raw_in))
    if not sk_empty and #sk_shown > 30 then sk_shown = "..." .. sk_shown:sub(-27) end
    local ip_w = card_w - 28 - 64
    add_btn("sakura_ip_box", sk_shown .. (sk_focused and "|" or ""), rx + 14, y + 55, ip_w, 24, "input", {
        small = true, placeholder = sk_empty and (not sk_focused), focused = sk_focused,
    })
    add_btn("paste_sakura_ip", "粘贴", rx + 14 + ip_w + 6, y + 55, 58, 24, "wood", { small = true })

    if lobby_prefs.supports_sakura_carrier(sk_raw_in) then
        local cur_c = lobby_prefs.get_sakura_carrier(sk_raw_in)
        local cw4 = math.floor((card_w - 28 - 15) / 4)
        local cy4 = y + 82
        local carriers = {
            { id = "default", lbl = "默认线" },
            { id = "dx",      lbl = "电信dx" },
            { id = "yd",      lbl = "移动yd" },
        }
        for ci, cinfo in ipairs(carriers) do
            local act = (cur_c == cinfo.id)
            local lbl = sk and sk:get_probe_label(sk_raw_in, cinfo.id, cinfo.lbl) or cinfo.lbl
            add_btn("sakura_carrier", lbl, rx + 14 + (ci - 1) * (cw4 + 5), cy4, cw4, 20,
                act and "azure" or "parchment", { tiny = true, carrier = cinfo.id })
        end
        local pb_lbl = (sk and sk.probe_running) and "测速中.." or "三线测速"
        add_btn("sakura_probe", pb_lbl, rx + 14 + 3 * (cw4 + 5), cy4, (card_w - 28) - 3 * (cw4 + 5), 20,
            (sk and sk.probe_running) and "wood" or "battle", { tiny = true })
    elseif select(2, proto.split_fallback_addr(sk_raw_in)) ~= nil then
        ui.text("已识别 P2P + 樱花中继双地址：优先直连，不通自动切中继！", rx + 14, y + 84, { 34, 108, 48, 255 }, fm.tiny, card_w - 28, "left")
    elseif lobby_prefs.is_sakura_addr(sk_raw_in) then
        ui.text("已识别樱花免费子域 (.nyat.app)，支持 180 秒热续传与追帧！", rx + 14, y + 84, { 34, 108, 48, 255 }, fm.tiny, card_w - 28, "left")
    else
        ui.text("整行樱花日志点「粘贴」自动提取，识别后可一键三线测速！", rx + 14, y + 84, T.ink_muted, fm.tiny, card_w - 28, "left")
    end

    local lan_connecting = (not lobby.transport:is_online()) and lobby.transport:is_connecting()
    add_btn("join_sakura_ip", lan_connecting and "正在连接房主..." or "立即直连房主战桌", rx + 14, main_btn_y, card_w - 28, main_btn_h, "crimson", { small = false })

    y = y + card_h + 10

    -- Bottom Dark-Oak SakuraFrp Control Center (Single Source of Truth, Zero Redundancy, Zero Dead Space)
    local tray_h = (py + ph - 22) - y
    ui.draw_armory_tray(cx, y, cw, tray_h, 9)
    local sk_alive = (sk ~= nil and (sk.managed_proc ~= nil or sk.frpc_running == true))
    ui.draw_ping_dot(cx + 18, y + 17, sk_alive and 15 or 999, sk_alive)
    ui.print_shadow("本机樱花控制中心", cx + 30, y + 10, T.gold_bright, nil, nil, nil, fm.small_bold)
    add_btn("tab_lan", "同Wi-Fi免装樱花→", cx + 158, y + 6, 122, 22, "parchment", { tiny = true })
    add_btn("sakura_rescan", "刷新", cx + cw - 208, y + 6, 54, 22, "parchment", { tiny = true })
    add_btn("open_sakura", "樱花助手 (建/启隧道)", cx + cw - 148, y + 6, 136, 22, "azure", { tiny = true })

    -- Row 1: Single-Line Safe Local Status Card (Guaranteed No Wrap Overflow)
    local st_y, st_h = y + 34, 48
    ui.draw_parchment_card(cx + 12, st_y, cw - 24, st_h, { radius = 6 })
    local inst_s = (sk and sk.installed) and "官方启动器：已安装" or "官方启动器：未安装"
    local proc_s = (sk and sk.managed_proc) and (sk.managed_proc.confirmed and "独立 frpc 运行中 √" or "独立 frpc 连接中...")
        or ((sk and sk.frpc_running) and "官方 frpc 运行中 √"
            or ((sk and sk.service_running) and "后台服务待机" or "未运行"))
    local spd_s = (sk and sk.log_speed_text) and ("  ·  " .. sk.log_speed_text) or ""
    local text_w = (sk and sk.managed_proc) and (cw - 196) or (cw - 144)
    ui.text(string.format("%s  ·  状态：%s%s", inst_s, proc_s, spd_s),
        cx + 22, st_y + 7, sk_alive and { 32, 108, 48, 255 } or T.ink_text, fm.small_bold, text_w, "left")
    local line2, line2_col
    local sk_warn = (sk and sk.get_active_warning) and sk:get_active_warning(lobby) or nil
    if sk and sk.dl_busy then
        line2 = string.format("正在从樱花官方源下载启动器 v%s（%d%%），下完将自动校验并拉起安装...",
            tostring(sk.dl_ver or ""), sk:get_download_pct())
        line2_col = { 34, 108, 48, 255 }
    elseif sk and sk.frpc_dl_busy then
        local fp = (sk.get_frpc_download_pct and sk:get_frpc_download_pct()) or 0
        line2 = string.format("正在从樱花官方源下载独立版 frpc v%s（%d%%），校验完立即自动启动隧道...",
            tostring(sk.frpc_dl_ver or ""), fp)
        line2_col = { 34, 108, 48, 255 }
    elseif sk and (sk.managed_last_error or sk.frpc_dl_error) then
        line2 = "独立版 frpc：" .. tostring(sk.managed_last_error or sk.frpc_dl_error)
        line2_col = { 166, 46, 36, 255 }
    elseif sk_warn then
        line2, line2_col = sk_warn, { 166, 46, 36, 255 }
    elseif sk_disp then
        line2 = "已自动识别地址：" .. mask_if_private(lobby, sk_disp) .. (sk_p2p and "  [P2P优先]" or "")
        line2_col = { 34, 108, 48, 255 }
    elseif sk and not sk.installed then
        line2 = "仅房主需要安装樱花（队友不用装）；点右「一键装樱花」或进「樱花助手」看 4 步向导。"
        line2_col = T.ink_muted
    else
        line2 = "开启 TCP 17777 隧道后自动识别；或点右上「樱花助手」游戏内建/启隧道。"
        line2_col = T.ink_muted
    end
    ui.text(line2, cx + 22, st_y + 27, line2_col, fm.tiny, text_w, "left")

    if sk and sk.managed_proc then
        add_btn("sakura_copy_detected", "复制地址", cx + cw - 166, st_y + 11, 70, 26, "battle", { tiny = true, copy_addr = sk_copy })
        add_btn("sakura_stop_frpc", "停止隧道", cx + cw - 90, st_y + 11, 68, 26, "crimson", { tiny = true })
    elseif sk_disp then
        add_btn("sakura_copy_detected", "复制地址", cx + cw - 114, st_y + 11, 92, 26, "battle", { tiny = true, copy_addr = sk_copy })
    elseif sk and sk.installed then
        add_btn("sakura_launch_app", "启动樱花", cx + cw - 114, st_y + 11, 92, 26, "wood", { tiny = true })
    elseif sk and sk.dl_busy then
        add_btn("sakura_download_official", string.format("下载 %d%%", sk:get_download_pct()), cx + cw - 114, st_y + 11, 92, 26, "wood", { tiny = true })
    else
        add_btn("sakura_download_official", "一键装樱花", cx + cw - 114, st_y + 11, 92, 26, "battle", { tiny = true })
    end

    -- Row 2: Recent SakuraFrp Cards OR 3 Structured Parchment Step Cards (Zero Empty Black Space)
    local r2_y = st_y + st_h + 10
    local rec = lobby.recent_addrs or {}
    if #rec > 0 then
        ui.print_shadow("最近联机樱花地址（点击直接直连）：", cx + 14, r2_y, { 238, 214, 168, 235 }, nil, nil, nil, fm.tiny_bold)
        local chip_y = r2_y + 20
        local chip_h = math.min(68, math.max(40, (y + tray_h - 12) - chip_y))
        local count = math.min(#rec, 3)
        local gap = 8
        local chip_w = math.floor((cw - 24 - (count - 1) * gap) / count)
        for ri = 1, count do
            local addr = rec[ri]
            local rx_c = cx + 12 + (ri - 1) * (chip_w + gap)
            local shown = mask_if_private(lobby, addr)
            local disp = (#shown > 24) and ("..." .. shown:sub(-21)) or shown
            local tag = lobby_prefs.is_sakura_addr(addr) and "樱花专线" or "直连地址"
            add_btn("use_recent_addr", tag .. "\n" .. disp, rx_c, chip_y, chip_w, chip_h, "wood", {
                tiny = true, addr = addr,
            })
        end
    else
        local step_h = math.min(106, math.max(70, (y + tray_h - 12) - r2_y))
        local gap = 8
        local sw3 = math.floor((cw - 24 - gap * 2) / 3)
        local steps = {
            {
                badge = "1. 房主开隧道建房",
                bg = T.p1_top, rim = T.p1_border,
                body = has_direct_rc
                    and "开 TCP 17777 隧道后建房，设置请关「强制TLS」。"
                    or "在樱花开 TCP 17777 隧道后点上方建房；建议关「强制TLS」和「自动HTTPS」降延迟。",
            },
            {
                badge = "2. 自动识别一键复制",
                bg = { 38, 128, 62, 245 }, rim = { 26, 86, 40, 255 },
                body = has_direct_rc
                    and "自动抓活跃地址；直播开防窥并选「多线」节点。"
                    or "本机自动抓取活跃隧道地址，点复制发给队友；直播/大群招人请开防窥并选「多线」节点。",
            },
            {
                badge = "3. 队友粘贴三线测速",
                bg = T.p2_top, rim = T.p2_border,
                body = has_direct_rc
                    and "点粘贴自动提取，三线测速选最快线，180s 热续传。"
                    or "队友复制整行日志点「粘贴」自动提取，可三线测速挑最快线，闪断享 180 秒无感热续传。",
            },
        }
        for si, st in ipairs(steps) do
            local sx = cx + 12 + (si - 1) * (sw3 + gap)
            ui.draw_parchment_card(sx, r2_y, sw3, step_h, {
                top = { 246, 236, 208, 246 }, bot = { 232, 214, 174, 246 },
                border = { 132, 94, 48, 220 }, border_w = 1.4, radius = 7,
            })
            ui.draw_pill(sx + 10, r2_y + 8, sw3 - 20, 20, st.badge, st.bg, st.rim, { 255, 252, 240, 255 }, fm.tiny_bold)
            ui.text(st.body, sx + 10, r2_y + 34, T.ink_sub, fm.tiny, sw3 - 20, "left")
        end
    end
end

local function draw_home_lan(ctx, y)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local has_direct_rc
    y, has_direct_rc = draw_direct_reconnect_banner(ctx, y)

    local card_w = math.floor((cw - 14) / 2)
    local card_h = has_direct_rc and 144 or 154
    local main_btn_h = has_direct_rc and 31 or 32
    local main_btn_y = y + card_h - (has_direct_rc and 38 or 40)

    -- Left Contract: 1P LAN Host (Symmetric CTA Alignment with Right Card)
    ui.draw_parchment_card(cx, y, card_w, card_h, {
        top = { 236, 240, 232, 250 }, bot = { 228, 214, 178, 250 },
        border = T.p1_border, border_w = 2, thumbtack = true,
    })
    ui.draw_pill(cx + 14, y + 10, 150, 20, "1P 房主 · 蓝方旗帜 (局域网)", T.p1_top, T.p1_border, { 242, 250, 255, 255 }, fm.tiny_bold)
    add_btn("join_local", "本机双开 (127.0.0.1)", cx + card_w - 134, y + 9, 120, 22, "parchment", { tiny = true })
    ui.text("设立同 Wi-Fi / 局域网战桌", cx + 14, y + 35, T.ink_text, fm.hero)
    ui.text("监听 TCP 17777 并自动向同 Wi-Fi / 宿舍网广播房间，队友在下方布告栏点击「揭榜加入」即可开玩。",
        cx + 14, y + 58, T.ink_sub, fm.tiny, card_w - 28, "left")
    add_btn("host_lan", "创建局域网房间并备战", cx + 14, main_btn_y, card_w - 28, main_btn_h, "battle", { small = false })

    -- Right Contract: 2P LAN Manual IP Join
    local rx = cx + card_w + 14
    ui.draw_parchment_card(rx, y, card_w, card_h, {
        top = { 250, 238, 226, 250 }, bot = { 234, 212, 176, 250 },
        border = T.p2_border, border_w = 2, thumbtack = true,
    })
    ui.draw_pill(rx + 14, y + 10, 146, 20, "2P 队友 · 局域网 IP 直连", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, fm.tiny_bold)
    ui.text("手动输入局域网 IP 直连", rx + 14, y + 35, T.ink_text, fm.hero)

    local lan_in = lobby.lan_ip_input or "127.0.0.1"
    local lan_focused = (lobby.focused_field == "lan_ip")
    local ip_disp = (#lan_in > 30) and ("..." .. lan_in:sub(-27)) or lan_in
    local ip_w = card_w - 28 - 64
    add_btn("lan_ip_box", ip_disp .. (lan_focused and "|" or ""), rx + 14, y + 55, ip_w, 24, "input", {
        small = true, focused = lan_focused,
    })
    add_btn("paste_lan_ip", "粘贴", rx + 14 + ip_w + 6, y + 55, 58, 24, "wood", { small = true })
    ui.text("适合同宿舍手输内网 IP，或用 Radmin VPN / 蒲公英 / ZeroTier 异地免实名直连。",
        rx + 14, y + 84, T.ink_muted, fm.tiny, card_w - 28, "left")

    local lan_connecting = (not lobby.transport:is_online()) and lobby.transport:is_connecting()
    add_btn("join_lan_ip", lan_connecting and "正在连接主机..." or "连接该局域网主机", rx + 14, main_btn_y, card_w - 28, main_btn_h, "crimson", { small = false })

    y = y + card_h + 10

    -- Bottom Dark-Oak Tavern Notice Board (100% Dedicated to UDP 17778 LAN Auto-Discovery)
    local tray_h = (py + ph - 22) - y
    ui.draw_armory_tray(cx, y, cw, tray_h, 9)
    local rooms = lobby.transport:get_lan_rooms()
    ui.draw_ping_dot(cx + 18, y + 18, 12, #rooms > 0)
    ui.print_shadow(string.format("酒馆布告栏 · 自动扫描附近局域网战桌 (UDP 17778 · %d 个房间)", #rooms),
        cx + 30, y + 11, T.gold_bright, nil, nil, nil, fm.small_bold)

    local list_top = y + 34
    if #rooms == 0 then
        local empty_y = list_top + math.max(8, math.floor((y + tray_h - list_top - 24) * 0.42))
        ui.text("暂未扫描到同 Wi-Fi 房间 · 请等待房主点「创建局域网房间」并允许 Windows 防火墙；异地开黑请切回顶部「樱花联机」。",
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
    local is_handshaking = (lobby.server_handshaking == true and not lobby.server_connected)
    local is_connecting = (lobby.transport:is_online() and lobby.transport:is_connecting()) or is_handshaking

    if lobby.saved_session and lobby.saved_session.mode ~= "direct" then
        local s = lobby.saved_session
        add_btn("reconnect_last",
            string.format("一键高速追帧重连：房间 #%s (%dP)  @  %s", tostring(s.code), tonumber(s.pid) or 2, tostring(s.server)),
            cx, y, cw, 32, "battle", { small = true })
        y = y + 40
    end

    ui.draw_parchment_card(cx, y, cw, 44, { radius = 7 })
    ui.text("服务器：", cx + 12, y + 14, T.ink_text, fm.small_bold)
    local sx = cx + 64
    local sw_in = cw - 64 - 224
    local srv_disp = lobby.server_input
    if #srv_disp > 40 then srv_disp = "..." .. srv_disp:sub(-37) end
    add_btn("server_box", srv_disp .. (lobby.focused_field == "server" and "|" or ""), sx, y + 7, sw_in, 28, "input", {
        small = true, focused = (lobby.focused_field == "server"),
    })
    add_btn("paste_server", "粘贴", sx + sw_in + 6, y + 7, 48, 28, "wood", { small = true })
    local conn_lbl = lobby.server_connected and ("已连 " .. lobby.transport:get_rtt_ms() .. "ms")
        or (is_handshaking and "握手中..." or (is_connecting and "连接中..." or "连接"))
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
    local sh = lobby.server_host
    local srv_btn_lbl = (sh and sh.running) and "本机服运行中 √ (管理)" or "一键自建公网服"
    local srv_btn_w = (sh and sh.running) and 142 or 116
    add_btn("open_server_host", srv_btn_lbl, cx + cw - srv_btn_w - 10, y + 6, srv_btn_w, 22, "battle", { tiny = true })

    if is_connecting then
        ui.text("正在连接并校验公网中继服协议（不卡界面），也可直接修改上方地址后点「连接」。",
            cx + 22, y + math.floor(tray_h * 0.44), { 246, 224, 174, 225 }, fm.small, cw - 44, "center")
    elseif not lobby.server_connected then
        ui.text("尚未连接公网中继服 · 樱花 17777 直连请切回「樱花联机」页；想零成本自建水友大厅请点右上绿色「一键自建公网服」！",
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
    local tab = lobby.net_tab or "sakura"
    local is_sakura = (tab == "sakura")
    local is_lan = (tab == "lan")
    local is_online = (tab == "online")
    add_btn("tab_sakura", "樱花联机", cx, y, 104, 28, is_sakura and "wood" or "parchment", { small = true, active = is_sakura })
    add_btn("tab_lan", "局域网", cx + 110, y, 84, 28, is_lan and "wood" or "parchment", { small = true, active = is_lan })
    add_btn("tab_online", "公网服务器", cx + 200, y, 108, 28, is_online and "wood" or "parchment", { small = true, active = is_online })

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
        cx + 314, y + 7, T.ink_muted, fm.tiny, cw - 320 - upd_w - guide_w - 8, "right")

    y = y + 36
    G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], 130)
    G.setLineWidth(1)
    G.line(cx, y, cx + cw, y)
    y = y + 10

    if is_sakura then
        draw_home_sakura(ctx, y)
    elseif is_lan then
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
        if not lobby.transport:is_online() then
            add_btn("open_sakura", "樱花助手", cx + cw - 284, y + 5, 70, 23, "azure", { tiny = true })
        end
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
    local sk_disp = nil
    if is_host and (not lobby.transport:is_online()) and (not port_drifted) and lobby.sakura then
        sk_disp = lobby.sakura:get_host_share_addr(lobby.transport:get_port())
    end
    if lobby.transport:is_online() then
        net_info = string.format("#%s (点复制) · %dms", tostring(lobby.online_room_code or "----"), rtt)
        net_style = "parchment"
    elseif port_drifted then
        net_info = string.format("警告!端口:%d!", lobby.transport:get_port())
        net_style = "crimson"
        net_fg = { 255, 244, 218, 255 }
    elseif is_host and sk_disp then
        local shown = mask_if_private(lobby, sk_disp)
        if #shown > 14 then shown = shown:sub(1, 13) .. ".." end
        net_info = "樱花:" .. shown
        net_style = "battle"
        net_fg = { 255, 252, 236, 255 }
    elseif is_host then
        net_info = string.format("TCP:%d(复制)·%dms", lobby.transport:get_port(), rtt)
        net_style = "parchment"
    else
        net_info = string.format("直连(复制)·%dms", rtt)
        net_style = "parchment"
    end
    local info_w = is_host and 166 or 154
    if is_host and not lobby.transport:is_online() then
        add_btn("copy_net_info", net_info, cx + 136, y, 138, 24, net_style, {
            tiny = true, fg = net_fg or T.ink_sub,
        })
        add_btn("toggle_privacy", lobby.privacy_mask and "隐" or "显", cx + 136 + 140, y, 26, 24,
            lobby.privacy_mask and "azure" or "parchment", { tiny = true })
    else
        add_btn("copy_net_info", net_info, cx + 136, y, info_w, 24, net_style, {
            tiny = true, fg = net_fg or T.ink_sub,
        })
    end

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
    elseif lobby.sub_modal == "sakura" then
        sakura_modal.draw(ctx)
    elseif lobby.sub_modal == "server_host" then
        server_modal.draw(ctx)
    elseif lobby.view == "home" then
        draw_home(ctx)
        ui.text("赤羽的王国保卫战联机器 · 永久免费开源（仅适配 FL 8.2.0 · 如付费购买请立刻退款）",
            ctx.cx, py + ph - 17, { 132, 102, 64, 215 }, font_map.tiny, ctx.cw, "center")
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
