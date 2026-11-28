param(
    [string]$ReportPath = "",
    [string]$GameDir = "D:\FL8.2.0",
    [int]$PlayerPid = 0,
    [int]$Speed = 30,
    [int]$StopTick = 0,
    [switch]$TraceAroundDesync,
    [switch]$AutoExit,
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

if (-not $ReportPath) {
    $reportsDir = Join-Path $GameDir "kr_mp_reports"
    if (Test-Path $reportsDir) {
        $newest = Get-ChildItem $reportsDir -Filter "*.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "_index.json" } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest) { $ReportPath = $newest.FullName }
    }
}

if (-not $ReportPath -or -not (Test-Path $ReportPath)) {
    Write-Host "[错误] 未找到黑匣子报告文件，请通过 -ReportPath 指定玩家发来的 .json 报错报告！" -ForegroundColor Red
    exit 1
}

$ReportPath = (Resolve-Path $ReportPath).Path
$rawJson = [System.IO.File]::ReadAllText($ReportPath, [System.Text.Encoding]::UTF8)
$doc = $rawJson | ConvertFrom-Json

if (-not $doc.blackbox -or -not $doc.blackbox.cfg) {
    Write-Host "[错误] 该报告中不包含可回放的黑匣子对局数据 (blackbox.cfg 缺失)。" -ForegroundColor Red
    exit 1
}

$lvl = $doc.blackbox.cfg.level_idx
$seed = $doc.blackbox.cfg.seed
$turnCount = if ($doc.blackbox.turns) { $doc.blackbox.turns.Count } else { 0 }
$desyncTick = 0
if ($doc.match -and $doc.match.desync -and $doc.match.desync.tick) {
    $desyncTick = [int]$doc.match.desync.tick
}
$targetPid = if ($PlayerPid -eq 1 -or $PlayerPid -eq 2) { $PlayerPid } elseif ($doc.match -and $doc.match.pid) { [int]$doc.match.pid } else { 1 }

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  KR-MP 开发者黑匣子高速复现工具" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  报告文件 : $ReportPath" -ForegroundColor White
Write-Host "  报告版本 : $($doc.env.mod_version) | 关卡: $lvl | 种子: $seed | 视角: ${targetPid}P | 指令回合数: $turnCount" -ForegroundColor Green
if ($desyncTick -gt 0) {
    Write-Host "  分叉帧号 : 第 $desyncTick 帧 (local=$($doc.match.desync.local_hash) vs remote=$($doc.match.desync.remote_hash))" -ForegroundColor Magenta
}

$exe = Get-ChildItem $GameDir -Filter "Kingdom Rush FL_Alliance*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) {
    Write-Host "[错误] 未在 $GameDir 中找到 FL 8.2.0 主程序！" -ForegroundColor Red
    exit 1
}

$logDir = Join-Path $RepoRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$replayLog = Join-Path $logDir "blackbox_replay.log"
$replayHashLog = Join-Path $logDir "blackbox_replay_hashes.log"
Remove-Item $replayLog, $replayHashLog -Force -ErrorAction SilentlyContinue

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe.FullName
$psi.WorkingDirectory = $GameDir
$psi.UseShellExecute = $false
$psi.Arguments = "-windowed -width 920 -height 540 -fps 60 -screen slots"
$psi.EnvironmentVariables["KR_MP_BLACKBOX_FILE"] = $ReportPath
$psi.EnvironmentVariables["KR_MP_BLACKBOX_PID"] = "$targetPid"
$psi.EnvironmentVariables["KR_MP_BLACKBOX_SPEED"] = "$Speed"
$psi.EnvironmentVariables["KR_MP_LOG_FILE"] = $replayLog
$psi.EnvironmentVariables["KR_MP_HASH_LOG_FILE"] = $replayHashLog
if ($StopTick -gt 0) {
    $psi.EnvironmentVariables["KR_MP_BLACKBOX_STOP_TICK"] = "$StopTick"
}
if ($AutoExit) {
    $psi.EnvironmentVariables["KR_MP_BLACKBOX_AUTO_EXIT"] = "1"
}
if ($TraceAroundDesync -and $desyncTick -gt 0) {
    $fromTick = [Math]::Max(1, $desyncTick - 45)
    $toTick = $desyncTick + 5
    $psi.EnvironmentVariables["KR_MP_TRACE_TICK_FROM"] = "$fromTick"
    $psi.EnvironmentVariables["KR_MP_TRACE_TICK_TO"] = "$toTick"
    $psi.EnvironmentVariables["KR_MP_TRACE_ENTITIES"] = "1"
    Write-Host "  深度追踪 : 已自动开启第 $fromTick ~ $toTick 帧 RNG 与实体追踪" -ForegroundColor Yellow
}

Write-Host "  正在启动 FL 8.2.0（${Speed}x 极速复现中）..." -ForegroundColor Cyan
$proc = [System.Diagnostics.Process]::Start($psi)

if ($AutoExit) {
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $proc.Kill() } catch {}
        Write-Host "[超时] 黑匣子复现超过 ${TimeoutSec}s 未完成！" -ForegroundColor Red
        exit 2
    }
    if (Test-Path $replayLog) {
        $lines = Get-Content $replayLog -Encoding UTF8
        $doneLine = $lines | Where-Object { $_ -match "BLACKBOX_REPLAY_COMPLETE" } | Select-Object -Last 1
        $diffLines = $lines | Where-Object { $_ -match "BLACKBOX HASH DIFF" }
        Write-Host ""
        if ($doneLine) {
            Write-Host "  结果: $doneLine" -ForegroundColor Green
        } else {
            Write-Host "  [警告] 未检测到 BLACKBOX_REPLAY_COMPLETE，请查看日志: $replayLog" -ForegroundColor Yellow
            exit 3
        }
        if ($diffLines) {
            Write-Host "  检测到哈希差异 ($($diffLines.Count) 处):" -ForegroundColor Magenta
            $diffLines | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Magenta }
        }
        Write-Host "  回放日志: $replayLog" -ForegroundColor Gray
        Write-Host "  哈希日志: $replayHashLog" -ForegroundColor Gray
    }
} else {
    Write-Host "  游戏窗口已启动，复现完成后会自动停在目标帧，日志见: $replayLog" -ForegroundColor Green
}
exit 0
