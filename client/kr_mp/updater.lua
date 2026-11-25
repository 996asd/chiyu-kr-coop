-- KR-MP 非阻塞后台检查更新模块（love.thread + Windows 原生 WinINet HTTPS，零黑框、零卡顿）
-- 优先读取 Gitee 线上 version.json（国内直连快），失败自动回退 GitHub；连接公网中继服时也会交叉比对服务端版本号。
local proto = require("kr_mp.proto")

local updater = {
    -- 运行 同步推送到GitHub和Gitee.bat 配置双平台仓库后，以下 4 个地址会自动写入真实仓库地址
    GITEE_VERSION_URL = "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/version.json",
    GITHUB_VERSION_URL = "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/version.json",
    DEFAULT_DOWNLOAD_GITEE = "https://gitee.com/chiyu-studio/chiyu-kr-coop/releases",
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
    _thread = nil,
    _channel = nil,
}

local WORKER_CODE = [[
local channel_name, urls_str = ...
local ch = love.thread.getChannel(channel_name)

local function try_wininet(url)
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or not ffi or ffi.os ~= "Windows" then
        return nil, "no_win_ffi"
    end
    local ok_bit, bit = pcall(require, "bit")
    if not ok_bit then return nil, "no_bit" end

    pcall(ffi.cdef, [=[
        void* InternetOpenA(const char* lpszAgent, uint32_t dwAccessType, const char* lpszProxy, const char* lpszProxyBypass, uint32_t dwFlags);
        void* InternetOpenUrlA(void* hInternet, const char* lpszUrl, const char* lpszHeaders, uint32_t dwHeadersLength, uint32_t dwFlags, uintptr_t dwContext);
        int32_t InternetReadFile(void* hFile, void* lpBuffer, uint32_t dwNumberOfBytesToRead, uint32_t* lpdwNumberOfBytesRead);
        int32_t InternetCloseHandle(void* hInternet);
        int32_t InternetSetOptionA(void* hInternet, uint32_t dwOption, void* lpBuffer, uint32_t dwBufferLength);
    ]=])

    local ok_lib, wininet = pcall(ffi.load, "wininet")
    if not ok_lib or not wininet then
        return nil, "load_wininet_failed"
    end

    local hNet = wininet.InternetOpenA("KR-MP-Updater/1.0", 0, nil, nil, 0)
    if hNet == nil then
        return nil, "InternetOpenA_failed"
    end

    -- 3.5s connect & receive timeouts so offline users never hang
    local timeout = ffi.new("uint32_t[1]", 3500)
    pcall(wininet.InternetSetOptionA, hNet, 2, timeout, 4)
    pcall(wininet.InternetSetOptionA, hNet, 6, timeout, 4)

    -- INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE | INTERNET_FLAG_PRAGMA_NOCACHE
    local flags = bit.bor(0x80000000, 0x04000000, 0x00000100)
    local hUrl = wininet.InternetOpenUrlA(hNet, url, nil, 0, flags, 0)
    if hUrl == nil then
        wininet.InternetCloseHandle(hNet)
        return nil, "InternetOpenUrlA_failed"
    end

    local chunks = {}
    local total = 0
    local buf = ffi.new("uint8_t[4096]")
    local bytes_read = ffi.new("uint32_t[1]")
    while total < 32768 do
        bytes_read[0] = 0
        local res = wininet.InternetReadFile(hUrl, buf, 4096, bytes_read)
        local n = tonumber(bytes_read[0]) or 0
        if res == 0 or n <= 0 then
            break
        end
        chunks[#chunks + 1] = ffi.string(buf, n)
        total = total + n
    end

    wininet.InternetCloseHandle(hUrl)
    wininet.InternetCloseHandle(hNet)

    local body = table.concat(chunks)
    if #body == 0 then
        return nil, "empty_body"
    end
    return body, nil
end

local function try_http(url)
    if url:sub(1, 7) ~= "http://" then
        return nil, "not_plain_http"
    end
    local ok_h, http = pcall(require, "socket.http")
    local ok_l, ltn12 = pcall(require, "ltn12")
    if not ok_h or not ok_l then return nil, "no_socket_http" end
    http.TIMEOUT = 3
    local resp = {}
    local ok, code = http.request({
        url = url,
        sink = ltn12.sink.table(resp),
    })
    if ok and tonumber(code) == 200 then
        return table.concat(resp), nil
    end
    return nil, "http_" .. tostring(code)
end

local last_err = "no_urls"
for url in (urls_str or ""):gmatch("[^\n]+") do
    if #url > 7 then
        local backend = "wininet"
        local body, err = try_wininet(url)
        if not body then
            local werr = tostring(err)
            backend = "socket.http"
            body, err = try_http(url)
            if not body then
                err = werr .. "|" .. tostring(err)
            end
        end
        if body and body:match("^%s*{") then
            ch:push({ ok = true, url = url, body = body, backend = backend })
            return
        end
        last_err = tostring(err)
    end
end
ch:push({ ok = false, err = last_err })
]]

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

function updater:init(boot, overlay)
    self.boot = boot
    self.overlay = overlay
    if love and love.thread and love.thread.getChannel then
        self._channel = love.thread.getChannel("kr_mp_update_result")
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

function updater:has_remote_urls()
    return #self:get_candidate_urls() > 0
end

function updater:start_check(manual)
    if self.checking then
        if manual and self.overlay then
            self.overlay:show_toast("正在后台检查更新，请稍候...", 2.0)
        end
        return false
    end

    -- Skip external background checks during automated headless tests unless explicitly overridden
    if not manual and not os.getenv("KR_MP_UPDATE_URL") then
        if os.getenv("KR_MP_AUTO_COOP") or os.getenv("KR_MP_AUTO_M2") or os.getenv("KR_MP_SMOKE_TEST") == "1" then
            return false
        end
    end

    local urls = self:get_candidate_urls()
    if #urls == 0 then
        self.checked_once = true
        self.status_text = "未配置更新源"
        if manual and self.overlay then
            self.overlay:show_toast("尚未绑定 Gitee/GitHub 更新源；当前版本 v" .. proto.MOD_VERSION .. "（连接公网服时也会自动比对版本）", 4.5)
        end
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

    local ok, th = pcall(love.thread.newThread, WORKER_CODE)
    if not ok or not th then
        self.checking = false
        if self.boot then self.boot:log("[UPDATER] Failed to create thread: %s", tostring(th)) end
        return false
    end
    self._thread = th
    th:start("kr_mp_update_result", table.concat(urls, "\n"))
    if manual and self.overlay then
        self.overlay:show_toast("正在检查最新联机补丁版本...", 2.5)
    end
    return true
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
                string.format("公网服已升级至 v%s（你当前 v%s），建议在大厅右上角下载最新版！", server_ver, proto.MOD_VERSION),
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

function updater:update(dt)
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

    if updater.is_newer(remote_ver, proto.MOD_VERSION) then
        self.has_update = true
        self.status_text = "新版 v" .. remote_ver
        if self.boot then
            self.boot:log("[UPDATER] New version available: v%s (local v%s) via %s from %s",
                remote_ver, proto.MOD_VERSION, tostring(res.backend), tostring(res.url))
        end
        if self.overlay then
            local msg = string.format("发现联机补丁新版本 v%s！点击大厅右上角绿色按钮即可打开下载页。", remote_ver)
            if self.latest_notes and #self.latest_notes > 0 then
                msg = string.format("发现新版本 v%s：%s", remote_ver, self.latest_notes)
            end
            self.overlay:show_toast(msg, 6.5)
        end
    else
        self.has_update = false
        self.status_text = "已是最新"
        if self.boot then
            self.boot:log("[UPDATER] Up-to-date: local=v%s remote=v%s (%s)",
                proto.MOD_VERSION, remote_ver, tostring(res.url))
        end
        if self.manual_notify and self.overlay then
            self.overlay:show_toast("当前已是最新版本 v" .. proto.MOD_VERSION .. "！", 3.0)
        end
    end
    self.manual_notify = false
end

return updater
