param(
    [string]$TargetDir = "",
    [string]$OutputDir = "",
    [string]$Note = "",
    [string]$Author = "",
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
        if ($c -and (Test-Path (Join-Path $c "UH.lua")) -and (Test-Path (Join-Path $c "kr_mp\manifest.json"))) {
            return $c
        }
    }
    return ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  KR-MP 一键导出我的修改（群友投稿修复专用）" -ForegroundColor Yellow
Write-Host "  自动对比官方清单，只打包你改过的 Lua 文件，直接发群里即可！" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetDir) {
    $detected = Find-DefaultGameDir
    if (-not $Silent) {
        if ($detected) {
            Write-Host "检测到已安装联机补丁的目录: $detected" -ForegroundColor Green
            $ans = Read-Host "是否从此目录导出你的修改？回车确认，或输入你的 FL 4.1.0 游戏目录路径"
            if ($ans -eq "" -or $ans -match "^[Yy]$") {
                $TargetDir = $detected
            } else {
                $TargetDir = $ans.Trim('"').Trim()
            }
        } else {
            Write-Host "请选择你修改过的 FL 4.1.0 游戏目录（含 UH.lua 与 kr_mp\）..." -ForegroundColor Yellow
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "请选择你修改了联机脚本的 FL 4.1.0 游戏目录"
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $TargetDir = $dlg.SelectedPath
                }
            } catch {}
            if (-not $TargetDir) {
                $TargetDir = (Read-Host "请粘贴或拖入游戏目录路径").Trim('"').Trim()
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

$manifestPath = Join-Path $TargetDir "kr_mp\manifest.json"
if (-not (Test-Path $manifestPath)) {
    $fallback = Join-Path $PkgRoot "patch\kr_mp\manifest.json"
    if (Test-Path $fallback) { $manifestPath = $fallback }
}
if (-not (Test-Path $manifestPath)) {
    Write-Host "[错误] 未找到官方校验清单 manifest.json，请先安装最新版联机补丁。" -ForegroundColor Red
    exit 1
}

$mf = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseVer = [string]$mf.version
$changed = New-Object System.Collections.Generic.List[object]

# Check modified files
$mf.files.PSObject.Properties | ForEach-Object {
    $rel = $_.Name
    $expected = ([string]$_.Value).ToUpper()
    $localPath = Join-Path $TargetDir ($rel -replace "/", "\")
    if (Test-Path $localPath) {
        $actual = (Get-FileHash $localPath -Algorithm SHA256).Hash.ToUpper()
        if ($actual -ne $expected) {
            $changed.Add([PSCustomObject]@{
                status = "MODIFIED"
                rel = $rel
                local_path = $localPath
                sha256 = $actual
                size = (Get-Item $localPath).Length
            })
        }
    }
}

# Check newly added .lua files inside kr_mp/
$localKrMp = Join-Path $TargetDir "kr_mp"
if (Test-Path $localKrMp) {
    Get-ChildItem (Join-Path $localKrMp "*.lua") -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = "kr_mp/$($_.Name)"
        if (-not $mf.files.PSObject.Properties[$rel]) {
            $changed.Add([PSCustomObject]@{
                status = "ADDED"
                rel = $rel
                local_path = $_.FullName
                sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToUpper()
                size = $_.Length
            })
        }
    }
}

if ($changed.Count -eq 0) {
    Write-Host "[提示] 你的 UH.lua 和 kr_mp\*.lua 与官方 v$baseVer 完全一致，没有检测到任何本地修改。" -ForegroundColor Yellow
    Write-Host "如果你刚用 AI 改完代码，请确认修改的是目录 [$TargetDir] 里的文件后再试。" -ForegroundColor White
    exit 0
}

Write-Host "检测到以下 $($changed.Count) 个修改/新增文件：" -ForegroundColor Green
foreach ($c in $changed) {
    Write-Host ("  [{0}] {1} ({2} 字节)" -f $c.status, $c.rel, $c.size) -ForegroundColor Cyan
}
Write-Host ""

if (-not $Silent) {
    if (-not $Note) {
        $Note = Read-Host "请输入一句修复说明（例如：修复第15关技能不同步，可直接回车跳过）"
    }
    if (-not $Author) {
        $Author = Read-Host "你的群昵称/署名（选填，可直接回车匿名）"
    }
}
if (-not $Note) { $Note = "群友 AI 修复提交（未填写说明）" }
if (-not $Author) { $Author = "热心群友" }

if (-not $OutputDir) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ($desktop -and (Test-Path $desktop)) { $OutputDir = $desktop } else { $OutputDir = $PkgRoot }
}
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$stage = Join-Path $env:TEMP ("kr_mp_fix_" + $stamp)
New-Item -ItemType Directory -Force -Path (Join-Path $stage "client\kr_mp") | Out-Null

$fileMetaList = @()
$mdList = @()
foreach ($c in $changed) {
    $destPath = Join-Path (Join-Path $stage "client") ($c.rel -replace "/", "\")
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destPath) | Out-Null
    Copy-Item $c.local_path $destPath -Force
    $fileMetaList += [ordered]@{
        status = $c.status
        path = "client/" + $c.rel
        sha256 = $c.sha256
        size = $c.size
    }
    $mdList += "- **$($c.status)** ``client/$($c.rel)`` ($($c.size) 字节)"
}

$meta = [ordered]@{
    format = "kr-mp-community-patch-v1"
    base_version = $baseVer
    created_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    author = $Author
    note = $Note
    files = $fileMetaList
}
[System.IO.File]::WriteAllText(
    (Join-Path $stage "patch_meta.json"),
    ($meta | ConvertTo-Json -Depth 5) + "`n",
    (New-Object System.Text.UTF8Encoding($false))
)

$readmeMd = @"
# KR-MP 群友修复补丁投稿

- **基于官方版本**：v$baseVer
- **提交者**：$Author
- **提交时间**：$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
- **修改说明**：$Note

## 包含的改动文件（共 $($changed.Count) 个）
$($mdList -join "`r`n")

## 维护者审核与合并方法
把本压缩包直接拖给仓库根目录的 **``测试并合并群友修复.bat``**（或运行 ``tools\apply_community_fix.ps1``），脚本会自动预览差异、备份原文件并跑双开同步回归测试！
"@
[System.IO.File]::WriteAllText((Join-Path $stage "修改说明.md"), $readmeMd, (New-Object System.Text.UTF8Encoding($false)))

$zipPath = Join-Path $OutputDir ("KR-MP-群友修复补丁-" + $stamp + ".zip")
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[成功] 精简修复补丁包已生成！" -ForegroundColor Green
Write-Host "  文件路径: $zipPath" -ForegroundColor Cyan
Write-Host "  下一步：直接把这个几十 KB 的压缩包发到群里，或传到 GitHub / Gitee Issue 即可！" -ForegroundColor Green

if (-not $Silent) {
    try { Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`"" } catch {}
}
exit 0
