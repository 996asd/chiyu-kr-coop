-- KR-MP Shared Windows FFI, Path & WinINet Helpers (Single Source of Truth)
-- Consumed by sakura.lua, server_host.lua, sakura_workers.lua, and updater.lua.
-- Safe to require on all platforms (Android / Linux / macOS gracefully degrade to no-ops).
local proto = require("kr_mp.proto")

local M = {
    _win32_ready = false,
    _ffi = nil,
    _k32 = nil,
    _shell32 = nil,
}

function M.is_windows()
    if proto.is_android() then return false end
    local ok_ffi, ffi = pcall(require, "ffi")
    return ok_ffi and ffi and ffi.os == "Windows"
end

function M.file_exists(path)
    if type(path) ~= "string" or #path == 0 then return false end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

function M.now_sec()
    if love and love.timer and love.timer.getTime then
        return love.timer.getTime()
    end
    return os.clock()
end

function M.get_base_dir()
    if love and love.filesystem and love.filesystem.getSourceBaseDirectory then
        local ok, base = pcall(love.filesystem.getSourceBaseDirectory)
        if ok and type(base) == "string" and #base > 0 then
            return base:gsub("/", "\\"):gsub("\\+$", "")
        end
    end
    return "."
end

function M.get_save_dir()
    if love and love.filesystem and love.filesystem.getSaveDirectory then
        local ok, sd = pcall(love.filesystem.getSaveDirectory)
        if ok and type(sd) == "string" and #sd > 0 then
            return sd:gsub("/", "\\"):gsub("\\+$", "")
        end
    end
    return (os.getenv("TEMP") or "."):gsub("/", "\\"):gsub("\\+$", "")
end

function M.is_ascii_path(p)
    return type(p) == "string" and #p > 0 and (p:find("[\128-\255]") == nil)
end

function M.ascii_cache_dirs()
    local out = {}
    local pub = os.getenv("PUBLIC") or "C:\\Users\\Public"
    local pd = os.getenv("ProgramData") or "C:\\ProgramData"
    local drv = os.getenv("SystemDrive") or "C:"
    for _, d in ipairs({ pub .. "\\KR_MP_Bin", pd .. "\\KR_MP_Bin", drv .. "\\KR_MP_Bin" }) do
        if M.is_ascii_path(d) then out[#out + 1] = d end
    end
    return out
end

-- Canonical Win32 kernel32 / shell32 FFI initialization (idempotent across modules)
function M.init_win32()
    if M._win32_ready then
        return M._k32 ~= nil, M._ffi, M._k32, M._shell32
    end
    M._win32_ready = true
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" then
        return false, nil, nil, nil
    end
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
        "int32_t MultiByteToWideChar(uint32_t CodePage, uint32_t dwFlags, const char* lpMultiByteStr, int32_t cbMultiByte, uint16_t* lpWideCharStr, int32_t cchWideChar);",
        "uint32_t GetFileAttributesW(const uint16_t* lpFileName);",
        "int32_t CopyFileW(const uint16_t* lpExistingFileName, const uint16_t* lpNewFileName, int32_t bFailIfExists);",
    }
    for _, decl in ipairs(cdefs) do pcall(ffi.cdef, decl) end
    local ok_k, k32 = pcall(ffi.load, "kernel32")
    if ok_k and k32 then M._ffi, M._k32 = ffi, k32 end
    local ok_s, sh32 = pcall(ffi.load, "shell32")
    if ok_s and sh32 then M._shell32 = sh32 end
    return M._k32 ~= nil, M._ffi, M._k32, M._shell32
end

function M.attach_win32(target)
    local ok, ffi, k32, sh32 = M.init_win32()
    if target then
        target._win32_ready = true
        target._ffi = ffi
        target._k32 = k32
        target._shell32 = sh32
    end
    return ok
end

function M.utf8_to_wide(s)
    local ok, ffi, k32 = M.init_win32()
    if not ok or not k32 or not ffi or type(s) ~= "string" then return nil end
    local n = k32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
    if n <= 0 then return nil end
    local buf = ffi.new("uint16_t[?]", n)
    if k32.MultiByteToWideChar(65001, 0, s, -1, buf, n) <= 0 then return nil end
    return buf
end

-- === Shared WinINet FFI Client (callable inside love.thread or main thread) ===

M.WININET_CDEF = [=[
    void* InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
    void* InternetOpenUrlA(void* hInternet, const char* lpszUrl, const char* lpszHeaders, uint32_t dwHeadersLength, uint32_t dwFlags, uintptr_t dwContext);
    int32_t HttpQueryInfoA(void* hRequest, uint32_t dwInfoLevel, void* lpBuffer, uint32_t* lpdwBufferLength, uint32_t* lpdwIndex);
    int32_t InternetReadFile(void* hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
    int32_t InternetCloseHandle(void* hInternet);
    int32_t InternetSetOptionA(void* hInternet, uint32_t dwOption, void* lpBuffer, uint32_t dwBufferLength);
]=]

function M.open_wininet(user_agent, timeout_ms)
    local ok_ffi, ffi = pcall(require, "ffi")
    local ok_bit, bit = pcall(require, "bit")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" or not ok_bit then
        return nil, nil, 0, "non_windows_or_no_ffi"
    end
    pcall(ffi.cdef, M.WININET_CDEF)
    local ok_lib, wi = pcall(ffi.load, "wininet")
    if not ok_lib or not wi then
        return nil, nil, 0, "无法加载 Windows 网络组件 (wininet)"
    end
    local hNet = wi.InternetOpenA(user_agent or "KR-MP-Client/2.4", 0, nil, nil, 0)
    if hNet == nil then
        return nil, nil, 0, "初始化网络句柄失败"
    end
    local timeout = ffi.new("uint32_t[1]", tonumber(timeout_ms) or 15000)
    pcall(wi.InternetSetOptionA, hNet, 2, timeout, 4)
    pcall(wi.InternetSetOptionA, hNet, 6, timeout, 4)
    local flags = bit.bor(0x00800000, 0x80000000, 0x04000000) -- SECURE | RELOAD | NO_CACHE_WRITE
    return wi, hNet, flags, nil
end

function M.wininet_get_text(wi, hNet, flags, url, headers, max_bytes)
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not wi or hNet == nil then return nil, 0 end
    local hdr_len = (type(headers) == "string") and #headers or 0
    local hUrl = wi.InternetOpenUrlA(hNet, url, headers, hdr_len, flags, 0)
    if hUrl == nil then return nil, 0 end
    local code = ffi.new("uint32_t[1]", 0)
    local clen = ffi.new("uint32_t[1]", 4)
    wi.HttpQueryInfoA(hUrl, 0x20000013, code, clen, nil)
    local limit = tonumber(max_bytes) or 1048576
    local chunks, total = {}, 0
    local buf = ffi.new("uint8_t[8192]")
    local bread = ffi.new("uint32_t[1]")
    while total < limit do
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

-- Embeddable WinINet GET snippet for standalone love.thread workers without package.path (e.g. updater.lua)
M.WININET_THREAD_GET_SRC = [===[
local function kr_wininet_get(url, max_bytes, user_agent, timeout_ms)
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" then return nil, nil end
    local ok_bit, bit = pcall(require, "bit")
    if not ok_bit then return nil, nil end
    pcall(ffi.cdef, [=[
        void* InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
        void* InternetOpenUrlA(void* hInternet, const char* lpszUrl, const char* lpszHeaders, uint32_t dwHeadersLength, uint32_t dwFlags, uintptr_t dwContext);
        int32_t InternetReadFile(void* hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
        int32_t InternetCloseHandle(void* hInternet);
        int32_t InternetSetOptionA(void* hInternet, uint32_t dwOption, void* lpBuffer, uint32_t dwBufferLength);
    ]=])
    local ok_lib, wininet = pcall(ffi.load, "wininet")
    if not ok_lib or not wininet then return nil, "wininet_load_fail" end
    local hNet = wininet.InternetOpenA(user_agent or "KR-MP-Updater/2.4", 0, nil, nil, 0)
    if hNet == nil then return nil, "wininet_open_fail" end
    local timeout = ffi.new("uint32_t[1]", tonumber(timeout_ms) or 6000)
    pcall(wininet.InternetSetOptionA, hNet, 2, timeout, 4)
    pcall(wininet.InternetSetOptionA, hNet, 6, timeout, 4)
    local flags = bit.bor(0x80000000, 0x04000000, 0x00000100)
    local hUrl = wininet.InternetOpenUrlA(hNet, url, nil, 0, flags, 0)
    if hUrl == nil then
        wininet.InternetCloseHandle(hNet)
        return nil, "wininet_openurl_fail"
    end
    local chunks, total = {}, 0
    local buf = ffi.new("uint8_t[8192]")
    local bytes_read = ffi.new("uint32_t[1]")
    local limit = tonumber(max_bytes) or (2 * 1024 * 1024)
    while total < limit do
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
    return nil, "wininet_empty"
end
]===]

return M
