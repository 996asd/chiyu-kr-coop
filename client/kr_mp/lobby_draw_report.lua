-- KR-MP Bug Diagnostics & Opt-In Cloud Report Modal Renderer
-- Ironhide War-Table styled diagnostic ledger: dark-oak header + symmetric pinned cards + royal ticket plaque.
local proto = require("kr_mp.proto")
local ui = require("kr_mp.ui_assets")

local M = {}

local QUICK_NOTES = {
    { id = "desync", label = "不同步(DESYNC)", text = "战斗中途提示同步异常(DESYNC)" },
    { id = "crash",  label = "闪退/报错",      text = "游戏闪退或弹出蓝色Lua报错界面" },
    { id = "skill",  label = "英雄/塔异常",    text = "英雄技能、防御塔或援军表现异常" },
    { id = "net",    label = "掉线/重连",      text = "联机掉线或追帧重连失败" },
}

M.QUICK_NOTES = QUICK_NOTES

local function mask_addr_if_needed(lobby, addr)
    if lobby.privacy_mask and lobby.sakura and type(addr) == "string" and #addr > 0 then
        return lobby.sakura.mask_addr(addr)
    end
    return tostring(addr or "")
end

-- UTF-8 safe single-line truncation by logical pixel width (keeps cards crisp, never overflows!)
local function ellipsize_px(font, str, max_w)
    local s = tostring(str or ""):gsub("[\r\n]+", " ")
    if not font or not max_w or ui.font_w(font, s) <= max_w then
        return s
    end
    local dots = ".."
    local bytes = #s
    while bytes > 0 do
        -- Step back one full UTF-8 codepoint
        local cut = bytes - 1
        while cut > 0 do
            local b = s:byte(cut)
            if b < 0x80 or b >= 0xC0 then break end
            cut = cut - 1
        end
        bytes = cut
        local cand = s:sub(1, bytes) .. dots
        if ui.font_w(font, cand) <= max_w then
            return cand
        end
    end
    return dots
end

local function draw_divider(G, T, x, y, w)
    G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], 135)
    G.setLineWidth(1)
    G.line(x, y, x + w, y)
end

local function draw_left_cloud_card(ctx, y, left_w, card_h, u, active_ok)
    local lobby, G, T, cx, fm, add_btn = ctx.lobby, ctx.G, ctx.T, ctx.cx, ctx.font_map, ctx.add_btn
    ui.draw_parchment_card(cx, y, left_w, card_h, {
        top = { 239, 245, 236, 252 },
        bot = { 226, 215, 182, 250 },
        border = { 42, 122, 62, 235 },
        border_w = 2.0,
        thumbtack = true,
        radius = 9,
    })

    ui.draw_pill(cx + 14, y + 11, 172, 20, "方式一 · 云端上传 (推荐)",
        { 38, 128, 62, 245 }, { 24, 82, 38, 255 }, { 248, 255, 244, 255 }, fm.tiny_bold)
    if active_ok then
        ui.draw_pill(cx + left_w - 154, y + 11, 140, 20, "已连公网服 · 秒传 √",
            { 34, 108, 158, 240 }, { 22, 68, 104, 255 }, { 242, 250, 255, 255 }, fm.tiny_bold)
    else
        ui.draw_pill(cx + left_w - 154, y + 11, 140, 20, "临时短连 · 不掉房",
            { 96, 68, 36, 225 }, { 148, 112, 60, 210 }, T.gold_bright, fm.tiny_bold)
    end

    ui.text("生成 6 位反馈码（#R-4K9A），发群里即可 30 倍速复现",
        cx + 14, y + 37, T.ink_text, fm.small_bold, left_w - 28, "left")
    draw_divider(G, T, cx + 14, y + 57, left_w - 28)

    -- Quick symptom chips (single-click toggle, zero typing on PC/Android)
    ui.text("快捷点选现象（可选，再点取消）：", cx + 14, y + 63, T.ink_muted, fm.tiny)
    local chip_gap = 6
    local chip_w = math.floor((left_w - 28 - (#QUICK_NOTES - 1) * chip_gap) / #QUICK_NOTES)
    for i, q in ipairs(QUICK_NOTES) do
        local act = (u.note == q.text)
        add_btn("report_quick_note", q.label, cx + 14 + (i - 1) * (chip_w + chip_gap), y + 80,
            chip_w, 24, act and "azure" or "parchment", { tiny = true, note_text = q.text })
    end

    -- Optional Note Input Row
    local note_focused = (lobby.focused_field == "report_note")
    local note_raw = tostring(u.note or "")
    local note_empty = (#note_raw == 0)
    local note_shown = note_empty and "补充一句发生了什么（可选，可不填）" or note_raw
    if not note_empty and #note_shown > 44 then note_shown = "..." .. note_shown:sub(-40) end
    local note_w = left_w - 28 - 62
    add_btn("report_note_box", note_shown .. (note_focused and "|" or ""), cx + 14, y + 111, note_w, 26, "input", {
        small = true, placeholder = note_empty and (not note_focused), focused = note_focused,
    })
    add_btn("paste_report_note", "粘贴", cx + 14 + note_w + 6, y + 111, 56, 26, "wood", { tiny = true })

    -- Target Relay Server Row (symmetric height whether active_ok or custom input!)
    local srv_y = y + 144
    if active_ok then
        local cur_srv = mask_addr_if_needed(lobby, lobby.transport:get_server_addr() or "")
        ui.draw_parchment_card(cx + 14, srv_y + 2, left_w - 28, 42, {
            top = { 230, 246, 232, 245 }, bot = { 216, 236, 218, 245 },
            border = { 54, 134, 70, 215 }, border_w = 1.4, radius = 7,
        })
        ui.draw_pill(cx + 22, srv_y + 7, 74, 17, "通道就绪 √",
            { 38, 128, 62, 240 }, { 24, 82, 38, 255 }, { 248, 255, 244, 255 }, fm.tiny_bold)
        ui.text(ellipsize_px(fm.tiny_bold, "复用当前公网中继服 · " .. cur_srv, left_w - 134),
            cx + 102, srv_y + 8, { 26, 98, 42, 255 }, fm.tiny_bold)
        ui.text("无需另填地址，点下方绿按钮立刻安全上传生成反馈码。",
            cx + 22, srv_y + 26, T.ink_sub, fm.tiny, left_w - 44, "left")
    else
        ui.text("目标公网中继服（默认自动带入公网页地址）：", cx + 14, srv_y, T.ink_muted, fm.tiny)
        local srv_focused = (lobby.focused_field == "report_server")
        local srv_raw = tostring(u.server_addr or "")
        local srv_empty = (#srv_raw == 0)
        local srv_shown = srv_empty and "填公网服地址 (如 群服IP:17780)"
            or (srv_focused and srv_raw or mask_addr_if_needed(lobby, srv_raw))
        if not srv_empty and #srv_shown > 34 then srv_shown = "..." .. srv_shown:sub(-30) end
        local srv_w = left_w - 28 - 62
        add_btn("report_server_box", srv_shown .. (srv_focused and "|" or ""), cx + 14, srv_y + 17, srv_w, 26, "input", {
            small = true, placeholder = srv_empty and (not srv_focused), focused = srv_focused,
        })
        add_btn("paste_report_server", "粘贴", cx + 14 + srv_w + 6, srv_y + 17, 56, 26, "wood", { tiny = true })
    end

    -- Status / Royal Ticket Plaque (y + 195 .. y + 269, height 74)
    local box_x, box_y, box_w, box_h = cx + 14, y + 195, left_w - 28, 74
    local cta_y, cta_h = y + card_h - 46, 36
    if u.state == "done" and u.code then
        ui.draw_armory_tray(box_x, box_y, box_w, box_h, 8)
        G.setColor(T.gold_mid[1], T.gold_mid[2], T.gold_mid[3], 170)
        G.setLineWidth(1.2)
        G.rectangle("line", box_x + 3, box_y + 3, box_w - 6, box_h - 6, 6, 6)
        ui.print_shadow("上传成功 √  发下方反馈码到群里即可定位：",
            box_x + 12, box_y + 9, T.ok_bright, nil, nil, nil, fm.tiny_bold)
        ui.print_shadow("#" .. tostring(u.code),
            box_x + 12, box_y + 27, T.gold_bright, nil, nil, nil, fm.banner)
        ui.text(string.format("已上传 %.1f KB · 反馈码已自动复制", (tonumber(u.bytes) or 0) / 1024),
            box_x + 12, box_y + 52, { 226, 206, 168, 225 }, fm.tiny)
        add_btn("report_copy_ticket", "复制反馈码", box_x + box_w - 104, box_y + 21, 92, 32, "battle", { small = true })
        add_btn("report_cloud_upload", "重新上传一份", cx + 14, cta_y, left_w - 28, cta_h, "parchment", { small = true })
    elseif u.state == "connecting" or u.state == "sending" then
        ui.draw_armory_tray(box_x, box_y, box_w, box_h, 8)
        local t = (love and love.timer and love.timer.getTime and love.timer.getTime()) or 0
        local dots = string.rep(".", (math.floor(t * 2.5) % 3) + 1)
        local st_txt = (u.state == "connecting")
            and ("正在连接公网中继服并校验通道" .. dots)
            or ("正在发送已脱敏的黑匣子报告" .. dots)
        ui.print_shadow(st_txt, box_x + 12, box_y + 18, T.gold_bright, box_w - 24, "center", nil, fm.small_bold)
        ui.text("使用独立短连通道，绝不断开当前游戏房间",
            box_x + 12, box_y + 44, { 224, 204, 164, 215 }, fm.tiny, box_w - 24, "center")
        add_btn("report_cloud_upload", "正在安全上传中...", cx + 14, cta_y, left_w - 28, cta_h, "wood", { small = false, disabled = true })
    else
        if u.state == "error" and u.err then
            ui.draw_parchment_card(box_x, box_y, box_w, box_h, {
                top = { 254, 234, 230, 252 }, bot = { 244, 214, 208, 252 },
                border = T.p2_border, border_w = 1.6, radius = 8,
            })
            ui.text(ellipsize_px(fm.tiny_bold, "上传未成功：" .. tostring(u.err), box_w - 20),
                box_x + 10, box_y + 11, { 164, 34, 28, 255 }, fm.tiny_bold)
            ui.text("若当前没开公网服，直接点右侧「一键本地导出 (.json)」也能同样精准复现！",
                box_x + 10, box_y + 34, T.ink_sub, fm.tiny, box_w - 20, "left")
        else
            ui.draw_parchment_card(box_x, box_y, box_w, box_h, {
                top = { 248, 244, 230, 245 }, bot = { 236, 224, 194, 245 },
                border = { 162, 126, 74, 195 }, border_w = 1.2, radius = 8,
            })
            ui.draw_pill(box_x + 10, box_y + 12, 18, 18, "√",
                { 42, 132, 64, 235 }, { 24, 82, 38, 255 }, { 248, 255, 244, 255 }, fm.tiny_bold)
            ui.text("打包：关卡/英雄/双端黑匣子、不同步比对与脱敏日志",
                box_x + 34, box_y + 14, T.ink_text, fm.tiny)
            ui.draw_pill(box_x + 10, box_y + 42, 18, 18, "√",
                { 42, 132, 64, 235 }, { 24, 82, 38, 255 }, { 248, 255, 244, 255 }, fm.tiny_bold)
            ui.text("原则：仅在你点击下方按钮时发送，绝不后台静默上传",
                box_x + 34, box_y + 44, { 30, 102, 46, 255 }, fm.tiny_bold)
        end
        local cta_lbl = (u.state == "error") and "重试云端上传（生成反馈码）" or "确认上传并生成反馈码"
        add_btn("report_cloud_upload", cta_lbl, cx + 14, cta_y, left_w - 28, cta_h, "battle", { small = false })
    end
end

local function draw_right_local_card(ctx, y, rx, right_w, card_h, diag)
    local G, T, fm, add_btn = ctx.G, ctx.T, ctx.font_map, ctx.add_btn
    ui.draw_parchment_card(rx, y, right_w, card_h, {
        top = { 246, 241, 226, 252 },
        bot = { 232, 214, 178, 250 },
        border = { 46, 106, 162, 235 },
        border_w = 2.0,
        thumbtack = true,
        radius = 9,
    })
    ui.draw_pill(rx + 14, y + 11, 182, 20, "方式二 · 本地导出 (离线可用)",
        { 36, 98, 158, 245 }, { 22, 64, 108, 255 }, { 242, 250, 255, 255 }, fm.tiny_bold)
    ui.text("不连公网服也能精准排错", rx + 14, y + 37, T.ink_text, fm.hero)
    draw_divider(G, T, rx + 14, y + 57, right_w - 28)

    local steps = proto.is_android() and {
        "点下方按钮保存黑匣子，并自动复制诊断摘要到剪贴板。",
        "切回 QQ / 微信群长按粘贴发给作者即可快速排查。",
        "存档目录 kr_mp_reports/ 自动滚存保留最近 10 份报告。",
    } or {
        "点下方按钮在桌面生成 .json，并自动弹窗选中该文件。",
        "把选中的 .json 直接拖进群里，摘要也已自动复制。",
        "游戏目录 kr_mp_reports/ 自动保留最近 10 份不覆盖。",
    }
    local step_h, step_gap = 47, 7
    for i, line in ipairs(steps) do
        local sy = y + 66 + (i - 1) * (step_h + step_gap)
        ui.draw_parchment_card(rx + 14, sy, right_w - 28, step_h, {
            top = { 252, 247, 234, 245 }, bot = { 240, 226, 196, 245 },
            border = { 164, 130, 82, 175 }, border_w = 1.1, radius = 6,
        })
        ui.draw_pill(rx + 22, sy + 12, 22, 22, tostring(i),
            { 36, 98, 158, 240 }, { 22, 64, 108, 255 }, { 246, 252, 255, 255 }, fm.tiny_bold)
        ui.text(line, rx + 50, sy + 7, T.ink_text, fm.tiny, right_w - 72, "left")
    end

    -- Bottom Info / Recent Export Strip (bottom edge aligned with Left Card plaque!)
    local strip_y, strip_h = y + 229, 40
    if diag and diag.last_export_path and #diag.last_export_path > 0 then
        local short_p = diag.last_export_path:match("([^/\\]+)$") or diag.last_export_path
        ui.draw_parchment_card(rx + 14, strip_y, right_w - 28, strip_h, {
            top = { 232, 246, 232, 248 }, bot = { 216, 236, 218, 248 },
            border = { 54, 134, 70, 215 }, border_w = 1.3, radius = 7,
        })
        ui.text("最近已导出 √（可直接发群）", rx + 24, strip_y + 5, { 26, 98, 42, 255 }, fm.tiny_bold)
        ui.text(ellipsize_px(fm.tiny, short_p, right_w - 48), rx + 24, strip_y + 22, T.ink_sub, fm.tiny)
    else
        ui.draw_parchment_card(rx + 14, strip_y, right_w - 28, strip_h, {
            top = { 246, 238, 218, 242 }, bot = { 234, 218, 184, 242 },
            border = { 158, 122, 68, 175 }, border_w = 1.1, radius = 7,
        })
        ui.text("崩溃 / 不同步自动留档", rx + 24, strip_y + 5, T.ink_text, fm.tiny_bold)
        ui.text("重开游戏也不会覆盖上次报错现场", rx + 24, strip_y + 22, T.ink_muted, fm.tiny)
    end

    add_btn("report_local_export", proto.is_android() and "导出并复制诊断摘要" or "一键本地导出 (.json)",
        rx + 14, y + card_h - 46, right_w - 28, 36, "azure", { small = false })
end

function M.draw(ctx)
    local lobby, T, cx, cw, py, fm, add_btn = ctx.lobby, ctx.T, ctx.cx, ctx.cw, ctx.py, ctx.font_map, ctx.add_btn
    local diag = lobby.boot and lobby.boot.diagnostics
    if diag and diag.sync_modal_defaults then
        diag:sync_modal_defaults(lobby)
    end
    local prev = diag and diag:get_preview_summary() or {
        kind = "lobby",
        urgent = false,
        title = "运行日志与环境信息",
        detail = "v" .. tostring(proto.MOD_VERSION),
    }
    local u = (diag and diag.upload) or { state = "idle", note = "", server_addr = "" }

    -- Top Dark-Oak Recessed Diagnostic Status Header (y = 40..90)
    local y = py + 40
    ui.draw_armory_tray(cx, y, cw, 50, 9)
    ui.draw_ping_dot(cx + 18, y + 16, prev.urgent and 999 or 18, not prev.urgent)
    local badge_txt = prev.urgent and "已锁定异常黑匣子" or (prev.has_blackbox and "含完整黑匣子" or "大厅环境日志")
    local badge_bg = prev.urgent and T.p2_top or (prev.has_blackbox and { 38, 128, 62, 242 } or { 108, 76, 36, 235 })
    local badge_bd = prev.urgent and { 228, 120, 112, 220 } or (prev.has_blackbox and { 118, 220, 140, 200 } or T.gold_mid)
    ui.draw_pill(cx + 28, y + 7, 118, 19, badge_txt, badge_bg, badge_bd, { 255, 252, 240, 255 }, fm.tiny_bold)
    local title_col = prev.urgent and { 255, 198, 184, 255 } or T.gold_bright
    ui.print_shadow(ellipsize_px(fm.small_bold, prev.title, cw - 256),
        cx + 154, y + 8, title_col, nil, nil, nil, fm.small_bold)
    ui.text(ellipsize_px(fm.tiny, prev.detail, cw - 130),
        cx + 28, y + 30, { 226, 206, 168, 228 }, fm.tiny)
    add_btn("modal_back", "返回战桌", cx + cw - 92, y + 10, 82, 30, "parchment", { small = true })

    -- Two Symmetric Pinned Parchment Cards (y = 99..425)
    y = y + 59
    local left_w = 434
    local right_w = cw - left_w - 12
    local card_h = 326
    local active_online = (lobby.transport and lobby.transport:is_online()
        and lobby.transport:is_connected() and lobby.server_connected) == true
    local active_ok = active_online and (lobby.server_report_ok == true)

    draw_left_cloud_card(ctx, y, left_w, card_h, u, active_ok)
    draw_right_local_card(ctx, y, cx + left_w + 12, right_w, card_h, diag)

    -- Bottom Privacy Guarantee Strip (y = 434..462)
    local foot_y = y + card_h + 9
    ui.draw_parchment_card(cx, foot_y, cw, 28, {
        top = { 244, 235, 212, 232 }, bot = { 234, 218, 184, 232 },
        border = { 162, 126, 72, 155 }, border_w = 1.0, radius = 6,
    })
    ui.text("隐私保护：导出或上传前均自动擦除樱花访问密钥、电脑用户名与外网 IP，仅保留游戏排错所需数据。",
        cx + 12, foot_y + 7, T.ink_muted, fm.tiny, cw - 24, "center")
end

-- === Co-located Report Modal Button Handlers (registered by lobby_input.lua) ===

local H = {}

function H.export_report(lobby)
    if lobby.overlay then lobby.overlay:clear_toast() end
    local diag = lobby.boot and lobby.boot.diagnostics
    if diag and diag.sync_modal_defaults then diag:sync_modal_defaults(lobby) end
    lobby.sub_modal = (lobby.sub_modal == "report") and nil or "report"
end
function H.report_local_export(lobby)
    local diag = lobby.boot and lobby.boot.diagnostics
    if diag then
        diag:export_user_report("lobby_modal")
    elseif lobby.overlay then
        lobby.overlay:show_toast("诊断模块未就绪。", 2.0)
    end
end
function H.report_cloud_upload(lobby)
    local diag = lobby.boot and lobby.boot.diagnostics
    if diag then
        diag:start_cloud_upload(lobby, diag.upload and diag.upload.server_addr, diag.upload and diag.upload.note, "lobby_modal")
    end
end
function H.report_copy_ticket(lobby)
    local diag = lobby.boot and lobby.boot.diagnostics
    if diag then diag:copy_last_ticket() end
end
function H.report_quick_note(lobby, btn)
    local diag = lobby.boot and lobby.boot.diagnostics
    if diag and diag.upload and type(btn.note_text) == "string" then
        diag.upload.note = (diag.upload.note == btn.note_text) and "" or btn.note_text
    end
end
function H.report_note_box(lobby) lobby:set_focus("report_note") end
function H.paste_report_note(lobby) lobby:paste_into_field("report_note") end
function H.report_server_box(lobby) lobby:set_focus("report_server") end
function H.paste_report_server(lobby) lobby:paste_into_field("report_server") end

M.BTN_HANDLERS = H
return M
