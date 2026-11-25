param(
    [string]$TargetDir = "",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PkgRoot = Split-Path -Parent $ScriptRoot
$PatchDir = Join-Path $PkgRoot "patch"
if (-not (Test-Path (Join-Path $PatchDir "UH.lua"))) {
    # Fallback when run directly inside D:\kr-mp-mod\tools
    $PatchDir = Join-Path $PkgRoot "client"
}

function Find-DefaultGameDir {
    $candidates = @(
        (Get-Location).Path,
        "D:\kr\Kingdom Rush Alliance",
        "C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Alliance",
        "D:\SteamLibrary\steamapps\common\Kingdom Rush Alliance",
        "D:\kr-mp-mod\game-sandbox"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "Kingdom Rush FL_Alliance-FL4.1.0.exe"))) {
            return $c
        }
    }
    return ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  王国保卫战 FL 4.1.0 联机 MOD (KR-MP v1.0.0) 一键安装程序" -ForegroundColor Yellow
Write-Host "  零侵入外挂补丁架构：绝不修改原版 1.5GB 游戏主程序 .exe" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetDir) {
    $detected = Find-DefaultGameDir
    if (-not $Silent) {
        if ($detected) {
            Write-Host "检测到疑似游戏目录: $detected" -ForegroundColor Green
            $useDet = Read-Host "是否安装到此目录？输入 Y 确认，或直接输入/拖入其他 FL 4.1.0 游戏目录路径"
            if ($useDet -eq "" -or $useDet -match "^[Yy]$") {
                $TargetDir = $detected
            } else {
                $TargetDir = $useDet.Trim('"').Trim()
            }
        } else {
            Write-Host "请在弹出的文件夹选择框中选择包含 Kingdom Rush FL_Alliance-FL4.1.0.exe 的游戏目录..." -ForegroundColor Yellow
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "请选择王国保卫战 FL 4.1.0 游戏目录（含 Kingdom Rush FL_Alliance-FL4.1.0.exe）"
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $TargetDir = $dlg.SelectedPath
                }
            } catch {}
            if (-not $TargetDir) {
                $TargetDir = (Read-Host "请粘贴或拖入 FL 4.1.0 游戏目录路径").Trim('"').Trim()
            }
        }
    } else {
        $TargetDir = $detected
    }
}

if (-not $TargetDir -or -not (Test-Path $TargetDir)) {
    Write-Host "[错误] 未找到目标目录: $TargetDir" -ForegroundColor Red
    exit 1
}

$ExeFile = Join-Path $TargetDir "Kingdom Rush FL_Alliance-FL4.1.0.exe"
if (-not (Test-Path $ExeFile)) {
    Write-Host "[错误] 目标目录中未找到 Kingdom Rush FL_Alliance-FL4.1.0.exe！" -ForegroundColor Red
    Write-Host "请确认你选择的是 FL 4.1.0 的实际游戏目录（解压后的 exe 所在文件夹）。" -ForegroundColor Yellow
    exit 1
}

# 安全备份原有的第三方 UH.lua（若存在且不是 KR-MP 自身的 UH.lua）
$TargetUH = Join-Path $TargetDir "UH.lua"
$BackupUH = Join-Path $TargetDir "UH.lua.kr_mp_backup"
if (Test-Path $TargetUH) {
    $existing = Get-Content $TargetUH -Raw -ErrorAction SilentlyContinue
    if ($existing -and ($existing -notmatch "kr_mp\.boot") -and (-not (Test-Path $BackupUH))) {
        Copy-Item $TargetUH $BackupUH -Force
        Write-Host "[备份] 已将原有 UH.lua 备份为 UH.lua.kr_mp_backup" -ForegroundColor Yellow
    }
}

# 复制轻量化外挂补丁（仅 UH.lua + kr_mp/）
Copy-Item (Join-Path $PatchDir "UH.lua") $TargetUH -Force
$TargetKrMp = Join-Path $TargetDir "kr_mp"
New-Item -ItemType Directory -Force -Path $TargetKrMp | Out-Null
Copy-Item (Join-Path $PatchDir "kr_mp\*") $TargetKrMp -Recurse -Force

# 在游戏目录下生成锁定 60 FPS 的便捷联机启动器
$LauncherPath = Join-Path $TargetDir "启动联机版_FL4.1.0.bat"
$LauncherContent = @"
@echo off
cd /d "%~dp0"
start "" "Kingdom Rush FL_Alliance-FL4.1.0.exe" -fps 60
"@
[System.IO.File]::WriteAllText($LauncherPath, $LauncherContent, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "[成功] KR-MP v1.0.0 联机补丁安装完成！" -ForegroundColor Green
Write-Host "  已写入: $TargetUH"
Write-Host "  已写入: $TargetKrMp\ (全部联机模块)"
Write-Host "  已生成: $LauncherPath"
Write-Host ""
Write-Host "使用方法：双击游戏目录里的【启动联机版_FL4.1.0.bat】，进游戏按 F10 或点左上角【联机大厅】即可开黑！" -ForegroundColor Cyan
exit 0
