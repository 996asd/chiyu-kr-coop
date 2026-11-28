local _KR_REPO = (os.getenv("KR_MP_REPO_ROOT") or "."):gsub("\\", "/")
local _KR_TMP = (os.getenv("KR_MP_TEST_TMP") or (_KR_REPO .. "/tests/.tmp_run")):gsub("\\", "/")
-- Comprehensive LuaJIT unit + UI geometry verifier for Sakura v2.3.0 enhancements
package.path = _KR_REPO .. "/client/?.lua;" .. _KR_REPO .. "/client/?/init.lua;" .. package.path

local pass_cnt, fail_cnt = 0, 0
local function check(name, cond, msg)
    if cond then
        pass_cnt = pass_cnt + 1
    else
        fail_cnt = fail_cnt + 1
        print("[FAIL] " .. tostring(name) .. ": " .. tostring(msg or ""))
    end
end

-- 1. Syntax-compile all client Lua files
local lua_files = {
    "UH.lua",
    "kr_mp/autotest.lua", "kr_mp/boot.lua", "kr_mp/catalog.lua", "kr_mp/commands.lua",
    "kr_mp/coop.lua", "kr_mp/fonts.lua", "kr_mp/hooks.lua", "kr_mp/hooks_determinism.lua",
    "kr_mp/hooks_gui_actions.lua", "kr_mp/hooks_gui_guards.lua", "kr_mp/hooks_sim.lua",
    "kr_mp/lobby_draw.lua", "kr_mp/lobby_draw_modals.lua", "kr_mp/lobby_draw_sakura.lua",
    "kr_mp/lobby_draw_server.lua",
    "kr_mp/lobby_input.lua", "kr_mp/lobby_prefs.lua", "kr_mp/lobby_ui.lua",
    "kr_mp/lockstep.lua", "kr_mp/net_lan.lua", "kr_mp/net_online.lua", "kr_mp/overlay.lua",
    "kr_mp/prng.lua", "kr_mp/proto.lua", "kr_mp/replay.lua", "kr_mp/sakura.lua",
    "kr_mp/sakura_workers.lua", "kr_mp/server_host.lua", "kr_mp/state_hash.lua", "kr_mp/transport.lua",
    "kr_mp/ui_assets.lua", "kr_mp/updater.lua", "kr_mp/voice.lua",
}
for _, rel in ipairs(lua_files) do
    local fn, err = loadfile(_KR_REPO .. "/client/" .. rel)
    check("syntax:" .. rel, fn ~= nil, err)
end

-- 2. Syntax-compile all 3 love.thread worker strings in sakura_workers.lua + server_host.lua downloader worker
local workers = require("kr_mp.sakura_workers")
for _, k in ipairs({ "PROBE_WORKER_CODE", "API_WORKER_CODE", "INSTALLER_WORKER_CODE" }) do
    local fn, err = loadstring(workers[k], k)
    check("worker_syntax:" .. k, fn ~= nil, err)
end
local server_host = require("kr_mp.server_host")
do
    local fn, err = loadstring(server_host._DL_WORKER_CODE, "SERVER_DL_WORKER_CODE")
    check("worker_syntax:SERVER_DL_WORKER_CODE", fn ~= nil, err)
end

-- 3. Verify pure-LuaJIT streaming MD5 implementation inside INSTALLER_WORKER_CODE against RFC 1321 vectors
do
    local src = workers.INSTALLER_WORKER_CODE
    local s1 = src:find("-- Pure-LuaJIT streaming MD5", 1, true)
    local s2 = src:find("local function md5_file", 1, true)
    check("md5_extract", s1 and s2 and s2 > s1, "cannot slice md5 block")
    if s1 and s2 then
        local md5_src = "local bit = require('bit')\n" .. src:sub(s1, s2 - 1) .. "\nreturn md5_new\n"
        local loader, lerr = loadstring(md5_src, "md5_test")
        check("md5_compile", loader ~= nil, lerr)
        if loader then
            local md5_new = loader()
            local function md5_str(str, chunk_sz)
                local h = md5_new()
                if chunk_sz then
                    for i = 1, #str, chunk_sz do
                        h:update(str:sub(i, i + chunk_sz - 1))
                    end
                else
                    h:update(str)
                end
                return h:final()
            end
            check("md5_empty", md5_str("") == "d41d8cd98f00b204e9800998ecf8427e", md5_str(""))
            check("md5_abc", md5_str("abc") == "900150983cd24fb0d6963f7d28e17f72", md5_str("abc"))
            check("md5_msg_digest", md5_str("message digest") == "f96b697d7cb7938d525a2f31aaf161d0", md5_str("message digest"))
            check("md5_alphabet", md5_str("abcdefghijklmnopqrstuvwxyz") == "c3fcd3d76192e4007dfb496cca67e13b", md5_str("abcdefghijklmnopqrstuvwxyz"))
            local big = string.rep("SakuraFrp_KR_MP_230!", 5000) -- 100 KB
            check("md5_stream_equiv", md5_str(big, 137) == md5_str(big), "chunked != single")
        end
    end
end

-- 4. Test sakura node sorting (public_mode OFF vs ON) & realname == 0 guard
local sakura = require("kr_mp.sakura")
local last_toast = nil
sakura.overlay = { show_toast = function(_, msg) last_toast = msg end }
sakura._all_rec_nodes = {
    { id = 10, name = "十堰多线", is_mainland = true, is_public_ok = true, load = 18, vip = 0 },
    { id = 11, name = "杭州电信", is_mainland = true, is_public_ok = false, load = 8, vip = 0 },
    { id = 12, name = "枣庄多线", is_mainland = true, is_public_ok = true, load = 15, vip = 0 },
    { id = 13, name = "福州移动", is_mainland = true, is_public_ok = false, load = 22, vip = 0 },
    { id = 14, name = "香港多线", is_mainland = false, is_public_ok = true, load = 5, vip = 0 },
}
sakura.public_mode = false
sakura.node_page = 3
sakura:rebuild_filtered_nodes()
check("nodes_all_count", #sakura.recommended_nodes == 5, tostring(#sakura.recommended_nodes))
check("nodes_all_page_reset", sakura.node_page == 1, tostring(sakura.node_page))
check("nodes_all_first_lowest", sakura.recommended_nodes[1].id == 11, tostring(sakura.recommended_nodes[1].name))
check("nodes_all_second", sakura.recommended_nodes[2].id == 12, tostring(sakura.recommended_nodes[2].name))
check("nodes_all_overseas_last", sakura.recommended_nodes[5].id == 14, tostring(sakura.recommended_nodes[5].name))

sakura.public_mode = true
sakura:rebuild_filtered_nodes()
check("nodes_pub_count", #sakura.recommended_nodes == 3, tostring(#sakura.recommended_nodes))
check("nodes_pub_first", sakura.recommended_nodes[1].id == 12, tostring(sakura.recommended_nodes[1].name))
check("nodes_pub_second", sakura.recommended_nodes[2].id == 10, tostring(sakura.recommended_nodes[2].name))
check("nodes_pub_overseas_last", sakura.recommended_nodes[3].id == 14, tostring(sakura.recommended_nodes[3].name))

-- Realname == 0 guard
sakura.token = "dummy_token_123456"
sakura.user_info = { name = "test", realname = 0, group_level = 0, remain_gib = 10, speed = "10 Mbps", tunnels_max = 2 }
local ok_cr = sakura:create_krmp_tunnel(12, 17777)
check("realname_guard_blocks", ok_cr == false, "should block unverified user")
check("realname_guard_toast", last_toast and last_toast:find("实名", 1, true) ~= nil, tostring(last_toast))

-- Download pct clamp
sakura.dl_done_bytes, sakura.dl_total_bytes = 0, 0
check("dl_pct_zero", sakura:get_download_pct() == 0, tostring(sakura:get_download_pct()))
sakura.dl_done_bytes, sakura.dl_total_bytes = 22600000, 45200000
check("dl_pct_half", sakura:get_download_pct() == 50, tostring(sakura:get_download_pct()))

-- Active warning gating: suppress local_refused on Home screen or when stale (>60s)
local base_t = 1795759000
sakura.log_warning = "local refused"
sakura.log_warning_kind = "local_refused"
sakura.log_warning_ts = base_t - 10
check("warn_suppressed_on_home", sakura:get_active_warning({ role = "none" }, base_t) == nil, "should suppress on home")
local host_w = sakura:get_active_warning({ role = "host", transport = { get_port = function() return 17777 end } }, base_t)
check("warn_shown_when_host_fresh", host_w ~= nil and host_w:find("17777", 1, true) ~= nil, tostring(host_w))
check("warn_suppressed_when_stale", sakura:get_active_warning({ role = "host" }, base_t + 70) == nil, "should expire >60s")
sakura.log_warning = "vip expired"
sakura.log_warning_kind = "vip_denied"
sakura.log_warning_ts = base_t - 20
check("warn_vip_shown_fresh", sakura:get_active_warning({ role = "none" }, base_t) == "vip expired", "vip should show")
sakura.log_warning, sakura.log_warning_kind, sakura.log_warning_ts = nil, nil, 0

-- 5. Mock LÖVE graphics & verify UI geometry (zero overlap, zero OOB) across all Sakura modal & Home states
local drawn_texts = {}
local function make_font(sz)
    return {
        _sz = sz,
        getHeight = function() return sz + 4 end,
        getWidth = function(_, s)
            local w = 0
            local i = 1
            s = tostring(s or "")
            while i <= #s do
                local b = s:byte(i)
                if b >= 224 then
                    w = w + sz * 1.0
                    i = i + 3
                elseif b >= 192 then
                    w = w + sz * 0.85
                    i = i + 2
                else
                    w = w + sz * 0.54
                    i = i + 1
                end
            end
            return w
        end,
        getWrap = function(self, s, limit)
            local tw = self:getWidth(s)
            local lines = math.max(1, math.ceil(tw / math.max(1, limit)))
            return math.min(tw, limit), { n = lines }
        end,
    }
end

local cur_font = make_font(12)
local noop = function() end
_G.love = {
    graphics = setmetatable({
        getDimensions = function() return 1280, 720 end,
        getWidth = function() return 1280 end,
        getHeight = function() return 720 end,
        getPixelDimensions = function() return 1280, 720 end,
        getDPIScale = function() return 1 end,
        setFont = function(f) cur_font = f or cur_font end,
        getFont = function() return cur_font end,
        print = function(t, x, y) drawn_texts[#drawn_texts + 1] = { t = tostring(t), x = x, y = y, f = cur_font } end,
        printf = function(t, x, y, lim) drawn_texts[#drawn_texts + 1] = { t = tostring(t), x = x, y = y, lim = lim, f = cur_font } end,
        newImage = function() return nil end,
        newFont = function(sz) return make_font(tonumber(sz) or 12) end,
    }, { __index = function() return noop end }),
    window = { getDPIScale = function() return 1 end },
    mouse = { getPosition = function() return 0, 0 end, isDown = function() return false end },
    timer = { getTime = function() return 100.0 end },
    system = { getOS = function() return "Windows" end },
    filesystem = { getInfo = function() return nil end },
}

local ui = require("kr_mp.ui_assets")
local sakura_modal = require("kr_mp.lobby_draw_sakura")
local lobby_draw = require("kr_mp.lobby_draw")
local fm = {
    title = make_font(20), hero = make_font(15), body = make_font(13),
    small = make_font(12), small_bold = make_font(12),
    tiny = make_font(11), tiny_bold = make_font(11),
}

local function check_buttons_geom(tag, btns, px, py, pw, ph)
    local overlaps, oobs = 0, 0
    for i = 1, #btns do
        local a = btns[i]
        local allow_badge = (a.id == "close" or a.id == "export_report")
        if not allow_badge then
            if a.x < px - 1 or a.y < py - 1 or (a.x + a.w) > (px + pw + 1) or (a.y + a.h) > (py + ph + 1) then
                oobs = oobs + 1
                print(string.format("  [OOB] %s btn=%s (%d,%d %dx%d) panel=(%d,%d %dx%d)", tag, a.id, a.x, a.y, a.w, a.h, px, py, pw, ph))
            end
        end
        for j = i + 1, #btns do
            local b = btns[j]
            local ox = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
            local oy = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
            if ox > 0 and oy > 0 then
                overlaps = overlaps + 1
                print(string.format("  [OVERLAP] %s %s(%s) vs %s(%s) ox=%.1f oy=%.1f", tag, a.id, a.label, b.id, b.label, ox, oy))
            end
        end
    end
    check("geom_oob:" .. tag, oobs == 0, "oob=" .. oobs)
    check("geom_overlap:" .. tag, overlaps == 0, "overlaps=" .. overlaps)
end

local function make_mock_lobby(sk_state)
    local l = {
        open = true, view = "home", net_tab = "sakura", sub_modal = "sakura",
        privacy_mask = false, sakura_show_wizard = false, sakura_wizard_dismissed = false,
        sakura_ip_input = "", lan_ip_input = "127.0.0.1", ip_input = "", server_input = "127.0.0.1:17780",
        recent_addrs = {}, buttons = {}, role = "none",
        room = { level_idx = 101, level_difficulty = 2, econ_mode = "independent", tower_mode = "owned", input_delay_turns = 2, heroes = { 53, 54 }, towers = { 1, 2, 3, 4, 5, 6 } },
        is_point_in_rect = function() return false end,
        transport = { is_online = function() return false end, is_connecting = function() return false end, get_port = function() return 17777 end },
        sakura = sk_state,
    }
    return l
end

local function run_sakura_modal_case(tag, sk_override, lobby_override)
    local sk = {
        installed = false, frpc_running = false, service_running = false,
        dl_busy = false, dl_done_bytes = 0, dl_total_bytes = 47558016, dl_ver = "3.2.0.2",
        dl_stage = nil, dl_error = nil, dl_path = nil,
        token = "", public_mode = false, api_busy = false, api_error = nil,
        user_info = nil, tunnels = {}, recommended_nodes = {}, node_page = 1,
        get_host_share_addr = function() return nil, nil, false end,
        get_download_pct = sakura.get_download_pct,
        get_probe_label = sakura.get_probe_label,
        mask_addr = sakura.mask_addr,
    }
    for k, v in pairs(sk_override or {}) do sk[k] = v end
    local lobby = make_mock_lobby(sk)
    for k, v in pairs(lobby_override or {}) do lobby[k] = v end
    lobby.sub_modal = "sakura"
    lobby.buttons = {}
    drawn_texts = {}
    -- Test through REAL lobby_draw.draw at actual 780x520 war-table coordinates!
    lobby_draw.draw(lobby)
    check_buttons_geom(tag, lobby.buttons, 0, 0, 780, 486)
    -- Also verify NO wrapped text block collides with any button vertically (unscale physical -> logical)!
    local sc = lobby._ui_scale or 1
    local ox0, oy0 = lobby._ui_ox or 0, lobby._ui_oy or 0
    local txt_hits = 0
    for _, dt in ipairs(drawn_texts) do
        if dt.lim and dt.f and dt.x and dt.y then
            local lx = (dt.x - ox0) / sc
            local ly = (dt.y - oy0) / sc
            local llim = dt.lim / sc
            local lsz = (dt.f._sz or 11) / sc
            local ltw = dt.f:getWidth(dt.t) / sc
            local lines = math.max(1, math.ceil((ltw * 1.04) / math.max(1, llim)))
            local lh = math.ceil(lsz * 1.45)
            local tx1, tx2 = lx, lx + math.min(ltw, llim)
            local ty1, ty2 = ly, ly + lines * lh
            for _, b in ipairs(lobby.buttons) do
                if b.id ~= "close" and b.id ~= "export_report" then
                    local ox = math.min(tx2, b.x + b.w) - math.max(tx1, b.x)
                    local oy = math.min(ty2, b.y + b.h) - math.max(ty1, b.y)
                    local inside_btn = (ly >= b.y - 3 and (ly + lh) <= (b.y + b.h + 5) and lx >= b.x - 4 and (lx + llim) <= (b.x + b.w + 8))
                    if (not inside_btn) and ox > 4 and oy > 1 then
                        txt_hits = txt_hits + 1
                        print(string.format("  [TEXT_BTN_COLLIDE] %s text='%s' (y=%.1f..%.1f lines=%d lh=%d) vs btn=%s (y=%d..%d)",
                            tag, dt.t:sub(1, 30), ty1, ty2, lines, lh, b.id, b.y, b.y + b.h))
                    end
                end
            end
        end
    end
    check("text_btn_clear:" .. tag, txt_hits == 0, "collisions=" .. txt_hits)
    return lobby.buttons
end

-- Case A: New user wizard (not installed, not logged in)
local b_wiz = run_sakura_modal_case("modal_wizard_fresh", { installed = false })
local has_dl_btn = false
for _, b in ipairs(b_wiz) do if b.id == "sakura_download_official" then has_dl_btn = true end end
check("wizard_has_dl_btn", has_dl_btn, "missing sakura_download_official")

-- Case B: Downloading official installer (45%) + wizard visible
run_sakura_modal_case("modal_downloading_wizard", {
    installed = false, dl_busy = true, dl_stage = "downloading", dl_done_bytes = 21400000, dl_total_bytes = 47558016,
})

-- Case C: Download done waiting refresh
run_sakura_modal_case("modal_dl_done", {
    installed = false, dl_path = "C:\\Temp\\SakuraLauncher_v3.2.0.2_official.exe",
})

-- Case D: Synced + Unverified realname == 0 (split tunnel/nodes view)
local many_nodes = {}
for i = 1, 14 do
    many_nodes[i] = { id = i, name = "测试节点" .. i, is_public_ok = (i % 2 == 0), load = 10 + i * 2, vip = 0 }
end
local b_unv = run_sakura_modal_case("modal_synced_unverified", {
    installed = true, token = "tok_1234567890",
    user_info = { name = "chiyu", group_name = "免费用户", remain_gib = 11.5, speed = "10 Mbps", tunnels_max = 2, realname = 0 },
    tunnels = {
        { id = 1, name = "kr17777", local_port = 17777, online = true, addr = "frp-ski.com:54321", node_name = "十堰多线", remote = "54321", is_krmp = true },
        { id = 2, name = "mc_srv", local_port = 25565, online = false, addr = nil, node_name = "宿迁VIP", remote = "42019", is_krmp = false },
    },
    recommended_nodes = many_nodes, node_page = 1,
})
local has_rn_btn, has_next_btn = false, false
for _, b in ipairs(b_unv) do
    if b.id == "sakura_open_realname" then has_rn_btn = true end
    if b.id == "sakura_nodes_next" then has_next_btn = true end
end
check("unverified_has_realname_btn", has_rn_btn, "missing sakura_open_realname")
check("nodes_has_pagination", has_next_btn, "missing sakura_nodes_next")

-- Case E: Synced + Verified + Privacy Mask ON + Page 2 + Active managed frpc
run_sakura_modal_case("modal_synced_verified_p2_masked", {
    installed = true, token = "tok_1234567890", frpc_running = true,
    managed_proc = { tunnel_id = 1, tunnel_name = "kr17777", addr = "frp-ski.com:54321" },
    user_info = { name = "chiyu", group_name = "免费用户", remain_gib = 11.5, speed = "10 Mbps", tunnels_max = 2, realname = 1 },
    tunnels = {
        { id = 1, name = "kr17777", local_port = 17777, online = true, addr = "frp-ski.com:54321", node_name = "十堰多线", remote = "54321", is_krmp = true },
    },
    recommended_nodes = many_nodes, node_page = 2,
    get_host_share_addr = function() return "frp-ski.com:54321", "frp-ski.com:54321", false end,
}, { privacy_mask = true })

-- Case F: Home Sakura tab (uninstalled & downloading 42%) via lobby_draw.draw
local function run_home_case(tag, sk_override)
    local sk = {
        installed = false, frpc_running = false, service_running = false,
        dl_busy = false, dl_done_bytes = 0, dl_total_bytes = 47558016, dl_ver = "3.2.0.2",
        get_host_share_addr = function() return nil, nil, false end,
        get_download_pct = sakura.get_download_pct,
        get_probe_label = sakura.get_probe_label,
        mask_addr = sakura.mask_addr,
    }
    for k, v in pairs(sk_override or {}) do sk[k] = v end
    local lobby = make_mock_lobby(sk)
    lobby.sub_modal = nil
    lobby.view = "home"
    lobby.net_tab = "sakura"
    lobby.room = { level_idx = 101, level_difficulty = 2, econ_mode = "independent", tower_mode = "owned", input_delay_turns = 2, heroes = { 53, 54 }, towers = { 1, 2, 3, 4, 5, 6 } }
    lobby.is_point_in_rect = function() return false end
    lobby.buttons = {}
    drawn_texts = {}
    lobby_draw.draw(lobby)
    check_buttons_geom(tag, lobby.buttons, 0, 0, 780, 486)
    -- Also verify NO wrapped text block collides with any button vertically (unscale physical -> logical)!
    local sc = lobby._ui_scale or 1
    local ox0, oy0 = lobby._ui_ox or 0, lobby._ui_oy or 0
    local txt_hits = 0
    for _, dt in ipairs(drawn_texts) do
        if dt.lim and dt.f and dt.x and dt.y then
            local lx = (dt.x - ox0) / sc
            local ly = (dt.y - oy0) / sc
            local llim = dt.lim / sc
            local lsz = (dt.f._sz or 11) / sc
            local ltw = dt.f:getWidth(dt.t) / sc
            local lines = math.max(1, math.ceil((ltw * 1.04) / math.max(1, llim)))
            local lh = math.ceil(lsz * 1.45)
            local tx1, tx2 = lx, lx + math.min(ltw, llim)
            local ty1, ty2 = ly, ly + lines * lh
            for _, b in ipairs(lobby.buttons) do
                if b.id ~= "close" and b.id ~= "export_report" then
                    local ox = math.min(tx2, b.x + b.w) - math.max(tx1, b.x)
                    local oy = math.min(ty2, b.y + b.h) - math.max(ty1, b.y)
                    local inside_btn = (ly >= b.y - 3 and (ly + lh) <= (b.y + b.h + 5) and lx >= b.x - 4 and (lx + llim) <= (b.x + b.w + 8))
                    if (not inside_btn) and ox > 4 and oy > 1 then
                        txt_hits = txt_hits + 1
                        print(string.format("  [TEXT_BTN_COLLIDE] %s text='%s' (y=%.1f..%.1f lines=%d lh=%d) vs btn=%s (y=%d..%d)",
                            tag, dt.t:sub(1, 30), ty1, ty2, lines, lh, b.id, b.y, b.y + b.h))
                    end
                end
            end
        end
    end
    check("text_btn_clear:" .. tag, txt_hits == 0, "collisions=" .. txt_hits)
    return lobby.buttons
end

local bh1 = run_home_case("home_sakura_uninstalled", { installed = false })
local home_has_dl = false
for _, b in ipairs(bh1) do if b.id == "sakura_download_official" then home_has_dl = true end end
check("home_uninstalled_has_dl_btn", home_has_dl, "missing sakura_download_official on home")
run_home_case("home_sakura_downloading", { installed = false, dl_busy = true, dl_done_bytes = 20000000, dl_total_bytes = 47558016 })

-- Case G: Online handshake gating (never mark server_connected=true before SERVER_HELLO)
local lobby_ui = require("kr_mp.lobby_ui")
local sent_msgs, online_toasts = {}, {}
lobby_ui.boot = { log = function() end }
lobby_ui.overlay = { show_toast = function(_, msg) online_toasts[#online_toasts + 1] = msg end, clear_toast = function() end }
lobby_ui.transport = {
    is_online = function() return true end,
    is_connected = function() return true end,
    is_connecting = function() return false end,
    send = function(_, m) sent_msgs[#sent_msgs + 1] = m end,
    close = function() end,
    poll = function() return {} end,
    get_rtt_ms = function() return 18 end,
}
lobby_ui.pending_online_action = { kind = "list_rooms" }
lobby_ui:on_online_connected()
check("online_not_connected_before_hello", lobby_ui.server_connected == false, "premature server_connected")
check("online_handshaking_true", lobby_ui.server_handshaking == true, "missing server_handshaking")
check("online_sent_hello_only", #sent_msgs == 1 and sent_msgs[1].t == "HELLO", "expected HELLO only before SERVER_HELLO")

lobby_ui:on_message({ t = "SERVER_HELLO", server_ver = "2.3.0", voice_ok = true, rooms = {} })
check("online_connected_after_hello", lobby_ui.server_connected == true, "should be connected after SERVER_HELLO")
check("online_handshaking_cleared", lobby_ui.server_handshaking == false, "handshaking not cleared")
check("online_flushed_pending_list", #sent_msgs == 2 and sent_msgs[2].t == "LIST_ROOMS", "pending action not flushed")

-- Simulate SakuraFrp 17777 early disconnect during handshake (non-silent)
lobby_ui.server_connected = false
lobby_ui.server_handshaking = true
lobby_ui.server_connect_silent = false
lobby_ui.transport.poll = function() return { { type = "server_disconnected" } } end
lobby_ui:update(0.016)
check("online_early_eof_clear_toast",
    online_toasts[#online_toasts] and online_toasts[#online_toasts]:find("kr-mp-server", 1, true) ~= nil,
    tostring(online_toasts[#online_toasts]))

-- Case H: 1-Click Self-Hosted Server Modal (4 states) + Online Home Tab at real 780x486
local function run_server_modal_case(tag, sh_override, sk_override)
    local sh = {
        DEFAULT_PORT = 17780, VPS_DEPLOY_CMD = server_host.VPS_DEPLOY_CMD,
        binary_path = nil, running = false, keep_running_on_exit = true, lan_ip = "192.168.1.88",
        dl_busy = false, dl_done_bytes = 0, dl_total_bytes = 6970000, dl_ver = "2.3.0", dl_stage = nil, dl_error = nil,
        get_download_pct = server_host.get_download_pct,
        get_sakura_relay_info = server_host.get_sakura_relay_info,
    }
    for k, v in pairs(sh_override or {}) do sh[k] = v end
    local sk = {
        installed = true, user_info = nil, tunnels = {}, recommended_nodes = {},
        mask_addr = sakura.mask_addr, get_active_warning = sakura.get_active_warning,
    }
    for k, v in pairs(sk_override or {}) do sk[k] = v end
    local lobby = make_mock_lobby(sk)
    lobby.server_host = sh
    lobby.sub_modal = "server_host"
    lobby.buttons = {}
    drawn_texts = {}
    lobby_draw.draw(lobby)
    check_buttons_geom(tag, lobby.buttons, 0, 0, 780, 486)
    local sc = lobby._ui_scale or 1
    local ox0, oy0 = lobby._ui_ox or 0, lobby._ui_oy or 0
    local txt_hits = 0
    for _, dt in ipairs(drawn_texts) do
        if dt.lim and dt.f and dt.x and dt.y then
            local lx, ly = (dt.x - ox0) / sc, (dt.y - oy0) / sc
            local llim, lsz = dt.lim / sc, (dt.f._sz or 11) / sc
            local ltw = dt.f:getWidth(dt.t) / sc
            local lines = math.max(1, math.ceil((ltw * 1.04) / math.max(1, llim)))
            local lh = math.ceil(lsz * 1.45)
            local tx1, tx2, ty1, ty2 = lx, lx + math.min(ltw, llim), ly, ly + lines * lh
            for _, b in ipairs(lobby.buttons) do
                if b.id ~= "close" and b.id ~= "export_report" then
                    local ox = math.min(tx2, b.x + b.w) - math.max(tx1, b.x)
                    local oy = math.min(ty2, b.y + b.h) - math.max(ty1, b.y)
                    local inside_btn = (ly >= b.y - 3 and (ly + lh) <= (b.y + b.h + 5) and lx >= b.x - 4 and (lx + llim) <= (b.x + b.w + 8))
                    if (not inside_btn) and ox > 4 and oy > 1 then
                        txt_hits = txt_hits + 1
                        print(string.format("  [TEXT_BTN_COLLIDE] %s text='%s' (y=%.1f..%.1f) vs btn=%s (y=%d..%d)",
                            tag, dt.t:sub(1, 30), ty1, ty2, b.id, b.y, b.y + b.h))
                    end
                end
            end
        end
    end
    check("text_btn_clear:" .. tag, txt_hits == 0, "collisions=" .. txt_hits)
end

run_server_modal_case("srv_modal_fresh", { binary_path = nil, running = false }, { installed = false })
run_server_modal_case("srv_modal_downloading", { dl_busy = true, dl_stage = "downloading", dl_done_bytes = 3300000, dl_total_bytes = 6970000 })
run_server_modal_case("srv_modal_running_pub",
    { binary_path = "D:\\FL8.2.0\\server\\kr-mp-server.exe", running = true },
    {
        user_info = { name = "chiyu", realname = 1 },
        tunnels = { { id = 99, name = "kr17780", type = "tcp", local_port = 17780, online = true, addr = "frp-ski.com:54321" } },
    })
run_server_modal_case("srv_modal_running_create",
    { binary_path = "D:\\FL8.2.0\\server\\kr-mp-server.exe", running = true },
    {
        user_info = { name = "chiyu", realname = 1 },
        tunnels = {},
        recommended_nodes = { { id = 12, name = "枣庄多线", is_public_ok = true, load = 14 } },
    })

-- Also test Online Home tab with new "一键自建公网服" button
do
    local lobby = make_mock_lobby({ mask_addr = sakura.mask_addr })
    lobby.sub_modal = nil
    lobby.view = "home"
    lobby.net_tab = "online"
    lobby.server_connected = false
    lobby.server_handshaking = false
    lobby.online_rooms = {}
    lobby.pw_input = ""
    lobby.code_input = ""
    lobby.room_public = true
    lobby.transport.get_rtt_ms = function() return 0 end
    lobby.server_host = { running = false }
    lobby.buttons = {}
    drawn_texts = {}
    lobby_draw.draw(lobby)
    check_buttons_geom("home_online_with_host_btn", lobby.buttons, 0, 0, 780, 486)
    local has_srv_btn = false
    for _, b in ipairs(lobby.buttons) do if b.id == "open_server_host" then has_srv_btn = true end end
    check("home_online_has_open_server_host", has_srv_btn, "missing open_server_host")
end

-- Case I: A+B standalone frpc download, error fallback, log diagnosis, LAN IP filter, and modal geometry
do
    -- I1: Virtual/TUN LAN IP filtering (Mihomo 198.18.*, APIPA 169.254.*, vEthernet 172.*)
    check("lan_ip_skip_mihomo_pick_wlan",
        server_host._pick_best_lan_ip({ "198.18.0.1", "169.254.109.100", "172.28.16.1", "26.171.18.157", "10.142.17.6" }) == "10.142.17.6",
        tostring(server_host._pick_best_lan_ip({ "198.18.0.1", "169.254.109.100", "172.28.16.1", "26.171.18.157", "10.142.17.6" })))
    check("lan_ip_prefer_192_over_10",
        server_host._pick_best_lan_ip({ "198.18.0.1", "10.0.0.5", "192.168.1.88", "172.16.0.2" }) == "192.168.1.88",
        "expected 192.168.1.88")
    check("lan_ip_all_bad_nil",
        server_host._pick_best_lan_ip({ "127.0.0.1", "0.0.0.0", "198.18.0.1", "198.19.2.3", "169.254.1.2" }) == nil,
        "expected nil")

    -- I2: Standalone frpc log parser + diagnosis
    local parsed_st = workers.parse_sakura_log_tail(
        "2026/11/27 12:00:01 I/frpc 隧道启动成功\n2026/11/27 12:00:01 I/frpc 使用 >>frp-box.com:48985<< 连接你的隧道\n",
        "krmp_17780_795"
    )
    check("standalone_log_parse_addr", parsed_st and parsed_st.alive and parsed_st.addr == "frp-box.com:48985",
        parsed_st and tostring(parsed_st.addr) or "nil")
    check("diag_401", workers.diagnose_frpc_log("[401] 访问密钥无效\n"):find("密钥", 1, true) ~= nil, "401 diag")
    check("diag_realname", workers.diagnose_frpc_log("未完成实名认证"):find("实名", 1, true) ~= nil, "realname diag")
    check("diag_launcher_frpc", workers.diagnose_frpc_log("part of SakuraFrp Launcher"):find("独立版", 1, true) ~= nil, "launcher frpc diag")
    check("diag_timeout", workers.diagnose_frpc_log("dial tcp: i/o timeout"):find("代理", 1, true) ~= nil, "timeout diag")

    -- I3: Sakura modal new A+B states (downloading standalone frpc + managed error + connecting)
    run_sakura_modal_case("modal_frpc_downloading", {
        installed = true, token = "tok_1234567890", frpc_dl_busy = true, frpc_dl_stage = "downloading",
        frpc_dl_ver = "0.51.0-sakura-15.1", frpc_dl_done_bytes = 6800000, frpc_dl_total_bytes = 14209024,
        get_frpc_download_pct = sakura.get_frpc_download_pct,
        user_info = { name = "chiyu", group_name = "免费用户", remain_gib = 11.5, speed = "10 Mbps", tunnels_max = 2, realname = 1 },
        tunnels = { { id = 1, name = "kr17777", local_port = 17777, online = false, addr = "frp-ski.com:54321", node_name = "十堰多线", remote = "54321", is_krmp = true } },
    })
    run_sakura_modal_case("modal_frpc_error_and_connecting", {
        installed = true, token = "tok_1234567890", managed_last_error = "访问密钥无效，请重新粘贴樱花访问密钥",
        get_frpc_download_pct = sakura.get_frpc_download_pct,
        user_info = { name = "chiyu", group_name = "免费用户", remain_gib = 11.5, speed = "10 Mbps", tunnels_max = 2, realname = 1 },
        tunnels = { { id = 1, name = "kr17777", local_port = 17777, online = false, addr = "frp-ski.com:54321", node_name = "十堰多线", remote = "54321", is_krmp = true } },
    })

    -- I4: Server-host modal new A+B states (downloading frpc, connecting, offline A+B, offline error A+B)
    run_server_modal_case("srv_modal_frpc_dl",
        { binary_path = "D:\\FL8.2.0\\server\\kr-mp-server.exe", running = true },
        {
            user_info = { name = "chiyu", realname = 1 },
            frpc_dl_busy = true, frpc_dl_stage = "downloading", frpc_dl_ver = "0.51.0-sakura-15.1",
            frpc_dl_done_bytes = 7100000, frpc_dl_total_bytes = 14209024,
            get_frpc_download_pct = sakura.get_frpc_download_pct,
            tunnels = { { id = 99, name = "krmp_17780_795", type = "tcp", local_port = 17780, online = false, addr = "frp-box.com:48985" } },
        })
    run_server_modal_case("srv_modal_connecting",
        { binary_path = "D:\\FL8.2.0\\server\\kr-mp-server.exe", running = true },
        {
            user_info = { name = "chiyu", realname = 1 },
            managed_proc = { tunnel_id = 99, tunnel_name = "krmp_17780_795", local_port = 17780, addr = "frp-box.com:48985", confirmed = false },
            tunnels = { { id = 99, name = "krmp_17780_795", type = "tcp", local_port = 17780, online = false, addr = "frp-box.com:48985" } },
        })
    run_server_modal_case("srv_modal_offline_ab",
        { binary_path = "D:\\FL8.2.0\\server\\kr-mp-server.exe", running = true },
        {
            user_info = { name = "chiyu", realname = 1 },
            tunnels = { { id = 99, name = "krmp_17780_795", type = "tcp", local_port = 17780, online = false, addr = "frp-box.com:48985" } },
        })
    run_server_modal_case("srv_modal_offline_ab_err",
        { binary_path = "D:\\FL8.2.0\\server\\kr-mp-server.exe", running = true },
        {
            user_info = { name = "chiyu", realname = 1 },
            managed_last_error = "无法连接樱花节点（可能受代理/VPN 或防火墙干扰）",
            tunnels = { { id = 99, name = "krmp_17780_795", type = "tcp", local_port = 17780, online = false, addr = "frp-box.com:48985" } },
        })

    -- I5: Home Sakura tab with frpc_dl_busy & managed_last_error
    run_home_case("home_sakura_frpc_dl", {
        installed = true, frpc_dl_busy = true, frpc_dl_ver = "0.51.0", frpc_dl_done_bytes = 5000000, frpc_dl_total_bytes = 14209024,
        get_frpc_download_pct = sakura.get_frpc_download_pct,
    })
    run_home_case("home_sakura_managed_err", {
        installed = true, managed_last_error = "独立版 frpc 异常退出",
    })

    -- I6: In-game 4-page Beginner Guide geometry + single-line wrap & text-vs-button collision check
    for gtab = 1, 4 do
        local lobby = make_mock_lobby({ mask_addr = sakura.mask_addr })
        lobby.sub_modal = "guide"
        lobby.guide_tab = gtab
        lobby.buttons = {}
        drawn_texts = {}
        lobby_draw.draw(lobby)
        local tag = "guide_tab_" .. tostring(gtab)
        check_buttons_geom(tag, lobby.buttons, 0, 0, 780, 486)
        local sc = lobby._ui_scale or 1
        local ox0, oy0 = lobby._ui_ox or 0, lobby._ui_oy or 0
        local txt_hits, wrap_overflows = 0, 0
        for _, dt in ipairs(drawn_texts) do
            if dt.lim and dt.f and dt.x and dt.y then
                local lx, ly = (dt.x - ox0) / sc, (dt.y - oy0) / sc
                local llim, lsz = dt.lim / sc, (dt.f._sz or 11) / sc
                local ltw = dt.f:getWidth(dt.t) / sc
                local lines = math.max(1, math.ceil((ltw * 1.04) / math.max(1, llim)))
                local lh = math.ceil(lsz * 1.45)
                -- On guide tab 1, each of the 3 card body lines has 21px row pitch -> must fit on 1 line!
                if gtab == 1 and llim > 600 and lines > 1 then
                    wrap_overflows = wrap_overflows + 1
                    print(string.format("  [GUIDE_WRAP] tab1 line wraps (%d lines, w=%.1f > lim=%.1f): %s", lines, ltw, llim, dt.t))
                end
                local tx1, tx2, ty1, ty2 = lx, lx + math.min(ltw, llim), ly, ly + lines * lh
                for _, b in ipairs(lobby.buttons) do
                    if b.id ~= "close" then
                        local ox = math.min(tx2, b.x + b.w) - math.max(tx1, b.x)
                        local oy = math.min(ty2, b.y + b.h) - math.max(ty1, b.y)
                        local inside_btn = (ly >= b.y - 3 and (ly + lh) <= (b.y + b.h + 5) and lx >= b.x - 4 and (lx + llim) <= (b.x + b.w + 8))
                        if (not inside_btn) and ox > 4 and oy > 1 then
                            txt_hits = txt_hits + 1
                            print(string.format("  [TEXT_BTN_COLLIDE] %s text='%s' (y=%.1f..%.1f) vs btn=%s (y=%d..%d)",
                                tag, dt.t:sub(1, 30), ty1, ty2, b.id, b.y, b.y + b.h))
                        end
                    end
                end
            end
        end
        check("text_btn_clear:" .. tag, txt_hits == 0, "collisions=" .. txt_hits)
        if gtab == 1 then
            check("guide_tab1_single_line_fit", wrap_overflows == 0, "wraps=" .. wrap_overflows)
        end
    end

    -- I7: v2.3.1 Chinese-path ASCII safety + fail-closed SHA-256 + Home Sakura quick-LAN button
    check("sakura_ascii_ok", sakura._is_ascii_path("D:\\FL8.2.0") == true, "ASCII path")
    check("sakura_non_ascii_cn", sakura._is_ascii_path("D:\\游戏\\王国保卫战FL8.2.0") == false, "CN path")
    check("server_host_ascii_ok", server_host._is_ascii_path("C:\\Users\\Public\\KR_MP_Bin") == true, "ASCII path")
    check("server_host_non_ascii_cn", server_host._is_ascii_path("C:\\Users\\小明\\Desktop\\FL8.2.0") == false, "CN path")
    check("server_host_builtin_sha_64",
        type(server_host.BUILTIN_WIN_SHA256) == "string" and #server_host.BUILTIN_WIN_SHA256 == 64,
        tostring(server_host.BUILTIN_WIN_SHA256))
    check("server_host_fail_closed_guard",
        server_host._DL_WORKER_CODE:find("无法获取官方 SHA-256 校验值", 1, true) ~= nil,
        "missing fail-closed guard")
    -- Simulate Chinese game dir & Chinese save dir -> get_bin_dir & get_download_target_dir MUST return pure ASCII!
    local old_fs = _G.love.filesystem
    _G.love.filesystem = {
        getInfo = function() return nil end,
        getSourceBaseDirectory = function() return "D:\\游戏\\王国保卫战FL8.2.0" end,
        getSaveDirectory = function() return "C:\\Users\\小明\\AppData\\Roaming\\LOVE\\KR" end,
    }
    local sk_dir = sakura:get_bin_dir()
    local sh_dir = server_host:get_download_target_dir()
    _G.love.filesystem = old_fs
    check("sakura_cn_fallback_ascii", sakura._is_ascii_path(sk_dir), "got=" .. tostring(sk_dir))
    check("server_host_cn_fallback_ascii", server_host._is_ascii_path(sh_dir), "got=" .. tostring(sh_dir))

    -- Verify Home Sakura tab now has quick "同Wi-Fi免装樱花→" button without overlap/collision
    local bh_v231 = run_home_case("home_sakura_v231_quick_lan", { installed = true })
    local has_quick_lan = false
    for _, b in ipairs(bh_v231) do
        if b.id == "tab_lan" and b.label:find("免装", 1, true) then has_quick_lan = true end
    end
    check("home_sakura_has_quick_lan_btn", has_quick_lan, "missing quick tab_lan button")

    -- Verify Home LAN tab geometry & zero text-button collision with anti-scam footer
    local l_lan = make_mock_lobby({ mask_addr = sakura.mask_addr })
    l_lan.sub_modal = nil
    l_lan.view = "home"
    l_lan.net_tab = "lan"
    l_lan.transport.get_lan_rooms = function() return {} end
    l_lan.buttons = {}
    drawn_texts = {}
    lobby_draw.draw(l_lan)
    check_buttons_geom("home_lan_v231", l_lan.buttons, 0, 0, 780, 486)

    -- I8: copy_net_info anti-footgun: Sakura host without tunnel MUST NOT copy 127.0.0.1; LAN host copies real LAN IP
    local lobby_input = require("kr_mp.lobby_input")
    local copied_val, toast_val = nil, nil
    local mock_host = {
        role = "host", net_tab = "sakura", privacy_mask = false,
        set_focus = function() end,
        transport = { is_online = function() return false end, get_port = function() return 17777 end, is_port_drifted = function() return false end },
        sakura = { get_host_share_addr = function() return nil, nil, false end, mask_addr = sakura.mask_addr },
        server_host = { lan_ip = "192.168.1.88" },
        copy_to_clipboard = function(_, val, msg) copied_val = val; toast_val = msg end,
        overlay = { show_toast = function(_, msg) toast_val = msg end },
    }
    lobby_input.handle_button(mock_host, { id = "copy_net_info" })
    check("sakura_no_tunnel_never_copies_loopback", copied_val == nil, "should not copy: " .. tostring(copied_val))
    check("sakura_no_tunnel_warns_user", toast_val and toast_val:find("127.0.0.1", 1, true) ~= nil, tostring(toast_val))

    copied_val, toast_val = nil, nil
    mock_host.net_tab = "lan"
    lobby_input.handle_button(mock_host, { id = "copy_net_info" })
    check("lan_host_copies_real_lan_ip", copied_val == "192.168.1.88:17777", tostring(copied_val))

    -- I9: Verify Layer 3 Report Modal geometry (idle / error / done states: zero OOB, zero overlap)
    for _, st in ipairs({
        { tag = "report_modal_idle",  upload = { state = "idle",  note = "", server_addr = "127.0.0.1:17780" } },
        { tag = "report_modal_error", upload = { state = "error", note = "测试", server_addr = "127.0.0.1:17780", err = "连接超时" } },
        { tag = "report_modal_done",  upload = { state = "done",  note = "测试", server_addr = "127.0.0.1:17780", code = "R-4K9A", bytes = 26800 } },
    }) do
        local rl = make_mock_lobby({ mask_addr = sakura.mask_addr })
        rl.sub_modal = "report"
        rl.boot = {
            diagnostics = {
                upload = st.upload,
                sync_modal_defaults = function() end,
                get_preview_summary = function()
                    return { kind = "desync", urgent = true, has_blackbox = true, title = "已锁定同步异常黑匣子 · 第37关 (第 960 帧 DESYNC)", detail = "v2.5.0 · 文件校验:正常(46) · 已自动脱敏" }
                end,
                last_export_path = "C:\\Users\\Demo\\Desktop\\KR-MP报错_L37_T960.json",
            },
        }
        rl.buttons = {}
        drawn_texts = {}
        lobby_draw.draw(rl)
        check_buttons_geom(st.tag, rl.buttons, 0, 0, 780, 486)
    end
end

print(string.format("SUMMARY: %d passed, %d failed", pass_cnt, fail_cnt))
if fail_cnt > 0 then error("suite failed: " .. tostring(fail_cnt) .. " failures") end
