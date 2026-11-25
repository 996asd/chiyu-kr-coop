-- KR-MP 全中文双模式联机大厅（局域网 + 公网服务器 + 全100关/67英雄/41选12塔卡组 + 一键追帧重连 + 后台检查更新）
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")
local updater = require("kr_mp.updater")

local lobby = {
    boot = nil,
    transport = nil,
    lockstep = nil,
    coop = nil,
    overlay = nil,

    open = false,
    net_tab = "lan", -- "lan" | "online"
    view = "home",   -- "home" | "room"
    sub_modal = nil, -- nil | "stages" | "hero1" | "hero2" | "towers"
    stage_pack_idx = 1,
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
    online_rooms = {},
    online_room_code = nil,
    online_token = nil,
    saved_session = nil,

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
        level_difficulty = 2, -- 1=休闲, 2=普通, 3=老兵
        econ_mode = "independent", -- "independent" | "shared"
        tower_mode = "owned",      -- "owned" | "open"
        input_delay_turns = proto.INPUT_DELAY_TURNS, -- 2=局域网(100ms), 4=樱花映射(200ms), 6=抗抖(300ms)
        heroes = { [1] = 48, [2] = 49 }, -- 维斯珀 + 蕾琳
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

local DIFF_NAMES = { [1] = "休闲", [2] = "普通", [3] = "老兵" }
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
    if not r.heroes or not r.heroes[1] then r.heroes = { 48, 49 } end
    if not r.heroes[2] then r.heroes[2] = 49 end
    if not r.towers or #r.towers == 0 then
        r.towers = copy_array(catalog.DEFAULT_TOWERS)
    end
    r.level_idx = tonumber(r.level_idx) or 101
    r.level_mode = tonumber(r.level_mode) or 1
    r.level_difficulty = tonumber(r.level_difficulty) or 2
    r.econ_mode = r.econ_mode or "independent"
    r.tower_mode = r.tower_mode or "owned"
    r.input_delay_turns = normalize_delay_turns(r.input_delay_turns)
end

local function get_base_dir_safe()
    return (love and love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()) or "."
end

local function get_prefs_path()
    return get_base_dir_safe() .. "\\kr_mp_prefs.json"
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
end

function lobby:save_prefs()
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") then return end
    local prefs = {
        ip_input = self.ip_input,
        server_input = self.server_input,
        input_delay_turns = normalize_delay_turns(self.room and self.room.input_delay_turns),
        show_tower_marks = (self.coop == nil) or (self.coop.show_tower_marks ~= false),
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
        if log_dir then return log_dir .. "\\last_session.json" end
    end
    local base_dir = (love and love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()) or "."
    return base_dir .. "\\kr_mp_last_session.json"
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

function lobby:toggle()
    if self.coop and self.coop:is_active() then
        self.open = false
        return
    end
    self.open = not self.open
    self.sub_modal = nil
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
    self.focused_field = nil
    self.sub_modal = nil
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
        if not self.server_connected then
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
    self.overlay:show_toast("局域网房间已创建（端口 " .. tostring(res) .. "），等待 2P 加入...", 4)
    return true
end

function lobby:join_lan_room(ip, port)
    local target_ip = ip or self.ip_input or "127.0.0.1"
    local target_port = tonumber(port) or tonumber(os.getenv("KR_MP_PORT")) or proto.DEFAULT_TCP_PORT
    local parsed_ip, parsed_port = target_ip:match("^([^:]+):(%d+)$")
    if parsed_ip and parsed_port then
        target_ip = parsed_ip
        target_port = tonumber(parsed_port)
    end

    local ok, err = self.transport:join_lan(target_ip, target_port)
    if not ok then
        self.overlay:show_toast("连接局域网房主失败：" .. tostring(err), 4)
        return false
    end

    self.role = "client"
    self.local_pid = 2
    self.online_room_code = nil
    self.online_token = nil
    self.peer_connected = true
    self.local_ready = true
    self.peer_name = "房主 (" .. target_ip .. ")"
    self.view = "room"
    self.sub_modal = nil

    self.transport:send({
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "4.1.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "Player 2",
    })
    self.overlay:show_toast("已连接到局域网房主 " .. target_ip .. ":" .. tostring(target_port), 3.5)
    return true
end

-- === Online Relay Server Actions ===

function lobby:connect_online_server(addr, silent_fail)
    local target = (addr and addr ~= "") and addr or self.server_input
    local ok, err = self.transport:connect_online(target, proto.DEFAULT_ONLINE_PORT)
    if not ok then
        self.server_connected = false
        if not silent_fail then
            self.overlay:show_toast("连接公网服务器失败：" .. tostring(err), 4.5)
        end
        return false
    end
    self.server_connected = true
    self.transport:send({
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "4.1.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "Player",
    })
    return true
end

function lobby:ensure_online_connected()
    if self.transport:is_online() and self.transport:is_connected() and self.server_connected then
        return true
    end
    return self:connect_online_server(self.server_input, false)
end

function lobby:refresh_online_rooms()
    if not self:ensure_online_connected() then return false end
    self.transport:send({ t = "LIST_ROOMS" })
    return true
end

function lobby:create_online_room(password, is_public)
    if not self:ensure_online_connected() then return false end
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
        fl_ver = tostring(KR_FL_VERSION or "4.1.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        player_name = "Player 1",
    })
    return true
end

function lobby:join_online_room(code, password)
    local clean_code = tostring(code or self.code_input or ""):upper():gsub("%s+", "")
    if #clean_code < 3 then
        self.overlay:show_toast("请先输入 4 位房间码！", 3)
        return false
    end
    if not self:ensure_online_connected() then return false end
    self.transport:send({
        t = "JOIN_ROOM",
        code = clean_code,
        password = (password ~= nil) and password or self.pw_input or "",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "4.1.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        player_name = "Player 2",
    })
    return true
end

function lobby:reconnect_online_session(sess)
    sess = sess or self.saved_session or self:load_saved_session()
    if not sess then
        self.overlay:show_toast("未找到可重连的公网对局记录！", 3)
        return false
    end
    if not self:connect_online_server(sess.server, false) then
        return false
    end
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
        fl_ver = tostring(KR_FL_VERSION or "4.1.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
    })
    self.overlay:show_toast("正在向房间 #" .. tostring(sess.code) .. " 发起断线重连...", 4)
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
        self.overlay:show_toast("已退出局域网房间。", 2.5)
    else
        if self.server_connected and self.transport:is_connected() then
            self:refresh_online_rooms()
        end
        self.overlay:show_toast("已退出公网房间。", 2.5)
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
    if t == "SERVER_HELLO" then
        self.server_connected = true
        self.server_ver = msg.server_ver
        self.online_rooms = msg.rooms or {}
        updater:note_server_version(msg.server_ver)
        self.boot:log("[LOBBY] Server hello OK (ver=%s, rooms=%d)", tostring(msg.server_ver), #self.online_rooms)

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
        self.overlay:show_toast("公网房间 #" .. tostring(msg.code) .. " 已创建！把房间码发给好友即可加入！", 5)

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
        self.overlay:show_toast("已加入公网房间 #" .. tostring(msg.code) .. "（你是 2P 红方）！", 4)

    elseif t == "PEER_JOINED" then
        self.peer_connected = true
        self.peer_ready = (msg.peer_ready ~= false)
        self.peer_name = tostring(msg.name or "2P 队友")
        if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
        self.overlay:show_toast("2P 队友已加入房间 #" .. tostring(self.online_room_code) .. "，可以开局了！", 4)

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
        local my_fl = tostring(KR_FL_VERSION or "4.1.0")
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
        self.overlay:show_toast("2P 队友已加入局域网房间，可以开局了！", 4)

    elseif t == "WELCOME" and self.role == "client" then
        self.local_pid = tonumber(msg.pid) or 2
        if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
        self.peer_connected = true
        self.overlay:show_toast("已加入局域网房间（你是 2P 红方）！", 3.5)

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
        elseif ev.type == "peer_disconnected" then
            self.peer_connected = false
            self.peer_ready = false
            self.peer_name = "已断开"
            if self.lockstep and self.lockstep:is_active() then
                self.lockstep:on_peer_disconnected(ev.reason, false)
            else
                self.overlay:show_toast("队友已断开连接。", 3.5)
            end
        elseif ev.type == "server_disconnected" then
            self.server_connected = false
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
            self.room.level_idx = 101
            self.room.econ_mode = "independent"
            self.room.tower_mode = "owned"
            self.room.heroes = { 48, 49 }
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
            self.room.level_idx = 101
            self.room.econ_mode = "independent"
            self.room.tower_mode = "owned"
            self.room.heroes = { 48, 49 }
            self.room.towers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 23, 24 } -- Mix of KR5 + KR4 towers to test custom deck sync!
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
    if not self.open or not self.focused_field then return false end
    local f = self.focused_field
    if f == "ip" then
        local c = (t == "：") and ":" or t
        if c:match("^[%d%.:a-zA-Z%-]$") and #self.ip_input < 80 then
            self.ip_input = self.ip_input .. c
        end
    elseif f == "server" then
        local c = (t == "：") and ":" or t
        if c:match("^[%d%.:a-zA-Z%-]$") and #self.server_input < 80 then
            self.server_input = self.server_input .. c
        end
    elseif f == "code" then
        if t:match("^[%da-zA-Z]$") and #self.code_input < 6 then
            self.code_input = self.code_input .. t:upper()
        end
    elseif f == "pw" then
        if t:match("^[%w%-%_@#]$") and #self.pw_input < 16 then
            self.pw_input = self.pw_input .. t
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
    if key == "escape" then
        if self.sub_modal then
            self.sub_modal = nil
        else
            self.open = false
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
            self.focused_field = nil
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
    self.focused_field = nil

    if id == "close" then
        self.open = false
        self.sub_modal = nil
    elseif id == "check_update" then
        if updater.has_update then
            updater:open_download_page()
        else
            updater:start_check(true)
        end
    elseif id == "modal_back" then
        self.sub_modal = nil
    elseif id == "tab_lan" then
        self:switch_tab("lan")
    elseif id == "tab_online" then
        self:switch_tab("online")
    -- LAN Home
    elseif id == "host_lan" then
        self:host_lan_room()
    elseif id == "join_local" then
        self:join_lan_room("127.0.0.1", proto.DEFAULT_TCP_PORT)
    elseif id == "ip_box" then
        self.focused_field = "ip"
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
        self.focused_field = "server"
    elseif id == "paste_server" then
        self:paste_into_field("server")
    elseif id == "connect_server" then
        self.server_input = proto.sanitize_addr(self.server_input):sub(1, 80)
        self:save_prefs()
        self:connect_online_server(self.server_input, false)
    elseif id == "refresh_online" then
        self:refresh_online_rooms()
    elseif id == "code_box" then
        self.focused_field = "code"
    elseif id == "pw_box" then
        self.focused_field = "pw"
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
        self.sub_modal = "stages"
    elseif id == "open_hero1" and self.role == "host" then
        self.sub_modal = "hero1"
    elseif id == "open_hero2" then
        self.sub_modal = "hero2"
    elseif id == "open_towers" and self.role == "host" then
        ensure_room_defaults(self.room)
        self.sub_modal = "towers"
    elseif id == "diff_cycle" and self.role == "host" then
        self.room.level_difficulty = (self.room.level_difficulty % 3) + 1
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
        self.overlay:show_toast(tips[self.room.input_delay_turns], 3.2)
    elseif id == "toggle_tower_marks" and self.coop then
        self.coop.show_tower_marks = not self.coop.show_tower_marks
        self:save_prefs()
        self.overlay:show_toast(self.coop.show_tower_marks and "已开启本地防御塔底座红蓝标志（仅对自己生效）" or "已关闭本地防御塔归属标志（纯净画面）", 2.8)
    elseif id == "toggle_ready" and self.role == "client" then
        self.local_ready = not self.local_ready
        self.transport:send({ t = "SET_GUEST", ready = self.local_ready, hero_idx = self.room.heroes[2] })
    -- Sub-Modal Pickers
    elseif id == "stage_pack" and btn.pack_idx then
        self.stage_pack_idx = btn.pack_idx
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
        for _, b in ipairs(self.buttons) do
            if x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h then
                self._consumed_down = true
                self:handle_button(b)
                return true
            end
        end
        self.focused_field = nil
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

-- === Lobby Rendering ===

function lobby:draw()
    if not self.open or not love.graphics then return end

    local G = love.graphics
    local sw, sh = G.getWidth(), G.getHeight()
    local pw, ph = math.min(680, sw - 32), math.min(488, sh - 32)
    local px, py = math.floor((sw - pw) / 2), math.floor((sh - ph) / 2)

    if not self.font_title then self.font_title = fonts.get(17) end
    if not self.font then self.font = fonts.get(13) end
    if not self.font_small then self.font_small = fonts.get(12) end
    if not self.font_tiny then self.font_tiny = fonts.get(11) end

    local btns = {}
    local function add_btn(id, label, x, y, w, h, bg, extra)
        local b = { id = id, label = label, x = x, y = y, w = w, h = h, bg = bg }
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

    -- Backdrop
    G.setColor(5, 8, 15, 182)
    G.rectangle("fill", 0, 0, sw, sh)

    -- Main lobby card
    G.setColor(22, 28, 42, 248)
    G.rectangle("fill", px, py, pw, ph, 10, 10)
    G.setColor(110, 175, 255, 215)
    G.setLineWidth(2)
    G.rectangle("line", px, py, pw, ph, 10, 10)

    -- Title bar
    if self.font_title then G.setFont(self.font_title) end
    G.setColor(255, 232, 130, 255)
    G.print("赤羽的王国保卫战联机器（2P 合作守关）", px + 18, py + 12)
    local upd_lbl = updater.has_update and ("下载新版 v" .. tostring(updater.latest_version))
        or (updater.checking and "检查中..." or "检查更新")
    local upd_w = updater.has_update and 112 or 76
    local upd_bg = updater.has_update and { 28, 158, 86, 248 } or { 52, 68, 96, 225 }
    add_btn("check_update", upd_lbl, px + pw - 46 - upd_w, py + 10, upd_w, 26, upd_bg, { small = true })
    add_btn("close", "×", px + pw - 38, py + 10, 28, 26, { 150, 45, 45, 230 })

    if self.font_small then G.setFont(self.font_small) end
    G.setColor(175, 200, 230, 235)
    G.print(string.format("FL %s | 联机补丁 v%s | 脚本校验 %s | 60Hz 帧同步（按 F10 开关）",
        tostring(KR_FL_VERSION), proto.MOD_VERSION, proto.compute_script_hash()), px + 18, py + 37)

    if self.font then G.setFont(self.font) end

    if self.view == "home" then
        local ty = py + 60
        local tw = math.floor((pw - 44) / 2)
        local lan_bg = (self.net_tab == "lan") and { 38, 115, 195, 250 } or { 38, 46, 62, 220 }
        local onl_bg = (self.net_tab == "online") and { 30, 145, 95, 250 } or { 38, 46, 62, 220 }
        add_btn("tab_lan", "局域网联机（同Wi-Fi / 直连）", px + 18, ty, tw, 32, lan_bg)
        add_btn("tab_online", "公网服务器（大厅 / 房间码）", px + 26 + tw, ty, tw, 32, onl_bg)

        local y = ty + 42

        if self.net_tab == "lan" then
            add_btn("host_lan", "创建局域网房间（1P 房主 · 蓝方）", px + 18, y, pw - 36, 38, { 35, 110, 195, 240 })
            y = y + 48
            add_btn("join_local", "本机快速加入 127.0.0.1（2P 双开测试 · 红方）", px + 18, y, pw - 36, 34, { 185, 65, 55, 240 })
            y = y + 44

            G.setColor(220, 230, 245, 240)
            G.print("直连/映射：", px + 18, y + 6)
            local ip_x = px + 94
            local ip_w = pw - 94 - 166
            local ip_bg = (self.focused_field == "ip") and { 45, 62, 92, 255 } or { 32, 40, 58, 245 }
            local ip_disp = self.ip_input
            if #ip_disp > 42 then ip_disp = "..." .. ip_disp:sub(-39) end
            add_btn("ip_box", ip_disp .. (self.focused_field == "ip" and "_" or ""), ip_x, y, ip_w, 30, ip_bg, { small = true })
            add_btn("paste_ip", "粘贴", px + pw - 160, y, 52, 30, { 68, 92, 132, 240 }, { small = true })
            add_btn("join_ip", "直连加入", px + pw - 102, y, 84, 30, { 40, 145, 85, 240 }, { small = true })
            y = y + 34

            if self.font_tiny then G.setFont(self.font_tiny) end
            G.setColor(145, 205, 245, 230)
            G.print("樱花映射远程开黑：房主建 TCP 隧道映射本地端口 17777，2P 复制地址后点「粘贴」(或 Ctrl+V) 直连！", px + 18, y)
            if self.font then G.setFont(self.font) end
            y = y + 20

            G.setColor(255, 225, 130, 240)
            G.print("已发现的局域网房间（自动扫描 UDP 17778）：", px + 18, y)
            y = y + 24

            local rooms = self.transport:get_lan_rooms()
            if #rooms == 0 then
                G.setColor(150, 165, 185, 215)
                G.print("  暂未发现局域网房间... 同 Wi-Fi 请等房主开房；远程请直接粘贴樱花映射地址直连。", px + 18, y + 6)
            else
                for idx = 1, math.min(#rooms, 3) do
                    local r = rooms[idx]
                    G.setColor(34, 44, 64, 230)
                    G.rectangle("fill", px + 18, y, pw - 36, 34, 5, 5)
                    G.setColor(235, 245, 255, 255)
                    G.print(string.format("%s | %s | %s:%d (%d/2)",
                        r.name, catalog.get_stage_short(r.level_idx), r.ip, r.port, r.players), px + 28, y + 8)
                    add_btn("join_lan_room", "加入", px + pw - 96, y + 4, 72, 26, { 40, 145, 85, 240 }, { room = r })
                    y = y + 40
                end
            end
        else
            -- 公网服务器首页
            if self.saved_session then
                local s = self.saved_session
                add_btn("reconnect_last",
                    string.format("一键重连上次对局：房间 #%s (%dP) @ %s", tostring(s.code), tonumber(s.pid) or 2, tostring(s.server)),
                    px + 18, y, pw - 36, 34, { 205, 118, 22, 248 })
                y = y + 42
            end

            G.setColor(220, 230, 245, 240)
            G.print("服务器：", px + 18, y + 6)
            local srv_bg = (self.focused_field == "server") and { 45, 62, 92, 255 } or { 32, 40, 58, 245 }
            local srv_disp = self.server_input
            if #srv_disp > 38 then srv_disp = "..." .. srv_disp:sub(-35) end
            add_btn("server_box", srv_disp .. (self.focused_field == "server" and "_" or ""), px + 76, y, pw - 306, 28, srv_bg, { small = true })
            add_btn("paste_server", "粘贴", px + pw - 224, y, 48, 28, { 68, 92, 132, 240 }, { small = true })
            local conn_bg = self.server_connected and { 35, 140, 82, 240 } or { 45, 105, 185, 240 }
            local conn_lbl = self.server_connected and ("已连 " .. self.transport:get_rtt_ms() .. "ms") or "连接"
            add_btn("connect_server", conn_lbl, px + pw - 170, y, 84, 28, conn_bg, { small = true })
            add_btn("refresh_online", "刷新列表", px + pw - 80, y, 62, 28, { 62, 82, 112, 240 }, { small = true })
            y = y + 38

            local pw_bg = (self.focused_field == "pw") and { 45, 62, 92, 255 } or { 32, 40, 58, 245 }
            local pw_disp = (#self.pw_input > 0 and self.pw_input or "无密码(选填)") .. (self.focused_field == "pw" and "_" or "")
            G.setColor(220, 230, 245, 240)
            G.print("密码：", px + 18, y + 6)
            add_btn("pw_box", pw_disp, px + 68, y, 136, 28, pw_bg)
            add_btn("toggle_public", self.room_public and "公开大厅" or "仅房间码", px + 212, y, 88, 28,
                self.room_public and { 42, 118, 88, 240 } or { 115, 72, 145, 240 })
            add_btn("create_online", "创建公网房间（1P 房主）", px + 308, y, pw - 326, 28, { 35, 110, 195, 245 })
            y = y + 38

            G.setColor(220, 230, 245, 240)
            G.print("房间码：", px + 18, y + 6)
            local code_bg = (self.focused_field == "code") and { 45, 62, 92, 255 } or { 32, 40, 58, 245 }
            local code_disp = (#self.code_input > 0 and self.code_input or "4位房间码") .. (self.focused_field == "code" and "_" or "")
            add_btn("code_box", code_disp, px + 78, y, 126, 28, code_bg)
            add_btn("join_code", "凭房间码进房（2P 队友）", px + 212, y, pw - 230, 28, { 185, 65, 55, 240 })
            y = y + 38

            G.setColor(255, 225, 130, 240)
            G.print("公开在线房间列表 (" .. tostring(#self.online_rooms) .. ")：", px + 18, y)
            y = y + 22

            if not self.server_connected then
                G.setColor(170, 180, 198, 225)
                G.print("  点击「连接」接入中继服（房主开本地中继服 + 樱花映射 TCP 17780 即可免服务器享 5 分钟断线重连）。", px + 18, y + 6)
            elseif #self.online_rooms == 0 then
                G.setColor(150, 165, 185, 215)
                G.print("  已连接服务器！当前暂无公开房间，可点击「创建公网房间」或「刷新列表」。", px + 18, y + 6)
            else
                local max_show = self.saved_session and 3 or 4
                for idx = 1, math.min(#self.online_rooms, max_show) do
                    local r = self.online_rooms[idx]
                    G.setColor(34, 44, 64, 232)
                    G.rectangle("fill", px + 18, y, pw - 36, 32, 5, 5)
                    G.setColor(235, 245, 255, 255)
                    local pw_tag = r.has_password and " [需密码]" or ""
                    G.print(string.format("#%s | %s | %s | %d/2%s",
                        tostring(r.code), tostring(r.name), catalog.get_stage_short(r.level_idx), tonumber(r.players) or 1, pw_tag),
                        px + 26, y + 7)
                    add_btn("join_online_room", "加入", px + pw - 92, y + 3, 68, 26, { 40, 145, 85, 240 }, { room = r })
                    y = y + 36
                end
            end
        end

    elseif self.sub_modal == "stages" then
        -- === 全 100 关分页中文选择器 ===
        local y = py + 62
        G.setColor(255, 232, 130, 255)
        G.print("选择合作关卡（共 100 关 · 含 5代/3代/2代/1代）", px + 18, y + 4)
        add_btn("modal_back", "返回房间", px + pw - 108, y, 90, 26, { 155, 65, 65, 235 })
        y = y + 34

        local packs = catalog.STAGE_PACKS
        local tab_w = math.floor((pw - 36 - (#packs - 1) * 6) / #packs)
        for i, pk in ipairs(packs) do
            local bg = (i == self.stage_pack_idx) and { 35, 135, 95, 248 } or { 42, 52, 72, 225 }
            add_btn("stage_pack", pk.name, px + 18 + (i - 1) * (tab_w + 6), y, tab_w, 28, bg, { pack_idx = i })
        end
        y = y + 36

        local pack = packs[self.stage_pack_idx] or packs[1]
        local cols = 5
        local gap = 6
        local cw = math.floor((pw - 36 - (cols - 1) * gap) / cols)
        local ch = 46
        for i, st in ipairs(pack.stages) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local bx = px + 18 + col * (cw + gap)
            local by = y + row * (ch + gap)
            local sel = (self.room.level_idx == st.idx)
            local bg = sel and { 32, 155, 82, 250 } or { 38, 48, 68, 235 }
            add_btn("pick_stage", string.format("%d\n%s", st.idx, st.name), bx, by, cw, ch, bg, { level_idx = st.idx, tiny = true })
        end

    elseif self.sub_modal == "hero1" or self.sub_modal == "hero2" then
        -- === 全 67 英雄分页中文选择器 ===
        local is_h1 = (self.sub_modal == "hero1")
        local cur_hero = is_h1 and self.room.heroes[1] or self.room.heroes[2]
        local y = py + 62
        G.setColor(is_h1 and 110 or 255, is_h1 and 200 or 125, is_h1 and 255 or 125, 255)
        G.print(is_h1 and "选择 1P 房主英雄（蓝方 · 共 67 位）" or "选择 2P 队友英雄（红方 · 共 67 位）", px + 18, y + 4)
        add_btn("modal_back", "返回房间", px + pw - 108, y, 90, 26, { 155, 65, 65, 235 })
        y = y + 34

        local packs = catalog.HERO_PACKS
        local tab_w = math.floor((pw - 36 - (#packs - 1) * 6) / #packs)
        for i, pk in ipairs(packs) do
            local bg = (i == self.hero_pack_idx) and { 45, 110, 185, 248 } or { 42, 52, 72, 225 }
            add_btn("hero_pack", pk.name, px + 18 + (i - 1) * (tab_w + 6), y, tab_w, 28, bg, { pack_idx = i })
        end
        y = y + 38

        local pack = packs[self.hero_pack_idx] or packs[1]
        local cols = 4
        local gap = 8
        local cw = math.floor((pw - 36 - (cols - 1) * gap) / cols)
        local ch = 48
        for i, h in ipairs(pack.heroes) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local bx = px + 18 + col * (cw + gap)
            local by = y + row * (ch + gap)
            local sel = (cur_hero == h.idx)
            local bg = sel and (is_h1 and { 35, 130, 215, 250 } or { 195, 62, 68, 250 }) or { 38, 48, 68, 235 }
            add_btn("pick_hero", string.format("#%d %s", h.idx, h.name), bx, by, cw, ch, bg, { hero_idx = h.idx, small = true })
        end

    elseif self.sub_modal == "towers" then
        -- === 41 选 12 防御塔卡组配置器 ===
        ensure_room_defaults(self.room)
        local selected = {}
        for _, tid in ipairs(self.room.towers) do selected[tid] = true end

        local y = py + 62
        G.setColor(255, 232, 130, 255)
        G.print(string.format("配置联机防御塔卡组：已选 %d / 12 座（点击增减）", #self.room.towers), px + 18, y + 4)
        add_btn("towers_default", "恢复默认12塔", px + pw - 216, y, 102, 26, { 68, 92, 130, 235 })
        add_btn("modal_back", "完成返回", px + pw - 106, y, 88, 26, { 35, 145, 82, 245 })
        y = y + 34

        local packs = catalog.TOWER_PACKS
        local tab_w = math.floor((pw - 36 - 8) / 2)
        for i, pk in ipairs(packs) do
            local bg = (i == self.tower_pack_idx) and { 115, 72, 155, 248 } or { 42, 52, 72, 225 }
            add_btn("tower_pack", pk.name, px + 18 + (i - 1) * (tab_w + 8), y, tab_w, 28, bg, { pack_idx = i })
        end
        y = y + 36

        local pack = packs[self.tower_pack_idx] or packs[1]
        local cols = 4
        local gap = 7
        local cw = math.floor((pw - 36 - (cols - 1) * gap) / cols)
        local ch = 44
        for i, tw in ipairs(pack.towers) do
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local bx = px + 18 + col * (cw + gap)
            local by = y + row * (ch + gap)
            local is_sel = selected[tw.idx] == true
            local bg = is_sel and { 32, 145, 78, 248 } or { 38, 46, 64, 230 }
            local lbl = (is_sel and "√ " or "") .. tw.name
            add_btn("pick_tower", lbl, bx, by, cw, ch, bg, { tower_idx = tw.idx, small = true })
        end

    else
        -- === 房间准备界面（局域网 & 公网共用） ===
        ensure_room_defaults(self.room)
        local y = py + 60
        local rtt = self.transport:get_rtt_ms()
        local room_prefix = self.transport:is_online()
            and ("公网房间 #" .. tostring(self.online_room_code or "----") .. " | ")
            or ("TCP端口:" .. tostring(self.transport:get_port()) .. " (樱花映射填此端口) | ")
        local conn_txt = self.peer_connected
            and string.format("%s2/2 已连接（延迟 %dms）", room_prefix, rtt)
            or string.format("%s1/2 等待 2P 队友加入...", room_prefix)
        G.setColor(self.peer_connected and 110 or 255, self.peer_connected and 245 or 210, 120, 255)
        G.print(conn_txt, px + 18, y)
        y = y + 26

        -- P1 & P2 英雄卡片
        local cw = math.floor((pw - 48) / 2)
        G.setColor(28, 52, 88, 225)
        G.rectangle("fill", px + 18, y, cw, 74, 6, 6)
        G.setColor(90, 180, 255, 255)
        G.rectangle("line", px + 18, y, cw, 74, 6, 6)
        G.print("1P · 房主（蓝方）", px + 28, y + 8)
        local h1_lbl = "英雄1：" .. catalog.get_hero_label(self.room.heroes[1])
        if self.role == "host" then
            add_btn("open_hero1", h1_lbl .. " [更换]", px + 26, y + 36, cw - 16, 28, { 45, 95, 165, 240 })
        else
            G.setColor(230, 242, 255, 255)
            G.print(h1_lbl, px + 28, y + 40)
        end

        local c2x = px + 30 + cw
        G.setColor(82, 32, 38, 225)
        G.rectangle("fill", c2x, y, cw, 74, 6, 6)
        G.setColor(255, 100, 100, 255)
        G.rectangle("line", c2x, y, cw, 74, 6, 6)
        G.print("2P · 队友（红方）" .. (self.peer_connected and " [已就绪]" or " [等待中]"), c2x + 10, y + 8)
        local h2_lbl = "英雄2：" .. catalog.get_hero_label(self.room.heroes[2])
        add_btn("open_hero2", h2_lbl .. " [更换]", c2x + 8, y + 36, cw - 16, 28, { 155, 55, 65, 240 })
        y = y + 86

        local is_host = (self.role == "host")

        -- 关卡行
        G.setColor(34, 44, 64, 220)
        G.rectangle("fill", px + 18, y, pw - 36, 36, 5, 5)
        G.setColor(255, 240, 150, 255)
        G.print("当前关卡：" .. catalog.get_stage_label(self.room.level_idx), px + 28, y + 9)
        if is_host then
            add_btn("open_stages", "选择关卡 (100关)", px + pw - 166, y + 4, 140, 28, { 48, 112, 175, 245 })
        end
        y = y + 44

        -- 防御塔卡组行
        G.setColor(34, 44, 64, 220)
        G.rectangle("fill", px + 18, y, pw - 36, 36, 5, 5)
        if self.font_small then G.setFont(self.font_small) end
        G.setColor(210, 232, 255, 245)
        G.print(string.format("携带卡组(%d/12)：%s", #self.room.towers, catalog.format_tower_summary(self.room.towers)), px + 28, y + 10)
        if is_host then
            add_btn("open_towers", "配置卡组 (41选12)", px + pw - 166, y + 4, 140, 28, { 112, 68, 152, 245 })
        end
        if self.font then G.setFont(self.font) end
        y = y + 46

        -- 联机规则四项（含樱花映射抗抖动网络缓冲档位）+ 个人防御塔标志开关
        local diff_lbl = "难度:" .. (DIFF_NAMES[self.room.level_difficulty] or "普通")
        local econ_lbl = (self.room.econ_mode == "independent") and "经济:独立(50/50)" or "经济:共享金币"
        local tower_lbl = (self.room.tower_mode == "owned") and "塔权:红蓝保护" or "塔权:自由共享"
        local d_turns = normalize_delay_turns(self.room.input_delay_turns)
        local delay_lbl = DELAY_LABELS[d_turns] or "缓冲:局域网100ms"
        local marks_on = (self.coop == nil) or (self.coop.show_tower_marks ~= false)

        if is_host then
            local rw = math.floor((pw - 36 - 18) / 4)
            add_btn("diff_cycle", diff_lbl, px + 18, y, rw, 34, { 52, 68, 96, 240 }, { small = true })
            add_btn("econ_toggle", econ_lbl, px + 18 + (rw + 6), y, rw, 34, { 45, 98, 72, 240 }, { small = true })
            add_btn("tower_toggle", tower_lbl, px + 18 + (rw + 6) * 2, y, rw, 34, { 108, 65, 130, 240 }, { small = true })
            local dbg = (d_turns >= 4) and { 155, 95, 32, 245 } or { 45, 92, 132, 240 }
            add_btn("delay_cycle", delay_lbl, px + 18 + (rw + 6) * 3, y, rw, 34, dbg, { small = true })
            y = y + 42
            if self.font_tiny then G.setFont(self.font_tiny) end
            G.setColor(165, 195, 225, 225)
            local tip = (rtt >= 65 and d_turns == 2)
                and "检测到延迟偏高：建议把右侧「缓冲」切换为【樱花200ms】消除跨网抖动卡顿！"
                or "提示：用樱花映射远程开黑时，建议将「缓冲」调为【樱花200ms】；右侧可自选是否显示塔底归属标志。"
            G.print(tip, px + 18, y + 6)
            add_btn("toggle_tower_marks", marks_on and "我的塔标:开" or "我的塔标:关",
                px + pw - 118, y, 100, 24, marks_on and { 42, 112, 145, 235 } or { 68, 74, 88, 225 }, { tiny = true })
        else
            if self.font_small then G.setFont(self.font_small) end
            G.setColor(215, 230, 250, 245)
            G.print(string.format("规则：%s | %s | %s | %s", diff_lbl, econ_lbl, tower_lbl, delay_lbl), px + 18, y + 8)
            y = y + 36
            if self.font_tiny then G.setFont(self.font_tiny) end
            G.setColor(165, 195, 225, 225)
            G.print("提示：可点击红色卡片更换 2P 英雄；右侧可自由开关自己画面中的防御塔归属标志。", px + 18, y + 6)
            add_btn("toggle_tower_marks", marks_on and "我的塔标:开" or "我的塔标:关",
                px + pw - 118, y, 100, 24, marks_on and { 42, 112, 145, 235 } or { 68, 74, 88, 225 }, { tiny = true })
        end

        -- 底部操作栏
        if self.font then G.setFont(self.font) end
        if is_host then
            local sbg = self.peer_connected and { 32, 165, 80, 245 } or { 75, 82, 92, 200 }
            local slbl = self.peer_connected and "开始双人合作守关！" or "等待 2P 队友加入房间..."
            add_btn("start_match", slbl, px + 18, py + ph - 52, pw - 166, 38, sbg)
            add_btn("leave_room", "关闭房间", px + pw - 138, py + ph - 52, 120, 38, { 165, 50, 50, 235 })
        else
            local rbg = self.local_ready and { 35, 150, 80, 240 } or { 165, 120, 30, 240 }
            local rlbl = self.local_ready and "已就绪（等待房主开始游戏）" or "点击准备就绪"
            add_btn("toggle_ready", rlbl, px + 18, py + ph - 52, pw - 166, 38, rbg)
            add_btn("leave_room", "离开房间", px + pw - 138, py + ph - 52, 120, 38, { 165, 50, 50, 235 })
        end
    end

    -- Draw all buttons with hover highlight
    self.buttons = btns
    local mx, my = 0, 0
    if love.mouse and love.mouse.getPosition then mx, my = love.mouse.getPosition() end

    for _, b in ipairs(btns) do
        local hover = (mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h)
        local c = b.bg
        if hover then
            G.setColor(math.min(255, c[1] + 28), math.min(255, c[2] + 28), math.min(255, c[3] + 28), 255)
        else
            G.setColor(c[1], c[2], c[3], c[4])
        end
        G.rectangle("fill", b.x, b.y, b.w, b.h, 5, 5)
        G.setColor(255, 255, 255, hover and 235 or 125)
        G.setLineWidth(1.5)
        G.rectangle("line", b.x, b.y, b.w, b.h, 5, 5)
        G.setColor(255, 255, 255, 255)

        if b.tiny and self.font_tiny then
            G.setFont(self.font_tiny)
            G.printf(b.label, b.x + 2, b.y + 8, b.w - 4, "center")
        elseif b.small and self.font_small then
            G.setFont(self.font_small)
            G.printf(b.label, b.x + 2, b.y + math.floor((b.h - 15) / 2), b.w - 4, "center")
        else
            if self.font then G.setFont(self.font) end
            G.printf(b.label, b.x + 2, b.y + math.floor((b.h - 17) / 2), b.w - 4, "center")
        end
    end

    G.pop()
end

return lobby
