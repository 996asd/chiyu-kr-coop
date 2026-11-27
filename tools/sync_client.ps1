param(
    [string]$ClientDir = "D:\kr-mp-mod\client",
    [string]$SandboxDir = "D:\FL8.2.0"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $SandboxDir)) {
    throw "Sandbox not found: $SandboxDir. Run tools/setup_sandbox.ps1 first."
}

Copy-Item -Path (Join-Path $ClientDir "UH.lua") -Destination (Join-Path $SandboxDir "UH.lua") -Force
$dstMod = Join-Path $SandboxDir "kr_mp"
New-Item -ItemType Directory -Force -Path $dstMod | Out-Null
Get-ChildItem -LiteralPath $dstMod -Force | Where-Object { $_.Name -ne "bin" } | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath (Join-Path $ClientDir "kr_mp") -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dstMod $_.Name) -Recurse -Force
}
Write-Host "[KR-MP] Synced client/ -> $SandboxDir"
