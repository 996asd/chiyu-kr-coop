-- KR-MP Beginner-Friendly 1-Click Public Relay Server Modal (Calibrated for 780x486 War-Table)
-- Step 1: 1-click download/verify & zero-popup launch of local kr-mp-server.exe (TCP 17780)
-- Step 2: Seamless SakuraFrp TCP 17780 linkage so friends join without installing SakuraFrp
-- Step 3: 1-line Linux VPS deployment command for 24/7 community servers
local ui = require("kr_mp.ui_assets")

local M = {}

local function mask_addr(lobby, addr)
    if lobby.privacy_mask and lobby.sakura and type(addr) == "string" and #addr > 0 then
        return lobby.sakura.mask_addr(addr)
    end
    return tostring(addr or "")
end

local function draw_dl_bar(x, y, w, h, pct, stage, ver, done_b, total_b, fm, item_name, verify_alg)
    local name = item_name or "官方服务端 kr-mp-server.exe"
    local alg = verify_alg or "SHA-256"
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
        lbl = string.format("正在连接官方源获取 %s 最新版本与校验信息...", name)
    elseif stage == "verifying" then
        lbl = string.format("正在校验 %s v%s 完整性 (%s)...", name, tostring(ver or ""), alg)
    else
        local dm = (done_b or 0) / 1048576
        local tm = (total_b or 0) / 1048576
        if tm > 0 then
            lbl = string.format("正在下载 %s：%.1f / %.1f MB (%d%%)", name, dm, tm, pct)
        else
            lbl = string.format("正在下载 %s：%.1f MB...", name, dm)
        end
    end
    ui.text(lbl, x + 6, y + 2, { 255, 250, 234, 255 }, fm.tiny_bold, w - 12, "center")
end

function M.draw(ctx)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local sh = lobby.server_host
    local sk = lobby.sakura
    local y = py + 38

    -- Top Header Bar
    ui.draw_pill(cx, y + 1, 186, 24, "傻瓜式开服助手 · TCP 17780", { 46, 98, 152, 245 }, { 26, 58, 98, 255 }, { 244, 250, 255, 255 }, fm.small_bold)
    local keep_on = (sh == nil) or (sh.keep_running_on_exit ~= false)
    add_btn("srv_toggle_keep", keep_on and "退游戏保活:开" or "退游戏保活:关", cx + 192, y, 106, 26,
        keep_on and "azure" or "parchment", { tiny = true })
    add_btn("toggle_privacy", lobby.privacy_mask and "防窥:开" or "防窥:关", cx + 304, y, 72, 26,
        lobby.privacy_mask and "azure" or "parchment", { tiny = true })
    add_btn("srv_rescan", "刷新状态", cx + 382, y, 72, 26, "parchment", { tiny = true })
    add_btn("modal_back", "返回公网大厅", cx + cw - 98, y, 98, 26, "crimson", { small = true })
    y = y + 32

    -- Honest Beginner Tip Strip (30px)
    ui.draw_parchment_card(cx, y, cw, 28, {
        top = { 246, 240, 222, 245 }, bot = { 236, 224, 194, 245 },
        border = { 164, 126, 66, 220 }, border_w = 1.2, radius = 6,
    })
    ui.text("提示：仅 2 人双排用「樱花联机」更简单！本页适合开「多人水友大厅 / 4位房间码 / 1P闪退也能保局 5 分钟」。",
        cx + 10, y + 7, T.ink_sub, fm.tiny_bold, cw - 20, "center")
    y = y + 34

    -- Step 1 Card: Zero-Cost Local Relay Server (104px)
    local c1_h = 104
    local running = (sh and sh.running == true)
    local dl_busy = (sh and sh.dl_busy == true)
    local dl_pct = (sh and sh:get_download_pct()) or 0
    local has_bin = (sh and sh.binary_path ~= nil)
    ui.draw_parchment_card(cx, y, cw, c1_h, {
        top = { 242, 246, 236, 252 }, bot = { 228, 222, 192, 250 },
        border = running and { 48, 134, 68, 240 } or T.p1_border, border_w = 1.8, radius = 8,
    })
    ui.draw_pill(cx + 10, y + 8, 50, 19, "步骤 1", { 72, 48, 28, 235 }, { 148, 112, 62, 220 }, T.gold_bright, fm.tiny_bold)
    ui.text("一键启动本机公网中继服（零成本 · 端口 17780）", cx + 66, y + 10, T.ink_text, fm.small_bold, cw - 196, "left")
    local b1_txt = running and "运行中 √" or (dl_busy and (dl_pct .. "%") or (has_bin and "已就绪" or "需自动下载"))
    local b1_bg = running and { 38, 128, 62, 240 } or { 126, 86, 36, 225 }
    local b1_bd = running and { 24, 84, 40, 255 } or { 86, 56, 20, 245 }
    ui.draw_pill(cx + cw - 92, y + 8, 80, 19, b1_txt, b1_bg, b1_bd, { 255, 250, 242, 255 }, fm.tiny_bold)

    if dl_busy then
        draw_dl_bar(cx + 12, y + 34, cw - 24, 20, dl_pct, sh.dl_stage, sh.dl_ver, sh.dl_done_bytes, sh.dl_total_bytes, fm)
    elseif sh and sh.dl_error then
        ui.text("下载异常：" .. tostring(sh.dl_error) .. "（也可直接下载 full-and-server 完整包解压 server 文件夹）",
            cx + 12, y + 34, { 166, 46, 36, 255 }, fm.tiny, cw - 24, "left")
    elseif running then
        local lan_s = (sh and sh.lan_ip) and (sh.lan_ip .. ":17780") or "本机内网IP:17780"
        ui.text("本机中继服运行中 (127.0.0.1:17780) √ · 同 Wi-Fi 队友可直接连 " .. mask_addr(lobby, lan_s) .. "；外网水友请看步骤 2。",
            cx + 12, y + 34, { 32, 108, 48, 255 }, fm.tiny_bold, cw - 24, "left")
        ui.text("开启顶部「退游戏保活」后，即使房主游戏闪退服务器仍常驻后台，重开游戏 5 分钟内可一键追帧接回。",
            cx + 12, y + 52, T.ink_muted, fm.tiny, cw - 24, "left")
    else
        ui.text(has_bin
            and "已检测到本机服务端 kr-mp-server.exe！点下方绿按钮无黑框后台启动并自动接入大厅（首次弹防火墙请点允许）。"
            or "点下方绿按钮将自动从官方源下载独立服务端（约 6.6 MB，自动校验 SHA-256）并无黑框后台启动。",
            cx + 12, y + 34, T.ink_sub, fm.tiny, cw - 24, "left")
    end

    local b1y = y + c1_h - 31
    if running then
        add_btn("srv_connect_local", "立即连入本机服 (127.0.0.1)", cx + 12, b1y, 212, 24, "battle", { tiny = true })
        add_btn("srv_copy_lan", "复制局域网服地址", cx + 232, b1y, 146, 24, "parchment", { tiny = true })
        add_btn("srv_stop_local", "停止本机服", cx + cw - 114, b1y, 102, 24, "crimson", { tiny = true })
    elseif dl_busy then
        add_btn("srv_start_local", string.format("正在下载服务端 %d%%...", dl_pct), cx + 12, b1y, 224, 24, "wood", { tiny = true })
    else
        add_btn("srv_start_local", has_bin and "一键启动本机服务器并连入 (17780)" or "一键下载并启动本机服务器 (17780)",
            cx + 12, b1y, 272, 24, "battle", { tiny = true })
    end
    y = y + c1_h + 8

    -- Step 2 Card: SakuraFrp 17780 Public Exposure (114px, Option A standalone frpc + Option B official launcher)
    local c2_h = 114
    local relay = (sh and sk) and sh:get_sakura_relay_info(sk) or nil
    local has_pub = (relay ~= nil and (relay.state == "managed" or relay.state == "online") and relay.addr ~= nil)
    local pub_confirmed = has_pub and (relay.confirmed ~= false)
    local frpc_dl_busy = (sk ~= nil and sk.frpc_dl_busy == true)
    local frpc_dl_pct = (sk and sk.get_frpc_download_pct and sk:get_frpc_download_pct()) or 0
    local sk_logged = (sk ~= nil and sk.user_info ~= nil)
    ui.draw_parchment_card(cx, y, cw, c2_h, {
        border = pub_confirmed and { 48, 134, 68, 240 } or { 138, 94, 40, 235 }, border_w = 1.6, radius = 8,
    })
    ui.draw_pill(cx + 10, y + 8, 50, 19, "步骤 2", { 72, 48, 28, 235 }, { 148, 112, 62, 220 }, T.gold_bright, fm.tiny_bold)
    ui.text("樱花联动暴露公网（把地址发群里，所有水友免装樱花！）", cx + 66, y + 10, T.ink_text, fm.small_bold, cw - 196, "left")
    local b2_txt = pub_confirmed and "公网就绪 √"
        or (has_pub and "连接中..." or (frpc_dl_busy and (frpc_dl_pct .. "%") or (relay and "隧道离线" or "外网必选")))
    local b2_bg = pub_confirmed and { 38, 128, 62, 240 } or (has_pub and { 164, 108, 30, 240 } or { 126, 86, 36, 225 })
    local b2_bd = pub_confirmed and { 24, 84, 40, 255 } or { 86, 56, 20, 245 }
    ui.draw_pill(cx + cw - 92, y + 8, 80, 19, b2_txt, b2_bg, b2_bd, { 255, 250, 242, 255 }, fm.tiny_bold)

    local b2y = y + c2_h - 31
    if frpc_dl_busy then
        draw_dl_bar(cx + 12, y + 34, cw - 24, 20, frpc_dl_pct, sk.frpc_dl_stage, sk.frpc_dl_ver,
            sk.frpc_dl_done_bytes, sk.frpc_dl_total_bytes, fm, "官方独立版 frpc", "MD5")
        ui.text("首次内启自动从樱花官方源拉取独立版 frpc（约 13.5 MB，自动 MD5 校验），下完立即自动启动 17780 隧道！",
            cx + 12, y + 58, T.ink_muted, fm.tiny, cw - 24, "left")
        local tname = relay and relay.tunnel and relay.tunnel.name or (sk and sk.managed_last_tunnel_name)
        add_btn("srv_start_sakura_17780", string.format("下载独立 frpc %d%%...", frpc_dl_pct),
            cx + 12, b2y, 196, 24, "wood", { tiny = true, tunnel = relay and relay.tunnel })
        add_btn("sakura_launch_app", "改用官方樱花开", cx + 216, b2y, 134, 24, "parchment", { tiny = true, tunnel_name = tname })
    elseif has_pub then
        if pub_confirmed then
            ui.text("公网中继服地址：" .. mask_addr(lobby, relay.addr) .. "  （水友直接粘贴进「公网服务器」页点连接即可！）",
                cx + 12, y + 34, { 32, 108, 48, 255 }, fm.tiny_bold, cw - 24, "left")
            ui.text("水友无需下载樱花、无需注册账号；你在大厅里建好房间，全群都能看到公开房或凭 4 位房间码加入。",
                cx + 12, y + 54, T.ink_muted, fm.tiny, cw - 24, "left")
        else
            ui.text("正在通过官方独立版 frpc 连接节点：" .. mask_addr(lobby, relay.addr) .. "（预计 1~2 秒就绪）",
                cx + 12, y + 34, { 164, 96, 20, 255 }, fm.tiny_bold, cw - 24, "left")
            ui.text("如持续未就绪或被安全软件拦截，可随时点右侧「改用官方樱花开」在官方启动器打开隧道。",
                cx + 12, y + 54, T.ink_muted, fm.tiny, cw - 24, "left")
        end
        add_btn("srv_copy_public", "一键复制公网服地址发群里", cx + 12, b2y, 202, 24, "battle", { tiny = true, copy_addr = relay.addr })
        add_btn("srv_connect_public", "用此公网地址连接", cx + 222, b2y, 140, 24, "azure", { tiny = true, addr = relay.addr })
        if not pub_confirmed then
            add_btn("sakura_launch_app", "改用官方樱花开", cx + 370, b2y, 126, 24, "wood", {
                tiny = true, tunnel_name = relay.tunnel and relay.tunnel.name,
            })
        end
        if relay.state == "managed" or relay.can_stop_standalone then
            add_btn("sakura_stop_frpc", "停 17780 隧道", cx + cw - 114, b2y, 102, 24, "crimson", { tiny = true })
        end
    elseif relay and relay.state == "offline" then
        local err_txt = sk and (sk.managed_last_error or sk.frpc_dl_error) or nil
        if err_txt then
            ui.text("独立版 frpc 异常：" .. tostring(err_txt), cx + 12, y + 34, { 166, 46, 36, 255 }, fm.tiny_bold, cw - 24, "left")
            ui.text(string.format("可直接点「用官方樱花开」在官方软件打开「%s」，开启后战桌自动识别公网地址！", tostring(relay.tunnel.name)),
                cx + 12, y + 54, T.ink_sub, fm.tiny, cw - 24, "left")
        else
            ui.text(string.format("已检测到你的樱花 17780 隧道「%s」（当前离线），可直接后台启动或用官方樱花开！", tostring(relay.tunnel.name)),
                cx + 12, y + 34, T.ink_text, fm.tiny_bold, cw - 24, "left")
            ui.text("方案 A 直启官方独立版 frpc（首次自动下载校验，免切换窗口）；方案 B 唤起官方樱花客户端手动开启。",
                cx + 12, y + 54, T.ink_muted, fm.tiny, cw - 24, "left")
        end
        add_btn("srv_start_sakura_17780", "一键后台启动 (独立frpc)", cx + 12, b2y, 196, 24, "battle", { tiny = true, tunnel = relay.tunnel })
        add_btn("sakura_launch_app", "用官方樱花开", cx + 216, b2y, 124, 24, "wood", { tiny = true, tunnel_name = relay.tunnel.name })
        add_btn("open_sakura", "樱花助手", cx + 348, b2y, 96, 24, "parchment", { tiny = true })
    elseif sk_logged then
        local best_nd = (sk.recommended_nodes and sk.recommended_nodes[1]) or nil
        if best_nd then
            local ntag = best_nd.is_public_ok and "[多线]" or "[普通]"
            ui.text(string.format("已登录樱花账号，当前尚未建 17780 隧道；推荐低负载节点：%s %s（负载 %d%%）",
                ntag, tostring(best_nd.name), math.floor((best_nd.load or 0) + 0.5)),
                cx + 12, y + 34, T.ink_text, fm.tiny_bold, cw - 24, "left")
            ui.text("若向直播间/大群公开招募水友，请先在樱花助手开启「公开直播合规(仅多线)」再一键创建！",
                cx + 12, y + 54, T.ink_muted, fm.tiny, cw - 24, "left")
            add_btn("srv_create_sakura_17780", "一键建 17780 樱花隧道", cx + 12, b2y, 198, 24, "battle", { tiny = true, node_id = best_nd.id, node_name = best_nd.name })
            add_btn("open_sakura", "去樱花助手自选节点", cx + 218, b2y, 152, 24, "wood", { tiny = true })
        else
            ui.text("已登录樱花账号，暂未获取到可用空闲节点；点右侧打开樱花助手刷新或调整多线筛选。",
                cx + 12, y + 36, T.ink_sub, fm.tiny, cw - 24, "left")
            add_btn("open_sakura", "打开樱花助手刷新节点", cx + 12, b2y, 184, 24, "azure", { tiny = true })
        end
    else
        ui.text("登录「樱花助手」访问密钥后，可在此一键自动创建并启动 TCP 17780 公网隧道；",
            cx + 12, y + 34, T.ink_sub, fm.tiny, cw - 24, "left")
        ui.text("也可直接打开官方樱花软件，手动新建一条「本地端口 = 17780」的 TCP 隧道并把地址发群里。",
            cx + 12, y + 52, T.ink_muted, fm.tiny, cw - 24, "left")
        add_btn("open_sakura", "打开樱花助手 (4步向导/托管)", cx + 12, b2y, 212, 24, "azure", { tiny = true })
        if sk and sk.installed then
            add_btn("sakura_launch_app", "打开官方樱花", cx + 232, b2y, 128, 24, "wood", { tiny = true })
        else
            add_btn("sakura_download_official", "一键装官方樱花", cx + 232, b2y, 128, 24, "battle", { tiny = true })
        end
    end
    y = y + c2_h + 8

    -- Bottom Dark-Oak Card: 24/7 Linux VPS 1-Line Deploy
    local vps_h = (py + ph - 18) - y
    ui.draw_armory_tray(cx, y, cw, vps_h, 9)
    ui.print_shadow("进阶 · 7×24 小时永久群服（Linux 云服务器 1 行傻瓜部署）",
        cx + 12, y + 9, T.gold_bright, nil, nil, nil, fm.small_bold)
    ui.text("自家电脑关机后本机服会停止；若有腾讯/阿里等云服务器，复制下方命令贴进网页终端回车即可永久常驻：",
        cx + 12, y + 31, { 232, 206, 158, 225 }, fm.tiny, cw - 24, "left")

    local cmd_y = y + 56
    local cmd_w = cw - 24 - 148
    ui.draw_parchment_card(cx + 12, cmd_y, cmd_w, 28, { radius = 5 })
    local cmd_short = "curl -fsSL .../chiyu-kr-coop/raw/main/tools/deploy_server.sh | sudo bash"
    ui.text(cmd_short, cx + 20, cmd_y + 7, T.ink_text, fm.tiny_bold, cmd_w - 16, "left")
    add_btn("srv_copy_vps_cmd", "一键复制开服命令", cx + cw - 152, cmd_y, 140, 28, "battle", { tiny = true })

    ui.text("部署完成后终端会自动打印「公网IP:17780」；别忘了在云控制台安全组放行 TCP 17780 端口（也可直接交给 AI 智能体执行）。",
        cx + 12, cmd_y + 35, { 216, 192, 148, 210 }, fm.tiny, cw - 24, "left")
end

return M
