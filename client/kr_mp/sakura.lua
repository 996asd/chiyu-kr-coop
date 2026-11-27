-- KR-MP SakuraFrp Official Deep-Integration Module (Zero Simulation Impact)
-- Capabilities:
--   1. Pure read-only detection of local SakuraLauncher / SakuraFrpService / frpc.exe & active TCP tunnel log (NEVER reads config.json secrets!)
--   2. Non-blocking 3-line concurrent TCP latency probe (Default / Telecom dx. / Mobile yd.)
--   3. Opt-in Official SakuraFrp OpenAPI v4 (https://api.natfrp.com/v4) for traffic, low-load node recommendation (with public-stream 多线 compliance), 1-click 17777 tunnel creation, and Port-Export P2P address lookup
--   4. Zero-popup managed frpc.exe launcher (passes user-supplied Token via child env NATFRP_TOKEN, never on CLI, auto-terminates on exit)
--   5. Streamer privacy address masking
local proto = require("kr_mp.proto")
local lobby_prefs = require("kr_mp.lobby_prefs")

local sakura = {
    DOWNLOAD_URL = "https://www.natfrp.com/tunnel/download",
    PANEL_URL = "https://www.natfrp.com/tunnel/",

    boot = nil,
    overlay = nil,

    -- Read-only local official software & log detection
    installed = false,
    launcher_path = nil,
    frpc_path = nil,
    service_running = false,
    frpc_running = false,
    log_detected_addr = nil,      -- e.g. "frp-ski.com:54321"
    log_detected_p2p = nil,       -- e.g. "1.2.3.4:56789" if Port Export detected in log
    log_detected_tunnel = nil,    -- tunnel name from log
    log_speed_text = nil,         -- e.g. "10 Mibit/s"
    log_warning = nil,            -- recent diagnostic warning from SakuraFrp log
    last_local_scan_ts = 0,

    -- 3-line concurrent TCP probe state
    probe_running = false,
    probe_seq = 0,
    probe_result = nil,           -- { base, port, default={ok,ms,err}, dx=..., yd=..., best="dx", best_addr="..." }
    _probe_channel = nil,

    -- Opt-in Official OpenAPI v4 state (NEVER read from SakuraFrpService config.json!)
    token = "",
    public_mode = false,          -- true => strictly filter nodes with (flag & 2048) ~= 0 or name contains "多线"
    api_busy = false,
    api_action = nil,
    api_seq = 0,
    api_error = nil,
    user_info = nil,              -- { name, group_name, group_level, speed, remain_gib, used_today_mib, tunnels_max }
    tunnels = {},                 -- sorted list of TCP tunnels (17777 first)
    recommended_nodes = {},       -- sorted list of low-load available nodes
    _api_channel = nil,

    -- Managed frpc.exe process (spawned explicitly by user inside KR-MP)
    managed_proc = nil,           -- { hProcess, pid, tunnel_id, tunnel_name, addr, p2p_addr }
    _win32_ready = false,
    _k32 = nil,
    _shell32 = nil,
}

-- === Win32 FFI Helpers (Zero Console Popup, Optional on Windows Only) ===

local function init_win32(self)
    if self._win32_ready then return self._k32 ~= nil end
    self._win32_ready = true
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" then return false end
    pcall(ffi.cdef, [[
        typedef struct {
            uint32_t dwSize;
            uint32_t cntUsage;
            uint32_t th32ProcessID;
            uintptr_t th32DefaultHeapID;
            uint32_t th32ModuleID;
            uint32_t cntThreads;
            uint32_t th32ParentProcessID;
            int32_t pcPriClassBase;
            uint32_t dwFlags;
            char szExeFile[260];
        } KR_PROCESSENTRY32;

        typedef struct {
            uint32_t cb;
            const char* lpReserved;
            const char* lpDesktop;
            const char* lpTitle;
            uint32_t dwX;
            uint32_t dwY;
            uint32_t dwXSize;
            uint32_t dwYSize;
            uint32_t dwXCountChars;
            uint32_t dwYCountChars;
            uint32_t dwFillAttribute;
            uint32_t dwFlags;
            uint16_t wShowWindow;
            uint16_t cbReserved2;
            uint8_t* lpReserved2;
            void* hStdInput;
            void* hStdOutput;
            void* hStdError;
        } KR_STARTUPINFOA;

        typedef struct {
            void* hProcess;
            void* hThread;
            uint32_t dwProcessId;
            uint32_t dwThreadId;
        } KR_PROCESS_INFORMATION;

        void* CreateToolhelp32Snapshot(uint32_t dwFlags, uint32_t th32ProcessID);
        int32_t Process32First(void* hSnapshot, KR_PROCESSENTRY32* lppe);
        int32_t Process32Next(void* hSnapshot, KR_PROCESSENTRY32* lppe);
        int32_t CloseHandle(void* hObject);
        int32_t SetEnvironmentVariableA(const char* lpName, const char* lpValue);
        int32_t CreateProcessA(
            const char* lpApplicationName,
            char* lpCommandLine,
            void* lpProcessAttributes,
            void* lpThreadAttributes,
            int32_t bInheritHandles,
            uint32_t dwCreationFlags,
            void* lpEnvironment,
            const char* lpCurrentDirectory,
            KR_STARTUPINFOA* lpStartupInfo,
            KR_PROCESS_INFORMATION* lpProcessInformation
        );
        int32_t GetExitCodeProcess(void* hProcess, uint32_t* lpExitCode);
        int32_t TerminateProcess(void* hProcess, uint32_t uExitCode);
        void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int32_t nShowCmd);
    ]])
    local ok_k, k32 = pcall(ffi.load, "kernel32")
    if ok_k and k32 then
        self._ffi = ffi
        self._k32 = k32
    end
    local ok_s, sh32 = pcall(ffi.load, "shell32")
    if ok_s and sh32 then
        self._shell32 = sh32
    end
    return self._k32 ~= nil
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

local function is_windows()
    if proto.is_android() then return false end
    local ok_ffi, ffi = pcall(require, "ffi")
    return ok_ffi and ffi and ffi.os == "Windows"
end

local function now_sec()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

-- === Privacy Masking & Export Address Utilities ===

function sakura.mask_addr(addr)
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

function sakura.parse_export_field(exp_str)
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

-- === Part 1: Read-Only Local Software & Log Detection (NO SECRETS) ===

local function scan_processes(self)
    self.service_running = false
    self.frpc_running = false
    if not init_win32(self) or not self._k32 then return end
    local ffi, k32 = self._ffi, self._k32
    local snap = k32.CreateToolhelp32Snapshot(0x00000002, 0) -- TH32CS_SNAPPROCESS
    if snap == nil or tonumber(ffi.cast("intptr_t", snap)) == -1 then return end
    local pe = ffi.new("KR_PROCESSENTRY32")
    pe.dwSize = ffi.sizeof(pe)
    if k32.Process32First(snap, pe) ~= 0 then
        repeat
            local name = ffi.string(pe.szExeFile):lower()
            if name == "sakurafrpservice.exe" or name == "sakuralauncher.exe" then
                self.service_running = true
            elseif name == "frpc.exe" then
                self.frpc_running = true
            end
        until k32.Process32Next(snap, pe) == 0
    end
    k32.CloseHandle(snap)
end

local function parse_sakura_log_tail(text)
    local tunnels = {}
    local last_warn = nil
    local line_no = 0
    for line in text:gmatch("[^\r\n]+") do
        line_no = line_no + 1
        local tname = line:match("frpc%[([^|%]]+)|") or line:match("Tunnel/([^%s]+)")
        if tname then
            if not tunnels[tname] then
                tunnels[tname] = { name = tname, alive = false, is_http = false, addr = nil, p2p = nil, speed = nil, last_seen = 0 }
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
            if line:find("TCP 隧道启动成功", 1, true) then
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
                last_warn = "樱花日志提示：无法连接本地服务，请确认已点「创建房间」且本地端口为 17777"
            elseif line:find("无权使用该节点", 1, true) then
                last_warn = "樱花日志提示：当前节点 VIP 已到期或无权使用，请更换免费/多线节点"
            elseif line:find("网络波动导致数据连接断开", 1, true) then
                last_warn = "樱花节点近期有波动（联机中已自动受 180 秒热续传保护）"
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
    return best_non_http or best_any, last_warn
end

function sakura:scan_local(force)
    if not is_windows() then return end
    if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_AUTO_SAKURA") then
        return
    end
    local now = now_sec()
    if not force and (now - self.last_local_scan_ts) < 4.0 then return end
    self.last_local_scan_ts = now

    local pf = os.getenv("ProgramFiles") or "C:\\Program Files"
    local pf86 = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    local lap = os.getenv("LOCALAPPDATA") or ""
    local candidates = {
        pf .. "\\SakuraFrpLauncher",
        pf86 .. "\\SakuraFrpLauncher",
        lap .. "\\SakuraFrpLauncher",
    }
    self.launcher_path = nil
    self.frpc_path = nil
    for _, dir in ipairs(candidates) do
        if file_exists(dir .. "\\SakuraLauncher.exe") then
            self.launcher_path = dir .. "\\SakuraLauncher.exe"
        end
        if file_exists(dir .. "\\frpc.exe") then
            self.frpc_path = dir .. "\\frpc.exe"
        end
        if self.launcher_path or self.frpc_path then break end
    end
    self.installed = (self.launcher_path ~= nil or self.frpc_path ~= nil)

    scan_processes(self)
    self:poll_managed_frpc()

    -- Read-only tail scan of today's (or yesterday's) SakuraFrpService log (NEVER touches config.json!)
    self.log_detected_addr = nil
    self.log_detected_p2p = nil
    self.log_detected_tunnel = nil
    self.log_speed_text = nil
    self.log_warning = nil
    if self.frpc_running then
        local pd = os.getenv("ProgramData") or "C:\\ProgramData"
        local log_dir = pd .. "\\SakuraFrpService\\Logs"
        local now_t = os.time()
        local dates = { os.date("%Y%m%d", now_t), os.date("%Y%m%d", now_t - 86400) }
        for _, dstr in ipairs(dates) do
            local lp = log_dir .. "\\SakuraFrpService." .. dstr .. ".log"
            local f = io.open(lp, "rb")
            if f then
                local sz = f:seek("end") or 0
                local start_pos = math.max(0, sz - 49152)
                f:seek("set", start_pos)
                local chunk = f:read("*a") or ""
                f:close()
                local best, warn = parse_sakura_log_tail(chunk)
                self.log_warning = warn
                if best and best.addr then
                    self.log_detected_addr = best.addr
                    self.log_detected_p2p = best.p2p
                    self.log_detected_tunnel = best.name
                    self.log_speed_text = best.speed
                    break
                end
            end
        end
    end
end

function sakura:launch_official_launcher()
    if self.launcher_path and init_win32(self) and self._shell32 then
        self._shell32.ShellExecuteA(nil, "open", self.launcher_path, nil, nil, 1)
        if self.overlay then
            self.overlay:show_toast("已唤起官方 SakuraFrp 启动器，启动 17777 隧道后战桌会自动识别地址！", 3.5)
        end
        return true
    end
    if love and love.system and love.system.openURL then
        pcall(love.system.openURL, self.DOWNLOAD_URL)
        if self.overlay then
            self.overlay:show_toast("未检测到樱花启动器，已在浏览器打开 SakuraFrp 官方下载页。", 3.5)
        end
        return true
    end
    return false
end

-- Get best active connectable address for Host to share with 2P (returns display_addr, copy_addr, has_p2p)
function sakura:get_host_share_addr(host_port)
    -- Priority 1: Managed frpc launched inside KR-MP
    if self.managed_proc and self.managed_proc.addr then
        local relay = self.managed_proc.addr
        local p2p = self.managed_proc.p2p_addr
        local copy = (p2p and #p2p > 0) and (p2p .. "|" .. relay) or relay
        return relay, copy, (p2p ~= nil)
    end
    -- Priority 2: Online matching 17777 tunnel from OpenAPI v4
    if self.tunnels and #self.tunnels > 0 then
        for _, t in ipairs(self.tunnels) do
            if t.online and t.type == "tcp" and t.local_port == host_port and t.addr then
                local copy = (t.p2p_addr and #t.p2p_addr > 0) and (t.p2p_addr .. "|" .. t.addr) or t.addr
                return t.addr, copy, (t.p2p_addr ~= nil)
            end
        end
    end
    -- Priority 3: Read-only local SakuraFrpService log detection
    if self.log_detected_addr then
        local copy = (self.log_detected_p2p and #self.log_detected_p2p > 0)
            and (self.log_detected_p2p .. "|" .. self.log_detected_addr)
            or self.log_detected_addr
        return self.log_detected_addr, copy, (self.log_detected_p2p ~= nil)
    end
    return nil, nil, false
end

-- === Part 2: Non-Blocking 3-Line Concurrent TCP Latency Probe ===

local PROBE_WORKER_CODE = [===[
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
    local ip, derr = socket.dns.toip(t.host)
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

function sakura:start_carrier_probe(raw_addr)
    local primary = proto.split_fallback_addr(raw_addr or "")
    local base, port, _, supports_carrier = lobby_prefs.parse_sakura_parts(primary or raw_addr)
    if not base or not port or not supports_carrier then
        if self.overlay then
            self.overlay:show_toast("当前地址不支持默认/电信/移动三线测速（需 frp-*.com:端口 格式）。", 2.8)
        end
        return false
    end
    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
        return false
    end
    self._probe_channel = self._probe_channel or love.thread.getChannel("kr_mp_sakura_probe")
    self.probe_seq = self.probe_seq + 1
    self.probe_running = true
    local ok, th = pcall(love.thread.newThread, PROBE_WORKER_CODE)
    if not ok or not th then
        self.probe_running = false
        return false
    end
    th:start("kr_mp_sakura_probe", self.probe_seq, base, tonumber(port))
    if self.overlay then
        self.overlay:show_toast("正在并发测速 默认 / 电信(dx) / 移动(yd) 三条樱花线路...", 2.4)
    end
    return true
end

function sakura:get_probe_label(addr, carrier_id, fallback_lbl)
    local pr = self.probe_result
    if not pr or not pr.results then return fallback_lbl end
    local primary = proto.split_fallback_addr(addr or "")
    local base, port = lobby_prefs.parse_sakura_parts(primary or addr)
    if not base or base ~= pr.base or tonumber(port) ~= tonumber(pr.port) then
        return fallback_lbl
    end
    local r = pr.results[carrier_id]
    local short = (carrier_id == "dx") and "电信" or ((carrier_id == "yd") and "移动" or "默认")
    if not r then return fallback_lbl end
    if r.ok then
        return string.format("%s%dms%s", short, r.ms, (pr.best == carrier_id) and "★" or "")
    end
    return short .. (r.err == "dns" and "无" or "×")
end

-- === Part 3: Opt-In Official SakuraFrp OpenAPI v4 Worker (WinINet / LuaHTTPS) ===

local API_WORKER_CODE = [===[
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
        -- Android / LÖVE 12 LuaHTTPS fallback
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

function sakura:set_token(raw_token)
    local clean = tostring(raw_token or ""):gsub("[%s\r\n]+", ""):sub(1, 96)
    self.token = clean
    if #clean == 0 then
        self.user_info = nil
        self.tunnels = {}
        self.recommended_nodes = {}
        self.api_error = nil
    end
    return clean
end

function sakura:refresh_api()
    if type(self.token) ~= "string" or #self.token < 8 then
        self.api_error = "请先粘贴你的樱花访问密钥（在 natfrp.com 用户信息页复制）"
        if self.overlay then self.overlay:show_toast(self.api_error, 3.0) end
        return false
    end
    if self.api_busy then return false end
    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
        self.api_error = "当前环境不支持后台网络线程"
        return false
    end
    self._api_channel = self._api_channel or love.thread.getChannel("kr_mp_sakura_api")
    self.api_seq = self.api_seq + 1
    self.api_busy = true
    self.api_action = "refresh"
    self.api_error = nil
    local ok, th = pcall(love.thread.newThread, API_WORKER_CODE)
    if not ok or not th then
        self.api_busy = false
        self.api_error = "无法启动 API 线程"
        return false
    end
    th:start("kr_mp_sakura_api", self.api_seq, "refresh", self.token, "", package.path)
    return true
end

function sakura:create_krmp_tunnel(node_id, local_port)
    if type(self.token) ~= "string" or #self.token < 8 then
        if self.overlay then self.overlay:show_toast("请先填写樱花访问密钥！", 2.6) end
        return false
    end
    if self.api_busy then return false end
    local port_n = tonumber(local_port) or proto.DEFAULT_TCP_PORT
    local payload = proto.encode({
        name = string.format("krmp_%d_%d", port_n, os.time() % 1000),
        type = "tcp",
        node = tonumber(node_id),
        local_ip = "127.0.0.1",
        local_port = port_n,
        extra = "auto_https = off",
        note = "KR-MP 2P Co-op",
    })
    self._api_channel = self._api_channel or love.thread.getChannel("kr_mp_sakura_api")
    self.api_seq = self.api_seq + 1
    self.api_busy = true
    self.api_action = "create"
    self.api_error = nil
    local ok, th = pcall(love.thread.newThread, API_WORKER_CODE)
    if not ok or not th then
        self.api_busy = false
        return false
    end
    th:start("kr_mp_sakura_api", self.api_seq, "create", self.token, payload, package.path)
    if self.overlay then
        self.overlay:show_toast("正在通过樱花官方 API 创建 17777 专属联机隧道...", 2.5)
    end
    return true
end

local function process_api_refresh(self, res)
    local u = res.user or {}
    local grp = type(u.group) == "table" and u.group or {}
    local tr = type(u.traffic) == "table" and u.traffic or {}
    local used_b = tonumber(tr[1]) or 0
    local rem_b = tonumber(tr[2]) or 0
    self.user_info = {
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

    -- Index nodes & live stats
    local bit = require("bit")
    local stats_by_id = {}
    if type(res.stats) == "table" and type(res.stats.nodes) == "table" then
        for _, ns in ipairs(res.stats.nodes) do
            if tonumber(ns.id) then stats_by_id[tonumber(ns.id)] = ns end
        end
    end

    local nodes_by_id = {}
    local rec = {}
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
                    id = nid,
                    name = name,
                    host = tostring(nd.host),
                    vip = tonumber(nd.vip) or 0,
                    flag = fl,
                    online = online,
                    load = load_pct,
                    allow_create = allow_create,
                    is_mainland = is_mainland,
                    is_public_ok = is_public_ok,
                }
                nodes_by_id[nid] = entry
                if online and allow_create and entry.vip <= self.user_info.group_level then
                    rec[#rec + 1] = entry
                end
            end
        end
    end

    table.sort(rec, function(a, b)
        if a.is_mainland ~= b.is_mainland then return a.is_mainland end
        if a.is_public_ok ~= b.is_public_ok then return a.is_public_ok end
        if a.load ~= b.load then return a.load < b.load end
        return a.id < b.id
    end)
    self._all_rec_nodes = rec
    self:rebuild_filtered_nodes()

    -- Build user's TCP tunnel list (17777 prioritized)
    local tlist = {}
    if type(res.tunnels) == "table" then
        for _, t in ipairs(res.tunnels) do
            if type(t) == "table" and (t.type == "tcp" or t.type == "etcp") then
                local nd = nodes_by_id[tonumber(t.node)]
                local host = nd and nd.host or nil
                local remote_s = tostring(t.remote or "")
                local addr = (host and remote_s:match("^%d+$")) and (host .. ":" .. remote_s) or nil
                local p2p = sakura.parse_export_field(t.export)
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
                    p2p_addr = p2p,
                    is_krmp = (tonumber(t.local_port) == proto.DEFAULT_TCP_PORT),
                }
            end
        end
    end
    table.sort(tlist, function(a, b)
        if a.is_krmp ~= b.is_krmp then return a.is_krmp end
        if a.online ~= b.online then return a.online end
        return a.id < b.id
    end)
    self.tunnels = tlist
end

function sakura:rebuild_filtered_nodes()
    local out = {}
    for _, nd in ipairs(self._all_rec_nodes or {}) do
        if (not self.public_mode) or nd.is_public_ok then
            out[#out + 1] = nd
        end
    end
    self.recommended_nodes = out
end

-- === Part 4: Zero-Popup Managed frpc.exe Launcher (Env-Passed Token, Clean Stop) ===

function sakura:poll_managed_frpc()
    if not self.managed_proc or not self._k32 then return false end
    local code = self._ffi.new("uint32_t[1]", 0)
    local ok = self._k32.GetExitCodeProcess(self.managed_proc.hProcess, code)
    if ok == 0 or tonumber(code[0]) ~= 259 then -- 259 = STILL_ACTIVE
        self._k32.CloseHandle(self.managed_proc.hProcess)
        self.managed_proc = nil
        return false
    end
    return true
end

function sakura:stop_managed_frpc()
    if not self.managed_proc then return false end
    if self._k32 and self.managed_proc.hProcess ~= nil then
        pcall(self._k32.TerminateProcess, self.managed_proc.hProcess, 0)
        pcall(self._k32.CloseHandle, self.managed_proc.hProcess)
    end
    local name = self.managed_proc.tunnel_name
    self.managed_proc = nil
    if self.boot then
        self.boot:log("[SAKURA] Stopped managed frpc process (tunnel=%s)", tostring(name))
    end
    return true
end

function sakura:start_managed_frpc(tunnel)
    if not tunnel or not tunnel.id then return false, "无效隧道" end
    if not is_windows() or not init_win32(self) or not self._k32 then
        return false, "仅 PC Windows 支持内置启动 frpc.exe"
    end
    if not self.frpc_path then
        return false, "未找到本机 frpc.exe，请先安装官方 SakuraFrp 启动器"
    end
    if type(self.token) ~= "string" or #self.token < 8 then
        return false, "请先粘贴你的樱花访问密钥"
    end
    if tunnel.online and (not self.managed_proc or self.managed_proc.tunnel_id ~= tunnel.id) then
        return false, "该隧道已在官方启动器中运行！无需重复启动，可直接复制地址使用。"
    end

    self:stop_managed_frpc()
    local ffi, k32 = self._ffi, self._k32
    local cmd = string.format('"%s" -n --disable_log_color', self.frpc_path)
    local cmd_buf = ffi.new("char[?]", #cmd + 1, cmd)
    local si = ffi.new("KR_STARTUPINFOA")
    si.cb = ffi.sizeof(si)
    local pi = ffi.new("KR_PROCESS_INFORMATION")
    local workdir = self.frpc_path:match("^(.*)[/\\][^/\\]+$")

    local old_tok = os.getenv("NATFRP_TOKEN")
    local old_tgt = os.getenv("NATFRP_TARGET")
    k32.SetEnvironmentVariableA("NATFRP_TOKEN", self.token)
    k32.SetEnvironmentVariableA("NATFRP_TARGET", tostring(tunnel.id))
    local ok = k32.CreateProcessA(nil, cmd_buf, nil, nil, 0, 0x08000000, nil, workdir, si, pi) -- CREATE_NO_WINDOW
    k32.SetEnvironmentVariableA("NATFRP_TOKEN", old_tok)
    k32.SetEnvironmentVariableA("NATFRP_TARGET", old_tgt)

    if ok == 0 then
        return false, "启动 frpc.exe 失败（可能被杀毒软件拦截）"
    end
    k32.CloseHandle(pi.hThread)
    self.managed_proc = {
        hProcess = pi.hProcess,
        pid = tonumber(pi.dwProcessId) or 0,
        tunnel_id = tunnel.id,
        tunnel_name = tunnel.name,
        addr = tunnel.addr,
        p2p_addr = tunnel.p2p_addr,
    }
    self.frpc_running = true
    if self.boot then
        self.boot:log("[SAKURA] Started managed frpc pid=%d tunnel=#%d (%s -> %s)",
            self.managed_proc.pid, tunnel.id, tostring(tunnel.name), tostring(tunnel.addr))
    end
    return true
end

-- === Lifecycle ===

function sakura:init(boot, overlay)
    self.boot = boot
    self.overlay = overlay
    self:scan_local(true)
end

function sakura:update(dt, lobby)
    -- 1. Drain 3-line carrier probe result
    if self._probe_channel then
        while true do
            local res = self._probe_channel:pop()
            if not res then break end
            if res.seq == self.probe_seq then
                self.probe_running = false
                if res.ok then
                    self.probe_result = res
                    if res.best_addr and lobby then
                        lobby.sakura_ip_input = res.best_addr
                        lobby.ip_input = res.best_addr
                        lobby_prefs.record_recent_addr(lobby, res.best_addr)
                        lobby:save_prefs()
                    end
                    local r = res.results or {}
                    local function fmt(id, name)
                        local x = r[id]
                        if x and x.ok then return string.format("%s %dms", name, x.ms) end
                        return name .. " 不通"
                    end
                    local summary = string.format("三线测速完成：%s | %s | %s",
                        fmt("default", "默认"), fmt("dx", "电信"), fmt("yd", "移动"))
                    if res.best_addr then
                        summary = summary .. " -> 已自动选最快线！"
                    end
                    if self.overlay then self.overlay:show_toast(summary, 4.5) end
                elseif self.overlay then
                    self.overlay:show_toast("三线测速失败：" .. tostring(res.err), 3.0)
                end
            end
        end
    end

    -- 2. Drain OpenAPI v4 worker result
    if self._api_channel then
        while true do
            local res = self._api_channel:pop()
            if not res then break end
            if res.seq == self.api_seq then
                self.api_busy = false
                if not res.ok then
                    self.api_error = tostring(res.err or "未知错误")
                    if self.overlay then self.overlay:show_toast("樱花 API：" .. self.api_error, 4.0) end
                elseif res.action == "refresh" then
                    self.api_error = nil
                    process_api_refresh(self, res)
                    if self.overlay then
                        self.overlay:show_toast(string.format(
                            "樱花账号已同步：%s · 剩余 %.1f GiB · %d 条 TCP 隧道",
                            self.user_info.name, self.user_info.remain_gib, #self.tunnels), 3.0)
                    end
                elseif res.action == "create" then
                    self.api_error = nil
                    local c = res.created or {}
                    if self.overlay then
                        self.overlay:show_toast(string.format(
                            "17777 联机隧道创建成功（#%s · 远程端口 %s），正在刷新列表...",
                            tostring(c.id), tostring(c.remote)), 3.5)
                    end
                    self:refresh_api()
                end
            end
        end
    end

    -- 3. Periodic lightweight local status check only while Lobby is open
    if lobby and lobby.open then
        self:scan_local(false)
    end
end

function sakura:shutdown()
    self:stop_managed_frpc()
end

return sakura
