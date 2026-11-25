param(
    [string]$Kr5SourceDir = "D:\kr\Kingdom Rush Alliance",
    [string]$FlRarPath = "D:\kr\Kingdom Rush Origins\【解压密码请见新手教程，请放到5代安装目录】Kingdom Rush FL_Alliance-4.1.0.rar",
    [string]$SandboxDir = "D:\kr-mp-mod\game-sandbox"
)

$ErrorActionPreference = "Stop"

Write-Host "=== [KR-MP] Setting up isolated FL 4.1.0 sandbox ==="
Write-Host "Source DLLs (READ-ONLY): $Kr5SourceDir"
Write-Host "FL RAR      (READ-ONLY): $FlRarPath"
Write-Host "Sandbox Dir            : $SandboxDir"

if (-not (Test-Path $Kr5SourceDir)) {
    throw "KR5 source directory not found: $Kr5SourceDir"
}
if (-not (Test-Path $FlRarPath)) {
    throw "FL RAR archive not found: $FlRarPath"
}

New-Item -ItemType Directory -Force -Path $SandboxDir | Out-Null
New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\logs" | Out-Null
New-Item -ItemType Directory -Force -Path "D:\kr-mp-mod\replays" | Out-Null

$dlls = @(
    "khttps.dll",
    "ksystem.dll",
    "libcurl-x64.dll",
    "love.dll",
    "lua51.dll",
    "mpg123.dll",
    "msvcp120.dll",
    "msvcr120.dll",
    "OpenAL32.dll",
    "SDL2.dll",
    "steam_api.dll",
    "license-kr-desktop.txt"
)

foreach ($f in $dlls) {
    $src = Join-Path $Kr5SourceDir $f
    $dst = Join-Path $SandboxDir $f
    if (Test-Path $src) {
        if (-not (Test-Path $dst)) {
            Copy-Item -LiteralPath $src -Destination $dst -Force
            Write-Host "  Copied $f"
        } else {
            Write-Host "  Exists $f (skipped)"
        }
    } else {
        Write-Warning "  Missing optional file: $src"
    }
}

$flExe = Join-Path $SandboxDir "Kingdom Rush FL_Alliance-FL4.1.0.exe"
if (-not (Test-Path $flExe)) {
    Write-Host "Extracting FL 4.1.0 exe into sandbox using tar.exe..."
    & tar.exe -xf $FlRarPath -C $SandboxDir
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe extraction failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Host "  Exists Kingdom Rush FL_Alliance-FL4.1.0.exe (skipped)"
}

if (-not (Test-Path $flExe)) {
    throw "Expected extracted exe not found: $flExe"
}

$item = Get-Item -LiteralPath $flExe
Write-Host "=== Sandbox ready! FL exe size: $($item.Length) bytes ==="
