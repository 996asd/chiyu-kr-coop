local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Unit & Integration Verification Suite for Diagnostics Layer 3 (Cloud Upload & #R-XXXX Ticket Flow)
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local pass_cnt, fail_cnt = 0, 0
local function check(cond, label)
    if cond then
        pass_cnt = pass_cnt + 1
    else
        fail_cnt = fail_cnt + 1
        io.stderr:write("FAIL: " .. tostring(label) .. "\n")
    end
end

local clip_store = ""
local toasts = {}
local fake_clock = 100.0
_G.KR_FL_VERSION = "8.2.0"
_G.TICK_LENGTH = 1 / 60
_G.love = {
    timer = { getTime = function() return fake_clock end },
    system = {
        getOS = function() return "Windows" end,
        setClipboardText = function(s) clip_store = tostring(s or "") end,
        getClipboardText = function() return clip_store end,
    },
    getVersion = function() return 11, 4, 0 end,
    graphics = { getWidth = function() return 1280 end, getHeight = function() return 720 end },
    filesystem = { getSaveDirectory = function() return "D:\\FL8.2.0" end },
    keyboard = { isDown = function() return false end },
}

local proto = require("kr_mp.proto")
local diagnostics = require("kr_mp.diagnostics")
local diag_cloud = require("kr_mp.diagnostics_cloud")
local lobby_input = require("kr_mp.lobby_input")
local lobby_prefs = require("kr_mp.lobby_prefs")
local report_modal = require("kr_mp.lobby_draw_report")

-- Isolate reports directory into scratch temp folder so workspace stays spotless
local tmp_base = (_KR_TMP .. "/diag_l3_test"):gsub("/", "\\")
proto.get_writable_dir = function() return tmp_base end

local mock_overlay = {
    show_toast = function(_, msg) toasts[#toasts + 1] = tostring(msg) end,
    clear_toast = function() end,
}
local logs = {}
local mock_boot = {
    script_hash = "DEADBEEF",
    overlay = mock_overlay,
    sakura = { token = "sk_secret_token_987654321" },
    log = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end,
}

diagnostics:init(mock_boot, mock_overlay)
mock_boot.diagnostics = diagnostics

-- 1. Preview summary in lobby vs desync state
local p_lobby = diagnostics:get_preview_summary()
check(p_lobby.kind == "lobby" and p_lobby.urgent == false, "lobby preview summary kind=lobby")

diagnostics:on_match_start(1, { level_idx = 37, seed = 4242, heroes = { 53, 54 }, econ_mode = "independent", tower_mode = "owned" }, false, "online")
diagnostics:on_command_exec(900, { player = 1, op = "build", id = 5, arg = "tower_ranger" })
diagnostics:on_desync({ tick = 960, local_hash = "AAAA1111", remote_hash = "BBBB2222", local_snap = "g1=100", remote_snap = "g1=150" }, nil)

local p_desync = diagnostics:get_preview_summary()
check(p_desync.kind == "desync" and p_desync.urgent == true and p_desync.has_blackbox == true, "desync preview summary urgent=true")
check(p_desync.title:find("960", 1, true) ~= nil, "desync preview mentions tick 960")

-- 2. Upload budget trimmer (>480 KB report auto-trims logs & turns while preserving desync)
for i = 1, 400 do
    diagnostics:record_log(string.format("[12:00:00][KR-MP] %03d %s", i, string.rep("L", 1400)))
end
local prep_rep, prep_note, prep_meta = diag_cloud.prepare_upload_report(diagnostics, "desync", "我的密钥 sk_secret_token_987654321 和外网 8.8.8.8 报错")
local enc_len = #proto.encode(prep_rep)
check(enc_len <= 480 * 1024, "prepared upload report trimmed under 480KB (got " .. tostring(enc_len) .. ")")
check(#prep_rep.logs <= 120, "oversized logs trimmed to <=120 lines")
check(prep_rep.match and prep_rep.match.desync and prep_rep.match.desync.tick == 960, "desync snapshot preserved after trimming")
check(not prep_note:find("sk_secret_token_987654321", 1, true), "user note redacted Sakura token")
check(not prep_note:find("8.8.8.8", 1, true), "user note redacted external IPv4")
check(prep_meta.tick == 960, "meta captures desync tick 960")

-- 3. Path A: Active Online Socket Reuse — Old Server (report_ok=false) cleanly rejected
local sent_packets = {}
local mock_lobby = {
    boot = mock_boot,
    overlay = mock_overlay,
    open = true,
    view = "home",
    sub_modal = nil,
    focused_field = nil,
    server_input = "127.0.0.1:17780",
    server_connected = true,
    server_report_ok = false,
    transport = {
        is_online = function() return true end,
        is_connected = function() return true end,
        get_server_addr = function() return "127.0.0.1:17780" end,
        send = function(_, pkt) sent_packets[#sent_packets + 1] = pkt; return true end,
    },
    set_focus = function(self, f) self.focused_field = f end,
    paste_into_field = function(self, f) return lobby_prefs.paste_into_field(self, f) end,
}

local ok_old, err_old = diagnostics:start_cloud_upload(mock_lobby, nil, "测试", "test")
check(ok_old == false and err_old == "unsupported_server", "old server report_ok=false rejected cleanly")
check(diagnostics.upload.state == "error", "upload state becomes error on unsupported server")
check(#sent_packets == 0, "no BUG_REPORT sent to unsupported server")

-- 4. Path A: Active Online Socket Reuse — New Server (report_ok=true) sends BUG_REPORT & handles BUG_REPORT_OK
mock_lobby.server_report_ok = true
local ok_new, st_new = diagnostics:start_cloud_upload(mock_lobby, nil, "第37关测试", "lobby_modal")
check(ok_new == true and st_new == "sending", "active online upload started")
check(diagnostics.upload.via == "active" and diagnostics.upload.state == "sending", "via=active state=sending")
check(#sent_packets == 1 and sent_packets[1].t == "BUG_REPORT", "sent BUG_REPORT packet over active socket")
check(sent_packets[1].note == "第37关测试", "sent sanitized user note")
check(sent_packets[1].report and sent_packets[1].report.format == "kr-mp-report-v1", "sent kr-mp-report-v1 payload")

diagnostics:on_cloud_upload_ok({ t = "BUG_REPORT_OK", code = "R-7K9M", bytes = 12345 })
check(diagnostics.upload.state == "done" and diagnostics.upload.code == "R-7K9M", "upload state done with ticket R-7K9M")
check(diagnostics.has_unread_issue == false, "unread issue cleared after successful upload")
check(clip_store:find("#R-7K9M", 1, true) ~= nil, "ticket #R-7K9M auto-copied to clipboard")
check(clip_store:find("第37关测试", 1, true) ~= nil, "clipboard summary includes user note")

-- 5. Timeout protection when server never replies
diagnostics:start_cloud_upload(mock_lobby, nil, "timeout_test", "test")
check(diagnostics.upload.state == "sending", "second upload enters sending")
fake_clock = fake_clock + 13.0
diagnostics:update(0.1)
check(diagnostics.upload.state == "error", "upload times out cleanly after 12s")

-- 6. Lobby UI Input: export_report toggles modal, quick note toggles text, UTF-8 Chinese textinput & backspace
lobby_input.handle_button(mock_lobby, { id = "export_report" })
check(mock_lobby.sub_modal == "report", "export_report opens report sub_modal")
lobby_input.handle_button(mock_lobby, { id = "report_quick_note", note_text = report_modal.QUICK_NOTES[1].text })
check(diagnostics.upload.note == report_modal.QUICK_NOTES[1].text, "quick note preset fills upload.note")
lobby_input.handle_button(mock_lobby, { id = "report_note_box" })
check(mock_lobby.focused_field == "report_note", "clicking note box focuses report_note")
diagnostics.upload.note = "你好A"
lobby_input.textinput(mock_lobby, "世")
check(diagnostics.upload.note == "你好A世", "UTF-8 textinput appends Chinese character")
lobby_input.keypressed(mock_lobby, "backspace")
check(diagnostics.upload.note == "你好A", "UTF-8 backspace removes full 3-byte Chinese char cleanly")
lobby_input.keypressed(mock_lobby, "backspace")
check(diagnostics.upload.note == "你好", "backspace removes ASCII char cleanly")
lobby_input.keypressed(mock_lobby, "backspace")
check(diagnostics.upload.note == "你", "UTF-8 backspace removes second Chinese char cleanly")

-- Paste into report_server & report_note
clip_store = "frp-foo.com:17780\r\n"
lobby_prefs.paste_into_field(mock_lobby, "report_server")
check(diagnostics.upload.server_addr == "frp-foo.com:17780", "paste_into_field(report_server) sanitizes host:port")
clip_store = "第10关放火球闪退\n多行"
lobby_prefs.paste_into_field(mock_lobby, "report_note")
check(diagnostics.upload.note == "第10关放火球闪退 多行", "paste_into_field(report_note) strips control newlines")

-- 7. Path B: Isolated Temporary net_online State Machine (Never touches active Sakura/LAN transport!)
do
    local fake_sent = {}
    local fake_events = {}
    local fake_closed = false
    local fake_net_inst = {
        connect = function(self, host, port, silent)
            self._connected_host = host
            self._connected_port = port
            self._silent = silent
            return true, "connecting"
        end,
        send = function(_, msg)
            fake_sent[#fake_sent + 1] = msg
            return true
        end,
        poll = function()
            local out = fake_events
            fake_events = {}
            return out
        end,
        close = function()
            fake_closed = true
        end,
    }
    local saved_net_online = package.loaded["kr_mp.net_online"]
    local captured_dns_chan = nil
    package.loaded["kr_mp.net_online"] = {
        new = function(_, dns_ch)
            captured_dns_chan = dns_ch
            return fake_net_inst
        end,
    }

    local lan_lobby = {
        boot = mock_boot,
        overlay = mock_overlay,
        server_input = "198.51.100.10:17780",
        server_connected = false,
        server_report_ok = false,
        transport = {
            is_online = function() return false end,
            is_connected = function() return true end,
            close = function() error("MUST NOT TOUCH ACTIVE LAN/SAKURA TRANSPORT!") end,
        },
    }

    diagnostics:_reset_upload_state()
    local ok_b, st_b = diagnostics:start_cloud_upload(lan_lobby, "198.51.100.10:17780", "樱花房不断线上传", "sakura_room")
    check(ok_b == true and st_b == "connecting", "Path B starts isolated temporary net_online connection")
    check(captured_dns_chan == "kr_mp_report_dns", "Path B uses isolated DNS channel kr_mp_report_dns")
    check(diagnostics.upload.via == "temp", "Path B via=temp")

    -- Step 1: TCP connected -> sends HELLO
    fake_events = { { type = "server_connected" } }
    diagnostics:update(0.016)
    check(#fake_sent == 1 and fake_sent[1].t == "HELLO", "Path B sends HELLO upon server_connected")

    -- Step 2: SERVER_HELLO(report_ok=true) -> sends BUG_REPORT
    fake_events = { { type = "msg", msg = { t = "SERVER_HELLO", server_ver = "2.4.3", report_ok = true } } }
    diagnostics:update(0.016)
    check(#fake_sent == 2 and fake_sent[2].t == "BUG_REPORT", "Path B sends BUG_REPORT after SERVER_HELLO(report_ok=true)")
    check(diagnostics.upload.state == "sending", "Path B transitions to sending")

    -- Step 3: BUG_REPORT_OK -> transitions to done, closes temp socket, copies ticket
    fake_events = { { type = "msg", msg = { t = "BUG_REPORT_OK", code = "R-9X2P", bytes = 24680 } } }
    diagnostics:update(0.016)
    check(diagnostics.upload.state == "done" and diagnostics.upload.code == "R-9X2P", "Path B finishes with ticket #R-9X2P")
    check(fake_closed == true, "Path B closes temporary socket cleanly on completion")
    check(clip_store:find("#R-9X2P", 1, true) ~= nil, "Path B auto-copies #R-9X2P to clipboard")

    -- Step 4: Old server via Path B (SERVER_HELLO report_ok=false) -> graceful error & socket closed
    fake_sent, fake_events, fake_closed = {}, {}, false
    diagnostics:_reset_upload_state()
    diagnostics:start_cloud_upload(lan_lobby, "198.51.100.10:17780", "old srv", "test")
    fake_events = { { type = "server_connected" }, { type = "msg", msg = { t = "SERVER_HELLO", server_ver = "2.4.0", report_ok = false } } }
    diagnostics:update(0.016)
    check(diagnostics.upload.state == "error" and fake_closed == true, "Path B rejects old server report_ok=false and closes temp socket")

    package.loaded["kr_mp.net_online"] = saved_net_online
end

print(string.format("DIAG_LAYER3_SUITE: PASS=%d FAIL=%d", pass_cnt, fail_cnt))
if fail_cnt > 0 then
    error("verify_diagnostics_layer3 failed with " .. tostring(fail_cnt) .. " failures")
end
