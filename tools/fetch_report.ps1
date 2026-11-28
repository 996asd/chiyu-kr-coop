param(
    [Parameter(Position = 0)]
    [string]$Code = "",
    [string]$ServerHttp = "http://127.0.0.1:17781",
    [string]$ReportsDir = "",
    [string]$AdminToken = "",
    [int]$Limit = 20,
    [switch]$Replay,
    [switch]$TraceAroundDesync,
    [int]$Speed = 30,
    [switch]$AutoExit,
    [string]$GameDir = "D:\FL8.2.0"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$FetchedDir = Join-Path $RepoRoot "logs\fetched_reports"
New-Item -ItemType Directory -Force -Path $FetchedDir | Out-Null

function Get-HttpHeaders {
    $h = @{}
    if ($AdminToken) { $h["Authorization"] = "Bearer $AdminToken" }
    return $h
}

function Normalize-TicketCode([string]$raw) {
    $c = $raw.Trim().TrimStart('#').ToUpperInvariant()
    if ($c -match '^[A-Z0-9]{4}$') { $c = "R-$c" }
    return $c
}

function Find-LocalReportDir {
    if ($ReportsDir -and (Test-Path $ReportsDir)) { return $ReportsDir }
    $candidates = @(
        (Join-Path $RepoRoot "server\reports"),
        (Join-Path $GameDir "server\reports"),
        (Join-Path $GameDir "kr_mp\bin\reports"),
        "C:\Users\Public\KR_MP_Bin\reports"
    )
    foreach ($d in $candidates) {
        if (Test-Path $d) { return $d }
    }
    return ""
}

function Get-JsonListItems($val) {
    if ($null -eq $val) { return @() }
    if ($val -is [System.Array]) { return $val }
    if ($val -is [string]) { return @($val) }
    # Lua proto.encode({}) emits "{}" which ConvertFrom-Json parses as an empty PSCustomObject
    if ($val.PSObject.Properties.Count -eq 0) { return @() }
    return @($val)
}

function Show-ReportSummary([object]$doc, [string]$savedPath) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  KR-MP 报错工单诊断速览" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    if ($doc.ticket -and $doc.ticket.code) {
        Write-Host "  反馈码   : #$($doc.ticket.code)  (接收时间: $($doc.ticket.received_at))" -ForegroundColor Green
    }
    Write-Host "  本地文件 : $savedPath" -ForegroundColor Gray
    Write-Host "  客户端   : v$($doc.env.mod_version) | FL $($doc.env.fl_version) | $($doc.env.os) | $($doc.env.screen_w)x$($doc.env.screen_h) | hash=$($doc.env.script_hash)" -ForegroundColor White
    if ($doc.integrity) {
        $modItems = @(Get-JsonListItems $doc.integrity.modified)
        $missItems = @(Get-JsonListItems $doc.integrity.missing)
        $mCnt = $modItems.Count
        $missCnt = $missItems.Count
        $col = if ($doc.integrity.status -eq "clean") { "Green" } else { "Magenta" }
        Write-Host "  完整性   : $($doc.integrity.status) (正常 $($doc.integrity.ok_count), 改动 $mCnt, 缺失 $missCnt)" -ForegroundColor $col
        if ($mCnt -gt 0) { Write-Host "    改动文件: $($modItems -join ', ')" -ForegroundColor Magenta }
    }
    if ($doc.user_note) {
        Write-Host "  玩家备注 : $($doc.user_note)" -ForegroundColor Yellow
    }
    Write-Host "  触发原因 : $($doc.reason) | 创建时间: $($doc.created_at)" -ForegroundColor White

    if ($doc.match) {
        $m = $doc.match
        $h1 = if ($m.hero_names -and $m.hero_names.Count -ge 1) { $m.hero_names[0] } else { "?" }
        $h2 = if ($m.hero_names -and $m.hero_names.Count -ge 2) { $m.hero_names[1] } else { "?" }
        $bbTurns = if ($doc.blackbox -and $doc.blackbox.turns) { $doc.blackbox.turns.Count } else { 0 }
        Write-Host "  对局信息 : $($m.pid)P | 关卡 $($m.level_name) (idx=$($m.level_idx)) | 难度 $($m.difficulty) | 英雄 $h1 & $h2" -ForegroundColor Cyan
        Write-Host "  同步进度 : 第 $($m.last_tick) 帧 | 校验通过 $($m.sync_ok_count) 次 | 黑匣子回合数: $bbTurns" -ForegroundColor Cyan
        if ($m.desync) {
            $d = $m.desync
            Write-Host "  [DESYNC] 第 $($d.tick) 帧分叉! local=$($d.local_hash) vs remote=$($d.remote_hash)" -ForegroundColor Red
            if ($d.local_snap)  { Write-Host "    LOCAL  SNAP: $($d.local_snap)" -ForegroundColor Yellow }
            if ($d.remote_snap) { Write-Host "    REMOTE SNAP: $($d.remote_snap)" -ForegroundColor Yellow }
            if ($d.local_ents)  { Write-Host "    LOCAL  ENTS: $($d.local_ents)" -ForegroundColor Magenta }
            if ($d.remote_ents) { Write-Host "    REMOTE ENTS: $($d.remote_ents)" -ForegroundColor Magenta }
        }
        if ($m.recent_cmds -and $m.recent_cmds.Count -gt 0) {
            Write-Host ""
            Write-Host "  最近操作指令 (末尾 10 条):" -ForegroundColor DarkCyan
            $m.recent_cmds | Select-Object -Last 10 | ForEach-Object {
                Write-Host "    [T$($_.t)] P$($_.p) $($_.op) id=$($_.id) arg=$($_.arg) pos=($($_.wx),$($_.wy))" -ForegroundColor Gray
            }
        }
    }
    if ($doc.crash -and $doc.crash.traceback) {
        Write-Host ""
        Write-Host "  [LUA CRASH 堆栈]" -ForegroundColor Red
        Write-Host $doc.crash.traceback -ForegroundColor Red
    }
    if ($doc.logs -and $doc.logs.Count -gt 0) {
        Write-Host ""
        Write-Host "  末尾日志 (最后 8 行):" -ForegroundColor DarkCyan
        $doc.logs | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }
    Write-Host "============================================================" -ForegroundColor Cyan
}

$localDir = Find-LocalReportDir

# Mode 1: List recent tickets
if (-not $Code) {
    $listed = $false
    if ($ServerHttp) {
        try {
            $url = "$($ServerHttp.TrimEnd('/'))/reports?limit=$Limit"
            $resp = Invoke-RestMethod -Uri $url -Headers (Get-HttpHeaders) -TimeoutSec 5
            Write-Host "=== 公网中继服报错工单列表 ($url · 共 $($resp.count) 份) ===" -ForegroundColor Cyan
            if (-not $resp.reports -or $resp.reports.Count -eq 0) {
                Write-Host "  (暂无报错工单)" -ForegroundColor Gray
            } else {
                foreach ($r in $resp.reports) {
                    $flags = @()
                    if ($r.has_crash) { $flags += "CRASH" }
                    if ($r.desync_tick -gt 0) { $flags += "DESYNC@$($r.desync_tick)" }
                    if ($flags.Count -eq 0) { $flags += $r.reason }
                    $lvlStr = if ($r.level_idx -gt 0) { "L$($r.level_idx) $($r.level_name)" } else { "大厅" }
                    $noteStr = if ($r.note) { " | 备注: $($r.note)" } else { "" }
                    Write-Host ("  #{0}  [{1}]  v{2}  {3}  ({4:N1} KB)  {5}{6}" -f $r.code, ($flags -join ","), $r.mod_ver, $lvlStr, ($r.bytes / 1024.0), $r.received_at, $noteStr) -ForegroundColor White
                }
            }
            $listed = $true
        } catch {
            Write-Host "[提示] HTTP 查询 $ServerHttp 不可达 ($($_.Exception.Message))，尝试扫描本地目录..." -ForegroundColor Yellow
        }
    }
    if (-not $listed) {
        if (-not $localDir) {
            Write-Host "[错误] 未找到本地 reports 目录且无法访问 $ServerHttp。" -ForegroundColor Red
            exit 1
        }
        Write-Host "=== 本地服务端报错工单目录 ($localDir) ===" -ForegroundColor Cyan
        $files = Get-ChildItem $localDir -Filter "R-*.json" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First $Limit
        if (-not $files) {
            Write-Host "  (暂无报错工单)" -ForegroundColor Gray
        } else {
            foreach ($f in $files) {
                Write-Host ("  {0}  ({1:N1} KB)  {2}" -f $f.Name, ($f.Length / 1024.0), $f.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")) -ForegroundColor White
            }
        }
    }
    Write-Host ""
    Write-Host "用法示例: powershell -ExecutionPolicy Bypass -File tools\fetch_report.ps1 R-4K9A -Replay" -ForegroundColor DarkGray
    exit 0
}

# Mode 2: Fetch & inspect specific ticket code
$normCode = Normalize-TicketCode $Code
if ($normCode -notmatch '^R-[A-Z0-9]{4,6}$') {
    Write-Host "[错误] 反馈码格式无效: $Code（正确示例: R-4K9A 或 #R-4K9A 或 4K9A）" -ForegroundColor Red
    exit 1
}

$rawJson = $null
$savedPath = Join-Path $FetchedDir "$normCode.json"

if ($localDir) {
    $hit = Get-ChildItem $localDir -Filter "${normCode}_*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) {
        $rawJson = [System.IO.File]::ReadAllText($hit.FullName, [System.Text.Encoding]::UTF8)
        Copy-Item $hit.FullName $savedPath -Force
    }
}

if (-not $rawJson -and $ServerHttp) {
    $url = "$($ServerHttp.TrimEnd('/'))/reports/$normCode"
    try {
        $resp = Invoke-WebRequest -Uri $url -Headers (Get-HttpHeaders) -TimeoutSec 10 -UseBasicParsing
        $rawJson = $resp.Content
        [System.IO.File]::WriteAllText($savedPath, $rawJson, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Host "[错误] 从 $url 拉取工单 #$normCode 失败: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

if (-not $rawJson) {
    Write-Host "[错误] 未找到工单 #$normCode（已查本地目录与 $ServerHttp）。" -ForegroundColor Red
    exit 1
}

$doc = $rawJson | ConvertFrom-Json
Show-ReportSummary -doc $doc -savedPath $savedPath

if ($Replay) {
    if (-not $doc.blackbox -or -not $doc.blackbox.cfg) {
        Write-Host "[警告] 该工单不包含可回放对局黑匣子 (blackbox.cfg 缺失)，跳过自动复现。" -ForegroundColor Yellow
        exit 0
    }
    $replayScript = Join-Path $RepoRoot "tools\replay_blackbox.ps1"
    $rpArgs = @("-ExecutionPolicy", "Bypass", "-File", $replayScript, "-ReportPath", $savedPath, "-GameDir", $GameDir, "-Speed", "$Speed")
    if ($TraceAroundDesync) { $rpArgs += "-TraceAroundDesync" }
    if ($AutoExit) { $rpArgs += "-AutoExit" }
    Write-Host ""
    Write-Host ">>> 正在联动 30 倍速黑匣子复现工具..." -ForegroundColor Green
    & powershell @rpArgs
    exit $LASTEXITCODE
}
exit 0
