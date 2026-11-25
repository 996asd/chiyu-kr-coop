param(
    [string]$GitHubUrl = "",
    [string]$GiteeUrl = "",
    [switch]$Push,
    [switch]$ConfigureOnly
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location $Root

try {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  KR-MP GitHub + Gitee 双平台仓库配置与一键同步推送工具" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path (Join-Path $Root ".git"))) {
        throw "当前目录还不是 Git 仓库，请先运行 git init。"
    }

    function Get-RemoteUrlSafe([string]$name) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $out = & git remote get-url $name 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1).Trim() }
            return ""
        } finally {
            $ErrorActionPreference = $prev
        }
    }

    $curGh = Get-RemoteUrlSafe "github"
    $curGe = Get-RemoteUrlSafe "gitee"

    if (-not $GitHubUrl -and -not $ConfigureOnly) {
        if ($curGh) {
            Write-Host "当前 GitHub 地址: $curGh" -ForegroundColor Green
            $inGh = Read-Host "直接回车保持不变，或输入新的 GitHub 仓库 HTTPS/SSH 地址"
            $GitHubUrl = if ($inGh) { $inGh.Trim() } else { $curGh }
        } else {
            $GitHubUrl = (Read-Host "请输入你的 GitHub 仓库地址（例如 https://github.com/你的用户名/kr-fl-mp-mod.git，暂不填请回车）").Trim()
        }
    }

    if (-not $GiteeUrl -and -not $ConfigureOnly) {
        if ($curGe) {
            Write-Host "当前 Gitee 地址 : $curGe" -ForegroundColor Green
            $inGe = Read-Host "直接回车保持不变，或输入新的 Gitee 仓库 HTTPS/SSH 地址"
            $GiteeUrl = if ($inGe) { $inGe.Trim() } else { $curGe }
        } else {
            $GiteeUrl = (Read-Host "请输入你的 Gitee 仓库地址（例如 https://gitee.com/你的用户名/kr-fl-mp-mod.git，暂不填请回车）").Trim()
        }
    }

    function Parse-OwnerRepo([string]$url) {
        if ($url -match "(?:github\.com|gitee\.com)[:/]([^/]+)/([^/\.]+)(?:\.git)?/?$") {
            return @{ owner = $Matches[1]; repo = $Matches[2] }
        }
        return $null
    }

    $ghInfo = if ($GitHubUrl) { Parse-OwnerRepo $GitHubUrl } else { $null }
    $geInfo = if ($GiteeUrl) { Parse-OwnerRepo $GiteeUrl } else { $null }

    if ($GitHubUrl) {
        if ($curGh) { & git remote set-url github $GitHubUrl } else { & git remote add github $GitHubUrl }
        $hasOrigin = Get-RemoteUrlSafe "origin"
        if ($hasOrigin) { & git remote set-url origin $GitHubUrl } else { & git remote add origin $GitHubUrl }
        Write-Host "[配置] GitHub 远端已设置为: $GitHubUrl" -ForegroundColor Green
    }
    if ($GiteeUrl) {
        if ($curGe) { & git remote set-url gitee $GiteeUrl } else { & git remote add gitee $GiteeUrl }
        Write-Host "[配置] Gitee  远端已设置为: $GiteeUrl" -ForegroundColor Green
    }

    # Auto-wire live version.json & updater.lua URLs if repo coordinates were parsed!
    if ($ghInfo -or $geInfo) {
        $verPath = Join-Path $Root "version.json"
        $vObj = Get-Content $verPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $geRaw = ""
        $ghRaw = ""
        if ($geInfo) {
            $vObj.download_gitee = "https://gitee.com/$($geInfo.owner)/$($geInfo.repo)/releases"
            $geRaw = "https://gitee.com/$($geInfo.owner)/$($geInfo.repo)/raw/main/version.json"
        }
        if ($ghInfo) {
            $vObj.download_github = "https://github.com/$($ghInfo.owner)/$($ghInfo.repo)/releases"
            $ghRaw = "https://raw.githubusercontent.com/$($ghInfo.owner)/$($ghInfo.repo)/main/version.json"
        }
        [System.IO.File]::WriteAllText($verPath, ($vObj | ConvertTo-Json -Depth 4) + "`n", (New-Object System.Text.UTF8Encoding($false)))

        $updPath = Join-Path $Root "client\kr_mp\updater.lua"
        if (Test-Path $updPath) {
            $updText = Get-Content $updPath -Raw -Encoding UTF8
            if ($geRaw) {
                $updText = $updText -replace 'GITEE_VERSION_URL\s*=\s*"[^"]*"', ('GITEE_VERSION_URL = "' + $geRaw + '"')
                $updText = $updText -replace 'DEFAULT_DOWNLOAD_GITEE\s*=\s*"[^"]*"', ('DEFAULT_DOWNLOAD_GITEE = "' + $vObj.download_gitee + '"')
            }
            if ($ghRaw) {
                $updText = $updText -replace 'GITHUB_VERSION_URL\s*=\s*"[^"]*"', ('GITHUB_VERSION_URL = "' + $ghRaw + '"')
                $updText = $updText -replace 'DEFAULT_DOWNLOAD_GITHUB\s*=\s*"[^"]*"', ('DEFAULT_DOWNLOAD_GITHUB = "' + $vObj.download_github + '"')
            }
            [System.IO.File]::WriteAllText($updPath, $updText, (New-Object System.Text.UTF8Encoding($false)))
            & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\generate_manifest.ps1") -Root $Root
            Write-Host "[同步] 已自动将 Gitee/GitHub 线上更新地址写入 version.json 与 client/kr_mp/updater.lua！" -ForegroundColor Green
        }
    }

    if ($Push -or (-not $ConfigureOnly -and ($GitHubUrl -or $GiteeUrl))) {
        $doPush = $Push.IsPresent
        if (-not $doPush) {
            $ans = Read-Host "是否立刻推送 main 分支与标签到已配置的平台？(Y/n)"
            if ($ans -eq "" -or $ans -match "^[Yy]$") { $doPush = $true }
        }
        if ($doPush) {
            # Commit updated repo URLs if dirty
            $dirty = & git status --porcelain -- version.json client/kr_mp/updater.lua client/kr_mp/manifest.json
            if ($dirty) {
                & git add version.json client/kr_mp/updater.lua client/kr_mp/manifest.json
                & git commit -m "chore: configure GitHub and Gitee update URLs"
            }
            if ($GitHubUrl) {
                Write-Host "[推送] 正在推送到 GitHub (main + tags)..." -ForegroundColor Cyan
                & git push -u github main --tags
            }
            if ($GiteeUrl) {
                Write-Host "[推送] 正在推送到 Gitee (main + tags)..." -ForegroundColor Cyan
                & git push -u gitee main --tags
            }
            Write-Host "[完成] 双平台代码同步完成！别忘了重新运行 package_release.ps1 把带更新地址的压缩包上传到 Releases！" -ForegroundColor Green
        }
    }
} finally {
    Pop-Location
}
