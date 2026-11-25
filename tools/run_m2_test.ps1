param(
    [int]$Width = 920,
    [int]$Height = 540,
    [int]$Port = 17780,
    [int]$HttpPort = 17781,
    [switch]$Interactive
)

$ErrorActionPreference = "Stop"
$SandboxDir = "D:\kr-mp-mod\game-sandbox"
$ExePath = Join-Path $SandboxDir "Kingdom Rush FL_Alliance-FL4.1.0.exe"
$ServerExe = "D:\kr-mp-mod\server\kr-mp-server.exe"

if (-not (Test-Path $ServerExe)) {
    & powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\build_server.ps1"
}
& powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\sync_client.ps1"

New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\logs" | Out-Null

$srvLog = "D:\kr-mp-mod\logs\m2_server.log"
$srvErr = "D:\kr-mp-mod\logs\m2_server_err.log"
$log1 = "D:\kr-mp-mod\logs\m2_p1.log"
$log2a = "D:\kr-mp-mod\logs\m2_p2_before_crash.log"
$log2b = "D:\kr-mp-mod\logs\m2_p2_reconnected.log"
$h1 = "D:\kr-mp-mod\logs\m2_p1_hashes.log"
$h2 = "D:\kr-mp-mod\logs\m2_p2_hashes.log"
$sess1 = "D:\kr-mp-mod\logs\m2_session_p1.json"
$sess2 = "D:\kr-mp-mod\logs\m2_session_p2.json"

Remove-Item $srvLog, $srvErr, $log1, $log2a, $log2b, $h1, $h2, $sess1, $sess2 -ErrorAction SilentlyContinue

function Launch-Client([string]$role, [string]$logPath, [string]$hashPath, [string]$sessPath, [string]$wpos, [bool]$autoFast) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.WorkingDirectory = $SandboxDir
    $psi.UseShellExecute = $false
    $psi.Arguments = "-windowed -width $Width -height $Height -wpos $wpos -fps 60 -screen slots"
    $psi.EnvironmentVariables["KR_MP_LOG_FILE"] = $logPath
    $psi.EnvironmentVariables["KR_MP_HASH_LOG_FILE"] = $hashPath
    $psi.EnvironmentVariables["KR_MP_SESSION_FILE"] = $sessPath
    $psi.EnvironmentVariables["KR_MP_SERVER"] = "127.0.0.1:$Port"
    $psi.EnvironmentVariables["KR_MP_DEFAULT_TAB"] = "online"
    $psi.EnvironmentVariables["KR_MP_OPEN_LOBBY"] = "1"
    if ($autoFast) {
        $psi.EnvironmentVariables["KR_MP_AUTO_M2"] = $role
        $psi.EnvironmentVariables["KR_MP_AUTO_COOP_FAST"] = "1"
    }
    return [System.Diagnostics.Process]::Start($psi)
}

if ($Interactive) {
    Write-Host "[KR-MP M2] Starting local Go Online Relay Server on 127.0.0.1:$Port..."
    Start-Process -FilePath $ServerExe -ArgumentList "-addr :$Port -http :$HttpPort"
    Start-Sleep -Milliseconds 600
    Launch-Client "host" $log1 $h1 $sess1 "20,120" $false | Out-Null
    Start-Sleep -Milliseconds 800
    Launch-Client "guest" $log2a $h2 $sess2 "960,120" $false | Out-Null
    Write-Host "[KR-MP M2] Online Server + 2 Windows launched! Both open directly on ONLINE SERVER tab."
    exit 0
}

Write-Host "[KR-MP M2] Starting Go Relay Server on 127.0.0.1:$Port (HTTP health :$HttpPort)..."
$srv = Start-Process -FilePath $ServerExe -ArgumentList "-addr 127.0.0.1:$Port -http 127.0.0.1:$HttpPort -grace 120" `
    -RedirectStandardOutput $srvLog -RedirectStandardError $srvErr -NoNewWindow -PassThru

$p1 = $null
$p2a = $null
$p2b = $null

try {
    # Wait for server HTTP health check
    $healthOk = $false
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 150
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$HttpPort/health" -TimeoutSec 1
            if ($resp.server_ver) {
                Write-Host "[KR-MP M2] Server healthy! ver=$($resp.server_ver) proto=$($resp.proto)"
                $healthOk = $true
                break
            }
        } catch {}
    }
    if (-not $healthOk) { throw "Go server failed to become healthy!" }

    Write-Host "[KR-MP M2] Launching P1 (Online Host) and P2 (Online Guest - will simulate crash @ tick 960)..."
    $p1 = Launch-Client "host" $log1 $h1 $sess1 "20,120" $true
    Start-Sleep -Milliseconds 700
    $p2a = Launch-Client "guest" $log2a $h2 $sess2 "960,120" $true

    # Phase 1: Wait for P2 to crash intentionally at tick 960 (up to 60s)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p2a.HasExited -and $sw.Elapsed.TotalSeconds -lt 60) {
        if ($p1.HasExited) { throw "P1 exited prematurely before P2 crash!" }
        Start-Sleep -Milliseconds 250
    }
    if (-not $p2a.HasExited) { throw "Timed out waiting for P2 simulated crash @ tick 960!" }

    $crashedCleanly = (Test-Path $log2a) -and (Select-String -Path $log2a -Pattern "AUTO_M2_SIMULATED_CRASH" -Quiet)
    if (-not $crashedCleanly) { throw "P2 exited without AUTO_M2_SIMULATED_CRASH!" }
    if (-not (Test-Path $sess2)) { throw "P2 session file ($sess2) missing for reconnect!" }

    Write-Host "[KR-MP M2] P2 crashed @ tick 960! Holding 1.2s while P1 stays paused in WAIT_RECONNECT..."
    Start-Sleep -Milliseconds 1200

    # Phase 2: Relaunch fresh P2 process in RECONNECT mode (fast-forward from tick 0 -> resume live -> 2x speed -> tick 2160!)
    Write-Host "[KR-MP M2] Relaunching fresh P2 (guest_reconnect) to test Fast-Forward Catch-Up & Live Resume..."
    $p2b = Launch-Client "guest_reconnect" $log2b $h2 $sess2 "960,120" $true

    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    while ((-not $p1.HasExited -or -not $p2b.HasExited) -and $sw2.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 300
    }
    $timedOut = (-not $p1.HasExited) -or (-not $p2b.HasExited)

    if (-not $p1.HasExited) { $p1.Kill() }
    if (-not $p2b.HasExited) { $p2b.Kill() }

    Write-Host "=== Go Server Log ==="
    if (Test-Path $srvErr) { Get-Content $srvErr }
    Write-Host "=== P1 (Online Host) Log ==="
    if (Test-Path $log1) { Get-Content $log1 | Select-Object -Last 35 }
    Write-Host "=== P2 Phase 1 (Before Crash) Log ==="
    if (Test-Path $log2a) { Get-Content $log2a | Select-Object -Last 20 }
    Write-Host "=== P2 Phase 2 (Reconnected & Fast-Forwarded) Log ==="
    if (Test-Path $log2b) { Get-Content $log2b | Select-Object -Last 35 }

    if ($timedOut) { throw "Timed out waiting for post-reconnect match completion!" }

    Write-Host ""
    & python "D:\kr-mp-mod\tools\check_replay.py" $h1 $h2
    $chk = $LASTEXITCODE
    $ok1 = (Test-Path $log1) -and (Select-String -Path $log1 -Pattern "AUTO_M2_PASSED" -Quiet)
    $ok2 = (Test-Path $log2b) -and (Select-String -Path $log2b -Pattern "AUTO_M2_PASSED" -Quiet)

    if ($chk -eq 0 -and $ok1 -and $ok2) {
        Write-Host "[KR-MP M2] === 3-PROCESS ONLINE SERVER + CRASH & FAST-FORWARD RECONNECT PASSED 100%! ==="
        exit 0
    } else {
        Write-Warning "[KR-MP M2] Verification failed (chk=$chk ok1=$ok1 ok2=$ok2)"
        exit 1
    }
} finally {
    if ($p1 -and -not $p1.HasExited) { try { $p1.Kill() } catch {} }
    if ($p2a -and -not $p2a.HasExited) { try { $p2a.Kill() } catch {} }
    if ($p2b -and -not $p2b.HasExited) { try { $p2b.Kill() } catch {} }
    if ($srv -and -not $srv.HasExited) { try { $srv.Kill() } catch {} }
}
