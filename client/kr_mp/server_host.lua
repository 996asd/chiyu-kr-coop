-- KR-MP 1-Click Beginner Public Relay Server Manager (Zero Simulation Impact)
-- Capabilities:
--   1. Auto-detects local kr-mp-server.exe (game dir / kr_mp/bin / save dir) & running status
--   2. On-demand official kr-mp-server.exe downloader from Gitee/GitHub Releases with SHA-256 verification
--   3. Zero-popup Win32 CreateProcessA background host for kr-mp-server.exe (-addr :17780 -http :17781 -grace 300)
--   4. Optional keep-running-on-exit mode (so 1P crashes never kill viewer rooms!) & clean stop button
--   5. Seamless SakuraFrp TCP 17780 linkage (1-click create / start / copy public relay address)
--   6. 1-line Linux VPS deployment command for 24/7 community servers
local proto = require("kr_mp.proto")
local updater = require("kr_mp.updater")

local server_host = {
    DEFAULT_PORT = proto.DEFAULT_ONLINE_PORT or 17780,
    DEFAULT_HTTP_PORT = 17781,
    VPS_DEPLOY_CMD = "curl -fsSL https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/tools/deploy_server.sh | sudo bash",
    BUILTIN_WIN_SHA256 = "7B1A7940CB3CD0FBFFEF075CBF55CF9D236281C6C13A44E8BE3533C8F213A0E7",

    boot = nil,
    overlay = nil,

    -- Local binary & process status
    binary_path = nil,
    running = false,
    external_running = false,   -- true if kr-mp-server.exe was already running outside this session
    managed_proc = nil,         -- { hProcess, pid, port }
    keep_running_on_exit = true,
    lan_ip = nil,
    last_scan_ts = 0,
    auto_connect_at = nil,      -- scheduled timestamp to auto-connect 127.0.0.1:17780 after launch
    _auto_start_after_dl = false,

    -- On-demand binary download state
    dl_busy = false,
    dl_seq = 0,
    dl_stage = nil,             -- "meta" | "downloading" | "verifying" | "done" | "error"
    dl_done_bytes = 0,
    dl_total_bytes = 0,
    dl_ver = nil,
    dl_error = nil,
    _dl_channel = nil,

    _win32_ready = false,
    _ffi = nil,
    _k32 = nil,
}

local function is_windows()
    if proto.is_android() then return false end
    local ok_ffi, ffi = pcall(require, "ffi")
    return ok_ffi and ffi and ffi.os == "Windows"
end

local function file_exists(path)
    if type(path) ~= "string" or #path == 0 then return false end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function now_sec()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

local function init_win32(self)
    if self._win32_ready then return self._k32 ~= nil end
    self._win32_ready = true
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" then return false end
    -- Declare canonical shared Win32 struct & function prototypes individually so
    -- sakura.lua and server_host.lua never conflict regardless of load order.
    local cdefs = {
        [[typedef struct {
            uint32_t dwSize; uint32_t cntUsage; uint32_t th32ProcessID;
            uintptr_t th32DefaultHeapID; uint32_t th32ModuleID; uint32_t cntThreads;
            uint32_t th32ParentProcessID; int32_t pcPriClassBase; uint32_t dwFlags;
            char szExeFile[260];
        } KR_PROCESSENTRY32;]],
        [[typedef struct {
            uint32_t cb; const char* lpReserved; const char* lpDesktop; const char* lpTitle;
            uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize;
            uint32_t dwXCountChars; uint32_t dwYCountChars; uint32_t dwFillAttribute;
            uint32_t dwFlags; uint16_t wShowWindow; uint16_t cbReserved2; uint8_t* lpReserved2;
            void* hStdInput; void* hStdOutput; void* hStdError;
        } KR_STARTUPINFOA;]],
        [[typedef struct {
            void* hProcess; void* hThread; uint32_t dwProcessId; uint32_t dwThreadId;
        } KR_PROCESS_INFORMATION;]],
        "void* CreateToolhelp32Snapshot(uint32_t dwFlags, uint32_t th32ProcessID);",
        "int32_t Process32First(void* hSnapshot, KR_PROCESSENTRY32* lppe);",
        "int32_t Process32Next(void* hSnapshot, KR_PROCESSENTRY32* lppe);",
        "void* OpenProcess(uint32_t dwDesiredAccess, int32_t bInheritHandle, uint32_t dwProcessId);",
        "int32_t CloseHandle(void* hObject);",
        [[int32_t CreateProcessA(
            const char* lpApplicationName, char* lpCommandLine, void* lpProcessAttributes,
            void* lpThreadAttributes, int32_t bInheritHandles, uint32_t dwCreationFlags,
            void* lpEnvironment, const char* lpCurrentDirectory,
            KR_STARTUPINFOA* lpStartupInfo, KR_PROCESS_INFORMATION* lpProcessInformation
        );]],
        "int32_t GetExitCodeProcess(void* hProcess, uint32_t* lpExitCode);",
        "int32_t TerminateProcess(void* hProcess, uint32_t uExitCode);",
        "int32_t CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);",
        "int32_t MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int32_t cbMultiByte, uint16_t* lpWideCharStr, int32_t cchWideChar);",
        "uint32_t GetFileAttributesW(const uint16_t* lpFileName);",
        "int32_t CopyFileW(const uint16_t* lpExistingFileName, const uint16_t* lpNewFileName, int32_t bFailIfExists);",
    }
    for _, decl in ipairs(cdefs) do pcall(ffi.cdef, decl) end
    local ok_k, k32 = pcall(ffi.load, "kernel32")
    if ok_k and k32 then
        self._ffi = ffi
        self._k32 = k32
    end
    return self._k32 ~= nil
end

local function get_base_dir()
    if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
        local ok, base = pcall(love.filesystem.getSourceBaseDirectory)
        if ok and type(base) == "string" and #base > 0 then
            return base:gsub("/", "\\"):gsub("\\+$", "")
        end
    end
    return "."
end

local function get_save_dir()
    if love and love.filesystem and love.filesystem.getSaveDirectory then
        local ok, sd = pcall(love.filesystem.getSaveDirectory)
        if ok and type(sd) == "string" and #sd > 0 then
            return sd:gsub("/", "\\"):gsub("\\+$", "")
        end
    end
    return (os.getenv("TEMP") or "."):gsub("/", "\\"):gsub("\\+$", "")
end

local function is_usable_lan_ip(ip)
    if type(ip) ~= "string" or not ip:match("^%d+%.%d+%.%d+%.%d+$") then return false end
    if ip == "0.0.0.0" or ip:match("^127%.") or ip:match("^169%.254%.") then return false end
    -- Filter out RFC 2544 benchmark / Mihomo / Clash TUN fake-IP virtual adapters
    if ip:match("^198%.18%.") or ip:match("^198%.19%.") then return false end
    return true
end

local function lan_ip_score(ip)
    if ip:match("^192%.168%.") then return 100 end
    if ip:match("^10%.") then return 90 end
    local b2 = tonumber(ip:match("^172%.(%d+)%."))
    if b2 and b2 >= 16 and b2 <= 31 then return 60 end -- often WSL / Hyper-V vEthernet
    return 30
end

function server_host._pick_best_lan_ip(candidates)
    local best, best_score = nil, -1
    for _, ip in ipairs(candidates or {}) do
        if is_usable_lan_ip(ip) then
            local sc = lan_ip_score(ip)
            if sc > best_score then
                best, best_score = ip, sc
            end
        end
    end
    return best
end

function server_host:detect_lan_ip()
    local ok_s, socket = pcall(require, "socket")
    if not ok_s or not socket then return nil end
    local cands = {}
    if socket.udp then
        -- Probe RFC-1918 destinations first (bypasses Mihomo/Clash TUN default routes) then public fallback
        for _, dst in ipairs({ "192.168.255.254", "10.255.255.254", "223.5.5.5" }) do
            local u = socket.udp()
            if u then
                pcall(u.setpeername, u, dst, 53)
                local ok_g, addr = pcall(u.getsockname, u)
                pcall(u.close, u)
                if ok_g and type(addr) == "string" then
                    cands[#cands + 1] = addr
                end
            end
        end
    end
    if socket.dns and socket.dns.gethostname and socket.dns.toip then
        local ok_h, hname = pcall(socket.dns.gethostname)
        if ok_h and type(hname) == "string" and #hname > 0 then
            local ok_r, ip1, info = pcall(socket.dns.toip, hname)
            if ok_r then
                if type(ip1) == "string" then cands[#cands + 1] = ip1 end
                if type(info) == "table" and type(info.ip) == "table" then
                    for _, ip in ipairs(info.ip) do cands[#cands + 1] = ip end
                end
            end
        end
    end
    return server_host._pick_best_lan_ip(cands)
end

local function is_ascii_path(p)
    return type(p) == "string" and #p > 0 and (p:find("[\128-\255]") == nil)
end

local function ascii_cache_dirs()
    local out = {}
    local pub = os.getenv("PUBLIC") or "C:\\Users\\Public"
    local pd = os.getenv("ProgramData") or "C:\\ProgramData"
    local drv = os.getenv("SystemDrive") or "C:"
    for _, d in ipairs({ pub .. "\\KR_MP_Bin", pd .. "\\KR_MP_Bin", drv .. "\\KR_MP_Bin" }) do
        if is_ascii_path(d) then out[#out + 1] = d end
    end
    return out
end

local function utf8_to_wide(self, s)
    if not self._k32 or not self._ffi or type(s) ~= "string" then return nil end
    local n = self._k32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
    if n <= 0 then return nil end
    local buf = self._ffi.new("uint16_t[?]", n)
    if self._k32.MultiByteToWideChar(65001, 0, s, -1, buf, n) <= 0 then return nil end
    return buf
end

function server_host:get_download_target_dir()
    local cands = {}
    local base, save = get_base_dir(), get_save_dir()
    -- Pure-ASCII paths guarantee Win32 CreateProcessA & LuaJIT io.open never fail on Chinese folders/usernames
    if is_ascii_path(base) then cands[#cands + 1] = base .. "\\kr_mp\\bin" end
    if is_ascii_path(save) then cands[#cands + 1] = save .. "\\kr_mp_bin" end
    for _, d in ipairs(ascii_cache_dirs()) do cands[#cands + 1] = d end
    for _, dir in ipairs(cands) do
        if init_win32(self) and self._k32 then
            pcall(self._k32.CreateDirectoryA, dir, nil)
        end
        local probe = dir .. "\\.kr_write_test"
        local f = io.open(probe, "wb")
        if f then
            f:close()
            os.remove(probe)
            return dir
        end
    end
    return cands[#cands] or "C:\\Users\\Public\\KR_MP_Bin"
end

function server_host:find_binary()
    local base, save = get_base_dir(), get_save_dir()
    local candidates = {}
    if is_ascii_path(base) then
        candidates[#candidates + 1] = base .. "\\server\\kr-mp-server.exe"
        candidates[#candidates + 1] = base .. "\\kr_mp\\bin\\kr-mp-server.exe"
    end
    if is_ascii_path(save) then
        candidates[#candidates + 1] = save .. "\\kr_mp_bin\\kr-mp-server.exe"
    end
    for _, d in ipairs(ascii_cache_dirs()) do
        candidates[#candidates + 1] = d .. "\\kr-mp-server.exe"
    end
    for _, p in ipairs(candidates) do
        if file_exists(p) then return p end
    end
    -- If game lives in a Chinese/non-ASCII folder with bundled server\kr-mp-server.exe, mirror once via CopyFileW
    if (not is_ascii_path(base)) and init_win32(self) and self._k32 then
        local src_w = utf8_to_wide(self, base .. "\\server\\kr-mp-server.exe")
        if src_w and self._k32.GetFileAttributesW(src_w) ~= 0xFFFFFFFF then
            local dst = self:get_download_target_dir() .. "\\kr-mp-server.exe"
            local dst_w = utf8_to_wide(self, dst)
            if dst_w and self._k32.CopyFileW(src_w, dst_w, 0) ~= 0 and file_exists(dst) then
                return dst
            end
        end
    end
    return nil
end

server_host._is_ascii_path = is_ascii_path

local function scan_server_processes(self)
    local pids = {}
    if not init_win32(self) or not self._k32 then return pids end
    local ffi, k32 = self._ffi, self._k32
    local snap = k32.CreateToolhelp32Snapshot(0x00000002, 0)
    if snap == nil or tonumber(ffi.cast("intptr_t", snap)) == -1 then return pids end
    local pe = ffi.new("KR_PROCESSENTRY32")
    pe.dwSize = ffi.sizeof(pe)
    if k32.Process32First(snap, pe) ~= 0 then
        repeat
            local name = ffi.string(pe.szExeFile):lower()
            if name == "kr-mp-server.exe" then
                pids[#pids + 1] = tonumber(pe.th32ProcessID) or 0
            end
        until k32.Process32Next(snap, pe) == 0
    end
    k32.CloseHandle(snap)
    return pids
end

function server_host:poll_managed_proc()
    if not self.managed_proc or not self._k32 then return false end
    local code = self._ffi.new("uint32_t[1]", 0)
    local ok = self._k32.GetExitCodeProcess(self.managed_proc.hProcess, code)
    if ok == 0 or tonumber(code[0]) ~= 259 then -- 259 = STILL_ACTIVE
        pcall(self._k32.CloseHandle, self.managed_proc.hProcess)
        self.managed_proc = nil
        return false
    end
    return true
end

function server_host:scan_local(force)
    if not is_windows() then return end
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_AUTO_SAKURA") then
        return
    end
    local now = now_sec()
    if not force and (now - self.last_scan_ts) < 3.0 then return end
    self.last_scan_ts = now

    self.binary_path = self:find_binary()
    local managed_alive = self:poll_managed_proc()
    local pids = scan_server_processes(self)
    self.running = managed_alive or (#pids > 0)
    self.external_running = (not managed_alive) and (#pids > 0)
    if not self.lan_ip then
        self.lan_ip = self:detect_lan_ip()
    end
end

-- === On-Demand Official kr-mp-server.exe Downloader (WinINet + SHA-256 Verify) ===

local SERVER_DL_WORKER_CODE = [===[
local ch_name, seq, dest_dir, pkg_path, fallback_ver, fallback_sha = ...
if type(pkg_path) == "string" and #pkg_path > 0 then
    package.path = pkg_path
end
local ch = love.thread.getChannel(ch_name)
local ok_p, proto = pcall(require, "kr_mp.proto")
local ok_u, updater = pcall(require, "kr_mp.updater")
local ok_ffi, ffi = pcall(require, "ffi")
local ok_bit, bit = pcall(require, "bit")
if not ok_p or not proto or not ok_ffi or not ffi or ffi.os ~= "Windows" or not ok_bit then
    ch:push({ seq = seq, stage = "error", ok = false, err = "仅支持 PC Windows 一键下载服务端程序" })
    return
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

local hNet = wi.InternetOpenA("KR-MP-ServerDownloader/2.3", 0, nil, nil, 0)
if hNet == nil then
    ch:push({ seq = seq, stage = "error", ok = false, err = "网络初始化失败" })
    return
end
local timeout = ffi.new("uint32_t[1]", 15000)
pcall(wi.InternetSetOptionA, hNet, 2, timeout, 4)
pcall(wi.InternetSetOptionA, hNet, 6, timeout, 4)
local FLAGS = bit.bor(0x00800000, 0x80000000, 0x04000000) -- SECURE | RELOAD | NO_CACHE_WRITE

local function http_get_text(url)
    local hUrl = wi.InternetOpenUrlA(hNet, url, nil, 0, FLAGS, 0)
    if hUrl == nil then return nil, 0 end
    local code = ffi.new("uint32_t[1]", 0)
    local clen = ffi.new("uint32_t[1]", 4)
    wi.HttpQueryInfoA(hUrl, 0x20000013, code, clen, nil)
    local chunks, total = {}, 0
    local buf = ffi.new("uint8_t[8192]")
    local bread = ffi.new("uint32_t[1]")
    while total < 131072 do
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

local ver = tostring(fallback_ver or "2.4.5")
local expect_sha = ""
local expect_size = 0
for _, vurl in ipairs({
    "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/version.json",
    "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/version.json",
}) do
    local body, code = http_get_text(vurl)
    if body and code >= 200 and code < 300 then
        local obj = proto.decode(body)
        if type(obj) == "table" and obj.version then
            ver = tostring(obj.version):gsub("[^%w%.%-]", "")
            expect_sha = tostring(obj.server_win_sha256 or ""):upper()
            expect_size = tonumber(obj.server_win_size) or 0
            break
        end
    end
end
if #expect_sha ~= 64 and ver == tostring(fallback_ver or "") and type(fallback_sha) == "string" and #fallback_sha == 64 then
    expect_sha = fallback_sha:upper()
end
if #expect_sha ~= 64 then
    wi.InternetCloseHandle(hNet)
    ch:push({ seq = seq, stage = "error", ok = false, err = "无法获取官方 SHA-256 校验值，已按安全策略中止下载" })
    return
end

local out_dir = tostring(dest_dir or "."):gsub("[/\\]+$", "")
local final_path = out_dir .. "\\kr-mp-server.exe"
local part_path = final_path .. ".part"

local urls = {
    "https://gitee.com/chiyu-studio/chiyu-kr-coop/releases/download/v" .. ver .. "/kr-mp-server.exe",
    "https://github.com/996asd/chiyu-kr-coop/releases/download/v" .. ver .. "/kr-mp-server.exe",
}

local downloaded_data = nil
local last_err = "无法连接 Gitee/GitHub 发行版下载源"
for _, url in ipairs(urls) do
    local hUrl = wi.InternetOpenUrlA(hNet, url, nil, 0, FLAGS, 0)
    if hUrl ~= nil then
        local sc = ffi.new("uint32_t[1]", 0)
        local sl = ffi.new("uint32_t[1]", 4)
        wi.HttpQueryInfoA(hUrl, 0x20000013, sc, sl, nil)
        local code = tonumber(sc[0]) or 0
        if code >= 200 and code < 300 then
            local cl = ffi.new("uint32_t[1]", 0)
            local cll = ffi.new("uint32_t[1]", 4)
            local total_sz = expect_size
            if wi.HttpQueryInfoA(hUrl, 0x20000005, cl, cll, nil) ~= 0 and tonumber(cl[0]) > 0 then
                total_sz = tonumber(cl[0])
            end
            local chunks, written, last_rep = {}, 0, 0
            local buf = ffi.new("uint8_t[32768]")
            local bread = ffi.new("uint32_t[1]")
            local read_ok = true
            ch:push({ seq = seq, stage = "downloading", done = 0, total = total_sz, ver = ver })
            while written < 32 * 1048576 do
                bread[0] = 0
                local r = wi.InternetReadFile(hUrl, buf, 32768, bread)
                local n = tonumber(bread[0]) or 0
                if r == 0 then read_ok = false; break end
                if n <= 0 then break end
                chunks[#chunks + 1] = ffi.string(buf, n)
                written = written + n
                if (written - last_rep) >= 131072 then
                    last_rep = written
                    ch:push({ seq = seq, stage = "downloading", done = written, total = total_sz, ver = ver })
                end
            end
            wi.InternetCloseHandle(hUrl)
            if read_ok and written >= 1048576 then
                local blob = table.concat(chunks)
                if blob:sub(1, 2) == "MZ" then
                    downloaded_data = blob
                    break
                else
                    last_err = "下载内容不是有效的 Windows 可执行程序（可能版本尚未发布）"
                end
            else
                last_err = "下载中断或文件过小"
            end
        else
            wi.InternetCloseHandle(hUrl)
            last_err = "发行版暂未提供 kr-mp-server.exe (HTTP " .. tostring(code) .. ")"
        end
    end
end
wi.InternetCloseHandle(hNet)

if not downloaded_data then
    ch:push({ seq = seq, stage = "error", ok = false, err = last_err })
    return
end

ch:push({ seq = seq, stage = "verifying", done = #downloaded_data, total = #downloaded_data, ver = ver })
if #expect_sha ~= 64 or not (ok_u and updater and updater.sha256_hex) then
    ch:push({ seq = seq, stage = "error", ok = false, err = "缺少 SHA-256 校验组件或官方哈希，已按安全策略拒绝保存" })
    return
end
local got_sha = updater.sha256_hex(downloaded_data)
if got_sha ~= expect_sha then
    ch:push({ seq = seq, stage = "error", ok = false, err = "服务端程序 SHA-256 校验未通过，已拒绝保存" })
    return
end

local f, ferr = io.open(part_path, "wb")
if not f then
    ch:push({ seq = seq, stage = "error", ok = false, err = "无法写入服务端程序：" .. tostring(ferr) })
    return
end
f:write(downloaded_data)
f:close()
os.remove(final_path)
if not os.rename(part_path, final_path) then
    os.remove(part_path)
    ch:push({ seq = seq, stage = "error", ok = false, err = "保存 kr-mp-server.exe 失败（可能被安全软件拦截）" })
    return
end

ch:push({ seq = seq, stage = "done", ok = true, path = final_path, ver = ver, size = #downloaded_data })
]===]

server_host._DL_WORKER_CODE = SERVER_DL_WORKER_CODE

function server_host:get_download_pct()
    if self.dl_total_bytes and self.dl_total_bytes > 0 then
        return math.max(0, math.min(100, math.floor((self.dl_done_bytes / self.dl_total_bytes) * 100 + 0.5)))
    end
    return 0
end

function server_host:start_download(auto_start)
    if not is_windows() then
        if self.overlay then self.overlay:show_toast("仅 PC Windows 支持游戏内一键开服；手机端请连 PC 或云服务器。", 3.5) end
        return false
    end
    if self.dl_busy then
        if self.overlay then
            self.overlay:show_toast(string.format("正在下载官方服务端程序 (%d%%)，请稍候...", self:get_download_pct()), 2.4)
        end
        return false
    end
    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
        if self.overlay then self.overlay:show_toast("当前环境不支持后台下载线程，请下载 full-and-server 完整包。", 3.5) end
        return false
    end
    self._dl_channel = self._dl_channel or love.thread.getChannel("kr_mp_srv_dl")
    self.dl_seq = self.dl_seq + 1
    self.dl_busy = true
    self.dl_stage = "meta"
    self.dl_done_bytes = 0
    self.dl_total_bytes = 0
    self.dl_error = nil
    self._auto_start_after_dl = (auto_start ~= false)
    local ok, th = pcall(love.thread.newThread, SERVER_DL_WORKER_CODE)
    if not ok or not th then
        self.dl_busy = false
        self.dl_stage = "error"
        self.dl_error = "无法启动后台下载线程"
        return false
    end
    local dest_dir = self:get_download_target_dir()
    th:start("kr_mp_srv_dl", self.dl_seq, dest_dir, package.path, proto.MOD_VERSION, self.BUILTIN_WIN_SHA256)
    if self.overlay then
        self.overlay:show_toast("正在从官方源下载独立服务端 kr-mp-server.exe 并校验完整性...", 3.0)
    end
    return true
end

function server_host:start_local_server(lobby)
    if not is_windows() or not init_win32(self) or not self._k32 then
        return false, "仅 PC Windows 支持游戏内一键启动本机服务器"
    end
    self:scan_local(true)
    if self.running then
        if lobby then
            lobby.server_input = "127.0.0.1:" .. tostring(self.DEFAULT_PORT)
            lobby:save_prefs()
            lobby:connect_online_server(lobby.server_input, false)
        end
        if self.overlay then
            self.overlay:show_toast("本机公网中继服已在运行（端口 17780），正在自动接入！", 2.8)
        end
        return true
    end
    if not self.binary_path then
        self:start_download(true)
        return true, "downloading"
    end

    local ffi, k32 = self._ffi, self._k32
    local cmd = string.format('"%s" -addr :%d -http 127.0.0.1:%d -grace 300',
        self.binary_path, self.DEFAULT_PORT, self.DEFAULT_HTTP_PORT)
    local cmd_buf = ffi.new("char[?]", #cmd + 1, cmd)
    local si = ffi.new("KR_STARTUPINFOA")
    si.cb = ffi.sizeof(si)
    local pi = ffi.new("KR_PROCESS_INFORMATION")
    local workdir = self.binary_path:match("^(.*)[/\\][^/\\]+$")

    local ok = k32.CreateProcessA(nil, cmd_buf, nil, nil, 0, 0x08000000, nil, workdir, si, pi) -- CREATE_NO_WINDOW
    if ok == 0 then
        return false, "启动 kr-mp-server.exe 失败（可能被安全软件拦截）"
    end
    k32.CloseHandle(pi.hThread)
    self.managed_proc = {
        hProcess = pi.hProcess,
        pid = tonumber(pi.dwProcessId) or 0,
        port = self.DEFAULT_PORT,
    }
    self.running = true
    self.external_running = false
    self.auto_connect_at = now_sec() + 0.45
    if self.boot then
        self.boot:log("[SERVER_HOST] Started local kr-mp-server pid=%d port=%d", self.managed_proc.pid, self.DEFAULT_PORT)
    end
    if self.overlay then
        self.overlay:show_toast("本机公网中继服已无黑框启动（TCP 17780），正在自动连接...", 3.0)
    end
    return true
end

function server_host:stop_local_server()
    local stopped = false
    if self.managed_proc and self._k32 then
        pcall(self._k32.TerminateProcess, self.managed_proc.hProcess, 0)
        pcall(self._k32.CloseHandle, self.managed_proc.hProcess)
        self.managed_proc = nil
        stopped = true
    end
    -- Also terminate any kept-alive kr-mp-server.exe instance when user explicitly clicks Stop
    if init_win32(self) and self._k32 then
        local pids = scan_server_processes(self)
        for _, pid in ipairs(pids) do
            if pid > 0 then
                local h = self._k32.OpenProcess(0x0001, 0, pid) -- PROCESS_TERMINATE
                if h ~= nil then
                    pcall(self._k32.TerminateProcess, h, 0)
                    pcall(self._k32.CloseHandle, h)
                    stopped = true
                end
            end
        end
    end
    self.running = false
    self.external_running = false
    self.auto_connect_at = nil
    if stopped and self.boot then
        self.boot:log("[SERVER_HOST] Stopped local kr-mp-server.")
    end
    return stopped
end

function server_host:get_running_pid()
    if self.managed_proc and self:poll_managed_proc() and self.managed_proc.pid and self.managed_proc.pid > 0 then
        return self.managed_proc.pid
    end
    local pids = scan_server_processes(self)
    if #pids > 0 and pids[1] > 0 then return pids[1] end
    return nil
end

-- Helper: Inspect SakuraFrp tunnels for a TCP 17780 relay tunnel
function server_host:get_sakura_relay_info(sakura)
    if not sakura then return nil end
    local port = self.DEFAULT_PORT
    if sakura.managed_proc and sakura.managed_proc.addr then
        local mp = sakura.managed_proc
        if tonumber(mp.local_port) == port then
            local matched_t = nil
            for _, t in ipairs(sakura.tunnels or {}) do
                if t.id == mp.tunnel_id then matched_t = t; break end
            end
            return {
                state = "managed",
                confirmed = (mp.confirmed == true),
                tunnel = matched_t or { id = mp.tunnel_id, name = mp.tunnel_name, local_port = port, addr = mp.addr },
                addr = mp.addr,
                can_stop_standalone = true,
            }
        end
    end
    for _, t in ipairs(sakura.tunnels or {}) do
        if (t.type == "tcp" or t.type == "etcp") and tonumber(t.local_port) == port then
            return {
                state = t.online and "online" or "offline",
                confirmed = (t.online == true),
                tunnel = t,
                addr = t.addr,
                can_stop_standalone = (t.online == true and sakura.standalone_frpc_running == true),
            }
        end
    end
    return nil
end

function server_host:init(boot, overlay)
    self.boot = boot
    self.overlay = overlay
    self:scan_local(true)
end

function server_host:update(dt, lobby)
    -- 1. Drain server binary download worker
    if self._dl_channel then
        while true do
            local res = self._dl_channel:pop()
            if not res then break end
            if res.seq == self.dl_seq then
                self.dl_stage = res.stage
                if res.ver then self.dl_ver = res.ver end
                if res.done then self.dl_done_bytes = res.done end
                if res.total then self.dl_total_bytes = res.total end
                if res.stage == "error" then
                    self.dl_busy = false
                    self.dl_error = tostring(res.err or "下载失败")
                    self._auto_start_after_dl = false
                    if self.overlay then
                        self.overlay:show_toast("服务端下载失败：" .. self.dl_error, 4.5)
                    end
                elseif res.stage == "done" and res.ok and res.path then
                    self.dl_busy = false
                    self.dl_error = nil
                    self.binary_path = res.path
                    if self._auto_start_after_dl then
                        self._auto_start_after_dl = false
                        self:start_local_server(lobby)
                    elseif self.overlay then
                        self.overlay:show_toast("官方服务端 kr-mp-server.exe 校验完成！点击启动即可开服。", 3.2)
                    end
                end
            end
        end
    end

    -- 2. Deferred auto-connect to 127.0.0.1:17780 once server finishes binding port
    if self.auto_connect_at and now_sec() >= self.auto_connect_at then
        self.auto_connect_at = nil
        if lobby and self.running then
            local addr = "127.0.0.1:" .. tostring(self.DEFAULT_PORT)
            lobby.server_input = addr
            lobby:save_prefs()
            if lobby.net_tab ~= "online" and lobby.view == "home" then
                lobby:switch_tab("online")
            end
            lobby:connect_online_server(addr, false)
        end
    end

    -- 3. Periodic lightweight local status scan while lobby is open
    if lobby and lobby.open then
        self:scan_local(false)
    end
end

function server_host:shutdown()
    if self.managed_proc and self._k32 then
        if not self.keep_running_on_exit then
            pcall(self._k32.TerminateProcess, self.managed_proc.hProcess, 0)
            if self.boot then self.boot:log("[SERVER_HOST] Terminated local kr-mp-server on game exit.") end
        else
            if self.boot then self.boot:log("[SERVER_HOST] Keeping local kr-mp-server alive in background (keep_running_on_exit=true).") end
        end
        pcall(self._k32.CloseHandle, self.managed_proc.hProcess)
        self.managed_proc = nil
    end
end

return server_host
