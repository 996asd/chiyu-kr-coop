param(
    [string]$Version = "1.0.0"
)

$ErrorActionPreference = "Stop"
$Root = "D:\kr-mp-mod"
$DistDir = Join-Path $Root "dist"
$StageClient = Join-Path $DistDir "_stage_client"
$StageFull = Join-Path $DistDir "_stage_full"

# Ensure official file checksum manifest is fresh before packaging
& powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\generate_manifest.ps1") -Root $Root

# Ensure Go binaries are up-to-date
if (-not (Test-Path (Join-Path $Root "server\kr-mp-server.exe")) -or -not (Test-Path (Join-Path $Root "server\kr-mp-server-linux-amd64"))) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $Root "tools\build_server.ps1") -Linux
}

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
Remove-Item $StageClient, $StageFull -Recurse -Force -ErrorAction SilentlyContinue

function Populate-BasePackage([string]$dest) {
    New-Item -ItemType Directory -Force -Path (Join-Path $dest "patch\kr_mp") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dest "tools") | Out-Null

    Copy-Item (Join-Path $Root "client\UH.lua") (Join-Path $dest "patch\UH.lua") -Force
    Copy-Item (Join-Path $Root "client\kr_mp\*.lua") (Join-Path $dest "patch\kr_mp\") -Force
    Copy-Item (Join-Path $Root "client\kr_mp\manifest.json") (Join-Path $dest "patch\kr_mp\manifest.json") -Force
    Copy-Item (Join-Path $Root "tools\install_patch.ps1") (Join-Path $dest "tools\install_patch.ps1") -Force
    Copy-Item (Join-Path $Root "tools\uninstall_patch.ps1") (Join-Path $dest "tools\uninstall_patch.ps1") -Force
    Copy-Item (Join-Path $Root "tools\collect_bug_report.ps1") (Join-Path $dest "tools\collect_bug_report.ps1") -Force
    Copy-Item (Join-Path $Root "tools\export_my_fix.ps1") (Join-Path $dest "tools\export_my_fix.ps1") -Force
    Copy-Item (Join-Path $Root "README.md") (Join-Path $dest "联机使用与自建服说明书.md") -Force
    Copy-Item (Join-Path $Root "AI修复指南.md") (Join-Path $dest "AI修复指南.md") -Force
    Copy-Item (Join-Path $Root "AGENTS.md") (Join-Path $dest "AGENTS.md") -Force
    if (Test-Path (Join-Path $Root "LICENSE")) {
        Copy-Item (Join-Path $Root "LICENSE") (Join-Path $dest "LICENSE") -Force
    }

    $installBat = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tools\install_patch.ps1"
pause
"@
    $uninstallBat = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tools\uninstall_patch.ps1"
pause
"@
    $bugBat = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tools\collect_bug_report.ps1"
pause
"@
    $exportBat = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tools\export_my_fix.ps1"
pause
"@
    [System.IO.File]::WriteAllText((Join-Path $dest "一键安装联机补丁.bat"), $installBat, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $dest "一键卸载联机补丁.bat"), $uninstallBat, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $dest "一键收集报错包.bat"), $bugBat, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $dest "一键导出我的修改.bat"), $exportBat, (New-Object System.Text.UTF8Encoding($false)))
}

# 1. Lightweight Client-Only Patch Zip (~70 KB!)
Populate-BasePackage $StageClient
$ClientZip = Join-Path $DistDir "KR-MP-FL4.1.0-v$Version-客户端轻量补丁包.zip"
Remove-Item $ClientZip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $StageClient "*") -DestinationPath $ClientZip -CompressionLevel Optimal

# 2. Full Package Zip (Client Patch + Windows/Linux Go Relay Server)
Populate-BasePackage $StageFull
$SrvDest = Join-Path $StageFull "server"
New-Item -ItemType Directory -Force -Path $SrvDest | Out-Null
Copy-Item (Join-Path $Root "server\kr-mp-server.exe") (Join-Path $SrvDest "kr-mp-server.exe") -Force
Copy-Item (Join-Path $Root "server\kr-mp-server-linux-amd64") (Join-Path $SrvDest "kr-mp-server-linux-amd64") -Force

$srvBat = @"
@echo off
chcp 65001 >nul
title KR-MP 公网大厅与帧中继服务端 (TCP :17780)
cd /d "%~dp0"
echo [KR-MP] 启动 Go 公网中继服：TCP :17780 | 状态监控 :17781/health | 断线重连保留 300 秒
echo [KR-MP] 按 Ctrl+C 停止服务。
kr-mp-server.exe -addr :17780 -http :17781 -grace 300
pause
"@
[System.IO.File]::WriteAllText((Join-Path $SrvDest "启动公网中继服.bat"), $srvBat, (New-Object System.Text.UTF8Encoding($false)))

$FullZip = Join-Path $DistDir "KR-MP-FL4.1.0-v$Version-完整联机与服务端包.zip"
Remove-Item $FullZip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $StageFull "*") -DestinationPath $FullZip -CompressionLevel Optimal

Remove-Item $StageClient, $StageFull -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=== M3 Release Packages Built ===" -ForegroundColor Green
Get-Item $ClientZip, $FullZip | Select-Object Name, @{N='SizeKB';E={[math]::Round($_.Length/1KB, 1)}}, LastWriteTime
