param(
    [string]$Root = ""
)

$ErrorActionPreference = "Stop"
if (-not $Root) {
    $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

$VerPath = Join-Path $Root "version.json"
$ClientDir = Join-Path $Root "client"
$OutPath = Join-Path $ClientDir "kr_mp\manifest.json"

$verObj = Get-Content $VerPath -Raw -Encoding UTF8 | ConvertFrom-Json
$files = [ordered]@{}

$uh = Join-Path $ClientDir "UH.lua"
if (Test-Path $uh) {
    $files["UH.lua"] = (Get-FileHash $uh -Algorithm SHA256).Hash.ToUpper()
}

$luaFiles = Get-ChildItem (Join-Path $ClientDir "kr_mp\*.lua") | Sort-Object Name
foreach ($f in $luaFiles) {
    $files["kr_mp/$($f.Name)"] = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToUpper()
}

$assets = [ordered]@{}
$assetDir = Join-Path $ClientDir "kr_mp\assets"
if (Test-Path $assetDir) {
    $pngFiles = Get-ChildItem $assetDir -File | Sort-Object Name
    foreach ($a in $pngFiles) {
        $assets["kr_mp/assets/$($a.Name)"] = (Get-FileHash $a.FullName -Algorithm SHA256).Hash.ToUpper()
    }
}

$manifest = [ordered]@{
    version = [string]$verObj.version
    protocol = [int]$verObj.protocol
    fl_version = [string]$verObj.fl_version
    generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    files = $files
    assets = $assets
}

$json = ($manifest | ConvertTo-Json -Depth 4) -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($OutPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[KR-MP] Generated manifest.json (v$($manifest.version), $($files.Count) Lua + $($assets.Count) assets) -> $OutPath" -ForegroundColor Green
