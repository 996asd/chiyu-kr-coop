-- KR-MP Shared Non-Blocking TCP Line-JSON Stream Engine
-- Shared by net_lan.lua (LAN / SakuraFrp direct) and net_online.lua (Go relay server)
-- Covers: async DNS via love.thread, non-blocking TCP handshake, anti-HoL QoS voice queue,
--         O(N) newline-delimited JSON framing, RTT PING/PONG, and 12s dead-link watchdog.
local socket = require("socket")
local proto = require("kr_mp.proto")

local M = {}

M.WATCHDOG_SEC = tonumber(os.getenv("KR_MP_WATCHDOG_SEC")) or 12.0

M.DNS_WORKER_CODE = [[
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

function M.reset_io_buffers(conn)
    conn.recv_buf = ""
    conn.send_queue = {}
    conn.voice_queue = {}
    conn.active_chunk = nil
    conn.send_offset = 1
end

function M.configure_socket(sock)
    pcall(sock.setoption, sock, "tcp-nodelay", true)
    pcall(sock.setoption, sock, "keepalive", true)
    sock:settimeout(0)
end

function M.is_lockstep_waiting(conn)
    return conn.boot ~= nil and conn.boot.lockstep ~= nil and conn.boot.lockstep.waiting_for_peer == true
end

-- Protect 12s watchdog against local main-thread stalls (e.g., FL level load/unload texture GC)
function M.protect_watchdog_stall(conn, now)
    if (conn.last_poll_ts or 0) > 0 then
        local gap = now - conn.last_poll_ts
        if gap > 1.5 and (conn.last_recv_ts or 0) > 0 then
            conn.last_recv_ts = conn.last_recv_ts + gap
        end
    end
    conn.last_poll_ts = now
end

function M.start_async_dns(conn, channel_name, target_host, timeout_sec)
    if not (love and love.thread and love.thread.newThread and conn.dns_channel) then
        return false
    end
    conn.connect_seq = (conn.connect_seq or 0) + 1
    local seq = conn.connect_seq
    local ok_th, th = pcall(love.thread.newThread, M.DNS_WORKER_CODE)
    if not ok_th or not th then
        return false
    end
    conn.state = "resolving"
    conn.connect_started_ts = socket.gettime()
    conn.connect_deadline = conn.connect_started_ts + (timeout_sec or 5.0)
    conn.last_error = nil
    th:start(channel_name, seq, target_host)
    return true
end

-- Returns: ("connected", sock) | ("connecting", sock) | ("error", err_str)
function M.begin_nonblocking_connect(conn, connect_ip, target_host, target_port, timeout_sec)
    local c, err = socket.tcp()
    if not c then
        return "error", "TCP 初始化失败: " .. tostring(err)
    end
    c:settimeout(0)
    local ok, cerr = c:connect(connect_ip, target_port)
    if ok == 1 then
        M.configure_socket(c)
        conn.connecting_sock = nil
        M.reset_io_buffers(conn)
        local now = socket.gettime()
        conn.last_ping_ts = now
        conn.last_recv_ts = now
        conn.last_error = nil
        return "connected", c
    end
    if cerr == "timeout" or cerr == "Operation already in progress" or cerr == "already in progress" then
        local now = socket.gettime()
        conn.connecting_sock = c
        conn.connect_target_host = target_host
        conn.connect_target_port = target_port
        conn.connect_target_ip = connect_ip
        conn.connect_started_ts = now
        conn.connect_deadline = now + (timeout_sec or 5.0)
        conn.connect_saw_peer = (c:getpeername() ~= nil)
        conn.state = "connecting"
        conn.last_error = nil
        return "connecting", c
    end
    pcall(c.close, c)
    return "error", cerr
end

-- Returns: ("resolved", ip) | ("failed", err) | ("timeout", "dns_timeout") | ("pending", nil)
function M.poll_dns(conn, now)
    if conn.dns_channel then
        while true do
            local res = conn.dns_channel:pop()
            if not res then break end
            if res.seq == conn.connect_seq then
                if res.ip then
                    return "resolved", res.ip
                end
                return "failed", res.err or "dns_failed"
            end
        end
    end
    if now >= (conn.connect_deadline or 0) then
        return "timeout", "dns_timeout"
    end
    return "pending", nil
end

-- Returns: ("connected", sock) | ("refused", "connection refused") | ("timeout", "timeout") | ("pending", nil)
function M.poll_connect(conn, now)
    local c = conn.connecting_sock
    if not c then return "pending", nil end
    local _, writable = socket.select(nil, { c }, 0)
    local peer = c:getpeername()
    if peer then
        conn.connect_saw_peer = true
    end
    if writable and #writable > 0 then
        if peer then
            M.configure_socket(c)
            conn.connecting_sock = nil
            M.reset_io_buffers(conn)
            conn.last_ping_ts = now
            conn.last_recv_ts = now
            conn.last_error = nil
            return "connected", c
        end
        return "refused", "connection refused"
    end
    -- On Windows Winsock, a failed non-blocking connect clears getpeername() without firing writefds
    if not peer and (conn.connect_saw_peer or (now - (conn.connect_started_ts or 0)) >= 0.08) then
        return "refused", "connection refused"
    end
    if now >= (conn.connect_deadline or 0) then
        return "timeout", "timeout"
    end
    return "pending", nil
end

function M.flush_send(conn, sock, on_error)
    if not sock then return end
    while conn.active_chunk or #conn.send_queue > 0 or #conn.voice_queue > 0 do
        if not conn.active_chunk then
            if #conn.send_queue > 0 then
                conn.active_chunk = table.remove(conn.send_queue, 1)
                conn.send_offset = 1
            elseif #conn.voice_queue > 0 then
                if M.is_lockstep_waiting(conn) then
                    conn.voice_dropped = (conn.voice_dropped or 0) + #conn.voice_queue
                    conn.voice_queue = {}
                    break
                end
                conn.active_chunk = table.remove(conn.voice_queue, 1)
                conn.send_offset = 1
            end
        end
        local sent, err, partial = sock:send(conn.active_chunk, conn.send_offset)
        if sent then
            conn.active_chunk = nil
            conn.send_offset = 1
        elseif err == "timeout" then
            if partial and partial >= conn.send_offset then
                conn.send_offset = partial + 1
            end
            break
        else
            if on_error then on_error(err) end
            break
        end
    end
end

function M.send(conn, sock, msg, on_error)
    if not sock or conn.state ~= "connected" then
        return false
    end
    if msg and msg.t == "VOICE" then
        -- Anti-HoL QoS: always yield to lockstep TURN/control traffic
        if #conn.send_queue > 2 or #conn.voice_queue >= 2 or M.is_lockstep_waiting(conn) then
            conn.voice_dropped = (conn.voice_dropped or 0) + 1
            return false
        end
        conn.voice_queue[#conn.voice_queue + 1] = proto.encode(msg)
        M.flush_send(conn, sock, on_error)
        return true
    end
    conn.send_queue[#conn.send_queue + 1] = proto.encode(msg)
    M.flush_send(conn, sock, on_error)
    return true
end

-- Non-blocking receive + O(N) newline JSON framing + PING/PONG RTT + 12s watchdog.
-- Returns disconnect reason string if the link closed/timed out, else nil.
function M.pump_connected(conn, get_sock, now, events, opts)
    opts = opts or {}
    local chunks = nil
    local closed_reason = nil
    for _ = 1, 64 do
        local sock = get_sock()
        if not sock then break end
        local data, err, partial = sock:receive(16384)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            conn.last_recv_ts = now
            if not chunks then
                chunks = (#conn.recv_buf > 0) and { conn.recv_buf, chunk } or { chunk }
            else
                chunks[#chunks + 1] = chunk
            end
        end
        if err == "closed" then
            closed_reason = opts.classify_eof and opts.classify_eof(now) or "closed"
            if opts.on_closed then opts.on_closed(closed_reason) end
            break
        elseif err == "timeout" or not data then
            break
        end
    end
    if chunks then
        conn.recv_buf = (#chunks == 1) and chunks[1] or table.concat(chunks)
    end

    if #conn.recv_buf > 0 then
        local pos = 1
        while true do
            local nl = conn.recv_buf:find("\n", pos, true)
            if not nl then break end
            local line = conn.recv_buf:sub(pos, nl - 1)
            pos = nl + 1
            if #line > 0 then
                local msg, derr = proto.decode(line)
                if msg then
                    if opts.on_msg_decoded then opts.on_msg_decoded(msg) end
                    if msg.t == "PING" then
                        conn:send({ t = "PONG", ts = msg.ts })
                    elseif msg.t == "PONG" and type(msg.ts) == "number" then
                        conn.rtt_ms = math.floor((socket.gettime() - msg.ts) * 1000 + 0.5)
                    else
                        events[#events + 1] = { type = "msg", msg = msg }
                    end
                elseif opts.on_malformed then
                    opts.on_malformed(derr)
                end
            end
        end
        if pos > 1 then
            conn.recv_buf = conn.recv_buf:sub(pos)
        end
    end

    if closed_reason then
        conn.pending_disconnect_reason = nil
        return closed_reason
    end

    local sock = get_sock()
    if sock and conn.state == "connected" and (conn.last_recv_ts or 0) > 0 and (now - conn.last_recv_ts) >= M.WATCHDOG_SEC then
        if opts.on_watchdog then opts.on_watchdog(now - conn.last_recv_ts) end
        conn.pending_disconnect_reason = nil
        return "watchdog_timeout"
    end

    if sock and conn.state == "connected" and now - (conn.last_ping_ts or 0) >= 1.5 then
        conn.last_ping_ts = now
        conn:send({ t = "PING", ts = now })
    end
    return nil
end

return M
