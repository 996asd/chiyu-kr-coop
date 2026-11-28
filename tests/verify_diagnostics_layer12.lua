local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Unit test suite for KR-MP Layer 1 + Layer 2 Diagnostics, Black-Box & UTF-8 Win32 I/O
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local pass, fail = 0, 0
local function check(cond, name)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print("FAIL: " .. tostring(name))
    end
end

-- Minimal LÖVE stubs pointing writable dir at a clean temp directory
local tmp_root = _KR_TMP .. "/diag_unit_tmp"
local copied_clipboard = nil
local last_toast = nil

_G.KR_FL_VERSION = "8.2.0"
_G.TICK_LENGTH = 1 / 60
_G.love = {
    getVersion = function() return 11, 5, 0 end,
    system = {
        getOS = function() return "Windows" end,
        setClipboardText = function(t) copied_clipboard = t end,
    },
    graphics = {
        getWidth = function() return 1280 end,
        getHeight = function() return 720 end,
    },
    filesystem = {
        getSourceBaseDirectory = function() return tmp_root end,
        getSaveDirectory = function() return tmp_root end,
        read = function() return nil end,
    },
    timer = { getTime = function() return 100.0 end },
}

local proto = require("kr_mp.proto")
local win_util = require("kr_mp.win_util")
local diagnostics = require("kr_mp.diagnostics")

-- Clean up temp dir before test
os.execute('powershell -NoProfile -Command "if (Test-Path \'' .. tmp_root .. '\') { Remove-Item -Recurse -Force \'' .. tmp_root .. '\' }"')
check(win_util.ensure_dir(tmp_root), "win_util.ensure_dir creates temp root")
check(win_util.dir_exists(tmp_root), "win_util.dir_exists detects created dir")

-- 1. UTF-8 Chinese path Win32 read/write/delete test
local cn_dir = tmp_root .. "\\中文目录_测试"
check(win_util.ensure_dir(cn_dir), "win_util.ensure_dir supports Chinese UTF-8 folder")
local cn_file = cn_dir .. "\\报错黑匣子_测试.json"
local cn_payload = '{"msg":"你好世界-UTF8-测试","ok":true}\n'
local ok_w, werr = win_util.write_file_utf8(cn_file, cn_payload)
check(ok_w and not werr, "win_util.write_file_utf8 writes Chinese filename")
local read_back = win_util.read_file_utf8(cn_file)
check(read_back == cn_payload, "win_util.read_file_utf8 reads back identical bytes")
check(win_util.delete_file_utf8(cn_file), "win_util.delete_file_utf8 deletes Chinese file")
check(win_util.read_file_utf8(cn_file) == nil, "deleted Chinese file no longer exists")

-- 2. Privacy auto-sanitization test
local raw_secret_line = 'Path=C:\\Users\\ZhangSan\\Desktop\\game.exe token="sakura_secret_987654321" host=frp-ski.com:54321 alt=abc12.nyat.app:33211 pub=114.22.33.44 lan=192.168.1.8 loc=127.0.0.1 pubdir=C:\\Users\\Public\\KR_MP_Bin\0\7end'
local clean_line = diagnostics.sanitize_text(raw_secret_line, { "sakura_secret_987654321" })
check(not clean_line:find("ZhangSan", 1, true), "masks Windows username in path")
check(clean_line:find("C:\\Users\\***\\Desktop", 1, true) ~= nil, "keeps masked path structure")
check(clean_line:find("C:\\Users\\Public\\KR_MP_Bin", 1, true) ~= nil, "preserves Public dir")
check(not clean_line:find("sakura_secret_987654321", 1, true), "redacts extra secret token")
check(not clean_line:find("frp-ski.com:54321", 1, true), "masks SakuraFrp host:port")
check(not clean_line:find("abc12.nyat.app:33211", 1, true), "masks nyat.app host:port")
check(not clean_line:find("114.22.33.44", 1, true), "masks public IPv4")
check(clean_line:find("114.*.*.44", 1, true) ~= nil, "keeps partial public IPv4 mask")
check(clean_line:find("192.168.1.8", 1, true) ~= nil, "preserves LAN 192.168 IPv4")
check(clean_line:find("127.0.0.1", 1, true) ~= nil, "preserves loopback 127.0.0.1")
check(not clean_line:find("[%z\7]"), "strips ASCII control bytes for RFC8259 JSON")

-- 3. Diagnostics lifecycle: ring buffer, match black-box, command ring, DESYNC merge + rolling archive
local mock_overlay = { show_toast = function(_, msg) last_toast = msg end }
local mock_boot = {
    script_hash = "CAFEBABE",
    sakura = { token = "my_private_sakura_tok_xyz" },
    transport = { is_online = function() return true end, get_rtt_ms = function() return 32 end },
    lobby = { net_tab = "online" },
    log = function() end,
}
diagnostics:init(mock_boot, mock_overlay)

for i = 1, 450 do
    diagnostics:record_log(string.format("[12:00:00][KR-MP] log line #%d token=my_private_sakura_tok_xyz", i))
end

local sample_cfg = {
    level_idx = 37,
    level_mode = 1,
    level_difficulty = 3,
    seed = 778899,
    turn_ticks = 3,
    input_delay_turns = 2,
    econ_mode = "independent",
    tower_mode = "owned",
    heroes = { [1] = 53, [2] = 54 },
    towers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    slot_snapshot = { towers = { 1, 2, 3 }, liuhui = { cheat = false } },
}
local mock_ls = {
    active = true,
    phase = "RUNNING",
    sync_ok_count = 40,
    input_delay_turns = 2,
    hot_resume_count = 1,
    cold_reconnect_count = 0,
    highest_complete_turn = 400,
    history_nonempty = {
        [6] = { c1 = { { op = "TW_UPGRADE", id = 12, arg = "tower_arcane", player = 1 } }, c2 = {} },
        [15] = { c1 = {}, c2 = { { op = "HERO_RALLY", id = 88, wx = 512.25, wy = 320.5, player = 2 } } },
    },
}
mock_boot.lockstep = mock_ls

diagnostics:on_match_start(1, sample_cfg, false, "online")
diagnostics:on_command_exec(19, { player = 1, op = "TW_UPGRADE", id = 12, arg = "tower_arcane" })
diagnostics:on_command_exec(46, { player = 2, op = "HERO_RALLY", id = 88, wx = 512.25, wy = 320.5 })
diagnostics:on_hash_checkpoint({ tick = 1170, hash = "11223344" }, "tick=1170 hash=11223344 gold=500 lives=20")
diagnostics:on_hash_checkpoint({ tick = 1200, hash = "AABBCCDD" }, "tick=1200 hash=AABBCCDD gold=520 lives=20")

-- Step A: Local DESYNC detected -> auto-saves file
local desync_path1 = diagnostics:on_desync({
    tick = 1200,
    local_hash = "AABBCCDD",
    remote_hash = "EEFF0011",
    local_snap = "tick=1200 hash=AABBCCDD",
    remote_snap = "tick=1200 hash=EEFF0011",
    local_ents = "t=1200 | E[#10:orc(100,200,hp=50)]",
    detected_by = "local",
}, mock_ls)
check(desync_path1 ~= nil and win_util.read_file_utf8(desync_path1) ~= nil, "DESYNC auto-saves report JSON")
check(diagnostics.has_unread_issue == true, "DESYNC marks has_unread_issue=true")

-- Step B: Peer DESYNC_DIAG arrives 30ms later -> enriches SAME file with remote_ents!
local desync_path2 = diagnostics:on_desync({
    tick = 1200,
    remote_ents = "t=1200 | E[#10:orc(100,200,hp=40)]",
}, mock_ls)
check(desync_path2 == desync_path1, "Peer DESYNC_DIAG updates the exact same auto-saved report file")

local raw_desync = win_util.read_file_utf8(desync_path1)
local bb, doc, perr = diagnostics.parse_report_for_replay(raw_desync)
check(perr == nil and bb ~= nil and doc ~= nil, "parse_report_for_replay decodes saved report cleanly")
check(doc.format == "kr-mp-report-v1", "report format version matches kr-mp-report-v1")
check(#doc.logs == 400, "log ring caps strictly at 400 lines")
check(doc.logs[1]:find("log line #51", 1, true) ~= nil, "log ring keeps newest 400 lines (#51..#450)")
check(not raw_desync:find("my_private_sakura_tok_xyz", 1, true), "saved JSON never leaks sakura token")
check(doc.match.desync.local_ents:find("hp=50", 1, true) ~= nil, "saved report retains local_ents")
check(doc.match.desync.remote_ents:find("hp=40", 1, true) ~= nil, "saved report enriched with remote_ents")
check(#doc.match.recent_cmds == 2, "records both P1 and P2 commands with args")
check(doc.match.recent_cmds[1].arg == "tower_arcane", "P1 command arg preserved")
check(doc.match.recent_cmds[2].p == 2 and doc.match.recent_cmds[2].wx == 512.25, "P2 command coords preserved")
check(bb.cfg.level_idx == 37 and bb.cfg.seed == 778899, "blackbox preserves level_idx & seed")
check(#bb.turns == 2 and bb.turns[1].turn == 6 and bb.turns[2].turn == 15, "blackbox preserves sorted turn stream")
check(bb.target_turn == 400, "blackbox preserves target_turn")

-- 4. Match end freezes last_match so returning to lobby still exports the full black-box
diagnostics:on_match_end("DESYNC", mock_ls)
check(diagnostics.active_match == nil and diagnostics.last_match ~= nil, "on_match_end moves match to last_match")
local post_rep = diagnostics:build_report("manual")
check(post_rep.blackbox ~= nil and #post_rep.blackbox.turns == 2, "post-match report still carries full blackbox")

-- 5. Crash auto-save + previous-session recovery after restart!
local crash_path, crash_banner = diagnostics:on_crash("all/systems.lua:99: boom\nstack traceback: ...")
check(crash_path ~= nil and win_util.read_file_utf8(crash_path) ~= nil, "on_crash writes crash report")
check(crash_banner:find("KR-MP 崩溃已自动保存黑匣子报告", 1, true) ~= nil, "crash banner has friendly Chinese message")
check(copied_clipboard ~= nil and copied_clipboard:find("LUA CRASH", 1, true) ~= nil, "crash copies summary to clipboard")

-- Simulate full restart of game -> diagnostics:init should detect prev_issue_fname!
diagnostics:init(mock_boot, mock_overlay)
check(diagnostics.prev_issue_fname ~= nil and diagnostics.prev_issue_fname:match("^crash_") ~= nil,
    "restart detects previous crash report in _index.json")

-- 6. Rolling index prunes > 10 archived reports automatically
for i = 1, 13 do
    local fn = string.format("report_20261128_0000%02d.json", i)
    local p = proto.path_join(diagnostics:get_reports_dir(), fn)
    win_util.write_file_utf8(p, '{"i":' .. i .. '}\n')
    diagnostics:_update_rolling_index(fn)
end
local idx_raw = win_util.read_file_utf8(proto.path_join(diagnostics:get_reports_dir(), "_index.json"))
local idx_list = proto.decode(idx_raw)
check(type(idx_list) == "table" and #idx_list == 10, "rolling index retains strictly max 10 reports")
check(win_util.read_file_utf8(proto.path_join(diagnostics:get_reports_dir(), "report_20261128_000001.json")) == nil,
    "oldest archived report pruned from disk")
check(win_util.read_file_utf8(proto.path_join(diagnostics:get_reports_dir(), "report_20261128_000013.json")) ~= nil,
    "newest archived report retained on disk")

-- 7. Manifest SHA-256 verification against real client repo directory!
_G.love.filesystem.getSourceBaseDirectory = function() return _KR_REPO .. "/client" end
local mf_res = diagnostics:check_manifest(true)
check(mf_res.status == "clean" or mf_res.status == "modified", "check_manifest parses real manifest.json (" .. tostring(mf_res.status) .. ")")
check((mf_res.ok_count or 0) >= 20, "check_manifest verifies real SHA-256 hashes (ok=" .. tostring(mf_res.ok_count) .. ")")

-- 8. Clipboard summary on Android includes recent logs
local android_rep = diagnostics:build_report("manual")
android_rep.env.is_android = true
android_rep.logs = { "lineA", "lineB", "lineC" }
local android_clip = diagnostics:build_clipboard_summary(android_rep, "kr_mp_reports/test.json")
check(android_clip:find("最近日志", 1, true) ~= nil and android_clip:find("lineC", 1, true) ~= nil,
    "Android clipboard summary embeds tail logs for easy paste")

-- Cleanup temp dir
os.execute('powershell -NoProfile -Command "if (Test-Path \'' .. tmp_root .. '\') { Remove-Item -Recurse -Force \'' .. tmp_root .. '\' }"')

print(string.format("VERIFY_DIAGNOSTICS_LAYER12: PASS=%d FAIL=%d", pass, fail))
if fail > 0 then error("suite failed: " .. tostring(fail) .. " failures") end
