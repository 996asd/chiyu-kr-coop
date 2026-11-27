-- KR-MP 全中文双模式联机大厅（核心状态机、偏好/会话持久化、局域网/公网房间通信）
-- 子模块：
--   lobby_input.lua       : 键盘/鼠标/剪贴板输入与表驱动按钮分发
--   lobby_draw.lua        : 皇家战桌主界面渲染
--   lobby_draw_modals.lua : 新手指南/关卡/英雄/防御塔/语音调音弹窗渲染
--   autotest.lua          : M1/M2 多进程自动化联机回归驱动
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")
local lobby_prefs = require("kr_mp.lobby_prefs")
local lobby_input = require("kr_mp.lobby_input")
local lobby_draw = require("kr_mp.lobby_draw")
local autotest = require("kr_mp.autotest")

local DELAY_LABELS = {
    [2] = "缓冲:局域网100ms",
    [3] = "缓冲:低抖150ms",
    [4] = "缓冲:樱花200ms",
    [6] = "缓冲:抗抖300ms",
}

local function normalize_delay_turns(v)
    local n = tonumber(v) or proto.INPUT_DELAY_TURNS
    if n >= 6 then return 6 end
    if n >= 4 then return 4 end
    if n >= 3 then return 3 end
    return 2
end

local function copy_array(t)
    local out = {}
    for i = 1, #(t or {}) do out[i] = t[i] end
    return out
end

local function ensure_room_defaults(r)
    if not r then return end
    if not r.heroes or not r.heroes[1] then r.heroes = { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 } end
    if not r.heroes[2] then r.heroes[2] = catalog.DEFAULT_HERO_2 or 54 end
    if not r.towers or #r.towers == 0 then
        r.towers = copy_array(catalog.DEFAULT_TOWERS)
    end
    r.level_idx = tonumber(r.level_idx) or 101
    r.level_mode = tonumber(r.level_mode) or 1
    local d = tonumber(r.level_difficulty) or 2
    if d < 1 or d > 4 then d = 2 end
    r.level_difficulty = math.floor(d)
    r.econ_mode = r.econ_mode or "independent"
    r.tower_mode = r.tower_mode or "owned"
    r.input_delay_turns = normalize_delay_turns(r.input_delay_turns)
end

local lobby = {
    DELAY_LABELS = DELAY_LABELS,
    normalize_delay_turns = normalize_delay_turns,
    copy_array = copy_array,
    ensure_room_defaults = ensure_room_defaults,

    boot = nil,
    transport = nil,
    lockstep = nil,
    coop = nil,
    overlay = nil,
    voice = nil,
    sakura = nil,
    privacy_mask = false,
    sakura_show_wizard = false,
    sakura_wizard_dismissed = false,

    open = false,
    net_tab = "sakura", -- "sakura" | "lan" | "online"
    view = "home",      -- "home" | "room"
    sub_modal = nil,    -- nil | "guide" | "sakura" | "stages" | "hero1" | "hero2" | "towers" | "voice"
    guide_tab = 1,
    seen_guide = false,
    stage_pack_idx = 1,
    stage_page = 1,
    hero_pack_idx = 1,
    tower_pack_idx = 1,

    -- Input fields & focus
    focused_field = nil, -- nil | "sakura_ip" | "lan_ip" | "server" | "code" | "pw" | "sakura_token"
    sakura_ip_input = "",
    lan_ip_input = "127.0.0.1",
    ip_input = "",
    recent_addrs = {},
    server_input = "127.0.0.1:17780",
    code_input = "",
    pw_input = "",
    room_public = true,

    -- Online server & SakuraFrp direct reconnect state
    server_connected = false,
    server_ver = nil,
    server_voice_ok = true,
    online_rooms = {},
    online_room_code = nil,
    online_token = nil,
    saved_session = nil,
    pending_online_action = nil,
    pending_lan_join = nil,
    last_direct_host = nil,
    last_direct_port = nil,
    direct_auto_retry = nil,

    -- Responsive UI transform cache for exact mouse hit-testing
    _ui_scale = 1,
    _ui_ox = 0,
    _ui_oy = 0,

    -- Active room role & peers
    role = "none", -- "none" | "host" | "client"
    local_pid = 1,
    peer_connected = false,
    peer_ready = false,
    local_ready = false,
    peer_name = "等待加入...",

    room = {
        name = "王国保卫战合作房",
        level_idx = 101,
        level_mode = 1,
        level_difficulty = 2,
        econ_mode = "independent",
        tower_mode = "owned",
        input_delay_turns = proto.INPUT_DELAY_TURNS,
        heroes = { [1] = catalog.DEFAULT_HERO_1 or 53, [2] = catalog.DEFAULT_HERO_2 or 54 },
        towers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    },

    buttons = {},
    _consumed_down = false,
    font_title = nil,
    font = nil,
    font_small = nil,
    font_tiny = nil,
}

-- === Preferences, Clipboard & Reconnect Session Persistence (delegated to lobby_prefs.lua) ===

function lobby:load_prefs() return lobby_prefs.load_prefs(self) end
function lobby:save_prefs() return lobby_prefs.save_prefs(self) end
function lobby:paste_into_field(field_name) return lobby_prefs.paste_into_field(self, field_name) end
function lobby:copy_to_clipboard(text, toast_msg) return lobby_prefs.copy_to_clipboard(self, text, toast_msg) end
function lobby:load_saved_session() return lobby_prefs.load_saved_session(self) end
function lobby:save_session(code, pid, token) return lobby_prefs.save_online_session(self, code, pid, token) end
function lobby:save_direct_session(host, port, match_id, level_idx) return lobby_prefs.save_direct_session(self, host, port, match_id, level_idx) end
function lobby:clear_saved_session() return lobby_prefs.clear_saved_session(self) end

-- === Lifecycle & Navigation ===

function lobby:init(boot, transport, lockstep, coop, overlay)
    self.boot = boot
    self.transport = transport
    self.lockstep = lockstep
    self.coop = coop
    self.overlay = overlay

    local srv_env = os.getenv("KR_MP_SERVER")
    if srv_env and srv_env ~= "" then self.server_input = srv_env end
    local def_tab = os.getenv("KR_MP_DEFAULT_TAB")
    if def_tab == "online" or def_tab == "lan" or def_tab == "sakura" then
        self.net_tab = def_tab
    end

    self.font_title = fonts.get(17)
    self.font = fonts.get(13)
    self.font_small = fonts.get(12)
    self.font_tiny = fonts.get(11)

    self:load_prefs()
    self:load_saved_session()
    updater:init(boot, overlay)

    if os.getenv("KR_MP_OPEN_LOBBY") == "1" then
        self.open = true
        if self.net_tab == "lan" then
            self.transport:start_lan_scan()
        elseif self.net_tab == "sakura" and self.sakura then
            self.sakura:scan_local(true)
        end
        if not updater.checked_once then updater:start_check(false) end
    end

    autotest:init(self)
end

function lobby:set_focus(field)
    self.focused_field = field
    if proto.is_android() and love and love.keyboard and love.keyboard.setTextInput then
        pcall(love.keyboard.setTextInput, field ~= nil and self.open == true)
    end
end

function lobby:toggle()
    if self.coop and self.coop:is_active() then
        self.open = false
        self:set_focus(nil)
        return
    end
    self.open = not self.open
    self.sub_modal = nil
    if not self.open then self:set_focus(nil) end
    if self.open and self.view == "home" then
        self:load_saved_session()
        if self.sakura then self.sakura:scan_local(true) end
        if not updater.checked_once then updater:start_check(false) end
        if self.net_tab == "lan" then
            self.transport:start_lan_scan()
        elseif self.net_tab == "online" and self.server_connected then
            self:refresh_online_rooms()
        end
    elseif not self.open and self.role == "none" then
        self.transport:stop_lan_scan()
    end
end

function lobby:switch_tab(tab)
    if self.view ~= "home" or self.net_tab == tab then return end
    self:set_focus(nil)
    self.sub_modal = nil
    self.pending_online_action = nil
    self.pending_lan_join = nil
    local prev = self.net_tab
    self.net_tab = tab
    if tab == "sakura" then
        if prev == "online" then
            self.transport:close()
            self.server_connected = false
            self.transport:switch_mode("lan")
        end
        self.transport:stop_lan_scan()
        if self.sakura then self.sakura:scan_local(true) end
    elseif tab == "lan" then
        if prev == "online" then
            self.transport:close()
            self.server_connected = false
            self.transport:switch_mode("lan")
        end
        self.transport:start_lan_scan()
    else
        self.transport:stop_lan_scan()
        self.transport:switch_mode("online")
        self:load_saved_session()
        if not self.server_connected and not self.transport:is_connecting() then
            self:connect_online_server(self.server_input, true)
        end
    end
end

-- === LAN Mode Actions ===

function lobby:broadcast_room_state()
    if self.role ~= "host" then return end
    ensure_room_defaults(self.room)
    if self.transport:is_online() then
        self.transport:send({ t = "UPDATE_ROOM", room = self.room })
        return
    end
    self.transport:update_advert({
        name = self.room.name,
        level_idx = self.room.level_idx,
        players = self.peer_connected and 2 or 1,
    })
    if self.peer_connected then
        self.transport:send({ t = "ROOM_STATE", room = self.room, peer_ready = self.peer_ready })
    end
end

function lobby:host_lan_room()
    local port = tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
    local ok, res = self.transport:host_lan(port, {
        name = self.room.name,
        level_idx = self.room.level_idx,
        players = 1,
    })
    if not ok then
        self.overlay:show_toast("创建局域网房间失败：" .. tostring(res), 4)
        return false
    end
    self.role = "host"
    self.local_pid = 1
    self.online_room_code = nil
    self.online_token = nil
    self.peer_connected = false
    self.peer_ready = false
    self.local_ready = true
    self.peer_name = "等待 2P 加入..."
    self.view = "room"
    self.sub_modal = nil
    self.direct_auto_retry = nil
    if self.transport:is_port_drifted() then
        local req = self.transport:get_requested_port()
        self.overlay:show_toast(string.format(
            "警告：端口 %d 被占用，已自动改用端口 %s！樱花隧道指向 %d 将无法连入，请关闭占用程序或改隧道端口！",
            req, tostring(res), req), 10.0)
    else
        if self.sakura then self.sakura:scan_local(true) end
        local sk_disp = self.sakura and self.sakura:get_host_share_addr(tonumber(res) or port) or nil
        if sk_disp then
            local shown = self.privacy_mask and self.sakura.mask_addr(sk_disp) or sk_disp
            self.overlay:show_toast("战桌已就绪！检测到本机樱花 " .. shown .. "，点上方绿条一键复制给队友！", 3.6)
        else
            self.overlay:show_toast("樱花/局域网战桌已创建（TCP " .. tostring(res) .. " · 内置热续传），等待 2P 加入...", 2.5)
        end
    end
    return true
end

function lobby:on_lan_connected(target_ip, target_port)
    local info = self.pending_lan_join
    self.pending_lan_join = nil
    target_ip = target_ip or (info and info.ip) or self.last_direct_host or "127.0.0.1"
    target_port = tonumber(target_port) or (info and info.port) or self.last_direct_port or proto.DEFAULT_TCP_PORT
    self.last_direct_host = target_ip
    self.last_direct_port = target_port

    -- Tier 1: Mid-match 0.2s Zero-Reload Hot Resume
    if self.coop and self.coop:is_active() and self.lockstep and self.lockstep:is_active()
        and self.lockstep.phase == "WAIT_RECONNECT" then
        self.boot:log("[LOBBY] Direct Hot-Resume TCP reconnected -> sending HOT_RESUME_REQ")
        self.transport:send(self.lockstep:build_hot_resume_req())
        return
    end

    -- Tier 2: Fresh Launch Cold Reconnect to Direct Host
    if info and info.cold_reconnect then
        local sess = info.cold_reconnect
        self.role = "client"
        self.local_pid = 2
        self.online_room_code = nil
        self.online_token = nil
        self.peer_connected = true
        self.peer_name = "房主 (" .. tostring(target_ip) .. ")"
        self.boot:log("[LOBBY] Direct Cold-Reconnect TCP connected -> sending COLD_RECONNECT match_id=%s", tostring(sess.match_id))
        self.transport:send({
            t = "COLD_RECONNECT",
            match_id = sess.match_id,
            pid = 2,
            proto = proto.PROTOCOL_VER,
            mod_ver = proto.MOD_VERSION,
            fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
            script_hash = proto.compute_script_hash(),
            tick_len = TICK_LENGTH or (1 / 60),
        })
        self.overlay:show_toast("已重新接通房主，正在拉取历史战局高速追帧...", 4.0)
        return
    end

    self.role = "client"
    self.local_pid = 2
    self.online_room_code = nil
    self.online_token = nil
    self.peer_connected = true
    self.local_ready = true
    self.peer_name = "房主 (" .. tostring(target_ip) .. ")"
    self.view = "room"
    self.sub_modal = nil
    lobby_prefs.record_recent_addr(self, tostring(target_ip) .. ":" .. tostring(target_port))
    self:save_prefs()

    self.transport:send({
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "Player 2",
    })
    self.overlay:show_toast("已连接到房主 " .. tostring(target_ip) .. ":" .. tostring(target_port), 2.0)
end

function lobby:reconnect_direct_session(sess)
    sess = sess or self.saved_session or self:load_saved_session()
    if not sess or sess.mode ~= "direct" or not sess.host or not sess.match_id then
        self.overlay:show_toast("未找到可重连的樱花/局域网直连记录！", 3)
        return false
    end
    self.pending_lan_join = { ip = sess.host, port = tonumber(sess.port) or proto.DEFAULT_TCP_PORT, cold_reconnect = sess }
    local ok, st = self.transport:join_lan(sess.host, sess.port, false)
    if not ok then
        self.pending_lan_join = nil
        self.overlay:show_toast("重连房主失败：" .. tostring(st), 4.0)
        return false
    end
    if st == "connected" then
        self:on_lan_connected(sess.host, sess.port)
    else
        self.overlay:show_toast("正在重连房主 " .. tostring(sess.host) .. ":" .. tostring(sess.port) .. "...", 3.0)
    end
    return true
end

function lobby:join_lan_room(ip, port)
    local raw_addr = ip
    if not raw_addr or #tostring(raw_addr) == 0 then
        raw_addr = (self.net_tab == "sakura") and self.sakura_ip_input or self.lan_ip_input
    end
    local primary, fallback = proto.split_fallback_addr(raw_addr or "")
    if primary == "" then
        if self.net_tab == "sakura" and not ip then
            self.overlay:show_toast("请先粘贴房主的樱花映射地址（如 frp-xxx.com:12345）！", 3.0)
            return false
        end
        primary = "127.0.0.1"
    end
    local target_ip = primary
    local target_port = tonumber(port) or tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
    local parsed_ip, parsed_port = target_ip:match("^([^:]+):(%d+)$")
    if parsed_ip and parsed_port then
        target_ip = parsed_ip
        target_port = tonumber(parsed_port)
    end

    local connect_arg = fallback and (target_ip .. ":" .. tostring(target_port) .. "|" .. fallback) or target_ip
    self.pending_lan_join = { ip = target_ip, port = target_port, fallback = fallback }
    local ok, status_or_err = self.transport:join_lan(connect_arg, target_port)
    if not ok then
        self.pending_lan_join = nil
        self.overlay:show_toast("连接房主失败：" .. tostring(status_or_err), 4.5)
        return false
    end

    if status_or_err == "connected" then
        self:on_lan_connected(target_ip, target_port)
    else
        local shown = (self.privacy_mask and self.sakura)
            and self.sakura.mask_addr(tostring(target_ip) .. ":" .. tostring(target_port))
            or (tostring(target_ip) .. ":" .. tostring(target_port))
        local tag = fallback and "（免费 P2P 优先，不通自动切樱花中继）" or ""
        self.overlay:show_toast("正在连接房主 " .. shown .. tag .. "...", 2.8)
    end
    return true
end

-- === Online Relay Server Actions (100% Non-Blocking) ===

function lobby:on_online_connected()
    self.server_connected = true
    self.transport:send({
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "Player",
    })

    local act = self.pending_online_action
    self.pending_online_action = nil
    if not act then return end
    if act.kind == "list_rooms" then
        self.transport:send({ t = "LIST_ROOMS" })
    elseif act.kind == "create_room" then
        self:send_create_online_room(act.password, act.is_public)
    elseif act.kind == "join_room" then
        self:send_join_online_room(act.code, act.password)
    elseif act.kind == "reconnect" and act.sess then
        self:send_reconnect_online(act.sess)
    end
end

function lobby:connect_online_server(addr, silent_fail)
    local target = (addr and addr ~= "") and addr or self.server_input
    local ok, status_or_err = self.transport:connect_online(target, proto.DEFAULT_ONLINE_PORT, silent_fail)
    if not ok then
        self.server_connected = false
        self.pending_online_action = nil
        if not silent_fail then
            self.overlay:show_toast("连接公网服务器失败：" .. tostring(status_or_err), 4.5)
        end
        return false
    end
    if status_or_err == "connected" then
        self:on_online_connected()
    else
        self.server_connected = false
        if not silent_fail then
            self.overlay:show_toast("正在连接公网服务器 " .. tostring(target) .. "...", 2.5)
        end
    end
    return true
end

function lobby:ensure_online_connected(action)
    if self.transport:is_online() and self.transport:is_connected() and self.server_connected then
        return true
    end
    if action then self.pending_online_action = action end
    if self.transport:is_online() and self.transport:is_connecting() then
        if self.transport.online_backend then
            self.transport.online_backend.connect_silent = false
        end
        return false, "connecting"
    end
    local ok = self:connect_online_server(self.server_input, false)
    if ok and self.server_connected then return true end
    return false, ok and "connecting" or "failed"
end

function lobby:refresh_online_rooms()
    local ready = self:ensure_online_connected({ kind = "list_rooms" })
    if not ready then return true end
    self.transport:send({ t = "LIST_ROOMS" })
    return true
end

function lobby:send_create_online_room(password, is_public)
    ensure_room_defaults(self.room)
    self.transport:send({
        t = "CREATE_ROOM",
        name = self.room.name,
        password = (password ~= nil) and password or self.pw_input or "",
        public = (is_public ~= nil) and is_public or self.room_public,
        room = self.room,
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        player_name = "Player 1",
    })
end

function lobby:create_online_room(password, is_public)
    local pw = (password ~= nil) and password or self.pw_input or ""
    local pub = (is_public ~= nil) and is_public or self.room_public
    local ready, st = self:ensure_online_connected({ kind = "create_room", password = pw, is_public = pub })
    if not ready then return st == "connecting" end
    self:send_create_online_room(pw, pub)
    return true
end

function lobby:send_join_online_room(clean_code, password)
    self.transport:send({
        t = "JOIN_ROOM",
        code = clean_code,
        password = (password ~= nil) and password or self.pw_input or "",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        player_name = "Player 2",
    })
end

function lobby:join_online_room(code, password)
    local clean_code = tostring(code or self.code_input or ""):upper():gsub("%s+", "")
    if #clean_code < 3 then
        self.overlay:show_toast("请先输入 4 位房间码！", 3)
        return false
    end
    local pw = (password ~= nil) and password or self.pw_input or ""
    local ready, st = self:ensure_online_connected({ kind = "join_room", code = clean_code, password = pw })
    if not ready then return st == "connecting" end
    self:send_join_online_room(clean_code, pw)
    return true
end

function lobby:send_reconnect_online(sess)
    self.online_room_code = sess.code
    self.online_token = sess.token
    self.local_pid = tonumber(sess.pid) or 2
    self.role = (self.local_pid == 1) and "host" or "client"
    self.boot:log("[LOBBY] Sending RECONNECT room=%s pid=%d server=%s", sess.code, self.local_pid, sess.server)
    self.transport:send({
        t = "RECONNECT",
        code = sess.code,
        pid = self.local_pid,
        token = sess.token,
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
    })
    self.overlay:show_toast("正在向房间 #" .. tostring(sess.code) .. " 发起断线重连...", 4)
end

function lobby:reconnect_online_session(sess)
    sess = sess or self.saved_session or self:load_saved_session()
    if not sess then
        self.overlay:show_toast("未找到可重连的公网对局记录！", 3)
        return false
    end
    self.pending_online_action = { kind = "reconnect", sess = sess }
    if not self:connect_online_server(sess.server, false) then
        self.pending_online_action = nil
        return false
    end
    return true
end

function lobby:leave_room()
    self.direct_auto_retry = nil
    if self.transport:is_online() and self.transport:is_connected() then
        self.transport:send({ t = "LEAVE_ROOM" })
    end
    if self.coop and self.coop:is_active() then
        self.coop:leave_match()
    end
    self:clear_saved_session()
    self.role = "none"
    self.peer_connected = false
    self.peer_ready = false
    self.local_ready = false
    self.online_room_code = nil
    self.online_token = nil
    self.view = "home"
    self.sub_modal = nil

    if self.net_tab == "sakura" or self.net_tab == "lan" then
        self.transport:close()
        if self.open and self.net_tab == "lan" then
            self.transport:start_lan_scan()
        elseif self.open and self.net_tab == "sakura" and self.sakura then
            self.sakura:scan_local(true)
        end
        self.overlay:show_toast(self.net_tab == "sakura" and "已退出樱花联机房间。" or "已退出局域网房间。", 1.8)
    else
        if self.server_connected and self.transport:is_connected() then
            self:refresh_online_rooms()
        end
        self.overlay:show_toast("已退出公网房间。", 1.8)
    end
end

function lobby:return_to_lobby()
    if not self.transport or not self.transport:is_connected() then
        self:leave_room()
        self.open = true
        return false
    end
    self.transport:send({ t = "RETURN_LOBBY", pid = self.local_pid })
    if not self.transport:is_online() then
        self:on_return_lobby(self.local_pid)
    end
    return true
end

function lobby:on_return_lobby(by_pid, room_data)
    self.direct_auto_retry = nil
    if self.overlay then self.overlay.voice_panel_open = false end
    if self.coop and self.coop:is_active() then
        self.coop:leave_match()
    end
    if not self.transport:is_online() then
        self:clear_saved_session()
    end
    if room_data then
        self.room = room_data
        ensure_room_defaults(self.room)
    end
    if main and main.handler and main.handler.active_item == game then
        main.handler.next_item_name = "slots"
        main.handler.next_item_args = {}
    end
    self.peer_connected = true
    self.local_ready = true
    self.peer_ready = true
    self.view = "room"
    self.sub_modal = nil
    self.open = true
    if self.role == "host" and not self.transport:is_online() then
        self:broadcast_room_state()
    end
    self.boot:log("[LOBBY] Returned to War Table without disconnecting (by P%d)", tonumber(by_pid) or 0)
    self.overlay:show_toast(string.format("%dP 返回战桌（连接保持不断），可直接换关或再次出征！", tonumber(by_pid) or 0), 3.0)
end

function lobby:host_start_match()
    if self.role ~= "host" or not self.peer_connected then
        self.overlay:show_toast("请等待 2P 队友加入后再开局！", 3)
        return false
    end
    ensure_room_defaults(self.room)
    if #self.room.towers < 1 then
        self.overlay:show_toast("请至少选择 1 座防御塔！", 3)
        return false
    end

    local seed = (os.time() % 900000) + 100000
    local match_id = string.format("%06d-%06d", os.time() % 1000000, math.random(100000, 999999))
    local slot_snap = self.coop:build_host_slot_snapshot(self.room.heroes, self.room.towers)
    local delay_turns = normalize_delay_turns(self.room.input_delay_turns)
    local measured_rtt = (self.transport and self.transport:get_rtt_ms()) or 0
    if not autotest:is_active() then
        if delay_turns < 6 and measured_rtt >= 110 then
            delay_turns = 6
            self.room.input_delay_turns = 6
            self.overlay:show_toast(string.format("检测到较高延迟 (%dms)，已自动启用【抗抖300ms】缓冲！", measured_rtt), 2.8)
        elseif delay_turns < 4 and measured_rtt >= 25 then
            delay_turns = 4
            self.room.input_delay_turns = 4
            self.overlay:show_toast(string.format("检测到跨网延迟 (%dms)，已自动启用【樱花200ms】防卡顿缓冲！", measured_rtt), 2.8)
        end
    end
    self:save_prefs()
    local cfg = {
        match_id = match_id,
        level_idx = self.room.level_idx,
        level_mode = self.room.level_mode or 1,
        level_difficulty = self.room.level_difficulty or 2,
        seed = seed,
        tick_len = TICK_LENGTH or (1 / 60),
        turn_ticks = proto.TURN_TICKS,
        input_delay_turns = delay_turns,
        econ_mode = self.room.econ_mode,
        tower_mode = self.room.tower_mode,
        heroes = { self.room.heroes[1], self.room.heroes[2] },
        towers = copy_array(self.room.towers),
        slot_snapshot = slot_snap,
    }

    self.boot:log("[LOBBY] Host launching 2P Co-op match (online=%s, level=%d, seed=%d, delay=%d, econ=%s, tower=%s, deck=%d)",
        tostring(self.transport:is_online()), cfg.level_idx, cfg.seed, cfg.input_delay_turns, cfg.econ_mode, cfg.tower_mode, #cfg.towers)
    self.transport:send({ t = "START_MATCH", cfg = cfg })

    if not self.transport:is_online() then
        self.open = false
        self.sub_modal = nil
        self.coop:prepare_match(1, cfg)
    end
    return true
end

function lobby:toggle_ready(force_ready)
    if self.view ~= "room" or self.role ~= "client" then return false end
    if not self.transport or not self.transport:is_connected() then return false end
    local next_state = (type(force_ready) == "boolean") and force_ready or (not self.local_ready)
    if self.local_ready == next_state then return self.local_ready end
    self.local_ready = next_state
    self.transport:send({
        t = "SET_GUEST",
        ready = self.local_ready,
        hero_idx = self.room and self.room.heroes and self.room.heroes[2] or (catalog.DEFAULT_HERO_2 or 54),
    })
    return self.local_ready
end

-- === Incoming Network Message Router (Table-Driven) ===

local MSG_HANDLERS = {}

function MSG_HANDLERS.VOICE(self, msg)
    if self.voice then self.voice:on_voice_message(msg) end
end

function MSG_HANDLERS.SERVER_HELLO(self, msg)
    self.server_connected = true
    self.server_ver = msg.server_ver
    self.server_voice_ok = (msg.voice_ok == true)
    self.online_rooms = msg.rooms or {}
    updater:note_server_version(msg.server_ver)
    self.boot:log("[LOBBY] Server hello OK (ver=%s, voice_ok=%s, rooms=%d)",
        tostring(msg.server_ver), tostring(self.server_voice_ok), #self.online_rooms)
end

function MSG_HANDLERS.ROOM_LIST(self, msg)
    self.online_rooms = msg.rooms or {}
end

function MSG_HANDLERS.ROOM_CREATED(self, msg)
    self.role = "host"
    self.local_pid = 1
    self.online_room_code = msg.code
    self.online_token = msg.token
    if msg.room then self.room = msg.room end
    ensure_room_defaults(self.room)
    self.peer_connected = false
    self.peer_ready = false
    self.local_ready = true
    self.peer_name = "等待 2P 加入..."
    self.view = "room"
    self.sub_modal = nil
    self:save_session(msg.code, 1, msg.token)
    self.boot:log("[LOBBY] Created Online Room #%s (token saved)", tostring(msg.code))
    self.overlay:show_toast("公网房间 #" .. tostring(msg.code) .. " 已创建！把房间码发给好友即可加入！", 2.8)
end

function MSG_HANDLERS.ROOM_JOINED(self, msg)
    self.role = "client"
    self.local_pid = tonumber(msg.pid) or 2
    self.online_room_code = msg.code
    self.online_token = msg.token
    if msg.room then self.room = msg.room end
    ensure_room_defaults(self.room)
    self.peer_connected = true
    self.local_ready = true
    self.peer_ready = true
    self.peer_name = tostring(msg.host_name or "1P 房主")
    self.view = "room"
    self.sub_modal = nil
    self:save_session(msg.code, self.local_pid, msg.token)
    self.boot:log("[LOBBY] Joined Online Room #%s as P%d", tostring(msg.code), self.local_pid)
    self.overlay:show_toast("已加入公网房间 #" .. tostring(msg.code) .. "（你是 2P 红方）！", 2.2)
end

function MSG_HANDLERS.PEER_JOINED(self, msg)
    self.peer_connected = true
    self.peer_ready = (msg.peer_ready ~= false)
    self.peer_name = tostring(msg.name or "2P 队友")
    if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
    self.overlay:show_toast("2P 队友已加入房间 #" .. tostring(self.online_room_code) .. "，可以开局了！", 2.2)
end

function MSG_HANDLERS.PEER_LEFT(self)
    self.peer_connected = false
    self.peer_ready = false
    self.peer_name = "等待 2P 加入..."
    self.overlay:show_toast("2P 队友离开了房间。", 3.5)
end

function MSG_HANDLERS.ROOM_CLOSED(self, msg)
    self:clear_saved_session()
    if self.coop and self.coop:is_active() then self.coop:leave_match() end
    self.role = "none"
    self.peer_connected = false
    self.online_room_code = nil
    self.online_token = nil
    self.view = "home"
    self.sub_modal = nil
    self.open = true
    self:refresh_online_rooms()
    self.overlay:show_toast("房间已关闭：" .. tostring(msg.reason or "房主退出"), 5)
end

function MSG_HANDLERS.RECONNECT_STATE(self, msg)
    if not msg.cfg then return end
    self.local_pid = tonumber(msg.pid) or self.local_pid
    self.role = (self.local_pid == 1) and "host" or "client"
    self.peer_connected = true
    self.direct_auto_retry = nil
    if msg.direct then
        if self.last_direct_host and msg.match_id then
            self:save_direct_session(self.last_direct_host, self.last_direct_port or proto.DEFAULT_TCP_PORT, msg.match_id, msg.cfg.level_idx)
        end
        self.boot:log("[LOBBY] Received direct RECONNECT_STATE match_id=%s pid=%d target_turn=%s",
            tostring(msg.match_id), self.local_pid, tostring(msg.target_turn))
    else
        self.online_room_code = msg.code
        self.online_token = msg.token
        self:save_session(msg.code, self.local_pid, msg.token)
        self.boot:log("[LOBBY] Received RECONNECT_STATE room=%s pid=%d target_turn=%s",
            tostring(msg.code), self.local_pid, tostring(msg.target_turn))
    end
    self.open = false
    self.sub_modal = nil
    self.coop:prepare_match(self.local_pid, msg.cfg, msg)
end

function MSG_HANDLERS.HOT_RESUME_REQ(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    if self.lockstep and self.lockstep:handle_hot_resume_req(msg) then
        self.peer_connected = true
        self.peer_ready = true
        if autotest.on_hot_resumed then autotest:on_hot_resumed() end
    else
        self.transport:send({ t = "ERROR", msg = "房主当前对局已结束或局号不匹配，无法热续传。" })
        self.transport:drop_peer_socket("hot_resume_mismatch", true)
    end
end

function MSG_HANDLERS.HOT_RESUME_OK(self, msg)
    if self.role ~= "client" or self.transport:is_online() then return end
    if self.lockstep and self.lockstep:handle_hot_resume_ok(msg) then
        self.peer_connected = true
        self.direct_auto_retry = nil
        if autotest.on_hot_resumed then autotest:on_hot_resumed() end
    end
end

function MSG_HANDLERS.COLD_RECONNECT(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    local my_hash = proto.compute_script_hash()
    if msg.script_hash and msg.script_hash ~= my_hash then
        self.transport:send({ t = "ERROR", msg = "重连失败：核心脚本哈希不一致！" })
        self.transport:drop_peer_socket("cold_reconnect_hash_mismatch", true)
        return
    end
    if self.lockstep and self.lockstep:handle_cold_reconnect_req(msg) then
        self.peer_connected = true
    else
        self.transport:send({ t = "ERROR", msg = "直连追帧重连失败：房主对局已结束或局号不匹配。" })
        self.transport:drop_peer_socket("cold_reconnect_reject", true)
    end
end

function MSG_HANDLERS.RETURN_LOBBY(self, msg)
    self:on_return_lobby(msg.pid, msg.room)
end

function MSG_HANDLERS.HELLO(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    if self.coop and self.coop:is_active() then
        self.transport:send({ t = "ERROR", msg = "房主正在对局等待原队友重连，请稍候再试！" })
        self.transport:drop_peer_socket("busy_in_match", true)
        return
    end
    local my_fl = tostring(KR_FL_VERSION or "8.2.0")
    local my_hash = proto.compute_script_hash()
    if msg.proto ~= proto.PROTOCOL_VER or msg.fl_ver ~= my_fl then
        self.transport:send({
            t = "ERROR",
            msg = string.format("版本不匹配！房主 FL=%s 协议=%d，客机 FL=%s 协议=%s",
                my_fl, proto.PROTOCOL_VER, tostring(msg.fl_ver), tostring(msg.proto)),
        })
        self.overlay:show_toast("已拒绝客机：游戏或补丁版本不一致！", 4)
        return
    end
    if msg.script_hash and msg.script_hash ~= my_hash then
        self.transport:send({
            t = "ERROR",
            msg = string.format("核心脚本哈希不一致！房主=%s 客机=%s", my_hash, tostring(msg.script_hash)),
        })
        self.overlay:show_toast("已拒绝客机：游戏核心脚本不一致！", 4)
        return
    end
    if msg.tick_len and math.abs(msg.tick_len - (TICK_LENGTH or 1 / 60)) > 1e-4 then
        self.transport:send({ t = "ERROR", msg = "帧率设置不一致！请双方统一以 60 FPS 启动。" })
        return
    end
    self.peer_connected = true
    self.peer_ready = true
    self.peer_name = tostring(msg.name or "2P 队友")
    self.transport:send({ t = "WELCOME", pid = 2, room = self.room })
    self:broadcast_room_state()
    self.overlay:show_toast("2P 队友已加入局域网房间，可以开局了！", 2.2)
end

function MSG_HANDLERS.WELCOME(self, msg)
    if self.role ~= "client" then return end
    self.local_pid = tonumber(msg.pid) or 2
    if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
    self.peer_connected = true
    self.overlay:show_toast("已加入局域网房间（你是 2P 红方）！", 2.0)
end

function MSG_HANDLERS.ROOM_STATE(self, msg)
    if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
    if msg.peer_connected ~= nil then self.peer_connected = msg.peer_connected end
    if msg.peer_ready ~= nil then self.peer_ready = msg.peer_ready end
    if self.role == "host" and msg.guest_name then
        self.peer_name = msg.guest_name
    elseif self.role == "client" and msg.host_name then
        self.peer_name = msg.host_name
    end
end

function MSG_HANDLERS.SET_GUEST(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    if msg.ready ~= nil then self.peer_ready = msg.ready end
    if msg.hero_idx then
        self.room.heroes[2] = tonumber(msg.hero_idx) or self.room.heroes[2]
    end
    self:broadcast_room_state()
end

function MSG_HANDLERS.START_MATCH(self, msg)
    if not msg.cfg then return end
    self.boot:log("[LOBBY] Received START_MATCH (pid=%d, level=%d, seed=%d, match_id=%s)",
        self.local_pid, msg.cfg.level_idx or 0, msg.cfg.seed or 0, tostring(msg.cfg.match_id))
    if msg.code and self.online_token then
        self:save_session(msg.code, self.local_pid, self.online_token)
    elseif not self.transport:is_online() and self.local_pid == 2 and self.last_direct_host and msg.cfg.match_id then
        self:save_direct_session(self.last_direct_host, self.last_direct_port or proto.DEFAULT_TCP_PORT, msg.cfg.match_id, msg.cfg.level_idx)
    end
    self.open = false
    self.sub_modal = nil
    self.coop:prepare_match(self.local_pid, msg.cfg)
end

function MSG_HANDLERS.ERROR(self, msg)
    self.boot:log("[LOBBY] Server/Host ERROR: %s", tostring(msg.msg))
    self.overlay:show_toast("提示：" .. tostring(msg.msg), 5)
end

function lobby:on_message(msg)
    if not msg or not msg.t then return end
    if self.lockstep and self.lockstep:on_message(msg) then
        if msg.t == "PEER_RECONNECTED" or (msg.t == "RECONNECT_DONE" and self.local_pid == 1 and not self.transport:is_online()) then
            self.peer_connected = true
            autotest:on_peer_reconnected()
        end
        return
    end
    local fn = MSG_HANDLERS[msg.t]
    if fn then fn(self, msg) end
end

function lobby:update(dt)
    updater:update(dt)
    local now = (love and love.timer and love.timer.getTime()) or os.clock()
    if self.lockstep and self.lockstep.update_timers then
        self.lockstep:update_timers(now)
    end
    if self.transport and self.transport.lan_backend then
        local in_match = (self.coop and self.coop:is_active()) == true
        local waiting_rc = (self.lockstep ~= nil and self.lockstep.phase == "WAIT_RECONNECT")
        self.transport.lan_backend.accept_enabled = (not in_match) or waiting_rc
    end

    -- Direct / SakuraFrp 2P silent background auto-retry every 2s during WAIT_RECONNECT
    if self.direct_auto_retry and self.lockstep and self.lockstep:is_active()
        and self.lockstep.phase == "WAIT_RECONNECT" and not self.transport:is_online() then
        if not self.transport:is_connected() and not self.transport:is_connecting() and now >= self.direct_auto_retry.next_try_ts then
            self.direct_auto_retry.attempt = self.direct_auto_retry.attempt + 1
            self.direct_auto_retry.next_try_ts = now + 2.0
            self.boot:log("[LOBBY] Direct Hot-Resume auto-retry #%d -> %s:%d",
                self.direct_auto_retry.attempt, tostring(self.direct_auto_retry.host), tonumber(self.direct_auto_retry.port) or 17777)
            local ok, st = self.transport:join_lan(self.direct_auto_retry.host, self.direct_auto_retry.port, true)
            if ok and st == "connected" then
                self:on_lan_connected(self.direct_auto_retry.host, self.direct_auto_retry.port)
            end
        end
    elseif self.direct_auto_retry and (not self.lockstep or self.lockstep.phase ~= "WAIT_RECONNECT") then
        self.direct_auto_retry = nil
    end

    local events = self.transport:poll()
    for i = 1, #events do
        local ev = events[i]
        if ev.type == "peer_connected" then
            self.peer_connected = true
            self.peer_name = "正在握手 (" .. tostring(ev.ip) .. ")..."
        elseif ev.type == "lan_connected" then
            self:on_lan_connected(ev.ip, ev.port)
        elseif ev.type == "lan_fallback" then
            self.overlay:show_toast("免费 P2P 端口导出未通，已自动切回樱花中继线路继续连接...", 3.0)
        elseif ev.type == "lan_connect_failed" then
            self.pending_lan_join = nil
            if not ev.silent then
                self.overlay:show_toast("连接房主失败：" .. tostring(ev.reason), 5.0)
            end
            autotest:on_lan_connect_failed()
        elseif ev.type == "peer_disconnected" then
            self.peer_connected = false
            self.peer_ready = false
            self.peer_name = "已断开"
            if self.lockstep and self.lockstep:is_active() then
                local ph = self.lockstep.phase
                local can_hot = (ph == "RUNNING" or ph == "PAUSED" or ph == "WAIT_RECONNECT")
                self.lockstep:on_peer_disconnected(ev.reason, can_hot, 180, true)
                if can_hot and self.local_pid == 2 and self.last_direct_host then
                    if self.direct_auto_retry then
                        self.direct_auto_retry.next_try_ts = now + 2.0
                    else
                        self.direct_auto_retry = {
                            host = self.last_direct_host,
                            port = self.last_direct_port or proto.DEFAULT_TCP_PORT,
                            next_try_ts = now + 1.0,
                            attempt = 0,
                        }
                    end
                end
            elseif ev.reason == "early_eof_refused" and self.role == "client" then
                self.role = "none"
                self.view = "home"
                self.sub_modal = nil
                self.transport:close()
                if self.open then self.transport:start_lan_scan() end
                self.overlay:show_toast("已连到樱花节点，但房主游戏未就绪！请确认：① 房主已点「创建房间」；② 樱花本地端口填的是 17777！", 6.5)
            else
                self.overlay:show_toast("队友已断开连接。", 3.5)
            end
        elseif ev.type == "server_connected" then
            self:on_online_connected()
        elseif ev.type == "server_connect_failed" then
            self.server_connected = false
            self.pending_online_action = nil
            if not ev.silent then
                self.overlay:show_toast("连接公网服务器失败：" .. tostring(ev.reason), 4.5)
            end
            autotest:on_server_connect_failed()
        elseif ev.type == "server_disconnected" then
            self.server_connected = false
            self.pending_online_action = nil
            if self.lockstep and self.lockstep:is_active() then
                self.lockstep:on_peer_disconnected("与公网中继服断开连接", false)
            else
                self.overlay:show_toast("与公网服务器断开连接。", 4)
            end
        elseif ev.type == "msg" then
            self:on_message(ev.msg)
        end
    end

    if autotest:is_active() then
        autotest:update(self, dt)
    end
end

-- === Delegated Input & Rendering Entrypoints ===

function lobby:handle_button(btn) return lobby_input.handle_button(self, btn) end
function lobby:textinput(t) return lobby_input.textinput(self, t) end
function lobby:keypressed(key) return lobby_input.keypressed(self, key) end
function lobby:mousepressed(x, y, button) return lobby_input.mousepressed(self, x, y, button) end
function lobby:mousereleased(x, y, button) return lobby_input.mousereleased(self, x, y, button) end
function lobby:draw() return lobby_draw.draw(self) end

return lobby
