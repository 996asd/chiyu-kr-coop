param(
    [string]$TargetDir = "",
    [string]$OutputDir = "",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PkgRoot = Split-Path -Parent $ScriptRoot

function Find-DefaultGameDir {
    $candidates = @(
        (Get-Location).Path,
        $PkgRoot,
        (Join-Path $PkgRoot "game-sandbox"),
        "D:\kr\Kingdom Rush Alliance",
        "C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Alliance",
        "D:\SteamLibrary\steamapps\common\Kingdom Rush Alliance"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c "Kingdom Rush FL_Alliance-FL4.1.0.exe")) -and (Test-Path (Join-Path $c "kr_mp"))) {
            return $c
        }
    }
    return ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  KR-MP 一键收集报错与不同步诊断包" -ForegroundColor Yellow
Write-Host "  打包后可直接发给群里，或连同提问词一起喂给 AI 排错！" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetDir) {
    $detected = Find-DefaultGameDir
    if (-not $Silent) {
        if ($detected) {
            Write-Host "检测到已安装联机补丁的游戏目录: $detected" -ForegroundColor Green
            $ans = Read-Host "是否收集此目录的日志？直接回车确认，或输入其他 FL 4.1.0 游戏目录路径"
            if ($ans -eq "" -or $ans -match "^[Yy]$") {
                $TargetDir = $detected
            } else {
                $TargetDir = $ans.Trim('"').Trim()
            }
        } else {
            Write-Host "请选择你的 FL 4.1.0 游戏目录（含 Kingdom Rush FL_Alliance-FL4.1.0.exe）..." -ForegroundColor Yellow
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "请选择已安装 KR-MP 补丁的 FL 4.1.0 游戏目录"
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
    Write-Host "[错误] 未找到目标游戏目录: $TargetDir" -ForegroundColor Red
    exit 1
}

if (-not $OutputDir) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ($desktop -and (Test-Path $desktop)) {
        $OutputDir = $desktop
    } else {
        $OutputDir = $PkgRoot
    }
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$stage = Join-Path $env:TEMP ("kr_mp_bug_" + $stamp)
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$logsOut = Join-Path $stage "logs"
New-Item -ItemType Directory -Force -Path $logsOut | Out-Null

# 1. Collect game-directory logs, hashes, and last session
$logNames = @("kr_mp.log", "kr_mp_prev.log", "kr_mp_hashes.log", "kr_mp_last_session.json")
$collectedLogs = @()
foreach ($ln in $logNames) {
    $src = Join-Path $TargetDir $ln
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $logsOut $ln) -Force
        $collectedLogs += $ln
    }
}

# Also check repo logs/ if running inside dev workspace
$repoLogs = Join-Path $PkgRoot "logs"
if (Test-Path $repoLogs) {
    $recentRepoLogs = Get-ChildItem $repoLogs -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 6
    foreach ($rf in $recentRepoLogs) {
        Copy-Item $rf.FullName (Join-Path $logsOut ("dev_" + $rf.Name)) -Force
        $collectedLogs += ("dev_" + $rf.Name)
    }
}

# 2. Inspect installed files vs manifest.json
$manifestPath = Join-Path $TargetDir "kr_mp\manifest.json"
if (-not (Test-Path $manifestPath)) {
    $fallbackM = Join-Path $PkgRoot "patch\kr_mp\manifest.json"
    if (Test-Path $fallbackM) { $manifestPath = $fallbackM }
}

$modVer = "未知"
$fileReport = New-Object System.Collections.Generic.List[string]
$modifiedFiles = New-Object System.Collections.Generic.List[string]

if (Test-Path $manifestPath) {
    $mf = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $modVer = [string]$mf.version
    $mf.files.PSObject.Properties | ForEach-Object {
        $rel = $_.Name
        $expected = ([string]$_.Value).ToUpper()
        $localPath = Join-Path $TargetDir ($rel -replace "/", "\")
        if (-not (Test-Path $localPath)) {
            $fileReport.Add("  [缺失] $rel")
            $modifiedFiles.Add($rel)
        } else {
            $actual = (Get-FileHash $localPath -Algorithm SHA256).Hash.ToUpper()
            if ($actual -eq $expected) {
                $fileReport.Add("  [官方原版] $rel")
            } else {
                $fileReport.Add("  [已本地修改] $rel (SHA256=$($actual.Substring(0,12))...)")
                $modifiedFiles.Add($rel)
            }
        }
    }
    # Check extra custom lua files
    $localKrMp = Join-Path $TargetDir "kr_mp"
    if (Test-Path $localKrMp) {
        Get-ChildItem (Join-Path $localKrMp "*.lua") -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = "kr_mp/$($_.Name)"
            if (-not $mf.files.PSObject.Properties[$rel]) {
                $fileReport.Add("  [新增文件] $rel")
                $modifiedFiles.Add($rel)
            }
        }
    }
} else {
    $fileReport.Add("  (未找到 manifest.json，无法比对文件校验值)")
}

# 3. Auto-scan logs for crash / desync clues
$detectedIssue = "未在日志中自动检测到明显崩溃或分叉关键字（可能是网络连不上、界面异常或还未触发）"
$clueLines = New-Object System.Collections.Generic.List[string]

foreach ($scanName in @("kr_mp.log", "kr_mp_prev.log")) {
    $p = Join-Path $logsOut $scanName
    if (Test-Path $p) {
        $lines = Get-Content $p -Encoding UTF8 -ErrorAction SilentlyContinue
        $crashIdx = -1
        $desyncIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "LUA CRASH") { $crashIdx = $i }
            if ($lines[$i] -match "DESYNC") { $desyncIdx = $i }
        }
        if ($crashIdx -ge 0) {
            $detectedIssue = "检测到 Lua 崩溃堆栈（来源：$scanName）"
            $end = [Math]::Min($lines.Count - 1, $crashIdx + 25)
            $clueLines.Add("=== [$scanName] LUA CRASH 摘录 ===")
            for ($k = $crashIdx; $k -le $end; $k++) { $clueLines.Add($lines[$k]) }
            break
        } elseif ($desyncIdx -ge 0) {
            $detectedIssue = "检测到联机不同步 DESYNC（来源：$scanName）"
            $start = [Math]::Max(0, $desyncIdx - 12)
            $end = [Math]::Min($lines.Count - 1, $desyncIdx + 8)
            $clueLines.Add("=== [$scanName] DESYNC 上下文摘录 ===")
            for ($k = $start; $k -le $end; $k++) { $clueLines.Add($lines[$k]) }
            break
        }
    }
}

# 4. Write diagnostic summary & ready-to-paste AI prompt
$hasExe = Test-Path (Join-Path $TargetDir "Kingdom Rush FL_Alliance-FL4.1.0.exe")
$diagText = @"
=== KR-MP 联机环境与文件体检报告 ===
生成时间: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
游戏目录: $TargetDir
FL 4.1.0 主程序存在: $hasExe
已安装补丁版本: v$modVer
操作系统: $([System.Environment]::OSVersion.VersionString)
已收集日志文件: $(if ($collectedLogs.Count -gt 0) { $collectedLogs -join ", " } else { "(无)" })
自动诊断结论: $detectedIssue

--- 本地补丁文件核对 ---
$($fileReport -join "`r`n")

$($clueLines -join "`r`n")
"@
[System.IO.File]::WriteAllText((Join-Path $stage "环境与文件体检.txt"), $diagText, (New-Object System.Text.UTF8Encoding($false)))

$aiPrompt = @"
我在玩《王国保卫战 FL 4.1.0》的 KR-MP 双人联机 MOD（版本 v$modVer）时遇到了问题，请帮我分析原因并给出最小、安全的 Lua/Go 修复方案。

【自动检测结论】
$detectedIssue

【我遇到的问题描述（请补充你当时的操作，比如选了第几关、哪两个英雄、做了什么动作）】
（在这里补充 1~2 句话即可，例如：选了 3代第10关，打到第3波放技能时提示不同步）

【已附带的日志与体检文件】
请先阅读压缩包里的：
1. 环境与文件体检.txt
2. logs/kr_mp.log（以及如有 logs/kr_mp_prev.log、logs/kr_mp_hashes.log）
3. 项目根目录的 AGENTS.md 或 AI修复指南.md

【请严格遵守以下 4 条修改红线】
1. 绝不修改原版 FL 4.1.0 游戏 .exe 或素材，只改 UH.lua / kr_mp/*.lua / server/*.go。
2. 绝不破坏 60Hz 确定性帧同步：战斗内严禁原生 math.random、无序 pairs()、系统时间驱动；纯视觉随机必须包在 prng:enter_visual()/exit_visual() 内。
3. 纯本地 UI 预览实体必须标记 _kr_mp_local = true 并走 LOCAL_ID_BASE，绝不污染仿真 ID。
4. 请明确告诉我需要修改哪几个文件、改哪里，改完我测试没问题后会用「一键导出我的修改.bat」分享回群里！
"@
[System.IO.File]::WriteAllText((Join-Path $stage "复制给AI的提问词.txt"), $aiPrompt, (New-Object System.Text.UTF8Encoding($false)))

# Copy AI guide into zip if present
foreach ($guideCand in @((Join-Path $PkgRoot "AI修复指南.md"), (Join-Path $PkgRoot "AGENTS.md"))) {
    if (Test-Path $guideCand) {
        Copy-Item $guideCand $stage -Force
    }
}

$zipPath = Join-Path $OutputDir ("KR-MP-报错诊断包-" + $stamp + ".zip")
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[成功] 报错诊断包已生成！" -ForegroundColor Green
Write-Host "  文件路径: $zipPath" -ForegroundColor Cyan
Write-Host "  自动诊断: $detectedIssue" -ForegroundColor Yellow
Write-Host "  已含日志: $(if ($collectedLogs.Count -gt 0) { $collectedLogs -join ', ' } else { '无（请先运行一次联机版）' })" -ForegroundColor White
Write-Host ""
Write-Host "下一步：把该压缩包直接发群里，或解压把「复制给AI的提问词.txt」+ 日志喂给 AI 即可排错！" -ForegroundColor Green

if (-not $Silent) {
    try { Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`"" } catch {}
}
exit 0
