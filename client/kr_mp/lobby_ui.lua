-- KR-MP 全中文双模式联机大厅（FL 8.2.0 全201关/105英雄/59选12塔卡组 + 一键追帧重连 + 后台检查更新）
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")
local ui = require("kr_mp.ui_assets")

local lobby = {
    boot = nil,
    transport = nil,
    lockstep = nil,
    coop = nil,
    overlay = nil,
    voice = nil,

    open = false,
    net_tab = "lan", -- "lan" | "online"
    view = "home",   -- "home" | "room"
    sub_modal = nil, -- nil | "guide" | "stages" | "hero1" | "hero2" | "towers"
    guide_tab = 1,   -- 1..4 (新手教程四分页)
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
        level_difficulty = 2, -- 1=休闲, 2=普通, 3=老兵, 4=不可能
        econ_mode = "independent", -- "independent" | "shared"
        tower_mode = "owned",      -- "owned" | "open"
        input_delay_turns = proto.INPUT_DELAY_TURNS, -- 2=局域网(100ms), 4=樱花映射(200ms), 6=抗抖(300ms)
        heroes = { [1] = catalog.DEFAULT_HERO_1 or 53, [2] = catalog.DEFAULT_HERO_2 or 54 }, -- 维斯珀 + 蕾琳
        towers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 },
    },

    buttons = {},
    _consumed_down = false,
    font_title = nil,
    font = nil,
    font_small = nil,
    font_tiny = nil,

    -- Automated test drivers (M1: KR_MP_AUTO_COOP, M2: KR_MP_AUTO_M2)
    auto_role = nil,
    auto_m2_role = nil,
    auto_stage = nil,
    auto_timer = 0,
    auto_sent_ticks = {},
    auto_saw_reconnect = false,
}

local DIFF_NAMES = { [1] = "休闲", [2] = "普通", [3] = "老兵", [4] = "不可能" }
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

local function get_base_dir_safe()
    return proto.get_writable_dir()
end

local function get_prefs_path()
    return proto.path_join(get_base_dir_safe(), "kr_mp_prefs.json")
end

function lobby:load_prefs()
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") then return end
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
        if type(obj.voice_mode) == "string" then
            self.voice:set_mode(obj.voice_mode)
        end
        if obj.voice_peer_muted ~= nil then
            self.voice.peer_muted = (obj.voice_peer_muted == true)
        end
    end
    if obj.seen_guide ~= nil then
        self.seen_guide = (obj.seen_guide == true)
    end
end

function lobby:save_prefs()
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") then return end
    local prefs = {
        ip_input = self.ip_input,
        server_input = self.server_input,
        input_delay_turns = normalize_delay_turns(self.room and self.room.input_delay_turns),
        show_tower_marks = (self.coop == nil) or (self.coop.show_tower_marks ~= false),
        voice_mode = self.voice and self.voice.mode or "ptt",
        voice_peer_muted = self.voice and (self.voice.peer_muted == true) or false,
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
        if #clean > 0 then
            self.code_input = clean
            return true
        end
    elseif field_name == "pw" then
        local clean = clip:gsub("[^%w%-%_@#]", ""):sub(1, 16)
        if #clean > 0 then
            self.pw_input = clean
            return true
        end
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
    local path = get_session_path()
    local f = io.open(path, "r")
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
    local path = get_session_path()
    local f = io.open(path, "w")
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

function lobby:init(boot, transport, lockstep, coop, overlay)
    self.boot = boot
    self.transport = transport
    self.lockstep = lockstep
    self.coop = coop
    self.overlay = overlay

    local srv_env = os.getenv("KR_MP_SERVER")
    if srv_env and srv_env ~= "" then
        self.server_input = srv_env
    end
    if os.getenv("KR_MP_DEFAULT_TAB") == "online" then
        self.net_tab = "online"
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
        end
        if not updater.checked_once then
            updater:start_check(false)
        end
    end

    local ar = os.getenv("KR_MP_AUTO_COOP")
    if ar == "host" or ar == "guest" then
        self.auto_role = ar
        self.auto_stage = "INIT"
        self.net_tab = "lan"
        self.open = true
        self.boot:log("[LOBBY] AUTO_COOP (M1 LAN) test role=%s enabled!", ar)
    end

    local am2 = os.getenv("KR_MP_AUTO_M2")
    if am2 == "host" or am2 == "guest" or am2 == "guest_reconnect" then
        self.auto_m2_role = am2
        self.auto_stage = "INIT"
        self.net_tab = "online"
        self.open = true
        self.boot:log("[LOBBY] AUTO_M2 (Online + Reconnect) test role=%s enabled!", am2)
    end
end

function lobby:set_focus(field)
    self.focused_field = field
    if proto.is_android() and love and love.keyboard and love.keyboard.setTextInput then
        local want = (field ~= nil and self.open == true)
        pcall(love.keyboard.setTextInput, want)
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
    if not self.open then
        self:set_focus(nil)
    end
    if self.open and self.view == "home" then
        self:load_saved_session()
        if not updater.checked_once then
            updater:start_check(false)
        end
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
            -- 100% non-blocking background probe: 0ms UI freeze when switching tabs!
            self:connect_online_server(self.server_input, true)
        end
    end
end

-- === LAN Mode Actions ===

function lobby:broadcast_room_state()
    if self.role ~= "host" then return end
    ensure_room_defaults(self.room)
    if self.transport:is_online() then
        self.transport:send({
            t = "UPDATE_ROOM",
            room = self.room,
        })
        return
    end
    self.transport:update_advert({
        name = self.room.name,
        level_idx = self.room.level_idx,
        players = self.peer_connected and 2 or 1,
    })
    if self.peer_connected then
        self.transport:send({
            t = "ROOM_STATE",
            room = self.room,
            peer_ready = self.peer_ready,
        })
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
    if action then
        self.pending_online_action = action
    end
    if self.transport:is_online() and self.transport:is_connecting() then
        -- Already connecting in background; action will run automatically once connected!
        if self.transport.online_backend then
            self.transport.online_backend.connect_silent = false
        end
        return false, "connecting"
    end
    local ok = self:connect_online_server(self.server_input, false)
    if ok and self.server_connected then
        return true
    end
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
    local pw = (password ~= nil) and password or self.pw_input or ""
    local pub = (is_public ~= nil) and is_public or self.room_public
    self.transport:send({
        t = "CREATE_ROOM",
        name = self.room.name,
        password = pw,
        public = pub,
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
    local ok = self:connect_online_server(sess.server, false)
    if not ok then
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
        if self.open then
            self.transport:start_lan_scan()
        end
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
    if not self.auto_role and not self.auto_m2_role then
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

-- === Incoming Network Message Router ===

function lobby:on_message(msg)
    if not msg or not msg.t then return end
    if self.lockstep and self.lockstep:on_message(msg) then
        if msg.t == "PEER_RECONNECTED" then
            self.auto_saw_reconnect = true
        end
        return
    end

    local t = msg.t
    if t == "VOICE" then
        if self.voice then
            self.voice:on_voice_message(msg)
        end
        return

    elseif t == "SERVER_HELLO" then
        self.server_connected = true
        self.server_ver = msg.server_ver
        self.server_voice_ok = (msg.voice_ok == true)
        self.online_rooms = msg.rooms or {}
        updater:note_server_version(msg.server_ver)
        self.boot:log("[LOBBY] Server hello OK (ver=%s, voice_ok=%s, rooms=%d)",
            tostring(msg.server_ver), tostring(self.server_voice_ok), #self.online_rooms)

    elseif t == "ROOM_LIST" then
        self.online_rooms = msg.rooms or {}

    elseif t == "ROOM_CREATED" then
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

    elseif t == "ROOM_JOINED" then
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

    elseif t == "PEER_JOINED" then
        self.peer_connected = true
        self.peer_ready = (msg.peer_ready ~= false)
        self.peer_name = tostring(msg.name or "2P 队友")
        if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
        self.overlay:show_toast("2P 队友已加入房间 #" .. tostring(self.online_room_code) .. "，可以开局了！", 2.2)

    elseif t == "PEER_LEFT" then
        self.peer_connected = false
        self.peer_ready = false
        self.peer_name = "等待 2P 加入..."
        self.overlay:show_toast("2P 队友离开了房间。", 3.5)

    elseif t == "ROOM_CLOSED" then
        self:clear_saved_session()
        if self.coop and self.coop:is_active() then
            self.coop:leave_match()
        end
        self.role = "none"
        self.peer_connected = false
        self.online_room_code = nil
        self.online_token = nil
        self.view = "home"
        self.sub_modal = nil
        self.open = true
        self:refresh_online_rooms()
        self.overlay:show_toast("房间已关闭：" .. tostring(msg.reason or "房主退出"), 5)

    elseif t == "RECONNECT_STATE" and msg.cfg then
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

    elseif t == "HELLO" and self.role == "host" and not self.transport:is_online() then
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
        if msg.tick_len and math.abs(msg.tick_len - (TICK_LENGTH or 1/60)) > 1e-4 then
            self.transport:send({ t = "ERROR", msg = "帧率设置不一致！请双方统一以 60 FPS 启动。" })
            return
        end
        self.peer_connected = true
        self.peer_ready = true
        self.peer_name = tostring(msg.name or "2P 队友")
        self.transport:send({
            t = "WELCOME",
            pid = 2,
            room = self.room,
        })
        self:broadcast_room_state()
        self.overlay:show_toast("2P 队友已加入局域网房间，可以开局了！", 2.2)

    elseif t == "WELCOME" and self.role == "client" then
        self.local_pid = tonumber(msg.pid) or 2
        if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
        self.peer_connected = true
        self.overlay:show_toast("已加入局域网房间（你是 2P 红方）！", 2.0)

    elseif t == "ROOM_STATE" then
        if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
        if msg.peer_connected ~= nil then self.peer_connected = msg.peer_connected end
        if msg.peer_ready ~= nil then self.peer_ready = msg.peer_ready end
        if self.role == "host" and msg.guest_name then
            self.peer_name = msg.guest_name
        elseif self.role == "client" and msg.host_name then
            self.peer_name = msg.host_name
        end

    elseif t == "SET_GUEST" and self.role == "host" and not self.transport:is_online() then
        if msg.ready ~= nil then self.peer_ready = msg.ready end
        if msg.hero_idx then
            self.room.heroes[2] = tonumber(msg.hero_idx) or self.room.heroes[2]
        end
        self:broadcast_room_state()

    elseif t == "START_MATCH" and msg.cfg then
        self.boot:log("[LOBBY] Received START_MATCH (pid=%d, level=%d, seed=%d)",
            self.local_pid, msg.cfg.level_idx or 0, msg.cfg.seed or 0)
        if msg.code and self.online_token then
            self:save_session(msg.code, self.local_pid, self.online_token)
        end
        self.open = false
        self.sub_modal = nil
        self.coop:prepare_match(self.local_pid, msg.cfg)

    elseif t == "ERROR" then
        self.boot:log("[LOBBY] Server/Host ERROR: %s", tostring(msg.msg))
        self.overlay:show_toast("提示：" .. tostring(msg.msg), 5)
    end
end

function lobby:update(dt)
    updater:update(dt)
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
            if self.auto_role == "guest" and self.auto_stage == "GUEST_WAIT_START" then
                self.auto_stage = "INIT"
                self.auto_timer = 0.5
            end
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
            if self.auto_m2_role and (self.auto_stage == "HOST_WAIT_ROOM" or self.auto_stage == "GUEST_SCAN_ONLINE" or self.auto_stage == "RECONNECT_WAIT") then
                self.auto_stage = "INIT"
                self.auto_timer = 0
            end
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

    if self.auto_role then
        self:step_auto_coop(dt)
    elseif self.auto_m2_role then
        self:step_auto_m2(dt)
    end
end

-- === Automated Test Drivers (M1 LAN & M2 Online + Reconnect) ===

local function find_sorted_ents(store, pred)
    local out = {}
    for id, e in pairs(store.entities) do
        if type(id) == "number" and e and not e._kr_mp_local and pred(e) then
            out[#out + 1] = e
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function lobby:step_auto_coop(dt)
    self.auto_timer = self.auto_timer + dt

    if self.auto_stage == "INIT" then
        if self.auto_role == "host" then
            self.room.level_idx = tonumber(os.getenv("KR_MP_TEST_LEVEL")) or 101
            local env_diff = tonumber(os.getenv("KR_MP_TEST_DIFF"))
            if env_diff and env_diff >= 1 and env_diff <= 4 then
                self.room.level_difficulty = math.floor(env_diff)
            end
            self.room.econ_mode = "independent"
            self.room.tower_mode = "owned"
            self.room.heroes = { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 }
            if self:host_lan_room() then
                self.auto_stage = "HOST_WAIT_GUEST"
            end
        else
            self.transport:start_lan_scan()
            if self.auto_timer >= 1.5 then
                local rooms = self.transport:get_lan_rooms()
                local ip, port = "127.0.0.1", tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
                if #rooms > 0 then
                    ip, port = rooms[1].ip, rooms[1].port
                    self.boot:log("[AUTO_COOP] Guest discovered LAN room via UDP: %s:%d (%s)", ip, port, rooms[1].name)
                end
                if self:join_lan_room(ip, port) then
                    self.auto_stage = "GUEST_WAIT_START"
                else
                    self.auto_timer = 0.5
                end
            end
        end

    elseif self.auto_stage == "HOST_WAIT_GUEST" then
        if self.peer_connected and self.peer_ready then
            self.auto_stage = "MATCH_ACTIVE"
            self:host_start_match()
        end

    elseif self.auto_stage == "GUEST_WAIT_START" then
        if self.coop and self.coop:is_active() then
            self.auto_stage = "MATCH_ACTIVE"
        end

    elseif self.auto_stage == "MATCH_ACTIVE" then
        if not self.lockstep or not self.lockstep:is_active() then return end
        if self.lockstep.phase == "DESYNC" then
            self.boot:log("AUTO_COOP_FAILED desync_tick=%s", tostring(self.lockstep.desync_info and self.lockstep.desync_info.tick))
            love.event.quit()
            return
        end
        local store = game and game.store
        if not store then return end
        local tick = store.tick or 0
        local pid = self.coop.local_pid
        if tick >= 1860 and self.lockstep.sync_ok_count >= 60 then
            self.boot:log("AUTO_COOP_PASSED pid=%d ticks=%d sync_ok=%d gold=(P1:%d,P2:%d)",
                pid, tick, self.lockstep.sync_ok_count, self.coop:get_player_gold(1), self.coop:get_player_gold(2))
            self.lockstep:close_hash_log()
            love.event.quit()
            return
        end
        if self.lockstep.phase ~= "RUNNING" then return end

        local function once(tag, min_tick, fn)
            if tick >= min_tick and not self.auto_sent_ticks[tag] then
                self.auto_sent_ticks[tag] = true
                fn()
            end
        end

        if pid == 1 then
            once("p1_build", 20, function()
                local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
                if hs[1] then self.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
            end)
            once("p1_hero", 45, function()
                local h = self.coop.hero_ids[1] and store.entities[self.coop.hero_ids[1]]
                if h then self.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 80, wy = h.pos.y + 10 }) end
            end)
            once("p1_wave", 90, function() self.lockstep:queue_local_command({ op = "SEND_WAVE" }) end)
            once("p1_reinf", 300, function()
                local h = self.coop.hero_ids[1] and store.entities[self.coop.hero_ids[1]]
                if h then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 30, wy = h.pos.y }) end
            end)
            once("p1_sendgold", 450, function() self.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 50 }) end)
            once("p1_ping", 600, function() self.lockstep:queue_local_command({ op = "MAP_PING", wx = 600, wy = 400 }) end)
            once("p1_ult", 900, function()
                local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
                if es[1] then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 1, wx = es[1].pos.x, wy = es[1].pos.y }) end
            end)
        else
            once("p2_build", 30, function()
                local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
                if hs[2] then self.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[2].id, arg = "tower_build_royal_archers" }) end
            end)
            once("p2_hero", 60, function()
                local h = self.coop.hero_ids[2] and store.entities[self.coop.hero_ids[2]]
                if h then self.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 120, wy = h.pos.y - 10 }) end
            end)
            once("p2_reinf", 330, function()
                local h = self.coop.hero_ids[2] and store.entities[self.coop.hero_ids[2]]
                if h then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 20, wy = h.pos.y }) end
            end)
            once("p2_ping", 630, function() self.lockstep:queue_local_command({ op = "MAP_PING", wx = 720, wy = 450 }) end)
            once("p2_ult", 960, function()
                local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
                if es[1] then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 3, wx = es[1].pos.x, wy = es[1].pos.y }) end
            end)
            once("p2_illegal_sell", 1100, function()
                local p1_t = find_sorted_ents(store, function(e) return e.tower and e._mp_owner == 1 end)
                if p1_t[1] then self.lockstep:queue_local_command({ op = "TW_SELL", id = p1_t[1].id }) end
            end)
        end

        if tick >= 1860 and self.lockstep.sync_ok_count >= 60 then
            self.boot:log("AUTO_COOP_PASSED pid=%d ticks=%d sync_ok=%d gold=(P1:%d,P2:%d)",
                pid, tick, self.lockstep.sync_ok_count, self.coop:get_player_gold(1), self.coop:get_player_gold(2))
            self.lockstep:close_hash_log()
            love.event.quit()
        end
    end
end

function lobby:step_auto_m2(dt)
    self.auto_timer = self.auto_timer + dt

    if self.auto_stage == "INIT" then
        if self.auto_m2_role == "host" then
            self.room.name = "M2 Auto Online Room"
            self.room.level_idx = tonumber(os.getenv("KR_MP_TEST_LEVEL")) or 101
            self.room.econ_mode = "independent"
            self.room.tower_mode = "owned"
            self.room.heroes = { catalog.DEFAULT_HERO_1 or 53, catalog.DEFAULT_HERO_2 or 54 }
            self.room.towers = { 1, 2, 3, 4, 5, 6, 7, 8, 25, 27, 44, 59 } -- Mix of KR5 + KR4 + KR6 towers!
            if self:create_online_room("1234", true) then
                self.auto_stage = "HOST_WAIT_ROOM"
            end
        elseif self.auto_m2_role == "guest" then
            if self.auto_timer >= 0.8 then
                if self:connect_online_server(self.server_input, false) then
                    self.auto_stage = "GUEST_SCAN_ONLINE"
                    self.auto_timer = 0
                else
                    self.auto_timer = 0
                end
            end
        elseif self.auto_m2_role == "guest_reconnect" then
            local sess = self:load_saved_session()
            if sess and self:reconnect_online_session(sess) then
                self.auto_stage = "RECONNECT_WAIT"
            elseif self.auto_timer > 5.0 then
                self.boot:log("AUTO_M2_FAILED no saved session to reconnect!")
                love.event.quit()
            end
        end

    elseif self.auto_stage == "HOST_WAIT_ROOM" then
        if self.online_room_code then
            self.boot:log("[AUTO_M2] Host Online Room created: code=%s", self.online_room_code)
            self.auto_stage = "HOST_WAIT_GUEST"
        end

    elseif self.auto_stage == "HOST_WAIT_GUEST" then
        if self.peer_connected and self.peer_ready then
            self.auto_stage = "HOST_WAIT_START"
            self:host_start_match()
        end

    elseif self.auto_stage == "HOST_WAIT_START" then
        if self.coop and self.coop:is_active() then
            self.auto_stage = "MATCH_ACTIVE"
        end

    elseif self.auto_stage == "GUEST_SCAN_ONLINE" then
        if #self.online_rooms > 0 then
            local r = self.online_rooms[1]
            self.boot:log("[AUTO_M2] Guest found public Online room: code=%s name=%s has_pw=%s",
                tostring(r.code), tostring(r.name), tostring(r.has_password))
            self:join_online_room(r.code, "1234")
            self.auto_stage = "GUEST_WAIT_START"
        elseif self.auto_timer >= 0.6 then
            self.auto_timer = 0
            self:refresh_online_rooms()
        end

    elseif self.auto_stage == "GUEST_WAIT_START" or self.auto_stage == "RECONNECT_WAIT" then
        if self.coop and self.coop:is_active() then
            self.auto_stage = "MATCH_ACTIVE"
        end

    elseif self.auto_stage == "MATCH_ACTIVE" then
        if not self.lockstep or not self.lockstep:is_active() then return end
        if self.lockstep.phase == "DESYNC" then
            self.boot:log("AUTO_M2_FAILED desync_tick=%s", tostring(self.lockstep.desync_info and self.lockstep.desync_info.tick))
            love.event.quit()
            return
        end
        local store = game and game.store
        if not store then return end
        local tick = store.tick or 0

        -- Check completion before phase guard so if peer already finished and closed socket at tick>=2160 we don't stall in WAIT_RECONNECT
        if self.auto_m2_role == "guest_reconnect" and tick >= 2160 and self.lockstep.sync_ok_count >= 25 then
            self.boot:log("AUTO_M2_PASSED role=guest_reconnect pid=2 ticks=%d post_sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                tick, self.lockstep.sync_ok_count, self.lockstep.game_speed,
                self.coop:get_player_gold(1), self.coop:get_player_gold(2))
            self.lockstep:close_hash_log()
            love.event.quit()
            return
        end
        if self.auto_m2_role == "host" and tick >= 2160 and self.auto_saw_reconnect and self.lockstep.sync_ok_count >= 50
            and (tick >= 2175 or self.lockstep.phase == "WAIT_RECONNECT") then
            self.boot:log("AUTO_M2_PASSED role=host pid=1 ticks=%d sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                tick, self.lockstep.sync_ok_count, self.lockstep.game_speed,
                self.coop:get_player_gold(1), self.coop:get_player_gold(2))
            self.lockstep:close_hash_log()
            love.event.quit()
            return
        end

        if self.lockstep.phase ~= "RUNNING" then return end

        local function once(tag, min_tick, fn)
            if tick >= min_tick and not self.auto_sent_ticks[tag] then
                self.auto_sent_ticks[tag] = true
                fn()
            end
        end

        if self.auto_m2_role == "host" then
            once("p1_build1", 20, function()
                local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
                if hs[1] then self.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
            end)
            once("p1_hero", 45, function()
                local h = self.coop.hero_ids[1] and store.entities[self.coop.hero_ids[1]]
                if h then self.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 80, wy = h.pos.y + 10 }) end
            end)
            once("p1_wave", 90, function() self.lockstep:queue_local_command({ op = "SEND_WAVE" }) end)
            once("p1_reinf", 300, function()
                local h = self.coop.hero_ids[1] and store.entities[self.coop.hero_ids[1]]
                if h then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 30, wy = h.pos.y }) end
            end)
            once("p1_sendgold", 450, function() self.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 50 }) end)
            once("p1_ult", 780, function()
                local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
                if es[1] then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 1, wx = es[1].pos.x, wy = es[1].pos.y }) end
            end)
            once("p1_post_build", 1200, function()
                local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
                if hs[1] then self.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_arcane_wizard" }) end
            end)
            once("p1_post_ping", 1500, function() self.lockstep:queue_local_command({ op = "MAP_PING", wx = 640, wy = 390 }) end)

            if tick >= 2160 and self.auto_saw_reconnect and self.lockstep.sync_ok_count >= 50 then
                self.boot:log("AUTO_M2_PASSED role=host pid=1 ticks=%d sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                    tick, self.lockstep.sync_ok_count, self.lockstep.game_speed,
                    self.coop:get_player_gold(1), self.coop:get_player_gold(2))
                self.lockstep:close_hash_log()
                love.event.quit()
            end

        elseif self.auto_m2_role == "guest" then
            once("p2_build1", 30, function()
                local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
                if hs[2] then self.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[2].id, arg = "tower_build_royal_archers" }) end
            end)
            once("p2_hero", 60, function()
                local h = self.coop.hero_ids[2] and store.entities[self.coop.hero_ids[2]]
                if h then self.lockstep:queue_local_command({ op = "HERO_RALLY", id = h.id, wx = h.pos.x + 120, wy = h.pos.y - 10 }) end
            end)
            once("p2_reinf", 330, function()
                local h = self.coop.hero_ids[2] and store.entities[self.coop.hero_ids[2]]
                if h then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 2, wx = h.pos.x + 20, wy = h.pos.y }) end
            end)
            once("p2_ping", 600, function() self.lockstep:queue_local_command({ op = "MAP_PING", wx = 720, wy = 440 }) end)

            if tick >= 960 then
                self.boot:log("AUTO_M2_SIMULATED_CRASH tick=%d hash=%s (hard exiting P2 to test fast-forward reconnect!)",
                    tick, tostring(self.lockstep.last_hash_hex))
                if self.boot.log_file then self.boot.log_file:flush() end
                os.exit(0)
            end

        elseif self.auto_m2_role == "guest_reconnect" then
            once("p2_post_speed2x", 1230, function() self.lockstep:request_toggle_speed() end)
            once("p2_post_build", 1290, function()
                local hs = find_sorted_ents(store, function(e) return e.tower and e.template_name and e.template_name:find("tower_holder", 1, true) end)
                if hs[1] then self.lockstep:queue_local_command({ op = "TW_UPGRADE", id = hs[1].id, arg = "tower_build_paladin_covenant" }) end
            end)
            once("p2_post_ult", 1560, function()
                local es = find_sorted_ents(store, function(e) return e.enemy and e.health and not e.health.dead end)
                if es[1] then self.lockstep:queue_local_command({ op = "POWER_FIRE", idx = 3, wx = es[1].pos.x, wy = es[1].pos.y }) end
            end)
            once("p2_post_sendgold", 1740, function() self.lockstep:queue_local_command({ op = "SEND_GOLD", amount = 50 }) end)

            if tick >= 2160 and self.lockstep.sync_ok_count >= 25 then
                self.boot:log("AUTO_M2_PASSED role=guest_reconnect pid=2 ticks=%d post_sync_ok=%d speed=%dx gold=(P1:%d,P2:%d)",
                    tick, self.lockstep.sync_ok_count, self.lockstep.game_speed,
                    self.coop:get_player_gold(1), self.coop:get_player_gold(2))
                self.lockstep:close_hash_log()
                love.event.quit()
            end
        end
    end
end

-- === Lobby Input & Button Handler ===

function lobby:textinput(t)
    if not self.open or not self.focused_field or type(t) ~= "string" then return false end
    local f = self.focused_field
    -- Support multi-character Android soft-keyboard IME commits as well as fullwidth colons
    local clean_t = t:gsub("：", ":")
    for i = 1, #clean_t do
        local c = clean_t:sub(i, i)
        if f == "ip" then
            if c:match("^[%d%.:a-zA-Z%-]$") and #self.ip_input < 80 then
                self.ip_input = self.ip_input .. c
            end
        elseif f == "server" then
            if c:match("^[%d%.:a-zA-Z%-]$") and #self.server_input < 80 then
                self.server_input = self.server_input .. c
            end
        elseif f == "code" then
            if c:match("^[%da-zA-Z]$") and #self.code_input < 6 then
                self.code_input = self.code_input .. c:upper()
            end
        elseif f == "pw" then
            if c:match("^[%w%-%_@#]$") and #self.pw_input < 16 then
                self.pw_input = self.pw_input .. c
            end
        end
    end
    return true
end

function lobby:keypressed(key)
    if key == "f10" then
        self:toggle()
        return true
    end
    if not self.open then return false end
    if key == "escape" or key == "acback" then
        if self.focused_field then
            self:set_focus(nil)
        elseif self.sub_modal then
            self.sub_modal = nil
        else
            self.open = false
            self:set_focus(nil)
        end
        return true
    end
    local f = self.focused_field
    if f then
        local ctrl = love and love.keyboard and love.keyboard.isDown and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl"))
        if ctrl and key == "v" then
            self:paste_into_field(f)
            return true
        elseif key == "backspace" then
            if f == "ip" then self.ip_input = self.ip_input:sub(1, -2)
            elseif f == "server" then self.server_input = self.server_input:sub(1, -2)
            elseif f == "code" then self.code_input = self.code_input:sub(1, -2)
            elseif f == "pw" then self.pw_input = self.pw_input:sub(1, -2)
            end
            return true
        elseif key == "return" or key == "kpenter" then
            self:set_focus(nil)
            if f == "ip" then
                self.ip_input = proto.sanitize_addr(self.ip_input):sub(1, 80)
                self:save_prefs()
                self:join_lan_room(self.ip_input)
            elseif f == "server" then
                self.server_input = proto.sanitize_addr(self.server_input):sub(1, 80)
                self:save_prefs()
                self:connect_online_server(self.server_input, false)
            elseif f == "code" then
                self:join_online_room(self.code_input, self.pw_input)
            end
            return true
        end
    end
    return true
end

local function toggle_tower_in_deck(deck, tid)
    for i = 1, #deck do
        if deck[i] == tid then
            if #deck <= 1 then
                return false, "至少保留 1 座防御塔！"
            end
            table.remove(deck, i)
            return true
        end
    end
    if #deck >= 12 then
        return false, "最多携带 12 座防御塔！请先点掉 1 座已选塔。"
    end
    deck[#deck + 1] = tid
    table.sort(deck)
    return true
end

function lobby:handle_button(btn)
    local id = btn.id
    local is_input_box = (id == "ip_box" or id == "server_box" or id == "code_box" or id == "pw_box")
    if not is_input_box then
        self:set_focus(nil)
    end

    -- Native Ironhide tactile UI sound feedback (purely visual/audio, outside sim)
    if id == "close" or id == "leave_room" then
        ui.play_sfx("close")
    elseif id == "start_match" or id == "toggle_ready" then
        ui.play_sfx("start")
    elseif id == "tab_lan" or id == "tab_online" or id == "stage_pack" or id == "hero_pack" or id == "tower_pack"
        or id == "open_stages" or id == "open_hero1" or id == "open_hero2" or id == "open_towers"
        or id == "open_guide" or id == "guide_tab" then
        ui.play_sfx("tab")
    elseif id == "econ_toggle" then
        ui.play_sfx("coin")
    elseif id ~= "ip_box" and id ~= "server_box" and id ~= "code_box" and id ~= "pw_box" then
        ui.play_sfx("click")
    end

    if id == "close" then
        self.open = false
        self.sub_modal = nil
        if self.overlay then self.overlay:clear_toast() end
    elseif id == "check_update" then
        if updater.ota_applied then
            updater:restart_game()
        elseif updater.ota_updating then
            self.overlay:show_toast("正在下载并校验热更新补丁，请稍候几秒...", 2.0)
        elseif updater.ota_ready then
            updater:start_ota_apply()
        elseif updater.has_update then
            updater:open_download_page()
        else
            updater:start_check(true)
        end
    elseif id == "modal_back" then
        self.sub_modal = nil
        if self.overlay then self.overlay:clear_toast() end
    elseif id == "open_guide" then
        if self.overlay then self.overlay:clear_toast() end
        if not self.seen_guide then
            self.seen_guide = true
            self:save_prefs()
        end
        self.guide_tab = tonumber(btn.tab) or ((self.view == "room") and 2 or 1)
        self.sub_modal = "guide"
    elseif id == "guide_tab" and btn.tab then
        self.guide_tab = math.max(1, math.min(4, tonumber(btn.tab) or 1))
    elseif id == "guide_prev" then
        self.guide_tab = math.max(1, (self.guide_tab or 1) - 1)
    elseif id == "guide_next" then
        self.guide_tab = math.min(4, (self.guide_tab or 1) + 1)
    elseif id == "tab_lan" then
        if self.overlay then self.overlay:clear_toast() end
        self:switch_tab("lan")
    elseif id == "tab_online" then
        if self.overlay then self.overlay:clear_toast() end
        self:switch_tab("online")
    -- LAN Home
    elseif id == "host_lan" then
        self:host_lan_room()
    elseif id == "join_local" then
        self:join_lan_room("127.0.0.1", proto.DEFAULT_TCP_PORT)
    elseif id == "ip_box" then
        self:set_focus("ip")
    elseif id == "paste_ip" then
        self:paste_into_field("ip")
    elseif id == "join_ip" then
        self.ip_input = proto.sanitize_addr(self.ip_input):sub(1, 80)
        self:save_prefs()
        self:join_lan_room(self.ip_input)
    elseif id == "join_lan_room" and btn.room then
        self:join_lan_room(btn.room.ip, btn.room.port)
    -- Online Home
    elseif id == "server_box" then
        self:set_focus("server")
    elseif id == "paste_server" then
        self:paste_into_field("server")
    elseif id == "connect_server" then
        self.server_input = proto.sanitize_addr(self.server_input):sub(1, 80)
        self:save_prefs()
        self:connect_online_server(self.server_input, false)
    elseif id == "refresh_online" then
        self:refresh_online_rooms()
    elseif id == "code_box" then
        self:set_focus("code")
    elseif id == "pw_box" then
        self:set_focus("pw")
    elseif id == "toggle_public" then
        self.room_public = not self.room_public
    elseif id == "create_online" then
        self:create_online_room(self.pw_input, self.room_public)
    elseif id == "join_code" then
        self:join_online_room(self.code_input, self.pw_input)
    elseif id == "join_online_room" and btn.room then
        self:join_online_room(btn.room.code, self.pw_input)
    elseif id == "reconnect_last" then
        self:reconnect_online_session(self.saved_session)
    -- Room View
    elseif id == "leave_room" then
        self:leave_room()
    elseif id == "start_match" then
        self:host_start_match()
    elseif id == "open_stages" and self.role == "host" then
        if self.overlay then self.overlay:clear_toast() end
        self.sub_modal = "stages"
    elseif id == "open_hero1" and self.role == "host" then
        if self.overlay then self.overlay:clear_toast() end
        self.sub_modal = "hero1"
    elseif id == "open_hero2" then
        if self.overlay then self.overlay:clear_toast() end
        self.sub_modal = "hero2"
    elseif id == "open_towers" and self.role == "host" then
        if self.overlay then self.overlay:clear_toast() end
        ensure_room_defaults(self.room)
        self.sub_modal = "towers"
    elseif id == "diff_cycle" and self.role == "host" then
        self.room.level_difficulty = (self.room.level_difficulty % 4) + 1
        self:broadcast_room_state()
    elseif id == "econ_toggle" and self.role == "host" then
        self.room.econ_mode = (self.room.econ_mode == "independent") and "shared" or "independent"
        self:broadcast_room_state()
    elseif id == "tower_toggle" and self.role == "host" then
        self.room.tower_mode = (self.room.tower_mode == "owned") and "open" or "owned"
        self:broadcast_room_state()
    elseif id == "delay_cycle" and self.role == "host" then
        local cur = normalize_delay_turns(self.room.input_delay_turns)
        self.room.input_delay_turns = (cur == 2) and 4 or ((cur == 4) and 6 or 2)
        self:save_prefs()
        self:broadcast_room_state()
        local tips = {
            [2] = "已切至【局域网 100ms 缓冲】：同 Wi-Fi / 低延迟最跟手",
            [4] = "已切至【樱花映射 200ms 缓冲】：免费 FRP / 跨省联机更丝滑不卡顿！",
            [6] = "已切至【高延迟抗抖 300ms 缓冲】：适合高抖动跨网 / 热点联机",
        }
        self.overlay:show_toast(tips[self.room.input_delay_turns], 2.4)
    elseif id == "toggle_tower_marks" and self.coop then
        self.coop.show_tower_marks = not self.coop.show_tower_marks
        self:save_prefs()
        self.overlay:show_toast(self.coop.show_tower_marks and "已开启本地防御塔底座红蓝标志（仅对自己生效）" or "已关闭本地防御塔归属标志（纯净画面）", 2.0)
    elseif id == "voice_cycle" and self.voice then
        if not self.voice.supported then
            self.overlay:show_toast("当前环境未检测到可用语音音频接口。", 2.2)
        else
            self.voice:cycle_mode()
            self:save_prefs()
            self.overlay:show_toast(self.voice:get_mode_toast(), 2.4)
        end
    elseif id == "voice_aux" and self.voice then
        if not self.voice.supported then
            self.overlay:show_toast("当前环境未检测到可用语音音频接口。", 2.2)
        elseif self.peer_connected then
            local muted = self.voice:toggle_peer_mute()
            self:save_prefs()
            self.overlay:show_toast(muted and "已静音队友语音（听筒关闭）" or "已恢复收听队友语音（听筒开启）", 1.8)
        else
            local testing = self.voice:toggle_self_test()
            self.overlay:show_toast(testing and "试麦已开启：现在说话可实时听见自己回放（请戴耳机，再点关闭）" or "已关闭本地试麦回放。", 2.4)
        end
    elseif id == "cycle_font_theme" then
        local info = fonts.cycle_theme()
        self:save_prefs()
        self.overlay:show_toast("已切换字体风格：" .. info.desc, 2.8)
    elseif id == "cycle_seal_style" then
        local info = ui.cycle_seal_style()
        self:save_prefs()
        self.overlay:show_toast("已切换蜡封样式：" .. info.desc, 2.8)
    elseif id == "toggle_ready" and self.role == "client" then
        self:toggle_ready()
    -- Sub-Modal Pickers
    elseif id == "stage_pack" and btn.pack_idx then
        self.stage_pack_idx = btn.pack_idx
        self.stage_page = 1
    elseif id == "stage_page_prev" then
        self.stage_page = math.max(1, (self.stage_page or 1) - 1)
    elseif id == "stage_page_next" then
        self.stage_page = (self.stage_page or 1) + 1
    elseif id == "pick_stage" and btn.level_idx and self.role == "host" then
        self.room.level_idx = btn.level_idx
        self.sub_modal = nil
        self:broadcast_room_state()
    elseif id == "hero_pack" and btn.pack_idx then
        self.hero_pack_idx = btn.pack_idx
    elseif id == "pick_hero" and btn.hero_idx then
        if self.sub_modal == "hero1" and self.role == "host" then
            self.room.heroes[1] = btn.hero_idx
            self.sub_modal = nil
            self:broadcast_room_state()
        elseif self.sub_modal == "hero2" then
            self.room.heroes[2] = btn.hero_idx
            self.sub_modal = nil
            if self.role == "host" then
                self:broadcast_room_state()
            elseif self.role == "client" then
                self.transport:send({ t = "SET_GUEST", hero_idx = btn.hero_idx, ready = self.local_ready })
            end
        end
    elseif id == "tower_pack" and btn.pack_idx then
        self.tower_pack_idx = btn.pack_idx
    elseif id == "pick_tower" and btn.tower_idx and self.role == "host" then
        ensure_room_defaults(self.room)
        local ok, msg = toggle_tower_in_deck(self.room.towers, btn.tower_idx)
        if not ok and msg then
            self.overlay:show_toast(msg, 2.5)
        else
            self:broadcast_room_state()
        end
    elseif id == "towers_default" and self.role == "host" then
        self.room.towers = copy_array(catalog.DEFAULT_TOWERS)
        self:broadcast_room_state()
        self.overlay:show_toast("已恢复默认 5 代 12 座防御塔！", 2.0)
    end
end

function lobby:mousepressed(x, y, button)
    if not self.open then return false end
    if button == 1 then
        local s = self._ui_scale or 1
        local lx = (x - (self._ui_ox or 0)) / s
        local ly = (y - (self._ui_oy or 0)) / s
        for _, b in ipairs(self.buttons) do
            if lx >= b.x and lx <= b.x + b.w and ly >= b.y and ly <= b.y + b.h then
                self._consumed_down = true
                self:handle_button(b)
                return true
            end
        end
        if self.overlay and self.overlay:dismiss_toast_at(x, y) then
            return true
        end
        self:set_focus(nil)
    end
    return true
end

function lobby:mousereleased(x, y, button)
    if self._consumed_down and button == 1 then
        self._consumed_down = false
        return true
    end
    return self.open
end

-- === Lobby Rendering (V2 Ironhide Native Parchment & Hand-Hewn Oak War-Table) ===

local PACK_TAG_STYLES = {
    kr6 = { bg = { 24, 54, 108, 230 }, border = { 136, 198, 255, 225 }, fg = { 228, 246, 255, 255 }, era = "6代·创世" },
    kr5 = { bg = { 46, 26, 12, 220 },  border = { 218, 166, 78, 220 },  fg = { 255, 232, 164, 255 }, era = "5代·联盟" },
    kr4 = { bg = { 76, 22, 64, 225 },  border = { 224, 128, 212, 215 }, fg = { 255, 226, 250, 255 }, era = "4代·复仇" },
    kr3 = { bg = { 30, 64, 38, 225 },  border = { 132, 214, 148, 210 }, fg = { 232, 255, 236, 255 }, era = "3代·起源" },
    kr2 = { bg = { 98, 56, 18, 225 },  border = { 242, 186, 94, 215 },  fg = { 255, 240, 204, 255 }, era = "2代·前线" },
    kr1 = { bg = { 96, 30, 30, 225 },  border = { 236, 132, 126, 210 }, fg = { 255, 230, 226, 255 }, era = "1代·初代" },
}

local DIFF_STYLES = {
    [1] = { name = "休闲",   stars = "★☆☆",  col = { 42, 118, 56, 255 },  star_col = { 255, 236, 172, 255 } },
    [2] = { name = "普通",   stars = "★★☆",  col = { 168, 92, 24, 255 },  star_col = { 255, 236, 172, 255 } },
    [3] = { name = "老兵",   stars = "★★★",  col = { 158, 32, 32, 255 },  star_col = { 255, 236, 172, 255 } },
    [4] = { name = "不可能", stars = "★★★★", col = { 126, 24, 148, 255 }, star_col = { 242, 168, 255, 255 } },
}

local function get_stage_pack_info(level_idx)
    local info = catalog.get_stage_info(level_idx)
    if info and info.pack_id then return info.pack_id end
    local idx = tonumber(level_idx) or 101
    if idx >= 251 then return "kr6"
    elseif idx >= 150 then return "kr4"
    elseif idx >= 101 then return "kr5"
    elseif idx <= 22 or idx == 86 then return "kr3"
    elseif idx <= 44 or idx >= 77 then return "kr2"
    else return "kr1" end
end

local function get_stage_clean_title(level_idx)
    local short = catalog.get_stage_short(level_idx)
    local num, name = short:match("^(%d+)%s+(.+)$")
    if num and name then
        return string.format("第 %s 关 · %s", num, name)
    end
    return catalog.get_stage_label(level_idx)
end

function lobby:draw()
    if not self.open or not love.graphics then return end

    local G = love.graphics
    local T = ui.THEME
    local sw, sh = G.getWidth(), G.getHeight()
    local scale = ui.compute_lobby_scale(sw, sh)
    local pw, ph = 780, 486
    local ox = math.floor((sw - pw * scale) * 0.5)
    local oy = math.floor((sh - ph * scale) * 0.5 + 12 * scale)
    oy = math.max(math.floor(28 * scale), oy)
    local px, py = 0, 0

    self._ui_scale = scale
    self._ui_ox = ox
    self._ui_oy = oy

    local font_map = ui.make_font_map(scale)

    local raw_mx, raw_my = 0, 0
    if love.mouse and love.mouse.getPosition then
        raw_mx, raw_my = love.mouse.getPosition()
    end
    local mx = (raw_mx - ox) / scale
    local my = (raw_my - oy) / scale

    local btns = {}
    local function add_btn(id, label, x, y, w, h, style, extra)
        local b = { id = id, label = label, x = x, y = y, w = w, h = h, style = style or "wood" }
        if extra then
            for k, v in pairs(extra) do b[k] = v end
        end
        btns[#btns + 1] = b
    end

    G.push("all")
    G.origin()
    G.setScissor()
    G.setShader()
    G.setBlendMode("alpha")

    -- Full-screen warm darkened backdrop vignette
    G.setColor(T.backdrop[1], T.backdrop[2], T.backdrop[3], T.backdrop[4])
    G.rectangle("fill", 0, 0, sw, sh)

    -- Scale entire War-Table cleanly to current resolution while rendering all text at native physical DPI!
    ui.begin_transform(scale, ox, oy)

    -- Pick clean single-line Royal Crimson Banner Title (100% centered inside gold stitch!)
    local banner_title = "双人同盟 · 皇家战桌"
    if self.sub_modal == "guide" then
        banner_title = "新手指南 · 1分钟开黑"
    elseif self.view == "home" then
        banner_title = "联机酒馆 · 冒险驿站"
    elseif self.sub_modal == "stages" then
        banner_title = "战役舆图 · 选择关卡"
    elseif self.sub_modal == "hero1" then
        banner_title = "英雄殿 · 选 1P 主将"
    elseif self.sub_modal == "hero2" then
        banner_title = "英雄殿 · 选 2P 队友"
    elseif self.sub_modal == "towers" then
        banner_title = "皇家军械库 · 59选12"
    end

    -- Draw Hand-Hewn Dark Oak Shell + Aged Parchment + 4 Iron Corners + Royal Crimson Ribbon
    ui.draw_ironhide_war_table(px, py, pw, ph, banner_title, font_map.banner)

    -- Protruding Ironhide Corner Crimson Close Shield (×)
    add_btn("close", "×", px + pw - 22, py - 10, 32, 30, "crimson", { large = true, radius = 8 })

    -- Content bounds inside parchment double-ink hairline frame
    local cx = px + 25
    local cw = pw - 50

    if self.sub_modal == "guide" then
        -- === 零基础小白 1 分钟上手图文教程（4 分页羊皮纸卷轴） ===
        local y = py + 42
        local tabs = {
            { idx = 1, label = "1. 怎么联机" },
            { idx = 2, label = "2. 双人玩法" },
            { idx = 3, label = "3. 连麦直播" },
            { idx = 4, label = "4. 按键与排错" },
        }
        local cur_tab = math.max(1, math.min(4, tonumber(self.guide_tab) or 1))
        self.guide_tab = cur_tab
        local back_w = 92
        local t_gap = 6
        local tab_w = math.floor((cw - back_w - 10 - (#tabs - 1) * t_gap) / #tabs)
        for i, tb in ipairs(tabs) do
            local act = (cur_tab == tb.idx)
            add_btn("guide_tab", tb.label, cx + (i - 1) * (tab_w + t_gap), y, tab_w, 28,
                act and "wood" or "parchment", { tab = tb.idx, small = true, active = act })
        end
        add_btn("modal_back", self.view == "room" and "返回战桌" or "返回大厅", cx + cw - back_w, y, back_w, 28, "crimson", { small = true })
        y = y + 36

        if cur_tab == 1 then
            -- TAB 1: 怎么联机（3 种情况一步步说清楚）
            local cards = {
                {
                    badge = "最简单 · 同宿舍 / 同 Wi-Fi",
                    badge_bg = { 38, 128, 62, 245 },
                    badge_rim = { 26, 86, 40, 255 },
                    border = { 54, 132, 68, 235 },
                    title = "什么都不用填，10 秒直接开玩！",
                    lines = {
                        "第1步：两台电脑都双击游戏目录里的「启动联机版_FL8.2.0.bat」，进入后点左上角「联机大厅 (F10)」。",
                        "第2步：一人当房主点左边「创建房间并备战」；队友等 2 秒，在最下方酒馆布告栏点「揭榜加入」就行！",
                        "小提示：首次开房若弹出 Windows 防火墙提示，请务必勾选专用/公用网络并点「允许访问」。",
                    },
                },
                {
                    badge = "异地免费 · 樱花映射直连",
                    badge_bg = { 36, 98, 158, 245 },
                    badge_rim = { 22, 64, 108, 255 },
                    border = { 46, 106, 162, 235 },
                    title = "不在同一个房间？用免费内网穿透（零服务器费用）",
                    lines = {
                        "第1步：房主在樱花映射 (SakuraFrp) 开一条免费 TCP 隧道，本地端口填 17777，复制生成的地址发给朋友。",
                        "第2步：房主点「创建房间并备战」，把房间顶部「缓冲」点一下切到【缓冲:樱花200ms】（更稳不卡顿）。",
                        "第3步：朋友复制整段地址 -> 点右边「粘贴」（自动去掉多余汉字）-> 点「立即直连队友战桌」秒进！",
                    },
                },
                {
                    badge = "不怕闪退 · 公网中继服重连",
                    badge_bg = { 116, 42, 138, 245 },
                    badge_rim = { 76, 24, 92, 255 },
                    border = { 126, 56, 146, 235 },
                    title = "打超长关卡怕中途掉线？支持 5 分钟保局 + 高速追帧重连",
                    lines = {
                        "第1步：房主运行完整包里的「启动公网中继服.bat」（映射本地端口 17780）或使用已有公网服地址。",
                        "第2步：双方切到「公网中继服」页点连接 -> 房主建房后把 4 位房间码发给朋友，朋友输码进房。",
                        "第3步：中途谁闪退/断网，5 分钟内重开游戏切到公网页，点顶部绿色「一键高速追帧重连」瞬间回到战场！",
                    },
                },
            }
            local ch = 104
            local cgap = 8
            for i, c in ipairs(cards) do
                local cy = y + (i - 1) * (ch + cgap)
                ui.draw_parchment_card(cx, cy, cw, ch, { border = c.border, border_w = 1.8, radius = 8 })
                ui.draw_pill(cx + 12, cy + 8, 174, 20, c.badge, c.badge_bg, c.badge_rim, { 255, 252, 238, 255 }, font_map.tiny_bold)
                ui.text(c.title, cx + 196, cy + 9, T.ink_text, font_map.small_bold)
                for j, line in ipairs(c.lines) do
                    local ly = cy + 33 + (j - 1) * 21
                    ui.text(line, cx + 14, ly, (j == 3) and T.ink_muted or T.ink_sub, font_map.tiny, cw - 28, "left")
                end
            end

        elseif cur_tab == 2 then
            -- TAB 2: 双人玩法与规则大白话
            local half_w = math.floor((cw - 12) / 2)
            local top_h = 144

            -- Left: 1P Blue Host
            ui.draw_parchment_card(cx, y, half_w, top_h, {
                top = { 234, 242, 250, 252 }, bot = { 222, 224, 206, 250 },
                border = T.p1_border, border_w = 2.0, thumbtack = true, radius = 8,
            })
            ui.draw_pill(cx + 12, y + 11, 134, 20, "1P 蓝方主将（房主）", T.p1_top, T.p1_border, { 244, 250, 255, 255 }, font_map.tiny_bold)
            ui.text("· 操控【1 号英雄】和左侧专属英雄大招。", cx + 12, y + 38, T.ink_text, font_map.small)
            ui.text("· 拥有【独立冷却援军】，与 2P 互不抢冷却！", cx + 12, y + 60, T.ink_text, font_map.small)
            ui.text("· 负责挑选地图（全 6 代 201 关）、战役难度", cx + 12, y + 83, T.ink_sub, font_map.tiny)
            ui.text("  （含第 4 档「不可能」）以及 59 选 12 防御塔卡组。", cx + 12, y + 100, T.ink_sub, font_map.tiny)
            ui.text("· 等 2P 进房、蜡封变绿「就绪」后点「出征守关！」", cx + 12, y + 120, T.p1_border, font_map.tiny_bold)

            -- Right: 2P Red Guest
            local rx = cx + half_w + 12
            ui.draw_parchment_card(rx, y, half_w, top_h, {
                top = { 252, 238, 234, 252 }, bot = { 236, 218, 190, 250 },
                border = T.p2_border, border_w = 2.0, thumbtack = true, radius = 8,
            })
            ui.draw_pill(rx + 12, y + 11, 134, 20, "2P 红方协防（队友）", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, font_map.tiny_bold)
            ui.text("· 操控【2 号英雄】和右侧专属英雄大招。", rx + 12, y + 38, T.ink_text, font_map.small)
            ui.text("· 同样拥有【独立冷却援军】，随便放不冲突！", rx + 12, y + 60, T.ink_text, font_map.small)
            ui.text("· 进房后点「更换 2P 英雄」，可在 105 位全系列", rx + 12, y + 83, T.ink_sub, font_map.tiny)
            ui.text("  英雄中任选自己喜欢的搭档（含 6 代新英雄）。", rx + 12, y + 100, T.ink_sub, font_map.tiny)
            ui.text("· 选好英雄确认「已就绪」，等房主一键发车！", rx + 12, y + 120, T.p2_border, font_map.tiny_bold)

            -- Bottom 3 Rule Cards
            local ry2 = y + top_h + 10
            local rh2 = 176
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
                ui.text(r.title, rx3 + 12, ry2 + 9, T.ink_text, font_map.small_bold)
                ui.draw_pill(rx3 + 12, ry2 + 30, rw3 - 24, 19, r.tag,
                    { r.col[1], r.col[2], r.col[3], 230 }, T.ink_dark, { 255, 250, 236, 255 }, font_map.tiny_bold)
                ui.text(r.body, rx3 + 12, ry2 + 56, T.ink_sub, font_map.tiny, rw3 - 24, "left")
            end

        elseif cur_tab == 3 then
            -- TAB 3: 内置连麦与直播动效教程
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
                ui.draw_pill(rx3 + 12, y + 13, rw3 - 24, 22, m.badge, m.bg, T.ink_dark, { 255, 252, 238, 255 }, font_map.tiny_bold)
                ui.text(m.sub, rx3 + 12, y + 39, T.ink_text, font_map.small_bold, rw3 - 24, "center")
                ui.text(m.body, rx3 + 12, y + 61, T.ink_sub, font_map.tiny, rw3 - 24, "left")
            end

            -- Bottom Dark-Oak Livestream Tips Panel
            local by = y + top_h + 10
            local bh = 172
            ui.draw_armory_tray(cx, by, cw, bh, 9)
            ui.print_shadow("直播效果 & 开播前试麦小贴士（无需任何第三方语音软件！）", cx + 16, by + 11, T.gold_bright, nil, nil, nil, font_map.small_bold)
            local tips = {
                "1. 开播前先点【试麦】：队友还没进房时，点房间顶部「试麦」按钮并戴上耳机讲两句——能听到自己清晰回放、且 1P 英雄头像右下声波条跳动，就说明麦克风完全正常！",
                "2. 直播声波特效自动触发：在战桌说话时对应英雄卡亮起翡翠呼吸光圈；进战局后谁开口，顶部 HUD 下方自动弹出【英雄头像 + 1P/2P + 5段动态声波气泡】，观众一眼分清谁在喊话！",
                "3. 队友太吵或自己没插麦？：队友进房后顶部可一键点「听筒:关」静音对方；没插麦克风的电脑也完全不报错，可以直接清楚收听队友指挥。",
                "4. 零卡帧零掉线：语音跑在独立后台线程且仅占 ~10KB/s，网络抖动时自动让路给游戏操作帧，绝不影响 60Hz 同步！",
            }
            for i, line in ipairs(tips) do
                ui.text(line, cx + 16, by + 37 + (i - 1) * 32, { 244, 226, 188, 240 }, font_map.tiny, cw - 32, "left")
            end

        else
            -- TAB 4: 常用快捷键 & 小白常见 4 大问题急救
            local lw = 304
            local rw = cw - lw - 12
            local card_h = 330

            -- Left: Hotkey Cheat Sheet
            ui.draw_parchment_card(cx, y, lw, card_h, { border = { 138, 94, 40, 245 }, border_w = 1.8, radius = 8 })
            ui.draw_pill(cx + 12, y + 10, lw - 24, 22, "常用快捷键 & 顶栏按钮速查", T.wood_mid, T.ink_dark, T.gold_bright, font_map.tiny_bold)
            local keys = {
                { k = "F10",        d = "随时打开 / 关闭联机大厅" },
                { k = "F9",         d = "隐藏 / 显示顶部联机信息条" },
                { k = "按住 V",     d = "按键说话（按V麦模式）" },
                { k = "M 键",       d = "一键闭麦 / 恢复开麦" },
                { k = "Alt + 左键", d = "在地图打点标记提醒队友" },
                { k = "Space 空格", d = "双端同步暂停 / 继续战斗" },
                { k = "A / S 键",   d = "1P / 2P 释放各自英雄大招" },
                { k = "顶栏 转50",  d = "独立经济下给队友转 50 金" },
                { k = "顶栏 1x/2x", d = "双端同步切换 1 倍/2 倍速" },
            }
            for i, item in ipairs(keys) do
                local ky = y + 39 + (i - 1) * 31
                ui.draw_pill(cx + 12, ky, 82, 22, item.k, { 236, 214, 168, 245 }, { 148, 108, 52, 210 }, T.ink_text, font_map.tiny_bold)
                ui.text(item.d, cx + 102, ky + 4, T.ink_text, font_map.tiny, lw - 114, "left")
            end

            -- Right: Top 4 Newbie Troubleshooting Q&A
            local rx = cx + lw + 12
            ui.draw_parchment_card(rx, y, rw, card_h, { border = T.p2_border, border_w = 1.8, radius = 8 })
            ui.draw_pill(rx + 12, y + 10, rw - 24, 22, "小白最常遇到的 4 个问题急救箱", T.p2_top, T.p2_border, { 255, 246, 238, 255 }, font_map.tiny_bold)
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
                    q = "Q3：玩起来觉得点一下要等半拍，或者有点卡顿？",
                    a = "异地/樱花节点有网络波动很正常！让房主把房间顶部「缓冲」切到【樱花200ms】或【抗抖300ms】，操作会丝滑很多。",
                },
                {
                    q = "Q4：某关意外闪退，或顶部提示红字「同步异常」？",
                    a = "别慌！打开解压好的补丁文件夹，双击「一键收集报错包.bat」，10 秒自动打包日志与 AI 提问词，发给作者或直接喂给 AI 即可秒修！",
                },
            }
            for i, fq in ipairs(faqs) do
                local fy = y + 40 + (i - 1) * 71
                ui.text(fq.q, rx + 14, fy, T.p2_border, font_map.small_bold, rw - 28, "left")
                ui.text(fq.a, rx + 14, fy + 19, T.ink_sub, font_map.tiny, rw - 28, "left")
            end
        end

        -- Bottom compact Prev / Page / Next navigation bar cleanly seated INSIDE the parchment frame
        local pby = py + ph - 62
        ui.draw_pill(cx + math.floor(cw / 2) - 64, pby + 3, 128, 22,
            string.format("第 %d / 4 页 · 按 ESC 返回", cur_tab),
            { 246, 232, 198, 240 }, T.parchment_edge, T.ink_sub, font_map.tiny_bold)
        if cur_tab > 1 then
            add_btn("guide_prev", "上一页", cx, pby, 92, 28, "wood", { small = true })
        end
        if cur_tab < 4 then
            add_btn("guide_next", "下一页", cx + cw - 92, pby, 92, 28, "battle", { small = true })
        else
            add_btn("modal_back", "看懂了，去开黑！", cx + cw - 134, pby, 134, 28, "battle", { small = true })
        end

    elseif self.view == "home" then
        -- === 联机酒馆 · 冒险驿站 ===
        local y = py + 42
        local is_lan = (self.net_tab == "lan")
        add_btn("tab_lan", "局域网 / 樱花直连", cx, y, 162, 28, is_lan and "wood" or "parchment", { small = true, active = is_lan })
        add_btn("tab_online", "公网中继服 (追帧重连)", cx + 170, y, 178, 28, (not is_lan) and "wood" or "parchment", { small = true, active = not is_lan })

        local upd_lbl, upd_w, upd_style
        if updater.ota_applied then
            upd_lbl = "重启生效 √"
            upd_w = 92
            upd_style = "battle"
        elseif updater.ota_updating then
            upd_lbl = updater.ota_progress_text or "热更新中..."
            upd_w = 98
            upd_style = "azure"
        elseif updater.ota_ready then
            local nchg = updater.ota_changed_files and #updater.ota_changed_files or 0
            upd_lbl = (updater.latest_version and updater.is_newer(updater.latest_version, proto.MOD_VERSION))
                and ("热更新 v" .. tostring(updater.latest_version))
                or string.format("一键热更(%d)", nchg)
            upd_w = 108
            upd_style = "battle"
        elseif updater.has_update then
            upd_lbl = "下载新版 v" .. tostring(updater.latest_version)
            upd_w = 112
            upd_style = "battle"
        elseif updater.checking then
            upd_lbl = "检查中..."
            upd_w = 76
            upd_style = "parchment"
        else
            upd_lbl = "检查更新"
            upd_w = 76
            upd_style = "parchment"
        end
        add_btn("check_update", upd_lbl, cx + cw - upd_w, y + 1, upd_w, 26, upd_style, { tiny = true })
        local guide_w = 78
        add_btn("open_guide", "新手教程", cx + cw - upd_w - guide_w - 6, y + 1, guide_w, 26,
            (not self.seen_guide) and "azure" or "parchment", { tiny = true, tab = 1 })
        ui.text(string.format("FL %s · v%s · F10", tostring(KR_FL_VERSION), proto.MOD_VERSION),
            cx + 354, y + 7, T.ink_muted, font_map.tiny, cw - 360 - upd_w - guide_w - 8, "right")

        y = y + 36
        G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], 130)
        G.setLineWidth(1)
        G.line(cx, y, cx + cw, y)
        y = y + 10

        if is_lan then
            -- Two Pinned Tavern Bounty Contracts side-by-side
            local card_w = math.floor((cw - 14) / 2)
            local card_h = 164

            -- Left Contract: 1P Host
            ui.draw_parchment_card(cx, y, card_w, card_h, {
                top = { 236, 240, 232, 250 },
                bot = { 228, 214, 178, 250 },
                border = T.p1_border,
                border_w = 2,
                thumbtack = true,
            })
            ui.draw_pill(cx + 14, y + 14, 124, 20, "1P 房主 · 蓝方旗帜", T.p1_top, T.p1_border, { 242, 250, 255, 255 }, font_map.tiny_bold)
            ui.text("设立双人合作战桌", cx + 14, y + 40, T.ink_text, font_map.hero)
            ui.text("开房自动开启局域网发现 (TCP 17777)；异地开黑用樱花映射指向此端口即可零服务器直连。",
                cx + 14, y + 62, T.ink_sub, font_map.tiny, card_w - 28, "left")
            add_btn("host_lan", "创建房间并备战", cx + 14, y + 96, card_w - 28, 32, "battle", { small = false })
            add_btn("join_local", "本机双开快速加入 (127.0.0.1)", cx + 14, y + 134, card_w - 28, 22, "parchment", { tiny = true })

            -- Right Contract: 2P Guest / SakuraFrp Smart Paste
            local rx = cx + card_w + 14
            ui.draw_parchment_card(rx, y, card_w, card_h, {
                top = { 250, 238, 226, 250 },
                bot = { 234, 212, 176, 250 },
                border = T.p2_border,
                border_w = 2,
                thumbtack = true,
            })
            ui.draw_pill(rx + 14, y + 14, 124, 20, "2P 队友 · 红方驰援", T.p2_top, T.p2_border, { 255, 244, 244, 255 }, font_map.tiny_bold)
            ui.text("粘贴樱花 / 局域网地址直连", rx + 14, y + 40, T.ink_text, font_map.hero)

            local ip_disp = self.ip_input
            if #ip_disp > 32 then ip_disp = "..." .. ip_disp:sub(-29) end
            local ip_w = card_w - 28 - 64
            add_btn("ip_box", ip_disp .. (self.focused_field == "ip" and "|" or ""), rx + 14, y + 66, ip_w, 28, "input", {
                small = true, focused = (self.focused_field == "ip"),
            })
            add_btn("paste_ip", "粘贴", rx + 14 + ip_w + 6, y + 66, 58, 28, "wood", { small = true })
            ui.text("复制整行樱花日志后点「粘贴」(或 Ctrl+V) 自动提取地址！", rx + 14, y + 99, T.ink_muted, font_map.tiny)
            local lan_connecting = (not self.transport:is_online()) and self.transport:is_connecting()
            add_btn("join_ip", lan_connecting and "正在连接房主..." or "立即直连队友战桌", rx + 14, y + 120, card_w - 28, 34, "crimson", { small = false })

            y = y + card_h + 12

            -- Bottom Dark-Oak Tavern Notice Board (LAN Auto-Discovery)
            local tray_h = (py + ph - 22) - y
            ui.draw_armory_tray(cx, y, cw, tray_h, 9)
            local rooms = self.transport:get_lan_rooms()
            ui.draw_ping_dot(cx + 18, y + 18, 12, #rooms > 0)
            ui.print_shadow(string.format("酒馆布告栏 · 自动扫描附近局域网战桌 (UDP 17778 · %d 个房间)", #rooms),
                cx + 30, y + 11, T.gold_bright, nil, nil, nil, font_map.small_bold)

            if #rooms == 0 then
                ui.text("暂未扫描到同 Wi-Fi 房间 · 同局域网请等待房主点「创建房间」；异地远程请直接使用右上樱花映射直连。",
                    cx + 22, y + math.floor(tray_h * 0.46), { 232, 206, 158, 220 }, font_map.small, cw - 44, "center")
            else
                local max_lan = math.max(1, math.floor((tray_h - 38) / 48))
                for idx = 1, math.min(#rooms, max_lan) do
                    local r = rooms[idx]
                    local ry = y + 34 + (idx - 1) * 48
                    ui.draw_parchment_card(cx + 12, ry, cw - 24, 42, { radius = 6 })
                    ui.draw_stage_thumb(r.level_idx, cx + 18, ry + 4, 58, 34, { radius = 4, pad = 1, border = { 108, 72, 32, 235 } })
                    ui.text(string.format("%s  ·  %s", tostring(r.name), get_stage_clean_title(r.level_idx)), cx + 86, ry + 5, T.ink_text, font_map.main_bold)
                    ui.text(string.format("%s:%d  ·  %d/2 勇士等待中", tostring(r.ip), tonumber(r.port) or 17777, tonumber(r.players) or 1), cx + 86, ry + 23, T.ink_sub, font_map.tiny)
                    add_btn("join_lan_room", "揭榜加入", cx + cw - 110, ry + 6, 86, 28, "battle", { small = true, room = r })
                end
            end
        else
            -- === 公网中继服首页 ===
            local is_connecting = self.transport:is_online() and self.transport:is_connecting()

            if self.saved_session then
                local s = self.saved_session
                add_btn("reconnect_last",
                    string.format("一键高速追帧重连：房间 #%s (%dP)  @  %s", tostring(s.code), tonumber(s.pid) or 2, tostring(s.server)),
                    cx, y, cw, 32, "battle", { small = true })
                y = y + 40
            end

            -- Server connection strip
            ui.draw_parchment_card(cx, y, cw, 44, { radius = 7 })
            ui.text("中继服：", cx + 12, y + 14, T.ink_text, font_map.small_bold)
            local sx = cx + 64
            local sw_in = cw - 64 - 224
            local srv_disp = self.server_input
            if #srv_disp > 40 then srv_disp = "..." .. srv_disp:sub(-37) end
            add_btn("server_box", srv_disp .. (self.focused_field == "server" and "|" or ""), sx, y + 7, sw_in, 28, "input", {
                small = true, focused = (self.focused_field == "server"),
            })
            add_btn("paste_server", "粘贴", sx + sw_in + 6, y + 7, 48, 28, "wood", { small = true })
            local conn_lbl = self.server_connected and ("已连 " .. self.transport:get_rtt_ms() .. "ms")
                or (is_connecting and "连接中..." or "连接")
            add_btn("connect_server", conn_lbl, sx + sw_in + 60, y + 7, 86, 28,
                self.server_connected and "battle" or (is_connecting and "wood" or "azure"), { small = true })
            add_btn("refresh_online", "刷新", sx + sw_in + 152, y + 7, 58, 28, "parchment", { small = true })
            y = y + 52

            -- Two Pinned Online Contracts
            local lw = math.floor(cw * 0.54)
            local rw = cw - lw - 12
            local rx = cx + lw + 12

            ui.draw_parchment_card(cx, y, lw, 92, { border = T.p1_border, border_w = 1.8, thumbtack = true })
            ui.text("1P 房主 · 创建公网合作房", cx + 12, y + 8, T.p1_border, font_map.small_bold)
            local pw_empty = (#self.pw_input == 0)
            local pw_disp = (pw_empty and "房间密码(选填)" or self.pw_input) .. (self.focused_field == "pw" and "|" or "")
            local pw_w = lw - 122
            add_btn("pw_box", pw_disp, cx + 12, y + 28, pw_w, 25, "input", {
                small = true, placeholder = pw_empty and (self.focused_field ~= "pw"), focused = (self.focused_field == "pw"),
            })
            add_btn("toggle_public", self.room_public and "公开大厅" or "仅房间码", cx + 18 + pw_w, y + 28, 92, 25, "parchment", { tiny = true })
            add_btn("create_online", "创建公网房间", cx + 12, y + 58, lw - 24, 26, "azure", { small = true })

            ui.draw_parchment_card(rx, y, rw, 92, { border = T.p2_border, border_w = 1.8, thumbtack = true })
            ui.text("2P 队友 · 凭房间码加入", rx + 12, y + 8, T.p2_border, font_map.small_bold)
            local code_empty = (#self.code_input == 0)
            local code_disp = (code_empty and "输入4位房间码(如 A1B2)" or self.code_input) .. (self.focused_field == "code" and "|" or "")
            add_btn("code_box", code_disp, rx + 12, y + 28, rw - 24, 25, "input", {
                small = true, placeholder = code_empty and (self.focused_field ~= "code"), focused = (self.focused_field == "code"),
            })
            add_btn("join_code", "凭房间码进房", rx + 12, y + 58, rw - 24, 26, "crimson", { small = true })
            y = y + 100

            -- Online Public Hall Tray
            local tray_h = (py + ph - 22) - y
            ui.draw_armory_tray(cx, y, cw, tray_h, 9)
            ui.draw_ping_dot(cx + 18, y + 17, self.transport:get_rtt_ms(), self.server_connected)
            ui.print_shadow(string.format("公开在线房间大厅 (%d 个房间)", #self.online_rooms), cx + 30, y + 10, T.gold_bright, nil, nil, nil, font_map.small_bold)

            if is_connecting then
                ui.text("正在后台探测公网中继服（不卡界面），也可直接修改上方服务器地址后点「连接」。",
                    cx + 22, y + math.floor(tray_h * 0.44), { 246, 224, 174, 225 }, font_map.small, cw - 44, "center")
            elseif not self.server_connected then
                ui.text("尚未连接中继服 · 点上方「连接」接入；或自开 kr-mp-server + 樱花映射 TCP 17780 享 5 分钟追帧重连。",
                    cx + 22, y + math.floor(tray_h * 0.44), { 232, 206, 158, 220 }, font_map.small, cw - 44, "center")
            elseif #self.online_rooms == 0 then
                ui.text("已连接服务器！当前暂无公开房间，可点左上「创建公网房间」或「刷新」。",
                    cx + 22, y + math.floor(tray_h * 0.46), { 232, 206, 158, 220 }, font_map.small, cw - 44, "center")
            else
                local max_show = math.max(1, math.floor((tray_h - 34) / 38))
                for idx = 1, math.min(#self.online_rooms, max_show) do
                    local r = self.online_rooms[idx]
                    local ry = y + 32 + (idx - 1) * 38
                    ui.draw_parchment_card(cx + 12, ry, cw - 24, 33, { radius = 5 })
                    ui.draw_pill(cx + 18, ry + 6, 56, 20, "#" .. tostring(r.code), T.wood_mid, T.ink_dark, T.gold_bright, font_map.tiny_bold)
                    local pw_tag = r.has_password and " [需密码]" or ""
                    ui.text(string.format("%s  ·  %s  (%d/2)%s",
                        tostring(r.name), get_stage_clean_title(r.level_idx), tonumber(r.players) or 1, pw_tag),
                        cx + 82, ry + 9, T.ink_text, font_map.small_bold)
                    add_btn("join_online_room", "加入", cx + cw - 92, ry + 4, 70, 24, "battle", { small = true, room = r })
                end
            end
        end

    elseif self.sub_modal == "stages" then
        -- === 战役舆图 · FL 8.2.0 全 201 关选择器（6代同堂 + 分页） ===
        local y = py + 42
        local packs = catalog.STAGE_PACKS
        local back_w = 84
        local tab_gap = 5
        local tab_w = math.floor((cw - back_w - 10 - (#packs - 1) * tab_gap) / #packs)
        for i, pk in ipairs(packs) do
            local act = (i == self.stage_pack_idx)
            local lbl = string.format("%s(%d)", pk.tag or pk.id, #pk.stages)
            add_btn("stage_pack", lbl, cx + (i - 1) * (tab_w + tab_gap), y, tab_w, 28,
                act and "wood" or "parchment", { pack_idx = i, tiny = true, active = act })
        end
        add_btn("modal_back", "返回战桌", cx + cw - back_w, y, back_w, 28, "crimson", { tiny = true })
        y = y + 36

        local pack = packs[self.stage_pack_idx] or packs[1]
        local per_page = 30
        local total_pages = math.max(1, math.ceil(#pack.stages / per_page))
        local cur_page = math.max(1, math.min(total_pages, self.stage_page or 1))
        self.stage_page = cur_page
        local start_i = (cur_page - 1) * per_page + 1
        local end_i = math.min(#pack.stages, start_i + per_page - 1)

        local cols = 5
        local gap = 6
        local tile_w = math.floor((cw - (cols - 1) * gap) / cols)
        local tile_h = (total_pages > 1) and 50 or 56
        for idx_in_pack = start_i, end_i do
            local st = pack.stages[idx_in_pack]
            local slot = idx_in_pack - start_i
            local col = slot % cols
            local row = math.floor(slot / cols)
            local bx = cx + col * (tile_w + gap)
            local by = y + row * (tile_h + gap)
            local sel = (self.room.level_idx == st.idx)
            add_btn("pick_stage", string.format("第 %d 关\n%s", st.idx, st.name), bx, by, tile_w, tile_h,
                sel and "battle" or "parchment", { level_idx = st.idx, selected = sel, tiny = true })
        end

        if total_pages > 1 then
            local pby = py + ph - 60
            ui.draw_pill(cx + math.floor(cw / 2) - 56, pby + 2, 112, 24,
                string.format("第 %d / %d 页", cur_page, total_pages),
                { 246, 232, 198, 240 }, T.parchment_edge, T.ink_text, font_map.small_bold)
            if cur_page > 1 then
                add_btn("stage_page_prev", "上一页", cx + math.floor(cw / 2) - 146, pby, 82, 28, "wood", { small = true })
            end
            if cur_page < total_pages then
                add_btn("stage_page_next", "下一页", cx + math.floor(cw / 2) + 64, pby, 82, 28, "wood", { small = true })
            end
        end

    elseif self.sub_modal == "hero1" or self.sub_modal == "hero2" then
        -- === 经典铁皮分栏英雄殿：左侧大立绘实时预览 + 右侧全 105 英雄方阵 ===
        local is_h1 = (self.sub_modal == "hero1")
        local cur_hero = is_h1 and self.room.heroes[1] or self.room.heroes[2]
        local y = py + 42
        local packs = catalog.HERO_PACKS
        local back_w = 80
        local tab_gap = 4
        local tab_w = math.floor((cw - back_w - 8 - (#packs - 1) * tab_gap) / #packs)
        for i, pk in ipairs(packs) do
            local act = (i == self.hero_pack_idx)
            local short_lbl = pk.name:gsub("·[^%(]+", "")
            add_btn("hero_pack", short_lbl, cx + (i - 1) * (tab_w + tab_gap), y, tab_w, 28,
                act and (is_h1 and "azure" or "crimson") or "parchment", { pack_idx = i, tiny = true, active = act })
        end
        add_btn("modal_back", "返回战桌", cx + cw - back_w, y, back_w, 28, "wood", { tiny = true })
        y = y + 38

        -- Compute hovered hero for instant giant vertical art preview on the left!
        local pack = packs[self.hero_pack_idx] or packs[1]
        local preview_w = 186
        local preview_h = 372
        local grid_x = cx + preview_w + 12
        local grid_w = cw - preview_w - 12
        local cols = 4
        local gap = 6
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

        -- Left Giant Vertical Hero Showcase Frame
        ui.draw_vgrad_rect(cx, y, preview_w, preview_h,
            is_h1 and T.p1_top or T.p2_top, { 26, 16, 10, 255 }, 10)
        G.setColor(is_h1 and T.p1_border[1] or T.p2_border[1],
            is_h1 and T.p1_border[2] or T.p2_border[2],
            is_h1 and T.p1_border[3] or T.p2_border[3], 255)
        G.setLineWidth(2.2)
        G.rectangle("line", cx, y, preview_w, preview_h, 10, 10)

        ui.draw_pill(cx + 12, y + 10, preview_w - 24, 20,
            is_h1 and "1P 蓝方主将预览" or "2P 红方队友预览",
            { 18, 12, 8, 185 }, T.gold_mid, T.gold_bright, font_map.tiny_bold)

        ui.draw_hero_big_portrait(preview_hero, cx + 12, y + 36, preview_w - 24, 242, {
            radius = 8, pad = 2, border = T.gold_mid, border_w = 2,
        })
        ui.print_shadow(catalog.get_hero_label(preview_hero), cx + 8, y + 288, T.gold_bright, preview_w - 16, "center", nil, font_map.title)
        ui.print_shadow(string.format("英雄编号 #%d", preview_hero), cx + 8, y + 314,
            is_h1 and T.p1_light or T.p2_light, preview_w - 16, "center", nil, font_map.small_bold)
        ui.text("点击右侧头像立即委任出战", cx + 10, y + 344, { 232, 212, 174, 215 }, font_map.tiny, preview_w - 20, "center")

    elseif self.sub_modal == "towers" then
        -- === 皇家军械库 · FL 8.2.0 全 59 选 12（6代 + 5代 + 4代） ===
        ensure_room_defaults(self.room)
        local selected = {}
        for _, tid in ipairs(self.room.towers) do selected[tid] = true end

        local y = py + 42
        local full = (#self.room.towers >= 12)
        ui.draw_pill(cx, y + 2, 102, 24, string.format("已装备 %d/12", #self.room.towers),
            full and { 42, 122, 54, 245 } or { 172, 108, 28, 245 },
            T.ink_dark, { 255, 250, 232, 255 }, font_map.tiny_bold)

        local packs = catalog.TOWER_PACKS
        local right_w = 180
        local avail_tabs_w = cw - 110 - right_w - 8
        local t_gap = 6
        local t_tab_w = math.floor((avail_tabs_w - (#packs - 1) * t_gap) / #packs)
        for i, pk in ipairs(packs) do
            local act = (i == self.tower_pack_idx)
            add_btn("tower_pack", pk.name, cx + 108 + (i - 1) * (t_tab_w + t_gap), y, t_tab_w, 28,
                act and "wood" or "parchment", { pack_idx = i, tiny = true, active = act })
        end
        add_btn("towers_default", "默认12塔", cx + cw - 178, y, 84, 28, "parchment", { tiny = true })
        add_btn("modal_back", "完成返回", cx + cw - 88, y, 88, 28, "battle", { tiny = true })
        y = y + 38

        local pack = packs[self.tower_pack_idx] or packs[1]
        local cols = 4
        local gap = 7
        local tile_w = math.floor((cw - (cols - 1) * gap) / cols)
        local tile_h = 56
        for i, tw in ipairs(pack.towers) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local bx = cx + col * (tile_w + gap)
            local by = y + row * (tile_h + gap)
            local is_sel = selected[tw.idx] == true
            add_btn("pick_tower", tw.name, bx, by, tile_w, tile_h, "tower_tile", {
                tower_idx = tw.idx,
                sub_label = is_sel and "已带入军械盘" or "点击加入卡组",
                selected = is_sel,
                icon_size = 44,
            })
        end

    else
        -- === 战备沙盘（V2 铁皮羊皮纸皇家战桌主界面 · 1:1 高清自适应！） ===
        ensure_room_defaults(self.room)
        local is_host = (self.role == "host")
        local rtt = self.transport:get_rtt_ms()
        local d_turns = normalize_delay_turns(self.room.input_delay_turns)
        local delay_lbl = DELAY_LABELS[d_turns] or "缓冲:局域网100ms"
        local marks_on = (self.coop == nil) or (self.coop.show_tower_marks ~= false)

        -- Row 1: Top Status & Sakura/Marks Compact Strip
        local y = py + 40
        ui.draw_ping_dot(cx + 8, y + 12, rtt, self.peer_connected)
        ui.text(self.peer_connected and "同盟已集结 (2/2)" or "等待 2P 入阵 (1/2)", cx + 20, y + 5, T.ink_text, font_map.small_bold)

        local net_info
        if self.transport:is_online() then
            net_info = string.format("公网 #%s · %dms", tostring(self.online_room_code or "----"), rtt)
        elseif is_host then
            net_info = string.format("TCP:%d (樱花端口) · %dms", self.transport:get_port(), rtt)
        else
            net_info = string.format("已直连远程主机 · %dms", rtt)
        end
        local info_w = is_host and 204 or 164
        ui.draw_pill(cx + 136, y + 2, info_w, 21, net_info,
            { 74, 44, 18, 28 }, { 154, 114, 58, 160 }, T.ink_sub, font_map.tiny)

        -- Built-in Livestream Voice Controls cleanly nested in the Row 1 center gap
        if self.voice then
            local v_ok = self.voice.supported
            local v_mode = self.voice.mode
            local v_talk = self.voice.local_talking
            local v_lbl = self.voice:get_mode_lobby_label()
            local v_style = (v_ok and v_talk) and "battle" or ((v_ok and v_mode ~= "mute") and "wood" or "parchment")
            local v_fg = (v_mode == "mute" or not v_ok) and { 158, 42, 42, 255 }
                or ((v_mode == "vad") and { 196, 255, 206, 255 } or { 255, 240, 198, 255 })
            add_btn("voice_cycle", v_lbl, cx + 346, y, 106, 24, v_style, {
                tiny = true, fg = v_talk and { 255, 255, 242, 255 } or v_fg,
            })
            local aux_lbl, aux_style, aux_fg
            if self.peer_connected then
                local pm = self.voice.peer_muted
                aux_lbl = pm and "听筒:关" or "听筒:开"
                aux_style = pm and "crimson" or "parchment"
                aux_fg = pm and { 255, 236, 232, 255 } or { 42, 118, 56, 255 }
            else
                local st = self.voice.self_test
                aux_lbl = st and "试麦中" or "试麦"
                aux_style = st and "battle" or "parchment"
                aux_fg = st and { 255, 255, 238, 255 } or T.ink_text
            end
            add_btn("voice_aux", aux_lbl, cx + 456, y, 52, 24, aux_style, {
                tiny = true, fg = aux_fg,
            })
        end

        if is_host then
            add_btn("delay_cycle", delay_lbl, cx + cw - 216, y, 122, 24, "parchment", {
                tiny = true, active = (d_turns >= 4),
            })
        else
            ui.draw_pill(cx + cw - 216, y + 1, 122, 22, delay_lbl,
                { 238, 218, 174, 240 }, { 154, 114, 58, 180 }, T.ink_text, font_map.tiny)
        end
        add_btn("toggle_tower_marks", marks_on and "塔底徽记:开" or "塔底徽记:关", cx + cw - 88, y, 88, 24,
            marks_on and "wood" or "parchment", {
                tiny = true,
                fg = marks_on and { 226, 255, 218, 255 } or T.ink_sub,
            })

        y = y + 29
        G.setColor(T.parchment_line[1], T.parchment_line[2], T.parchment_line[3], 145)
        G.setLineWidth(1)
        G.line(cx, y, cx + cw, y)
        y = y + 7

        -- Row 2: HEROIC 3-COLUMN STAGE (1P Tall Hero | Pinned Map Postcard + 3 Rules | 2P Tall Hero + Wax Seal)
        local hero_w = 190
        local mid_w = cw - hero_w * 2 - 24
        local stage_h = 216
        local mid_x = cx + hero_w + 12
        local c2x = mid_x + mid_w + 12

        -- LEFT: 1P Azure Champion Tall Vertical Card
        G.setColor(34, 18, 6, 72)
        G.rectangle("fill", cx + 2, y + 4, hero_w, stage_h, 10, 10)
        ui.draw_vgrad_rect(cx, y, hero_w, stage_h, T.p1_top, T.p1_bot, 10)
        G.setColor(168, 222, 255, 78)
        G.setLineWidth(1.5)
        G.line(cx + 10, y + 2, cx + hero_w - 10, y + 2)
        G.setColor(T.p1_border[1], T.p1_border[2], T.p1_border[3], 255)
        G.setLineWidth(2.2)
        G.rectangle("line", cx, y, hero_w, stage_h, 10, 10)

        ui.print_shadow("1P 蓝方主将", cx + 10, y + 6, T.p1_light, nil, nil, nil, font_map.tiny_bold)
        ui.draw_pill(cx + hero_w - 44, y + 4, 36, 17, "房主", { 12, 26, 48, 175 }, nil, T.gold_bright, font_map.tiny_bold)

        -- Full Vertical Hero Art (1P)
        local hp_x, hp_y, hp_w, hp_h = cx + 8, y + 24, hero_w - 16, 152
        ui.draw_hero_big_portrait(self.room.heroes[1], hp_x, hp_y, hp_w, hp_h, {
            radius = 7, pad = 2, bg = { 16, 34, 58, 255 }, border = T.gold_mid, border_w = 2,
        })
        -- Bottom dark scrim inside portrait for crisp hero name
        ui.draw_vgrad_rect(hp_x + 2, hp_y + hp_h - 46, hp_w - 4, 44, { 10, 22, 38, 0 }, { 8, 18, 32, 232 }, 4)
        ui.print_shadow(catalog.get_hero_label(self.room.heroes[1]), hp_x + 8, hp_y + hp_h - 36, T.gold_bright, nil, nil, nil, font_map.hero)
        ui.print_shadow("英雄 #" .. tostring(self.room.heroes[1]), hp_x + 8, hp_y + hp_h - 17, T.p1_light, nil, nil, nil, font_map.tiny)
        -- 1P Live Voice Equalizer Badge & Speaking Aura
        if self.voice and self.voice.supported then
            local v1_talk, v1_lvl = self.voice:get_seat_state(1, self.local_pid)
            if v1_talk or (self.local_pid == 1 and v1_lvl > 0.06 and self.voice.mode ~= "mute") then
                G.setColor(10, 26, 44, 215)
                G.rectangle("fill", hp_x + hp_w - 44, hp_y + hp_h - 24, 38, 18, 5, 5)
                G.setColor(v1_talk and 92 or 120, v1_talk and 242 or 178, v1_talk and 148 or 230, 220)
                G.setLineWidth(1.2)
                G.rectangle("line", hp_x + hp_w - 44, hp_y + hp_h - 24, 38, 18, 5, 5)
                ui.draw_voice_eq(hp_x + hp_w - 40, hp_y + hp_h - 22, 30, 14, v1_lvl, v1_talk,
                    { 118, 255, 168, 255 }, { 84, 206, 255, 230 })
            end
            if v1_talk then
                ui.draw_speaking_glow(cx, y, hero_w, stage_h, 10, { 92, 242, 152, 255 }, v1_lvl)
            end
        end
        if is_host then
            add_btn("open_hero1", "更换 1P 主将", cx + 8, y + 182, hero_w - 16, 26, "azure", { small = true })
        else
            ui.draw_pill(cx + 12, y + 184, hero_w - 24, 22, "房主主控主将",
                { 14, 34, 62, 185 }, { 112, 178, 238, 130 }, T.p1_light, font_map.tiny_bold)
        end

        -- CENTER: Pinned Painted Campaign Map Postcard + 3 Cohesive Parchment Rule Plaques
        ui.draw_parchment_card(mid_x, y, mid_w, 148, {
            top = { 255, 250, 238, 255 },
            bot = { 238, 218, 174, 255 },
            border = { 138, 94, 40, 245 },
            border_w = 2,
            thumbtack = true,
            radius = 9,
        })
        local mp_x, mp_y, mp_w, mp_h = mid_x + 8, y + 10, mid_w - 16, 128
        ui.draw_stage_thumb(self.room.level_idx, mp_x, mp_y, mp_w, mp_h, {
            radius = 6, pad = 1, bg = { 42, 26, 12, 255 }, border = { 88, 56, 24, 255 }, border_w = 1.8,
        })
        -- Strong bottom dark scrim so text over bright grass is 100% razor-sharp!
        ui.draw_vgrad_rect(mp_x + 1, mp_y + mp_h - 52, mp_w - 2, 51, { 24, 12, 4, 0 }, { 22, 10, 4, 235 }, 4)
        local pk_key = get_stage_pack_info(self.room.level_idx)
        local pks = PACK_TAG_STYLES[pk_key] or PACK_TAG_STYLES.kr5
        ui.draw_pill(mp_x + 7, mp_y + 7, 68, 19, pks.era, pks.bg, pks.border, pks.fg, font_map.tiny_bold)
        if is_host then
            add_btn("open_stages", string.format("切换地图 (%d关)", catalog.TOTAL_STAGES or 201), mp_x + mp_w - 114, mp_y + 6, 108, 22, "wood", { tiny = true })
        end
        local df_info = DIFF_STYLES[self.room.level_difficulty] or DIFF_STYLES[2]
        ui.print_shadow("出征战役目标", mp_x + 10, mp_y + mp_h - 40, { 255, 224, 152, 245 }, nil, nil, nil, font_map.tiny)
        ui.print_shadow(get_stage_clean_title(self.room.level_idx), mp_x + 10, mp_y + mp_h - 23, { 255, 248, 224, 255 }, nil, nil, nil, font_map.hero)
        ui.print_shadow(df_info.stars, mp_x + mp_w - 72, mp_y + mp_h - 22, df_info.star_col or T.gold_bright, 64, "right", nil, font_map.small_bold)

        -- 3 Cohesive Tactile Rule Plaques under Map Postcard
        local ry_rules = y + 158
        local rh_rules = 56
        local rw_rule = math.floor((mid_w - 14) / 3)
        local econ_short = (self.room.econ_mode == "independent") and "独立 50/50" or "共享金库"
        local tower_short = (self.room.tower_mode == "owned") and "红蓝保护" or "自由共享"

        if is_host then
            add_btn("diff_cycle", "战役难度\n" .. df_info.name, mid_x, ry_rules, rw_rule, rh_rules, "parchment", {
                small = true, fg = df_info.col,
            })
            add_btn("econ_toggle", "军费账本\n" .. econ_short, mid_x + rw_rule + 7, ry_rules, rw_rule, rh_rules, "parchment", {
                small = true,
            })
            add_btn("tower_toggle", "防御塔权\n" .. tower_short, mid_x + (rw_rule + 7) * 2, ry_rules, rw_rule, rh_rules, "parchment", {
                small = true,
            })
        else
            local ro_rules = {
                { t = "战役难度", v = df_info.name, col = df_info.col },
                { t = "军费账本", v = econ_short, col = T.ink_text },
                { t = "防御塔权", v = tower_short, col = T.ink_text },
            }
            for i, rr in ipairs(ro_rules) do
                local rx_r = mid_x + (i - 1) * (rw_rule + 7)
                ui.draw_parchment_card(rx_r, ry_rules, rw_rule, rh_rules, { radius = 7 })
                ui.text(rr.t, rx_r, ry_rules + 9, T.ink_muted, font_map.tiny, rw_rule, "center")
                ui.text(rr.v, rx_r, ry_rules + 28, rr.col, font_map.small_bold, rw_rule, "center")
            end
        end

        -- RIGHT: 2P Crimson Ally Tall Vertical Card + Embossed Wax Seal
        G.setColor(34, 18, 6, 72)
        G.rectangle("fill", c2x + 2, y + 4, hero_w, stage_h, 10, 10)
        ui.draw_vgrad_rect(c2x, y, hero_w, stage_h, T.p2_top, T.p2_bot, 10)
        G.setColor(255, 180, 175, 76)
        G.setLineWidth(1.5)
        G.line(c2x + 10, y + 2, c2x + hero_w - 10, y + 2)
        G.setColor(T.p2_border[1], T.p2_border[2], T.p2_border[3], 255)
        G.setLineWidth(2.2)
        G.rectangle("line", c2x, y, hero_w, stage_h, 10, 10)

        ui.print_shadow("2P 红方协防", c2x + 10, y + 6, T.p2_light, nil, nil, nil, font_map.tiny_bold)

        -- Full Vertical Hero Art (2P)
        local hp2_x, hp2_y = c2x + 8, y + 24
        ui.draw_hero_big_portrait(self.room.heroes[2], hp2_x, hp2_y, hp_w, hp_h, {
            radius = 7, pad = 2, bg = { 44, 12, 14, 255 }, border = T.gold_mid, border_w = 2,
        })
        ui.draw_vgrad_rect(hp2_x + 2, hp2_y + hp_h - 46, hp_w - 4, 44, { 36, 8, 10, 0 }, { 32, 6, 8, 232 }, 4)
        ui.print_shadow(catalog.get_hero_label(self.room.heroes[2]), hp2_x + 8, hp2_y + hp_h - 36, T.gold_bright, nil, nil, nil, font_map.hero)
        ui.print_shadow("英雄 #" .. tostring(self.room.heroes[2]), hp2_x + 8, hp2_y + hp_h - 17, T.p2_light, nil, nil, nil, font_map.tiny)
        -- 2P Live Voice Equalizer Badge & Speaking Aura
        if self.voice and self.voice.supported then
            local v2_talk, v2_lvl = self.voice:get_seat_state(2, self.local_pid)
            if v2_talk or (self.local_pid == 2 and v2_lvl > 0.06 and self.voice.mode ~= "mute") then
                G.setColor(44, 12, 14, 215)
                G.rectangle("fill", hp2_x + hp_w - 44, hp2_y + hp_h - 24, 38, 18, 5, 5)
                G.setColor(v2_talk and 106 or 236, v2_talk and 244 or 162, v2_talk and 148 or 156, 220)
                G.setLineWidth(1.2)
                G.rectangle("line", hp2_x + hp_w - 44, hp2_y + hp_h - 24, 38, 18, 5, 5)
                ui.draw_voice_eq(hp2_x + hp_w - 40, hp2_y + hp_h - 22, 30, 14, v2_lvl, v2_talk,
                    { 255, 226, 118, 255 }, { 255, 132, 128, 235 })
            end
            if v2_talk then
                ui.draw_speaking_glow(c2x, y, hero_w, stage_h, 10, { 112, 244, 148, 255 }, v2_lvl)
            end
        end
        add_btn("open_hero2", "更换 2P 英雄", c2x + 8, y + 182, hero_w - 16, 26, "crimson", { small = true })

        -- Large smooth Royal Wax Seal cleanly nested in top-right of 2P Card (zero clipping, zero overlap!)
        local rdy_ok = self.peer_connected and ((is_host and self.peer_ready) or (not is_host and self.local_ready))
        local seal_st = (not self.peer_connected) and "waiting" or (rdy_ok and "ready" or "joined")
        ui.draw_wax_seal(c2x + hero_w - 28, y + 28, 28, seal_st, font_map)

        y = y + stage_h + 10

        -- Row 3: RECESSED DARK-OAK VELVET 12-TOWER ARMORY CHEST (50x50 Medallions!)
        local tray_h = 92
        ui.draw_armory_tray(cx, y, cw, tray_h, 9)
        local deck = self.room.towers or catalog.DEFAULT_TOWERS
        local icon_sz = 50
        local icon_gap = 9
        local total_tw = 12 * icon_sz + 11 * icon_gap
        local row_x = cx + math.floor((cw - total_tw) * 0.5)
        local row_y = y + 34
        local hovered_tw_name = nil

        for i = 1, 12 do
            local tid = deck[i]
            local ix = row_x + (i - 1) * (icon_sz + icon_gap)
            local is_hov = (tid ~= nil and mx >= ix and mx <= ix + icon_sz and my >= row_y and my <= row_y + icon_sz)
            local dy_lift = is_hov and -3 or 0
            if is_hov then hovered_tw_name = catalog.get_tower_name(tid) end

            -- Velvet socket recess
            G.setColor(22, 12, 6, 245)
            G.rectangle("fill", ix, row_y + dy_lift, icon_sz, icon_sz, 7, 7)
            if tid then
                ui.draw_tower_icon(tid, ix, row_y + dy_lift, icon_sz, icon_sz, {
                    radius = 7, pad = 2, bg = { 32, 18, 9, 250 },
                    border = is_hov and T.gold_bright or { 128, 86, 42, 235 },
                    border_w = is_hov and 2.2 or 1.4,
                })
            else
                G.setColor(92, 62, 32, 125)
                G.setLineWidth(1.2)
                G.rectangle("line", ix, row_y, icon_sz, icon_sz, 7, 7)
            end
        end

        ui.print_shadow(string.format("随军防御塔军械盘 (%d/12)", #deck), cx + 14, y + 8, T.gold_bright, nil, nil, nil, font_map.small_bold)
        ui.draw_pill(cx + 186, y + 7, 178, 19,
            hovered_tw_name and ("当前检阅：" .. hovered_tw_name) or "悬停纹章检阅防御塔",
            { 18, 10, 4, 175 }, { 196, 148, 72, 115 },
            hovered_tw_name and T.gold_bright or { 228, 202, 154, 215 }, font_map.tiny)

        if is_host then
            add_btn("open_guide", "新手教程", cx + cw - 208, y + 5, 76, 23, "parchment", { tiny = true, tab = 2 })
            add_btn("open_towers", string.format("配置 %d 选 12", catalog.TOTAL_TOWERS or 59), cx + cw - 126, y + 5, 114, 23, "wood", { tiny = true })
        else
            add_btn("open_guide", "新手教程", cx + cw - 196, y + 5, 76, 23, "parchment", { tiny = true, tab = 2 })
            ui.draw_pill(cx + cw - 114, y + 7, 102, 19, "房主配置卡组",
                { 18, 10, 4, 165 }, { 164, 122, 64, 115 }, { 224, 198, 152, 210 }, font_map.tiny)
        end

        y = y + tray_h + 11

        -- Row 4: SCULPTED 3D GLOSSY EMERALD "出征守关！" WAR PLAQUE
        local cta_h = 42
        local close_w = 122
        if is_host then
            local can_start = self.peer_connected
            local slbl = can_start and "出征守关！" or "等待 2P 队友加入..."
            add_btn("start_match", slbl, cx, y, cw - close_w - 12, cta_h, "battle", {
                large = true, disabled = not can_start, radius = 9,
            })
            add_btn("leave_room", "关闭房间", cx + cw - close_w, y, close_w, cta_h, "crimson", { radius = 9 })
        else
            local rlbl = self.local_ready and "已就绪 · 等待房主开局" or "点击准备就绪！"
            add_btn("toggle_ready", rlbl, cx, y, cw - close_w - 12, cta_h, "battle", {
                large = true, radius = 9,
            })
            add_btn("leave_room", "离开房间", cx + cw - close_w, y, close_w, cta_h, "crimson", { radius = 9 })
        end
    end

    -- Draw all buttons with hover state (skip sticky hover on Android touchscreens)
    self.buttons = btns
    local allow_hover = not proto.is_android()
    for _, b in ipairs(btns) do
        local hover = allow_hover and (mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h)
        ui.draw_button(b, hover, font_map)
    end

    ui.end_transform()
    G.pop()
end

-- Toggle (or explicitly set) Guest Ready state when inside a Co-op lobby room
function lobby:toggle_ready(force_ready)
    if self.view ~= "room" or self.role ~= "client" then
        return false
    end
    if not self.transport or not self.transport:is_connected() then
        return false
    end
    local next_state
    if type(force_ready) == "boolean" then
        next_state = force_ready
    else
        next_state = not self.local_ready
    end
    if self.local_ready == next_state then
        return self.local_ready
    end
    self.local_ready = next_state
    self.transport:send({
        t = "SET_GUEST",
        ready = self.local_ready,
        hero_idx = self.room and self.room.heroes and self.room.heroes[2] or (catalog.DEFAULT_HERO_2 or 54),
    })
    return self.local_ready
end

return lobby
