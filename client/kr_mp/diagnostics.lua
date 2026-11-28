-- KR-MP Diagnostics, Match Black-Box Recorder & Cross-Platform One-Click Bug Exporter
-- Layer 1: Rolling archive (kr_mp_reports/, keeps latest 10), full match black-box (cfg + turns),
--          detailed both-peer command ring, manifest SHA-256 verification, privacy auto-sanitization.
-- Layer 2: Pure-Lua PC + Android one-click export (Desktop file + Explorer reveal + clipboard summary)
--          and friendly Chinese crash-screen guidance.
-- Layer 3: Explicit opt-in cloud bug report upload to Go relay server returning a 6-char ticket (#R-XXXX),
--          supporting both active online socket reuse and non-intrusive temporary TCP upload.
local proto = require("kr_mp.proto")
local win_util = require("kr_mp.win_util")
local catalog = require("kr_mp.catalog")
local cloud = require("kr_mp.diagnostics_cloud")

local REPORT_FORMAT = "kr-mp-report-v1"
local REPORTS_DIR_NAME = "kr_mp_reports"
local INDEX_FILE_NAME = "_index.json"
local MAX_ARCHIVED_REPORTS = 10
local MAX_LOG_LINES = 400
local MAX_RECENT_CMDS = 150
local MAX_RECENT_HASHES = 60

local diagnostics = {
    REPORT_FORMAT = REPORT_FORMAT,
    boot = nil,
    overlay = nil,
    log_ring = {},
    log_head = 0,
    log_count = 0,

    active_match = nil,
    last_match = nil,
    last_crash = nil,
    prev_issue_fname = nil,
    has_unread_issue = false,
    last_export_path = nil,
    _manifest_cache = nil,
    _user_profile_cache = nil,
    upload = cloud.new_state(),
}

-- === Lightweight O(1) Ring Buffer Helpers ===

local function ring_new(cap)
    return { items = {}, head = 0, count = 0, cap = cap }
end

local function ring_push(r, val)
    r.head = (r.head % r.cap) + 1
    r.items[r.head] = val
    if r.count < r.cap then r.count = r.count + 1 end
end

local function ring_to_list(r, max_tail)
    if not r or r.count == 0 then return {} end
    local n = r.count
    local want = (max_tail and max_tail < n) and max_tail or n
    local out = {}
    local start_idx = ((r.head - want) % r.cap) + 1
    for i = 0, want - 1 do
        local pos = ((start_idx - 1 + i) % r.cap) + 1
        out[#out + 1] = r.items[pos]
    end
    return out
end

local deep_copy = proto.deep_copy

local function escape_lua_pattern(s)
    return (tostring(s or ""):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- === Privacy Auto-Sanitization ===

local function is_private_ipv4(a, b)
    a, b = tonumber(a), tonumber(b)
    if not a or not b then return false end
    if a == 127 or a == 10 or a == 0 or a == 255 then return true end
    if a == 192 and b == 168 then return true end
    if a == 172 and b >= 16 and b <= 31 then return true end
    return false
end

function diagnostics.sanitize_text(str, extra_secrets)
    if type(str) ~= "string" then return "" end
    -- Strip non-printable ASCII control chars (keep \r \n \t) so JSON stays strictly RFC 8259 valid
    local s = str:gsub("[%z\1-\8\11\12\14-\31]", " ")
    if type(extra_secrets) == "table" then
        for i = 1, #extra_secrets do
            local sec = extra_secrets[i]
            if type(sec) == "string" and #sec >= 6 then
                s = s:gsub(escape_lua_pattern(sec), "***")
            end
        end
    end
    -- Mask Windows user profile paths (preserve Public / Default)
    s = s:gsub("([%a]:[/\\][Uu]sers[/\\])([^/\\:%s\"']+)", function(prefix, uname)
        local low = uname:lower()
        if low == "public" or low == "default" then return prefix .. uname end
        return prefix .. "***"
    end)
    -- Mask explicit token/authorization key-value patterns
    s = s:gsub('("?[Tt]oken"?%s*[:=]%s*"?)([%w%-_%.]+)', "%1***")
    s = s:gsub("([Aa]uthorization%s*:%s*[Bb]earer%s+)([%w%-_%.]+)", "%1***")
    -- Mask SakuraFrp / nyat tunnel domains with ports
    s = s:gsub("frp%-[%w%-]+%.[%w%.%-]+:%d+", "frp-***.***:****")
    s = s:gsub("[%w%-]+%.nyat%.app:%d+", "***.nyat.app:****")
    -- Mask non-private IPv4 addresses while preserving 127.0.0.1 / LAN IPs
    s = s:gsub("(%d+)%.(%d+)%.(%d+)%.(%d+)", function(a, b, c, d)
        local na, nb, nc, nd = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
        if not (na and nb and nc and nd and na <= 255 and nb <= 255 and nc <= 255 and nd <= 255) then
            return a .. "." .. b .. "." .. c .. "." .. d
        end
        if is_private_ipv4(na, nb) then
            return a .. "." .. b .. "." .. c .. "." .. d
        end
        return a .. ".*.*." .. d
    end)
    return s
end

function diagnostics:_collect_secrets()
    local out = {}
    local sk = self.boot and self.boot.sakura
    if sk and type(sk.token) == "string" and #sk.token >= 6 then
        out[#out + 1] = sk.token
    end
    local prof = self._user_profile_cache
    if prof == nil then
        prof = win_util.get_env_utf8("USERNAME") or ""
        self._user_profile_cache = prof
    end
    -- Only scrub exact USERNAME if >= 4 chars and not generic words like "work"/"user"
    if #prof >= 4 and prof:lower() ~= "user" and prof:lower() ~= "work" and prof:lower() ~= "admin" then
        -- Path-level scrubbing already masks C:\Users\<name>, so avoid mangling random English words
        out[#out + 1] = "\\Users\\" .. prof
        out[#out + 1] = "/Users/" .. prof
    end
    return out
end

-- === Cross-Platform Storage (kr_mp_reports/ + Rolling 10-File Index) ===

function diagnostics:get_reports_dir()
    if proto.is_android() then
        return REPORTS_DIR_NAME
    end
    return proto.path_join(proto.get_writable_dir(), REPORTS_DIR_NAME)
end

local function write_report_file(rel_or_abs, bytes)
    if proto.is_android() then
        local FS = love and love.filesystem
        if not FS or not FS.write then return false, "no_love_fs" end
        pcall(FS.createDirectory, REPORTS_DIR_NAME)
        local ok, err = FS.write(rel_or_abs, bytes)
        return ok == true, err
    end
    local dir = rel_or_abs:match("^(.*)[/\\][^/\\]+$")
    if dir and #dir > 0 then win_util.ensure_dir(dir) end
    return win_util.write_file_utf8(rel_or_abs, bytes)
end

local function read_report_file(rel_or_abs)
    if proto.is_android() then
        local FS = love and love.filesystem
        if not FS or not FS.read then return nil end
        local ok, data = pcall(FS.read, rel_or_abs)
        if ok and type(data) == "string" then return data end
        return nil
    end
    local data = win_util.read_file_utf8(rel_or_abs)
    return data
end

local function delete_report_file(rel_or_abs)
    if proto.is_android() then
        local FS = love and love.filesystem
        if FS and FS.remove then pcall(FS.remove, rel_or_abs) end
        return
    end
    win_util.delete_file_utf8(rel_or_abs)
end

local function join_report_path(fname)
    if proto.is_android() then
        return REPORTS_DIR_NAME .. "/" .. fname
    end
    return proto.path_join(diagnostics:get_reports_dir(), fname)
end

function diagnostics:_update_rolling_index(new_fname)
    local idx_path = join_report_path(INDEX_FILE_NAME)
    local raw = read_report_file(idx_path)
    local list = {}
    if raw and #raw > 0 then
        local dec = proto.decode(raw)
        if type(dec) == "table" then
            for i = 1, #dec do
                if type(dec[i]) == "string" and dec[i] ~= new_fname then
                    list[#list + 1] = dec[i]
                end
            end
        end
    end
    list[#list + 1] = new_fname
    while #list > MAX_ARCHIVED_REPORTS do
        local old_name = table.remove(list, 1)
        if type(old_name) == "string" and #old_name > 0 then
            delete_report_file(join_report_path(old_name))
        end
    end
    write_report_file(idx_path, proto.encode(list))
end

-- === Lifecycle & Event Recorders ===

function diagnostics:init(boot, overlay)
    self.boot = boot
    self.overlay = overlay
    self.log_ring = ring_new(MAX_LOG_LINES)
    self.active_match = nil
    self.last_match = nil
    self.last_crash = nil
    self.prev_issue_fname = nil
    self.has_unread_issue = false
    self.last_export_path = nil
    self._manifest_cache = nil
    self:_reset_upload_state()

    -- Detect if previous run ended with an auto-saved crash or desync report so restarting doesn't lose it
    local raw_idx = read_report_file(join_report_path(INDEX_FILE_NAME))
    if raw_idx and #raw_idx > 0 then
        local list = proto.decode(raw_idx)
        if type(list) == "table" and #list > 0 then
            local newest = list[#list]
            if type(newest) == "string" and (newest:match("^crash_") or newest:match("^desync_")) then
                self.prev_issue_fname = newest
            end
        end
    end
    return self
end

function diagnostics:record_log(line)
    if type(line) ~= "string" then return end
    if not self.log_ring or not self.log_ring.cap then
        self.log_ring = ring_new(MAX_LOG_LINES)
    end
    ring_push(self.log_ring, line)
end

function diagnostics:on_match_start(local_pid, cfg, is_reconnect, net_mode)
    self.active_match = {
        started_at = os.date("%Y-%m-%d %H:%M:%S"),
        pid = tonumber(local_pid) or 1,
        net_mode = tostring(net_mode or "lan"),
        is_reconnect = (is_reconnect == true),
        cfg = deep_copy(cfg or {}),
        recent_cmds = ring_new(MAX_RECENT_CMDS),
        recent_hashes = ring_new(MAX_RECENT_HASHES),
        last_tick = 0,
        last_hash = "--------",
        sync_ok_count = 0,
        desync = nil,
        turns = nil,
        target_turn = 0,
        auto_report_fname = nil,
    }
end

function diagnostics:mark_reconnect(is_reconnect)
    if self.active_match then
        self.active_match.is_reconnect = (is_reconnect == true)
    end
end

function diagnostics:on_command_exec(tick, cmd)
    local m = self.active_match
    if not m or type(cmd) ~= "table" then return end
    local rec = {
        t = tonumber(tick) or 0,
        p = tonumber(cmd.player) or 0,
        op = tostring(cmd.op or "?"),
    }
    if cmd.id ~= nil then rec.id = cmd.id end
    if cmd.arg ~= nil then rec.arg = cmd.arg end
    if cmd.idx ~= nil then rec.idx = cmd.idx end
    if cmd.wx ~= nil then rec.wx = cmd.wx end
    if cmd.wy ~= nil then rec.wy = cmd.wy end
    if cmd.amount ~= nil then rec.amt = cmd.amount end
    if cmd.delay ~= nil then rec.d = cmd.delay end
    ring_push(m.recent_cmds, rec)
end

function diagnostics:on_hash_checkpoint(snap, formatted_line)
    local m = self.active_match
    if not m then return end
    if type(snap) == "table" then
        m.last_tick = tonumber(snap.tick) or m.last_tick
        m.last_hash = tostring(snap.hash or m.last_hash)
    end
    if type(formatted_line) == "string" and #formatted_line > 0 then
        ring_push(m.recent_hashes, formatted_line)
    end
end

local function extract_sorted_turns(lockstep_ref)
    if not lockstep_ref or type(lockstep_ref.history_nonempty) ~= "table" then
        return {}, 0
    end
    local keys = {}
    for tid in pairs(lockstep_ref.history_nonempty) do
        if type(tid) == "number" and tid >= 0 then
            keys[#keys + 1] = tid
        end
    end
    table.sort(keys)
    local turns = {}
    for i = 1, #keys do
        local tid = keys[i]
        local h = lockstep_ref.history_nonempty[tid]
        if h then
            turns[#turns + 1] = {
                turn = tid,
                c1 = deep_copy(h.c1 or {}),
                c2 = deep_copy(h.c2 or {}),
            }
        end
    end
    local target_turn = tonumber(lockstep_ref.highest_complete_turn) or 0
    if #keys > 0 and keys[#keys] > target_turn then
        target_turn = keys[#keys]
    end
    return turns, target_turn
end

function diagnostics:on_match_end(phase, lockstep_ref)
    local m = self.active_match
    if not m then return end
    m.ended_at = os.date("%Y-%m-%d %H:%M:%S")
    m.end_phase = tostring(phase or "ENDED")
    if lockstep_ref then
        m.sync_ok_count = tonumber(lockstep_ref.sync_ok_count) or m.sync_ok_count
        m.turns, m.target_turn = extract_sorted_turns(lockstep_ref)
        m.hot_resumes = tonumber(lockstep_ref.hot_resume_count) or 0
        m.cold_reconnects = tonumber(lockstep_ref.cold_reconnect_count) or 0
        m.delay_turns = tonumber(lockstep_ref.input_delay_turns) or 2
    end
    self.last_match = m
    self.active_match = nil
end

function diagnostics:on_desync(info, lockstep_ref)
    local m = self.active_match or self.last_match
    if not m then return nil end
    local d = m.desync or {}
    if type(info) == "table" then
        if info.tick then d.tick = tonumber(info.tick) or d.tick end
        if info.local_hash then d.local_hash = tostring(info.local_hash) end
        if info.remote_hash then d.remote_hash = tostring(info.remote_hash) end
        if info.local_snap and info.local_snap ~= "" then d.local_snap = tostring(info.local_snap) end
        if info.remote_snap and info.remote_snap ~= "" then d.remote_snap = tostring(info.remote_snap) end
        if info.local_ents and info.local_ents ~= "" then d.local_ents = tostring(info.local_ents) end
        if info.remote_ents and info.remote_ents ~= "" then d.remote_ents = tostring(info.remote_ents) end
        if info.detected_by and not d.detected_by then d.detected_by = tostring(info.detected_by) end
    end
    m.desync = d
    self.has_unread_issue = true

    if not m.auto_report_fname then
        local lvl = tonumber(m.cfg and m.cfg.level_idx) or 0
        local tk = tonumber(d.tick) or m.last_tick or 0
        m.auto_report_fname = string.format("desync_%s_L%d_T%d.json", os.date("%Y%m%d_%H%M%S"), lvl, tk)
    end
    -- Auto-save (and automatically enrich when peer DESYNC_DIAG arrives ~30ms later!)
    local report = self:build_report("desync", { lockstep = lockstep_ref })
    local path = join_report_path(m.auto_report_fname)
    local ok_w = write_report_file(path, proto.encode(report))
    if ok_w then
        self:_update_rolling_index(m.auto_report_fname)
        self.last_export_path = path
    end
    return ok_w and path or nil
end

-- === Manifest SHA-256 Integrity Verification ===

local function read_installed_client_file(rel)
    if proto.is_android() then
        if love and love.filesystem and love.filesystem.read then
            local ok, data = pcall(love.filesystem.read, rel)
            if ok and type(data) == "string" then return data end
        end
        return nil
    end
    local full = proto.path_join(proto.get_writable_dir(), rel:gsub("/", "\\"))
    local data = win_util.read_file_utf8(full)
    if data then return data end
    if love and love.filesystem and love.filesystem.read then
        local ok, d2 = pcall(love.filesystem.read, rel)
        if ok and type(d2) == "string" then return d2 end
    end
    return nil
end

function diagnostics:check_manifest(force)
    if self._manifest_cache and not force then
        return self._manifest_cache
    end
    local raw = read_installed_client_file("kr_mp/manifest.json")
    if not raw or #raw == 0 then
        self._manifest_cache = { status = "no_manifest", ok_count = 0, modified = {}, missing = {} }
        return self._manifest_cache
    end
    local mf = proto.decode(raw)
    if type(mf) ~= "table" or type(mf.files) ~= "table" then
        self._manifest_cache = { status = "bad_manifest", ok_count = 0, modified = {}, missing = {} }
        return self._manifest_cache
    end
    local ok_u, updater = pcall(require, "kr_mp.updater")
    local sha256_fn = (ok_u and updater and updater.sha256_hex) or nil
    local ok_cnt, modified, missing = 0, {}, {}
    local rels = {}
    for rel in pairs(mf.files) do rels[#rels + 1] = tostring(rel) end
    table.sort(rels)
    for i = 1, #rels do
        local rel = rels[i]
        local expected = tostring(mf.files[rel] or ""):upper()
        local bytes = read_installed_client_file(rel)
        if not bytes then
            missing[#missing + 1] = rel
        elseif sha256_fn then
            local actual = sha256_fn(bytes)
            if actual == expected then
                ok_cnt = ok_cnt + 1
            else
                modified[#modified + 1] = rel .. "(" .. actual:sub(1, 10) .. ")"
            end
        else
            ok_cnt = ok_cnt + 1
        end
    end
    local st = (#modified == 0 and #missing == 0) and "clean" or "modified"
    self._manifest_cache = {
        status = st,
        manifest_version = tostring(mf.version or "?"),
        ok_count = ok_cnt,
        modified = modified,
        missing = missing,
    }
    return self._manifest_cache
end

-- === Structured Report Builder ("kr-mp-report-v1") ===

function diagnostics:build_report(reason, extra)
    extra = extra or {}
    local secrets = self:_collect_secrets()
    local b = self.boot
    local ls = extra.lockstep or (b and b.lockstep)
    local tr = b and b.transport

    local os_name = (love and love.system and love.system.getOS and love.system.getOS()) or "unknown"
    local lv_str = "?"
    if love and love.getVersion then
        local maj, min, rev = love.getVersion()
        lv_str = string.format("%s.%s.%s", tostring(maj), tostring(min), tostring(rev))
    end
    local sw, sh = 0, 0
    if love and love.graphics and love.graphics.getWidth then
        sw = love.graphics.getWidth() or 0
        sh = love.graphics.getHeight() or 0
    end

    local raw_logs = ring_to_list(self.log_ring, MAX_LOG_LINES)
    local safe_logs = {}
    for i = 1, #raw_logs do
        safe_logs[i] = diagnostics.sanitize_text(raw_logs[i], secrets)
    end

    local report = {
        format = REPORT_FORMAT,
        created_at = os.date("%Y-%m-%d %H:%M:%S"),
        reason = tostring(reason or "manual"),
        env = {
            mod_version = proto.MOD_VERSION,
            protocol_ver = proto.PROTOCOL_VER,
            fl_version = tostring(KR_FL_VERSION or "8.2.0"),
            script_hash = (b and b.script_hash) or proto.compute_script_hash(),
            os = os_name,
            love_version = lv_str,
            screen_w = sw,
            screen_h = sh,
            is_android = proto.is_android(),
        },
        integrity = self:check_manifest(false),
        network = {
            mode = (tr and tr:is_online()) and "online" or ((b and b.lobby and b.lobby.net_tab) or "lan"),
            rtt_ms = (tr and tr.get_rtt_ms and tr:get_rtt_ms()) or 0,
            delay_turns = (ls and ls.input_delay_turns) or 2,
            hot_resumes = (ls and ls.hot_resume_count) or 0,
            cold_reconnects = (ls and ls.cold_reconnect_count) or 0,
        },
        logs = safe_logs,
    }

    local crash_tb = extra.traceback or self.last_crash
    if type(crash_tb) == "string" and #crash_tb > 0 then
        report.crash = {
            traceback = diagnostics.sanitize_text(crash_tb, secrets),
        }
    end

    local m = self.active_match or self.last_match
    if m then
        local cfg = m.cfg or {}
        local lvl = tonumber(cfg.level_idx) or 0
        local h1 = cfg.heroes and cfg.heroes[1] or 0
        local h2 = cfg.heroes and cfg.heroes[2] or 0
        local turns, target_turn
        if m == self.active_match and ls and ls.active then
            turns, target_turn = extract_sorted_turns(ls)
        else
            turns = m.turns or {}
            target_turn = m.target_turn or 0
        end
        report.match = {
            pid = m.pid,
            net_mode = m.net_mode,
            started_at = m.started_at,
            ended_at = m.ended_at,
            end_phase = m.end_phase or (ls and ls.phase) or nil,
            is_reconnect = m.is_reconnect,
            level_idx = lvl,
            level_name = (lvl > 0 and catalog.get_stage_label) and catalog.get_stage_label(lvl) or tostring(lvl),
            level_mode = tonumber(cfg.level_mode) or 1,
            difficulty = tonumber(cfg.level_difficulty) or 2,
            seed = tonumber(cfg.seed) or 0,
            heroes = { h1, h2 },
            hero_names = {
                (h1 > 0 and catalog.get_hero_label) and catalog.get_hero_label(h1) or tostring(h1),
                (h2 > 0 and catalog.get_hero_label) and catalog.get_hero_label(h2) or tostring(h2),
            },
            econ_mode = tostring(cfg.econ_mode or "independent"),
            tower_mode = tostring(cfg.tower_mode or "owned"),
            last_tick = m.last_tick,
            last_hash = m.last_hash,
            sync_ok_count = (m == self.active_match and ls and ls.sync_ok_count) or m.sync_ok_count or 0,
            desync = m.desync and deep_copy(m.desync) or nil,
            recent_cmds = ring_to_list(m.recent_cmds, MAX_RECENT_CMDS),
            recent_hashes = ring_to_list(m.recent_hashes, MAX_RECENT_HASHES),
        }
        if next(cfg) ~= nil then
            report.blackbox = {
                version = 1,
                cfg = deep_copy(cfg),
                target_turn = target_turn,
                turn_count = #turns,
                turns = turns,
            }
        end
    end

    return report
end

-- === Plain-Text Clipboard Summary (Great for Chat / Android Copy-Paste) ===

function diagnostics:build_clipboard_summary(report, saved_path)
    local env = report.env or {}
    local integ = report.integrity or {}
    local m = report.match
    local lines = {
        string.format("【KR-MP 报错诊断摘要】v%s (FL %s · %s · %dx%d · hash=%s)",
            tostring(env.mod_version), tostring(env.fl_version), tostring(env.os),
            tonumber(env.screen_w) or 0, tonumber(env.screen_h) or 0, tostring(env.script_hash)),
        string.format("时间：%s | 触发：%s | 文件校验：%s (正常 %d，改动 %d，缺失 %d)",
            tostring(report.created_at), tostring(report.reason), tostring(integ.status or "?"),
            tonumber(integ.ok_count) or 0, #(integ.modified or {}), #(integ.missing or {})),
    }
    if integ.modified and #integ.modified > 0 then
        lines[#lines + 1] = "本地改动文件：" .. table.concat(integ.modified, ", ")
    end
    if m then
        lines[#lines + 1] = string.format("对局：%dP | 关卡 %s | 难度 %d | 英雄 %s & %s | 帧 %d (校验√%d)",
            tonumber(m.pid) or 1, tostring(m.level_name), tonumber(m.difficulty) or 2,
            tostring(m.hero_names and m.hero_names[1] or "?"),
            tostring(m.hero_names and m.hero_names[2] or "?"),
            tonumber(m.last_tick) or 0, tonumber(m.sync_ok_count) or 0)
        if m.desync then
            local d = m.desync
            lines[#lines + 1] = string.format("DESYNC @ 第 %s 帧 | local=%s remote=%s",
                tostring(d.tick or "?"), tostring(d.local_hash or "?"), tostring(d.remote_hash or "?"))
            if d.local_snap then lines[#lines + 1] = "LOCAL  SNAP: " .. d.local_snap end
            if d.remote_snap then lines[#lines + 1] = "REMOTE SNAP: " .. d.remote_snap end
            if d.local_ents then lines[#lines + 1] = "LOCAL  ENTS: " .. d.local_ents end
            if d.remote_ents then lines[#lines + 1] = "REMOTE ENTS: " .. d.remote_ents end
        end
    end
    if report.crash and report.crash.traceback then
        lines[#lines + 1] = "--- LUA CRASH ---"
        lines[#lines + 1] = report.crash.traceback
    end
    if saved_path and #saved_path > 0 then
        lines[#lines + 1] = "完整黑匣子报告文件：" .. diagnostics.sanitize_text(saved_path, self:_collect_secrets())
    end
    -- On Android, append last 25 log lines directly into clipboard so tester can paste straight into group chat
    if env.is_android and type(report.logs) == "table" and #report.logs > 0 then
        lines[#lines + 1] = "--- 最近日志 ---"
        local start_i = math.max(1, #report.logs - 24)
        for i = start_i, #report.logs do
            lines[#lines + 1] = report.logs[i]
        end
    end
    return table.concat(lines, "\n")
end

-- === Crash Handler & One-Click Player Export ===

function diagnostics:on_crash(traceback_str)
    self.last_crash = tostring(traceback_str or "")
    self.has_unread_issue = true
    local fname = string.format("crash_%s.json", os.date("%Y%m%d_%H%M%S"))
    local ok_b, report = pcall(self.build_report, self, "crash", { traceback = self.last_crash })
    if not ok_b or type(report) ~= "table" then
        return nil, ""
    end
    local path = join_report_path(fname)
    local ok_w = write_report_file(path, proto.encode(report))
    if ok_w then
        pcall(self._update_rolling_index, self, fname)
        self.last_export_path = path
    end
    -- Also try copying concise summary to clipboard so player can paste right away
    if love and love.system and love.system.setClipboardText then
        pcall(love.system.setClipboardText, self:build_clipboard_summary(report, ok_w and path or nil))
    end
    local disp_path = ok_w and (proto.is_android() and (proto.get_writable_dir() .. "/" .. path) or path) or "kr_mp.log"
    local banner = string.format(
        "【KR-MP 崩溃已自动保存黑匣子报告】\n文件位置: %s\n(核心摘要已自动复制到剪贴板，可直接粘贴发群里；重启后点大厅右上角「导出报错」也能一键提取)\n\n",
        disp_path
    )
    return ok_w and path or nil, banner
end

function diagnostics:export_user_report(reason)
    local reason_tag = tostring(reason or "manual")
    local stamp = os.date("%Y%m%d_%H%M%S")
    local report, json_bytes, archive_name, archive_path, lvl_tag, tick_tag, reused_prev

    -- If player just restarted after a crash/desync and clicks "导出报错" before starting a new match,
    -- automatically export that preserved crash/desync report instead of an empty lobby log!
    if not self.active_match and not self.last_match and not self.last_crash and self.prev_issue_fname then
        local prev_path = join_report_path(self.prev_issue_fname)
        local prev_raw = read_report_file(prev_path)
        local prev_doc = prev_raw and proto.decode(prev_raw) or nil
        if type(prev_doc) == "table" and prev_doc.format == REPORT_FORMAT then
            report = prev_doc
            json_bytes = prev_raw
            archive_name = self.prev_issue_fname
            archive_path = prev_path
            reused_prev = true
            local pm = prev_doc.match
            lvl_tag = (pm and tonumber(pm.level_idx) and pm.level_idx > 0) and ("L" .. tostring(pm.level_idx)) or "PrevCrash"
            tick_tag = (pm and pm.desync and pm.desync.tick) and ("T" .. tostring(pm.desync.tick))
                or ((pm and tonumber(pm.last_tick) and pm.last_tick > 0) and ("T" .. tostring(pm.last_tick)) or "Crash")
        end
    end

    if not reused_prev then
        report = self:build_report(reason_tag)
        local m = report.match
        lvl_tag = (m and tonumber(m.level_idx) and m.level_idx > 0) and ("L" .. tostring(m.level_idx)) or "Lobby"
        tick_tag = (m and m.desync and m.desync.tick) and ("T" .. tostring(m.desync.tick))
            or ((m and tonumber(m.last_tick) and m.last_tick > 0) and ("T" .. tostring(m.last_tick)) or "0")

        archive_name = string.format("report_%s_%s_%s.json", stamp, lvl_tag, tick_tag)
        archive_path = join_report_path(archive_name)
        json_bytes = proto.encode(report)
        local ok_arc = write_report_file(archive_path, json_bytes)
        if ok_arc then
            self:_update_rolling_index(archive_name)
        end
    end

    local exported_path = archive_path
    local on_desktop = false
    if not proto.is_android() and win_util.is_windows() then
        local desk = win_util.get_desktop_dir()
        local friendly = string.format("KR-MP报错_%s_%s_%s.json", lvl_tag, tick_tag, stamp)
        if desk then
            local desk_path = desk .. "\\" .. friendly
            local ok_d = win_util.write_file_utf8(desk_path, json_bytes)
            if ok_d then
                exported_path = desk_path
                on_desktop = true
            end
        end
        win_util.reveal_in_explorer(exported_path)
    end

    self.last_export_path = exported_path
    self.has_unread_issue = false
    if reused_prev then
        self.prev_issue_fname = nil
    end

    local clip_ok = false
    if love and love.system and love.system.setClipboardText then
        clip_ok = pcall(love.system.setClipboardText, self:build_clipboard_summary(report, exported_path))
    end

    if self.boot then
        self.boot:log("[DIAG] Exported bug report (%s, reused_prev=%s, bytes=%d) -> %s",
            reason_tag, tostring(reused_prev == true), #json_bytes, exported_path)
    end

    local ov = self.overlay or (self.boot and self.boot.overlay)
    if ov and ov.show_toast then
        local prefix = reused_prev and "已提取上次崩溃/异常黑匣子" or "报错黑匣子已保存"
        if proto.is_android() then
            ov:show_toast(clip_ok
                and (prefix .. "并复制诊断摘要到剪贴板！直接去群里粘贴发给作者即可 √")
                or (prefix .. "至存档目录：" .. archive_path), 5.5)
        elseif on_desktop then
            ov:show_toast(prefix .. "到桌面并打开目录！直接把选中的 .json 文件拖进群里即可 √", 5.5)
        else
            ov:show_toast(prefix .. "并打开目录！把选中的 .json 文件发给作者即可（摘要已复制）√", 5.5)
        end
    end
    return true, exported_path
end

function diagnostics:_resolve_or_build_report(reason_tag, archive_if_new)
    if not self.active_match and not self.last_match and not self.last_crash and self.prev_issue_fname then
        local prev_path = join_report_path(self.prev_issue_fname)
        local prev_raw = read_report_file(prev_path)
        local prev_doc = prev_raw and proto.decode(prev_raw) or nil
        if type(prev_doc) == "table" and prev_doc.format == REPORT_FORMAT then
            return prev_doc, true, prev_raw, self.prev_issue_fname, prev_path
        end
    end
    local report = self:build_report(reason_tag)
    local json_bytes = proto.encode(report)
    local archive_name, archive_path = nil, nil
    if archive_if_new then
        local m = report.match
        local lvl_tag = (m and tonumber(m.level_idx) and m.level_idx > 0) and ("L" .. tostring(m.level_idx)) or "Lobby"
        local tick_tag = (m and m.desync and m.desync.tick) and ("T" .. tostring(m.desync.tick))
            or ((m and tonumber(m.last_tick) and m.last_tick > 0) and ("T" .. tostring(m.last_tick)) or "0")
        archive_name = string.format("report_%s_%s_%s.json", os.date("%Y%m%d_%H%M%S"), lvl_tag, tick_tag)
        archive_path = join_report_path(archive_name)
        if write_report_file(archive_path, json_bytes) then
            self:_update_rolling_index(archive_name)
        end
    end
    return report, false, json_bytes, archive_name, archive_path
end

function diagnostics:_reset_upload_state() return cloud.reset(self) end
function diagnostics:sync_modal_defaults(lobby) return cloud.sync_modal_defaults(self, lobby) end
function diagnostics:get_preview_summary() return cloud.get_preview_summary(self) end
function diagnostics:build_ticket_clipboard_text(code, meta) return cloud.build_ticket_clipboard_text(code, meta) end
function diagnostics:on_cloud_upload_ok(msg) return cloud.on_ok(self, msg) end
function diagnostics:on_cloud_upload_err(err_msg) return cloud.on_err(self, err_msg) end
function diagnostics:copy_last_ticket() return cloud.copy_last_ticket(self) end
function diagnostics:start_cloud_upload(lobby, server_addr_override, note_override, reason)
    return cloud.start(self, lobby, server_addr_override, note_override, reason)
end
function diagnostics:update(dt) return cloud.update(self, dt) end
function diagnostics:shutdown() return cloud.close_temp(self) end

-- === Developer Offline Black-Box Parser ===

function diagnostics.parse_report_for_replay(json_str)
    if type(json_str) ~= "string" or #json_str == 0 then
        return nil, nil, "empty_report"
    end
    local doc, err = proto.decode(json_str)
    if not doc or type(doc) ~= "table" then
        return nil, nil, "decode_failed: " .. tostring(err)
    end
    local bb = doc.blackbox
    if type(bb) ~= "table" or type(bb.cfg) ~= "table" then
        return nil, doc, "missing_blackbox_cfg"
    end
    if type(bb.turns) ~= "table" then
        bb.turns = {}
    end
    return bb, doc, nil
end

return diagnostics
