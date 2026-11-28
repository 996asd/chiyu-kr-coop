-- KR-MP LAN Transport (LuaSocket 2.0.2 non-blocking DNS + non-blocking TCP + UDP broadcast room discovery)
local socket = require("socket")
local proto = require("kr_mp.proto")
local tcp_stream = require("kr_mp.tcp_stream")

local net_lan = {}
net_lan.__index = net_lan

function net_lan.new(boot)
    local self = setmetatable({}, net_lan)
    self.boot = boot
    self.role = "none" -- "none" | "host" | "client"
    self.state = "idle" -- "idle" | "listening" | "resolving" | "connecting" | "connected" | "closed"
    self.server = nil
    self.peer = nil
    self.connecting_sock = nil
    self.connect_seq = 0
    self.connect_started_ts = 0
    self.connect_deadline = 0
    self.connect_saw_peer = false
    self.connect_target_host = nil
    self.connect_target_port = nil
    self.connect_target_ip = nil
    self.connect_fallback_addr = nil
    self.connected_at_ts = 0
    self.ever_received_app_msg = false
    self.dns_channel = (love and love.thread and love.thread.getChannel)
        and love.thread.getChannel("kr_mp_lan_dns") or nil
    self.connect_silent = false
    tcp_stream.reset_io_buffers(self)
    self.voice_dropped = 0
    self.udp_bcast = nil
    self.udp_scan = nil
    self.last_bcast_ts = 0
    self.room_advert = nil
    self.discovered = {} -- [key] = { ip, port, name, level_idx, players, fl_ver, seen_ts }
    self.requested_port = proto.DEFAULT_TCP_PORT
    self.port = proto.DEFAULT_TCP_PORT
    self.port_drifted = false
    self.peer_ip = nil
    self.last_error = nil
    self.last_ping_ts = 0
    self.last_recv_ts = 0
    self.last_poll_ts = 0
    self.pending_disconnect_reason = nil
    self.rtt_ms = 0
    self.accept_enabled = true
    return self
end

function net_lan:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[LAN] " .. fmt, ...)
    end
end

function net_lan:is_connecting()
    return self.state == "resolving" or self.state == "connecting"
end

function net_lan:close()
    self.connect_seq = self.connect_seq + 1
    for _, k in ipairs({ "connecting_sock", "peer", "server", "udp_bcast", "udp_scan" }) do
        if self[k] then
            pcall(self[k].close, self[k])
            self[k] = nil
        end
    end
    self.role = "none"
    self.state = "idle"
    self.connect_saw_peer = false
    self.connect_target_host = nil
    self.connect_target_port = nil
    self.connect_target_ip = nil
    self.connect_fallback_addr = nil
    self.connected_at_ts = 0
    self.ever_received_app_msg = false
    tcp_stream.reset_io_buffers(self)
    self.last_recv_ts = 0
    self.pending_disconnect_reason = nil
    self.port_drifted = false
    self.peer_ip = nil
    self.room_advert = nil
end

function net_lan:start_host(port, room_advert)
    self:close()
    local try_port = tonumber(port) or proto.DEFAULT_TCP_PORT
    self.requested_port = try_port
    local srv, err
    for p = try_port, try_port + 10 do
        local s = assert(socket.tcp())
        -- Avoid Windows SO_REUSEADDR TCP hijack so busy ports cleanly advance to p+1
        if love and love.system and love.system.getOS and love.system.getOS() ~= "Windows" then
            pcall(s.setoption, s, "reuseaddr", true)
        end
        local ok, berr = s:bind("0.0.0.0", p)
        if ok then
            local lok, lerr = s:listen(4)
            if lok then
                s:settimeout(0)
                srv = s
                self.port = p
                self.port_drifted = (p ~= try_port)
                break
            else
                err = lerr
                s:close()
            end
        else
            err = berr
            s:close()
        end
    end

    if not srv then
        self.last_error = "Bind failed: " .. tostring(err)
        self:log("Host bind failed: %s", tostring(err))
        return false, self.last_error
    end

    self.server = srv
    self.role = "host"
    self.state = "listening"
    self.room_advert = room_advert or { name = "KR-MP LAN Room", level_idx = 101, players = 1 }

    local u = socket.udp()
    if u then
        pcall(u.setoption, u, "broadcast", true)
        u:settimeout(0)
        self.udp_bcast = u
    end

    self:log("Hosting LAN room on TCP 0.0.0.0:%d (requested=%d drifted=%s, UDP bcast -> %d)",
        self.port, self.requested_port, tostring(self.port_drifted), proto.LAN_DISCOVERY_PORT)
    return true, self.port
end

function net_lan:update_advert(advert)
    self.room_advert = advert
end

function net_lan:start_scan()
    if self.udp_scan then return true end
    local u = socket.udp()
    if not u then return false end
    pcall(u.setoption, u, "reuseaddr", true)
    local ok, err = u:setsockname("0.0.0.0", proto.LAN_DISCOVERY_PORT)
    if not ok then
        self:log("UDP scan bind %d failed: %s (direct IP join still works)", proto.LAN_DISCOVERY_PORT, tostring(err))
        u:close()
        return false
    end
    u:settimeout(0)
    self.udp_scan = u
    self:log("LAN UDP room scanner listening on port %d", proto.LAN_DISCOVERY_PORT)
    return true
end

function net_lan:stop_scan()
    if self.udp_scan then
        pcall(self.udp_scan.close, self.udp_scan)
        self.udp_scan = nil
    end
end

function net_lan:get_discovered_rooms()
    local now = socket.gettime()
    local list = {}
    for k, r in pairs(self.discovered) do
        if now - r.seen_ts <= 5.0 then
            list[#list + 1] = r
        else
            self.discovered[k] = nil
        end
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    return list
end

function net_lan:format_connect_error(target_ip, target_port, cerr)
    local hint = (cerr == "timeout")
        and "连接超时（请确认房主樱花隧道已开启、未拥堵，或点「三线测速」切更快线路）"
        or ((cerr == "connection refused" or cerr == "refused")
            and "连接被拒绝（请确认房主已点创建房间且映射本地端口为 17777）"
            or tostring(cerr))
    return string.format("连接 %s:%d 失败：%s", target_ip, target_port, hint)
end

function net_lan:format_dns_error(host)
    local h = tostring(host or "")
    local lower = h:lower()
    if lower:match("^dx%.") or lower:match("^yd%.") or lower:match("^lt%.") then
        return string.format("域名解析失败 (%s)：该节点可能不支持 dx./yd. 专线前缀，请切回「默认线」或点「三线测速」", h)
    end
    return string.format("域名解析失败 (%s)：请检查樱花映射地址是否复制完整", h)
end

function net_lan:_mark_client_connected(sock, host, port, resolved_ip, now)
    self.peer = sock
    self.peer_ip = host
    self.port = port
    self.role = "client"
    self.state = "connected"
    self.connected_at_ts = now or socket.gettime()
    self.ever_received_app_msg = false
    self:log("Connected to LAN/FRP host %s:%d (ip=%s)", tostring(host), tonumber(port) or 0, tostring(resolved_ip))
end

function net_lan:begin_tcp_connect(connect_ip, target_ip, target_port)
    local timeout_sec = self.connect_fallback_addr and 2.6 or 5.0
    local status, res = tcp_stream.begin_nonblocking_connect(self, connect_ip, target_ip, target_port, timeout_sec)
    if status == "connected" then
        self:_mark_client_connected(res, target_ip, target_port, connect_ip)
        return true, "connected"
    elseif status == "connecting" then
        self.role = "client"
        return true, "connecting"
    end
    self.last_error = (type(res) == "string" and res:match("^TCP ")) and res or self:format_connect_error(target_ip, target_port, res)
    self.state = "idle"
    self.role = "none"
    self:log("Connect %s:%d (%s) failed: %s", target_ip, target_port, connect_ip, tostring(res))
    return false, self.last_error
end

function net_lan:start_connect_target(target_ip, target_port)
    self.connect_target_host = target_ip
    self.connect_target_port = target_port

    if target_ip:match("^%d+%.%d+%.%d+%.%d+$") then
        return self:begin_tcp_connect(target_ip, target_ip, target_port)
    end

    local dns_timeout = self.connect_fallback_addr and 2.8 or 5.0
    if tcp_stream.start_async_dns(self, "kr_mp_lan_dns", target_ip, dns_timeout) then
        self.role = "client"
        return true, "resolving"
    end

    local resolved, derr = socket.dns.toip(target_ip)
    if not resolved then
        self.last_error = self:format_dns_error(target_ip)
        self:log("DNS resolve failed for %s: %s", target_ip, tostring(derr))
        return false, self.last_error
    end
    self:log("Resolved FRP/host %s -> %s", target_ip, resolved)
    return self:begin_tcp_connect(resolved, target_ip, target_port)
end

-- Non-blocking connect: supports single "host:port" OR P2P-first dual "p2p_ip:port|relay_host:port"
function net_lan:connect(ip, port, silent_fail)
    local had_scan = (self.udp_scan ~= nil)
    self:close()
    if had_scan then self:start_scan() end

    local primary, fallback = proto.split_fallback_addr(ip or "")
    local target_ip = (primary ~= "") and primary or "127.0.0.1"
    local target_port = tonumber(port) or proto.DEFAULT_TCP_PORT
    local p_host, p_port = target_ip:match("^([^:]+):(%d+)$")
    if p_host and p_port then
        target_ip = p_host
        target_port = tonumber(p_port)
    end

    self.connect_silent = (silent_fail == true)
    self.connect_fallback_addr = fallback
    local ok, st = self:start_connect_target(target_ip, target_port)
    if not ok and self.connect_fallback_addr then
        local fb = self.connect_fallback_addr
        self.connect_fallback_addr = nil
        local fb_h, fb_p = fb:match("^([^:]+):(%d+)$")
        return self:start_connect_target(fb_h or fb, tonumber(fb_p) or proto.DEFAULT_TCP_PORT)
    end
    return ok, st
end

function net_lan:is_lockstep_waiting()
    return tcp_stream.is_lockstep_waiting(self)
end

function net_lan:send(msg)
    return tcp_stream.send(self, self.peer, msg, function(err)
        self:log("TCP send error: %s", tostring(err))
        self:handle_peer_disconnect(err)
    end)
end

function net_lan:flush_send()
    tcp_stream.flush_send(self, self.peer, function(err)
        self:log("TCP send error: %s", tostring(err))
        self:handle_peer_disconnect(err)
    end)
end

function net_lan:handle_peer_disconnect(reason)
    local was_connected = (self.peer ~= nil or self.state == "connected")
    if self.peer then
        pcall(self.peer.close, self.peer)
        self.peer = nil
    end
    tcp_stream.reset_io_buffers(self)
    self.last_recv_ts = 0
    self.peer_ip = nil
    self.state = (self.role == "host" and self.server) and "listening" or "closed"
    self.last_error = "Disconnected: " .. tostring(reason)
    if was_connected then
        self.pending_disconnect_reason = tostring(reason or "closed")
    end
end

function net_lan:drop_peer_socket(reason, silent_event)
    if not self.peer then return false end
    self:log("Force-closing peer TCP socket (%s)", tostring(reason or "drop"))
    self:handle_peer_disconnect(reason or "simulated_drop")
    if silent_event then self.pending_disconnect_reason = nil end
    return true
end

function net_lan:fail_pending_connect(events, raw_err, display_err)
    local host = self.connect_target_host or "127.0.0.1"
    local port = self.connect_target_port or proto.DEFAULT_TCP_PORT
    local ip = self.connect_target_ip or host
    local silent = self.connect_silent
    if self.connecting_sock then
        pcall(self.connecting_sock.close, self.connecting_sock)
        self.connecting_sock = nil
    end
    if self.connect_fallback_addr then
        local fb = self.connect_fallback_addr
        self.connect_fallback_addr = nil
        self.connect_saw_peer = false
        self:log("Primary P2P %s:%d failed (%s); auto-falling back to SakuraFrp relay %s",
            tostring(host), tonumber(port) or 0, tostring(raw_err), tostring(fb))
        local fb_h, fb_p = fb:match("^([^:]+):(%d+)$")
        local ok, st = self:start_connect_target(fb_h or fb, tonumber(fb_p) or proto.DEFAULT_TCP_PORT)
        if ok then
            if not silent then events[#events + 1] = { type = "lan_fallback", target = fb } end
            if st == "connected" then
                events[#events + 1] = { type = "lan_connected", ip = self.peer_ip, port = self.port }
            end
            return
        end
    end
    self.state = "idle"
    self.role = "none"
    self.connect_saw_peer = false
    self.last_error = display_err or self:format_connect_error(host, port, raw_err)
    self:log("Connect %s:%d (%s) failed: %s", tostring(host), tonumber(port) or 0, tostring(ip), tostring(raw_err))
    events[#events + 1] = { type = "lan_connect_failed", reason = self.last_error, silent = silent }
end

function net_lan:_poll_udp_discovery(now)
    if self.role == "host" and self.udp_bcast and self.room_advert and self.state == "listening" then
        if now - self.last_bcast_ts >= 1.2 then
            self.last_bcast_ts = now
            local adv = self.room_advert
            local pkt = string.format("KRMP1|%d|%s|%d|%d|%s",
                self.port, tostring(adv.name or "LAN Room"):gsub("|", "_"),
                tonumber(adv.level_idx) or 101, tonumber(adv.players) or 1,
                tostring(KR_FL_VERSION or "8.2.0"))
            pcall(self.udp_bcast.sendto, self.udp_bcast, pkt, "255.255.255.255", proto.LAN_DISCOVERY_PORT)
            pcall(self.udp_bcast.sendto, self.udp_bcast, pkt, "127.0.0.1", proto.LAN_DISCOVERY_PORT)
        end
    end
    if self.udp_scan then
        for _ = 1, 12 do
            local data, ip = self.udp_scan:receivefrom()
            if not data then break end
            local port_s, rname, lvl_s, pl_s, flv = data:match("^KRMP1|(%d+)|([^|]+)|(%d+)|(%d+)|(.+)$")
            if port_s and ip then
                local key = ip .. ":" .. port_s
                self.discovered[key] = {
                    key = key, ip = ip, port = tonumber(port_s), name = rname,
                    level_idx = tonumber(lvl_s) or 101, players = tonumber(pl_s) or 1,
                    fl_ver = flv, seen_ts = now,
                }
            end
        end
    end
end

function net_lan:_poll_host_accept(now, events)
    if self.role ~= "host" or not self.server or self.peer then return end
    local client = self.server:accept()
    if not client then return end
    if self.accept_enabled == false then
        pcall(client.close, client)
        return
    end
    tcp_stream.configure_socket(client)
    local cip = select(1, client:getpeername()) or "?"
    self.peer = client
    self.peer_ip = cip
    self.state = "connected"
    tcp_stream.reset_io_buffers(self)
    self.connected_at_ts = now
    self.ever_received_app_msg = false
    self.last_ping_ts = now
    self.last_recv_ts = now
    self:log("Guest connected from %s", tostring(cip))
    events[#events + 1] = { type = "peer_connected", ip = cip }
end

function net_lan:poll()
    local events = {}
    local now = socket.gettime()
    tcp_stream.protect_watchdog_stall(self, now)

    if self.pending_disconnect_reason then
        local r = self.pending_disconnect_reason
        self.pending_disconnect_reason = nil
        events[#events + 1] = { type = "peer_disconnected", reason = r }
        return events
    end

    if self.state == "resolving" then
        local dns_st, val = tcp_stream.poll_dns(self, now)
        if dns_st == "resolved" then
            self:log("Resolved FRP/host %s -> %s", tostring(self.connect_target_host), tostring(val))
            local ok, st = self:begin_tcp_connect(val, self.connect_target_host, self.connect_target_port)
            if not ok then
                events[#events + 1] = { type = "lan_connect_failed", reason = self.last_error or tostring(st) }
            elseif st == "connected" then
                events[#events + 1] = { type = "lan_connected", ip = self.peer_ip, port = self.port }
            end
        elseif dns_st == "failed" then
            self:fail_pending_connect(events, val, self:format_dns_error(self.connect_target_host))
        elseif dns_st == "timeout" then
            local msg = string.format("域名解析超时 (%s)：请检查网络或樱花映射地址", tostring(self.connect_target_host))
            self:fail_pending_connect(events, "dns_timeout", msg)
        end
    end

    if self.state == "connecting" and self.connecting_sock then
        local c_st, val = tcp_stream.poll_connect(self, now)
        if c_st == "connected" then
            self:_mark_client_connected(val, self.connect_target_host, self.connect_target_port, self.connect_target_ip, now)
            events[#events + 1] = { type = "lan_connected", ip = self.peer_ip, port = self.port }
        elseif c_st == "refused" or c_st == "timeout" then
            self:fail_pending_connect(events, val)
        end
    end

    self:_poll_udp_discovery(now)
    self:_poll_host_accept(now, events)

    if self.peer and self.state == "connected" then
        self:flush_send()
        if not self.peer or self.state ~= "connected" then
            local r = self.pending_disconnect_reason or self.last_error or "send_failed"
            self.pending_disconnect_reason = nil
            events[#events + 1] = { type = "peer_disconnected", reason = r }
            return events
        end
        local disc = tcp_stream.pump_connected(self, function() return self.peer end, now, events, {
            classify_eof = function(t_now)
                local early = (self.role == "client" and not self.ever_received_app_msg
                    and self.connected_at_ts > 0 and (t_now - self.connected_at_ts) < 1.8)
                return early and "early_eof_refused" or "closed"
            end,
            on_closed = function(reason)
                self:log("Peer disconnected (%s)", reason)
                self:handle_peer_disconnect(reason)
            end,
            on_msg_decoded = function() self.ever_received_app_msg = true end,
            on_malformed = function(derr) self:log("Malformed msg: %s", tostring(derr)) end,
            on_watchdog = function(elapsed)
                self:log("Dead-link watchdog timeout (%.1fs without inbound bytes); closing socket", elapsed)
                self:handle_peer_disconnect("watchdog_timeout")
            end,
        })
        if disc then
            events[#events + 1] = { type = "peer_disconnected", reason = disc }
        end
    end

    return events
end

return net_lan
