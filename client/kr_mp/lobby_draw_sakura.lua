-- KR-MP SakuraFrp Assistant Sub-Modal Renderer
-- Displays:
--   Top card: Zero-secret local SakuraFrp status, active detected tunnel address, privacy masking toggle, 1-click launch/download
--   Bottom cards: Opt-in Official OpenAPI v4 (user-supplied Token only!) for remaining traffic, 1-click managed frpc start/stop,
--                 P2P Port-Export copy, and low-load node recommendation (with public-stream 多线 compliance filter)
local proto = require("kr_mp.proto")
local ui = require("kr_mp.ui_assets")

local M = {}

local function format_display_addr(lobby, addr)
    if not addr or #addr == 0 then return "未检测到活跃 TCP 隧道" end
    if lobby.privacy_mask and lobby.sakura then
        return lobby.sakura.mask_addr(addr)
    end
    return addr
end

function M.draw(ctx)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local sk = lobby.sakura
    local y = py + 42

    -- Header bar
    ui.draw_pill(cx, y + 1, 186, 26, "樱花映射专属助手 · SakuraFrp", { 162, 54, 96, 245 }, { 108, 28, 60, 255 }, { 255, 246, 250, 255 }, fm.small_bold)
    add_btn("toggle_privacy", lobby.privacy_mask and "防窥打码:开" or "防窥打码:关", cx + 194, y, 96, 28,
        lobby.privacy_mask and "azure" or "parchment", { tiny = true })
    add_btn("sakura_rescan", "刷新本机状态", cx + 296, y, 96, 28, "parchment", { tiny = true })
    if sk and sk.installed then
        add_btn("sakura_launch_app", "打开官方樱花", cx + 398, y, 102, 28, "wood", { tiny = true })
    else
        add_btn("sakura_launch_app", "下载官方樱花", cx + 398, y, 102, 28, "battle", { tiny = true })
    end
    add_btn("modal_back", lobby.view == "room" and "返回战桌" or "返回大厅", cx + cw - 92, y, 92, 28, "crimson", { small = true })
    y = y + 36

    -- Card 1: Zero-Secret Local Read-Only Detection
    local c1_h = 84
    ui.draw_parchment_card(cx, y, cw, c1_h, {
        top = { 242, 246, 236, 252 }, bot = { 228, 222, 192, 250 },
        border = { 54, 128, 72, 235 }, border_w = 1.8, radius = 8,
    })
    local host_port = (lobby.role == "host" and lobby.transport and lobby.transport:get_port()) or proto.DEFAULT_TCP_PORT
    local disp_addr, copy_addr, has_p2p = nil, nil, false
    if sk then
        disp_addr, copy_addr, has_p2p = sk:get_host_share_addr(host_port)
    end
    local inst_txt = (sk and sk.installed) and "已安装官方启动器" or "未检测到官方启动器"
    local run_txt = (sk and (sk.managed_proc or sk.frpc_running)) and "frpc 运行中 √"
        or ((sk and sk.service_running) and "后台服务运行中（未开隧道）" or "未运行")
    ui.text(string.format("免密钥本机自动感知：%s  ·  状态：%s", inst_txt, run_txt),
        cx + 12, y + 9, T.ink_text, fm.small_bold)
    if disp_addr then
        local p2p_tag = has_p2p and "  [含免费P2P优先]" or ""
        local spd_tag = (sk and sk.log_speed_text) and ("  ·  " .. sk.log_speed_text) or ""
        ui.text(string.format("已识别活跃地址：%s%s%s", format_display_addr(lobby, disp_addr), p2p_tag, spd_tag),
            cx + 12, y + 32, { 34, 108, 48, 255 }, fm.small_bold)
        add_btn("sakura_copy_detected", has_p2p and "复制P2P+中继地址" or "一键复制发给队友",
            cx + cw - 152, y + 10, 140, 28, "battle", { tiny = true, copy_addr = copy_addr })
        if sk and sk.managed_proc then
            add_btn("sakura_stop_frpc", "停止内置隧道", cx + cw - 152, y + 44, 140, 26, "crimson", { tiny = true })
        end
    else
        ui.text("提示：在官方樱花启动器打开 TCP 17777 隧道后会自动抓取地址；或在下方可选填入访问密钥游戏内一键开隧道。",
            cx + 12, y + 32, T.ink_sub, fm.tiny, cw - 24, "left")
    end
    if sk and sk.log_warning then
        ui.text(sk.log_warning, cx + 12, y + 58, { 166, 46, 36, 255 }, fm.tiny, cw - 170, "left")
    else
        ui.text("安全承诺：绝不读取官方启动器 config.json 中的任何密钥；上方防窥打码开启后适合主播直播防撞房。",
            cx + 12, y + 58, T.ink_muted, fm.tiny, cw - 170, "left")
    end
    y = y + c1_h + 10

    -- Card 2: Opt-in Official OpenAPI v4 Bar
    local tok_h = 56
    ui.draw_parchment_card(cx, y, cw, tok_h, { border = { 138, 94, 40, 235 }, border_w = 1.6, radius = 8 })
    ui.text("可选进阶 · 官方 API 密钥：", cx + 12, y + 10, T.ink_text, fm.tiny_bold)
    local tok = (sk and sk.token) or ""
    local tok_disp
    if #tok == 0 then
        tok_disp = "选填：粘贴 natfrp.com 访问密钥（仅本地保存）"
    else
        tok_disp = tok:sub(1, 3) .. string.rep("*", math.min(14, math.max(4, #tok - 5))) .. tok:sub(-2)
    end
    local tok_w = cw - 168 - 224
    add_btn("sakura_token_box", tok_disp .. (lobby.focused_field == "sakura_token" and "|" or ""),
        cx + 162, y + 6, tok_w, 24, "input", {
            tiny = true, placeholder = (#tok == 0 and lobby.focused_field ~= "sakura_token"),
            focused = (lobby.focused_field == "sakura_token"),
        })
    local bx = cx + 162 + tok_w + 6
    add_btn("paste_sakura_token", "粘贴密钥", bx, y + 6, 68, 24, "wood", { tiny = true })
    add_btn("sakura_api_refresh", (sk and sk.api_busy) and "同步中..." or "同步账号", bx + 72, y + 6, 70, 24, "azure", { tiny = true })
    add_btn("sakura_token_clear", "清空", bx + 146, y + 6, 46, 24, "parchment", { tiny = true })

    local pub_on = (sk and sk.public_mode == true)
    add_btn("sakura_toggle_public", pub_on and "公开直播合规(仅多线):开" or "公开直播合规(仅多线):关",
        cx + 12, y + 33, 174, 19, pub_on and "battle" or "parchment", { tiny = true })
    if sk and sk.user_info then
        local u = sk.user_info
        ui.text(string.format("%s (%s) · 剩余 %.1f GiB · 限速 %s · 隧道上限 %d",
            u.name, u.group_name, u.remain_gib, u.speed, u.tunnels_max),
            cx + 194, y + 36, { 34, 108, 48, 255 }, fm.tiny, cw - 206, "left")
    elseif sk and sk.api_error then
        ui.text("状态：" .. tostring(sk.api_error), cx + 194, y + 36, { 166, 42, 36, 255 }, fm.tiny, cw - 206, "left")
    else
        ui.text("私下熟人开黑可任选低负载节点；若在直播间/大群公开招人，请开启左侧多线合规筛选防封号！",
            cx + 194, y + 36, T.ink_muted, fm.tiny, cw - 206, "left")
    end
    y = y + tok_h + 10

    -- Bottom Split Tray: Left = Existing TCP Tunnels, Right = Low-Load Recommended Nodes (1-Click Create 17777)
    local tray_h = (py + ph - 20) - y
    local lw = math.floor((cw - 10) * 0.54)
    local rw = cw - lw - 10
    local rx = cx + lw + 10

    -- Left tray: User's TCP tunnels
    ui.draw_armory_tray(cx, y, lw, tray_h, 9)
    local tlist = (sk and sk.tunnels) or {}
    ui.print_shadow(string.format("我的 TCP 隧道 (%d · 优先 17777)", #tlist), cx + 12, y + 9, T.gold_bright, nil, nil, nil, fm.small_bold)
    if #tlist == 0 then
        ui.text((sk and sk.user_info)
            and "账号下暂无 TCP 隧道，可在右侧挑选一个低负载节点「一键建 17777 隧道」！"
            or "在上方粘贴并同步樱花访问密钥后，即可在此一键启停 17777 隧道或新建低负载隧道。",
            cx + 14, y + math.floor(tray_h * 0.42), { 232, 206, 158, 220 }, fm.tiny, lw - 28, "center")
    else
        local max_t = math.max(1, math.floor((tray_h - 34) / 42))
        for i = 1, math.min(#tlist, max_t) do
            local t = tlist[i]
            local ty = y + 32 + (i - 1) * 42
            local is_mine = (sk and sk.managed_proc and sk.managed_proc.tunnel_id == t.id)
            local online_now = is_mine or t.online
            ui.draw_parchment_card(cx + 8, ty, lw - 16, 38, {
                radius = 5,
                border = t.is_krmp and T.p1_border or T.parchment_edge,
                border_w = t.is_krmp and 1.6 or 1.0,
            })
            local st_tag = is_mine and "[内置运行]" or (t.online and "[在线]" or "[离线]")
            ui.text(string.format("%s %s (:%d)%s", st_tag, t.name, t.local_port, t.p2p_addr and " P2P" or ""),
                cx + 14, ty + 4, online_now and { 32, 108, 48, 255 } or T.ink_text, fm.tiny_bold, lw - 144, "left")
            local sub = t.addr and format_display_addr(lobby, t.addr) or (t.node_name .. " :" .. tostring(t.remote))
            ui.text(sub, cx + 14, ty + 20, T.ink_muted, fm.tiny, lw - 144, "left")

            if t.addr then
                local c_addr = t.p2p_addr and (t.p2p_addr .. "|" .. t.addr) or t.addr
                add_btn("sakura_copy_detected", "复制", cx + lw - 122, ty + 7, 46, 24, "parchment", { tiny = true, copy_addr = c_addr })
            end
            if is_mine then
                add_btn("sakura_stop_frpc", "停止", cx + lw - 72, ty + 7, 56, 24, "crimson", { tiny = true })
            elseif t.online then
                add_btn("sakura_use_online", "已开√", cx + lw - 72, ty + 7, 56, 24, "wood", { tiny = true, tunnel = t })
            else
                add_btn("sakura_start_frpc", "启动", cx + lw - 72, ty + 7, 56, 24, "battle", { tiny = true, tunnel = t })
            end
        end
    end

    -- Right tray: Low-Load Recommended Nodes -> 1-click Create 17777 Tunnel
    ui.draw_armory_tray(rx, y, rw, tray_h, 9)
    local nlist = (sk and sk.recommended_nodes) or {}
    local r_title = pub_on and "低负载合规多线节点 (建17777)" or "低负载推荐节点 (一键建17777)"
    ui.print_shadow(r_title, rx + 12, y + 9, T.gold_bright, nil, nil, nil, fm.small_bold)
    if #nlist == 0 then
        ui.text((sk and sk.user_info)
            and (pub_on and "当前账号暂无可创建的合规「多线」节点，可先关闭多线筛选（仅限私下熟人开黑）或升级节点。"
                or "当前暂无可新建隧道的空闲节点，请稍后刷新。")
            or "同步账号后将自动读取全网实时负载，按低延迟内地节点排序，点击即可自动建好 TCP 17777（关闭自动HTTPS）。",
            rx + 14, y + math.floor(tray_h * 0.40), { 232, 206, 158, 220 }, fm.tiny, rw - 28, "center")
    else
        local max_n = math.max(1, math.floor((tray_h - 34) / 42))
        for i = 1, math.min(#nlist, max_n) do
            local nd = nlist[i]
            local ny = y + 32 + (i - 1) * 42
            ui.draw_parchment_card(rx + 8, ny, rw - 16, 38, { radius = 5 })
            local tag = nd.is_public_ok and "[多线]" or "[普通]"
            ui.text(string.format("%s %s", tag, nd.name), rx + 14, ny + 4, T.ink_text, fm.tiny_bold, rw - 104, "left")
            ui.text(string.format("负载 %d%% · %s", math.floor(nd.load + 0.5), nd.vip > 0 and ("VIP" .. nd.vip) or "免费"),
                rx + 14, ny + 20, nd.load <= 45 and { 34, 114, 50, 255 } or T.ink_muted, fm.tiny, rw - 104, "left")
            add_btn("sakura_create_tunnel", "建17777", rx + rw - 82, ny + 7, 66, 24, "azure", {
                tiny = true, node_id = nd.id, node_name = nd.name,
            })
        end
    end
end

return M
