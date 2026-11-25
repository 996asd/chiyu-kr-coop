param(
    [switch]$Linux
)

$ErrorActionPreference = "Stop"
$GoExe = "C:\Program Files\Go\bin\go.exe"
if (-not (Test-Path $GoExe)) {
    $cmd = Get-Command go -ErrorAction SilentlyContinue
    if ($cmd) { $GoExe = $cmd.Source } else { throw "Go toolchain not found!" }
}

$ServerDir = "D:\kr-mp-mod\server"
Push-Location $ServerDir
try {
    Write-Host "[KR-MP] Running go vet..."
    & $GoExe vet ./...

    Write-Host "[KR-MP] Building Windows binary (kr-mp-server.exe)..."
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"
    & $GoExe build -ldflags="-s -w" -o (Join-Path $ServerDir "kr-mp-server.exe") .

    if ($Linux) {
        Write-Host "[KR-MP] Cross-compiling Linux VPS binary (kr-mp-server-linux-amd64)..."
        $env:GOOS = "linux"
        $env:GOARCH = "amd64"
        $env:CGO_ENABLED = "0"
        & $GoExe build -ldflags="-s -w" -o (Join-Path $ServerDir "kr-mp-server-linux-amd64") .
    }
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}

Get-ChildItem $ServerDir -Filter "kr-mp-server*" | Select-Object Name, Length, LastWriteTime
Write-Host "[KR-MP] Server build complete!"
