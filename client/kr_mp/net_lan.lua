-- KR-MP LAN Transport (LuaSocket 2.0.2 non-blocking TCP + UDP broadcast room discovery)
local socket = require("socket")
local proto = require("kr_mp.proto")

local net_lan = {}
net_lan.__index = net_lan

function net_lan.new(boot)
    local self = setmetatable({}, net_lan)
    self.boot = boot
    self.role = "none" -- "none" | "host" | "client"
    self.state = "idle" -- "idle" | "listening" | "connecting" | "connected" | "closed"
    self.server = nil
    self.peer = nil
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self.udp_bcast = nil
    self.udp_scan = nil
    self.last_bcast_ts = 0
    self.room_advert = nil
    self.discovered = {} -- [key] = { ip, port, name, level_idx, players, fl_ver, seen_ts }
    self.port = proto.DEFAULT_TCP_PORT
    self.peer_ip = nil
    self.last_error = nil
    self.last_ping_ts = 0
    self.rtt_ms = 0
    return self
end

function net_lan:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[LAN] " .. fmt, ...)
    end
end

function net_lan:close()
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
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self.peer_ip = nil
    self.room_advert = nil
end

function net_lan:start_host(port, room_advert)
    self:close()
    local try_port = tonumber(port) or proto.DEFAULT_TCP_PORT
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

    self:log("Hosting LAN room on TCP 0.0.0.0:%d (UDP bcast -> %d)", self.port, proto.LAN_DISCOVERY_PORT)
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

function net_lan:connect(ip, port)
    self:close()
    local clean = proto.sanitize_addr(ip or "")
    local target_ip = (clean ~= "") and clean or "127.0.0.1"
    local target_port = tonumber(port) or proto.DEFAULT_TCP_PORT
    local p_host, p_port = target_ip:match("^([^:]+):(%d+)$")
    if p_host and p_port then
        target_ip = p_host
        target_port = tonumber(p_port)
    end

    -- Explicit IPv4 DNS resolution for SakuraFrp / OpenFrp domain names
    local connect_ip = target_ip
    if not target_ip:match("^%d+%.%d+%.%d+%.%d+$") then
        local resolved, derr = socket.dns.toip(target_ip)
        if not resolved then
            self.last_error = string.format("域名解析失败 (%s)：请检查樱花映射地址是否复制完整", target_ip)
            self:log("DNS resolve failed for %s: %s", target_ip, tostring(derr))
            return false, self.last_error
        end
        self:log("Resolved FRP/host %s -> %s", target_ip, resolved)
        connect_ip = resolved
    end

    local c, err = socket.tcp()
    if not c then
        self.last_error = "TCP 初始化失败: " .. tostring(err)
        return false, self.last_error
    end

    -- 5.0s connect timeout accommodates cross-ISP SakuraFrp / OpenFrp TCP tunnels
    c:settimeout(5.0)
    local ok, cerr = c:connect(connect_ip, target_port)
    if not ok then
        c:close()
        local hint = (cerr == "timeout")
            and "连接超时（请确认房主已开房且樱花映射 TCP 隧道已开启）"
            or ((cerr == "connection refused" or cerr == "refused")
                and "连接被拒绝（请确认房主已点创建房间且映射本地端口为 17777）"
                or tostring(cerr))
        self.last_error = string.format("连接 %s:%d 失败：%s", target_ip, target_port, hint)
        self:log("Connect %s:%d (%s) failed: %s", target_ip, target_port, connect_ip, tostring(cerr))
        return false, self.last_error
    end

    pcall(c.setoption, c, "tcp-nodelay", true)
    pcall(c.setoption, c, "keepalive", true)
    c:settimeout(0)
    self.peer = c
    self.peer_ip = target_ip
    self.port = target_port
    self.role = "client"
    self.state = "connected"
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self:log("Connected to LAN/FRP host %s:%d (ip=%s)", target_ip, target_port, connect_ip)
    return true
end

function net_lan:send(msg)
    if not self.peer or self.state ~= "connected" then
        return false
    end
    local raw = proto.encode(msg)
    self.send_queue[#self.send_queue + 1] = raw
    self:flush_send()
    return true
end

function net_lan:flush_send()
    if not self.peer then return end
    while #self.send_queue > 0 do
        local chunk = self.send_queue[1]
        local sent, err, partial = self.peer:send(chunk, self.send_offset)
        if sent then
            table.remove(self.send_queue, 1)
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
    if self.peer then
        pcall(self.peer.close, self.peer)
        self.peer = nil
    end
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self.peer_ip = nil
    if self.role == "host" and self.server then
        self.state = "listening"
    else
        self.state = "closed"
    end
    self.last_error = "Disconnected: " .. tostring(reason)
end

function net_lan:poll()
    local events = {}
    local now = socket.gettime()

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

    -- 3. Host TCP accept (only 1 guest in 2P Co-op)
    if self.role == "host" and self.server and not self.peer then
        local client, err = self.server:accept()
        if client then
            pcall(client.setoption, client, "tcp-nodelay", true)
            pcall(client.setoption, client, "keepalive", true)
            client:settimeout(0)
            local cip = select(1, client:getpeername()) or "?"
            self.peer = client
            self.peer_ip = cip
            self.state = "connected"
            self.recv_buf = ""
            self.send_queue = {}
            self.send_offset = 1
            self:log("Guest connected from %s", tostring(cip))
            events[#events + 1] = { type = "peer_connected", ip = cip }
        end
    end

    -- 4. Flush outgoing TCP queue
    if self.peer and self.state == "connected" then
        self:flush_send()
    end

    -- 5. Non-blocking TCP receive & line framing
    if self.peer and self.state == "connected" then
        for _ = 1, 32 do
            if not self.peer then break end
            local data, err, partial = self.peer:receive(8192)
            local chunk = data or partial
            if chunk and #chunk > 0 then
                self.recv_buf = self.recv_buf .. chunk
            end
            if err == "closed" then
                self:log("Peer disconnected (closed)")
                self:handle_peer_disconnect("closed")
                events[#events + 1] = { type = "peer_disconnected", reason = "closed" }
                break
            elseif err == "timeout" or not data then
                break
            end
        end

        while true do
            local nl = self.recv_buf:find("\n", 1, true)
            if not nl then break end
            local line = self.recv_buf:sub(1, nl - 1)
            self.recv_buf = self.recv_buf:sub(nl + 1)
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

        -- Periodic RTT ping every 1.5s
        if self.peer and now - self.last_ping_ts >= 1.5 then
            self.last_ping_ts = now
            self:send({ t = "PING", ts = now })
        end
    end

    return events
end

return net_lan
