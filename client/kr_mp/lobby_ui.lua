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
local lobby_input = require("kr_mp.lobby_input")
local lobby_draw = require("kr_mp.lobby_draw")
local autotest = require("kr_mp.autotest")

local DELAY_LABELS = {
    [2] = "缓冲:局域网100ms",
    [4] = "缓冲:樱花200ms",
    [6] = "缓冲:抗抖300ms",
}

local function normalize_delay_turns(v)
    local n = tonumber(v) or proto.INPUT_DELAY_TURNS
    if n >= 6 then return 6 end
    if n >= 4 then return 4 end
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

    open = false,
    net_tab = "lan", -- "lan" | "online"
    view = "home",   -- "home" | "room"
    sub_modal = nil, -- nil | "guide" | "stages" | "hero1" | "hero2" | "towers" | "voice"
    guide_tab = 1,
    seen_guide = false,
    stage_pack_idx = 1,
    stage_page = 1,
    hero_pack_idx = 1,
    tower_pack_idx = 1,

    -- Input fields & focus
    focused_field = nil, -- nil | "ip" | "server" | "code" | "pw"
    ip_input = "127.0.0.1",
    server_input = "127.0.0.1:17780",
    code_input = "",
    pw_input = "",
    room_public = true,

    -- Online server connection & room state
    server_connected = false,
    server_ver = nil,
    server_voice_ok = true,
    online_rooms = {},
    online_room_code = nil,
    online_token = nil,
    saved_session = nil,
    pending_online_action = nil,
    pending_lan_join = nil,

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

-- === Preferences, Clipboard & Reconnect Session Persistence ===

local function get_prefs_path()
    return proto.path_join(proto.get_writable_dir(), "kr_mp_prefs.json")
end

function lobby:load_prefs()
    if autotest:is_active() or os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") then return end
    local f = io.open(get_prefs_path(), "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    local obj = proto.decode(raw)
    if type(obj) ~= "table" then return end
    if type(obj.ip_input) == "string" and #obj.ip_input > 0 then
        self.ip_input = obj.ip_input:sub(1, 80)
    end
    if type(obj.server_input) == "string" and #obj.server_input > 0 and not os.getenv("KR_MP_SERVER") then
        self.server_input = obj.server_input:sub(1, 80)
    end
    if obj.input_delay_turns ~= nil then
        self.room.input_delay_turns = normalize_delay_turns(obj.input_delay_turns)
    end
    if obj.show_tower_marks ~= nil and self.coop then
        self.coop.show_tower_marks = (obj.show_tower_marks ~= false)
    end
    if self.voice then
        if type(obj.voice_mode) == "string" then self.voice:set_mode(obj.voice_mode) end
        if tonumber(obj.voice_mic_gain) then self.voice:set_mic_gain(tonumber(obj.voice_mic_gain)) end
        if tonumber(obj.voice_peer_volume) then self.voice:set_peer_volume(tonumber(obj.voice_peer_volume)) end
        if obj.voice_peer_muted ~= nil then self.voice.peer_muted = (obj.voice_peer_muted == true) end
        if type(obj.voice_indicator_style) == "string" then self.voice:set_indicator_style(obj.voice_indicator_style) end
    end
    if obj.seen_guide ~= nil then
        self.seen_guide = (obj.seen_guide == true)
    end
end

function lobby:save_prefs()
    if autotest:is_active() or os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") then return end
    local prefs = {
        ip_input = self.ip_input,
        server_input = self.server_input,
        input_delay_turns = normalize_delay_turns(self.room and self.room.input_delay_turns),
        show_tower_marks = (self.coop == nil) or (self.coop.show_tower_marks ~= false),
        voice_mode = self.voice and self.voice.mode or "ptt",
        voice_mic_gain = self.voice and self.voice.mic_gain or 1.0,
        voice_peer_volume = self.voice and self.voice.peer_volume or 1.0,
        voice_peer_muted = self.voice and (self.voice.peer_muted == true) or false,
        voice_indicator_style = self.voice and self.voice.indicator_style or "compact",
        seen_guide = (self.seen_guide == true),
    }
    local f = io.open(get_prefs_path(), "w")
    if f then
        f:write(proto.encode(prefs))
        f:flush()
        f:close()
    end
end

function lobby:paste_into_field(field_name)
    if not love or not love.system or not love.system.getClipboardText then
        self.overlay:show_toast("当前环境不支持读取剪贴板，请手动输入。", 2.5)
        return false
    end
    local clip = love.system.getClipboardText()
    if type(clip) ~= "string" or #clip == 0 then
        self.overlay:show_toast("剪贴板为空！请先复制樱花映射或服务器地址。", 2.5)
        return false
    end
    if field_name == "ip" then
        local clean = proto.sanitize_addr(clip):sub(1, 80)
        if #clean > 0 then
            self.ip_input = clean
            self:save_prefs()
            self.overlay:show_toast("已粘贴直连/映射地址：" .. clean, 3.0)
            return true
        end
    elseif field_name == "server" then
        local clean = proto.sanitize_addr(clip):sub(1, 80)
        if #clean > 0 then
            self.server_input = clean
            self:save_prefs()
            self.overlay:show_toast("已粘贴服务器/映射地址：" .. clean, 3.0)
            return true
        end
    elseif field_name == "code" then
        local clean = clip:upper():gsub("[^%dA-Z]", ""):sub(1, 6)
        if #clean > 0 then self.code_input = clean; return true end
    elseif field_name == "pw" then
        local clean = clip:gsub("[^%w%-%_@#]", ""):sub(1, 16)
        if #clean > 0 then self.pw_input = clean; return true end
    end
    self.overlay:show_toast("剪贴板里未识别到有效地址，请重新复制。", 2.8)
    return false
end

local function get_session_path()
    local env_p = os.getenv("KR_MP_SESSION_FILE")
    if env_p and env_p ~= "" then return env_p end
    local log_file = os.getenv("KR_MP_LOG_FILE")
    if log_file then
        local log_dir = log_file:match("^(.*)[/\\][^/\\]+$")
        if log_dir then return proto.path_join(log_dir, "last_session.json") end
    end
    return proto.path_join(proto.get_writable_dir(), "kr_mp_last_session.json")
end

function lobby:load_saved_session()
    local f = io.open(get_session_path(), "r")
    if not f then
        self.saved_session = nil
        return nil
    end
    local raw = f:read("*a")
    f:close()
    local obj = proto.decode(raw)
    if obj and obj.code and obj.token and obj.server and obj.pid then
        self.saved_session = obj
        return obj
    end
    self.saved_session = nil
    return nil
end

function lobby:save_session(code, pid, token)
    if not code or not token then return end
    local sess = {
        server = self.transport:get_server_addr() or self.server_input,
        code = code,
        pid = pid,
        token = token,
        level_idx = self.room and self.room.level_idx or 101,
    }
    self.saved_session = sess
    local f = io.open(get_session_path(), "w")
    if f then
        f:write(proto.encode(sess))
        f:flush()
        f:close()
    end
end

function lobby:clear_saved_session()
    self.saved_session = nil
    pcall(os.remove, get_session_path())
end

-- === Lifecycle & Navigation ===

function lobby:init(boot, transport, lockstep, coop, overlay)
    self.boot = boot
    self.transport = transport
    self.lockstep = lockstep
    self.coop = coop
    self.overlay = overlay

    local srv_env = os.getenv("KR_MP_SERVER")
    if srv_env and srv_env ~= "" then self.server_input = srv_env end
    if os.getenv("KR_MP_DEFAULT_TAB") == "online" then self.net_tab = "online" end

    self.font_title = fonts.get(17)
    self.font = fonts.get(13)
    self.font_small = fonts.get(12)
    self.font_tiny = fonts.get(11)

    self:load_prefs()
    self:load_saved_session()
    updater:init(boot, overlay)

    if os.getenv("KR_MP_OPEN_LOBBY") == "1" then
        self.open = true
        if self.net_tab == "lan" then self.transport:start_lan_scan() end
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
    self.net_tab = tab
    if tab == "lan" then
        self.transport:close()
        self.server_connected = false
        self.transport:switch_mode("lan")
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
    self.overlay:show_toast("局域网房间已创建（端口 " .. tostring(res) .. "），等待 2P 加入...", 2.0)
    return true
end

function lobby:on_lan_connected(target_ip, target_port)
    local info = self.pending_lan_join
    self.pending_lan_join = nil
    target_ip = target_ip or (info and info.ip) or "127.0.0.1"
    target_port = tonumber(target_port) or (info and info.port) or proto.DEFAULT_TCP_PORT

    self.role = "client"
    self.local_pid = 2
    self.online_room_code = nil
    self.online_token = nil
    self.peer_connected = true
    self.local_ready = true
    self.peer_name = "房主 (" .. tostring(target_ip) .. ")"
    self.view = "room"
    self.sub_modal = nil

    self.transport:send({
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "Player 2",
    })
    self.overlay:show_toast("已连接到局域网房主 " .. tostring(target_ip) .. ":" .. tostring(target_port), 2.0)
end

function lobby:join_lan_room(ip, port)
    local target_ip = ip or self.ip_input or "127.0.0.1"
    local target_port = tonumber(port) or tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
    local parsed_ip, parsed_port = target_ip:match("^([^:]+):(%d+)$")
    if parsed_ip and parsed_port then
        target_ip = parsed_ip
        target_port = tonumber(parsed_port)
    end

    self.pending_lan_join = { ip = target_ip, port = target_port }
    local ok, status_or_err = self.transport:join_lan(target_ip, target_port)
    if not ok then
        self.pending_lan_join = nil
        self.overlay:show_toast("连接局域网房主失败：" .. tostring(status_or_err), 4)
        return false
    end

    if status_or_err == "connected" then
        self:on_lan_connected(target_ip, target_port)
    else
        self.overlay:show_toast("正在连接房主 " .. tostring(target_ip) .. ":" .. tostring(target_port) .. "...", 2.5)
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

    if self.net_tab == "lan" then
        self.transport:close()
        if self.open then self.transport:start_lan_scan() end
        self.overlay:show_toast("已退出局域网房间。", 1.8)
    else
        if self.server_connected and self.transport:is_connected() then
            self:refresh_online_rooms()
        end
        self.overlay:show_toast("已退出公网房间。", 1.8)
    end
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
    local cfg = {
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
    self.online_room_code = msg.code
    self.online_token = msg.token
    self.local_pid = tonumber(msg.pid) or self.local_pid
    self.role = (self.local_pid == 1) and "host" or "client"
    self.peer_connected = true
    self:save_session(msg.code, self.local_pid, msg.token)
    self.boot:log("[LOBBY] Received RECONNECT_STATE room=%s pid=%d target_turn=%s",
        tostring(msg.code), self.local_pid, tostring(msg.target_turn))
    self.open = false
    self.sub_modal = nil
    self.coop:prepare_match(self.local_pid, msg.cfg, msg)
end

function MSG_HANDLERS.HELLO(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
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
    self.boot:log("[LOBBY] Received START_MATCH (pid=%d, level=%d, seed=%d)",
        self.local_pid, msg.cfg.level_idx or 0, msg.cfg.seed or 0)
    if msg.code and self.online_token then
        self:save_session(msg.code, self.local_pid, self.online_token)
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
        if msg.t == "PEER_RECONNECTED" then
            autotest:on_peer_reconnected()
        end
        return
    end
    local fn = MSG_HANDLERS[msg.t]
    if fn then fn(self, msg) end
end

function lobby:update(dt)
    updater:update(dt)
    if self.transport and self.transport.lan_backend then
        self.transport.lan_backend.accept_enabled = not (self.coop and self.coop:is_active())
    end
    local events = self.transport:poll()
    for i = 1, #events do
        local ev = events[i]
        if ev.type == "peer_connected" then
            self.peer_connected = true
            self.peer_name = "正在握手 (" .. tostring(ev.ip) .. ")..."
        elseif ev.type == "lan_connected" then
            self:on_lan_connected(ev.ip, ev.port)
        elseif ev.type == "lan_connect_failed" then
            self.pending_lan_join = nil
            self.overlay:show_toast("连接局域网房主失败：" .. tostring(ev.reason), 4)
            autotest:on_lan_connect_failed()
        elseif ev.type == "peer_disconnected" then
            self.peer_connected = false
            self.peer_ready = false
            self.peer_name = "已断开"
            if self.lockstep and self.lockstep:is_active() then
                self.lockstep:on_peer_disconnected(ev.reason, false)
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
