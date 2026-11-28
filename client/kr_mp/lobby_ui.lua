-- KR-MP 全中文双模式联机大厅（核心状态机、偏好/会话持久化、局域网/公网房间通信）
-- 子模块：
--   lobby_input.lua       : 键盘/鼠标/剪贴板输入与表驱动按钮分发
--   lobby_draw.lua        : 皇家战桌主界面渲染
--   lobby_draw_modals.lua : 新手指南/关卡/英雄/防御塔/语音调音弹窗渲染
--   autotest.lua          : M1/M2 多进程自动化联机回归驱动
local proto = require("kr_mp.proto")
local fonts = require("kr_mp.fonts")
local catalog = require("kr_mp.catalog")
local loadout = require("kr_mp.coop_loadout")
local updater = require("kr_mp.updater")
local lobby_prefs = require("kr_mp.lobby_prefs")
local lobby_net = require("kr_mp.lobby_net")
local lobby_input = require("kr_mp.lobby_input")
local lobby_draw = require("kr_mp.lobby_draw")
local autotest = require("kr_mp.autotest")
local stage_flow = require("kr_mp.stage_flow")

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
    if r.auto_next_stage == nil then r.auto_next_stage = true end
    loadout.normalize_room_loadout(r)
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
    server_host = nil,
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
    reinf_edit_pid = 1,

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
    server_handshaking = false,
    server_handshake_ts = 0,
    server_connect_silent = false,
    server_ver = nil,
    server_voice_ok = true,
    server_guest_stage_ok = false,
    server_lobby_reconnect_ok = false,
    server_direct_next_ok = false,
    _pending_chain_stage = nil,
    online_reconnecting_room = false,
    online_reconnect_attempt = 0,
    online_reconnect_next_ts = 0,
    _pending_lobby_reconnect = false,
    _pending_session_reconnect = false,
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
        cataclysm = loadout.DEFAULT_CATACLYSM,
        reinforcements = { [1] = loadout.DEFAULT_REINF, [2] = loadout.DEFAULT_REINF },
        max_tech = true,
        auto_next_stage = true,
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
            self.server_handshaking = false
            self.server_connect_silent = false
            self.transport:switch_mode("lan")
        end
        self.transport:stop_lan_scan()
        if self.sakura then self.sakura:scan_local(true) end
    elseif tab == "lan" then
        if prev == "online" then
            self.transport:close()
            self.server_connected = false
            self.server_handshaking = false
            self.server_connect_silent = false
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

-- === LAN / Sakura / Online Connection Actions (delegated to lobby_net.lua) ===

function lobby:is_room_link_alive() return lobby_net.is_room_link_alive(self) end
function lobby:exit_dead_online_room(reason_toast) return lobby_net.exit_dead_online_room(self, reason_toast) end
function lobby:broadcast_room_state() return lobby_net.broadcast_room_state(self) end
function lobby:host_lan_room() return lobby_net.host_lan_room(self) end
function lobby:on_lan_connected(target_ip, target_port) return lobby_net.on_lan_connected(self, target_ip, target_port) end
function lobby:reconnect_direct_session(sess) return lobby_net.reconnect_direct_session(self, sess) end
function lobby:join_lan_room(ip, port) return lobby_net.join_lan_room(self, ip, port) end
function lobby:on_online_connected() return lobby_net.on_online_connected(self) end
function lobby:flush_pending_online_action() return lobby_net.flush_pending_online_action(self) end
function lobby:connect_online_server(addr, silent_fail) return lobby_net.connect_online_server(self, addr, silent_fail) end
function lobby:ensure_online_connected(action) return lobby_net.ensure_online_connected(self, action) end
function lobby:refresh_online_rooms() return lobby_net.refresh_online_rooms(self) end
function lobby:send_create_online_room(password, is_public) return lobby_net.send_create_online_room(self, password, is_public) end
function lobby:create_online_room(password, is_public) return lobby_net.create_online_room(self, password, is_public) end
function lobby:send_join_online_room(clean_code, password) return lobby_net.send_join_online_room(self, clean_code, password) end
function lobby:join_online_room(code, password) return lobby_net.join_online_room(self, code, password) end
function lobby:send_reconnect_online(sess, silent) return lobby_net.send_reconnect_online(self, sess, silent) end
function lobby:reconnect_online_session(sess) return lobby_net.reconnect_online_session(self, sess) end
function lobby:leave_room() return lobby_net.leave_room(self) end

function lobby:return_to_lobby()
    if not self.transport or not self.transport:is_connected()
        or (self.lockstep and self.lockstep.phase == "DISCONNECTED") then
        self:leave_room()
        self.open = true
        return false
    end
    local sent = self.transport:send({ t = "RETURN_LOBBY", pid = self.local_pid })
    if not sent then
        self:leave_room()
        self.open = true
        return false
    end
    if not self.transport:is_online() then
        self:on_return_lobby(self.local_pid)
    end
    return true
end

function lobby:on_return_lobby(by_pid, room_data, msg)
    self.direct_auto_retry = nil
    self.online_reconnecting_room = false
    self._pending_lobby_reconnect = false
    if self.overlay then self.overlay.voice_panel_open = false end
    -- Old online server fallback: Host silently bounces through RETURN_LOBBY -> UPDATE_ROOM -> START_MATCH without flashing War Table
    if self.role == "host" and self._pending_chain_stage then
        local pending = self._pending_chain_stage
        self._pending_chain_stage = nil
        if room_data then self.room = room_data; ensure_room_defaults(self.room) end
        self.room.level_idx = pending.level_idx
        ensure_room_defaults(self.room)
        local peer_ok = (msg == nil or msg.peer_connected == nil) and true or (msg.peer_connected == true)
        self.peer_connected = peer_ok
        self.local_ready = true
        self.peer_ready = peer_ok
        self.open = false
        self.sub_modal = nil
        self:save_prefs()
        if peer_ok and self:is_room_link_alive() then
            self:broadcast_room_state()
            if self:host_start_match(true) then
                return
            end
        end
    end
    self._pending_chain_stage = nil
    stage_flow:reset()
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
    if main and main.handler and main.handler.active_item then
        local ai = main.handler.active_item
        local nm = ai.item_name
        if ai == game or (nm ~= "slots" and nm ~= "splash" and not ai.is_transition) then
            main.handler.next_item_name = "slots"
            main.handler.next_item_args = {}
        end
    end
    local peer_ok = true
    if msg and msg.peer_connected ~= nil then
        peer_ok = (msg.peer_connected == true)
    end
    local rdy_ok = peer_ok
    if msg and msg.peer_ready ~= nil then
        rdy_ok = peer_ok and (msg.peer_ready == true)
    end
    self.peer_connected = peer_ok
    self.local_ready = true
    self.peer_ready = rdy_ok
    self.view = "room"
    self.sub_modal = nil
    self.open = true
    if self.role == "host" and not self.transport:is_online() then
        self:broadcast_room_state()
    end
    self.boot:log("[LOBBY] Returned to War Table without disconnecting (by P%d, peer=%s)", tonumber(by_pid) or 0, tostring(peer_ok))
    self.overlay:show_toast(string.format("%dP 返回战桌（连接保持不断），可直接换关或再次出征！", tonumber(by_pid) or 0), 3.0)
end

function lobby:launch_chain_stage(target_level_idx, reason, requested_by_pid)
    if self.role ~= "host" then return false end
    local target = math.floor(tonumber(target_level_idx) or 0)
    if target < 1 or target > 999 then return false end
    if self.transport:is_online() and not self:is_room_link_alive() then
        self.overlay:show_toast("与公网服务器连接已断开，无法切换关卡！", 3.5)
        return false
    end
    if not self.peer_connected then
        self.overlay:show_toast("2P 队友未在线，无法切换关卡！", 3.5)
        return false
    end
    ensure_room_defaults(self.room)
    self.room.level_idx = target
    local label = catalog.get_stage_label(target)
    local prefix = (reason == "restart") and "正在原地重开：" or "正在自动进入下一关："
    if self.overlay then self.overlay:show_toast(prefix .. label, 2.5) end
    if self.transport:is_online() and self.server_direct_next_ok ~= true then
        self._pending_chain_stage = { level_idx = target, reason = reason or "next" }
        self.boot:log("[LOBBY] Old online server -> silent chain bounce to level=%d (reason=%s)", target, tostring(reason))
        local sent = self.transport:send({ t = "RETURN_LOBBY", pid = 1 })
        if not sent then self._pending_chain_stage = nil; return false end
        return true
    end
    self.boot:log("[LOBBY] Direct chaining to level=%d (reason=%s, by=P%d, online=%s)",
        target, tostring(reason), tonumber(requested_by_pid) or 1, tostring(self.transport:is_online()))
    return self:host_start_match(true)
end

function lobby:host_start_match(is_chain)
    if self.role ~= "host" then return false end
    if self.transport:is_online() and not self:is_room_link_alive() then
        self.overlay:show_toast("与公网服务器连接已断开，无法发车！请等待自动重连或关闭重开房间。", 4.0)
        return false
    end
    if not self.peer_connected then
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
    local slot_snap = self.coop:build_host_slot_snapshot(self.room.heroes, self.room.towers, self.room)
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
        cataclysm = self.room.cataclysm,
        reinforcements = { self.room.reinforcements[1], self.room.reinforcements[2] },
        max_tech = (self.room.max_tech ~= false),
        auto_next_stage = (self.room.auto_next_stage ~= false),
        slot_snapshot = slot_snap,
    }

    self.boot:log("[LOBBY] Host launching 2P Co-op match (online=%s, chain=%s, level=%d, seed=%d, delay=%d, econ=%s, tower=%s, deck=%d)",
        tostring(self.transport:is_online()), tostring(is_chain == true), cfg.level_idx, cfg.seed, cfg.input_delay_turns, cfg.econ_mode, cfg.tower_mode, #cfg.towers)
    local sent_ok = self.transport:send({ t = "START_MATCH", cfg = cfg, direct_chain = (is_chain == true) })
    if not sent_ok then
        self.overlay:show_toast("发送开局指令失败：网络连接已断开！请等待重连或退出重开房间。", 4.0)
        return false
    end
    self:save_prefs()

    if not self.transport:is_online() then
        self.open = false
        self.sub_modal = nil
        self.coop:prepare_match(1, cfg)
    end
    return true
end

function lobby:toggle_ready(force_ready)
    if self.view ~= "room" or self.role ~= "client" then return false end
    if not self:is_room_link_alive() then
        self.overlay:show_toast("与房间连接已断开，请等待自动重连或退出重新进房！", 3.5)
        return false
    end
    local next_state = (type(force_ready) == "boolean") and force_ready or (not self.local_ready)
    if self.local_ready == next_state then return self.local_ready end
    self.local_ready = next_state
    local sent_ok = self.transport:send({
        t = "SET_GUEST",
        ready = self.local_ready,
        hero_idx = self.room and self.room.heroes and self.room.heroes[2] or (catalog.DEFAULT_HERO_2 or 54),
        reinf = self.room and self.room.reinforcements and self.room.reinforcements[2] or loadout.DEFAULT_REINF,
    })
    if not sent_ok then
        self.local_ready = not next_state
        self.overlay:show_toast("同步准备状态失败：网络连接已中断！", 3.5)
        return false
    end
    return self.local_ready
end

-- === Incoming Network Message Router (Table-Driven) ===

local MSG_HANDLERS = {}

function MSG_HANDLERS.VOICE(self, msg)
    if self.voice then self.voice:on_voice_message(msg) end
end

function MSG_HANDLERS.SERVER_HELLO(self, msg)
    self.server_connected = true
    self.server_handshaking = false
    self.server_connect_silent = false
    self.server_ver = msg.server_ver
    self.server_voice_ok = (msg.voice_ok == true)
    self.server_guest_stage_ok = (msg.guest_stage_ok == true)
    self.server_lobby_reconnect_ok = (msg.lobby_reconnect_ok == true)
    self.server_direct_next_ok = (msg.direct_next_ok == true)
    self.online_rooms = msg.rooms or {}
    updater:note_server_version(msg.server_ver)
    self.boot:log("[LOBBY] Server hello OK (ver=%s, voice_ok=%s, guest_stage=%s, direct_next=%s, rooms=%d)",
        tostring(msg.server_ver), tostring(self.server_voice_ok), tostring(self.server_guest_stage_ok), tostring(self.server_direct_next_ok), #self.online_rooms)
    self:flush_pending_online_action()
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

function MSG_HANDLERS.ROOM_REJOINED(self, msg)
    self.online_reconnecting_room = false
    self.online_reconnect_attempt = 0
    self._pending_lobby_reconnect = false
    self._pending_session_reconnect = false
    self.local_pid = tonumber(msg.pid) or self.local_pid
    self.role = (self.local_pid == 1) and "host" or "client"
    self.online_room_code = msg.code or self.online_room_code
    self.online_token = msg.token or self.online_token
    if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
    self.peer_connected = (msg.peer_connected == true)
    self.peer_ready = (msg.peer_ready == true)
    if self.role == "host" and msg.guest_name then self.peer_name = msg.guest_name
    elseif self.role == "client" and msg.host_name then self.peer_name = msg.host_name end
    self.view = "room"
    self:save_session(self.online_room_code, self.local_pid, self.online_token)
    self.boot:log("[LOBBY] Auto-rejoined online room #%s as P%d (peer=%s)",
        tostring(self.online_room_code), self.local_pid, tostring(self.peer_connected))
    self.overlay:show_toast("公网房间 #" .. tostring(self.online_room_code) .. " 已自动重连恢复 √", 2.8)
end

function MSG_HANDLERS.ROOM_CLOSED(self, msg)
    self.online_reconnecting_room = false
    self.online_reconnect_attempt = 0
    self._pending_lobby_reconnect = false
    self._pending_session_reconnect = false
    self._pending_chain_stage = nil
    stage_flow:reset()
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
    self._pending_session_reconnect = false
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

local function validate_direct_guest_compat(self, msg, require_version_fields)
    local my_fl = tostring(KR_FL_VERSION or "8.2.0")
    local my_hash = proto.compute_script_hash()
    local check_ver = require_version_fields or (msg.proto ~= nil) or (msg.fl_ver ~= nil)
    if check_ver and (msg.proto ~= proto.PROTOCOL_VER or msg.fl_ver ~= my_fl) then
        self.transport:send({
            t = "ERROR",
            msg = string.format("版本不匹配！房主 FL=%s 协议=%d，客机 FL=%s 协议=%s",
                my_fl, proto.PROTOCOL_VER, tostring(msg.fl_ver), tostring(msg.proto)),
        })
        self.overlay:show_toast("已拒绝客机：游戏或补丁版本不一致！", 4)
        return false
    end
    if msg.script_hash and msg.script_hash ~= my_hash then
        self.transport:send({
            t = "ERROR",
            msg = string.format("核心脚本哈希不一致！房主=%s 客机=%s", my_hash, tostring(msg.script_hash)),
        })
        self.overlay:show_toast("已拒绝客机：游戏核心脚本不一致！", 4)
        return false
    end
    if msg.tick_len and math.abs(msg.tick_len - (TICK_LENGTH or 1 / 60)) > 1e-4 then
        self.transport:send({ t = "ERROR", msg = "帧率设置不一致！请双方统一以 60 FPS 启动。" })
        return false
    end
    return true
end

local function accept_direct_guest_into_room(self, msg, fallback_from_reconnect)
    self.peer_connected = true
    self.peer_ready = true
    self.peer_name = tostring(msg.name or "2P 队友")
    self.transport:send({
        t = "WELCOME",
        pid = 2,
        room = self.room,
        fallback_from_reconnect = (fallback_from_reconnect == true) or nil,
    })
    self:broadcast_room_state()
    if fallback_from_reconnect then
        self.boot:log("[LOBBY] Accepted reconnecting P2 seamlessly into host War Table (prev match ended)")
        self.overlay:show_toast("2P 队友重连上局（已结束），已自动同步接入当前战桌！", 3.5)
    else
        self.overlay:show_toast("2P 队友已加入局域网房间，可以开局了！", 2.2)
    end
end

function MSG_HANDLERS.HOT_RESUME_REQ(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    if self.lockstep and self.lockstep:handle_hot_resume_req(msg) then
        self.peer_connected = true
        self.peer_ready = true
        if autotest.on_hot_resumed then autotest:on_hot_resumed() end
    elseif not (self.coop and self.coop:is_active()) and self.view == "room" then
        -- Host crashed/restarted and is already waiting on the War Table: seamlessly pull P2 into
        -- the host's current lobby room instead of kicking P2 into a 180s disconnect loop!
        if validate_direct_guest_compat(self, msg, false) then
            accept_direct_guest_into_room(self, msg, true)
        else
            self.transport:drop_peer_socket("hot_resume_compat_mismatch", true)
        end
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
    elseif not (self.coop and self.coop:is_active()) and self.view == "room" then
        -- Host restarted and opened a fresh War Table room: accept P2 directly into the room!
        if validate_direct_guest_compat(self, msg, true) then
            accept_direct_guest_into_room(self, msg, true)
        else
            self.transport:drop_peer_socket("cold_reconnect_compat_mismatch", true)
        end
    else
        self.transport:send({ t = "ERROR", msg = "直连追帧重连失败：房主对局已结束或局号不匹配。" })
        self.transport:drop_peer_socket("cold_reconnect_reject", true)
    end
end

function MSG_HANDLERS.RETURN_LOBBY(self, msg)
    self:on_return_lobby(msg.pid, msg.room, msg)
end

function MSG_HANDLERS.HELLO(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    if self.coop and self.coop:is_active() then
        self.transport:send({ t = "ERROR", msg = "房主正在对局等待原队友重连，请稍候再试！" })
        self.transport:drop_peer_socket("busy_in_match", true)
        return
    end
    if not validate_direct_guest_compat(self, msg, true) then
        return
    end
    accept_direct_guest_into_room(self, msg, false)
end

function MSG_HANDLERS.WELCOME(self, msg)
    if self.role ~= "client" then return end
    self._pending_session_reconnect = false
    self.direct_auto_retry = nil
    self.local_pid = tonumber(msg.pid) or 2
    if msg.fallback_from_reconnect and self.coop and self.coop:is_active() then
        self.coop:leave_match()
    end
    if not self.transport:is_online() then
        self:clear_saved_session()
    end
    if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
    self.peer_connected = true
    self.local_ready = true
    self.view = "room"
    self.sub_modal = nil
    self.open = true
    if msg.fallback_from_reconnect then
        self.boot:log("[LOBBY] Reconnect seamlessly fell back into Host War Table (level=%s)",
            tostring(self.room and self.room.level_idx))
        self.overlay:show_toast("上局已结束，已自动为你同步并进入房主当前战桌！", 3.8)
    else
        self.overlay:show_toast("已加入局域网房间（你是 2P 红方）！", 2.0)
    end
end

function MSG_HANDLERS.ROOM_STATE(self, msg)
    local prev_lvl = self.room and self.room.level_idx
    if msg.room then self.room = msg.room; ensure_room_defaults(self.room) end
    if msg.peer_connected ~= nil then self.peer_connected = msg.peer_connected end
    if msg.peer_ready ~= nil then self.peer_ready = msg.peer_ready end
    if self.role == "host" and msg.guest_name then
        self.peer_name = msg.guest_name
    elseif self.role == "client" and msg.host_name then
        self.peer_name = msg.host_name
    end
    if prev_lvl and self.room and self.room.level_idx and prev_lvl ~= self.room.level_idx and self.view == "room" then
        if self.role == "host" then
            self:save_prefs()
            self.overlay:show_toast("2P 队友已切换关卡：" .. catalog.get_stage_label(self.room.level_idx), 2.5)
        elseif self.role == "client" then
            self.overlay:show_toast("房主已切换关卡：" .. catalog.get_stage_label(self.room.level_idx), 2.2)
        end
    end
end

function MSG_HANDLERS.SET_GUEST(self, msg)
    if self.role ~= "host" or self.transport:is_online() then return end
    ensure_room_defaults(self.room)
    if msg.ready ~= nil then self.peer_ready = msg.ready end
    if msg.hero_idx then
        self.room.heroes[2] = tonumber(msg.hero_idx) or self.room.heroes[2]
    end
    if type(msg.reinf) == "string" and #msg.reinf > 0 then
        self.room.reinforcements[2] = loadout.normalize_reinf(msg.reinf)
    end
    local req_lvl = tonumber(msg.level_idx)
    if req_lvl then
        req_lvl = math.floor(req_lvl)
        if req_lvl >= 1 and req_lvl <= 999 and req_lvl ~= self.room.level_idx then
            self.room.level_idx = req_lvl
            self:save_prefs()
            self.overlay:show_toast("2P 队友已切换关卡：" .. catalog.get_stage_label(req_lvl), 2.5)
        end
    end
    self:broadcast_room_state()
end

function MSG_HANDLERS.MATCH_FLOW(self, msg)
    stage_flow:on_message(msg)
end

function MSG_HANDLERS.START_MATCH(self, msg)
    if not msg.cfg then return end
    self._pending_chain_stage = nil
    if self.room then
        if tonumber(msg.cfg.level_idx) then
            self.room.level_idx = math.floor(tonumber(msg.cfg.level_idx))
        end
        if msg.cfg.auto_next_stage ~= nil then
            self.room.auto_next_stage = (msg.cfg.auto_next_stage == true)
        end
    end
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
    if self._pending_lobby_reconnect then
        self._pending_lobby_reconnect = false
        self:exit_dead_online_room("公网房间已失效（" .. tostring(msg.msg) .. "），已返回公网大厅，请重新建房或进房！")
        return
    end
    if self._pending_session_reconnect then
        self._pending_session_reconnect = false
        self:clear_saved_session()
        if not (self.coop and self.coop:is_active()) and self.view == "home" then
            self.role = "none"
            self.peer_connected = false
            self.online_room_code = nil
            self.online_token = nil
            if self.transport and not self.transport:is_online() then
                self.transport:close()
            end
        end
        self.overlay:show_toast("上次对局已失效（" .. tostring(msg.msg) .. "），已清理旧记录，请重新加入房主战桌！", 5.5)
        return
    end
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
    lobby_net.tick_reconnect_timers(self, now)
    lobby_net.dispatch_transport_events(self, self.transport:poll(), now)
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
