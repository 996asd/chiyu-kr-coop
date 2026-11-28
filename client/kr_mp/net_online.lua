-- KR-MP Online Relay Transport (M2: Non-blocking DNS + Non-blocking TCP to Go Public Relay Server)
local socket = require("socket")
local proto = require("kr_mp.proto")
local tcp_stream = require("kr_mp.tcp_stream")

local net_online = {}
net_online.__index = net_online

function net_online.new(boot, dns_channel_name)
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
    self.dns_channel_name = (type(dns_channel_name) == "string" and #dns_channel_name > 0)
        and dns_channel_name or "kr_mp_online_dns"
    self.dns_channel = (love and love.thread and love.thread.getChannel)
        and love.thread.getChannel(self.dns_channel_name) or nil
    self.host = proto.DEFAULT_ONLINE_HOST
    self.port = proto.DEFAULT_ONLINE_PORT
    tcp_stream.reset_io_buffers(self)
    self.voice_dropped = 0
    self.last_error = nil
    self.last_ping_ts = 0
    self.last_recv_ts = 0
    self.last_poll_ts = 0
    self.pending_disconnect_reason = nil
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
    tcp_stream.reset_io_buffers(self)
    self.last_recv_ts = 0
    self.pending_disconnect_reason = nil
end

function net_online:format_connect_error(target_host, target_port, cerr)
    local hint = (cerr == "timeout")
        and "连接超时（请检查公网服或樱花映射 TCP 17780 隧道是否开启）"
        or ((cerr == "connection refused" or cerr == "refused")
            and "连接被拒绝（请确认已启动公网中继服 kr-mp-server.exe）"
            or tostring(cerr))
    return string.format("连接 %s:%d 失败：%s", target_host, target_port, hint)
end

function net_online:_mark_connected(sock, host, port, resolved_ip)
    self.sock = sock
    self.host = host
    self.port = port
    self.state = "connected"
    self:log("Connected to Online Relay Server %s:%d (ip=%s)", tostring(host), tonumber(port) or 0, tostring(resolved_ip))
end

function net_online:begin_tcp_connect(connect_ip, target_host, target_port)
    local status, res = tcp_stream.begin_nonblocking_connect(self, connect_ip, target_host, target_port, 5.0)
    if status == "connected" then
        self:_mark_connected(res, target_host, target_port, connect_ip)
        return true, "connected"
    elseif status == "connecting" then
        return true, "connecting"
    end
    self.last_error = (type(res) == "string" and res:match("^TCP ")) and res or self:format_connect_error(target_host, target_port, res)
    self.state = "idle"
    self:log("Connect server %s:%d (%s) failed: %s", target_host, target_port, connect_ip, tostring(res))
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

    if tcp_stream.start_async_dns(self, self.dns_channel_name or "kr_mp_online_dns", target_host, 5.0) then
        return true, "resolving"
    end

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

function net_online:is_lockstep_waiting()
    return tcp_stream.is_lockstep_waiting(self)
end

function net_online:send(msg)
    return tcp_stream.send(self, self.sock, msg, function(err)
        self:log("TCP send error: %s", tostring(err))
        self:handle_disconnect(err)
    end)
end

function net_online:flush_send()
    tcp_stream.flush_send(self, self.sock, function(err)
        self:log("TCP send error: %s", tostring(err))
        self:handle_disconnect(err)
    end)
end

function net_online:handle_disconnect(reason)
    local was_connected = (self.sock ~= nil or self.state == "connected")
    if self.sock then
        pcall(self.sock.close, self.sock)
        self.sock = nil
    end
    tcp_stream.reset_io_buffers(self)
    self.last_recv_ts = 0
    self.state = "closed"
    self.last_error = "Server disconnected: " .. tostring(reason)
    if was_connected then
        self.pending_disconnect_reason = tostring(reason or "closed")
    end
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
    events[#events + 1] = { type = "server_connect_failed", reason = self.last_error, silent = silent }
end

function net_online:poll()
    local events = {}
    local now = socket.gettime()
    tcp_stream.protect_watchdog_stall(self, now)

    if self.pending_disconnect_reason then
        local r = self.pending_disconnect_reason
        self.pending_disconnect_reason = nil
        events[#events + 1] = { type = "server_disconnected", reason = r }
        return events
    end

    if self.state == "resolving" then
        local dns_st, val = tcp_stream.poll_dns(self, now)
        if dns_st == "resolved" then
            self:log("Resolved server %s -> %s", tostring(self.connect_target_host), tostring(val))
            local ok, st = self:begin_tcp_connect(val, self.connect_target_host, self.connect_target_port)
            if not ok then
                events[#events + 1] = { type = "server_connect_failed", reason = self.last_error or tostring(st), silent = self.connect_silent }
            elseif st == "connected" then
                events[#events + 1] = { type = "server_connected" }
            end
        elseif dns_st == "failed" then
            local msg = string.format("域名解析失败 (%s)：请检查服务器/樱花映射地址", tostring(self.connect_target_host))
            self:fail_pending_connect(events, val, msg)
        elseif dns_st == "timeout" then
            local msg = string.format("域名解析超时 (%s)：请检查网络或服务器地址", tostring(self.connect_target_host))
            self:fail_pending_connect(events, "dns_timeout", msg)
        end
        return events
    end

    if self.state == "connecting" and self.connecting_sock then
        local c_st, val = tcp_stream.poll_connect(self, now)
        if c_st == "connected" then
            self:_mark_connected(val, self.connect_target_host, self.connect_target_port, self.connect_target_ip)
            events[#events + 1] = { type = "server_connected" }
        elseif c_st == "refused" or c_st == "timeout" then
            self:fail_pending_connect(events, val)
        end
        return events
    end

    if not self.sock or self.state ~= "connected" then
        return events
    end

    self:flush_send()
    if not self.sock or self.state ~= "connected" then
        local r = self.pending_disconnect_reason or self.last_error or "send_failed"
        self.pending_disconnect_reason = nil
        events[#events + 1] = { type = "server_disconnected", reason = r }
        return events
    end

    local disc = tcp_stream.pump_connected(self, function() return self.sock end, now, events, {
        on_closed = function()
            self:log("Online server connection closed")
            self:handle_disconnect("closed")
        end,
        on_malformed = function(derr) self:log("Malformed server msg: %s", tostring(derr)) end,
        on_watchdog = function(elapsed)
            self:log("Dead-link watchdog timeout (%.1fs without inbound bytes); closing server socket", elapsed)
            self:handle_disconnect("watchdog_timeout")
        end,
    })
    if disc then
        events[#events + 1] = { type = "server_disconnected", reason = disc }
    end

    return events
end

return net_online
