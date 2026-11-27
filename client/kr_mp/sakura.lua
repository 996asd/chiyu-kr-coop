-- KR-MP SakuraFrp Official Deep-Integration Module (Zero Simulation Impact)
-- Capabilities:
--   1. Pure read-only detection of local SakuraLauncher / SakuraFrpService / frpc.exe & active TCP tunnel log (NEVER reads config.json secrets!)
--   2. One-click official SakuraLauncher.exe downloader via api.natfrp.com/v4/system/clients with live progress & MD5 verification
--   3. Non-blocking 3-line concurrent TCP latency probe (Default / Telecom dx. / Mobile yd.)
--   4. Opt-in Official SakuraFrp OpenAPI v4 (https://api.natfrp.com/v4) for traffic, real-name status, low-load node recommendation
--      (with public-stream 多线 compliance filter & pagination), 1-click 17777 tunnel creation, and Port-Export P2P address lookup
--   5. Zero-popup managed frpc.exe launcher (passes user-supplied Token via child env NATFRP_TOKEN, never on CLI, auto-terminates on exit)
--   6. Streamer privacy address masking
local proto = require("kr_mp.proto")
local lobby_prefs = require("kr_mp.lobby_prefs")
local workers = require("kr_mp.sakura_workers")

local sakura = {
    DOWNLOAD_URL = "https://www.natfrp.com/tunnel/download",
    PANEL_URL = "https://www.natfrp.com/tunnel/",
    REGISTER_URL = "https://www.natfrp.com/user/",
    REALNAME_URL = "https://www.natfrp.com/user/realname",
    PROFILE_URL = "https://www.natfrp.com/user/profile",

    boot = nil,
    overlay = nil,

    -- Read-only local official software & log detection
    installed = false,
    launcher_path = nil,          -- official SakuraLauncher.exe (Option B fallback GUI)
    frpc_path = nil,              -- official launcher-bundled frpc.exe (read-only detection ONLY, never spawned!)
    standalone_frpc_path = nil,   -- official standalone frpc_windows_*.exe downloaded to kr_mp/bin/sakura_frpc.exe (Option A)
    service_running = false,
    official_frpc_running = false,
    standalone_frpc_running = false,
    frpc_running = false,
    log_detected_addr = nil,      -- e.g. "frp-ski.com:54321"
    log_detected_p2p = nil,       -- e.g. "1.2.3.4:56789" if Port Export detected in log
    log_detected_tunnel = nil,    -- tunnel name from log
    log_speed_text = nil,         -- e.g. "10 Mibit/s"
    log_warning = nil,            -- recent diagnostic warning from SakuraFrp log
    log_warning_kind = nil,       -- "local_refused" | "vip_denied" | "net_jitter"
    log_warning_ts = 0,           -- unix timestamp of warning log line
    last_local_scan_ts = 0,

    -- Official SakuraLauncher.exe downloader state (Option B installer)
    dl_busy = false,
    dl_seq = 0,
    dl_stage = nil,               -- "meta" | "downloading" | "verifying" | "done" | "error"
    dl_done_bytes = 0,
    dl_total_bytes = 0,
    dl_ver = nil,
    dl_error = nil,
    dl_path = nil,
    _dl_channel = nil,

    -- Official standalone frpc downloader state (Option A CLI binary)
    frpc_dl_busy = false,
    frpc_dl_seq = 0,
    frpc_dl_stage = nil,
    frpc_dl_done_bytes = 0,
    frpc_dl_total_bytes = 0,
    frpc_dl_ver = nil,
    frpc_dl_error = nil,
    _frpc_dl_channel = nil,
    _pending_start = nil,         -- { tunnel = ..., opts = ... } auto-launched after standalone frpc download completes

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
    user_info = nil,              -- { name, group_name, group_level, speed, remain_gib, used_today_mib, tunnels_max, realname }
    tunnels = {},                 -- sorted list of TCP tunnels (17777 first)
    _all_rec_nodes = {},          -- all online creatable nodes allowed for user's VIP level
    recommended_nodes = {},       -- filtered & sorted nodes according to public_mode
    node_page = 1,
    _api_channel = nil,

    -- Managed standalone sakura_frpc.exe process (spawned explicitly by user inside KR-MP)
    managed_proc = nil,           -- { hProcess, pid, tunnel_id, tunnel_name, local_port, addr, p2p_addr, started_at, log_path, confirmed, keep_on_exit }
    managed_last_error = nil,     -- concise error if managed standalone frpc exited unexpectedly
    managed_last_tunnel_name = nil,
    _last_managed_poll_ts = 0,
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
    local cdefs = {
        "typedef struct { uint32_t dwSize; uint32_t cntUsage; uint32_t th32ProcessID; uintptr_t th32DefaultHeapID; uint32_t th32ModuleID; uint32_t cntThreads; uint32_t th32ParentProcessID; int32_t pcPriClassBase; uint32_t dwFlags; char szExeFile[260]; } KR_PROCESSENTRY32;",
        "typedef struct { uint32_t cb; const char* lpReserved; const char* lpDesktop; const char* lpTitle; uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize; uint32_t dwXCountChars; uint32_t dwYCountChars; uint32_t dwFillAttribute; uint32_t dwFlags; uint16_t wShowWindow; uint16_t cbReserved2; uint8_t* lpReserved2; void* hStdInput; void* hStdOutput; void* hStdError; } KR_STARTUPINFOA;",
        "typedef struct { void* hProcess; void* hThread; uint32_t dwProcessId; uint32_t dwThreadId; } KR_PROCESS_INFORMATION;",
        "typedef struct { uint32_t nLength; void* lpSecurityDescriptor; int32_t bInheritHandle; } KR_SECURITY_ATTRIBUTES;",
        "void* CreateToolhelp32Snapshot(uint32_t dwFlags, uint32_t th32ProcessID);",
        "int32_t Process32First(void* hSnapshot, KR_PROCESSENTRY32* lppe);",
        "int32_t Process32Next(void* hSnapshot, KR_PROCESSENTRY32* lppe);",
        "void* OpenProcess(uint32_t dwDesiredAccess, int32_t bInheritHandle, uint32_t dwProcessId);",
        "int32_t CloseHandle(void* hObject);",
        "uint32_t GetCurrentProcessId(void);",
        "int32_t CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes);",
        "void* CreateFileA(const char* lpFileName, uint32_t dwDesiredAccess, uint32_t dwShareMode, KR_SECURITY_ATTRIBUTES* lpSecurityAttributes, uint32_t dwCreationDisposition, uint32_t dwFlagsAndAttributes, void* hTemplateFile);",
        "int32_t SetEnvironmentVariableA(const char* lpName, const char* lpValue);",
        "int32_t CreateProcessA(const char* lpApplicationName, char* lpCommandLine, void* lpProcessAttributes, void* lpThreadAttributes, int32_t bInheritHandles, uint32_t dwCreationFlags, void* lpEnvironment, const char* lpCurrentDirectory, KR_STARTUPINFOA* lpStartupInfo, KR_PROCESS_INFORMATION* lpProcessInformation);",
        "int32_t GetExitCodeProcess(void* hProcess, uint32_t* lpExitCode);",
        "int32_t TerminateProcess(void* hProcess, uint32_t uExitCode);",
        "void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile, const char* lpParameters, const char* lpDirectory, int32_t nShowCmd);",
    }
    for _, decl in ipairs(cdefs) do pcall(ffi.cdef, decl) end
    local ok_k, k32 = pcall(ffi.load, "kernel32")
    if ok_k and k32 then self._ffi, self._k32 = ffi, k32 end
    local ok_s, sh32 = pcall(ffi.load, "shell32")
    if ok_s and sh32 then self._shell32 = sh32 end
    return self._k32 ~= nil
end

local function get_base_dir()
    local ok, base = pcall(function() return love.filesystem.getSourceBaseDirectory() end)
    return (ok and type(base) == "string" and #base > 0) and base:gsub("/", "\\"):gsub("\\+$", "") or "."
end

local function get_save_dir()
    local ok, sd = pcall(function() return love.filesystem.getSaveDirectory() end)
    if ok and type(sd) == "string" and #sd > 0 then return sd:gsub("/", "\\"):gsub("\\+$", "") end
    return (os.getenv("TEMP") or "."):gsub("/", "\\"):gsub("\\+$", "")
end

local function detect_windows_frpc_arch()
    local pa = tostring(os.getenv("PROCESSOR_ARCHITECTURE") or ""):upper()
    local paw = tostring(os.getenv("PROCESSOR_ARCHITEW6432") or ""):upper()
    if pa == "AMD64" or paw == "AMD64" then return "windows_amd64" end
    if pa == "ARM64" or paw == "ARM64" then return "windows_arm64" end
    return "windows_386"
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
    return workers.mask_addr(proto, addr)
end

function sakura.parse_export_field(exp_str)
    return workers.parse_export_field(exp_str)
end

-- === Part 1: Read-Only Local Software & Log Detection (NO SECRETS) ===

local function scan_processes(self)
    self.service_running = false
    self.official_frpc_running = false
    self.standalone_frpc_running = false
    self.frpc_running = false
    local standalone_pids = {}
    if not init_win32(self) or not self._k32 then return standalone_pids end
    local ffi, k32 = self._ffi, self._k32
    local snap = k32.CreateToolhelp32Snapshot(0x00000002, 0) -- TH32CS_SNAPPROCESS
    if snap == nil or tonumber(ffi.cast("intptr_t", snap)) == -1 then return standalone_pids end
    local pe = ffi.new("KR_PROCESSENTRY32")
    pe.dwSize = ffi.sizeof(pe)
    if k32.Process32First(snap, pe) ~= 0 then
        repeat
            local name = ffi.string(pe.szExeFile):lower()
            if name == "sakurafrpservice.exe" or name == "sakuralauncher.exe" then
                self.service_running = true
            elseif name == "frpc.exe" then
                self.official_frpc_running = true
            elseif name == "sakura_frpc.exe" then
                self.standalone_frpc_running = true
                standalone_pids[#standalone_pids + 1] = tonumber(pe.th32ProcessID) or 0
            end
        until k32.Process32Next(snap, pe) == 0
    end
    k32.CloseHandle(snap)
    self.frpc_running = self.official_frpc_running or self.standalone_frpc_running
    return standalone_pids
end

function sakura:find_standalone_frpc()
    local base = get_base_dir()
    local save = get_save_dir()
    for _, p in ipairs({
        base .. "\\kr_mp\\bin\\sakura_frpc.exe",
        save .. "\\kr_mp_bin\\sakura_frpc.exe",
    }) do
        if file_exists(p) then return p end
    end
    return nil
end

function sakura:get_bin_dir()
    local bin_dir = get_base_dir() .. "\\kr_mp\\bin"
    if init_win32(self) and self._k32 then
        pcall(self._k32.CreateDirectoryA, bin_dir, nil)
    end
    local probe = bin_dir .. "\\.kr_write_test"
    local f = io.open(probe, "wb")
    if f then
        f:close()
        os.remove(probe)
        return bin_dir
    end
    local save_bin = get_save_dir() .. "\\kr_mp_bin"
    if init_win32(self) and self._k32 then
        pcall(self._k32.CreateDirectoryA, save_bin, nil)
    end
    return save_bin
end

local function read_file_tail(path, max_bytes)
    local f = io.open(path, "rb")
    if not f then return nil end
    local sz = f:seek("end") or 0
    local start_pos = math.max(0, sz - (max_bytes or 32768))
    f:seek("set", start_pos)
    local chunk = f:read("*a") or ""
    f:close()
    return chunk
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
    self.standalone_frpc_path = self:find_standalone_frpc()

    scan_processes(self)
    self:poll_managed_frpc()

    -- Read-only tail scan of today's (or yesterday's) SakuraFrpService log (NEVER touches config.json!)
    self.log_detected_addr = nil
    self.log_detected_p2p = nil
    self.log_detected_tunnel = nil
    self.log_speed_text = nil
    self.log_warning = nil
    self.log_warning_kind = nil
    self.log_warning_ts = 0
    if self.official_frpc_running then
        local pd = os.getenv("ProgramData") or "C:\\ProgramData"
        local log_dir = pd .. "\\SakuraFrpService\\Logs"
        local now_t = os.time()
        local dates = { os.date("%Y%m%d", now_t), os.date("%Y%m%d", now_t - 86400) }
        for _, dstr in ipairs(dates) do
            local chunk = read_file_tail(log_dir .. "\\SakuraFrpService." .. dstr .. ".log", 49152)
            if chunk then
                local best, warn, wkind, wts = workers.parse_sakura_log_tail(chunk)
                self.log_warning = warn
                self.log_warning_kind = wkind
                self.log_warning_ts = tonumber(wts) or 0
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
    -- Also inspect kept-alive standalone sakura_frpc.log if no official log address was picked
    if (not self.log_detected_addr) and self.standalone_frpc_running and self.standalone_frpc_path then
        local ldir = self.standalone_frpc_path:match("^(.*)[/\\][^/\\]+$")
        local chunk = ldir and read_file_tail(ldir .. "\\sakura_frpc.log", 16384) or nil
        if chunk then
            local best = workers.parse_sakura_log_tail(chunk, "standalone")
            if best and best.addr then
                self.log_detected_addr = best.addr
                self.log_detected_p2p = best.p2p
                self.log_detected_tunnel = best.name
                self.log_speed_text = best.speed
            end
        end
    end
end

-- Returns an actionable SakuraFrp log warning only when fresh and relevant to current room state.
-- Specifically suppresses "local_refused" when user is not hosting yet (port 17777 is expected to be closed on Home screen)
-- or when the log line is stale (> 60s old).
function sakura:get_active_warning(lobby, now_unix)
    if not self.log_warning or #self.log_warning == 0 then return nil end
    local now_t = tonumber(now_unix) or os.time()
    local age = (self.log_warning_ts and self.log_warning_ts > 0) and (now_t - self.log_warning_ts) or 0
    if self.log_warning_kind == "local_refused" then
        if not (lobby and lobby.role == "host") then
            return nil
        end
        if age > 60 then
            return nil
        end
        local port = (lobby.transport and lobby.transport.get_port and lobby.transport:get_port()) or proto.DEFAULT_TCP_PORT
        return string.format("樱花日志提示：隧道无法连上本机端口，请确认隧道本地端口已设为 %d", port)
    elseif self.log_warning_kind == "net_jitter" then
        if age > 60 then return nil end
    elseif self.log_warning_kind == "vip_denied" then
        if age > 180 then return nil end
    end
    return self.log_warning
end

function sakura:open_url(url, toast_msg)
    if type(url) ~= "string" or #url == 0 then return false end
    if love and love.system and love.system.openURL then
        pcall(love.system.openURL, url)
    elseif init_win32(self) and self._shell32 then
        self._shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
    else
        return false
    end
    if toast_msg and self.overlay then
        self.overlay:show_toast(toast_msg, 3.5)
    end
    return true
end

function sakura:launch_official_launcher(tunnel_name)
    if self.launcher_path and init_win32(self) and self._shell32 then
        self._shell32.ShellExecuteA(nil, "open", self.launcher_path, nil, nil, 1)
        if self.overlay then
            if type(tunnel_name) == "string" and #tunnel_name > 0 then
                self.overlay:show_toast(string.format(
                    "已打开官方樱花启动器！在「隧道」页打开「%s」开关，战桌会自动识别公网地址！",
                    tunnel_name), 4.5)
            else
                self.overlay:show_toast("已唤起官方 SakuraFrp 启动器，启动 17777 / 17780 隧道后战桌会自动识别地址！", 3.5)
            end
        end
        return true
    end
    return self:start_official_installer_download()
end

-- === Part 2: Official SakuraLauncher.exe & Standalone frpc 1-Click Downloaders ===

local function calc_pct(done_b, total_b)
    if total_b and total_b > 0 then
        return math.max(0, math.min(100, math.floor(((done_b or 0) / total_b) * 100 + 0.5)))
    end
    return 0
end

function sakura:get_download_pct() return calc_pct(self.dl_done_bytes, self.dl_total_bytes) end
function sakura:get_frpc_download_pct() return calc_pct(self.frpc_dl_done_bytes, self.frpc_dl_total_bytes) end

function sakura:start_official_installer_download()
    if not is_windows() then
        return self:open_url(self.DOWNLOAD_URL, "已打开 SakuraFrp 官方下载页，请按你的设备下载官方客户端。")
    end
    if self.dl_busy then
        if self.overlay then self.overlay:show_toast(string.format("正在后台下载官方樱花安装器（%d%%），请稍候...", self:get_download_pct()), 2.4) end
        return false
    end
    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
        return self:open_url(self.DOWNLOAD_URL, "已在浏览器打开 SakuraFrp 官方下载页。")
    end
    self._dl_channel = self._dl_channel or love.thread.getChannel("kr_mp_sakura_dl")
    self.dl_seq, self.dl_busy, self.dl_stage, self.dl_done_bytes, self.dl_total_bytes, self.dl_error =
        self.dl_seq + 1, true, "meta", 0, 0, nil
    local ok, th = pcall(love.thread.newThread, workers.INSTALLER_WORKER_CODE)
    if not ok or not th then
        self.dl_busy, self.dl_stage, self.dl_error = false, "error", "无法启动后台下载线程"
        return self:open_url(self.DOWNLOAD_URL, "已在浏览器打开 SakuraFrp 官方下载页。")
    end
    th:start("kr_mp_sakura_dl", self.dl_seq, os.getenv("TEMP") or os.getenv("TMP") or ".", package.path, "launcher", "")
    if self.overlay then self.overlay:show_toast("正在从樱花官方源获取最新启动器安装包并校验完整性...", 3.0) end
    return true
end

function sakura:start_standalone_frpc_download(pending_tunnel, pending_opts)
    if not is_windows() then return false, "仅 PC Windows 支持自动下载官方独立版 frpc" end
    if pending_tunnel then self._pending_start = { tunnel = pending_tunnel, opts = pending_opts } end
    if self.frpc_dl_busy then
        if self.overlay then self.overlay:show_toast(string.format("正在下载官方独立版 frpc（%d%%），下完立即自动启动隧道...", self:get_frpc_download_pct()), 2.6) end
        return true, "downloading"
    end
    if not (love and love.thread and love.thread.newThread and love.thread.getChannel) then
        return false, "当前环境不支持后台下载线程，请点「用官方樱花开」"
    end
    self._frpc_dl_channel = self._frpc_dl_channel or love.thread.getChannel("kr_mp_sakura_frpc_dl")
    self.frpc_dl_seq, self.frpc_dl_busy, self.frpc_dl_stage, self.frpc_dl_done_bytes, self.frpc_dl_total_bytes =
        self.frpc_dl_seq + 1, true, "meta", 0, 0
    self.frpc_dl_error, self.managed_last_error = nil, nil
    local ok, th = pcall(love.thread.newThread, workers.INSTALLER_WORKER_CODE)
    if not ok or not th then
        self.frpc_dl_busy, self.frpc_dl_stage, self.frpc_dl_error, self._pending_start = false, "error", "无法启动后台下载线程", nil
        return false, self.frpc_dl_error
    end
    th:start("kr_mp_sakura_frpc_dl", self.frpc_dl_seq, self:get_bin_dir(), package.path, "frpc", detect_windows_frpc_arch())
    if self.overlay then
        self.overlay:show_toast("首次内启将从樱花官方源下载独立版 frpc（约 13.5 MB，自动 MD5 校验），下完自动开启隧道！", 3.8)
    end
    return true, "downloading"
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

-- === Part 3: Non-Blocking 3-Line Concurrent TCP Latency Probe ===

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
    local ok, th = pcall(love.thread.newThread, workers.PROBE_WORKER_CODE)
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

-- === Part 4: Opt-In Official SakuraFrp OpenAPI v4 Client ===

function sakura:set_token(raw_token)
    local clean = tostring(raw_token or ""):gsub("[%s\r\n]+", ""):sub(1, 96)
    self.token = clean
    if #clean == 0 then
        self.user_info = nil
        self.tunnels = {}
        self._all_rec_nodes = {}
        self.recommended_nodes = {}
        self.node_page = 1
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
    local ok, th = pcall(love.thread.newThread, workers.API_WORKER_CODE)
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
    if self.user_info and tonumber(self.user_info.realname) == 0 then
        if self.overlay then
            self.overlay:show_toast("当前樱花账号尚未完成实名认证，请先点上方「去官网实名」后再新建隧道！", 3.8)
        end
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
    local ok, th = pcall(love.thread.newThread, workers.API_WORKER_CODE)
    if not ok or not th then
        self.api_busy = false
        return false
    end
    th:start("kr_mp_sakura_api", self.api_seq, "create", self.token, payload, package.path)
    if self.overlay then
        self.overlay:show_toast(string.format("正在通过樱花官方 API 创建 %d 专属联机隧道...", port_n), 2.5)
    end
    return true
end

local function process_api_refresh(self, res)
    local user_info, rec, tlist = workers.parse_api_refresh(res, proto.DEFAULT_TCP_PORT)
    self.user_info = user_info
    self._all_rec_nodes = rec
    self:rebuild_filtered_nodes()
    self.tunnels = tlist
end

function sakura:rebuild_filtered_nodes()
    local out = {}
    for _, nd in ipairs(self._all_rec_nodes or {}) do
        if (not self.public_mode) or nd.is_public_ok then
            out[#out + 1] = nd
        end
    end
    -- Sort purely by Mainland -> Load ascending -> ID so toggling public_mode immediately
    -- surfaces true lowest-load non-multi-line nodes when OFF vs strictly compliant 多线 nodes when ON.
    table.sort(out, function(a, b)
        if a.is_mainland ~= b.is_mainland then return a.is_mainland end
        if a.load ~= b.load then return a.load < b.load end
        return a.id < b.id
    end)
    self.recommended_nodes = out
    self.node_page = 1
end

-- === Part 5: Zero-Popup Managed Standalone sakura_frpc.exe Launcher (Option A + B Fallback) ===

function sakura:poll_managed_frpc()
    if not self.managed_proc or not self._k32 then return false end
    local mp = self.managed_proc
    local chunk = mp.log_path and read_file_tail(mp.log_path, 8192) or nil
    if chunk and #chunk > 0 then
        local parsed = workers.parse_sakura_log_tail(chunk, mp.tunnel_name or "standalone")
        if parsed and parsed.alive then
            mp.confirmed = true
            if parsed.addr then mp.addr = parsed.addr end
            if parsed.p2p then mp.p2p_addr = parsed.p2p end
            if parsed.speed then self.log_speed_text = parsed.speed end
        end
    end
    local code = self._ffi.new("uint32_t[1]", 0)
    local ok = self._k32.GetExitCodeProcess(mp.hProcess, code)
    if ok == 0 or tonumber(code[0]) ~= 259 then -- 259 = STILL_ACTIVE
        local exit_code = tonumber(code[0]) or 0
        pcall(self._k32.CloseHandle, mp.hProcess)
        local final_chunk = mp.log_path and read_file_tail(mp.log_path, 8192) or chunk or ""
        local diag = workers.diagnose_frpc_log(final_chunk)
        local tname = tostring(mp.tunnel_name or ("#" .. tostring(mp.tunnel_id)))
        self.managed_proc = nil
        self.standalone_frpc_running = false
        self.frpc_running = self.official_frpc_running
        self.managed_last_error = diag
        self.managed_last_tunnel_name = tname
        if self.boot then
            self.boot:log("[SAKURA] Managed standalone frpc exited (tunnel=%s exit=%d diag=%s)", tname, exit_code, diag)
        end
        if self.overlay then
            self.overlay:show_toast(string.format(
                "独立版 frpc 异常退出（%s）；可点「用官方樱花开」在官方客户端开启「%s」！", diag, tname), 5.0)
        end
        return false
    end
    return true
end

function sakura:stop_managed_frpc()
    local stopped = false
    local name = self.managed_proc and self.managed_proc.tunnel_name or nil
    if self.managed_proc and self._k32 and self.managed_proc.hProcess ~= nil then
        pcall(self._k32.TerminateProcess, self.managed_proc.hProcess, 0)
        pcall(self._k32.CloseHandle, self.managed_proc.hProcess)
        self.managed_proc = nil
        stopped = true
    end
    -- Also terminate any kept-alive standalone sakura_frpc.exe (NEVER touches official frpc.exe!)
    if init_win32(self) and self._k32 then
        local spids = scan_processes(self)
        for _, pid in ipairs(spids) do
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
    self.standalone_frpc_running = false
    self.frpc_running = self.official_frpc_running
    if stopped and self.boot then
        self.boot:log("[SAKURA] Stopped managed standalone sakura_frpc.exe (tunnel=%s)", tostring(name or "kept-alive"))
    end
    return stopped
end

function sakura:start_managed_frpc(tunnel, opts)
    if not tunnel or not tunnel.id then return false, "无效隧道" end
    if not is_windows() or not init_win32(self) or not self._k32 then
        return false, "仅 PC Windows 支持内置启动独立版 frpc"
    end
    if type(self.token) ~= "string" or #self.token < 8 then
        return false, "请先粘贴你的樱花访问密钥"
    end
    if tunnel.online and (not self.managed_proc or self.managed_proc.tunnel_id ~= tunnel.id) then
        return false, "该隧道已在运行中！无需重复启动，可直接复制地址使用。"
    end

    -- Option A: Always use official standalone sakura_frpc.exe (NEVER SakuraFrpLauncher\frpc.exe!)
    self.standalone_frpc_path = self:find_standalone_frpc()
    if not self.standalone_frpc_path then
        return self:start_standalone_frpc_download(tunnel, opts)
    end

    self:stop_managed_frpc()
    self.managed_last_error = nil
    self.managed_last_tunnel_name = tunnel.name
    local ffi, k32 = self._ffi, self._k32
    local watch_pid = (opts and tonumber(opts.watch_pid) and tonumber(opts.watch_pid) > 0)
        and math.floor(tonumber(opts.watch_pid))
        or tonumber(k32.GetCurrentProcessId()) or 0
    local cmd = (watch_pid > 0)
        and string.format('"%s" -n --disable_log_color --watch %d', self.standalone_frpc_path, watch_pid)
        or string.format('"%s" -n --disable_log_color', self.standalone_frpc_path)
    local cmd_buf = ffi.new("char[?]", #cmd + 1, cmd)
    local si = ffi.new("KR_STARTUPINFOA")
    si.cb = ffi.sizeof(si)
    local pi = ffi.new("KR_PROCESS_INFORMATION")
    local workdir = self.standalone_frpc_path:match("^(.*)[/\\][^/\\]+$") or self:get_bin_dir()
    local log_path = workdir .. "\\sakura_frpc.log"

    -- Redirect stdout/stderr to sakura_frpc.log (zero console popup, live startup & error diagnostics)
    local sa = ffi.new("KR_SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof(sa)
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1
    local hLog = k32.CreateFileA(log_path, 0x40000000, 3, sa, 2, 0x80, nil) -- GENERIC_WRITE, SHARE_RW, CREATE_ALWAYS
    local log_ok = (hLog ~= nil and tonumber(ffi.cast("intptr_t", hLog)) ~= -1)
    local inherit = 0
    if log_ok then
        si.dwFlags = 0x00000100 -- STARTF_USESTDHANDLES
        si.hStdOutput = hLog
        si.hStdError = hLog
        inherit = 1
    end

    local old_tok = os.getenv("NATFRP_TOKEN")
    local old_tgt = os.getenv("NATFRP_TARGET")
    k32.SetEnvironmentVariableA("NATFRP_TOKEN", self.token)
    k32.SetEnvironmentVariableA("NATFRP_TARGET", tostring(tunnel.id))
    local ok = k32.CreateProcessA(nil, cmd_buf, nil, nil, inherit, 0x08000000, nil, workdir, si, pi) -- CREATE_NO_WINDOW
    k32.SetEnvironmentVariableA("NATFRP_TOKEN", old_tok)
    k32.SetEnvironmentVariableA("NATFRP_TARGET", old_tgt)
    if log_ok then pcall(k32.CloseHandle, hLog) end

    if ok == 0 then
        self.managed_last_error = "系统拒绝启动 sakura_frpc.exe（可能被安全软件拦截）"
        return false, self.managed_last_error
    end
    k32.CloseHandle(pi.hThread)
    self.managed_proc = {
        hProcess = pi.hProcess,
        pid = tonumber(pi.dwProcessId) or 0,
        tunnel_id = tunnel.id,
        tunnel_name = tunnel.name,
        local_port = tonumber(tunnel.local_port) or proto.DEFAULT_TCP_PORT,
        addr = tunnel.addr,
        p2p_addr = tunnel.p2p_addr,
        started_at = now_sec(),
        log_path = log_ok and log_path or nil,
        confirmed = false,
        keep_on_exit = (opts and opts.keep_on_exit == true) or false,
    }
    self.standalone_frpc_running = true
    self.frpc_running = true
    if self.boot then
        self.boot:log("[SAKURA] Started standalone sakura_frpc.exe pid=%d watch=%d tunnel=#%d (%s -> %s)",
            self.managed_proc.pid, watch_pid, tunnel.id, tostring(tunnel.name), tostring(tunnel.addr))
    end
    return true
end

-- === Lifecycle ===

local function drain_launcher_dl(self)
    if not self._dl_channel then return end
    while true do
        local res = self._dl_channel:pop()
        if not res then break end
        if res.seq == self.dl_seq then
            self.dl_stage = res.stage
            if res.ver then self.dl_ver = res.ver end
            if res.done then self.dl_done_bytes = res.done end
            if res.total then self.dl_total_bytes = res.total end
            if res.stage == "error" then
                self.dl_busy, self.dl_error = false, tostring(res.err or "下载失败")
                if self.overlay then self.overlay:show_toast("官方樱花下载失败：" .. self.dl_error, 4.2) end
            elseif res.stage == "done" and res.ok and res.path then
                self.dl_busy, self.dl_error, self.dl_path = false, nil, res.path
                if init_win32(self) and self._shell32 then self._shell32.ShellExecuteA(nil, "open", res.path, nil, nil, 1) end
                if self.overlay then
                    self.overlay:show_toast(string.format("官方樱花 v%s 校验通过，已拉起安装向导！装完点「刷新状态」即可。", tostring(res.ver or "")), 5.0)
                end
            end
        end
    end
end

local function drain_frpc_dl(self)
    if not self._frpc_dl_channel then return end
    while true do
        local res = self._frpc_dl_channel:pop()
        if not res then break end
        if res.seq == self.frpc_dl_seq then
            self.frpc_dl_stage = res.stage
            if res.ver then self.frpc_dl_ver = res.ver end
            if res.done then self.frpc_dl_done_bytes = res.done end
            if res.total then self.frpc_dl_total_bytes = res.total end
            if res.stage == "error" then
                self.frpc_dl_busy, self.frpc_dl_error = false, tostring(res.err or "下载失败")
                self.managed_last_error, self._pending_start = self.frpc_dl_error, nil
                if self.overlay then self.overlay:show_toast("独立版 frpc 下载失败：" .. self.frpc_dl_error .. "（可点「用官方樱花开」）", 4.5) end
            elseif res.stage == "done" and res.ok and res.path then
                self.frpc_dl_busy, self.frpc_dl_error, self.standalone_frpc_path = false, nil, res.path
                local pend = self._pending_start
                self._pending_start = nil
                if pend and pend.tunnel then
                    local ok, err = self:start_managed_frpc(pend.tunnel, pend.opts)
                    if ok and err ~= "downloading" and self.overlay then
                        self.overlay:show_toast(string.format("官方独立版 frpc v%s 校验通过，正在后台连接隧道「%s」...", tostring(res.ver or ""), tostring(pend.tunnel.name)), 3.5)
                    elseif (not ok) and self.overlay then
                        self.overlay:show_toast("独立版 frpc 启动失败：" .. tostring(err), 4.0)
                    end
                elseif self.overlay then
                    self.overlay:show_toast("官方独立版 frpc 校验完成！点击隧道「启动」即可后台直启。", 3.2)
                end
            end
        end
    end
end

local function drain_probe_and_api(self, lobby)
    if self._probe_channel then
        while true do
            local res = self._probe_channel:pop()
            if not res then break end
            if res.seq == self.probe_seq then
                self.probe_running = false
                if res.ok then
                    self.probe_result = res
                    if res.best_addr and lobby then
                        lobby.sakura_ip_input, lobby.ip_input = res.best_addr, res.best_addr
                        lobby_prefs.record_recent_addr(lobby, res.best_addr)
                        lobby:save_prefs()
                    end
                    local r = res.results or {}
                    local function fmt(id, name)
                        local x = r[id]
                        return (x and x.ok) and string.format("%s %dms", name, x.ms) or (name .. " 不通")
                    end
                    local summary = string.format("三线测速完成：%s | %s | %s", fmt("default", "默认"), fmt("dx", "电信"), fmt("yd", "移动"))
                    if res.best_addr then summary = summary .. " -> 已自动选最快线！" end
                    if self.overlay then self.overlay:show_toast(summary, 4.5) end
                elseif self.overlay then
                    self.overlay:show_toast("三线测速失败：" .. tostring(res.err), 3.0)
                end
            end
        end
    end
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
                    if lobby then lobby.sakura_show_wizard = false end
                    if self.overlay then
                        local msg = (self.user_info.realname == 0)
                            and string.format("已登录 %s，但账号尚未完成实名认证，请先点「去官网实名」！", self.user_info.name)
                            or string.format("樱花账号已同步：%s · 剩余 %.1f GiB · %d 条 TCP 隧道", self.user_info.name, self.user_info.remain_gib, #self.tunnels)
                        self.overlay:show_toast(msg, self.user_info.realname == 0 and 4.5 or 3.0)
                    end
                elseif res.action == "create" then
                    self.api_error = nil
                    local c = res.created or {}
                    if self.overlay then
                        self.overlay:show_toast(string.format("樱花联机隧道创建成功（#%s · 远程端口 %s），正在刷新列表...", tostring(c.id), tostring(c.remote)), 3.5)
                    end
                    self:refresh_api()
                end
            end
        end
    end
end

function sakura:init(boot, overlay)
    self.boot, self.overlay = boot, overlay
    self:scan_local(true)
end

function sakura:update(dt, lobby)
    drain_launcher_dl(self)
    drain_frpc_dl(self)
    drain_probe_and_api(self, lobby)
    if self.managed_proc then
        local now = now_sec()
        if (now - self._last_managed_poll_ts) >= 0.4 then
            self._last_managed_poll_ts = now
            self:poll_managed_frpc()
        end
    end
    if lobby and lobby.open then self:scan_local(false) end
end

function sakura:shutdown()
    if self.managed_proc and self._k32 and self.managed_proc.keep_on_exit then
        pcall(self._k32.CloseHandle, self.managed_proc.hProcess)
        self.managed_proc = nil
        if self.boot then self.boot:log("[SAKURA] Keeping standalone sakura_frpc.exe alive with kr-mp-server (keep_on_exit=true).") end
        return
    end
    self:stop_managed_frpc()
end

return sakura
