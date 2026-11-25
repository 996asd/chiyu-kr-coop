param(
    [string]$FlZipPath = "C:\Users\work\Downloads\FL8.2.0-解压到新文件夹直玩，自动接档.zip",
    [string]$SandboxDir = "D:\FL8.2.0"
)

# Sets up the FL 8.2.0 dev/test game directory used by sync_client.ps1 / run_m*.ps1.
# The source zip is only READ; D:\kr\ is never touched.
$ErrorActionPreference = "Stop"
$ExeName = "Kingdom Rush FL_Alliance-FL8.1.0.exe"

Write-Host "=== [KR-MP] Setting up FL 8.2.0 test directory ==="
Write-Host "FL ZIP (READ-ONLY): $FlZipPath"
Write-Host "Target Dir        : $SandboxDir"

New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\replays" | Out-Null

$flExe = Join-Path $SandboxDir $ExeName
if (Test-Path $flExe) {
    Write-Host "  Exists $ExeName (skipped extraction)"
} else {
    if (-not (Test-Path $FlZipPath)) {
        throw "FL 8.2.0 zip not found: $FlZipPath"
    }
    New-Item -ItemType Directory -Force -Path $SandboxDir | Out-Null
    Write-Host "Extracting FL 8.2.0 (~3 GB) with tar.exe..."
    & tar.exe -xf $FlZipPath -C $SandboxDir
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe extraction failed with exit code $LASTEXITCODE"
    }
    # Flatten if the archive contained a single top-level folder
    if (-not (Test-Path $flExe)) {
        $inner = Get-ChildItem $SandboxDir -Recurse -Filter $ExeName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($inner) {
            Get-ChildItem $inner.DirectoryName -Force | Move-Item -Destination $SandboxDir -Force
        }
    }
}

if (-not (Test-Path $flExe)) {
    throw "Expected exe not found: $flExe"
}
$item = Get-Item -LiteralPath $flExe
Write-Host "=== FL 8.2.0 ready! exe size: $($item.Length) bytes ==="
