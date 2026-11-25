param(
    [string]$TargetDir = "",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  王国保卫战 FL 8.2.0 联机 MOD (KR-MP) 一键卸载程序" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetDir -and -not $Silent) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "请选择已安装联机补丁的 FL 8.2.0 游戏目录"
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $TargetDir = $dlg.SelectedPath
        }
    } catch {}
    if (-not $TargetDir) {
        $TargetDir = (Read-Host "请输入已安装补丁的 FL 8.2.0 游戏目录路径").Trim('"').Trim()
    }
}

if (-not $TargetDir -or -not (Test-Path $TargetDir)) {
    Write-Host "[错误] 未找到目标目录: $TargetDir" -ForegroundColor Red
    exit 1
}

$TargetUH = Join-Path $TargetDir "UH.lua"
$BackupUH = Join-Path $TargetDir "UH.lua.kr_mp_backup"
$TargetKrMp = Join-Path $TargetDir "kr_mp"

if (Test-Path $TargetKrMp) {
    Remove-Item $TargetKrMp -Recurse -Force
    Write-Host "[清理] 已删除 kr_mp\" -ForegroundColor Green
}

if (Test-Path $BackupUH) {
    Move-Item $BackupUH $TargetUH -Force
    Write-Host "[恢复] 已从 UH.lua.kr_mp_backup 恢复你原本的 UH.lua" -ForegroundColor Yellow
} elseif (Test-Path $TargetUH) {
    $content = Get-Content $TargetUH -Raw -ErrorAction SilentlyContinue
    if ($content -match "kr_mp\.boot") {
        Remove-Item $TargetUH -Force
        Write-Host "[清理] 已删除联机引导文件 UH.lua" -ForegroundColor Green
    }
}

foreach ($ln in @("启动联机版_FL8.2.0.bat", "启动联机版_FL4.1.0.bat")) {
    $lp = Join-Path $TargetDir $ln
    if (Test-Path $lp) {
        Remove-Item $lp -Force
        Write-Host "[清理] 已删除 $ln" -ForegroundColor Green
    }
}

foreach ($extra in @("kr_mp.log", "kr_mp_prev.log", "kr_mp_hashes.log", "kr_mp_prefs.json")) {
    $ep = Join-Path $TargetDir $extra
    if (Test-Path $ep) { Remove-Item $ep -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "[完成] 联机补丁已彻底卸载，原版 FL 8.2.0 文件完好无损！" -ForegroundColor Green
exit 0
