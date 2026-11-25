param(
    [string]$Version = "",
    [string]$Title = "",
    [string]$Body = "",
    [string]$BodyFile = "",
    [switch]$SkipPackage,
    [switch]$SkipGitPush,
    [switch]$GitHubOnly,
    [switch]$GiteeOnly,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $Root

try {
    function Get-EnvToken([string[]]$names) {
        foreach ($n in $names) {
            $v = [Environment]::GetEnvironmentVariable($n, "Process")
            if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, "User") }
            if ($v -and $v.Trim().Length -gt 0) { return $v.Trim() }
        }
        return ""
    }

    function Parse-RemoteRepo([string]$remoteName) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $url = (& git remote get-url $remoteName 2>$null | Select-Object -First 1)
        } finally {
            $ErrorActionPreference = $prev
        }
        if (-not $url) { return $null }
        $url = $url.Trim()
        if ($url -match "(?:github\.com|gitee\.com)[:/]([^/]+)/([^/\.]+)(?:\.git)?/?$") {
            return [PSCustomObject]@{ Owner = $Matches[1]; Repo = $Matches[2]; Url = $url }
        }
        return $null
    }

    function Invoke-HttpJson(
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers = @{},
        [object]$BodyObj = $null
    ) {
        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        try {
            $httpMethod = New-Object System.Net.Http.HttpMethod($Method)
            $req = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Url)
            $req.Headers.TryAddWithoutValidation("User-Agent", "KR-MP-Release-Bot/1.0") | Out-Null
            foreach ($k in $Headers.Keys) {
                $req.Headers.TryAddWithoutValidation($k, $Headers[$k]) | Out-Null
            }
            if ($null -ne $BodyObj) {
                $json = $BodyObj | ConvertTo-Json -Depth 6 -Compress
                $req.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, "application/json")
            }
            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $parsed = $null
            if ($text -and ($text.TrimStart().StartsWith("{") -or $text.TrimStart().StartsWith("["))) {
                try { $parsed = $text | ConvertFrom-Json } catch {}
            }
            return [PSCustomObject]@{
                StatusCode = [int]$resp.StatusCode
                Ok         = $resp.IsSuccessStatusCode
                Body       = $text
                Json       = $parsed
            }
        } finally {
            $client.Dispose()
        }
    }

    function Upload-GitHubAsset([string]$UploadBaseUrl, [string]$Token, [string]$FilePath) {
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $cleanBase = $UploadBaseUrl -replace "\{.*\}$", ""
        $targetUrl = "$cleanBase?name=$([Uri]::EscapeDataString($fileName))"

        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(5)
        $fs = [System.IO.File]::OpenRead($FilePath)
        try {
            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $targetUrl)
            $req.Headers.TryAddWithoutValidation("User-Agent", "KR-MP-Release-Bot/1.0") | Out-Null
            $req.Headers.TryAddWithoutValidation("Authorization", "Bearer $Token") | Out-Null
            $req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json") | Out-Null
            $req.Headers.TryAddWithoutValidation("X-GitHub-Api-Version", "2022-11-28") | Out-Null
            $content = New-Object System.Net.Http.StreamContent($fs)
            $content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/zip")
            $req.Content = $content

            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) {
                throw "GitHub 附件上传失败 [$fileName] (HTTP $([int]$resp.StatusCode)): $text"
            }
            return ($text | ConvertFrom-Json)
        } finally {
            $fs.Dispose()
            $client.Dispose()
        }
    }

    function Upload-GiteeAsset([string]$Owner, [string]$Repo, [string]$ReleaseId, [string]$Token, [string]$FilePath) {
        $fileName = [System.IO.Path]::GetFileName($FilePath)
        $targetUrl = "https://gitee.com/api/v5/repos/$Owner/$Repo/releases/$ReleaseId/attach_files"

        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromMinutes(5)
        $fs = [System.IO.File]::OpenRead($FilePath)
        $multipart = New-Object System.Net.Http.MultipartFormDataContent
        try {
            $tokenContent = New-Object System.Net.Http.StringContent($Token, [System.Text.Encoding]::UTF8)
            $multipart.Add($tokenContent, "access_token")

            $fileContent = New-Object System.Net.Http.StreamContent($fs)
            $fileContent.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue("application/zip")
            $multipart.Add($fileContent, "file", $fileName)

            $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, $targetUrl)
            $req.Headers.TryAddWithoutValidation("User-Agent", "KR-MP-Release-Bot/1.0") | Out-Null
            $req.Content = $multipart

            $resp = $client.SendAsync($req).GetAwaiter().GetResult()
            $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) {
                throw "Gitee 附件上传失败 [$fileName] (HTTP $([int]$resp.StatusCode)): $text"
            }
            return ($text | ConvertFrom-Json)
        } finally {
            $multipart.Dispose()
            $fs.Dispose()
            $client.Dispose()
        }
    }

    # --- 1. Load version & notes ---
    $verObj = Get-Content (Join-Path $Root "version.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Version) { $Version = [string]$verObj.version }
    $Tag = if ($Version.StartsWith("v")) { $Version } else { "v$Version" }
    $VerNum = $Tag.TrimStart("v")

    if (-not $Title) {
        $Title = "$Tag 赤羽的王国保卫战联机器 (FL 4.1.0)"
    }
    if ($BodyFile -and (Test-Path $BodyFile)) {
        $Body = Get-Content $BodyFile -Raw -Encoding UTF8
    } elseif (-not $Body) {
        $Body = @"
## $Tag 更新说明

$($verObj.notes)

### 下载说明
- **普通玩家开黑**：下载 ``KR-MP-FL4.1.0-$Tag-client-patch.zip``（轻量化客户端补丁），解压后双击 ``一键安装联机补丁.bat`` 即可。
- **房主自建公网中继服 / 樱花映射断线重连**：下载 ``KR-MP-FL4.1.0-$Tag-full-and-server.zip``（内置 Windows / Linux Go 中继服）。
"@
    }

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  KR-MP 官方 API 双平台自动发版工具 ($Tag)" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan

    # --- 2. Build/verify dist zips ---
    $ClientZip = Join-Path $Root "dist\KR-MP-FL4.1.0-$Tag-client-patch.zip"
    $FullZip   = Join-Path $Root "dist\KR-MP-FL4.1.0-$Tag-full-and-server.zip"
    if (-not $SkipPackage -or -not (Test-Path $ClientZip) -or -not (Test-Path $FullZip)) {
        Write-Host "[打包] 正在生成 $Tag 双份发行压缩包..." -ForegroundColor Cyan
        & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\package_release.ps1") -Version $VerNum
        if ($LASTEXITCODE -ne 0) { throw "package_release.ps1 失败" }
    }
    $Assets = @($ClientZip, $FullZip)
    foreach ($a in $Assets) {
        if (-not (Test-Path $a)) { throw "未找到发布压缩包: $a" }
        Write-Host ("  [资产] {0} ({1:N1} KB)" -f (Split-Path -Leaf $a), ((Get-Item $a).Length / 1KB)) -ForegroundColor Gray
    }

    # --- 3. Resolve targets & tokens ---
    $doGitHub = -not $GiteeOnly
    $doGitee  = -not $GitHubOnly
    $ghInfo = if ($doGitHub) { Parse-RemoteRepo "github" } else { $null }
    $geInfo = if ($doGitee)  { Parse-RemoteRepo "gitee" }  else { $null }

    $ghToken = Get-EnvToken @("KR_MP_GITHUB_TOKEN", "GITHUB_TOKEN")
    $geToken = Get-EnvToken @("KR_MP_GITEE_TOKEN", "GITEE_TOKEN")

    if ($DryRun) {
        Write-Host ""
        Write-Host "[DryRun] 本地预检结果：" -ForegroundColor Yellow
        Write-Host "  Tag      : $Tag"
        Write-Host "  Title    : $Title"
        Write-Host "  GitHub   : $(if ($ghInfo) { "$($ghInfo.Owner)/$($ghInfo.Repo)" } else { '未配置' }) | Token=$(if ($ghToken) { '已配置' } else { '未配置' })"
        Write-Host "  Gitee    : $(if ($geInfo) { "$($geInfo.Owner)/$($geInfo.Repo)" } else { '未配置' }) | Token=$(if ($geToken) { '已配置' } else { '未配置' })"
        Write-Host "  Assets   : $($Assets.Count) 个 zip 就绪"
        exit 0
    }

    $publishedUrls = @()

    # --- 4. Publish GitHub Release via Official REST API ---
    if ($doGitHub) {
        if (-not $ghInfo) {
            Write-Host "[跳过] 未配置 github 远端仓库。" -ForegroundColor Yellow
        } elseif (-not $ghToken) {
            Write-Host "[跳过] 未检测到 KR_MP_GITHUB_TOKEN / GITHUB_TOKEN，请先运行【配置API发版令牌.bat】。" -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host ">>> [GitHub] $($ghInfo.Owner)/$($ghInfo.Repo) ($Tag)" -ForegroundColor Cyan
            if (-not $SkipGitPush) {
                Write-Host "  推送分支与标签到 GitHub..." -ForegroundColor Gray
                & git push github main --tags
                if ($LASTEXITCODE -ne 0) { throw "git push github 失败" }
            }

            $ghHeaders = @{
                "Authorization"        = "Bearer $ghToken"
                "Accept"               = "application/vnd.github+json"
                "X-GitHub-Api-Version" = "2022-11-28"
            }
            $baseApi = "https://api.github.com/repos/$($ghInfo.Owner)/$($ghInfo.Repo)"
            $getRes = Invoke-HttpJson -Method "GET" -Url "$baseApi/releases/tags/$Tag" -Headers $ghHeaders
            $rel = $null

            if ($getRes.Ok -and $getRes.Json) {
                $relId = $getRes.Json.id
                Write-Host "  已存在 GitHub Release (id=$relId)，更新标题与说明..." -ForegroundColor Yellow
                $upd = Invoke-HttpJson -Method "PATCH" -Url "$baseApi/releases/$relId" -Headers $ghHeaders -BodyObj @{
                    name = $Title
                    body = $Body
                }
                if (-not $upd.Ok) { throw "更新 GitHub Release 失败: $($upd.Body)" }
                $rel = $upd.Json
            } else {
                Write-Host "  创建 GitHub Release $Tag..." -ForegroundColor Gray
                $crt = Invoke-HttpJson -Method "POST" -Url "$baseApi/releases" -Headers $ghHeaders -BodyObj @{
                    tag_name         = $Tag
                    target_commitish = "main"
                    name             = $Title
                    body             = $Body
                    draft            = $false
                    prerelease       = $false
                }
                if (-not $crt.Ok) { throw "创建 GitHub Release 失败 (HTTP $($crt.StatusCode)): $($crt.Body)" }
                $rel = $crt.Json
            }

            # Remove stale same-name assets before uploading fresh ones
            if ($rel.assets) {
                foreach ($a in $Assets) {
                    $fn = Split-Path -Leaf $a
                    foreach ($old in $rel.assets) {
                        if ($old.name -eq $fn) {
                            Write-Host "  清理旧 GitHub 附件: $fn (id=$($old.id))" -ForegroundColor DarkGray
                            Invoke-HttpJson -Method "DELETE" -Url "$baseApi/releases/assets/$($old.id)" -Headers $ghHeaders | Out-Null
                        }
                    }
                }
            }

            foreach ($a in $Assets) {
                $fn = Split-Path -Leaf $a
                Write-Host "  上传 GitHub 附件: $fn ..." -ForegroundColor Gray
                $up = Upload-GitHubAsset -UploadBaseUrl $rel.upload_url -Token $ghToken -FilePath $a
                Write-Host "  [OK] $($up.browser_download_url)" -ForegroundColor Green
            }
            $publishedUrls += "GitHub: $($rel.html_url)"
        }
    }

    # --- 5. Publish Gitee Release via Official V5 REST API ---
    if ($doGitee) {
        if (-not $geInfo) {
            Write-Host "[跳过] 未配置 gitee 远端仓库。" -ForegroundColor Yellow
        } elseif (-not $geToken) {
            Write-Host "[跳过] 未检测到 KR_MP_GITEE_TOKEN / GITEE_TOKEN，请先运行【配置API发版令牌.bat】。" -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host ">>> [Gitee] $($geInfo.Owner)/$($geInfo.Repo) ($Tag)" -ForegroundColor Cyan
            if (-not $SkipGitPush) {
                Write-Host "  推送分支与标签到 Gitee..." -ForegroundColor Gray
                & git push gitee main --tags
                if ($LASTEXITCODE -ne 0) { throw "git push gitee 失败（请先运行 配置API发版令牌.bat 保存 Gitee 凭据）" }
            }

            $geBase = "https://gitee.com/api/v5/repos/$($geInfo.Owner)/$($geInfo.Repo)"
            $encTok = [Uri]::EscapeDataString($geToken)
            $getRes = Invoke-HttpJson -Method "GET" -Url "$geBase/releases/tags/$Tag?access_token=$encTok"
            $relId = $null

            if ($getRes.Ok -and $getRes.Json -and $getRes.Json.id) {
                $relId = [string]$getRes.Json.id
                Write-Host "  已存在 Gitee Release (id=$relId)，更新标题与说明..." -ForegroundColor Yellow
                $upd = Invoke-HttpJson -Method "PATCH" -Url "$geBase/releases/$relId" -BodyObj @{
                    access_token = $geToken
                    tag_name     = $Tag
                    name         = $Title
                    body         = $Body
                    prerelease   = $false
                }
                if (-not $upd.Ok) { throw "更新 Gitee Release 失败 (HTTP $($upd.StatusCode)): $($upd.Body)" }
            } else {
                Write-Host "  创建 Gitee Release $Tag..." -ForegroundColor Gray
                $crt = Invoke-HttpJson -Method "POST" -Url "$geBase/releases" -BodyObj @{
                    access_token     = $geToken
                    tag_name         = $Tag
                    name             = $Title
                    body             = $Body
                    target_commitish = "main"
                    prerelease       = $false
                }
                if (-not $crt.Ok -or -not $crt.Json.id) {
                    throw "创建 Gitee Release 失败 (HTTP $($crt.StatusCode)): $($crt.Body)"
                }
                $relId = [string]$crt.Json.id
            }

            # List & delete duplicate attachments if re-publishing same tag
            $attRes = Invoke-HttpJson -Method "GET" -Url "$geBase/releases/$relId/attach_files?access_token=$encTok"
            if ($attRes.Ok -and $attRes.Json) {
                foreach ($a in $Assets) {
                    $fn = Split-Path -Leaf $a
                    foreach ($old in $attRes.Json) {
                        if ($old.name -eq $fn -and $old.id) {
                            Write-Host "  清理旧 Gitee 附件: $fn (id=$($old.id))" -ForegroundColor DarkGray
                            Invoke-HttpJson -Method "DELETE" -Url "$geBase/releases/$relId/attach_files/$($old.id)?access_token=$encTok" | Out-Null
                        }
                    }
                }
            }

            foreach ($a in $Assets) {
                $fn = Split-Path -Leaf $a
                Write-Host "  上传 Gitee 附件: $fn ..." -ForegroundColor Gray
                $up = Upload-GiteeAsset -Owner $geInfo.Owner -Repo $geInfo.Repo -ReleaseId $relId -Token $geToken -FilePath $a
                Write-Host "  [OK] $($up.browser_download_url)" -ForegroundColor Green
            }
            $publishedUrls += "Gitee : https://gitee.com/$($geInfo.Owner)/$($geInfo.Repo)/releases/tag/$Tag"
        }
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    if ($publishedUrls.Count -gt 0) {
        Write-Host "[完成] 官方 API 发版成功（全程零浏览器弹窗）：" -ForegroundColor Green
        foreach ($u in $publishedUrls) { Write-Host "  $u" -ForegroundColor Cyan }
    } else {
        Write-Host "[提示] 未发布到任何平台，请先运行【配置API发版令牌.bat】配置令牌。" -ForegroundColor Yellow
    }
    Write-Host "============================================================" -ForegroundColor Cyan
} finally {
    Pop-Location
}
