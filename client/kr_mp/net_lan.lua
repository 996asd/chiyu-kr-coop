-- KR-MP LAN Transport (LuaSocket 2.0.2 non-blocking DNS + non-blocking TCP + UDP broadcast room discovery)
local socket = require("socket")
local proto = require("kr_mp.proto")

local net_lan = {}
net_lan.__index = net_lan

local WATCHDOG_SEC = tonumber(os.getenv("KR_MP_WATCHDOG_SEC")) or 12.0

local DNS_WORKER_CODE = [[
local channel_name, seq, host = ...
local ch = love.thread.getChannel(channel_name)
local ok, sock = pcall(require, "socket")
if not ok or not sock or not sock.dns then
    ch:push({ seq = seq, host = host, ip = nil, err = "no_socket_dns" })
    return
end
local ip, err = sock.dns.toip(host)
ch:push({ seq = seq, host = host, ip = ip, err = err })
]]

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
    self.dns_channel = (love and love.thread and love.thread.getChannel)
        and love.thread.getChannel("kr_mp_lan_dns") or nil
    self.connect_silent = false
    self.recv_buf = ""
    self.send_queue = {}
    self.voice_queue = {}
    self.active_chunk = nil
    self.send_offset = 1
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
    if self.connecting_sock then
        pcall(self.connecting_sock.close, self.connecting_sock)
        self.connecting_sock = nil
    end
    if self.peer then
        pcall(self.peer.close, self.peer)
        self.peer = nil
    end
    if self.server then
        pcall(self.server.close, self.server)
        self.server = nil
    end
    if self.udp_bcast then
        pcall(self.udp_bcast.close, self.udp_bcast)
        self.udp_bcast = nil
    end
    if self.udp_scan then
        pcall(self.udp_scan.close, self.udp_scan)
        self.udp_scan = nil
    end
    self.role = "none"
    self.state = "idle"
    self.connect_saw_peer = false
    self.connect_target_host = nil
    self.connect_target_port = nil
    self.connect_target_ip = nil
    self.recv_buf = ""
    self.send_queue = {}
    self.voice_queue = {}
    self.active_chunk = nil
    self.send_offset = 1
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

    -- UDP broadcaster for LAN discovery
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
        and "连接超时（请确认房主已开房且樱花映射 TCP 隧道已开启）"
        or ((cerr == "connection refused" or cerr == "refused")
            and "连接被拒绝（请确认房主已点创建房间且映射本地端口为 17777）"
            or tostring(cerr))
    return string.format("连接 %s:%d 失败：%s", target_ip, target_port, hint)
end

function net_lan:begin_tcp_connect(connect_ip, target_ip, target_port)
    local c, err = socket.tcp()
    if not c then
        self.last_error = "TCP 初始化失败: " .. tostring(err)
        self.state = "idle"
        self.role = "none"
        return false, self.last_error
    end

    c:settimeout(0)
    local ok, cerr = c:connect(connect_ip, target_port)
    if ok == 1 then
        pcall(c.setoption, c, "tcp-nodelay", true)
        pcall(c.setoption, c, "keepalive", true)
        self.peer = c
        self.connecting_sock = nil
        self.peer_ip = target_ip
        self.port = target_port
        self.role = "client"
        self.state = "connected"
        self.recv_buf = ""
        self.send_queue = {}
        self.voice_queue = {}
        self.active_chunk = nil
        self.send_offset = 1
        local now = socket.gettime()
        self.last_ping_ts = now
        self.last_recv_ts = now
        self.last_error = nil
        self:log("Connected to LAN/FRP host %s:%d (ip=%s)", target_ip, target_port, connect_ip)
        return true, "connected"
    end

    if cerr == "timeout" or cerr == "Operation already in progress" or cerr == "already in progress" then
        local now = socket.gettime()
        self.connecting_sock = c
        self.connect_target_host = target_ip
        self.connect_target_port = target_port
        self.connect_target_ip = connect_ip
        self.connect_started_ts = now
        self.connect_deadline = now + 5.0
        self.connect_saw_peer = (c:getpeername() ~= nil)
        self.role = "client"
        self.state = "connecting"
        self.last_error = nil
        return true, "connecting"
    end

    pcall(c.close, c)
    self.last_error = self:format_connect_error(target_ip, target_port, cerr)
    self.state = "idle"
    self.role = "none"
    self:log("Connect %s:%d (%s) failed: %s", target_ip, target_port, connect_ip, tostring(cerr))
    return false, self.last_error
end

-- Non-blocking connect: returns (true, "connected"|"connecting"|"resolving") or (false, err_msg)
function net_lan:connect(ip, port, silent_fail)
    local had_scan = (self.udp_scan ~= nil)
    self:close()
    if had_scan then
        self:start_scan()
    end

    local clean = proto.sanitize_addr(ip or "")
    local target_ip = (clean ~= "") and clean or "127.0.0.1"
    local target_port = tonumber(port) or proto.DEFAULT_TCP_PORT
    local p_host, p_port = target_ip:match("^([^:]+):(%d+)$")
    if p_host and p_port then
        target_ip = p_host
        target_port = tonumber(p_port)
    end

    self.connect_silent = (silent_fail == true)
    self.connect_target_host = target_ip
    self.connect_target_port = target_port

    if target_ip:match("^%d+%.%d+%.%d+%.%d+$") then
        return self:begin_tcp_connect(target_ip, target_ip, target_port)
    end

    -- Non-blocking DNS lookup for SakuraFrp / OpenFrp domains
    if love and love.thread and love.thread.newThread and self.dns_channel then
        self.connect_seq = self.connect_seq + 1
        local seq = self.connect_seq
        local ok_th, th = pcall(love.thread.newThread, DNS_WORKER_CODE)
        if ok_th and th then
            self.role = "client"
            self.state = "resolving"
            self.connect_started_ts = socket.gettime()
            self.connect_deadline = self.connect_started_ts + 5.0
            self.last_error = nil
            th:start("kr_mp_lan_dns", seq, target_ip)
            return true, "resolving"
        end
    end

    local resolved, derr = socket.dns.toip(target_ip)
    if not resolved then
        self.last_error = string.format("域名解析失败 (%s)：请检查樱花映射地址是否复制完整", target_ip)
        self:log("DNS resolve failed for %s: %s", target_ip, tostring(derr))
        return false, self.last_error
    end
    self:log("Resolved FRP/host %s -> %s", target_ip, resolved)
    return self:begin_tcp_connect(resolved, target_ip, target_port)
end

function net_lan:is_lockstep_waiting()
    return self.boot ~= nil and self.boot.lockstep ~= nil and self.boot.lockstep.waiting_for_peer == true
end

function net_lan:send(msg)
    if not self.peer or self.state ~= "connected" then
        return false
    end
    if msg and msg.t == "VOICE" then
        -- Anti-HoL QoS for SakuraFrp: always yield to lockstep TURN/control traffic
        if #self.send_queue > 2 or #self.voice_queue >= 2 or self:is_lockstep_waiting() then
            self.voice_dropped = (self.voice_dropped or 0) + 1
            return false
        end
        self.voice_queue[#self.voice_queue + 1] = proto.encode(msg)
        self:flush_send()
        return true
    end
    local raw = proto.encode(msg)
    self.send_queue[#self.send_queue + 1] = raw
    self:flush_send()
    return true
end

function net_lan:flush_send()
    if not self.peer then return end
    while self.active_chunk or #self.send_queue > 0 or #self.voice_queue > 0 do
        if not self.active_chunk then
            if #self.send_queue > 0 then
                self.active_chunk = table.remove(self.send_queue, 1)
                self.send_offset = 1
            elseif #self.voice_queue > 0 then
                if self:is_lockstep_waiting() then
                    self.voice_dropped = (self.voice_dropped or 0) + #self.voice_queue
                    self.voice_queue = {}
                    break
                end
                self.active_chunk = table.remove(self.voice_queue, 1)
                self.send_offset = 1
            end
        end
        local sent, err, partial = self.peer:send(self.active_chunk, self.send_offset)
        if sent then
            self.active_chunk = nil
            self.send_offset = 1
        elseif err == "timeout" then
            if partial and partial >= self.send_offset then
                self.send_offset = partial + 1
            end
            break
        else
            self:log("TCP send error: %s", tostring(err))
            self:handle_peer_disconnect(err)
            break
        end
    end
end

function net_lan:handle_peer_disconnect(reason)
    local was_connected = (self.peer ~= nil or self.state == "connected")
    if self.peer then
        pcall(self.peer.close, self.peer)
        self.peer = nil
    end
    self.recv_buf = ""
    self.send_queue = {}
    self.voice_queue = {}
    self.active_chunk = nil
    self.send_offset = 1
    self.last_recv_ts = 0
    self.peer_ip = nil
    if self.role == "host" and self.server then
        self.state = "listening"
    else
        self.state = "closed"
    end
    self.last_error = "Disconnected: " .. tostring(reason)
    if was_connected then
        self.pending_disconnect_reason = tostring(reason or "closed")
    end
end

function net_lan:drop_peer_socket(reason, silent_event)
    if not self.peer then return false end
    self:log("Force-closing peer TCP socket (%s)", tostring(reason or "drop"))
    self:handle_peer_disconnect(reason or "simulated_drop")
    if silent_event then
        self.pending_disconnect_reason = nil
    end
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
    self.state = "idle"
    self.role = "none"
    self.connect_saw_peer = false
    self.last_error = display_err or self:format_connect_error(host, port, raw_err)
    self:log("Connect %s:%d (%s) failed: %s", tostring(host), tonumber(port) or 0, tostring(ip), tostring(raw_err))
    events[#events + 1] = {
        type = "lan_connect_failed",
        reason = self.last_error,
        silent = silent,
    }
end

function net_lan:poll()
    local events = {}
    local now = socket.gettime()
    -- Protect 12s watchdog against local main-thread stalls (e.g., FL level load/unload texture GC)
    if self.last_poll_ts > 0 then
        local gap = now - self.last_poll_ts
        if gap > 1.5 and self.last_recv_ts > 0 then
            self.last_recv_ts = self.last_recv_ts + gap
        end
    end
    self.last_poll_ts = now

    -- Flush any async disconnect triggered earlier during send() outside poll()
    if self.pending_disconnect_reason then
        local r = self.pending_disconnect_reason
        self.pending_disconnect_reason = nil
        events[#events + 1] = { type = "peer_disconnected", reason = r }
        return events
    end

    -- 0a. Async DNS completion for client join
    if self.state == "resolving" then
        if self.dns_channel then
            while true do
                local res = self.dns_channel:pop()
                if not res then break end
                if res.seq == self.connect_seq then
                    if not res.ip then
                        local msg = string.format("域名解析失败 (%s)：请检查樱花映射地址是否复制完整", tostring(self.connect_target_host))
                        self:fail_pending_connect(events, res.err or "dns_failed", msg)
                        break
                    end
                    self:log("Resolved FRP/host %s -> %s", tostring(self.connect_target_host), tostring(res.ip))
                    local ok, st = self:begin_tcp_connect(res.ip, self.connect_target_host, self.connect_target_port)
                    if not ok then
                        events[#events + 1] = {
                            type = "lan_connect_failed",
                            reason = self.last_error or tostring(st),
                        }
                    elseif st == "connected" then
                        events[#events + 1] = {
                            type = "lan_connected",
                            ip = self.peer_ip,
                            port = self.port,
                        }
                    end
                    break
                end
            end
        end
        if self.state == "resolving" and now >= self.connect_deadline then
            local msg = string.format("域名解析超时 (%s)：请检查网络或樱花映射地址", tostring(self.connect_target_host))
            self:fail_pending_connect(events, "dns_timeout", msg)
        end
    end

    -- 0b. Non-blocking TCP handshake poll for client join
    if self.state == "connecting" and self.connecting_sock then
        local c = self.connecting_sock
        local _, writable = socket.select(nil, { c }, 0)
        local peer = c:getpeername()
        if peer then
            self.connect_saw_peer = true
        end

        if writable and #writable > 0 then
            if peer then
                pcall(c.setoption, c, "tcp-nodelay", true)
                pcall(c.setoption, c, "keepalive", true)
                c:settimeout(0)
                self.peer = c
                self.connecting_sock = nil
                self.peer_ip = self.connect_target_host
                self.port = self.connect_target_port
                self.role = "client"
                self.state = "connected"
                self.recv_buf = ""
                self.send_queue = {}
                self.voice_queue = {}
                self.active_chunk = nil
                self.send_offset = 1
                self.last_ping_ts = now
                self.last_recv_ts = now
                self.last_error = nil
                self:log("Connected to LAN/FRP host %s:%d (ip=%s)",
                    tostring(self.peer_ip), tonumber(self.port) or 0, tostring(self.connect_target_ip))
                events[#events + 1] = {
                    type = "lan_connected",
                    ip = self.peer_ip,
                    port = self.port,
                }
            else
                self:fail_pending_connect(events, "connection refused")
            end
        elseif not peer and (self.connect_saw_peer or (now - self.connect_started_ts) >= 0.08) then
            self:fail_pending_connect(events, "connection refused")
        elseif now >= self.connect_deadline then
            self:fail_pending_connect(events, "timeout")
        end
    end

    -- 1. Host UDP LAN room broadcast every 1.2s (while waiting for guest)
    if self.role == "host" and self.udp_bcast and self.room_advert and self.state == "listening" then
        if now - self.last_bcast_ts >= 1.2 then
            self.last_bcast_ts = now
            local adv = self.room_advert
            local pkt = string.format("KRMP1|%d|%s|%d|%d|%s",
                self.port,
                tostring(adv.name or "LAN Room"):gsub("|", "_"),
                tonumber(adv.level_idx) or 101,
                tonumber(adv.players) or 1,
                tostring(KR_FL_VERSION or "8.2.0"))
            pcall(self.udp_bcast.sendto, self.udp_bcast, pkt, "255.255.255.255", proto.LAN_DISCOVERY_PORT)
            pcall(self.udp_bcast.sendto, self.udp_bcast, pkt, "127.0.0.1", proto.LAN_DISCOVERY_PORT)
        end
    end

    -- 2. UDP LAN discovery scanner (for client browsing rooms)
    if self.udp_scan then
        for _ = 1, 12 do
            local data, ip = self.udp_scan:receivefrom()
            if not data then break end
            local port_s, rname, lvl_s, pl_s, flv = data:match("^KRMP1|(%d+)|([^|]+)|(%d+)|(%d+)|(.+)$")
            if port_s and ip then
                local port_n = tonumber(port_s)
                local key = ip .. ":" .. port_s
                self.discovered[key] = {
                    key = key,
                    ip = ip,
                    port = port_n,
                    name = rname,
                    level_idx = tonumber(lvl_s) or 101,
                    players = tonumber(pl_s) or 1,
                    fl_ver = flv,
                    seen_ts = now,
                }
            end
        end
    end

    -- 3. Host TCP accept (only 1 guest in 2P Co-op; enabled in lobby and during WAIT_RECONNECT)
    if self.role == "host" and self.server and not self.peer then
        local client = self.server:accept()
        if client then
            if self.accept_enabled == false then
                pcall(client.close, client)
            else
                pcall(client.setoption, client, "tcp-nodelay", true)
                pcall(client.setoption, client, "keepalive", true)
                client:settimeout(0)
                local cip = select(1, client:getpeername()) or "?"
                self.peer = client
                self.peer_ip = cip
                self.state = "connected"
                self.recv_buf = ""
                self.send_queue = {}
                self.voice_queue = {}
                self.active_chunk = nil
                self.send_offset = 1
                self.last_ping_ts = now
                self.last_recv_ts = now
                self:log("Guest connected from %s", tostring(cip))
                events[#events + 1] = { type = "peer_connected", ip = cip }
            end
        end
    end

    -- 4. Flush outgoing TCP queue (emit peer_disconnected if send failed!)
    if self.peer and self.state == "connected" then
        self:flush_send()
        if not self.peer or self.state ~= "connected" then
            local r = self.pending_disconnect_reason or self.last_error or "send_failed"
            self.pending_disconnect_reason = nil
            events[#events + 1] = { type = "peer_disconnected", reason = r }
            return events
        end
    end

    -- 5. Non-blocking TCP receive (O(N) chunked concat + cursor framing + 12s dead-link watchdog)
    if self.peer and self.state == "connected" then
        local chunks = nil
        local closed_during_read = false
        for _ = 1, 64 do
            if not self.peer then break end
            local data, err, partial = self.peer:receive(16384)
            local chunk = data or partial
            if chunk and #chunk > 0 then
                self.last_recv_ts = now
                if not chunks then
                    chunks = (#self.recv_buf > 0) and { self.recv_buf, chunk } or { chunk }
                else
                    chunks[#chunks + 1] = chunk
                end
            end
            if err == "closed" then
                self:log("Peer disconnected (closed)")
                self:handle_peer_disconnect("closed")
                closed_during_read = true
                break
            elseif err == "timeout" or not data then
                break
            end
        end
        if chunks then
            self.recv_buf = (#chunks == 1) and chunks[1] or table.concat(chunks)
        end

        if #self.recv_buf > 0 then
            local pos = 1
            while true do
                local nl = self.recv_buf:find("\n", pos, true)
                if not nl then break end
                local line = self.recv_buf:sub(pos, nl - 1)
                pos = nl + 1
                if #line > 0 then
                    local msg, derr = proto.decode(line)
                    if msg then
                        if msg.t == "PING" then
                            self:send({ t = "PONG", ts = msg.ts })
                        elseif msg.t == "PONG" and type(msg.ts) == "number" then
                            self.rtt_ms = math.floor((socket.gettime() - msg.ts) * 1000 + 0.5)
                        else
                            events[#events + 1] = { type = "msg", msg = msg }
                        end
                    else
                        self:log("Malformed msg: %s", tostring(derr))
                    end
                end
            end
            if pos > 1 then
                self.recv_buf = self.recv_buf:sub(pos)
            end
        end

        if closed_during_read then
            self.pending_disconnect_reason = nil
            events[#events + 1] = { type = "peer_disconnected", reason = "closed" }
            return events
        end

        -- 12s dead-link watchdog (detects silent NAT/SakuraFrp blackholes)
        if self.peer and self.state == "connected" and self.last_recv_ts > 0 and (now - self.last_recv_ts) >= WATCHDOG_SEC then
            self:log("Dead-link watchdog timeout (%.1fs without inbound bytes); closing socket", now - self.last_recv_ts)
            self:handle_peer_disconnect("watchdog_timeout")
            self.pending_disconnect_reason = nil
            events[#events + 1] = { type = "peer_disconnected", reason = "watchdog_timeout" }
            return events
        end

        -- Periodic RTT ping every 1.5s
        if self.peer and now - self.last_ping_ts >= 1.5 then
            self.last_ping_ts = now
            self:send({ t = "PING", ts = now })
        end
    end

    return events
end

return net_lan
