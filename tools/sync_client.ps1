param(
    [string]$ClientDir = "D:\kr-mp-mod\client",
    [string]$SandboxDir = "D:\kr-mp-mod\game-sandbox"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SandboxDir)) {
    throw "Sandbox not found: $SandboxDir. Run tools/setup_sandbox.ps1 first."
}

Copy-Item -Path (Join-Path $ClientDir "UH.lua") -Destination (Join-Path $SandboxDir "UH.lua") -Force
$dstMod = Join-Path $SandboxDir "kr_mp"
if (Test-Path $dstMod) {
    Remove-Item -Recurse -Force $dstMod
}
Copy-Item -Path (Join-Path $ClientDir "kr_mp") -Destination $dstMod -Recurse -Force
Write-Host "[KR-MP] Synced client/ -> $SandboxDir"
