-- KR-MP Online Relay Transport (M2: connects to Go Public Lobby & Frame-Relay Server over TCP)
local socket = require("socket")
local proto = require("kr_mp.proto")

local net_online = {}
net_online.__index = net_online

function net_online.new(boot)
    local self = setmetatable({}, net_online)
    self.boot = boot
    self.role = "online"
    self.state = "idle" -- "idle" | "connected" | "closed"
    self.sock = nil
    self.host = proto.DEFAULT_ONLINE_HOST
    self.port = proto.DEFAULT_ONLINE_PORT
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self.last_error = nil
    self.last_ping_ts = 0
    self.rtt_ms = 0
    return self
end

function net_online:log(fmt, ...)
    if self.boot and self.boot.log then
        self.boot:log("[ONLINE] " .. fmt, ...)
    end
end

function net_online:close()
    if self.sock then
        pcall(self.sock.close, self.sock)
        self.sock = nil
    end
    self.state = "idle"
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
end

function net_online:connect(host, port)
    self:close()
    local clean = proto.sanitize_addr(host or "")
    local target_host = (clean ~= "") and clean or proto.DEFAULT_ONLINE_HOST
    local target_port = tonumber(port) or proto.DEFAULT_ONLINE_PORT
    local p_host, p_port = target_host:match("^([^:]+):(%d+)$")
    if p_host and p_port then
        target_host = p_host
        target_port = tonumber(p_port)
    end

    local connect_ip = target_host
    if not target_host:match("^%d+%.%d+%.%d+%.%d+$") then
        local resolved, derr = socket.dns.toip(target_host)
        if not resolved then
            self.last_error = string.format("域名解析失败 (%s)：请检查服务器/樱花映射地址", target_host)
            self:log("DNS resolve failed for %s: %s", target_host, tostring(derr))
            return false, self.last_error
        end
        self:log("Resolved server %s -> %s", target_host, resolved)
        connect_ip = resolved
    end

    local c, err = socket.tcp()
    if not c then
        self.last_error = "TCP 初始化失败: " .. tostring(err)
        return false, self.last_error
    end

    c:settimeout(5.0)
    local ok, cerr = c:connect(connect_ip, target_port)
    if not ok then
        c:close()
        local hint = (cerr == "timeout")
            and "连接超时（请检查公网服或樱花映射 TCP 17780 隧道是否开启）"
            or ((cerr == "connection refused" or cerr == "refused")
                and "连接被拒绝（请确认已启动公网中继服 kr-mp-server.exe）"
                or tostring(cerr))
        self.last_error = string.format("连接 %s:%d 失败：%s", target_host, target_port, hint)
        self:log("Connect server %s:%d (%s) failed: %s", target_host, target_port, connect_ip, tostring(cerr))
        return false, self.last_error
    end

    pcall(c.setoption, c, "tcp-nodelay", true)
    pcall(c.setoption, c, "keepalive", true)
    c:settimeout(0)

    self.sock = c
    self.host = target_host
    self.port = target_port
    self.state = "connected"
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self.last_ping_ts = socket.gettime()
    self.last_error = nil

    self:log("Connected to Online Relay Server %s:%d (ip=%s)", target_host, target_port, connect_ip)
    return true
end

function net_online:get_server_addr()
    return string.format("%s:%d", tostring(self.host or proto.DEFAULT_ONLINE_HOST), tonumber(self.port) or proto.DEFAULT_ONLINE_PORT)
end

function net_online:send(msg)
    if not self.sock or self.state ~= "connected" then
        return false
    end
    local raw = proto.encode(msg)
    self.send_queue[#self.send_queue + 1] = raw
    self:flush_send()
    return true
end

function net_online:flush_send()
    if not self.sock then return end
    while #self.send_queue > 0 do
        local chunk = self.send_queue[1]
        local sent, err, partial = self.sock:send(chunk, self.send_offset)
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
            self:handle_disconnect(err)
            break
        end
    end
end

function net_online:handle_disconnect(reason)
    if self.sock then
        pcall(self.sock.close, self.sock)
        self.sock = nil
    end
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
    self.state = "closed"
    self.last_error = "Server disconnected: " .. tostring(reason)
end

function net_online:poll()
    local events = {}
    if not self.sock or self.state ~= "connected" then
        return events
    end

    local now = socket.gettime()

    -- 1. Flush outgoing TCP queue
    self:flush_send()
    if not self.sock or self.state ~= "connected" then
        events[#events + 1] = { type = "server_disconnected", reason = self.last_error or "send_failed" }
        return events
    end

    -- 2. Non-blocking TCP receive (drain large RECONNECT_STATE bursts smoothly)
    for _ = 1, 64 do
        if not self.sock then break end
        local data, err, partial = self.sock:receive(16384)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            self.recv_buf = self.recv_buf .. chunk
        end
        if err == "closed" then
            self:log("Online server connection closed")
            self:handle_disconnect("closed")
            events[#events + 1] = { type = "server_disconnected", reason = "closed" }
            break
        elseif err == "timeout" or not data then
            break
        end
    end

    -- 3. Newline-delimited JSON framing
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
                self:log("Malformed server msg: %s", tostring(derr))
            end
        end
    end

    -- 4. Periodic RTT & keepalive ping every 1.5s
    if self.sock and self.state == "connected" and now - self.last_ping_ts >= 1.5 then
        self.last_ping_ts = now
        self:send({ t = "PING", ts = now })
    end

    return events
end

return net_online
