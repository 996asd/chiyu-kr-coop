-- KR-MP SakuraFrp Background Worker Threads & Log Parsers (Isolated from 60Hz Sim)
-- Contains three self-contained love.thread worker scripts + pure log diagnostic helpers:
--   1. PROBE_WORKER_CODE     : Concurrent 3-line TCP latency probe (Default / dx. / yd.)
--   2. API_WORKER_CODE       : Opt-in Official OpenAPI v4 client (WinINet / LuaHTTPS)
--   3. INSTALLER_WORKER_CODE : Official SakuraLauncher.exe & standalone frpc downloader (progress + RFC-1321 MD5)
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
local ch_name, seq, dest_dir, pkg_path, dl_kind, arch_pref = ...
dl_kind = (dl_kind == "frpc") and "frpc" or "launcher"
if type(pkg_path) == "string" and #pkg_path > 0 then
    package.path = pkg_path
end
local ch = love.thread.getChannel(ch_name)
local ok_p, proto = pcall(require, "kr_mp.proto")
local ok_ffi, ffi = pcall(require, "ffi")
local ok_bit, bit = pcall(require, "bit")
if not ok_p or not proto or not ok_ffi or not ffi or ffi.os ~= "Windows" or not ok_bit then
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "仅支持 PC Windows 自动下载官方樱花组件" })
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

ch:push({ seq = seq, kind = dl_kind, stage = "meta", done = 0, total = 0 })

local meta_obj = nil
local root_key = (dl_kind == "frpc") and "frpc" or "windows"
for _, url in ipairs({
    "https://api.natfrp.com/v4/system/clients",
    "https://natfrp-api.globalslb.net/v4/system/clients",
}) do
    local body, code = http_get_text(url)
    if body and code >= 200 and code < 300 then
        local decoded = proto.decode(body)
        if type(decoded) == "table" and type(decoded[root_key]) == "table" then
            meta_obj = decoded[root_key]
            break
        end
    end
end

local arch = nil
if meta_obj and type(meta_obj.archs) == "table" then
    if dl_kind == "frpc" then
        local pref = (type(arch_pref) == "string" and #arch_pref > 0) and arch_pref or "windows_amd64"
        arch = meta_obj.archs[pref] or meta_obj.archs.windows_amd64 or meta_obj.archs.windows_386
    else
        arch = meta_obj.archs.default
    end
end

if type(arch) ~= "table" then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "无法获取官方最新版本信息，请检查网络或改用官方樱花启动器" })
    return
end

local dl_url = tostring(arch.url or "")
local expect_md5 = tostring(arch.hash or ""):lower()
local expect_size = tonumber(arch.size) or 0
local ver = tostring(meta_obj.ver or "latest"):gsub("[^%w%.%-]", "")

local dl_host = dl_url:match("^https://([^/]+)/")
local trusted = dl_host and (dl_host == "nya.globalslb.net" or dl_host:match("%.natfrp%.com$") or dl_host:match("%.globalslb%.net$"))
if not trusted then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "官方下载地址校验异常，已中止下载" })
    return
end

local out_dir = (type(dest_dir) == "string" and #dest_dir > 0) and dest_dir or (os.getenv("TEMP") or ".")
out_dir = out_dir:gsub("[/\\]+$", "")
local final_path = (dl_kind == "frpc")
    and (out_dir .. "\\sakura_frpc.exe")
    or (out_dir .. "\\SakuraLauncher_v" .. ver .. "_official.exe")
local part_path = final_path .. ".part"

-- Reuse previously downloaded & verified official binary if still intact
if #expect_md5 == 32 then
    local cached_md5, cached_sz = md5_file(final_path)
    if cached_md5 and cached_md5 == expect_md5 and (expect_size <= 0 or cached_sz == expect_size) then
        wi.InternetCloseHandle(hNet)
        ch:push({ seq = seq, kind = dl_kind, stage = "done", ok = true, path = final_path, ver = ver, size = cached_sz, cached = true })
        return
    end
end

local hUrl = wi.InternetOpenUrlA(hNet, dl_url, nil, 0, FLAGS, 0)
if hUrl == nil then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "连接官方 CDN 失败，请稍后重试或改用官方樱花启动器" })
    return
end

local status_code = ffi.new("uint32_t[1]", 0)
local slen = ffi.new("uint32_t[1]", 4)
wi.HttpQueryInfoA(hUrl, 0x20000013, status_code, slen, nil)
if tonumber(status_code[0]) < 200 or tonumber(status_code[0]) >= 300 then
    wi.InternetCloseHandle(hUrl)
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "官方 CDN 返回 HTTP " .. tostring(status_code[0]) })
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
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "无法写入临时文件：" .. tostring(ferr) })
    return
end

local hasher = md5_new()
local buf = ffi.new("uint8_t[32768]")
local bread = ffi.new("uint32_t[1]")
local written = 0
local last_report = 0
local first2 = ""

ch:push({ seq = seq, kind = dl_kind, stage = "downloading", done = 0, total = total_sz, ver = ver })
while true do
    bread[0] = 0
    local r = wi.InternetReadFile(hUrl, buf, 32768, bread)
    local n = tonumber(bread[0]) or 0
    if r == 0 then
        f:close()
        os.remove(part_path)
        wi.InternetCloseHandle(hUrl)
        wi.InternetCloseHandle(hNet)
        ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "下载连接中断，请重试" })
        return
    end
    if n <= 0 then break end
    local chunk = ffi.string(buf, n)
    if #first2 < 2 then first2 = (first2 .. chunk):sub(1, 2) end
    f:write(chunk)
    hasher:update(chunk)
    written = written + n
    if (written - last_report) >= 262144 then
        last_report = written
        ch:push({ seq = seq, kind = dl_kind, stage = "downloading", done = written, total = total_sz, ver = ver })
    end
end
f:close()
wi.InternetCloseHandle(hUrl)
wi.InternetCloseHandle(hNet)

ch:push({ seq = seq, kind = dl_kind, stage = "verifying", done = written, total = total_sz, ver = ver })
local got_md5 = hasher:final()
if written < 1048576 or first2 ~= "MZ" or (#expect_md5 == 32 and got_md5 ~= expect_md5) then
    os.remove(part_path)
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "官方文件 MD5 校验未通过，已自动删除损坏文件，请重试" })
    return
end

os.remove(final_path)
local ok_ren = os.rename(part_path, final_path)
if not ok_ren then
    ch:push({ seq = seq, kind = dl_kind, stage = "error", ok = false, err = "写入官方程序失败（可能被安全软件占用或拦截）" })
    return
end

ch:push({ seq = seq, kind = dl_kind, stage = "done", ok = true, path = final_path, ver = ver, size = written, md5 = got_md5 })
]===]

-- === Pure Address, OpenAPI Parsing & Log Diagnostic Helpers (Zero Side Effects) ===

function M.mask_addr(proto, addr)
    if type(addr) ~= "string" or #addr == 0 then return "" end
    local p1, p2 = proto.split_fallback_addr(addr)
    local function mask_one(s)
        local host, port = s:match("^([^:]+):(%d+)$")
        if not host then host = s end
        local mh
        if host:match("^%d+%.%d+%.%d+%.%d+$") then
            local a, d = host:match("^(%d+)%.%d+%.%d+%.(%d+)$")
            mh = a and (a .. ".*.*." .. d) or "***.***"
        else
            local head, tail = host:match("^([^%.]+).*%.([^%.]+%.[^%.]+)$")
            if head and tail then
                mh = head:sub(1, 3) .. "***." .. tail
            else
                local h2, t2 = host:match("^([^%.]+)%.([^%.]+)$")
                mh = (h2 and t2) and (h2:sub(1, 4) .. "***." .. t2) or (host:sub(1, 3) .. "***")
            end
        end
        return port and (mh .. ":*****") or mh
    end
    if p2 then
        return mask_one(p1) .. "|" .. mask_one(p2)
    end
    return mask_one(p1 or addr)
end

function M.parse_export_field(exp_str)
    if type(exp_str) ~= "string" or #exp_str < 5 then return nil end
    local _, ip_raw, port_raw = exp_str:match("^([^|]+)|([^|]+)|(%d+)$")
    local port = tonumber(port_raw)
    if not ip_raw or not port or port <= 0 or port > 65535 then return nil end
    local ip_str = nil
    if ip_raw:match("^%d+%.%d+%.%d+%.%d+$") then
        ip_str = ip_raw
    elseif ip_raw:match("^%d+$") then
        local n = tonumber(ip_raw)
        if n and n > 0 and n <= 4294967295 then
            local b1 = math.floor(n / 16777216) % 256
            local b2 = math.floor(n / 65536) % 256
            local b3 = math.floor(n / 256) % 256
            local b4 = n % 256
            ip_str = string.format("%d.%d.%d.%d", b1, b2, b3, b4)
        end
    end
    if not ip_str or ip_str == "0.0.0.0" or ip_str:match("^127%.") then return nil end
    return ip_str .. ":" .. tostring(math.floor(port))
end

function M.parse_api_refresh(res, default_tcp_port)
    local u = res.user or {}
    local grp = type(u.group) == "table" and u.group or {}
    local tr = type(u.traffic) == "table" and u.traffic or {}
    local used_b = tonumber(tr[1]) or 0
    local rem_b = tonumber(tr[2]) or 0
    local user_info = {
        id = tonumber(u.id) or 0,
        name = tostring(u.name or "SakuraUser"),
        group_name = tostring(grp.name or "免费用户"),
        group_level = tonumber(grp.level) or 0,
        speed = tostring(u.speed or "10 Mbps"),
        tunnels_max = tonumber(u.tunnels) or 2,
        realname = tonumber(u.realname) or 0,
        used_today_mib = math.floor(used_b / 1048576 + 0.5),
        remain_gib = math.floor((rem_b / 1073741824) * 10 + 0.5) / 10,
    }

    local bit = require("bit")
    local stats_by_id = {}
    if type(res.stats) == "table" and type(res.stats.nodes) == "table" then
        for _, ns in ipairs(res.stats.nodes) do
            if tonumber(ns.id) then stats_by_id[tonumber(ns.id)] = ns end
        end
    end

    local nodes_by_id, rec = {}, {}
    if type(res.nodes) == "table" then
        for id_k, nd in pairs(res.nodes) do
            local nid = tonumber(id_k) or tonumber(nd.id)
            if nid and type(nd) == "table" and nd.host then
                local fl = tonumber(nd.flag) or 0
                local name = tostring(nd.name or ("节点#" .. nid))
                local st = stats_by_id[nid] or {}
                local online = (st.online == nil) or (tonumber(st.online) >= 0)
                local load_pct = tonumber(st.load) or 50
                local allow_create = (bit.band(fl, 4) ~= 0)
                local is_mainland = (bit.band(fl, 8) ~= 0)
                local is_public_ok = (bit.band(fl, 2048) ~= 0) or (name:find("多线", 1, true) ~= nil)
                local entry = {
                    id = nid, name = name, host = tostring(nd.host),
                    vip = tonumber(nd.vip) or 0, flag = fl, online = online, load = load_pct,
                    allow_create = allow_create, is_mainland = is_mainland, is_public_ok = is_public_ok,
                }
                nodes_by_id[nid] = entry
                if online and allow_create and entry.vip <= user_info.group_level then
                    rec[#rec + 1] = entry
                end
            end
        end
    end

    local tlist = {}
    if type(res.tunnels) == "table" then
        for _, t in ipairs(res.tunnels) do
            if type(t) == "table" and (t.type == "tcp" or t.type == "etcp") then
                local nd = nodes_by_id[tonumber(t.node)]
                local host = nd and nd.host or nil
                local remote_s = tostring(t.remote or "")
                local addr = (host and remote_s:match("^%d+$")) and (host .. ":" .. remote_s) or nil
                tlist[#tlist + 1] = {
                    id = tonumber(t.id) or 0,
                    name = tostring(t.name or "tunnel"),
                    type = tostring(t.type),
                    node = tonumber(t.node) or 0,
                    node_name = nd and nd.name or ("节点#" .. tostring(t.node)),
                    local_ip = tostring(t.local_ip or "127.0.0.1"),
                    local_port = tonumber(t.local_port) or 0,
                    remote = remote_s,
                    online = (t.online == true),
                    addr = addr,
                    p2p_addr = M.parse_export_field(t.export),
                    is_krmp = (tonumber(t.local_port) == default_tcp_port),
                }
            end
        end
    end
    table.sort(tlist, function(a, b)
        if a.is_krmp ~= b.is_krmp then return a.is_krmp end
        if a.online ~= b.online then return a.online end
        return a.id < b.id
    end)
    return user_info, rec, tlist
end

function M.parse_log_timestamp(line)
    local y, mo, d, h, mi, s = line:match("(%d%d%d%d)[/%-](%d%d)[/%-](%d%d)%s+(%d%d):(%d%d):(%d%d)")
    if not y then return 0 end
    local ok, ts = pcall(os.time, {
        year = tonumber(y), month = tonumber(mo), day = tonumber(d),
        hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    })
    return (ok and tonumber(ts)) or 0
end

function M.parse_sakura_log_tail(text, default_name)
    local tunnels = {}
    local line_no = 0
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        line_no = line_no + 1
        local tname = line:match("frpc%[([^|%]]+)|") or line:match("Tunnel/([^%s]+)") or default_name
        if tname then
            if not tunnels[tname] then
                tunnels[tname] = {
                    name = tname, alive = false, is_http = false,
                    addr = nil, p2p = nil, speed = nil, last_seen = 0,
                    warn_msg = nil, warn_kind = nil, warn_ts = 0,
                }
            end
            local t = tunnels[tname]
            t.last_seen = line_no
            if line:find("frpc 已退出", 1, true) or line:find("frpc 异常退出", 1, true) or line:find("已关闭该隧道", 1, true) then
                t.alive = false
            end
            if line:find("自动 HTTPS 已被禁用", 1, true) then
                t.is_http = false
            elseif line:find("自动 HTTPS", 1, true) or line:find("加载证书", 1, true) or line:find("生成自签证书", 1, true) then
                t.is_http = true
            end
            if line:find("TCP 隧道启动成功", 1, true) or line:find("隧道启动成功", 1, true) then
                t.alive = true
            end
            local spd = line:match("限速已更新:%s*([%w%./%s]+)")
            if spd then t.speed = spd:gsub("%s+$", "") end
            local addr = line:match(">>([%w%-]+%.[%w%.%-]+:%d+)<<")
            if addr then
                t.addr = addr
                t.alive = true
            end
            if line:find("端口导出", 1, true) or line:find("NAT 开放", 1, true) then
                local p2p = line:match("(%d+%.%d+%.%d+%.%d+:%d+)")
                if p2p and not p2p:match("^127%.") then t.p2p = p2p end
            end
            if line:find("连接映射目标", 1, true) and line:find("失败", 1, true) then
                t.warn_msg = "樱花日志提示：隧道无法连上本机游戏端口，请检查隧道本地端口是否设为 17777"
                t.warn_kind = "local_refused"
                t.warn_ts = M.parse_log_timestamp(line)
            elseif line:find("无权使用该节点", 1, true) then
                t.warn_msg = "樱花日志提示：当前节点 VIP 已到期或无权使用，请更换免费/多线节点"
                t.warn_kind = "vip_denied"
                t.warn_ts = M.parse_log_timestamp(line)
            elseif line:find("网络波动导致数据连接断开", 1, true) then
                t.warn_msg = "樱花节点近期有波动（联机中已自动受 180 秒热续传保护）"
                t.warn_kind = "net_jitter"
                t.warn_ts = M.parse_log_timestamp(line)
            end
        end
    end

    local best_non_http, best_any = nil, nil
    for _, t in pairs(tunnels) do
        if t.alive and t.addr then
            if not best_any or t.last_seen > best_any.last_seen then
                best_any = t
            end
            if not t.is_http and (not best_non_http or t.last_seen > best_non_http.last_seen) then
                best_non_http = t
            end
        end
    end
    local picked = best_non_http or best_any
    if picked and picked.warn_msg then
        return picked, picked.warn_msg, picked.warn_kind, picked.warn_ts
    end
    return picked, nil, nil, 0
end

function M.diagnose_frpc_log(text)
    local raw = tostring(text or "")
    if #raw == 0 then
        return "独立版 frpc 提前退出（可能被安全软件拦截或缺少网络权限）"
    end
    if raw:find("访问密钥无效", 1, true) or raw:find("[401]", 1, true) then
        return "访问密钥无效，请重新粘贴樱花访问密钥"
    elseif raw:find("实名", 1, true) then
        return "账号尚未完成实名认证，请先去樱花官网完成实名"
    elseif raw:find("无权使用", 1, true) or raw:find("VIP", 1, true) then
        return "当前节点无权使用或已满载，请更换其他低负载节点"
    elseif raw:find("already exists", 1, true) or raw:find("已被占用", 1, true)
        or raw:find("已在运行", 1, true) or raw:find("重复启动", 1, true) then
        return "该隧道已在官方启动器或其他进程中运行，请勿重复启动"
    elseif raw:find("SakuraFrp Launcher", 1, true) or raw:find("SakuraFrp Service", 1, true) then
        return "检测到了官方启动器内置专用版 frpc，请改用独立版或官方樱花启动"
    elseif raw:find("i/o timeout", 1, true) or raw:find("connectex", 1, true)
        or raw:find("proxyconnect", 1, true) or raw:find("EOF", 1, true) then
        return "无法连接樱花节点（可能受代理/VPN 或防火墙干扰）"
    end
    local last_line = nil
    for line in raw:gmatch("[^\r\n]+") do
        local s = line:gsub("^%s+", ""):gsub("%s+$", "")
        if #s > 0 then last_line = s end
    end
    if last_line then
        last_line = last_line:gsub("^%d%d%d%d/%d%d/%d%d%s+%d%d:%d%d:%d%d%s+[%w/]+%s*", "")
        if #last_line > 72 then last_line = last_line:sub(1, 72) .. "..." end
        return last_line
    end
    return "独立版 frpc 异常退出"
end

return M
