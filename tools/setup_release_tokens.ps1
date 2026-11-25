param(
    [switch]$OpenPages,
    [switch]$SkipGitHub,
    [switch]$SkipGitee
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

function Read-SecretPlain([string]$prompt) {
    $sec = Read-Host $prompt -AsSecureString
    if (-not $sec -or $sec.Length -eq 0) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim()
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-ApiGet([string]$url, [hashtable]$headers = @{}) {
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    try {
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
        $req.Headers.TryAddWithoutValidation("User-Agent", "KR-MP-Release-Bot/1.0") | Out-Null
        foreach ($k in $headers.Keys) {
            $req.Headers.TryAddWithoutValidation($k, $headers[$k]) | Out-Null
        }
        $resp = $client.SendAsync($req).GetAwaiter().GetResult()
        $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [PSCustomObject]@{
            StatusCode = [int]$resp.StatusCode
            Ok         = $resp.IsSuccessStatusCode
            Body       = $text
        }
    } finally {
        $client.Dispose()
    }
}

function Save-GitCredential([string]$hostName, [string]$username, [string]$password) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.Arguments = "credential approve"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $payload = "protocol=https`nhost=$hostName`nusername=$username`npassword=$password`n`n"
    $proc.StandardInput.Write($payload)
    $proc.StandardInput.Close()
    $proc.WaitForExit(10000) | Out-Null
    $err = $proc.StandardError.ReadToEnd()
    if ($proc.ExitCode -ne 0) {
        throw "git credential approve ($hostName) 失败: $err"
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  KR-MP 官方 API 发版令牌配置 & Gitee 凭据永久保存工具" -ForegroundColor Yellow
Write-Host "  令牌仅写入本机 Windows 用户环境变量与系统凭据管理器" -ForegroundColor Green
Write-Host "  绝不写入仓库内任何文件，彻底免网页登录与上传弹窗！" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$giteeUrl  = "https://gitee.com/profile/personal_access_tokens/new"
$githubUrl = "https://github.com/settings/tokens/new?scopes=repo&description=kr-mp-release"

Write-Host "所需私人令牌（仅需生成一次，留空直接回车可跳过该平台）：" -ForegroundColor White
Write-Host "  1) Gitee  私人令牌 (勾选 projects 权限): $giteeUrl" -ForegroundColor Cyan
Write-Host "  2) GitHub Classic PAT (勾选 repo 权限) : $githubUrl" -ForegroundColor Cyan
Write-Host ""

if ($OpenPages) {
    if (-not $SkipGitee)  { try { Start-Process $giteeUrl } catch {} }
    if (-not $SkipGitHub) { try { Start-Process $githubUrl } catch {} }
}

# --- 1. Gitee ---
if (-not $SkipGitee) {
    $existingGe = [Environment]::GetEnvironmentVariable("KR_MP_GITEE_TOKEN", "User")
    if ($existingGe) {
        Write-Host "[检测] 本机已配置 KR_MP_GITEE_TOKEN（若无需更新，直接回车跳过）" -ForegroundColor DarkGray
    }
    $geToken = Read-SecretPlain "请粘贴 Gitee 私人令牌（输入不可见，回车跳过）"
    if ($geToken) {
        Write-Host "[校验] 正在验证 Gitee 私人令牌..." -ForegroundColor Yellow
        $res = Invoke-ApiGet "https://gitee.com/api/v5/user?access_token=$([Uri]::EscapeDataString($geToken))"
        if (-not $res.Ok) {
            Write-Host "[失败] Gitee 令牌校验失败 (HTTP $($res.StatusCode)): $($res.Body)" -ForegroundColor Red
            exit 1
        }
        $u = $res.Body | ConvertFrom-Json
        $geLogin = [string]$u.login
        Write-Host "[成功] Gitee 身份验证通过: $geLogin ($($u.name))" -ForegroundColor Green

        [Environment]::SetEnvironmentVariable("KR_MP_GITEE_TOKEN", $geToken, "User")
        $env:KR_MP_GITEE_TOKEN = $geToken
        Write-Host "[保存] 已将 KR_MP_GITEE_TOKEN 写入当前用户的 Windows 环境变量。" -ForegroundColor Green

        # 同步写入 Git Windows 凭据管理器，让 git push gitee 永久免登录
        try {
            Save-GitCredential -hostName "gitee.com" -username $geLogin -password $geToken
            Write-Host "[保存] 已同步保存 Gitee HTTPS 凭据到系统凭据管理器（git push gitee 永久免密码）！" -ForegroundColor Green
        } catch {
            Write-Host "[警告] 自动写入 Git 凭据管理器失败：$($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "       可手动执行一次 git push gitee main 时输入账号 $geLogin 与该令牌。" -ForegroundColor Yellow
        }
    }
    Write-Host ""
}

# --- 2. GitHub ---
if (-not $SkipGitHub) {
    $existingGh = [Environment]::GetEnvironmentVariable("KR_MP_GITHUB_TOKEN", "User")
    if ($existingGh) {
        Write-Host "[检测] 本机已配置 KR_MP_GITHUB_TOKEN（若无需更新，直接回车跳过）" -ForegroundColor DarkGray
    }
    $ghToken = Read-SecretPlain "请粘贴 GitHub 私人令牌（输入不可见，回车跳过）"
    if ($ghToken) {
        Write-Host "[校验] 正在验证 GitHub 私人令牌..." -ForegroundColor Yellow
        $res = Invoke-ApiGet "https://api.github.com/user" @{
            "Authorization"        = "Bearer $ghToken"
            "Accept"               = "application/vnd.github+json"
            "X-GitHub-Api-Version" = "2022-11-28"
        }
        if (-not $res.Ok) {
            Write-Host "[失败] GitHub 令牌校验失败 (HTTP $($res.StatusCode)): $($res.Body)" -ForegroundColor Red
            exit 1
        }
        $u = $res.Body | ConvertFrom-Json
        Write-Host "[成功] GitHub 身份验证通过: $($u.login)" -ForegroundColor Green

        [Environment]::SetEnvironmentVariable("KR_MP_GITHUB_TOKEN", $ghToken, "User")
        $env:KR_MP_GITHUB_TOKEN = $ghToken
        Write-Host "[保存] 已将 KR_MP_GITHUB_TOKEN 写入当前用户的 Windows 环境变量。" -ForegroundColor Green
    }
    Write-Host ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "[完成] 配置结束！后续发版直接双击【一键API双平台发版.bat】即可。" -ForegroundColor Green
Write-Host "       也可以在命令行运行: powershell -ExecutionPolicy Bypass -File tools\publish_release.ps1" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
