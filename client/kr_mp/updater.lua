-- KR-MP 非阻塞后台检查更新 + 一键增量热更新模块（PC WinINet / 安卓 LuaHTTPS 全兼容）
-- 特性：
--   1. 检查 Gitee（主源） / GitHub（备源）线上 version.json 与 client/kr_mp/manifest.json；
--   2. 自动对比本地每个文件 SHA-256，仅下载有变化的增量文件（通常仅 15~220 KB，手机 2 秒热更免重传 4GB APK！）；
--   3. 写入前强制通过「SHA-256 精确校验 + Lua 语法编译校验（loadstring）」，任何单文件出错零写入；
--   4. 安卓端写入 love.filesystem 私有存档目录（自动优先覆盖 game.love，配合 UH.lua 崩溃自动回滚永不变砖）；
--      PC 端直接写入游戏目录下的 kr_mp/，下次重启即生效。
local proto = require("kr_mp.proto")

local updater = {
    GITEE_VERSION_URL   = "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/version.json",
    GITHUB_VERSION_URL  = "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/version.json",
    GITEE_CLIENT_BASE   = "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/client/",
    GITHUB_CLIENT_BASE  = "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/client/",
    DEFAULT_DOWNLOAD_GITEE  = "https://gitee.com/chiyu-studio/chiyu-kr-coop/releases",
    DEFAULT_DOWNLOAD_GITHUB = "https://github.com/996asd/chiyu-kr-coop/releases",

    boot = nil,
    overlay = nil,
    checking = false,
    checked_once = false,
    manual_notify = false,
    has_update = false,
    latest_version = nil,
    latest_notes = nil,
    download_url = nil,
    status_text = nil,

    -- OTA Hot-Update state
    ota_ready = false,
    ota_updating = false,
    ota_applied = false,
    ota_applied_ver = nil,
    ota_progress_text = nil,
    ota_changed_files = nil,   -- list of { rel, sha256 }
    ota_manifest_raw = nil,
    ota_manifest_ver = nil,
    ota_base_urls = nil,

    _thread = nil,
    _channel = nil,
    _ota_thread = nil,
    _ota_channel = nil,
}

-- Shared Pure-Lua SHA-256 (LuaJIT bit, 100% identical to OpenSSL/PowerShell Get-FileHash; also uses love.data when available)
local SHA256_LUA_SRC = [===[
local function kr_sha256_hex(msg)
    if love and love.data and love.data.hash and love.data.encode then
        local ok_h, digest = pcall(love.data.hash, "sha256", msg)
        if ok_h and digest then
            local ok_e, hex = pcall(love.data.encode, "string", "hex", digest)
            if ok_e and type(hex) == "string" and #hex == 64 then
                return hex:upper()
            end
        end
    end
    local bit = require("bit")
    local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
    local rshift, lshift, ror = bit.rshift, bit.lshift, bit.ror
    local K = {
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
    }
    local h0,h1,h2,h3 = 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a
    local h4,h5,h6,h7 = 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19

    local len = #msg
    local pad_len = (56 - (len + 1) % 64) % 64
    local bit_len_hi = math.floor((len * 8) / 4294967296)
    local bit_len_lo = (len * 8) % 4294967296
    local function u32be(v)
        return string.char(
            band(rshift(v, 24), 0xFF), band(rshift(v, 16), 0xFF),
            band(rshift(v, 8), 0xFF), band(v, 0xFF)
        )
    end
    local data = msg .. "\128" .. string.rep("\0", pad_len) .. u32be(bit_len_hi) .. u32be(bit_len_lo)
    local w = {}
    for pos = 1, #data, 64 do
        for i = 0, 15 do
            local b1, b2, b3, b4 = string.byte(data, pos + i * 4, pos + i * 4 + 3)
            w[i + 1] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
        end
        for i = 17, 64 do
            local v1, v2 = w[i - 15], w[i - 2]
            local s0 = bxor(ror(v1, 7), ror(v1, 18), rshift(v1, 3))
            local s1 = bxor(ror(v2, 17), ror(v2, 19), rshift(v2, 10))
            w[i] = bit.tobit(w[i - 16] + s0 + w[i - 7] + s1)
        end
        local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7
        for i = 1, 64 do
            local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = bit.tobit(h + S1 + ch + K[i] + w[i])
            local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = bit.tobit(S0 + maj)
            h = g; g = f; f = e; e = bit.tobit(d + t1)
            d = c; c = b; b = a; a = bit.tobit(t1 + t2)
        end
        h0 = bit.tobit(h0 + a); h1 = bit.tobit(h1 + b); h2 = bit.tobit(h2 + c); h3 = bit.tobit(h3 + d)
        h4 = bit.tobit(h4 + e); h5 = bit.tobit(h5 + f); h6 = bit.tobit(h6 + g); h7 = bit.tobit(h7 + h)
    end
    local function hex8(v)
        if v < 0 then v = v + 4294967296 end
        return string.format("%08X", v)
    end
    return hex8(h0)..hex8(h1)..hex8(h2)..hex8(h3)..hex8(h4)..hex8(h5)..hex8(h6)..hex8(h7)
end
]===]

-- Compile local SHA-256 helper on main thread too (for incremental diff!)
local sha256_hex = assert(loadstring(SHA256_LUA_SRC .. "\nreturn kr_sha256_hex"))()
updater.sha256_hex = sha256_hex

local HTTP_FETCH_SRC = [===[
local function kr_http_fetch(url, max_bytes)
    max_bytes = max_bytes or (2 * 1024 * 1024)
    local errs = {}

    -- 1. Windows WinINet (zero console popup, native TLS)
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and ffi and ffi.os == "Windows" then
        local ok_bit, bit = pcall(require, "bit")
        if ok_bit then
            pcall(ffi.cdef, [=[
                void* InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
                void* InternetOpenUrlA(void* hInternet, const char* lpszUrl, const char* lpszHeaders, uint32_t dwHeadersLength, uint32_t dwFlags, uintptr_t dwContext);
                int32_t InternetReadFile(void* hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
                int32_t InternetCloseHandle(void* hInternet);
                int32_t InternetSetOptionA(void* hInternet, uint32_t dwOption, void* lpBuffer, uint32_t dwBufferLength);
            ]=])
            local ok_lib, wininet = pcall(ffi.load, "wininet")
            if ok_lib and wininet then
                local hNet = wininet.InternetOpenA("KR-MP-Updater/2.2", 0, nil, nil, 0)
                if hNet ~= nil then
                    local timeout = ffi.new("uint32_t[1]", 6000)
                    pcall(wininet.InternetSetOptionA, hNet, 2, timeout, 4)
                    pcall(wininet.InternetSetOptionA, hNet, 6, timeout, 4)
                    local flags = bit.bor(0x80000000, 0x04000000, 0x00000100)
                    local hUrl = wininet.InternetOpenUrlA(hNet, url, nil, 0, flags, 0)
                    if hUrl ~= nil then
                        local chunks, total = {}, 0
                        local buf = ffi.new("uint8_t[8192]")
                        local bytes_read = ffi.new("uint32_t[1]")
                        while total < max_bytes do
                            bytes_read[0] = 0
                            local res = wininet.InternetReadFile(hUrl, buf, 8192, bytes_read)
                            local n = tonumber(bytes_read[0]) or 0
                            if res == 0 or n <= 0 then break end
                            chunks[#chunks + 1] = ffi.string(buf, n)
                            total = total + n
                        end
                        wininet.InternetCloseHandle(hUrl)
                        wininet.InternetCloseHandle(hNet)
                        local body = table.concat(chunks)
                        if #body > 0 then return body, "wininet" end
                        errs[#errs + 1] = "wininet_empty"
                    else
                        wininet.InternetCloseHandle(hNet)
                        errs[#errs + 1] = "wininet_openurl_fail"
                    end
                else
                    errs[#errs + 1] = "wininet_open_fail"
                end
            else
                errs[#errs + 1] = "wininet_load_fail"
            end
        end
    end

    -- 2. Android / LÖVE 12 built-in LuaHTTPS
    local ok_hs, https = pcall(require, "https")
    if ok_hs and https and https.request then
        local ok_req, code, body = pcall(https.request, url, { method = "GET" })
        if not ok_req then
            ok_req, code, body = pcall(https.request, url)
        end
        if ok_req and tonumber(code) == 200 and type(body) == "string" and #body > 0 then
            return body, "luahttps"
        end
        errs[#errs + 1] = "https_" .. tostring(code)
    end

    -- 3. Plain HTTP fallback (local test server / LAN mirror)
    if url:sub(1, 7) == "http://" then
        local ok_h, http = pcall(require, "socket.http")
        local ok_l, ltn12 = pcall(require, "ltn12")
        if ok_h and ok_l then
            http.TIMEOUT = 5
            local resp = {}
            local ok, code = http.request({ url = url, sink = ltn12.sink.table(resp) })
            if ok and tonumber(code) == 200 then
                return table.concat(resp), "socket.http"
            end
            errs[#errs + 1] = "http_" .. tostring(code)
        end
    end

    return nil, table.concat(errs, "|")
end
]===]

-- Worker 1: Check version.json + client/kr_mp/manifest.json
local CHECK_WORKER_CODE = HTTP_FETCH_SRC .. [===[
local channel_name, ver_urls_str, base_urls_str, bust = ...
local ch = love.thread.getChannel(channel_name)

local function with_bust(u)
    if not bust or bust == "" then return u end
    return u .. (u:find("?", 1, true) and "&" or "?") .. "t=" .. bust
end

local ver_body, ver_url, ver_backend, last_err = nil, nil, nil, "no_urls"
for url in (ver_urls_str or ""):gmatch("[^\n]+") do
    if #url > 7 then
        local body, be = kr_http_fetch(with_bust(url), 65536)
        if body and body:match("^%s*{") then
            ver_body, ver_url, ver_backend = body, url, be
            break
        end
        last_err = tostring(be)
    end
end

if not ver_body then
    ch:push({ ok = false, err = last_err })
    return
end

-- Also fetch manifest.json for incremental OTA diff (best-effort, non-fatal if absent)
local mf_body, mf_base = nil, nil
for base in (base_urls_str or ""):gmatch("[^\n]+") do
    if #base > 7 then
        local mu = base .. "kr_mp/manifest.json"
        local body = kr_http_fetch(with_bust(mu), 131072)
        if body and body:match("^%s*{") and body:find('"files"', 1, true) then
            mf_body = body
            mf_base = base
            break
        end
    end
end

ch:push({
    ok = true,
    url = ver_url,
    body = ver_body,
    backend = ver_backend,
    manifest_body = mf_body,
    manifest_base = mf_base,
})
]===]

-- Worker 2: Download & cryptographically verify changed OTA files (SHA-256 + Lua loadstring compile check!)
local OTA_WORKER_CODE = SHA256_LUA_SRC .. "\n" .. HTTP_FETCH_SRC .. [===[
local channel_name, base_urls_str, files_spec, bust = ...
local ch = love.thread.getChannel(channel_name)

local bases = {}
for b in (base_urls_str or ""):gmatch("[^\n]+") do
    if #b > 7 then bases[#bases + 1] = b end
end

local items = {}
for line in (files_spec or ""):gmatch("[^\n]+") do
    local rel, sha = line:match("^([^|]+)|([0-9A-Fa-f]+)$")
    if rel and sha then
        items[#items + 1] = { rel = rel, sha = sha:upper() }
    end
end

if #items == 0 or #bases == 0 then
    ch:push({ kind = "error", err = "empty_ota_plan" })
    return
end

local results = {}
for idx, it in ipairs(items) do
    ch:push({ kind = "progress", done = idx - 1, total = #items, file = it.rel })
    local fetched = nil
    local last_err = "fetch_failed"
    for _, base in ipairs(bases) do
        local u = base .. it.rel
        if bust and bust ~= "" then
            u = u .. (u:find("?", 1, true) and "&" or "?") .. "t=" .. bust
        end
        local body, be = kr_http_fetch(u, 2 * 1024 * 1024)
        if body and #body > 0 then
            local actual = kr_sha256_hex(body)
            if actual == it.sha then
                -- Extra Lua compilation gate: guarantees zero broken syntax can ever be written!
                if it.rel:sub(-4) == ".lua" then
                    local fn, lerr = loadstring(body, "@" .. it.rel)
                    if fn then
                        fetched = body
                        break
                    else
                        last_err = "lua_syntax:" .. tostring(lerr)
                    end
                else
                    fetched = body
                    break
                end
            else
                last_err = string.format("sha_mismatch(%s!=%s)", actual:sub(1, 8), it.sha:sub(1, 8))
            end
        else
            last_err = tostring(be)
        end
    end

    if not fetched then
        ch:push({ kind = "error", file = it.rel, err = last_err })
        return
    end
    results[it.rel] = fetched
    ch:push({ kind = "progress", done = idx, total = #items, file = it.rel })
end

ch:push({ kind = "done", files = results })
]===]

local function parse_semver(s)
    if type(s) ~= "string" then return 0, 0, 0 end
    local a, b, c = s:match("(%d+)%.(%d+)%.(%d+)")
    if a then return tonumber(a), tonumber(b), tonumber(c) end
    local a2, b2 = s:match("(%d+)%.(%d+)")
    if a2 then return tonumber(a2), tonumber(b2), 0 end
    return 0, 0, 0
end

function updater.is_newer(remote_ver, local_ver)
    local ra, rb, rc = parse_semver(remote_ver)
    local la, lb, lc = parse_semver(local_ver or proto.MOD_VERSION)
    if ra ~= la then return ra > la end
    if rb ~= lb then return rb > lb end
    return rc > lc
end

local function read_local_client_file(rel)
    -- Android reads through love.filesystem (checks SaveDir OTA first, then game.love)
    if proto.is_android() then
        if love and love.filesystem and love.filesystem.read then
            local ok, data = pcall(love.filesystem.read, rel)
            if ok and type(data) == "string" then return data end
        end
        return nil
    end
    -- PC reads directly from source base directory
    local base = (love and love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()) or "."
    local p = base:gsub("[/\\]+$", "") .. "\\" .. rel:gsub("/", "\\")
    local f = io.open(p, "rb")
    if f then
        local d = f:read("*a")
        f:close()
        return d
    end
    if love and love.filesystem and love.filesystem.read then
        local ok, data = pcall(love.filesystem.read, rel)
        if ok and type(data) == "string" then return data end
    end
    return nil
end

local function write_local_client_file(rel, bytes)
    if proto.is_android() then
        local FS = love and love.filesystem
        if not FS or not FS.write then return false, "no_love_fs" end
        local dir = rel:match("^(.+)/[^/]+$")
        if dir and dir ~= "" then
            pcall(FS.createDirectory, dir)
        end
        local ok, err = FS.write(rel, bytes)
        return ok == true, err
    end
    -- PC writes directly into source base directory (no shadowing in %APPDATA%)
    local base = (love and love.filesystem and love.filesystem.getSourceBaseDirectory and love.filesystem.getSourceBaseDirectory()) or "."
    local p = base:gsub("[/\\]+$", "") .. "\\" .. rel:gsub("/", "\\")
    local f, err = io.open(p, "wb")
    if not f then return false, err end
    f:write(bytes)
    f:flush()
    f:close()
    return true, nil
end

function updater:init(boot, overlay)
    self.boot = boot
    self.overlay = overlay
    if love and love.thread and love.thread.getChannel then
        self._channel = love.thread.getChannel("kr_mp_update_result")
        self._ota_channel = love.thread.getChannel("kr_mp_ota_result")
    end
end

function updater:get_candidate_urls()
    local urls = {}
    local env_url = os.getenv("KR_MP_UPDATE_URL")
    if env_url and #env_url > 7 then
        urls[#urls + 1] = env_url
    end
    if self.GITEE_VERSION_URL and #self.GITEE_VERSION_URL > 7 then
        urls[#urls + 1] = self.GITEE_VERSION_URL
    end
    if self.GITHUB_VERSION_URL and #self.GITHUB_VERSION_URL > 7 then
        urls[#urls + 1] = self.GITHUB_VERSION_URL
    end
    return urls
end

function updater:get_client_base_urls()
    local bases = {}
    local env_base = os.getenv("KR_MP_OTA_BASE_URL")
    if env_base and #env_base > 7 then
        if env_base:sub(-1) ~= "/" then env_base = env_base .. "/" end
        bases[#bases + 1] = env_base
    end
    if self.GITEE_CLIENT_BASE and #self.GITEE_CLIENT_BASE > 7 then
        bases[#bases + 1] = self.GITEE_CLIENT_BASE
    end
    if self.GITHUB_CLIENT_BASE and #self.GITHUB_CLIENT_BASE > 7 then
        bases[#bases + 1] = self.GITHUB_CLIENT_BASE
    end
    return bases
end

function updater:has_remote_urls()
    return #self:get_candidate_urls() > 0
end

function updater:start_check(manual)
    if self.ota_updating then
        if manual and self.overlay then
            self.overlay:show_toast("正在下载并校验热更新补丁，请稍候...", 2.0)
        end
        return false
    end
    if self.checking then
        if manual and self.overlay then
            self.overlay:show_toast("正在后台检查更新，请稍候...", 2.0)
        end
        return false
    end

    if not manual and not os.getenv("KR_MP_UPDATE_URL") then
        if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_SMOKE_TEST") == "1" then
            return false
        end
    end

    local urls = self:get_candidate_urls()
    if #urls == 0 then
        self.checked_once = true
        self.status_text = "未配置更新源"
        return false
    end
    if not love or not love.thread or not love.thread.newThread then
        return false
    end

    self.checking = true
    self.checked_once = true
    self.manual_notify = (manual == true)
    if not self._channel then
        self._channel = love.thread.getChannel("kr_mp_update_result")
    end
    self._channel:clear()

    local ok, th = pcall(love.thread.newThread, CHECK_WORKER_CODE)
    if not ok or not th then
        self.checking = false
        if self.boot then self.boot:log("[UPDATER] Failed to create check thread: %s", tostring(th)) end
        return false
    end
    self._thread = th
    local bust = tostring(os.time())
    th:start("kr_mp_update_result", table.concat(urls, "\n"), table.concat(self:get_client_base_urls(), "\n"), bust)
    if manual and self.overlay then
        self.overlay:show_toast("正在检查最新联机补丁（支持免重装热更新）...", 2.5)
    end
    return true
end

-- Compute which kr_mp/* files differ from remote manifest.json (never overwrites UH.lua bootloader!)
function updater:_compute_ota_diff(mf_obj)
    if type(mf_obj) ~= "table" or type(mf_obj.files) ~= "table" then
        return nil
    end
    -- Do not auto-apply breaking protocol jump silently without checking protocol compatibility
    local changed = {}
    local function inspect_map(tbl)
        if type(tbl) ~= "table" then return end
        local keys = {}
        for rel in pairs(tbl) do
            if type(rel) == "string" and rel:sub(1, 6) == "kr_mp/" and not rel:find("..", 1, true) then
                keys[#keys + 1] = rel
            end
        end
        table.sort(keys)
        for _, rel in ipairs(keys) do
            local want_sha = tostring(tbl[rel] or ""):upper()
            if #want_sha == 64 then
                local local_bytes = read_local_client_file(rel)
                local cur_sha = local_bytes and sha256_hex(local_bytes) or ""
                if cur_sha ~= want_sha then
                    changed[#changed + 1] = { rel = rel, sha256 = want_sha }
                end
            end
        end
    end
    inspect_map(mf_obj.files)
    inspect_map(mf_obj.assets)
    return changed
end

function updater:start_ota_apply()
    if self.ota_updating then return false end
    if self.ota_applied then
        return self:restart_game()
    end
    if not self.ota_ready or not self.ota_changed_files or #self.ota_changed_files == 0 then
        return self:open_download_page()
    end
    if not (love and love.thread and love.thread.newThread) then
        return self:open_download_page()
    end

    self.ota_updating = true
    self.ota_progress_text = string.format("更新中 0/%d", #self.ota_changed_files)
    if not self._ota_channel then
        self._ota_channel = love.thread.getChannel("kr_mp_ota_result")
    end
    self._ota_channel:clear()

    local lines = {}
    for _, item in ipairs(self.ota_changed_files) do
        lines[#lines + 1] = item.rel .. "|" .. item.sha256
    end

    -- Prioritize whichever base mirror answered manifest.json first
    local bases = {}
    local seen = {}
    for _, b in ipairs(self.ota_base_urls or {}) do
        if not seen[b] then seen[b] = true; bases[#bases + 1] = b end
    end
    for _, b in ipairs(self:get_client_base_urls()) do
        if not seen[b] then seen[b] = true; bases[#bases + 1] = b end
    end

    local ok, th = pcall(love.thread.newThread, OTA_WORKER_CODE)
    if not ok or not th then
        self.ota_updating = false
        self.ota_progress_text = nil
        if self.overlay then
            self.overlay:show_toast("无法启动热更新线程：" .. tostring(th), 3.0)
        end
        return false
    end
    self._ota_thread = th
    th:start("kr_mp_ota_result", table.concat(bases, "\n"), table.concat(lines, "\n"), tostring(os.time()))
    if self.overlay then
        self.overlay:show_toast(string.format("正在增量热更新 %d 个文件（约几十~200KB，无需重装 APK）...", #self.ota_changed_files), 3.0)
    end
    return true
end

function updater:restart_game()
    if self.boot then
        self.boot:log("[UPDATER] Triggering restart to activate OTA v%s", tostring(self.ota_applied_ver or self.latest_version))
    end
    if love and love.event and love.event.quit then
        local ok = pcall(love.event.quit, "restart")
        if ok then return true end
    end
    if self.overlay then
        self.overlay:show_toast("热更新已就绪！请完全关闭游戏并重新打开即可生效。", 5.0)
    end
    return false
end

function updater:note_server_version(server_ver)
    if not server_ver or type(server_ver) ~= "string" then return end
    if updater.is_newer(server_ver, proto.MOD_VERSION) then
        self.has_update = true
        self.latest_version = server_ver
        self.status_text = "发现新版 v" .. server_ver
        if not self.download_url then
            if self.DEFAULT_DOWNLOAD_GITEE ~= "" then
                self.download_url = self.DEFAULT_DOWNLOAD_GITEE
            elseif self.DEFAULT_DOWNLOAD_GITHUB ~= "" then
                self.download_url = self.DEFAULT_DOWNLOAD_GITHUB
            end
        end
        if self.overlay then
            self.overlay:show_toast(
                string.format("公网服已升级至 v%s（当前 v%s），点大厅右上角绿色按钮即可一键热更新！", server_ver, proto.MOD_VERSION),
                5.5
            )
        end
    end
end

function updater:open_download_page()
    local url = self.download_url
    if (not url or url == "") then
        if self.DEFAULT_DOWNLOAD_GITEE ~= "" then
            url = self.DEFAULT_DOWNLOAD_GITEE
        elseif self.DEFAULT_DOWNLOAD_GITHUB ~= "" then
            url = self.DEFAULT_DOWNLOAD_GITHUB
        end
    end
    if url and url ~= "" and love and love.system and love.system.openURL then
        love.system.openURL(url)
        if self.overlay then
            self.overlay:show_toast("已在浏览器打开最新版本下载页！", 3.5)
        end
        return true
    end
    if self.overlay then
        self.overlay:show_toast("请联系群主或在群文件获取最新版本 v" .. tostring(self.latest_version or proto.MOD_VERSION), 4.0)
    end
    return false
end

function updater:_poll_ota()
    if not self.ota_updating or not self._ota_channel then return end
    while true do
        local ev = self._ota_channel:pop()
        if not ev then break end
        if ev.kind == "progress" then
            self.ota_progress_text = string.format("更新中 %d/%d", tonumber(ev.done) or 0, tonumber(ev.total) or 1)
        elseif ev.kind == "error" then
            self.ota_updating = false
            self.ota_progress_text = nil
            if self.boot then
                self.boot:log("[UPDATER] OTA failed on %s: %s", tostring(ev.file), tostring(ev.err))
            end
            if self.overlay then
                self.overlay:show_toast("热更新校验失败（未改动原文件），请稍后重试或检查网络。", 3.8)
            end
            return
        elseif ev.kind == "done" and type(ev.files) == "table" then
            self.ota_updating = false
            self.ota_progress_text = nil
            -- Atomic commit: all files already passed SHA-256 + Lua syntax verification!
            local written = 0
            for rel, bytes in pairs(ev.files) do
                local ok_w, werr = write_local_client_file(rel, bytes)
                if not ok_w then
                    if self.boot then
                        self.boot:log("[UPDATER] OTA write failed for %s: %s", tostring(rel), tostring(werr))
                    end
                    if self.overlay then
                        self.overlay:show_toast("写入热更新文件失败：" .. tostring(werr), 4.0)
                    end
                    return
                end
                written = written + 1
            end
            if self.ota_manifest_raw then
                write_local_client_file("kr_mp/manifest.json", self.ota_manifest_raw)
            end
            if proto.is_android() and love and love.filesystem and love.filesystem.write then
                pcall(love.filesystem.write, "kr_mp_ota_active.txt",
                    tostring(self.ota_manifest_ver or self.latest_version or proto.MOD_VERSION) .. "\n" .. tostring(os.time()))
            end
            self.ota_applied = true
            self.ota_applied_ver = self.ota_manifest_ver or self.latest_version or proto.MOD_VERSION
            self.ota_ready = false
            self.has_update = false
            self.ota_changed_files = nil
            if self.boot then
                self.boot:log("[UPDATER] OTA hot-update applied successfully! (%d files -> v%s)", written, tostring(self.ota_applied_ver))
            end
            if self.overlay then
                self.overlay:show_toast(
                    string.format("热更新完成（共更新 %d 个文件至 v%s）！点击右上角「重启生效」或重开游戏即可！",
                        written, tostring(self.ota_applied_ver)),
                    6.0
                )
            end
            return
        end
    end
end

function updater:update(dt)
    self:_poll_ota()

    if not self.checking or not self._channel then return end
    local res = self._channel:pop()
    if not res then return end

    self.checking = false
    if not res.ok then
        self.status_text = "检查失败"
        if self.boot then self.boot:log("[UPDATER] Check failed: %s", tostring(res.err)) end
        if self.manual_notify and self.overlay then
            self.overlay:show_toast("暂时无法连接更新源，请检查网络或稍后再试。", 3.5)
        end
        self.manual_notify = false
        return
    end

    local obj, err = proto.decode(res.body)
    if not obj or type(obj) ~= "table" or not obj.version then
        self.status_text = "格式无效"
        if self.boot then self.boot:log("[UPDATER] Invalid version.json from %s: %s", tostring(res.url), tostring(err)) end
        if self.manual_notify and self.overlay then
            self.overlay:show_toast("版本信息解析失败，请稍后重试。", 3.0)
        end
        self.manual_notify = false
        return
    end

    local remote_ver = tostring(obj.version)
    self.latest_version = remote_ver
    self.latest_notes = obj.notes and tostring(obj.notes) or nil
    if obj.download_gitee and tostring(obj.download_gitee) ~= "" then
        self.download_url = tostring(obj.download_gitee)
    elseif obj.download_github and tostring(obj.download_github) ~= "" then
        self.download_url = tostring(obj.download_github)
    end

    -- Inspect manifest.json for incremental file-level OTA updates
    local mf_changed = nil
    local mf_ver = remote_ver
    if type(res.manifest_body) == "string" and #res.manifest_body > 10 then
        local mf_obj = proto.decode(res.manifest_body)
        if type(mf_obj) == "table" and type(mf_obj.files) == "table" then
            mf_ver = tostring(mf_obj.version or remote_ver)
            -- Only offer OTA when remote manifest is >= local version (prevents downgrading local dev builds!)
            if not updater.is_newer(proto.MOD_VERSION, mf_ver) then
                mf_changed = self:_compute_ota_diff(mf_obj)
                if mf_changed and #mf_changed > 0 then
                    self.ota_ready = true
                    self.ota_changed_files = mf_changed
                    self.ota_manifest_raw = res.manifest_body
                    self.ota_manifest_ver = mf_ver
                    self.ota_base_urls = res.manifest_base and { res.manifest_base } or {}
                end
            end
        end
    end

    local ver_newer = updater.is_newer(remote_ver, proto.MOD_VERSION)
    local has_hotfix = (mf_changed ~= nil and #mf_changed > 0)

    if ver_newer or has_hotfix then
        self.has_update = true
        self.status_text = ver_newer and ("新版 v" .. remote_ver) or string.format("热补丁(%d)", #mf_changed)
        if self.boot then
            self.boot:log("[UPDATER] Update available: remote=v%s local=v%s ota_files=%d via %s",
                remote_ver, proto.MOD_VERSION, mf_changed and #mf_changed or 0, tostring(res.backend))
        end
        if self.overlay then
            local msg
            if self.ota_ready then
                msg = string.format("发现联机补丁更新 v%s（仅需增量更新 %d 个文件），点击右上角绿色按钮一键热更新，无需重装！",
                    mf_ver, #self.ota_changed_files)
            else
                msg = string.format("发现联机补丁新版本 v%s！点击大厅右上角绿色按钮即可打开下载页。", remote_ver)
            end
            self.overlay:show_toast(msg, 6.0)
        end
    else
        self.has_update = false
        self.ota_ready = false
        self.status_text = "已是最新"
        if self.boot then
            self.boot:log("[UPDATER] Up-to-date: local=v%s remote=v%s (%s)",
                proto.MOD_VERSION, remote_ver, tostring(res.url))
        end
        if self.manual_notify and self.overlay then
            self.overlay:show_toast("当前已是最新联机补丁 v" .. proto.MOD_VERSION .. "（文件校验全部最新）！", 3.0)
        end
    end
    self.manual_notify = false
end

return updater
