-- KR-MP SakuraFrp Background Worker Threads (Isolated from 60Hz Sim)
-- Contains three self-contained love.thread worker scripts:
--   1. PROBE_WORKER_CODE     : Concurrent 3-line TCP latency probe (Default / dx. / yd.)
--   2. API_WORKER_CODE       : Opt-in Official OpenAPI v4 client (WinINet / LuaHTTPS)
--   3. INSTALLER_WORKER_CODE : Official SakuraLauncher.exe downloader with live progress & MD5 verify
local M = {}

M.PROBE_WORKER_CODE = [===[
local ch_name, seq, base, port = ...
local ch = love.thread.getChannel(ch_name)
local ok_s, socket = pcall(require, "socket")
if not ok_s or not socket then
    ch:push({ seq = seq, ok = false, err = "no_socket" })
    return
end

local targets = {
    { id = "default", host = base },
    { id = "dx",      host = "dx." .. base },
    { id = "yd",      host = "yd." .. base },
}
local results = {}
local pending = {}

for _, t in ipairs(targets) do
    local ip = socket.dns.toip(t.host)
    if not ip then
        results[t.id] = { ok = false, err = "dns" }
    else
        local s = socket.tcp()
        if not s then
            results[t.id] = { ok = false, err = "sock" }
        else
            s:settimeout(0)
            local t0 = socket.gettime()
            local ok, cerr = s:connect(ip, port)
            if ok == 1 then
                local ms = math.max(1, math.floor((socket.gettime() - t0) * 1000 + 0.5))
                pcall(s.close, s)
                results[t.id] = { ok = true, ms = ms, host = t.host }
            elseif cerr == "timeout" or cerr == "Operation already in progress" or cerr == "already in progress" then
                pending[#pending + 1] = { id = t.id, host = t.host, sock = s, t0 = t0, saw_peer = (s:getpeername() ~= nil) }
            else
                pcall(s.close, s)
                results[t.id] = { ok = false, err = "refused" }
            end
        end
    end
end

local deadline = socket.gettime() + 2.6
while #pending > 0 and socket.gettime() < deadline do
    local socks = {}
    for i = 1, #pending do socks[i] = pending[i].sock end
    local _, writable = socket.select(nil, socks, 0.05)
    local wmap = {}
    if writable then
        for i = 1, #writable do wmap[writable[i]] = true end
    end
    local now = socket.gettime()
    for i = #pending, 1, -1 do
        local p = pending[i]
        local peer = p.sock:getpeername()
        if peer then p.saw_peer = true end
        if wmap[p.sock] then
            if peer then
                local ms = math.max(1, math.floor((now - p.t0) * 1000 + 0.5))
                results[p.id] = { ok = true, ms = ms, host = p.host }
            else
                results[p.id] = { ok = false, err = "refused" }
            end
            pcall(p.sock.close, p.sock)
            table.remove(pending, i)
        elseif not peer and (p.saw_peer or (now - p.t0) >= 0.12) then
            results[p.id] = { ok = false, err = "refused" }
            pcall(p.sock.close, p.sock)
            table.remove(pending, i)
        end
    end
end

for _, p in ipairs(pending) do
    results[p.id] = { ok = false, err = "timeout" }
    pcall(p.sock.close, p.sock)
end

local best_id, best_ms, best_host = nil, 999999, nil
for _, id in ipairs({ "default", "dx", "yd" }) do
    local r = results[id]
    if r and r.ok and r.ms < best_ms then
        best_id, best_ms, best_host = id, r.ms, r.host
    end
end

ch:push({
    seq = seq,
    ok = true,
    base = base,
    port = port,
    results = results,
    best = best_id,
    best_ms = best_ms,
    best_addr = best_host and (best_host .. ":" .. tostring(port)) or nil,
})
]===]

M.API_WORKER_CODE = [===[
local ch_name, seq, action, token, payload_json, pkg_path = ...
if type(pkg_path) == "string" and #pkg_path > 0 then
    package.path = pkg_path
end
local ch = love.thread.getChannel(ch_name)
local ok_p, proto = pcall(require, "kr_mp.proto")
if not ok_p or not proto then
    ch:push({ seq = seq, action = action, ok = false, err = "无法加载协议模块" })
    return
end

local API_HOSTS = { "api.natfrp.com", "natfrp-api.globalslb.net" }

local function wininet_request(host, method, path, auth_token, body_str)
    local ok_ffi, ffi = pcall(require, "ffi")
    local ok_bit, bit = pcall(require, "bit")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" or not ok_bit then
        return nil, 0, "no_wininet"
    end
    pcall(ffi.cdef, [=[
        void* InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
        void* InternetConnectA(void* hInternet, const char* lpszServerName, uint16_t nServerPort, const char* lpszUserName, const char* lpszPassword, uint32_t dwService, uint32_t dwFlags, uintptr_t dwContext);
        void* HttpOpenRequestA(void* hConnect, const char* lpszVerb, const char* lpszObjectName, const char* lpszVersion, const char* lpszReferrer, void* lplpszAcceptTypes, uint32_t dwFlags, uintptr_t dwContext);
        int32_t HttpSendRequestA(void* hRequest, const char* lpszHeaders, uint32_t dwHeadersLength, const void* lpOptional, uint32_t dwOptionalLength);
        int32_t HttpQueryInfoA(void* hRequest, uint32_t dwInfoLevel, void* lpBuffer, uint32_t* lpdwBufferLength, uint32_t* lpdwIndex);
        int32_t InternetReadFile(void* hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
        int32_t InternetCloseHandle(void* hInternet);
        int32_t InternetSetOptionA(void* hInternet, uint32_t dwOption, void* lpBuffer, uint32_t dwBufferLength);
    ]=])
    local ok_lib, wi = pcall(ffi.load, "wininet")
    if not ok_lib or not wi then return nil, 0, "wininet_load_fail" end

    local hNet = wi.InternetOpenA("KR-MP-SakuraClient/2.3", 0, nil, nil, 0)
    if hNet == nil then return nil, 0, "wininet_open_fail" end
    local timeout = ffi.new("uint32_t[1]", 8000)
    pcall(wi.InternetSetOptionA, hNet, 2, timeout, 4)
    pcall(wi.InternetSetOptionA, hNet, 6, timeout, 4)

    local hConn = wi.InternetConnectA(hNet, host, 443, nil, nil, 3, 0, 0)
    if hConn == nil then
        wi.InternetCloseHandle(hNet)
        return nil, 0, "connect_fail"
    end

    local flags = bit.bor(0x00800000, 0x80000000, 0x04000000, 0x00000100)
    local hReq = wi.HttpOpenRequestA(hConn, method, path, nil, nil, nil, flags, 0)
    if hReq == nil then
        wi.InternetCloseHandle(hConn)
        wi.InternetCloseHandle(hNet)
        return nil, 0, "openreq_fail"
    end

    local hdrs = "Authorization: Bearer " .. tostring(auth_token) .. "\r\nAccept: application/json\r\n"
    if body_str and #body_str > 0 then
        hdrs = hdrs .. "Content-Type: application/json\r\n"
    end
    local ok_send = wi.HttpSendRequestA(hReq, hdrs, #hdrs, body_str or nil, body_str and #body_str or 0)
    if ok_send == 0 then
        wi.InternetCloseHandle(hReq)
        wi.InternetCloseHandle(hConn)
        wi.InternetCloseHandle(hNet)
        return nil, 0, "send_fail"
    end

    local status_code = ffi.new("uint32_t[1]", 0)
    local status_len = ffi.new("uint32_t[1]", 4)
    wi.HttpQueryInfoA(hReq, 0x20000013, status_code, status_len, nil)

    local chunks, total = {}, 0
    local buf = ffi.new("uint8_t[8192]")
    local bread = ffi.new("uint32_t[1]")
    while total < 1048576 do
        bread[0] = 0
        local r = wi.InternetReadFile(hReq, buf, 8192, bread)
        local n = tonumber(bread[0]) or 0
        if r == 0 or n <= 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, n)
        total = total + n
    end

    wi.InternetCloseHandle(hReq)
    wi.InternetCloseHandle(hConn)
    wi.InternetCloseHandle(hNet)
    return table.concat(chunks), tonumber(status_code[0]) or 0, nil
end

local function api_call(method, path, body_str)
    local last_err = "network_error"
    for _, host in ipairs(API_HOSTS) do
        local body, code, err = wininet_request(host, method, path, token, body_str)
        if not err and code > 0 then
            return body, code, nil
        end
        local ok_hs, https = pcall(require, "https")
        if ok_hs and https and https.request then
            local url = "https://" .. host .. path
            local hdrs = { Authorization = "Bearer " .. tostring(token), Accept = "application/json" }
            if body_str then hdrs["Content-Type"] = "application/json" end
            local ok_r, hcode, hbody = pcall(https.request, url, { method = method, headers = hdrs, data = body_str })
            if ok_r and tonumber(hcode) and tonumber(hcode) > 0 then
                return hbody or "", tonumber(hcode), nil
            end
        end
        last_err = tostring(err or "https_fail")
    end
    return nil, 0, last_err
end

local function decode_or_err(body, code)
    local obj = (type(body) == "string" and #body > 0) and proto.decode(body) or nil
    if code == 401 or code == 403 then
        return nil, "访问密钥无效或无权限（HTTP " .. tostring(code) .. "）"
    end
    if code < 200 or code >= 300 then
        local msg = (type(obj) == "table" and (obj.message or obj.error or obj.msg)) or ("HTTP " .. tostring(code))
        return nil, tostring(msg)
    end
    if type(obj) ~= "table" then
        return nil, "樱花 API 返回格式异常"
    end
    return obj, nil
end

if action == "refresh" then
    local b1, c1, e1 = api_call("GET", "/v4/user/info")
    if e1 then ch:push({ seq = seq, action = action, ok = false, err = "无法连接樱花 API：" .. e1 }); return end
    local user, uerr = decode_or_err(b1, c1)
    if not user then ch:push({ seq = seq, action = action, ok = false, err = uerr }); return end

    local b2, c2 = api_call("GET", "/v4/nodes")
    local nodes = decode_or_err(b2, c2) or {}

    local b3, c3 = api_call("GET", "/v4/node/stats")
    local stats = decode_or_err(b3, c3) or {}

    local b4, c4 = api_call("GET", "/v4/tunnels")
    local tunnels = decode_or_err(b4, c4) or {}

    ch:push({
        seq = seq, action = action, ok = true,
        user = user, nodes = nodes, stats = stats, tunnels = tunnels,
    })
elseif action == "create" then
    local b, c, e = api_call("POST", "/v4/tunnels", payload_json)
    if e then ch:push({ seq = seq, action = action, ok = false, err = "创建隧道网络失败：" .. e }); return end
    local created, cerr = decode_or_err(b, c)
    if not created then ch:push({ seq = seq, action = action, ok = false, err = cerr }); return end
    ch:push({ seq = seq, action = action, ok = true, created = created })
end
]===]

M.INSTALLER_WORKER_CODE = [===[
local ch_name, seq, dest_dir, pkg_path = ...
if type(pkg_path) == "string" and #pkg_path > 0 then
    package.path = pkg_path
end
local ch = love.thread.getChannel(ch_name)
local ok_p, proto = pcall(require, "kr_mp.proto")
local ok_ffi, ffi = pcall(require, "ffi")
local ok_bit, bit = pcall(require, "bit")
if not ok_p or not proto or not ok_ffi or not ffi or ffi.os ~= "Windows" or not ok_bit then
    ch:push({ seq = seq, stage = "error", ok = false, err = "仅支持 PC Windows 自动下载官方安装器" })
    return
end

-- Pure-LuaJIT streaming MD5 (RFC 1321) for verifying official SakuraLauncher installer integrity
local band, bor, bxor, bnot, rol, tobit = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit
local MD5_K = {}
for i = 1, 64 do
    MD5_K[i] = tobit(math.floor(math.abs(math.sin(i)) * 4294967296))
end
local MD5_S = {
    7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
    5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
    4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
    6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
}

local function md5_new()
    local st = {
        a = tobit(0x67452301),
        b = tobit(0xefcdab89),
        c = tobit(0x98badcfe),
        d = tobit(0x10325476),
        buf = "",
        len = 0,
    }
    local X = {}
    local function transform(blk, off)
        for j = 0, 15 do
            local p = off + j * 4
            local b0, b1, b2, b3 = blk:byte(p, p + 3)
            X[j] = tobit(b0 + b1 * 256 + b2 * 65536 + b3 * 16777216)
        end
        local a, b, c, d = st.a, st.b, st.c, st.d
        for i = 0, 63 do
            local f, g
            if i < 16 then
                f = bor(band(b, c), band(bnot(b), d))
                g = i
            elseif i < 32 then
                f = bor(band(d, b), band(bnot(d), c))
                g = (5 * i + 1) % 16
            elseif i < 48 then
                f = bxor(b, c, d)
                g = (3 * i + 5) % 16
            else
                f = bxor(c, bor(b, bnot(d)))
                g = (7 * i) % 16
            end
            local tmp = d
            d = c
            c = b
            b = tobit(b + rol(tobit(a + f + MD5_K[i + 1] + X[g]), MD5_S[i + 1]))
            a = tmp
        end
        st.a = tobit(st.a + a)
        st.b = tobit(st.b + b)
        st.c = tobit(st.c + c)
        st.d = tobit(st.d + d)
    end
    function st:update(data)
        if not data or #data == 0 then return end
        self.len = self.len + #data
        local s = (#self.buf > 0) and (self.buf .. data) or data
        local n = #s
        local pos = 1
        while pos + 63 <= n do
            transform(s, pos)
            pos = pos + 64
        end
        self.buf = (pos <= n) and s:sub(pos) or ""
    end
    function st:final()
        local bit_len_lo = (self.len * 8) % 4294967296
        local bit_len_hi = math.floor((self.len * 8) / 4294967296)
        local pad_len = (56 - ((self.len + 1) % 64)) % 64
        local tail = "\128" .. string.rep("\0", pad_len)
            .. string.char(
                bit_len_lo % 256, math.floor(bit_len_lo / 256) % 256,
                math.floor(bit_len_lo / 65536) % 256, math.floor(bit_len_lo / 16777216) % 256,
                bit_len_hi % 256, math.floor(bit_len_hi / 256) % 256,
                math.floor(bit_len_hi / 65536) % 256, math.floor(bit_len_hi / 16777216) % 256
            )
        self:update(tail)
        local function le_hex(w)
            local u = (w < 0) and (w + 4294967296) or w
            return string.format("%02x%02x%02x%02x",
                u % 256, math.floor(u / 256) % 256,
                math.floor(u / 65536) % 256, math.floor(u / 16777216) % 256)
        end
        return le_hex(self.a) .. le_hex(self.b) .. le_hex(self.c) .. le_hex(self.d)
    end
    return st
end

local function md5_file(path)
    local f = io.open(path, "rb")
    if not f then return nil, 0 end
    local h = md5_new()
    local total = 0
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        total = total + #chunk
        h:update(chunk)
    end
    f:close()
    return h:final(), total
end

pcall(ffi.cdef, [=[
    void* InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
    void* InternetOpenUrlA(void* hInternet, const char* lpszUrl, const char* lpszHeaders, uint32_t dwHeadersLength, uint32_t dwFlags, uintptr_t dwContext);
    int32_t HttpQueryInfoA(void* hRequest, uint32_t dwInfoLevel, void* lpBuffer, uint32_t* lpdwBufferLength, uint32_t* lpdwIndex);
    int32_t InternetReadFile(void* hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
    int32_t InternetCloseHandle(void* hInternet);
    int32_t InternetSetOptionA(void* hInternet, uint32_t dwOption, void* lpBuffer, uint32_t dwBufferLength);
]=])
local ok_lib, wi = pcall(ffi.load, "wininet")
if not ok_lib or not wi then
    ch:push({ seq = seq, stage = "error", ok = false, err = "无法加载 Windows 网络组件 (wininet)" })
    return
end

local hNet = wi.InternetOpenA("KR-MP-SakuraInstaller/2.3", 0, nil, nil, 0)
if hNet == nil then
    ch:push({ seq = seq, stage = "error", ok = false, err = "初始化网络句柄失败" })
    return
end
local timeout = ffi.new("uint32_t[1]", 15000)
pcall(wi.InternetSetOptionA, hNet, 2, timeout, 4)
pcall(wi.InternetSetOptionA, hNet, 6, timeout, 4)

local FLAGS = bit.bor(0x00800000, 0x80000000, 0x04000000) -- SECURE | RELOAD | NO_CACHE_WRITE

local function http_get_text(url)
    local hUrl = wi.InternetOpenUrlA(hNet, url, "Accept: application/json\r\n", 26, FLAGS, 0)
    if hUrl == nil then return nil, 0 end
    local code = ffi.new("uint32_t[1]", 0)
    local clen = ffi.new("uint32_t[1]", 4)
    wi.HttpQueryInfoA(hUrl, 0x20000013, code, clen, nil)
    local chunks, total = {}, 0
    local buf = ffi.new("uint8_t[8192]")
    local bread = ffi.new("uint32_t[1]")
    while total < 1048576 do
        bread[0] = 0
        local r = wi.InternetReadFile(hUrl, buf, 8192, bread)
        local n = tonumber(bread[0]) or 0
        if r == 0 or n <= 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, n)
        total = total + n
    end
    wi.InternetCloseHandle(hUrl)
    return table.concat(chunks), tonumber(code[0]) or 0
end

ch:push({ seq = seq, stage = "meta", done = 0, total = 0 })

local meta_obj = nil
for _, url in ipairs({
    "https://api.natfrp.com/v4/system/clients",
    "https://natfrp-api.globalslb.net/v4/system/clients",
}) do
    local body, code = http_get_text(url)
    if body and code >= 200 and code < 300 then
        local decoded = proto.decode(body)
        if type(decoded) == "table" and type(decoded.windows) == "table" then
            meta_obj = decoded.windows
            break
        end
    end
end

if not meta_obj or type(meta_obj.archs) ~= "table" or type(meta_obj.archs.default) ~= "table" then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, stage = "error", ok = false, err = "无法获取官方最新版本信息，请检查网络或打开官网下载" })
    return
end

local arch = meta_obj.archs.default
local dl_url = tostring(arch.url or "")
local expect_md5 = tostring(arch.hash or ""):lower()
local expect_size = tonumber(arch.size) or 0
local ver = tostring(meta_obj.ver or "latest"):gsub("[^%w%.%-]", "")

local dl_host = dl_url:match("^https://([^/]+)/")
local trusted = dl_host and (dl_host == "nya.globalslb.net" or dl_host:match("%.natfrp%.com$") or dl_host:match("%.globalslb%.net$"))
if not trusted then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, stage = "error", ok = false, err = "官方下载地址校验异常，已中止下载" })
    return
end

local out_dir = (type(dest_dir) == "string" and #dest_dir > 0) and dest_dir or (os.getenv("TEMP") or ".")
out_dir = out_dir:gsub("[/\\]+$", "")
local final_path = out_dir .. "\\SakuraLauncher_v" .. ver .. "_official.exe"
local part_path = final_path .. ".part"

-- Reuse previously downloaded & verified official installer if still intact
if #expect_md5 == 32 then
    local cached_md5, cached_sz = md5_file(final_path)
    if cached_md5 and cached_md5 == expect_md5 and (expect_size <= 0 or cached_sz == expect_size) then
        wi.InternetCloseHandle(hNet)
        ch:push({ seq = seq, stage = "done", ok = true, path = final_path, ver = ver, size = cached_sz, cached = true })
        return
    end
end

local hUrl = wi.InternetOpenUrlA(hNet, dl_url, nil, 0, FLAGS, 0)
if hUrl == nil then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, stage = "error", ok = false, err = "连接官方 CDN 失败，请稍后重试或去官网下载" })
    return
end

local status_code = ffi.new("uint32_t[1]", 0)
local slen = ffi.new("uint32_t[1]", 4)
wi.HttpQueryInfoA(hUrl, 0x20000013, status_code, slen, nil)
if tonumber(status_code[0]) < 200 or tonumber(status_code[0]) >= 300 then
    wi.InternetCloseHandle(hUrl)
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, stage = "error", ok = false, err = "官方 CDN 返回 HTTP " .. tostring(status_code[0]) })
    return
end

local cl_val = ffi.new("uint32_t[1]", 0)
local cl_len = ffi.new("uint32_t[1]", 4)
local total_sz = expect_size
if wi.HttpQueryInfoA(hUrl, 0x20000005, cl_val, cl_len, nil) ~= 0 and tonumber(cl_val[0]) > 0 then
    total_sz = tonumber(cl_val[0])
end

local f, ferr = io.open(part_path, "wb")
if not f then
    wi.InternetCloseHandle(hUrl)
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, stage = "error", ok = false, err = "无法写入临时文件：" .. tostring(ferr) })
    return
end

local hasher = md5_new()
local buf = ffi.new("uint8_t[32768]")
local bread = ffi.new("uint32_t[1]")
local written = 0
local last_report = 0

ch:push({ seq = seq, stage = "downloading", done = 0, total = total_sz, ver = ver })
while true do
    bread[0] = 0
    local r = wi.InternetReadFile(hUrl, buf, 32768, bread)
    local n = tonumber(bread[0]) or 0
    if r == 0 then
        f:close()
        os.remove(part_path)
        wi.InternetCloseHandle(hUrl)
        wi.InternetCloseHandle(hNet)
        ch:push({ seq = seq, stage = "error", ok = false, err = "下载连接中断，请重试" })
        return
    end
    if n <= 0 then break end
    local chunk = ffi.string(buf, n)
    f:write(chunk)
    hasher:update(chunk)
    written = written + n
    if (written - last_report) >= 262144 then
        last_report = written
        ch:push({ seq = seq, stage = "downloading", done = written, total = total_sz, ver = ver })
    end
end
f:close()
wi.InternetCloseHandle(hUrl)
wi.InternetCloseHandle(hNet)

ch:push({ seq = seq, stage = "verifying", done = written, total = total_sz, ver = ver })
local got_md5 = hasher:final()
if written < 1048576 or (#expect_md5 == 32 and got_md5 ~= expect_md5) then
    os.remove(part_path)
    ch:push({ seq = seq, stage = "error", ok = false, err = "安装包 MD5 校验未通过，已自动删除损坏文件，请重试" })
    return
end

os.remove(final_path)
local ok_ren = os.rename(part_path, final_path)
if not ok_ren then
    ch:push({ seq = seq, stage = "error", ok = false, err = "写入安装程序失败（可能被安全软件占用）" })
    return
end

ch:push({ seq = seq, stage = "done", ok = true, path = final_path, ver = ver, size = written, md5 = got_md5 })
]===]

return M
