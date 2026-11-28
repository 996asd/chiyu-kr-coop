-- KR-MP Bug Diagnostics & Opt-In Cloud Report Modal Renderer
-- Keeps lobby_draw.lua / lobby_draw_modals.lua clean & modular (<= 1,000 lines each).
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

    local y = py + 42
    -- Top Header Bar: Back button + Auto-detected Black-Box Status Banner
    ui.draw_parchment_card(cx, y, cw - 98, 46, {
        top = prev.urgent and { 254, 236, 232, 252 } or { 242, 238, 224, 252 },
        bot = prev.urgent and { 242, 214, 206, 250 } or { 228, 216, 186, 250 },
        border = prev.urgent and T.p2_border or { 138, 94, 40, 235 },
        border_w = 1.8,
        radius = 8,
    })
    local badge_txt = prev.urgent and "已锁定异常黑匣子" or (prev.has_blackbox and "含完整黑匣子" or "大厅环境日志")
    local badge_bg = prev.urgent and T.p2_top or { 38, 118, 56, 240 }
    ui.draw_pill(cx + 10, y + 6, 118, 18, badge_txt, badge_bg, T.ink_dark, { 255, 252, 240, 255 }, fm.tiny_bold)
    ui.text(prev.title, cx + 134, y + 6, prev.urgent and { 150, 28, 24, 255 } or T.ink_text, fm.tiny_bold, cw - 242, "left")
    ui.text(prev.detail, cx + 10, y + 27, T.ink_sub, fm.tiny, cw - 118, "left")
    add_btn("modal_back", "返回", cx + cw - 88, y + 8, 88, 30, "wood", { small = true })

    y = y + 56

    -- Two-Column Layout: Left = Opt-In Cloud Upload (#R-XXXX), Right = Offline Local Export (.json)
    local left_w = 438
    local right_w = cw - left_w - 12
    local card_h = 304

    -- === Left Card: Way 1 — Cloud Upload -> 6-Char Ticket Code ===
    ui.draw_parchment_card(cx, y, left_w, card_h, {
        top = { 238, 244, 236, 252 },
        bot = { 224, 214, 182, 250 },
        border = { 42, 122, 62, 235 },
        border_w = 2.0,
        thumbtack = true,
        radius = 9,
    })

    local active_online = (lobby.transport and lobby.transport:is_online()
        and lobby.transport:is_connected() and lobby.server_connected) == true
    local active_ok = active_online and (lobby.server_report_ok == true)
    ui.draw_pill(cx + 14, y + 11, 178, 20, "方式一 · 云端上传 (推荐)",
        { 38, 128, 62, 245 }, { 24, 82, 38, 255 }, { 248, 255, 244, 255 }, fm.tiny_bold)
    if active_ok then
        ui.draw_pill(cx + left_w - 154, y + 11, 140, 20, "已连公网服 · 秒传 √",
            { 34, 108, 158, 240 }, { 22, 68, 104, 255 }, { 242, 250, 255, 255 }, fm.tiny_bold)
    else
        ui.draw_pill(cx + left_w - 178, y + 11, 164, 20, "临时短连 · 不断开当前房",
            { 96, 68, 36, 225 }, { 148, 112, 60, 210 }, T.gold_bright, fm.tiny_bold)
    end

    ui.text("一键生成 6 位反馈码（如 #R-4K9A），发群里给作者即可 30 倍速复现！",
        cx + 14, y + 37, T.ink_text, fm.small_bold, left_w - 28, "left")

    -- Quick Symptom Preset Chips (zero typing needed on PC or Android!)
    ui.text("快捷点选现象（可选）：", cx + 14, y + 61, T.ink_muted, fm.tiny)
    local chip_gap = 6
    local chip_w = math.floor((left_w - 28 - (#QUICK_NOTES - 1) * chip_gap) / #QUICK_NOTES)
    for i, q in ipairs(QUICK_NOTES) do
        local act = (u.note == q.text)
        add_btn("report_quick_note", q.label, cx + 14 + (i - 1) * (chip_w + chip_gap), y + 79,
            chip_w, 24, act and "azure" or "parchment", { tiny = true, note_text = q.text })
    end

    -- Optional Note Input Box
    local note_focused = (lobby.focused_field == "report_note")
    local note_raw = tostring(u.note or "")
    local note_empty = (#note_raw == 0)
    local note_shown = note_empty and "补充一句发生了什么（可选，可不填）" or note_raw
    if not note_empty and #note_shown > 44 then note_shown = "..." .. note_shown:sub(-40) end
    local note_w = left_w - 28 - 62
    add_btn("report_note_box", note_shown .. (note_focused and "|" or ""), cx + 14, y + 110, note_w, 26, "input", {
        small = true, placeholder = note_empty and (not note_focused), focused = note_focused,
    })
    add_btn("paste_report_note", "粘贴", cx + 14 + note_w + 6, y + 110, 56, 26, "wood", { tiny = true })

    -- Target Relay Server Row
    local srv_y = y + 144
    if active_ok then
        local cur_srv = mask_addr_if_needed(lobby, lobby.transport:get_server_addr() or "")
        ui.text("上传通道：直接复用当前公网中继服 (" .. cur_srv .. ")", cx + 14, srv_y + 5, { 34, 108, 48, 255 }, fm.tiny_bold, left_w - 28, "left")
    else
        ui.text("目标公网中继服（默认自动带入公网页地址）：", cx + 14, srv_y - 2, T.ink_muted, fm.tiny)
        local srv_focused = (lobby.focused_field == "report_server")
        local srv_raw = tostring(u.server_addr or "")
        local srv_empty = (#srv_raw == 0)
        local srv_shown = srv_empty and "填公网服地址 (如 群服IP:17780)"
            or (srv_focused and srv_raw or mask_addr_if_needed(lobby, srv_raw))
        if not srv_empty and #srv_shown > 34 then srv_shown = "..." .. srv_shown:sub(-30) end
        local srv_w = left_w - 28 - 62
        add_btn("report_server_box", srv_shown .. (srv_focused and "|" or ""), cx + 14, srv_y + 15, srv_w, 25, "input", {
            small = true, placeholder = srv_empty and (not srv_focused), focused = srv_focused,
        })
        add_btn("paste_report_server", "粘贴", cx + 14 + srv_w + 6, srv_y + 15, 56, 25, "wood", { tiny = true })
    end

    -- Status / Ticket Display Box + Primary Upload CTA
    local box_y = y + 190
    if u.state == "done" and u.code then
        ui.draw_parchment_card(cx + 14, box_y, left_w - 28, 56, {
            top = { 226, 248, 230, 255 },
            bot = { 206, 236, 212, 255 },
            border = { 38, 128, 62, 245 },
            border_w = 2.0,
            radius = 8,
        })
        ui.text("上传成功 √ 请把下方反馈码发到群里：", cx + 24, box_y + 6, { 26, 98, 42, 255 }, fm.tiny_bold)
        ui.text("#" .. tostring(u.code), cx + 24, box_y + 24, { 164, 34, 24, 255 }, fm.banner)
        ui.text(string.format("(%.1f KB · 已自动复制)", (tonumber(u.bytes) or 0) / 1024),
            cx + 142, box_y + 30, T.ink_sub, fm.tiny)
        add_btn("report_copy_ticket", "复制反馈码", cx + left_w - 118, box_y + 13, 94, 30, "battle", { small = true })
        add_btn("report_cloud_upload", "重新上传一份", cx + 14, y + card_h - 42, left_w - 28, 32, "parchment", { small = true })
    elseif u.state == "connecting" or u.state == "sending" then
        ui.draw_parchment_card(cx + 14, box_y, left_w - 28, 52, { radius = 7 })
        local st_txt = (u.state == "connecting") and "正在连接公网中继服并校验上传通道..." or "正在发送已脱敏的黑匣子报告，请稍候..."
        ui.text(st_txt, cx + 24, box_y + 17, { 34, 96, 152, 255 }, fm.small_bold, left_w - 48, "center")
        add_btn("report_cloud_upload", "正在上传中...", cx + 14, y + card_h - 42, left_w - 28, 34, "wood", { small = false, disabled = true })
    else
        if u.state == "error" and u.err then
            ui.draw_parchment_card(cx + 14, box_y, left_w - 28, 52, {
                top = { 252, 232, 228, 252 },
                bot = { 244, 214, 208, 252 },
                border = T.p2_border,
                border_w = 1.6,
                radius = 7,
            })
            ui.text("上传未成功：" .. tostring(u.err), cx + 22, box_y + 7, { 164, 34, 28, 255 }, fm.tiny_bold, left_w - 44, "left")
            ui.text("若当前没开公网服，直接点右侧「一键本地导出 (.json)」一样能定位！",
                cx + 22, box_y + 31, T.ink_sub, fm.tiny, left_w - 44, "left")
        else
            ui.draw_parchment_card(cx + 14, box_y, left_w - 28, 52, { radius = 7 })
            ui.text("• 包含：关卡/英雄/双端操作黑匣子、不同步比对、崩溃堆栈与脱敏日志。",
                cx + 22, box_y + 8, T.ink_sub, fm.tiny, left_w - 44, "left")
            ui.text("• 仅在你点击下方按钮时才会发送，绝不在后台偷偷上传！",
                cx + 22, box_y + 28, { 34, 108, 48, 255 }, fm.tiny_bold, left_w - 44, "left")
        end
        local cta_lbl = (u.state == "error") and "重试云端上传（生成反馈码）" or "确认上传并生成反馈码"
        add_btn("report_cloud_upload", cta_lbl, cx + 14, y + card_h - 44, left_w - 28, 36, "battle", { small = false })
    end

    -- === Right Card: Way 2 — Local Offline Export (.json) ===
    local rx = cx + left_w + 12
    ui.draw_parchment_card(rx, y, right_w, card_h, {
        top = { 246, 240, 224, 252 },
        bot = { 232, 214, 178, 250 },
        border = { 46, 106, 162, 235 },
        border_w = 2.0,
        thumbtack = true,
        radius = 9,
    })
    ui.draw_pill(rx + 14, y + 11, 180, 20, "方式二 · 本地导出 (离线可用)",
        { 36, 98, 158, 245 }, { 22, 64, 108, 255 }, { 242, 250, 255, 255 }, fm.tiny_bold)
    ui.text("不连公网服也能用", rx + 14, y + 38, T.ink_text, fm.hero)

    local steps = proto.is_android() and {
        "1. 点下方按钮，自动保存黑匣子并复制诊断摘要 + 最近日志到剪贴板。",
        "2. 直接切回 QQ/微信群长按粘贴发给作者。",
        "3. 手机存档目录 kr_mp_reports/ 自动滚存保留最近 10 份报告。",
    } or {
        "1. 点下方按钮，自动在桌面生成 KR-MP报错_xxx.json 并弹出文件夹选中它。",
        "2. 把选中的 .json 文件直接拖进群里发给作者（摘要也已自动复制）。",
        "3. 历史异常均在游戏目录 kr_mp_reports/ 自动保留最近 10 份，重开不覆盖。",
    }
    for i, line in ipairs(steps) do
        ui.text(line, rx + 14, y + 66 + (i - 1) * 44, T.ink_sub, fm.tiny, right_w - 28, "left")
    end

    if diag and diag.last_export_path and #diag.last_export_path > 0 then
        local short_p = diag.last_export_path:match("([^/\\]+)$") or diag.last_export_path
        ui.draw_pill(rx + 14, y + 206, right_w - 28, 22, "最近导出: " .. short_p:sub(1, 24),
            { 234, 220, 186, 245 }, { 148, 108, 52, 210 }, T.ink_text, fm.tiny)
    end

    add_btn("report_local_export", proto.is_android() and "导出并复制诊断摘要" or "一键本地导出 (.json)",
        rx + 14, y + card_h - 44, right_w - 28, 36, "azure", { small = false })

    -- Bottom Privacy Note
    ui.text("隐私保护：所有报告导出或上传前均自动擦除樱花访问密钥、电脑用户名与外网 IP，仅包含游戏排错所需信息。",
        cx, y + card_h + 12, T.ink_muted, fm.tiny, cw, "center")
end

return M
