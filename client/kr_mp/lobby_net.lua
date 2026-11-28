-- KR-MP Lobby Network Connector & Transport Event Dispatcher
-- Extracted from lobby_ui.lua to keep LAN/Sakura/Online connection lifecycle & auto-reconnect cohesive.
local proto = require("kr_mp.proto")
local lobby_prefs = require("kr_mp.lobby_prefs")
local autotest = require("kr_mp.autotest")
local stage_flow = require("kr_mp.stage_flow")

local M = {}

function M.is_room_link_alive(self)
    if not self.transport then return false end
    if self.transport:is_online() then
        return self.server_connected == true and self.transport:is_connected() and (not self.online_reconnecting_room)
    end
    return self.transport:is_connected()
end

function M.exit_dead_online_room(self, reason_toast)
    self.online_reconnecting_room = false
    self.online_reconnect_attempt = 0
    self._pending_lobby_reconnect = false
    self._pending_session_reconnect = false
    self._pending_chain_stage = nil
    stage_flow:reset()
    self:clear_saved_session()
    self.role = "none"
    self.peer_connected = false
    self.peer_ready = false
    self.local_ready = false
    self.online_room_code = nil
    self.online_token = nil
    self.view = "home"
    self.sub_modal = nil
    if self.server_connected and self.transport and self.transport:is_connected() then
        self:refresh_online_rooms()
    end
    if reason_toast and self.overlay then
        self.overlay:show_toast(reason_toast, 5.0)
    end
end

function M.broadcast_room_state(self)
    if self.role ~= "host" then return false end
    self.ensure_room_defaults(self.room)
    if self.transport:is_online() then
        if not self:is_room_link_alive() then
            if self.overlay then
                self.overlay:show_toast("与公网服务器连接已断开，房间修改尚未同步（请等待重连或重开房间）！", 3.5)
            end
            return false
        end
        return self.transport:send({ t = "UPDATE_ROOM", room = self.room }) == true
    end
    self.transport:update_advert({
        name = self.room.name,
        level_idx = self.room.level_idx,
        players = self.peer_connected and 2 or 1,
    })
    if self.peer_connected then
        return self.transport:send({ t = "ROOM_STATE", room = self.room, peer_ready = self.peer_ready }) == true
    end
    return true
end

function M.host_lan_room(self)
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
    self._pending_session_reconnect = false
    if self.saved_session and self.saved_session.mode == "direct" then
        self:clear_saved_session()
    end
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
        elseif self.net_tab == "sakura" then
            self.overlay:show_toast("战桌已建好，但未检测到活跃樱花隧道！请先点上方「樱花助手」开启 TCP " .. tostring(res) .. " 隧道，否则异地队友连不上！", 5.0)
        else
            self.overlay:show_toast("局域网战桌已创建（TCP " .. tostring(res) .. " · 内置热续传），同 Wi-Fi 队友可直接揭榜加入！", 3.0)
        end
    end
    return true
end

function M.on_lan_connected(self, target_ip, target_port)
    local info = self.pending_lan_join
    self.pending_lan_join = nil
    target_ip = target_ip or (info and info.ip) or self.last_direct_host or "127.0.0.1"
    target_port = tonumber(target_port) or (info and info.port) or self.last_direct_port or proto.DEFAULT_TCP_PORT
    self.last_direct_host = target_ip
    self.last_direct_port = target_port

    if self.coop and self.coop:is_active() and self.lockstep and self.lockstep:is_active()
        and self.lockstep.phase == "WAIT_RECONNECT" then
        self.boot:log("[LOBBY] Direct Hot-Resume TCP reconnected -> sending HOT_RESUME_REQ")
        self.transport:send(self.lockstep:build_hot_resume_req())
        return
    end

    if info and info.cold_reconnect then
        local sess = info.cold_reconnect
        self.role = "client"
        self.local_pid = 2
        self.online_room_code = nil
        self.online_token = nil
        self.peer_connected = true
        self.peer_name = "房主 (" .. tostring(target_ip) .. ")"
        self._pending_session_reconnect = true
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
            name = "Player 2",
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
    self._pending_session_reconnect = false
    if self.saved_session and self.saved_session.mode == "direct" then
        self:clear_saved_session()
    end
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

function M.reconnect_direct_session(self, sess)
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

function M.join_lan_room(self, ip, port)
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

function M.on_online_connected(self)
    self.server_connected = false
    self.server_handshaking = true
    self.server_handshake_ts = (love and love.timer and love.timer.getTime()) or os.clock()
    self.transport:send({
        t = "HELLO",
        proto = proto.PROTOCOL_VER,
        mod_ver = proto.MOD_VERSION,
        fl_ver = tostring(KR_FL_VERSION or "8.2.0"),
        script_hash = proto.compute_script_hash(),
        tick_len = TICK_LENGTH or (1 / 60),
        name = "Player",
    })
end

function M.flush_pending_online_action(self)
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
        self:send_reconnect_online(act.sess, false)
    elseif act.kind == "reconnect_lobby" and act.sess then
        self._pending_lobby_reconnect = true
        self:send_reconnect_online(act.sess, true)
    end
end

function M.connect_online_server(self, addr, silent_fail)
    local target = (addr and addr ~= "") and addr or self.server_input
    self.server_connected = false
    self.server_handshaking = false
    self.server_connect_silent = (silent_fail == true)
    local ok, status_or_err = self.transport:connect_online(target, proto.DEFAULT_ONLINE_PORT, silent_fail)
    if not ok then
        self.server_connected = false
        self.server_handshaking = false
        self.pending_online_action = nil
        if not silent_fail then
            self.overlay:show_toast("连接公网服务器失败：" .. tostring(status_or_err), 4.5)
        end
        return false
    end
    if status_or_err == "connected" then
        self:on_online_connected()
    elseif not silent_fail then
        self.overlay:show_toast("正在连接公网服务器 " .. tostring(target) .. "...", 2.5)
    end
    return true
end

function M.ensure_online_connected(self, action)
    if self.transport:is_online() and self.transport:is_connected() and self.server_connected then
        return true
    end
    if action then self.pending_online_action = action end
    if self.transport:is_online() and (self.transport:is_connecting() or self.server_handshaking) then
        self.server_connect_silent = false
        if self.transport.online_backend then
            self.transport.online_backend.connect_silent = false
        end
        return false, "connecting"
    end
    local ok = self:connect_online_server(self.server_input, false)
    if ok and self.server_connected then return true end
    return false, ok and "connecting" or "failed"
end

function M.refresh_online_rooms(self)
    local ready = self:ensure_online_connected({ kind = "list_rooms" })
    if not ready then return true end
    self.transport:send({ t = "LIST_ROOMS" })
    return true
end

function M.send_create_online_room(self, password, is_public)
    self.ensure_room_defaults(self.room)
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

function M.create_online_room(self, password, is_public)
    local pw = (password ~= nil) and password or self.pw_input or ""
    local pub = (is_public ~= nil) and is_public or self.room_public
    local ready, st = self:ensure_online_connected({ kind = "create_room", password = pw, is_public = pub })
    if not ready then return st == "connecting" end
    self:send_create_online_room(pw, pub)
    return true
end

function M.send_join_online_room(self, clean_code, password)
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

function M.join_online_room(self, code, password)
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

function M.send_reconnect_online(self, sess, silent)
    self.online_room_code = sess.code
    self.online_token = sess.token
    self.local_pid = tonumber(sess.pid) or 2
    self.role = (self.local_pid == 1) and "host" or "client"
    if not silent then
        self._pending_session_reconnect = true
    end
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
    if not silent and self.overlay then
        self.overlay:show_toast("正在向房间 #" .. tostring(sess.code) .. " 发起断线重连...", 4)
    end
end

function M.reconnect_online_session(self, sess)
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

function M.leave_room(self)
    local was_in_match = (self.coop and self.coop:is_active()) == true
    self.direct_auto_retry = nil
    self.online_reconnecting_room = false
    self.online_reconnect_attempt = 0
    self._pending_lobby_reconnect = false
    self._pending_session_reconnect = false
    self._pending_chain_stage = nil
    stage_flow:reset()
    if self.transport:is_online() and self.transport:is_connected() then
        self.transport:send({ t = "LEAVE_ROOM" })
    end
    if was_in_match then
        self.coop:leave_match()
        self.open = true
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

-- === Background Reconnect Timers & Table-Driven Transport Event Dispatch ===

function M.tick_reconnect_timers(self, now)
    if self.server_handshaking and not self.server_connected and (now - (self.server_handshake_ts or 0)) >= 3.5 then
        local was_silent = self.server_connect_silent
        self.server_handshaking = false
        self.server_connect_silent = false
        self.pending_online_action = nil
        if self.transport and self.transport:is_online() then self.transport:close() end
        if not was_silent and self.overlay then
            self.overlay:show_toast("目标地址无公网中继服响应！樱花 17777 直连请切回「樱花联机」页；自建公网服请先运行 启动公网中继服.bat (17780)。", 6.0)
        end
        autotest:on_server_connect_failed()
    end

    if self.transport and self.transport.lan_backend then
        local in_match = (self.coop and self.coop:is_active()) == true
        local waiting_rc = (self.lockstep ~= nil and self.lockstep.phase == "WAIT_RECONNECT")
        self.transport.lan_backend.accept_enabled = (not in_match) or waiting_rc
    end

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

    if self.online_reconnecting_room and self.view == "room" and self.transport and self.transport:is_online()
        and not (self.coop and self.coop:is_active()) then
        if not self.server_connected and not self.server_handshaking and not self.transport:is_connecting()
            and now >= (self.online_reconnect_next_ts or 0) then
            self.online_reconnect_attempt = (self.online_reconnect_attempt or 0) + 1
            if self.online_reconnect_attempt > 4 then
                self:exit_dead_online_room("公网房间自动重连失败，已返回公网大厅（请检查网络/服务器后重新建房）！")
            else
                self.online_reconnect_next_ts = now + 2.5
                self.boot:log("[LOBBY] Auto-reconnecting online lobby room #%s (attempt %d/4)...",
                    tostring(self.online_room_code), self.online_reconnect_attempt)
                self.pending_online_action = {
                    kind = "reconnect_lobby",
                    sess = {
                        server = self.server_input,
                        code = self.online_room_code,
                        pid = self.local_pid,
                        token = self.online_token,
                    },
                }
                self:connect_online_server(self.server_input, true)
            end
        end
    elseif self.online_reconnecting_room and self.view ~= "room" then
        self.online_reconnecting_room = false
        self._pending_lobby_reconnect = false
    end
end

local TRANSPORT_HANDLERS = {}

function TRANSPORT_HANDLERS.peer_connected(self, ev)
    self.peer_connected = true
    self.peer_name = "正在握手 (" .. tostring(ev.ip) .. ")..."
end

function TRANSPORT_HANDLERS.lan_connected(self, ev)
    self:on_lan_connected(ev.ip, ev.port)
end

function TRANSPORT_HANDLERS.lan_fallback(self)
    self.overlay:show_toast("免费 P2P 端口导出未通，已自动切回樱花中继线路继续连接...", 3.0)
end

function TRANSPORT_HANDLERS.lan_connect_failed(self, ev)
    self.pending_lan_join = nil
    if not ev.silent then
        self.overlay:show_toast("连接房主失败：" .. tostring(ev.reason), 5.0)
    end
    autotest:on_lan_connect_failed()
end

function TRANSPORT_HANDLERS.peer_disconnected(self, ev, now)
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
    elseif (ev.reason == "early_eof_refused" or self.view == "home") and self.role == "client" then
        local was_early = (ev.reason == "early_eof_refused")
        local was_rc = (self._pending_session_reconnect == true)
        self._pending_session_reconnect = false
        self.role = "none"
        self.view = "home"
        self.sub_modal = nil
        self.transport:close()
        if self.open and self.net_tab == "lan" then self.transport:start_lan_scan() end
        if was_early then
            self.overlay:show_toast("已连到樱花节点，但房主游戏未就绪！请确认：① 房主已点「创建房间」；② 樱花本地端口填的是 17777！", 6.5)
        elseif not was_rc then
            self.overlay:show_toast("与房主连接已断开，请确认房主仍在房间后重新直连。", 4.0)
        end
    else
        self.overlay:show_toast("队友已断开连接。", 3.5)
    end
end

function TRANSPORT_HANDLERS.server_connected(self)
    self:on_online_connected()
end

function TRANSPORT_HANDLERS.server_connect_failed(self, ev)
    self.server_connected = false
    self.server_handshaking = false
    self.server_connect_silent = false
    self.pending_online_action = nil
    if not ev.silent then
        self.overlay:show_toast("连接公网服务器失败：" .. tostring(ev.reason), 4.5)
    end
    autotest:on_server_connect_failed()
end

function TRANSPORT_HANDLERS.server_disconnected(self, _, now)
    local was_connected = self.server_connected
    local was_handshaking = self.server_handshaking
    local was_silent = self.server_connect_silent
    self.server_connected = false
    self.server_handshaking = false
    self.server_connect_silent = false
    self.pending_online_action = nil
    if self.lockstep and self.lockstep:is_active() then
        self.lockstep:on_peer_disconnected("与公网中继服断开连接", false)
    elseif self.view == "room" and not self.online_reconnecting_room then
        self.peer_connected = false
        self.peer_ready = false
        if self.online_room_code and self.online_token then
            self.online_reconnecting_room = true
            self.online_reconnect_attempt = 0
            self.online_reconnect_next_ts = now + 0.5
            self.boot:log("[LOBBY] Online server disconnected in room #%s -> starting auto-reconnect", tostring(self.online_room_code))
            self.overlay:show_toast("公网连接波动已断开，正在自动重连房间 #" .. tostring(self.online_room_code) .. "...", 4.0)
        else
            self:exit_dead_online_room("与公网服务器断开连接，已返回公网大厅。")
        end
    elseif was_handshaking and not was_connected then
        if not was_silent then
            self.overlay:show_toast("未检测到公网中继服 (kr-mp-server)！樱花 17777 直连请切回「樱花联机」页；自建公网服请先启动 启动公网中继服.bat (17780)。", 6.5)
        end
        autotest:on_server_connect_failed()
    elseif was_connected and not self.online_reconnecting_room then
        self.overlay:show_toast("与公网服务器断开连接。", 4)
    end
end

function TRANSPORT_HANDLERS.msg(self, ev)
    self:on_message(ev.msg)
end

function M.dispatch_transport_events(self, events, now)
    for i = 1, #events do
        local ev = events[i]
        local fn = TRANSPORT_HANDLERS[ev.type]
        if fn then fn(self, ev, now) end
    end
end

return M
