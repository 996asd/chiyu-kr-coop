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

$TargetFlVersion = "8.2.0"
$PreferredExe = "Kingdom Rush FL_Alliance-FL8.1.0.exe"

# FL 8.2.0 launcher exe is named "...FL8.1.0.exe"; accept any "Kingdom Rush FL_Alliance*.exe" as fallback
function Get-FlExe([string]$dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return $null }
    $p = Join-Path $dir $PreferredExe
    if (Test-Path $p) { return (Get-Item $p) }
    return (Get-ChildItem -Path $dir -Filter "Kingdom Rush FL_Alliance*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-FlVersion([string]$dir) {
    $mg = Join-Path $dir "main_globals.lua"
    if (Test-Path $mg) {
        $m = Select-String -Path $mg -Pattern 'KR_FL_VERSION\s*=\s*"([^"]+)"' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return ""
}

function Find-DefaultGameDir {
    $candidates = @(
        (Get-Location).Path,
        "D:\FL8.2.0",
        "C:\FL8.2.0",
        "E:\FL8.2.0",
        "C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Alliance",
        "D:\SteamLibrary\steamapps\common\Kingdom Rush Alliance"
    )
    foreach ($c in $candidates) {
        if ($c -and (Get-FlExe $c)) {
            return $c
        }
    }
    return ""
}

$ModVer = "2.0.0"
$mfFile = Join-Path $PatchDir "kr_mp\manifest.json"
if (Test-Path $mfFile) {
    try { $ModVer = (Get-Content $mfFile -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  赤羽的王国保卫战联机器 FL $TargetFlVersion (KR-MP v$ModVer) 一键安装程序" -ForegroundColor Yellow
Write-Host "  零侵入外挂补丁架构：绝不修改原版游戏主程序与素材" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetDir) {
    $detected = Find-DefaultGameDir
    if (-not $Silent) {
        if ($detected) {
            Write-Host "检测到疑似游戏目录: $detected" -ForegroundColor Green
            $useDet = Read-Host "是否安装到此目录？输入 Y 确认，或直接输入/拖入其他 FL $TargetFlVersion 游戏目录路径"
            if ($useDet -eq "" -or $useDet -match "^[Yy]$") {
                $TargetDir = $detected
            } else {
                $TargetDir = $useDet.Trim('"').Trim()
            }
        } else {
            Write-Host "请在弹出的文件夹选择框中选择包含 $PreferredExe 的游戏目录..." -ForegroundColor Yellow
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "请选择王国保卫战 FL $TargetFlVersion 游戏目录（含 $PreferredExe）"
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $TargetDir = $dlg.SelectedPath
                }
            } catch {}
            if (-not $TargetDir) {
                $TargetDir = (Read-Host "请粘贴或拖入 FL $TargetFlVersion 游戏目录路径").Trim('"').Trim()
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

$ExeItem = Get-FlExe $TargetDir
if (-not $ExeItem) {
    Write-Host "[错误] 目标目录中未找到 $PreferredExe ！" -ForegroundColor Red
    Write-Host "请确认你选择的是 FL $TargetFlVersion 的实际游戏目录（解压后的 exe 所在文件夹）。" -ForegroundColor Yellow
    exit 1
}
$ExeName = $ExeItem.Name

$detVer = Get-FlVersion $TargetDir
if ($detVer -and $detVer -ne $TargetFlVersion) {
    Write-Host "[警告] 该目录的 FL 版本是 $detVer，本补丁只适配 FL $TargetFlVersion！双方版本不同会无法联机或不同步。" -ForegroundColor Red
    if (-not $Silent) {
        $go = Read-Host "仍要继续安装吗？(输入 Y 继续，其他键取消)"
        if ($go -notmatch "^[Yy]$") { exit 1 }
    }
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

# 复制轻量化外挂补丁（仅 UH.lua + kr_mp/，先清理旧版 kr_mp/ 避免残留或嵌套 assets）
Copy-Item (Join-Path $PatchDir "UH.lua") $TargetUH -Force
$TargetKrMp = Join-Path $TargetDir "kr_mp"
if (Test-Path $TargetKrMp) {
    Remove-Item $TargetKrMp -Recurse -Force
}
Copy-Item (Join-Path $PatchDir "kr_mp") $TargetKrMp -Recurse -Force

# 清理旧版 FL 4.1.0 启动器（若存在）
$OldLauncher = Join-Path $TargetDir "启动联机版_FL4.1.0.bat"
if (Test-Path $OldLauncher) { Remove-Item $OldLauncher -Force }

# 在游戏目录下生成锁定 60 FPS 的便捷联机启动器
$LauncherPath = Join-Path $TargetDir "启动联机版_FL8.2.0.bat"
$LauncherContent = @"
@echo off
cd /d "%~dp0"
start "" "$ExeName" -fps 60
"@
[System.IO.File]::WriteAllText($LauncherPath, $LauncherContent, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "[成功] KR-MP v$ModVer 联机补丁安装完成！" -ForegroundColor Green
Write-Host "  已写入: $TargetUH"
Write-Host "  已写入: $TargetKrMp\ (全部联机模块)"
Write-Host "  已生成: $LauncherPath"
Write-Host ""
Write-Host "使用方法：双击游戏目录里的【启动联机版_FL8.2.0.bat】，进游戏按 F10 或点左上角【联机大厅】即可开黑！" -ForegroundColor Cyan
exit 0
