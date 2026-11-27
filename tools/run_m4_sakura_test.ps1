param(
    [int]$Width = 920,
    [int]$Height = 540,
    [int]$Port = 17788
)

$ErrorActionPreference = "Stop"
$SandboxDir = "D:\FL8.2.0"
$ExePath = Join-Path $SandboxDir "Kingdom Rush FL_Alliance-FL8.1.0.exe"

& powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\sync_client.ps1"

New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\logs" | Out-Null

$log1 = "D:\kr-mp-mod\logs\m4_sakura_p1.log"
$log2a = "D:\kr-mp-mod\logs\m4_sakura_p2_phase1.log"
$log2b = "D:\kr-mp-mod\logs\m4_sakura_p2_cold.log"
$h1 = "D:\kr-mp-mod\logs\m4_sakura_p1_hashes.log"
$h2 = "D:\kr-mp-mod\logs\m4_sakura_p2_hashes.log"
$sess2 = "D:\kr-mp-mod\logs\m4_sakura_session_p2.json"

Remove-Item $log1, $log2a, $log2b, $h1, $h2, $sess2 -ErrorAction SilentlyContinue

function Launch-Client([string]$role, [string]$logPath, [string]$hashPath, [string]$sessPath, [string]$wpos) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.WorkingDirectory = $SandboxDir
    $psi.UseShellExecute = $false
    $psi.Arguments = "-windowed -width $Width -height $Height -wpos $wpos -fps 60 -screen slots"
    $psi.EnvironmentVariables["KR_MP_LOG_FILE"] = $logPath
    $psi.EnvironmentVariables["KR_MP_HASH_LOG_FILE"] = $hashPath
    $psi.EnvironmentVariables["KR_MP_SESSION_FILE"] = $sessPath
    $psi.EnvironmentVariables["KR_MP_PORT"] = "$Port"
    $psi.EnvironmentVariables["KR_MP_OPEN_LOBBY"] = "1"
    $psi.EnvironmentVariables["KR_MP_AUTO_SAKURA"] = $role
    $psi.EnvironmentVariables["KR_MP_AUTO_COOP_FAST"] = "1"
    return [System.Diagnostics.Process]::Start($psi)
}

$p1 = $null
$p2a = $null
$p2b = $null

try {
    Write-Host "[KR-MP M4] Launching Direct Host (TCP :$Port) + Guest (will test 0.2s Hot Resume @600, Live Delay 2->3->4->6->2, 200g transfer, Crash @960, Direct Cold Reconnect, Keep-Alive Return-Lobby)..."
    $p1 = Launch-Client "host" $log1 $h1 "D:\kr-mp-mod\logs\m4_sakura_session_p1.json" "20,120"
    Start-Sleep -Milliseconds 700
    $p2a = Launch-Client "guest" $log2a $h2 $sess2 "960,120"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $p2a.HasExited -and $sw.Elapsed.TotalSeconds -lt 75) {
        if ($p1.HasExited) { throw "P1 exited prematurely before P2 simulated crash!" }
        Start-Sleep -Milliseconds 250
    }
    if (-not $p2a.HasExited) { throw "Timed out waiting for P2 Hot Resume + Crash @ tick 960!" }

    $sawEof = (Test-Path $log2a) -and (Select-String -Path $log2a -Pattern "AUTO_SAKURA_SIMULATED_EOF" -Quiet)
    $sawHot = (Test-Path $log2a) -and (Select-String -Path $log2a -Pattern "DIRECT HOT_RESUME complete on P2" -Quiet)
    $sawCrash = (Test-Path $log2a) -and (Select-String -Path $log2a -Pattern "AUTO_SAKURA_SIMULATED_CRASH" -Quiet)
    if (-not ($sawEof -and $sawHot -and $sawCrash)) {
        throw "Phase 1 incomplete (eof=$sawEof hot=$sawHot crash=$sawCrash)!"
    }
    if (-not (Test-Path $sess2)) { throw "Direct session file ($sess2) missing for cold reconnect!" }

    Write-Host "[KR-MP M4] Phase 1 PASSED (Hot Resume succeeded + P2 crashed @960)! Holding 1.2s before launching fresh P2 Direct Cold Reconnect..."
    Start-Sleep -Milliseconds 1200

    $p2b = Launch-Client "guest_cold_reconnect" $log2b $h2 $sess2 "960,120"
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    while ((-not $p1.HasExited -or -not $p2b.HasExited) -and $sw2.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 300
    }
    $timedOut = (-not $p1.HasExited) -or (-not $p2b.HasExited)
    if (-not $p1.HasExited) { $p1.Kill() }
    if (-not $p2b.HasExited) { $p2b.Kill() }

    Write-Host "=== P1 (Direct Host) Tail ==="
    if (Test-Path $log1) { Get-Content $log1 | Select-Object -Last 35 }
    Write-Host "=== P2 Phase 1 (Hot Resume + Crash) Tail ==="
    if (Test-Path $log2a) { Get-Content $log2a | Select-Object -Last 25 }
    Write-Host "=== P2 Phase 2 (Direct Cold Reconnect + Return Lobby) Tail ==="
    if (Test-Path $log2b) { Get-Content $log2b | Select-Object -Last 30 }

    if ($timedOut) { throw "Timed out waiting for Phase 2 completion!" }

    Write-Host ""
    & python "D:\kr-mp-mod\tools\check_replay.py" $h1 $h2
    $chk = $LASTEXITCODE
    $ok1 = (Test-Path $log1) -and (Select-String -Path $log1 -Pattern "AUTO_SAKURA_PASSED" -Quiet)
    $ok2 = (Test-Path $log2b) -and (Select-String -Path $log2b -Pattern "AUTO_SAKURA_PASSED" -Quiet)
    if ($chk -eq 0 -and $ok1 -and $ok2) {
        Write-Host "[KR-MP M4] === SAKURA DIRECT HOT-RESUME + COLD-RECONNECT + LIVE-DELAY + RETURN-LOBBY PASSED 100%! ==="
        exit 0
    } else {
        Write-Warning "[KR-MP M4] Verification failed (chk=$chk ok1=$ok1 ok2=$ok2)"
        exit 1
    }
} finally {
    if ($p1 -and -not $p1.HasExited) { try { $p1.Kill() } catch {} }
    if ($p2a -and -not $p2a.HasExited) { try { $p2a.Kill() } catch {} }
    if ($p2b -and -not $p2b.HasExited) { try { $p2b.Kill() } catch {} }
}
