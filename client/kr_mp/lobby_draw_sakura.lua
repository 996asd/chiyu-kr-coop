-- KR-MP SakuraFrp Assistant Sub-Modal Renderer (Calibrated for 780x486 Ironhide War-Table)
-- Displays:
--   Top bar   : Privacy toggle, local rescan, 4-step wizard toggle, 1-click official installer / launcher
--   Card 1    : Zero-secret local SakuraFrp status, live official installer download progress bar, active tunnel address
--   Card 2    : Opt-in Official OpenAPI v4 token bar (1-click paste & login), real-name check, 多线 compliance toggle
--   Bottom    : Either the 4-step interactive onboarding wizard (for new hosts) OR split view (My TCP Tunnels + Paginated Low-Load Nodes)
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

local function draw_dl_progress_bar(x, y, w, h, pct, stage, ver, done_b, total_b, fm)
    love.graphics.setColor(58, 42, 26, 225)
    love.graphics.rectangle("fill", x, y, w, h, 4, 4)
    local fill_w = math.max(0, math.min(w - 2, math.floor((w - 2) * (pct / 100))))
    if fill_w > 0 then
        love.graphics.setColor(54, 152, 74, 245)
        love.graphics.rectangle("fill", x + 1, y + 1, fill_w, h - 2, 3, 3)
    end
    love.graphics.setColor(168, 128, 70, 235)
    love.graphics.setLineWidth(1.2)
    love.graphics.rectangle("line", x, y, w, h, 4, 4)
    local lbl
    if stage == "meta" then
        lbl = "正在连接樱花官方源获取最新版本信息..."
    elseif stage == "verifying" then
        lbl = string.format("正在校验官方安装器 v%s 完整性 (MD5)...", tostring(ver or ""))
    else
        local dm = (done_b or 0) / 1048576
        local tm = (total_b or 0) / 1048576
        if tm > 0 then
            lbl = string.format("正在下载官方 SakuraLauncher v%s：%.1f / %.1f MB (%d%%)", tostring(ver or ""), dm, tm, pct)
        else
            lbl = string.format("正在下载官方 SakuraLauncher v%s：%.1f MB...", tostring(ver or ""), dm)
        end
    end
    ui.text(lbl, x + 6, y + 2, { 255, 250, 234, 255 }, fm.tiny_bold, w - 12, "center")
end

local function draw_wizard_tray(ctx, y, tray_h, disp_addr)
    local lobby, T, cx, cw, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.font_map, ctx.add_btn
    local sk = lobby.sakura
    local u = sk and sk.user_info or nil
    local installed = (sk and sk.installed == true)
    local dl_busy = (sk and sk.dl_busy == true)
    local dl_pct = (sk and sk:get_download_pct()) or 0

    ui.draw_armory_tray(cx, y, cw, tray_h, 9)
    ui.print_shadow("零基础 4 步开樱花（仅房主需要，队友完全不用下载、不用注册！）",
        cx + 12, y + 8, T.gold_bright, nil, nil, nil, fm.small_bold)
    add_btn("sakura_toggle_wizard", u and "返回隧道面板" or "直接看隧道面板",
        cx + cw - 118, y + 5, 108, 21, "parchment", { tiny = true })

    local gx = cx + 10
    local gy = y + 30
    local gap = 8
    local col_w = math.floor((cw - 20 - gap) / 2)
    local row_h = math.floor((tray_h - 38 - gap) / 2)

    local function draw_step_card(col, row, step_no, title, badge_txt, badge_kind, desc)
        local sx = gx + (col - 1) * (col_w + gap)
        local sy = gy + (row - 1) * (row_h + gap)
        local border_col = (badge_kind == "ok") and { 52, 134, 70, 235 }
            or ((badge_kind == "warn") and { 174, 52, 42, 235 } or T.parchment_edge)
        ui.draw_parchment_card(sx, sy, col_w, row_h, { radius = 7, border = border_col, border_w = 1.6 })
        ui.draw_pill(sx + 10, sy + 7, 50, 19, "步骤 " .. tostring(step_no),
            { 72, 48, 28, 235 }, { 148, 112, 62, 220 }, T.gold_bright, fm.tiny_bold)
        ui.text(title, sx + 66, sy + 9, T.ink_text, fm.small_bold, col_w - 150, "left")
        local b_bg = (badge_kind == "ok") and { 38, 128, 62, 240 }
            or ((badge_kind == "warn") and { 166, 46, 36, 240 } or { 126, 86, 36, 225 })
        local b_bd = (badge_kind == "ok") and { 24, 84, 40, 255 }
            or ((badge_kind == "warn") and { 112, 26, 20, 255 } or { 86, 56, 20, 245 })
        ui.draw_pill(sx + col_w - 78, sy + 7, 68, 19, badge_txt, b_bg, b_bd, { 255, 250, 242, 255 }, fm.tiny_bold)
        ui.text(desc, sx + 10, sy + 30, T.ink_sub, fm.tiny, col_w - 20, "left")
        return sx, sy, sy + row_h - 30
    end

    local bw2 = math.floor((col_w - 26) / 2)

    -- Step 1: Install Official SakuraLauncher
    local s1x, _, s1by = draw_step_card(1, 1, 1, "安装官方樱花启动器",
        installed and "已安装 √" or (dl_busy and (dl_pct .. "%") or "未安装"),
        installed and "ok" or "todo",
        "直连官方源下载正版并自动 MD5 校验；弹管理员确认点「是」（队友不用装）。")
    if installed then
        add_btn("sakura_launch_app", "启动官方樱花", s1x + 10, s1by, bw2, 23, "wood", { tiny = true })
    elseif dl_busy then
        add_btn("sakura_download_official", string.format("官方下载中 %d%%", dl_pct), s1x + 10, s1by, bw2, 23, "wood", { tiny = true })
    else
        add_btn("sakura_download_official", "一键下载并安装", s1x + 10, s1by, bw2, 23, "battle", { tiny = true })
    end
    add_btn("sakura_open_download_page", "打开官方下载页", s1x + 16 + bw2, s1by, bw2, 23, "parchment", { tiny = true })

    -- Step 2: Register & Real-Name
    local rn_badge, rn_kind = "官网办理", "todo"
    if u then
        if tonumber(u.realname) == 0 then
            rn_badge, rn_kind = "未实名!", "warn"
        else
            rn_badge, rn_kind = "已实名 √", "ok"
        end
    end
    local s2x, _, s2by = draw_step_card(2, 1, 2, "注册账号并完成实名",
        rn_badge, rn_kind,
        "注册账号并用支付宝实名（官方通常收 1 元），实名后免费送多线节点与流量。")
    add_btn("sakura_open_register", "1. 去官网注册/登录", s2x + 10, s2by, bw2, 23, "azure", { tiny = true })
    add_btn("sakura_open_realname", "2. 去完成实名认证", s2x + 16 + bw2, s2by, bw2, 23,
        rn_kind == "warn" and "crimson" or "parchment", { tiny = true })

    -- Step 3: Copy Access Token & 1-Click Login
    local s3x, _, s3by = draw_step_card(1, 2, 3, "复制访问密钥一键登录",
        u and "已登录 √" or "待填入",
        u and "ok" or "todo",
        "打开官网「用户信息」复制访问密钥，回游戏点右下绿色按钮自动填入登录。")
    add_btn("sakura_open_profile", "打开用户信息页", s3x + 10, s3by, bw2, 23, "wood", { tiny = true })
    add_btn("sakura_paste_and_sync", "我已复制，粘贴登录", s3x + 16 + bw2, s3by, bw2, 23, "battle", { tiny = true })

    -- Step 4: Create & Start 17777 Tunnel
    local s4x, _, s4by = draw_step_card(2, 2, 4, "建/启 TCP 17777 隧道",
        disp_addr and "隧道就绪 √" or "最后一步",
        disp_addr and "ok" or "todo",
        "登录后挑低负载节点「建17777」并启动；或官方软件直开，战桌自动抓地址！")
    if u then
        add_btn("sakura_toggle_wizard", "进入隧道与低负载节点面板", s4x + 10, s4by, col_w - 20, 23, "battle", { tiny = true })
    else
        add_btn("sakura_launch_app", installed and "免密钥开官方樱花" or "先完成步骤 1 安装",
            s4x + 10, s4by, bw2, 23, "wood", { tiny = true })
        add_btn("sakura_rescan", "已开隧道？刷新检测", s4x + 16 + bw2, s4by, bw2, 23, "parchment", { tiny = true })
    end
end

local function draw_tunnels_and_nodes(ctx, y, tray_h, pub_on)
    local lobby, T, cx, cw, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.font_map, ctx.add_btn
    local sk = lobby.sakura
    local lw = math.floor((cw - 10) * 0.54)
    local rw = cw - lw - 10
    local rx = cx + lw + 10

    -- Left tray: User's TCP tunnels
    ui.draw_armory_tray(cx, y, lw, tray_h, 9)
    local tlist = (sk and sk.tunnels) or {}
    ui.print_shadow(string.format("我的 TCP 隧道 (%d · 优先 17777)", #tlist), cx + 12, y + 8, T.gold_bright, nil, nil, nil, fm.small_bold)
    if #tlist == 0 then
        ui.text((sk and sk.user_info)
            and "账号下暂无 TCP 隧道，可在右侧挑选一个低负载节点「建17777」！"
            or "在上方粘贴并登录樱花访问密钥后，即可在此一键启停 17777 隧道或新建低负载隧道。",
            cx + 14, y + math.floor(tray_h * 0.42), { 232, 206, 158, 220 }, fm.tiny, lw - 28, "center")
    else
        local max_t = math.max(1, math.floor((tray_h - 32) / 42))
        for i = 1, math.min(#tlist, max_t) do
            local t = tlist[i]
            local ty = y + 30 + (i - 1) * 42
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
            local sub
            if t.addr then
                sub = format_display_addr(lobby, t.addr)
            else
                sub = t.node_name .. " :" .. (lobby.privacy_mask and "*****" or tostring(t.remote))
            end
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

    -- Right tray: Paginated Low-Load Recommended Nodes -> 1-click Create 17777 Tunnel
    ui.draw_armory_tray(rx, y, rw, tray_h, 9)
    local nlist = (sk and sk.recommended_nodes) or {}
    local per_page = math.max(1, math.floor((tray_h - 32) / 42))
    local total_pages = math.max(1, math.ceil(#nlist / per_page))
    local cur_page = math.max(1, math.min(total_pages, (sk and tonumber(sk.node_page)) or 1))
    if sk then sk.node_page = cur_page end

    local r_title = pub_on
        and string.format("合规多线节点 (%d个)", #nlist)
        or string.format("全部低负载节点 (%d个)", #nlist)
    ui.print_shadow(r_title, rx + 12, y + 8, T.gold_bright, nil, nil, nil, fm.small_bold)
    if total_pages > 1 then
        add_btn("sakura_nodes_prev", "<", rx + rw - 92, y + 5, 24, 20, "parchment", { tiny = true, total_pages = total_pages })
        ui.text(string.format("%d/%d", cur_page, total_pages), rx + rw - 66, y + 8, T.gold_bright, fm.tiny_bold, 32, "center")
        add_btn("sakura_nodes_next", ">", rx + rw - 32, y + 5, 24, 20, "parchment", { tiny = true, total_pages = total_pages })
    end

    if #nlist == 0 then
        ui.text((sk and sk.user_info)
            and (pub_on and "当前账号暂无可创建的合规「多线」节点，可先关闭多线筛选（仅限私下熟人开黑）或升级节点。"
                or "当前暂无可新建隧道的空闲节点，请稍后刷新。")
            or "登录账号后自动按低延迟内地负载升序推荐，点右侧按钮一键建好 TCP 17777（自动关闭 HTTPS）。",
            rx + 14, y + math.floor(tray_h * 0.40), { 232, 206, 158, 220 }, fm.tiny, rw - 28, "center")
    else
        local start_idx = (cur_page - 1) * per_page + 1
        local end_idx = math.min(#nlist, start_idx + per_page - 1)
        for i = start_idx, end_idx do
            local nd = nlist[i]
            local row_i = i - start_idx + 1
            local ny = y + 30 + (row_i - 1) * 42
            ui.draw_parchment_card(rx + 8, ny, rw - 16, 38, { radius = 5 })
            local tag = nd.is_public_ok and "[多线]" or "[普通]"
            ui.text(string.format("%s %s", tag, nd.name), rx + 14, ny + 4,
                nd.is_public_ok and { 32, 102, 54, 255 } or T.ink_text, fm.tiny_bold, rw - 104, "left")
            ui.text(string.format("负载 %d%% · %s", math.floor(nd.load + 0.5), nd.vip > 0 and ("VIP" .. nd.vip) or "免费"),
                rx + 14, ny + 20, nd.load <= 45 and { 34, 114, 50, 255 } or T.ink_muted, fm.tiny, rw - 104, "left")
            add_btn("sakura_create_tunnel", "建17777", rx + rw - 82, ny + 7, 66, 24, "azure", {
                tiny = true, node_id = nd.id, node_name = nd.name,
            })
        end
    end
end

function M.draw(ctx)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local sk = lobby.sakura
    local y = py + 38
    local show_wizard = (lobby.sakura_show_wizard == true) or (not (sk and sk.user_info) and lobby.sakura_wizard_dismissed ~= true)

    -- Header bar
    ui.draw_pill(cx, y + 1, 186, 24, "樱花映射专属助手 · SakuraFrp", { 162, 54, 96, 245 }, { 108, 28, 60, 255 }, { 255, 246, 250, 255 }, fm.small_bold)
    add_btn("toggle_privacy", lobby.privacy_mask and "防窥:开" or "防窥:关", cx + 192, y, 76, 26,
        lobby.privacy_mask and "azure" or "parchment", { tiny = true })
    add_btn("sakura_rescan", "刷新状态", cx + 274, y, 74, 26, "parchment", { tiny = true })
    add_btn("sakura_toggle_wizard", show_wizard and "隧道面板" or "4步向导", cx + 354, y, 78, 26,
        show_wizard and "azure" or "parchment", { tiny = true })
    if sk and sk.installed then
        add_btn("sakura_launch_app", "打开官方樱花", cx + 438, y, 108, 26, "wood", { tiny = true })
    elseif sk and sk.dl_busy then
        add_btn("sakura_download_official", string.format("下载中 %d%%", sk:get_download_pct()), cx + 438, y, 108, 26, "wood", { tiny = true })
    else
        add_btn("sakura_download_official", "一键装官方樱花", cx + 438, y, 108, 26, "battle", { tiny = true })
    end
    add_btn("modal_back", lobby.view == "room" and "返回战桌" or "返回大厅", cx + cw - 92, y, 92, 26, "crimson", { small = true })
    y = y + 32

    -- Card 1: Zero-Secret Local Read-Only Detection & Official Installer Progress (Compact 72px)
    local c1_h = 72
    ui.draw_parchment_card(cx, y, cw, c1_h, {
        top = { 242, 246, 236, 252 }, bot = { 228, 222, 192, 250 },
        border = { 54, 128, 72, 235 }, border_w = 1.8, radius = 8,
    })
    local host_port = (lobby.role == "host" and lobby.transport and lobby.transport:get_port()) or proto.DEFAULT_TCP_PORT
    local disp_addr, copy_addr, has_p2p = nil, nil, false
    if sk then
        disp_addr, copy_addr, has_p2p = sk:get_host_share_addr(host_port)
    end
    local inst_txt = (sk and sk.installed) and "已安装官方启动器" or "未安装官方启动器"
    local run_txt = (sk and (sk.managed_proc or sk.frpc_running)) and "frpc 运行中 √"
        or ((sk and sk.service_running) and "后台服务运行中（未开隧道）" or "未运行")
    ui.text(string.format("免密钥本机自动感知：%s  ·  状态：%s", inst_txt, run_txt),
        cx + 12, y + 7, T.ink_text, fm.small_bold, cw - 172, "left")

    if sk and sk.dl_busy then
        draw_dl_progress_bar(cx + 12, y + 27, cw - 176, 18, sk:get_download_pct(), sk.dl_stage, sk.dl_ver, sk.dl_done_bytes, sk.dl_total_bytes, fm)
        add_btn("sakura_open_download_page", "官网手动下载", cx + cw - 152, y + 22, 140, 28, "parchment", { tiny = true })
    elseif disp_addr then
        local p2p_tag = has_p2p and "  [含免费P2P优先]" or ""
        local spd_tag = (sk and sk.log_speed_text) and ("  ·  " .. sk.log_speed_text) or ""
        ui.text(string.format("已识别活跃地址：%s%s%s", format_display_addr(lobby, disp_addr), p2p_tag, spd_tag),
            cx + 12, y + 28, { 34, 108, 48, 255 }, fm.small_bold, cw - 172, "left")
        if sk and sk.managed_proc then
            add_btn("sakura_copy_detected", has_p2p and "复制P2P+中继" or "一键复制发给队友",
                cx + cw - 152, y + 8, 140, 26, "battle", { tiny = true, copy_addr = copy_addr })
            add_btn("sakura_stop_frpc", "停止内置隧道", cx + cw - 152, y + 39, 140, 25, "crimson", { tiny = true })
        else
            add_btn("sakura_copy_detected", has_p2p and "复制P2P+中继地址" or "一键复制发给队友",
                cx + cw - 152, y + 22, 140, 28, "battle", { tiny = true, copy_addr = copy_addr })
        end
    elseif sk and sk.dl_error then
        ui.text("下载异常：" .. tostring(sk.dl_error), cx + 12, y + 28, { 166, 46, 36, 255 }, fm.tiny_bold, cw - 172, "left")
        add_btn("sakura_download_official", "重试下载安装", cx + cw - 152, y + 8, 140, 26, "battle", { tiny = true })
        add_btn("sakura_open_download_page", "打开官网下载页", cx + cw - 152, y + 39, 140, 25, "parchment", { tiny = true })
    elseif sk and sk.dl_path and not sk.installed then
        ui.text("官方安装包已拉起！按安装向导点完成后，点右侧「我已装好刷新」即可自动识别。",
            cx + 12, y + 28, { 34, 108, 48, 255 }, fm.tiny_bold, cw - 172, "left")
        add_btn("sakura_rescan", "我已装好，刷新", cx + cw - 152, y + 8, 140, 26, "battle", { tiny = true })
        add_btn("sakura_download_official", "重新拉起安装包", cx + cw - 152, y + 39, 140, 25, "parchment", { tiny = true })
    else
        ui.text((sk and sk.installed)
            and "提示：在官方樱花启动器打开 TCP 17777 隧道后会自动抓取地址；或在下方登录密钥游戏内一键建/启隧道。"
            or "提示：仅房主（1P）需要安装樱花映射，队友（2P）不用装！点右侧可直连官方源自动下载并校验安装。",
            cx + 12, y + 28, T.ink_sub, fm.tiny, cw - 172, "left")
        if sk and sk.installed then
            add_btn("sakura_launch_app", "启动官方樱花", cx + cw - 152, y + 22, 140, 28, "wood", { tiny = true })
        else
            add_btn("sakura_download_official", "一键下载并安装", cx + cw - 152, y + 22, 140, 28, "battle", { tiny = true })
        end
    end

    local sk_warn = (sk and sk.get_active_warning) and sk:get_active_warning(lobby) or nil
    if sk_warn then
        ui.text(sk_warn, cx + 12, y + 51, { 166, 46, 36, 255 }, fm.tiny, cw - 176, "left")
    else
        ui.text("安全承诺：绝不读取官方启动器 config.json 中的任何密钥；直连樱花官方源并自动 MD5 校验。",
            cx + 12, y + 51, T.ink_muted, fm.tiny, cw - 176, "left")
    end
    y = y + c1_h + 8

    -- Card 2: Opt-in Official OpenAPI v4 Bar (58px with generous Row 2 pill height)
    local tok_h = 58
    ui.draw_parchment_card(cx, y, cw, tok_h, { border = { 138, 94, 40, 235 }, border_w = 1.6, radius = 8 })
    ui.text("可选进阶 · 官方 API 密钥：", cx + 12, y + 9, T.ink_text, fm.tiny_bold)
    local tok = (sk and sk.token) or ""
    local tok_disp
    if #tok == 0 then
        tok_disp = "选填：复制访问密钥后点「粘贴并登录」（仅本地保存）"
    else
        tok_disp = tok:sub(1, 3) .. string.rep("*", math.min(14, math.max(4, #tok - 5))) .. tok:sub(-2)
    end
    local tok_w = cw - 162 - 216
    add_btn("sakura_token_box", tok_disp .. (lobby.focused_field == "sakura_token" and "|" or ""),
        cx + 162, y + 6, tok_w, 23, "input", {
            tiny = true, placeholder = (#tok == 0 and lobby.focused_field ~= "sakura_token"),
            focused = (lobby.focused_field == "sakura_token"),
        })
    local bx = cx + 162 + tok_w + 6
    add_btn("sakura_paste_and_sync", "粘贴并登录", bx, y + 6, 78, 23, "battle", { tiny = true })
    add_btn("sakura_api_refresh", (sk and sk.api_busy) and "同步中..." or "同步账号", bx + 82, y + 6, 70, 23, "azure", { tiny = true })
    add_btn("sakura_token_clear", "清空", bx + 156, y + 6, 46, 23, "parchment", { tiny = true })

    local pub_on = (sk and sk.public_mode == true)
    add_btn("sakura_toggle_public", pub_on and "公开直播合规(仅多线):开" or "公开直播合规(仅多线):关",
        cx + 12, y + 32, 182, 21, pub_on and "battle" or "parchment", { tiny = true })
    if sk and sk.user_info and tonumber(sk.user_info.realname) == 0 then
        ui.text(string.format("%s · 账号尚未完成实名认证（国内节点需在官网实名后才能建/启隧道）", sk.user_info.name),
            cx + 202, y + 36, { 172, 42, 34, 255 }, fm.tiny_bold, cw - 302, "left")
        add_btn("sakura_open_realname", "去官网实名", cx + cw - 94, y + 32, 82, 21, "crimson", { tiny = true })
    elseif sk and sk.user_info then
        local u = sk.user_info
        ui.text(string.format("%s (%s) · 剩余 %.1f GiB · 限速 %s · 隧道上限 %d",
            u.name, u.group_name, u.remain_gib, u.speed, u.tunnels_max),
            cx + 202, y + 36, { 34, 108, 48, 255 }, fm.tiny, cw - 214, "left")
    elseif sk and sk.api_error then
        ui.text("状态：" .. tostring(sk.api_error), cx + 202, y + 36, { 166, 42, 36, 255 }, fm.tiny, cw - 214, "left")
    else
        ui.text("私下熟人开黑可任选低负载节点；若在直播间/大群公开招人，请开启左侧多线合规筛选防封号！",
            cx + 202, y + 36, T.ink_muted, fm.tiny, cw - 214, "left")
    end
    y = y + tok_h + 8

    -- Bottom Area: 4-Step Interactive Onboarding Wizard OR Tunnels & Paginated Nodes
    local tray_h = (py + ph - 18) - y
    if show_wizard then
        draw_wizard_tray(ctx, y, tray_h, disp_addr)
    else
        draw_tunnels_and_nodes(ctx, y, tray_h, pub_on)
    end
end

return M
