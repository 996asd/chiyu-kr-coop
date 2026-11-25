param(
    [string]$PatchZip = "",
    [switch]$AutoApply,
    [switch]$RunTests
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  KR-MP 维护者工具：安全预览、应用并测试群友修复补丁" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $PatchZip) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = "选择群友提交的 KR-MP-群友修复补丁-*.zip"
        $dlg.Filter = "KR-MP 修复补丁 (*.zip)|*.zip"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $PatchZip = $dlg.FileName
        }
    } catch {}
    if (-not $PatchZip) {
        $PatchZip = (Read-Host "请拖入或粘贴群友修复补丁 .zip 路径").Trim('"').Trim()
    }
}

if (-not $PatchZip -or -not (Test-Path $PatchZip)) {
    Write-Host "[错误] 找不到补丁压缩包: $PatchZip" -ForegroundColor Red
    exit 1
}

$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$tmp = Join-Path $env:TEMP ("kr_mp_apply_" + $stamp)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    Expand-Archive -Path $PatchZip -DestinationPath $tmp -Force

    $metaPath = Join-Path $tmp "patch_meta.json"
    if (-not (Test-Path $metaPath)) {
        throw "压缩包内缺少 patch_meta.json，不是合法的 KR-MP 群友修复补丁！"
    }
    $meta = Get-Content $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "补丁信息：" -ForegroundColor Green
    Write-Host "  提交者  : $($meta.author)"
    Write-Host "  基于版本: v$($meta.base_version)"
    Write-Host "  修改说明: $($meta.note)"
    Write-Host "  提交时间: $($meta.created_at)"
    Write-Host ""

    # Strict security allowlist: ONLY client/UH.lua or client/kr_mp/*.lua!
    $srcClient = Join-Path $tmp "client"
    if (-not (Test-Path $srcClient)) {
        throw "压缩包内缺少 client/ 目录！"
    }
    $stagedFiles = Get-ChildItem $srcClient -Recurse -File
    if ($stagedFiles.Count -eq 0) {
        throw "补丁包内没有任何可应用的文件！"
    }

    $approved = New-Object System.Collections.Generic.List[object]
    foreach ($sf in $stagedFiles) {
        $rel = $sf.FullName.Substring($srcClient.Length + 1) -replace "\\", "/"
        if ($rel -match "\.\." -or ($rel -ne "UH.lua" -and $rel -notmatch "^kr_mp/[A-Za-z0-9_\-]+\.lua$")) {
            throw "[安全拦截] 检测到非法的补丁文件路径：$rel（仅允许 UH.lua 或 kr_mp/*.lua！）"
        }
        $approved.Add([PSCustomObject]@{
            rel = $rel
            src = $sf.FullName
            dst = Join-Path (Join-Path $Root "client") ($rel -replace "/", "\")
        })
        Write-Host "  [安全通过] client/$rel ($($sf.Length) 字节)" -ForegroundColor Cyan
    }

    if (-not $AutoApply) {
        Write-Host ""
        $confirm = Read-Host "确认备份当前 client/ 并应用以上 $($approved.Count) 个文件？(输入 Y 确认，其他键取消)"
        if ($confirm -notmatch "^[Yy]$") {
            Write-Host "已取消应用。" -ForegroundColor Yellow
            exit 0
        }
    }

    # Backup current client/
    $bakDir = Join-Path $Root ("logs\backup_client_" + $stamp)
    New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
    Copy-Item (Join-Path $Root "client\*") $bakDir -Recurse -Force
    Write-Host "[备份] 已备份原 client/ -> $bakDir" -ForegroundColor Yellow

    foreach ($item in $approved) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $item.dst) | Out-Null
        Copy-Item $item.src $item.dst -Force
        Write-Host "[写入] client/$($item.rel)" -ForegroundColor Green
    }

    # Show git diff summary if inside git repo
    if (Test-Path (Join-Path $Root ".git")) {
        Write-Host ""
        Write-Host "=== 代码改动概览 (git diff --stat) ===" -ForegroundColor Cyan
        Push-Location $Root
        try { & git diff --stat -- client/ } finally { Pop-Location }
    }

    & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\generate_manifest.ps1") -Root $Root
    if (Test-Path (Join-Path $Root "game-sandbox")) {
        & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\sync_client.ps1")
    }

    $doTests = $RunTests.IsPresent
    if (-not $AutoApply -and -not $doTests -and (Test-Path (Join-Path $Root "game-sandbox\Kingdom Rush FL_Alliance-FL4.1.0.exe"))) {
        $tAns = Read-Host "是否立刻运行 M1+M2 双开确定性同步回归测试以验收此修复？(Y/n)"
        if ($tAns -eq "" -or $tAns -match "^[Yy]$") { $doTests = $true }
    }

    if ($doTests) {
        Write-Host ""
        Write-Host "=== 正在运行 M2 公网追帧重连 + M1 局域网同步回归测试 ===" -ForegroundColor Yellow
        & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\run_m2_test.ps1")
        if ($LASTEXITCODE -ne 0) { throw "M2 同步回归测试未通过！请检查改动或从 [$bakDir] 恢复。" }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\run_m1_dual.ps1") -AutoCoopTest
        if ($LASTEXITCODE -ne 0) { throw "M1 同步回归测试未通过！请检查改动或从 [$bakDir] 恢复。" }
        Write-Host "[通过] 群友修复已通过全部同步测试！可以提交并运行 package_release.ps1 发布新版！" -ForegroundColor Green
    } else {
        Write-Host "[完成] 补丁已应用并更新 manifest.json。如需回退，原文件备份在: $bakDir" -ForegroundColor Green
    }
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
