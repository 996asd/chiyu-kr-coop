param(
    [int]$Width = 920,
    [int]$Height = 540,
    [int]$Port = 17777,
    [switch]$AutoCoopTest
)

$ErrorActionPreference = "Stop"
$SandboxDir = "D:\kr-mp-mod\game-sandbox"
$ExePath = Join-Path $SandboxDir "Kingdom Rush FL_Alliance-FL4.1.0.exe"

& powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\sync_client.ps1"

New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\replays" | Out-Null

$log1 = "D:\kr-mp-mod\logs\kr_mp_p1.log"
$log2 = "D:\kr-mp-mod\logs\kr_mp_p2.log"
$h1 = "D:\kr-mp-mod\logs\mp_p1_hashes.log"
$h2 = "D:\kr-mp-mod\logs\mp_p2_hashes.log"
Remove-Item $log1, $log2, $h1, $h2 -ErrorAction SilentlyContinue

function Launch-Client([string]$role, [string]$logPath, [string]$wpos, [bool]$autoFast) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.WorkingDirectory = $SandboxDir
    $psi.UseShellExecute = $false
    $psi.Arguments = "-windowed -width $Width -height $Height -wpos $wpos -fps 60 -screen slots"
    $psi.EnvironmentVariables["KR_MP_LOG_FILE"] = $logPath
    $psi.EnvironmentVariables["KR_MP_REPLAY_DIR"] = "D:\kr-mp-mod\replays"
    $psi.EnvironmentVariables["KR_MP_PORT"] = "$Port"
    $psi.EnvironmentVariables["KR_MP_OPEN_LOBBY"] = "1"
    if ($autoFast) {
        $psi.EnvironmentVariables["KR_MP_AUTO_COOP"] = $role
        $psi.EnvironmentVariables["KR_MP_AUTO_COOP_FAST"] = "1"
    }
    return [System.Diagnostics.Process]::Start($psi)
}

Write-Host "[KR-MP M1] Launching P1 (Host) window on LEFT (20,120)..."
$p1 = Launch-Client "host" $log1 "20,120" ([bool]$AutoCoopTest)
Start-Sleep -Milliseconds 900

Write-Host "[KR-MP M1] Launching P2 (Guest) window on RIGHT (960,120)..."
$p2 = Launch-Client "guest" $log2 "960,120" ([bool]$AutoCoopTest)

if ($AutoCoopTest) {
    Write-Host "[KR-MP M1] Waiting for automated 2-process LAN Co-op verification (up to 90s)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((-not $p1.HasExited -or -not $p2.HasExited) -and $sw.Elapsed.TotalSeconds -lt 90) {
        Start-Sleep -Milliseconds 300
    }
    $timedOut = (-not $p1.HasExited) -or (-not $p2.HasExited)
    if (-not $p1.HasExited) { $p1.Kill() }
    if (-not $p2.HasExited) { $p2.Kill() }

    Write-Host "=== P1 (Host) Log ==="
    if (Test-Path $log1) { Get-Content $log1 } else { Write-Host "(missing)" }
    Write-Host "=== P2 (Guest) Log ==="
    if (Test-Path $log2) { Get-Content $log2 } else { Write-Host "(missing)" }

    if ($timedOut) {
        Write-Warning "[KR-MP M1] Automated 2P Co-op test TIMED OUT!"
        exit 1
    }

    Write-Host ""
    & python "D:\kr-mp-mod\tools\check_replay.py" $h1 $h2
    $chk = $LASTEXITCODE
    $ok1 = (Test-Path $log1) -and (Select-String -Path $log1 -Pattern "AUTO_COOP_PASSED" -Quiet)
    $ok2 = (Test-Path $log2) -and (Select-String -Path $log2 -Pattern "AUTO_COOP_PASSED" -Quiet)
    if ($chk -eq 0 -and $ok1 -and $ok2) {
        Write-Host "[KR-MP M1] === 2-PROCESS REAL TCP/UDP LAN CO-OP VERIFICATION PASSED 100%! ==="
        exit 0
    } else {
        Write-Warning "[KR-MP M1] Verification failed (chk=$chk, ok1=$ok1, ok2=$ok2)"
        exit 1
    }
} else {
    Write-Host "[KR-MP M1] Both windows launched!"
    Write-Host "  1. Left window (1P): click [CREATE LAN ROOM]"
    Write-Host "  2. Right window (2P): click [QUICK JOIN 127.0.0.1] (or click discovered LAN room)"
    Write-Host "  3. Left window (1P): choose Level / Gold / Tower rules / Heroes, then click [START 2P CO-OP MATCH!]"
}
