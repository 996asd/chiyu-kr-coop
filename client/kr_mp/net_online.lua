-- KR-MP Online Relay Transport (M2: Non-blocking DNS + Non-blocking TCP to Go Public Relay Server)
local socket = require("socket")
local proto = require("kr_mp.proto")

local net_online = {}
net_online.__index = net_online

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

function net_online.new(boot)
    local self = setmetatable({}, net_online)
    self.boot = boot
    self.role = "online"
    self.state = "idle" -- "idle" | "resolving" | "connecting" | "connected" | "closed"
    self.sock = nil
    self.connecting_sock = nil
    self.connect_seq = 0
    self.connect_started_ts = 0
    self.connect_deadline = 0
    self.connect_saw_peer = false
    self.connect_target_host = nil
    self.connect_target_port = nil
    self.connect_target_ip = nil
    self.connect_silent = false
    self.dns_channel = (love and love.thread and love.thread.getChannel)
        and love.thread.getChannel("kr_mp_online_dns") or nil
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

function net_online:is_connecting()
    return self.state == "resolving" or self.state == "connecting"
end

function net_online:close()
    self.connect_seq = self.connect_seq + 1
    if self.connecting_sock then
        pcall(self.connecting_sock.close, self.connecting_sock)
        self.connecting_sock = nil
    end
    if self.sock then
        pcall(self.sock.close, self.sock)
        self.sock = nil
    end
    self.state = "idle"
    self.connect_saw_peer = false
    self.connect_target_host = nil
    self.connect_target_port = nil
    self.connect_target_ip = nil
    self.recv_buf = ""
    self.send_queue = {}
    self.send_offset = 1
end

function net_online:format_connect_error(target_host, target_port, cerr)
    local hint = (cerr == "timeout")
        and "连接超时（请检查公网服或樱花映射 TCP 17780 隧道是否开启）"
        or ((cerr == "connection refused" or cerr == "refused")
            and "连接被拒绝（请确认已启动公网中继服 kr-mp-server.exe）"
            or tostring(cerr))
    return string.format("连接 %s:%d 失败：%s", target_host, target_port, hint)
end

function net_online:begin_tcp_connect(connect_ip, target_host, target_port)
    local c, err = socket.tcp()
    if not c then
        self.last_error = "TCP 初始化失败: " .. tostring(err)
        self.state = "idle"
        return false, self.last_error
    end

    c:settimeout(0)
    local ok, cerr = c:connect(connect_ip, target_port)
    if ok == 1 then
        pcall(c.setoption, c, "tcp-nodelay", true)
        pcall(c.setoption, c, "keepalive", true)
        self.sock = c
        self.connecting_sock = nil
        self.host = target_host
        self.port = target_port
        self.state = "connected"
        self.recv_buf = ""
        self.send_queue = {}
        self.send_offset = 1
        self.last_ping_ts = socket.gettime()
        self.last_error = nil
        self:log("Connected to Online Relay Server %s:%d (ip=%s)", target_host, target_port, connect_ip)
        return true, "connected"
    end

    if cerr == "timeout" or cerr == "Operation already in progress" or cerr == "already in progress" then
        local now = socket.gettime()
        self.connecting_sock = c
        self.connect_target_host = target_host
        self.connect_target_port = target_port
        self.connect_target_ip = connect_ip
        self.connect_started_ts = now
        self.connect_deadline = now + 5.0
        self.connect_saw_peer = (c:getpeername() ~= nil)
        self.state = "connecting"
        self.last_error = nil
        return true, "connecting"
    end

    pcall(c.close, c)
    self.last_error = self:format_connect_error(target_host, target_port, cerr)
    self.state = "idle"
    self:log("Connect server %s:%d (%s) failed: %s", target_host, target_port, connect_ip, tostring(cerr))
    return false, self.last_error
end

-- Non-blocking connect: returns (true, "connected"|"connecting"|"resolving") or (false, err_msg)
function net_online:connect(host, port, silent_fail)
    self:close()
    local clean = proto.sanitize_addr(host or "")
    local target_host = (clean ~= "") and clean or proto.DEFAULT_ONLINE_HOST
    local target_port = tonumber(port) or proto.DEFAULT_ONLINE_PORT
    local p_host, p_port = target_host:match("^([^:]+):(%d+)$")
    if p_host and p_port then
        target_host = p_host
        target_port = tonumber(p_port)
    end

    self.connect_silent = (silent_fail == true)
    self.connect_target_host = target_host
    self.connect_target_port = target_port

    if target_host:match("^%d+%.%d+%.%d+%.%d+$") then
        return self:begin_tcp_connect(target_host, target_host, target_port)
    end

    -- Non-blocking DNS lookup via love.thread so main loop never freezes
    if love and love.thread and love.thread.newThread and self.dns_channel then
        self.connect_seq = self.connect_seq + 1
        local seq = self.connect_seq
        local ok_th, th = pcall(love.thread.newThread, DNS_WORKER_CODE)
        if ok_th and th then
            self.state = "resolving"
            self.connect_started_ts = socket.gettime()
            self.connect_deadline = self.connect_started_ts + 5.0
            self.last_error = nil
            th:start("kr_mp_online_dns", seq, target_host)
            return true, "resolving"
        end
    end

    -- Fallback synchronous DNS if love.thread unavailable
    local resolved, derr = socket.dns.toip(target_host)
    if not resolved then
        self.last_error = string.format("域名解析失败 (%s)：请检查服务器/樱花映射地址", target_host)
        self:log("DNS resolve failed for %s: %s", target_host, tostring(derr))
        return false, self.last_error
    end
    self:log("Resolved server %s -> %s", target_host, resolved)
    return self:begin_tcp_connect(resolved, target_host, target_port)
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

function net_online:fail_pending_connect(events, raw_err, display_err)
    local host = self.connect_target_host or self.host
    local port = self.connect_target_port or self.port
    local ip = self.connect_target_ip or host
    local silent = self.connect_silent
    if self.connecting_sock then
        pcall(self.connecting_sock.close, self.connecting_sock)
        self.connecting_sock = nil
    end
    self.state = "idle"
    self.connect_saw_peer = false
    self.last_error = display_err or self:format_connect_error(host, port, raw_err)
    self:log("Connect server %s:%d (%s) failed: %s", tostring(host), tonumber(port) or 0, tostring(ip), tostring(raw_err))
    events[#events + 1] = {
        type = "server_connect_failed",
        reason = self.last_error,
        silent = silent,
    }
end

function net_online:poll()
    local events = {}
    local now = socket.gettime()

    -- 0a. Async DNS completion
    if self.state == "resolving" then
        if self.dns_channel then
            while true do
                local res = self.dns_channel:pop()
                if not res then break end
                if res.seq == self.connect_seq then
                    if not res.ip then
                        local msg = string.format("域名解析失败 (%s)：请检查服务器/樱花映射地址", tostring(self.connect_target_host))
                        self:fail_pending_connect(events, res.err or "dns_failed", msg)
                        return events
                    end
                    self:log("Resolved server %s -> %s", tostring(self.connect_target_host), tostring(res.ip))
                    local ok, st = self:begin_tcp_connect(res.ip, self.connect_target_host, self.connect_target_port)
                    if not ok then
                        events[#events + 1] = {
                            type = "server_connect_failed",
                            reason = self.last_error or tostring(st),
                            silent = self.connect_silent,
                        }
                        return events
                    elseif st == "connected" then
                        events[#events + 1] = { type = "server_connected" }
                    end
                    break
                end
            end
        end
        if self.state == "resolving" and now >= self.connect_deadline then
            local msg = string.format("域名解析超时 (%s)：请检查网络或服务器地址", tostring(self.connect_target_host))
            self:fail_pending_connect(events, "dns_timeout", msg)
        end
        return events
    end

    -- 0b. Non-blocking TCP handshake poll (0ms main-thread overhead)
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
                self.sock = c
                self.connecting_sock = nil
                self.host = self.connect_target_host
                self.port = self.connect_target_port
                self.state = "connected"
                self.recv_buf = ""
                self.send_queue = {}
                self.send_offset = 1
                self.last_ping_ts = now
                self.last_error = nil
                self:log("Connected to Online Relay Server %s:%d (ip=%s)",
                    tostring(self.host), tonumber(self.port) or 0, tostring(self.connect_target_ip))
                events[#events + 1] = { type = "server_connected" }
                return events
            else
                self:fail_pending_connect(events, "connection refused")
                return events
            end
        end

        -- On Windows Winsock, a failed non-blocking connect clears getpeername() without firing writefds
        if not peer and (self.connect_saw_peer or (now - self.connect_started_ts) >= 0.08) then
            self:fail_pending_connect(events, "connection refused")
            return events
        end

        if now >= self.connect_deadline then
            self:fail_pending_connect(events, "timeout")
            return events
        end
        return events
    end

    if not self.sock or self.state ~= "connected" then
        return events
    end

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
