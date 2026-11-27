-- KR-MP Lobby Sub-Modal Renderers (Guide / Stages / Heroes / Towers / Voice Mixer)
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")
local ui = require("kr_mp.ui_assets")

local M = {}

local function draw_guide_tab1(ctx, y)
    local T, cx, cw, fm = ctx.T, ctx.cx, ctx.cw, ctx.font_map
    local cards = {
        {
            badge = "1. 樱花联机 · 异地首选",
            badge_bg = { 36, 98, 158, 245 },
            badge_rim = { 22, 64, 108, 255 },
            border = { 46, 106, 162, 235 },
            title = "零服务器异地开黑 · 自动抓地址 / 三线测速 / 180 秒无感热续传",
            lines = {
                "第1步：房主开官方樱花 TCP 17777（或点「樱花助手」一键建/启隧道），建房后自动抓取地址并支持主播防窥打码！",
                "第2步：队友在「樱花联机」页点「粘贴」自动识别地址，可点「三线测速」挑最快线（默认/电信dx/移动yd），支持免费 P2P 优先回退！",
                "避坑贴士：樱花设置关「强制TLS」和「自动HTTPS」降延迟；直播间/大群公开招人务必选含「多线」节点（三线≠多线）！",
            },
        },
        {
            badge = "2. 局域网 · 同宿舍 / Wi-Fi",
            badge_bg = { 38, 128, 62, 245 },
            badge_rim = { 26, 86, 40, 255 },
            border = { 54, 132, 68, 235 },
            title = "什么都不用填，10 秒同网直接开玩！（支持本机双开 / 虚拟局域网）",
            lines = {
                "第1步：切到顶部「局域网」页，房主点左边「创建局域网房间并备战」（首次弹出 Windows 防火墙务必点「允许访问」）。",
                "第2步：同 Wi-Fi 队友等 2 秒，在下方酒馆布告栏点「揭榜加入」就行；跨网段或 ZeroTier 可在右上手动输 IP 直连。",
                "小提示：局域网和樱花共用底层引擎，房主在一边建房，同网室友与异地好友都可直连，且同样享有 180 秒闪断热续传！",
            },
        },
        {
            badge = "3. 公网服务器 · 多房大厅",
            badge_bg = { 116, 42, 138, 245 },
            badge_rim = { 76, 24, 92, 255 },
            border = { 126, 56, 146, 235 },
            title = "自建或接入 Go 中继服 · 4 位房间码进房 + 5 分钟超长追帧重连",
            lines = {
                "第1步：房主运行完整包里的「启动公网中继服.bat」（映射本地端口 17780）或填入已有公网服务器地址。",
                "第2步：双方切到顶部「公网服务器」页点连接 -> 房主建房后把 4 位房间码发给朋友，朋友输码进房。",
                "第3步：中途谁闪退/断网，5 分钟内重开游戏切到公网服务器页，点顶部绿色「一键高速追帧重连」瞬间回到战场！",
            },
        },
    }
    local ch, cgap = 104, 8
    for i, c in ipairs(cards) do
        local cy = y + (i - 1) * (ch + cgap)
        ui.draw_parchment_card(cx, cy, cw, ch, { border = c.border, border_w = 1.8, radius = 8 })
        ui.draw_pill(cx + 12, cy + 8, 174, 20, c.badge, c.badge_bg, c.badge_rim, { 255, 252, 238, 255 }, fm.tiny_bold)
        ui.text(c.title, cx + 196, cy + 9, T.ink_text, fm.small_bold)
        for j, line in ipairs(c.lines) do
            ui.text(line, cx + 14, cy + 33 + (j - 1) * 21, (j == 3) and T.ink_muted or T.ink_sub, fm.tiny, cw - 28, "left")
        end
    end
end

local function draw_guide_tab2(ctx, y)
    local T, cx, cw, fm = ctx.T, ctx.cx, ctx.cw, ctx.font_map
    local half_w = math.floor((cw - 12) / 2)
    local top_h = 144

    ui.draw_parchment_card(cx, y, half_w, top_h, {
        top = { 234, 242, 250, 252 }, bot = { 222, 224, 206, 250 },
        border = T.p1_border, border_w = 2.0, thumbtack = true, radius = 8,
    })
    ui.draw_pill(cx + 12, y + 11, 134, 20, "1P 蓝方主将（房主）", T.p1_top, T.p1_border, { 244, 250, 255, 255 }, fm.tiny_bold)
    ui.text("· 操控【1 号英雄】和左侧专属英雄大招。", cx + 12, y + 38, T.ink_text, fm.small)
    ui.text("· 拥有【独立冷却援军】，与 2P 互不抢冷却！", cx + 12, y + 60, T.ink_text, fm.small)
    ui.text("· 负责挑选地图（全 6 代 201 关）、战役难度", cx + 12, y + 83, T.ink_sub, fm.tiny)
    ui.text("  （含第 4 档「不可能」）以及 59 选 12 防御塔卡组。", cx + 12, y + 100, T.ink_sub, fm.tiny)
    ui.text("· 等 2P 进房、蜡封变绿「就绪」后点「出征守关！」", cx + 12, y + 120, T.p1_border, fm.tiny_bold)

    local rx = cx + half_w + 12
    ui.draw_parchment_card(rx, y, half_w, top_h, {
        top = { 252, 238, 234, 252 }, bot = { 236, 218, 190, 250 },
        border = T.p2_border, border_w = 2.0, thumbtack = true, radius = 8,
    })
    ui.draw_pill(rx + 12, y + 11, 134, 20, "2P 红方协防（队友）", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, fm.tiny_bold)
    ui.text("· 操控【2 号英雄】和右侧专属英雄大招。", rx + 12, y + 38, T.ink_text, fm.small)
    ui.text("· 同样拥有【独立冷却援军】，随便放不冲突！", rx + 12, y + 60, T.ink_text, fm.small)
    ui.text("· 进房后点「更换 2P 英雄」，可在 105 位全系列", rx + 12, y + 83, T.ink_sub, fm.tiny)
    ui.text("  英雄中任选自己喜欢的搭档（含 6 代新英雄）。", rx + 12, y + 100, T.ink_sub, fm.tiny)
    ui.text("· 选好英雄确认「已就绪」，等房主一键发车！", rx + 12, y + 120, T.p2_border, fm.tiny_bold)

    local ry2, rh2 = y + top_h + 10, 176
    local rw3 = math.floor((cw - 20) / 3)
    local rules = {
        {
            title = "军费账本（钱怎么算？）",
            tag = "推荐：独立 50/50",
            col = { 164, 102, 22, 255 },
            body = "【独立50/50】：杀怪与过波金币一人一半，各花各的。钱不够时喊队友点局内顶部「转50」立刻打钱救场！\n\n【共享金库】：两人共用同一个钱包，一起花钱建塔。",
        },
        {
            title = "防御塔权（谁能动塔？）",
            tag = "推荐：红蓝保护",
            col = { 42, 118, 56, 255 },
            body = "【红蓝保护】：自己建的塔底座带蓝/红光弧，队友不能误卖或乱升级，保护各自分工！觉得花哨可点「塔底徽记:关」隐藏。\n\n【自由共享】：双方都能升级/出售任意塔。",
        },
        {
            title = "全 6 代自由混搭卡组",
            tag = "59 座塔随心选 12",
            col = { 126, 24, 148, 255 },
            body = "房主点击军械盘右上「配置59选12」，可以把6代创世、5代联盟、4代复仇的防御塔自由混搭进同一局！\n\n难度支持休闲/普通/老兵/不可能（4档），双端自动锁定一致。",
        },
    }
    for i, r in ipairs(rules) do
        local rx3 = cx + (i - 1) * (rw3 + 10)
        ui.draw_parchment_card(rx3, ry2, rw3, rh2, { radius = 8 })
        ui.text(r.title, rx3 + 12, ry2 + 9, T.ink_text, fm.small_bold)
        ui.draw_pill(rx3 + 12, ry2 + 30, rw3 - 24, 19, r.tag,
            { r.col[1], r.col[2], r.col[3], 230 }, T.ink_dark, { 255, 250, 236, 255 }, fm.tiny_bold)
        ui.text(r.body, rx3 + 12, ry2 + 56, T.ink_sub, fm.tiny, rw3 - 24, "left")
    end
end

local function draw_guide_tab3(ctx, y)
    local T, cx, cw, fm = ctx.T, ctx.cx, ctx.cw, ctx.font_map
    local rw3 = math.floor((cw - 20) / 3)
    local top_h = 148
    local modes = {
        {
            badge = "默认 · 按V说话",
            bg = { 156, 102, 26, 245 },
            sub = "最防回声 · 零杂音",
            body = "进房默认就是这个模式。\n\n按住键盘【V键】就能讲话，松开立刻静音。就算没戴耳机用电脑外放，也不容易出现回声啸叫！",
        },
        {
            badge = "直播首选 · 自由麦",
            bg = { 42, 138, 62, 245 },
            sub = "开口即说 · 解放双手",
            body = "戴上耳机开黑或直播强烈推荐！\n\n点房间顶部或战局顶栏切到「自由麦」，说话自动收音、闭嘴自动静音，双手专心微操英雄和防御塔！",
        },
        {
            badge = "快捷键 M · 闭麦",
            bg = { 158, 38, 38, 245 },
            sub = "随时秒闭 · 仍能听队友",
            body = "临时咳嗽、接电话或有人敲门？\n\n随时按一下键盘【M键】立刻闭麦（不会传出你的声音，但仍能听见队友），再按一次M键马上恢复开麦！",
        },
    }
    for i, m in ipairs(modes) do
        local rx3 = cx + (i - 1) * (rw3 + 10)
        ui.draw_parchment_card(rx3, y, rw3, top_h, { radius = 8, thumbtack = true })
        ui.draw_pill(rx3 + 12, y + 13, rw3 - 24, 22, m.badge, m.bg, T.ink_dark, { 255, 252, 238, 255 }, fm.tiny_bold)
        ui.text(m.sub, rx3 + 12, y + 39, T.ink_text, fm.small_bold, rw3 - 24, "center")
        ui.text(m.body, rx3 + 12, y + 61, T.ink_sub, fm.tiny, rw3 - 24, "left")
    end

    local by, bh = y + top_h + 10, 172
    ui.draw_armory_tray(cx, by, cw, bh, 9)
    ui.print_shadow("直播效果 & 开播前试麦小贴士（无需任何第三方语音软件！）", cx + 16, by + 11, T.gold_bright, nil, nil, nil, fm.small_bold)
    local tips = {
        "1. 开播前先点【试麦】：队友还没进房时，点房间顶部「试麦」按钮并戴上耳机讲两句——能听到自己清晰回放、且 1P 英雄头像右下声波条跳动，就说明麦克风完全正常！",
        "2. 直播声波特效自动触发：在战桌说话时对应英雄卡亮起翡翠呼吸光圈；进战局后谁开口，顶部 HUD 下方自动弹出【英雄头像 + 1P/2P + 5段动态声波气泡】，观众一眼分清谁在喊话！",
        "3. 队友太吵或自己没插麦？：队友进房后顶部可一键点「听筒:关」静音对方；没插麦克风的电脑也完全不报错，可以直接清楚收听队友指挥。",
        "4. 零卡帧零掉线：语音跑在独立后台线程且仅占 ~10KB/s，网络抖动时自动让路给游戏操作帧，绝不影响 60Hz 同步！",
    }
    for i, line in ipairs(tips) do
        ui.text(line, cx + 16, by + 37 + (i - 1) * 32, { 244, 226, 188, 240 }, fm.tiny, cw - 32, "left")
    end
end

local function draw_guide_tab4(ctx, y)
    local T, cx, cw, fm = ctx.T, ctx.cx, ctx.cw, ctx.font_map
    local lw = 304
    local rw = cw - lw - 12
    local card_h = 330

    ui.draw_parchment_card(cx, y, lw, card_h, { border = { 138, 94, 40, 245 }, border_w = 1.8, radius = 8 })
    ui.draw_pill(cx + 12, y + 10, lw - 24, 22, "常用快捷键 & 顶栏按钮速查", T.wood_mid, T.ink_dark, T.gold_bright, fm.tiny_bold)
    local keys = {
        { k = "F10",        d = "随时打开 / 关闭联机大厅" },
        { k = "F9",         d = "隐藏 / 显示顶部联机信息条" },
        { k = "按住 V",     d = "按键说话（按V麦模式）" },
        { k = "M 键",       d = "一键闭麦 / 恢复开麦" },
        { k = "Alt + 左键", d = "在地图打点标记提醒队友" },
        { k = "Space 空格", d = "双端同步暂停 / 继续战斗" },
        { k = "A / S 键",   d = "1P / 2P 释放各自英雄大招" },
        { k = "顶栏 转50",  d = "独立经济左键转 50 金，右键/Shift+左键转 200 金" },
        { k = "顶栏 战桌",  d = "不断线返回战桌换关；点右侧延迟数字可热切缓冲" },
    }
    for i, item in ipairs(keys) do
        local ky = y + 39 + (i - 1) * 31
        ui.draw_pill(cx + 12, ky, 82, 22, item.k, { 236, 214, 168, 245 }, { 148, 108, 52, 210 }, T.ink_text, fm.tiny_bold)
        ui.text(item.d, cx + 102, ky + 4, T.ink_text, fm.tiny, lw - 114, "left")
    end

    local rx = cx + lw + 12
    ui.draw_parchment_card(rx, y, rw, card_h, { border = T.p2_border, border_w = 1.8, radius = 8 })
    ui.draw_pill(rx + 12, y + 10, rw - 24, 22, "小白最常遇到的 4 个问题急救箱", T.p2_top, T.p2_border, { 255, 246, 238, 255 }, fm.tiny_bold)
    local faqs = {
        {
            q = "Q1：搜不到房主，或点加入一直连不上？",
            a = "确认房主已经点「创建房间」留在战桌内；首次弹出 Windows 防火墙必须点「允许访问」。异地开黑请用樱花映射 TCP 17777 点「粘贴」直连。",
        },
        {
            q = "Q2：提示「版本不匹配」或「核心脚本哈希不一致」？",
            a = "双方必须用同一份FL8.2.0游戏包，且补丁同为最新版（在大厅右上点「检查更新」即可一键下载新版覆盖安装）。",
        },
        {
            q = "Q3：玩起来觉得点一下要等半拍，或者樱花节点抖动卡顿？",
            a = "先点「三线测速」挑最低延迟线，并确认樱花未勾「强制TLS」；局内房主可直接点顶栏右侧延迟数字热切【樱花200ms】或【抗抖300ms】！",
        },
        {
            q = "Q4：某关意外闪退，或顶部提示红字「同步异常」？",
            a = "别慌！打开解压好的补丁文件夹，双击「一键收集报错包.bat」，10 秒自动打包日志与 AI 提问词，发给作者或直接喂给 AI 即可秒修！",
        },
    }
    for i, fq in ipairs(faqs) do
        local fy = y + 40 + (i - 1) * 71
        ui.text(fq.q, rx + 14, fy, T.p2_border, fm.small_bold, rw - 28, "left")
        ui.text(fq.a, rx + 14, fy + 19, T.ink_sub, fm.tiny, rw - 28, "left")
    end
end

function M.draw_guide(ctx)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local y = py + 42
    local tabs = {
        { idx = 1, label = "1. 怎么联机" },
        { idx = 2, label = "2. 双人玩法" },
        { idx = 3, label = "3. 连麦直播" },
        { idx = 4, label = "4. 按键与排错" },
    }
    local cur_tab = math.max(1, math.min(4, tonumber(lobby.guide_tab) or 1))
    lobby.guide_tab = cur_tab
    local back_w, t_gap = 92, 6
    local tab_w = math.floor((cw - back_w - 10 - (#tabs - 1) * t_gap) / #tabs)
    for i, tb in ipairs(tabs) do
        local act = (cur_tab == tb.idx)
        add_btn("guide_tab", tb.label, cx + (i - 1) * (tab_w + t_gap), y, tab_w, 28,
            act and "wood" or "parchment", { tab = tb.idx, small = true, active = act })
    end
    add_btn("modal_back", lobby.view == "room" and "返回战桌" or "返回大厅", cx + cw - back_w, y, back_w, 28, "crimson", { small = true })
    y = y + 36

    if cur_tab == 1 then draw_guide_tab1(ctx, y)
    elseif cur_tab == 2 then draw_guide_tab2(ctx, y)
    elseif cur_tab == 3 then draw_guide_tab3(ctx, y)
    else draw_guide_tab4(ctx, y) end

    local pby = py + ph - 62
    ui.draw_pill(cx + math.floor(cw / 2) - 64, pby + 3, 128, 22,
        string.format("第 %d / 4 页 · 按 ESC 返回", cur_tab),
        { 246, 232, 198, 240 }, T.parchment_edge, T.ink_sub, fm.tiny_bold)
    if cur_tab > 1 then
        add_btn("guide_prev", "上一页", cx, pby, 92, 28, "wood", { small = true })
    end
    if cur_tab < 4 then
        add_btn("guide_next", "下一页", cx + cw - 92, pby, 92, 28, "battle", { small = true })
    else
        add_btn("modal_back", "看懂了，去开黑！", cx + cw - 134, pby, 134, 28, "battle", { small = true })
    end
end

function M.draw_stages(ctx)
    local lobby, T, cx, cw, py, ph, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.ph, ctx.font_map, ctx.add_btn
    local y = py + 42
    local packs = catalog.STAGE_PACKS
    local back_w, tab_gap = 84, 5
    local tab_w = math.floor((cw - back_w - 10 - (#packs - 1) * tab_gap) / #packs)
    for i, pk in ipairs(packs) do
        local act = (i == lobby.stage_pack_idx)
        local lbl = string.format("%s(%d)", pk.tag or pk.id, #pk.stages)
        add_btn("stage_pack", lbl, cx + (i - 1) * (tab_w + tab_gap), y, tab_w, 28,
            act and "wood" or "parchment", { pack_idx = i, tiny = true, active = act })
    end
    add_btn("modal_back", "返回战桌", cx + cw - back_w, y, back_w, 28, "crimson", { tiny = true })
    y = y + 36

    local pack = packs[lobby.stage_pack_idx] or packs[1]
    local per_page = 30
    local total_pages = math.max(1, math.ceil(#pack.stages / per_page))
    local cur_page = math.max(1, math.min(total_pages, lobby.stage_page or 1))
    lobby.stage_page = cur_page
    local start_i = (cur_page - 1) * per_page + 1
    local end_i = math.min(#pack.stages, start_i + per_page - 1)

    local cols, gap = 5, 6
    local tile_w = math.floor((cw - (cols - 1) * gap) / cols)
    local tile_h = (total_pages > 1) and 50 or 56
    for idx_in_pack = start_i, end_i do
        local st = pack.stages[idx_in_pack]
        local slot = idx_in_pack - start_i
        local col = slot % cols
        local row = math.floor(slot / cols)
        local sel = (lobby.room.level_idx == st.idx)
        add_btn("pick_stage", string.format("第 %d 关\n%s", st.idx, st.name),
            cx + col * (tile_w + gap), y + row * (tile_h + gap), tile_w, tile_h,
            sel and "battle" or "parchment", { level_idx = st.idx, selected = sel, tiny = true })
    end

    if total_pages > 1 then
        local pby = py + ph - 60
        ui.draw_pill(cx + math.floor(cw / 2) - 56, pby + 2, 112, 24,
            string.format("第 %d / %d 页", cur_page, total_pages),
            { 246, 232, 198, 240 }, T.parchment_edge, T.ink_text, fm.small_bold)
        if cur_page > 1 then
            add_btn("stage_page_prev", "上一页", cx + math.floor(cw / 2) - 146, pby, 82, 28, "wood", { small = true })
        end
        if cur_page < total_pages then
            add_btn("stage_page_next", "下一页", cx + math.floor(cw / 2) + 64, pby, 82, 28, "wood", { small = true })
        end
    end
end

function M.draw_heroes(ctx)
    local lobby, G, T, cx, cw, py, mx, my, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.mx, ctx.my, ctx.font_map, ctx.add_btn
    local is_h1 = (lobby.sub_modal == "hero1")
    local cur_hero = is_h1 and lobby.room.heroes[1] or lobby.room.heroes[2]
    local y = py + 42
    local packs = catalog.HERO_PACKS
    local back_w, tab_gap = 80, 4
    local tab_w = math.floor((cw - back_w - 8 - (#packs - 1) * tab_gap) / #packs)
    for i, pk in ipairs(packs) do
        local act = (i == lobby.hero_pack_idx)
        local short_lbl = pk.name:gsub("·[^%(]+", "")
        add_btn("hero_pack", short_lbl, cx + (i - 1) * (tab_w + tab_gap), y, tab_w, 28,
            act and (is_h1 and "azure" or "crimson") or "parchment", { pack_idx = i, tiny = true, active = act })
    end
    add_btn("modal_back", "返回战桌", cx + cw - back_w, y, back_w, 28, "wood", { tiny = true })
    y = y + 38

    local pack = packs[lobby.hero_pack_idx] or packs[1]
    local preview_w, preview_h = 186, 372
    local grid_x = cx + preview_w + 12
    local grid_w = cw - preview_w - 12
    local cols, gap = 4, 6
    local tile_w = math.floor((grid_w - (cols - 1) * gap) / cols)
    local tile_h = 68
    local preview_hero = cur_hero

    for i, h in ipairs(pack.heroes) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local bx = grid_x + col * (tile_w + gap)
        local by = y + row * (tile_h + gap)
        if mx >= bx and mx <= bx + tile_w and my >= by and my <= by + tile_h then
            preview_hero = h.idx
        end
        local sel = (cur_hero == h.idx)
        add_btn("pick_hero", h.name, bx, by, tile_w, tile_h, "hero_tile", {
            hero_idx = h.idx,
            sub_label = string.format("#%d%s", h.idx, sel and " · 已选" or ""),
            selected = sel,
            is_p1 = is_h1,
            icon_size = 52,
        })
    end

    ui.draw_vgrad_rect(cx, y, preview_w, preview_h, is_h1 and T.p1_top or T.p2_top, { 26, 16, 10, 255 }, 10)
    local bcol = is_h1 and T.p1_border or T.p2_border
    G.setColor(bcol[1], bcol[2], bcol[3], 255)
    G.setLineWidth(2.2)
    G.rectangle("line", cx, y, preview_w, preview_h, 10, 10)

    ui.draw_pill(cx + 12, y + 10, preview_w - 24, 20,
        is_h1 and "1P 蓝方主将预览" or "2P 红方队友预览",
        { 18, 12, 8, 185 }, T.gold_mid, T.gold_bright, fm.tiny_bold)
    ui.draw_hero_big_portrait(preview_hero, cx + 12, y + 36, preview_w - 24, 242, {
        radius = 8, pad = 2, border = T.gold_mid, border_w = 2,
    })
    ui.print_shadow(catalog.get_hero_label(preview_hero), cx + 8, y + 288, T.gold_bright, preview_w - 16, "center", nil, fm.title)
    ui.print_shadow(string.format("英雄编号 #%d", preview_hero), cx + 8, y + 314,
        is_h1 and T.p1_light or T.p2_light, preview_w - 16, "center", nil, fm.small_bold)
    ui.text("点击右侧头像立即委任出战", cx + 10, y + 344, { 232, 212, 174, 215 }, fm.tiny, preview_w - 20, "center")
end

function M.draw_towers(ctx)
    local lobby, T, cx, cw, py, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.font_map, ctx.add_btn
    lobby.ensure_room_defaults(lobby.room)
    local selected = {}
    for _, tid in ipairs(lobby.room.towers) do selected[tid] = true end

    local y = py + 42
    local full = (#lobby.room.towers >= 12)
    ui.draw_pill(cx, y + 2, 102, 24, string.format("已装备 %d/12", #lobby.room.towers),
        full and { 42, 122, 54, 245 } or { 172, 108, 28, 245 },
        T.ink_dark, { 255, 250, 232, 255 }, fm.tiny_bold)

    local packs = catalog.TOWER_PACKS
    local avail_tabs_w = cw - 110 - 180 - 8
    local t_gap = 6
    local t_tab_w = math.floor((avail_tabs_w - (#packs - 1) * t_gap) / #packs)
    for i, pk in ipairs(packs) do
        local act = (i == lobby.tower_pack_idx)
        add_btn("tower_pack", pk.name, cx + 108 + (i - 1) * (t_tab_w + t_gap), y, t_tab_w, 28,
            act and "wood" or "parchment", { pack_idx = i, tiny = true, active = act })
    end
    add_btn("towers_default", "默认12塔", cx + cw - 178, y, 84, 28, "parchment", { tiny = true })
    add_btn("modal_back", "完成返回", cx + cw - 88, y, 88, 28, "battle", { tiny = true })
    y = y + 38

    local pack = packs[lobby.tower_pack_idx] or packs[1]
    local cols, gap = 4, 7
    local tile_w = math.floor((cw - (cols - 1) * gap) / cols)
    local tile_h = 56
    for i, tw in ipairs(pack.towers) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local is_sel = selected[tw.idx] == true
        add_btn("pick_tower", tw.name, cx + col * (tile_w + gap), y + row * (tile_h + gap), tile_w, tile_h, "tower_tile", {
            tower_idx = tw.idx,
            sub_label = is_sel and "已带入军械盘" or "点击加入卡组",
            selected = is_sel,
            icon_size = 44,
        })
    end
end

function M.draw_voice(ctx)
    local lobby, G, T, cx, cw, py, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.font_map, ctx.add_btn
    local y = py + 44
    ui.text("在这里可以随时调整你的麦克风音量、队友声音大小，以及战斗中说话提示标的显示样式（对局顶部点「调音」也能随时改）。",
        cx, y + 4, T.ink_sub, fm.tiny, cw - 98, "left")
    add_btn("modal_back", "返回战桌", cx + cw - 88, y, 88, 28, "battle", { small = true })
    y = y + 38

    local v = lobby.voice
    local is_mob = proto.is_android()

    -- Card 1: Local Mic Gain + Live Input Meter + Self Test
    ui.draw_parchment_card(cx, y, cw, 118, { border = T.p1_border, border_w = 1.8, radius = 9 })
    ui.draw_pill(cx + 14, y + 12, 118, 21, "我的麦克风收音", T.p1_top, T.p1_border, { 242, 250, 255, 255 }, fm.tiny_bold)
    local loc_lvl = math.max(0, math.min(1, tonumber(v.local_level) or 0))
    ui.text("实时音量：", cx + 146, y + 16, T.ink_sub, fm.tiny)
    local mtr_x, mtr_y, mtr_w, mtr_h = cx + 206, y + 17, 376, 11
    G.setColor(26, 15, 7, 225)
    G.rectangle("fill", mtr_x, mtr_y, mtr_w, mtr_h, 5, 5)
    if loc_lvl > 0.02 then
        ui.draw_vgrad_rect(mtr_x + 1, mtr_y + 1, math.max(3, math.floor((mtr_w - 2) * loc_lvl)), mtr_h - 2,
            T.emerald_top, T.emerald_bot, 4)
    end
    G.setColor(148, 108, 52, 210)
    G.setLineWidth(1.1)
    G.rectangle("line", mtr_x, mtr_y, mtr_w, mtr_h, 5, 5)
    add_btn("voice_self_test", v.self_test and "关闭试麦监听" or "开启本机试麦", cx + cw - 124, y + 10, 110, 24,
        v.self_test and "battle" or "wood", { tiny = true })

    local mic_g = tonumber(v.mic_gain) or 1.0
    ui.text("麦克风增益：", cx + 14, y + 48, T.ink_text, fm.small_bold)
    add_btn("voice_mic_step", "-20%", cx + 96, y + 43, 48, 26, "wood", { tiny = true, delta = -0.2 })
    local bar1_x, bar1_y, bar1_w, bar1_h = cx + 150, y + 45, 428, 22
    local f1 = math.max(0, math.min(1, (mic_g - 0.4) / 1.6))
    G.setColor(26, 15, 7, 232)
    G.rectangle("fill", bar1_x, bar1_y, bar1_w, bar1_h, 6, 6)
    if f1 > 0.01 then
        ui.draw_vgrad_rect(bar1_x + 1, bar1_y + 1, math.max(3, math.floor((bar1_w - 2) * f1)), bar1_h - 2,
            T.emerald_top, T.emerald_bot, 5)
    end
    G.setColor(156, 114, 52, 220)
    G.setLineWidth(1.2)
    G.rectangle("line", bar1_x, bar1_y, bar1_w, bar1_h, 6, 6)
    ui.print_shadow(string.format("%d%%（点击进度条可直调）", math.floor(mic_g * 100 + 0.5)),
        bar1_x, bar1_y + (bar1_h - ui.font_h(fm.tiny_bold)) * 0.5, { 255, 250, 234, 255 }, bar1_w, "center", nil, fm.tiny_bold)
    add_btn("voice_mic_set", "", bar1_x, y + 43, bar1_w, 26, "slider_hit", { slider_min = 0.4, slider_max = 2.0, no_draw = true })
    add_btn("voice_mic_step", "+20%", bar1_x + bar1_w + 6, y + 43, 48, 26, "wood", { tiny = true, delta = 0.2 })
    add_btn("voice_mic_set", "默认100%", bar1_x + bar1_w + 60, y + 43, 78, 26, "parchment", { tiny = true, val = 1.0 })

    ui.text("收音模式：", cx + 14, y + 83, T.ink_text, fm.small_bold)
    local modes = {
        { id = "ptt",  lbl = is_mob and "按住说话 (防杂音)" or "按键说话 (按住 V 键)" },
        { id = "vad",  lbl = "自由麦 (说话自动收音)" },
        { id = "mute", lbl = "闭麦 (不发声 · 可听队友)" },
    }
    for idx_m, mm in ipairs(modes) do
        local act = (v.mode == mm.id)
        local st_m = act and (mm.id == "mute" and "crimson" or "battle") or "parchment"
        add_btn("voice_set_mode", mm.lbl, cx + 96 + (idx_m - 1) * (201 + 8), y + 78, 201, 27, st_m, { tiny = true, mode = mm.id })
    end
    y = y + 128

    -- Card 2: Peer Playback Volume + Mute
    ui.draw_parchment_card(cx, y, cw, 82, { border = T.p2_border, border_w = 1.8, radius = 9 })
    ui.draw_pill(cx + 14, y + 12, 118, 21, "队友语音音量", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, fm.tiny_bold)
    ui.text("觉得队友声音太小或太响，可直接点击下方音量条调节（最高可放大至 180%）。", cx + 144, y + 16, T.ink_sub, fm.tiny)

    local peer_v = v.peer_muted and 0 or (tonumber(v.peer_volume) or 1.0)
    ui.text("队友音量：", cx + 14, y + 47, T.ink_text, fm.small_bold)
    add_btn("voice_peer_step", "-20%", cx + 96, y + 42, 48, 26, "wood", { tiny = true, delta = -0.2 })
    local bar2_x, bar2_y, bar2_w, bar2_h = cx + 150, y + 44, 428, 22
    local f2 = math.max(0, math.min(1, peer_v / 1.8))
    G.setColor(26, 15, 7, 232)
    G.rectangle("fill", bar2_x, bar2_y, bar2_w, bar2_h, 6, 6)
    if f2 > 0.01 then
        ui.draw_vgrad_rect(bar2_x + 1, bar2_y + 1, math.max(3, math.floor((bar2_w - 2) * f2)), bar2_h - 2,
            { 84, 186, 255, 255 }, { 34, 112, 188, 255 }, 5)
    end
    G.setColor(156, 114, 52, 220)
    G.setLineWidth(1.2)
    G.rectangle("line", bar2_x, bar2_y, bar2_w, bar2_h, 6, 6)
    ui.print_shadow(v.peer_muted and "已静音（点击恢复）" or string.format("%d%%", math.floor(peer_v * 100 + 0.5)),
        bar2_x, bar2_y + (bar2_h - ui.font_h(fm.tiny_bold)) * 0.5, { 255, 250, 234, 255 }, bar2_w, "center", nil, fm.tiny_bold)
    add_btn("voice_peer_set", "", bar2_x, y + 42, bar2_w, 26, "slider_hit", { slider_min = 0.0, slider_max = 1.8, no_draw = true })
    add_btn("voice_peer_step", "+20%", bar2_x + bar2_w + 6, y + 42, 48, 26, "wood", { tiny = true, delta = 0.2 })
    add_btn("voice_peer_mute", v.peer_muted and "取消静音" or "静音队友", bar2_x + bar2_w + 60, y + 42, 78, 26,
        v.peer_muted and "crimson" or "parchment", { tiny = true })
    y = y + 92

    -- Card 3: In-Battle Speaking Indicator Style
    ui.draw_parchment_card(cx, y, cw, 92, { border = { 138, 94, 40, 245 }, border_w = 1.8, radius = 9 })
    ui.draw_pill(cx + 14, y + 12, 152, 21, "战斗中说话图标显示", T.wood_mid, T.ink_dark, T.gold_bright, fm.tiny_bold)
    ui.text("默认使用「极简微标」，仅在顶栏下方显示极小半透明音浪小标，绝不遮挡战场！", cx + 178, y + 16, T.ink_sub, fm.tiny)

    local styles = {
        { id = "compact", lbl = "极简微标 (默认 · 轻巧不遮屏)" },
        { id = "off",     lbl = "完全关闭 (最纯净 · 仅听声音)" },
        { id = "card",    lbl = "醒目大卡 (带头像 · 适合直播)" },
    }
    local sw_s = math.floor((cw - 28 - 16) / 3)
    for idx_s, st_it in ipairs(styles) do
        local act = ((v.indicator_style or "compact") == st_it.id)
        add_btn("voice_style_set", st_it.lbl, cx + 14 + (idx_s - 1) * (sw_s + 8), y + 46, sw_s, 32,
            act and "azure" or "parchment", { small = true, style_id = st_it.id })
    end
end

return M
