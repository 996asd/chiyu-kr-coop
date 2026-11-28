-- KR-MP Diagnostics Layer 3: Explicit Opt-In Cloud Bug Report Uploader (#R-XXXX Ticket)
-- Extracted from diagnostics.lua to keep every flat module cohesive and <= 1,000 lines.
-- Guarantees:
--   1. NEVER uploads silently; strictly triggered by explicit user click.
--   2. Reuses active Online Relay TCP when connected to a report_ok server (zero match/room disruption).
--   3. Falls back to an isolated temporary non-blocking net_online socket so Sakura/LAN rooms are NEVER dropped.
local proto = require("kr_mp.proto")
local catalog = require("kr_mp.catalog")

local M = {}

local MAX_UPLOAD_JSON_BYTES = 480 * 1024
local UPLOAD_TIMEOUT_SEC = 12.0

local function diag_now()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local deep_copy = proto.deep_copy

function M.new_state()
    return {
        state = "idle",      -- "idle" | "connecting" | "sending" | "done" | "error"
        via = nil,           -- "active" | "temp"
        server_addr = "",
        note = "",
        started_ts = 0,
        code = nil,
        bytes = 0,
        err = nil,
        summary_text = nil,
        _temp_net = nil,
        _payload = nil,
        _reused_prev = false,
        _report_meta = nil,
    }
end

function M.close_temp(diag)
    local u = diag.upload
    if u and u._temp_net then
        pcall(u._temp_net.close, u._temp_net)
        u._temp_net = nil
    end
end

function M.reset(diag)
    M.close_temp(diag)
    diag.upload = M.new_state()
end

function M.sync_modal_defaults(diag, lobby)
    local u = diag.upload
    if not u then M.reset(diag); u = diag.upload end
    if (not u.server_addr or #u.server_addr == 0) and lobby then
        local srv = (lobby.transport and lobby.transport:is_online() and lobby.transport:get_server_addr())
            or lobby.server_input or ""
        u.server_addr = proto.sanitize_addr(srv):sub(1, 80)
    end
    if u.state == "done" and (diag.has_unread_issue or diag.prev_issue_fname) then
        u.state = "idle"
        u.code = nil
        u.err = nil
    end
end

function M.get_preview_summary(diag)
    local integ = diag:check_manifest(false)
    local integ_txt = (integ.status == "clean")
        and string.format("文件校验:正常(%d)", tonumber(integ.ok_count) or 0)
        or string.format("文件校验:%s(改%d/缺%d)", tostring(integ.status or "?"), #(integ.modified or {}), #(integ.missing or {}))
    local detail = string.format("v%s · %s · 已自动脱敏(隐藏樱花密钥/用户名/外网IP)", tostring(proto.MOD_VERSION), integ_txt)

    if not diag.active_match and not diag.last_match and not diag.last_crash and diag.prev_issue_fname then
        return {
            kind = "prev_issue",
            urgent = true,
            title = "已自动锁定上次崩溃/异常黑匣子：" .. tostring(diag.prev_issue_fname),
            detail = detail,
            has_blackbox = true,
        }
    end
    if diag.last_crash and #diag.last_crash > 0 then
        return {
            kind = "crash",
            urgent = true,
            title = "已捕获本次 Lua 崩溃堆栈与完整黑匣子",
            detail = detail,
            has_blackbox = (diag.active_match ~= nil or diag.last_match ~= nil),
        }
    end
    local m = diag.active_match or diag.last_match
    if m then
        local lvl = tonumber(m.cfg and m.cfg.level_idx) or 0
        local lname = (lvl > 0 and catalog.get_stage_label) and catalog.get_stage_label(lvl) or ("关卡 " .. tostring(lvl))
        if m.desync then
            return {
                kind = "desync",
                urgent = true,
                title = string.format("已锁定同步异常黑匣子 · %s (第 %s 帧 DESYNC)", lname, tostring(m.desync.tick or m.last_tick or 0)),
                detail = detail,
                has_blackbox = true,
            }
        end
        return {
            kind = "match",
            urgent = false,
            title = string.format("最近对局黑匣子 · %s (%dP · 第 %d 帧)", lname, tonumber(m.pid) or 1, tonumber(m.last_tick) or 0),
            detail = detail,
            has_blackbox = true,
        }
    end
    return {
        kind = "lobby",
        urgent = false,
        title = "当前联机大厅运行日志与环境信息（最近 400 行日志）",
        detail = detail,
        has_blackbox = false,
    }
end

function M.prepare_upload_report(diag, reason, note)
    local report, reused_prev = diag:_resolve_or_build_report(tostring(reason or "cloud_upload"), true)

    -- Enforce server 512 KB upload budget gracefully without dropping crash/desync snapshots
    local enc = proto.encode(report)
    if #enc > MAX_UPLOAD_JSON_BYTES then
        local trimmed = deep_copy(report)
        if type(trimmed.logs) == "table" and #trimmed.logs > 120 then
            local tail = {}
            for i = #trimmed.logs - 119, #trimmed.logs do tail[#tail + 1] = trimmed.logs[i] end
            trimmed.logs = tail
        end
        enc = proto.encode(trimmed)
        if #enc > MAX_UPLOAD_JSON_BYTES and type(trimmed.blackbox) == "table" and type(trimmed.blackbox.turns) == "table" then
            local tlist = trimmed.blackbox.turns
            if #tlist > 250 then
                local tail_t = {}
                for i = #tlist - 249, #tlist do tail_t[#tail_t + 1] = tlist[i] end
                trimmed.blackbox.turns = tail_t
                trimmed.blackbox.truncated_for_upload = true
            end
        end
        report = trimmed
    end

    local secrets = diag:_collect_secrets()
    local clean_note = diag.sanitize_text(tostring(note or ""), secrets)
        :gsub("[\r\n\t]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #clean_note > 180 then clean_note = clean_note:sub(1, 180) end

    local m = report.match
    local meta = {
        reason = tostring(report.reason or reason or "manual"),
        level_name = (m and m.level_name) or "大厅",
        tick = (m and m.desync and m.desync.tick) or (m and m.last_tick) or 0,
        note = clean_note,
    }
    return report, clean_note, meta, reused_prev
end

function M.build_ticket_clipboard_text(code, meta)
    meta = meta or {}
    local parts = {
        string.format("【KR-MP 报错反馈码】#%s（v%s · %s · 帧 %s · %s）",
            tostring(code or "?"), tostring(proto.MOD_VERSION),
            tostring(meta.level_name or "大厅"), tostring(meta.tick or 0), tostring(meta.reason or "manual")),
    }
    if type(meta.note) == "string" and #meta.note > 0 then
        parts[#parts + 1] = "现象备注：" .. meta.note
    end
    return table.concat(parts, "\n")
end

function M.on_ok(diag, msg)
    local u = diag.upload
    M.close_temp(diag)
    local code = tostring(msg and msg.code or "?")
    local bytes = tonumber(msg and msg.bytes) or 0
    u.state = "done"
    u.code = code
    u.bytes = bytes
    u.err = nil
    u._payload = nil
    u.summary_text = M.build_ticket_clipboard_text(code, u._report_meta)

    diag.has_unread_issue = false
    if u._reused_prev then
        diag.prev_issue_fname = nil
        u._reused_prev = false
    end

    local clip_ok = false
    if love and love.system and love.system.setClipboardText then
        clip_ok = pcall(love.system.setClipboardText, u.summary_text)
    end
    if diag.boot then
        diag.boot:log("[DIAG] Cloud bug report uploaded OK -> #%s (%d bytes)", code, bytes)
    end
    local ov = diag.overlay or (diag.boot and diag.boot.overlay)
    if ov and ov.show_toast then
        ov:show_toast(clip_ok
            and ("上传成功 √ 反馈码 #" .. code .. " 已复制到剪贴板！直接发群里给作者即可！")
            or ("上传成功 √ 反馈码 #" .. code .. "（请把反馈码发给作者）"), 6.0)
    end
end

function M.on_err(diag, err_msg)
    local u = diag.upload
    M.close_temp(diag)
    local clean_err = tostring(err_msg or "上传失败")
    u.state = "error"
    u.err = clean_err
    u._payload = nil
    if diag.boot then
        diag.boot:log("[DIAG] Cloud bug report upload FAILED: %s", clean_err)
    end
    local ov = diag.overlay or (diag.boot and diag.boot.overlay)
    if ov and ov.show_toast then
        ov:show_toast("云端上传失败：" .. clean_err .. "（可改用「本地导出 (.json)」发群里）", 5.5)
    end
end

function M.copy_last_ticket(diag)
    local u = diag.upload
    if not u or not u.code then return false end
    local text = u.summary_text or ("#" .. tostring(u.code))
    local ov = diag.overlay or (diag.boot and diag.boot.overlay)
    if love and love.system and love.system.setClipboardText then
        local ok = pcall(love.system.setClipboardText, text)
        if ok and ov and ov.show_toast then
            ov:show_toast("已复制反馈码 #" .. tostring(u.code) .. "，直接粘贴发群里给作者即可！", 3.0)
        end
        return ok
    end
    return false
end

local function make_hello_packet()
    return {
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "BugReporter",
    }
end

function M.start(diag, lobby, server_addr_override, note_override, reason)
    local u = diag.upload
    if not u then M.reset(diag); u = diag.upload end
    if u.state == "connecting" or u.state == "sending" then
        local ov = diag.overlay or (diag.boot and diag.boot.overlay)
        if ov and ov.show_toast then ov:show_toast("正在上传报错黑匣子，请稍候几秒...", 2.0) end
        return false, "busy"
    end

    local use_note = (note_override ~= nil) and tostring(note_override) or tostring(u.note or "")
    local report, clean_note, meta, reused_prev = M.prepare_upload_report(diag, reason or "cloud_upload", use_note)
    u.note = use_note
    u.code = nil
    u.err = nil
    u.bytes = 0
    u.summary_text = nil
    u._reused_prev = reused_prev
    u._report_meta = meta
    u.started_ts = diag_now()

    local packet = { t = "BUG_REPORT", note = clean_note, report = report }

    -- Path A: Reuse active Online Relay TCP socket with zero room/match disruption
    local active_online = lobby and lobby.transport and lobby.transport:is_online()
        and lobby.transport:is_connected() and lobby.server_connected
    local want_addr = proto.sanitize_addr(server_addr_override or u.server_addr or (lobby and lobby.server_input) or ""):sub(1, 80)
    local cur_addr = active_online and lobby.transport:get_server_addr() or nil
    if active_online and (want_addr == "" or want_addr == cur_addr or server_addr_override == nil) then
        if lobby.server_report_ok ~= true then
            M.on_err(diag, "当前公网中继服是旧版，暂不支持云端反馈码")
            return false, "unsupported_server"
        end
        u.via = "active"
        u.state = "sending"
        u.server_addr = cur_addr or want_addr
        local sent = lobby.transport:send(packet)
        if not sent then
            M.on_err(diag, "发送报错包失败：与公网服连接已中断")
            return false, "send_failed"
        end
        if diag.boot then
            diag.boot:log("[DIAG] Uploading bug report via active online socket (%s)", tostring(u.server_addr))
        end
        return true, "sending"
    end

    -- Path B: Isolated temporary non-blocking net_online socket (NEVER touches Sakura/LAN rooms)
    if want_addr == "" then
        M.on_err(diag, "请先填写公网中继服地址（如 群服IP:17780）")
        return false, "no_server"
    end
    u.server_addr = want_addr
    local ok_no, net_online = pcall(require, "kr_mp.net_online")
    if not ok_no or not net_online then
        M.on_err(diag, "网络模块未就绪")
        return false, "no_net_online"
    end
    M.close_temp(diag)
    local tmp = net_online.new(diag.boot, "kr_mp_report_dns")
    u._temp_net = tmp
    u._payload = packet
    u.via = "temp"
    u.state = "connecting"

    local ok_c, st = tmp:connect(want_addr, proto.DEFAULT_ONLINE_PORT, true)
    if not ok_c then
        M.on_err(diag, tostring(st or "无法连接公网中继服"))
        return false, "connect_failed"
    end
    if st == "connected" then
        tmp:send(make_hello_packet())
    end
    if diag.boot then
        diag.boot:log("[DIAG] Opening temporary upload connection to %s (state=%s)", want_addr, tostring(st))
    end
    return true, "connecting"
end

function M.update(diag)
    local u = diag.upload
    if not u or (u.state ~= "connecting" and u.state ~= "sending") then
        return
    end
    if (diag_now() - (u.started_ts or 0)) >= UPLOAD_TIMEOUT_SEC then
        M.on_err(diag, "连接或上传超时，请检查公网中继服地址是否在线")
        return
    end
    if u.via ~= "temp" or not u._temp_net then
        return
    end
    local events = u._temp_net:poll()
    for i = 1, #events do
        local ev = events[i]
        if ev.type == "server_connected" then
            u._temp_net:send(make_hello_packet())
        elseif ev.type == "server_connect_failed" then
            M.on_err(diag, tostring(ev.reason or "无法连接公网中继服"))
            return
        elseif ev.type == "server_disconnected" then
            if u.state ~= "done" and u.state ~= "error" then
                M.on_err(diag, "中继服连接已断开（请确认目标为新版 17780 公网服，不是 17777 樱花直连）")
            end
            return
        elseif ev.type == "msg" and type(ev.msg) == "table" then
            local m = ev.msg
            if m.t == "SERVER_HELLO" then
                if m.report_ok ~= true then
                    M.on_err(diag, "目标中继服版本较旧或未开启报错收集")
                    return
                end
                u.state = "sending"
                if not u._temp_net:send(u._payload) then
                    M.on_err(diag, "发送报错报告数据失败")
                    return
                end
            elseif m.t == "BUG_REPORT_OK" then
                M.on_ok(diag, m)
                return
            elseif m.t == "BUG_REPORT_ERR" or m.t == "ERROR" then
                M.on_err(diag, tostring(m.msg or "服务端拒绝接收报错"))
                return
            end
        end
    end
end

return M
