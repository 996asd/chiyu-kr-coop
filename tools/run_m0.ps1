param(
    [int]$Width = 1280,
    [int]$Height = 720,
    [string]$WPos = "80,60",
    [int]$Level = 0,
    [switch]$SmokeTest,
    [switch]$AutoVerify
)

$ErrorActionPreference = "Stop"
$SandboxDir = "D:\kr-mp-mod\game-sandbox"
$ExePath = Join-Path $SandboxDir "Kingdom Rush FL_Alliance-FL4.1.0.exe"

& "D:\kr-mp-mod\tools\sync_client.ps1"

$logFile = "D:\kr-mp-mod\logs\kr_mp_latest.log"
New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\replays" | Out-Null

$env:KR_MP_LOG_FILE = $logFile
$env:KR_MP_REPLAY_DIR = "D:\kr-mp-mod\replays"

Remove-Item Env:\KR_MP_SMOKE_TEST -ErrorAction SilentlyContinue
Remove-Item Env:\KR_MP_AUTO_VERIFY -ErrorAction SilentlyContinue

if ($SmokeTest) {
    $env:KR_MP_SMOKE_TEST = "1"
}
if ($AutoVerify) {
    $env:KR_MP_AUTO_VERIFY = "1"
    if ($Level -le 0) { $Level = 1 }
}

$argsList = @("-windowed", "-width", "$Width", "-height", "$Height", "-wpos", $WPos, "-fps", "60")
if ($Level -gt 0) {
    $argsList += @("-level", "$Level")
} elseif ($SmokeTest) {
    $argsList += @("-screen", "splash")
}

Write-Host "[KR-MP] Launching FL 4.1.0 sandbox: $ExePath $($argsList -join ' ')"
Push-Location $SandboxDir
try {
    if ($SmokeTest -or $AutoVerify) {
        $timeoutMs = if ($AutoVerify) { 90000 } else { 20000 }
        $proc = Start-Process -FilePath $ExePath -ArgumentList $argsList -WorkingDirectory $SandboxDir -PassThru
        $exited = $proc.WaitForExit($timeoutMs)
        if (-not $exited) {
            Write-Warning "Automated test did not exit within $($timeoutMs/1000)s; terminating process."
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            if (Test-Path $logFile) {
                Write-Host "=== Partial kr_mp_latest.log ==="
                Get-Content $logFile
            }
            exit 1
        }
        Write-Host "[KR-MP] Process exited with code $($proc.ExitCode)"
        if (Test-Path $logFile) {
            Write-Host "=== kr_mp_latest.log ==="
            Get-Content $logFile
        } else {
            Write-Warning "Log file not created: $logFile"
            exit 2
        }
        if ($AutoVerify) {
            Write-Host ""
            & python "D:\kr-mp-mod\tools\check_replay.py"
            exit $LASTEXITCODE
        }
    } else {
        Start-Process -FilePath $ExePath -ArgumentList $argsList -WorkingDirectory $SandboxDir
    }
} finally {
    Pop-Location
}
