param(
    [string]$TargetDir = "",
    [switch]$AutoFind,
    [switch]$Silent,
    [switch]$NoDesktopShortcut,
    [switch]$InstallSakura,
    [switch]$SkipSakuraPrompt
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PkgRoot = Split-Path -Parent $ScriptRoot
$PatchDir = Join-Path $PkgRoot "patch"
if (-not (Test-Path (Join-Path $PatchDir "UH.lua"))) {
    $PatchDir = Join-Path $PkgRoot "client"
}

$TargetFlVersion = "8.2.0"
$PreferredExe = "Kingdom Rush FL_Alliance-FL8.1.0.exe"

function Get-FlExe([string]$dir) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    $p = Join-Path $dir $PreferredExe
    if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p) }
    return (Get-ChildItem -LiteralPath $dir -Filter "Kingdom Rush FL_Alliance*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-FlVersion([string]$dir) {
    $mg = Join-Path $dir "main_globals.lua"
    if (Test-Path -LiteralPath $mg) {
        $m = Select-String -LiteralPath $mg -Pattern 'KR_FL_VERSION\s*=\s*"([^"]+)"' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return ""
}

function Find-FlGameDirs {
    $found = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    function Add-IfValid([string]$cand) {
        if (-not $cand -or -not (Test-Path -LiteralPath $cand -PathType Container)) { return }
        try { $full = (Resolve-Path -LiteralPath $cand -ErrorAction Stop).Path } catch { return }
        if ($seen.Contains($full)) { return }
        $exe = Get-FlExe $full
        if ($exe) {
            [void]$seen.Add($full)
            $ver = Get-FlVersion $full
            $found.Add([PSCustomObject]@{ Path = $full; Version = $ver; IsExact = ($ver -eq $TargetFlVersion) })
        }
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Get-Location).Path)
    foreach ($d in @("D:\FL8.2.0", "C:\FL8.2.0", "E:\FL8.2.0", "F:\FL8.2.0", "G:\FL8.2.0",
                     "C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Alliance",
                     "D:\SteamLibrary\steamapps\common\Kingdom Rush Alliance",
                     "E:\SteamLibrary\steamapps\common\Kingdom Rush Alliance")) {
        $roots.Add($d)
    }
    foreach ($sp in @([Environment]::GetFolderPath("Desktop"),
                      (Join-Path $env:USERPROFILE "Downloads"),
                      [Environment]::GetFolderPath("MyDocuments"),
                      "D:\Downloads", "D:\BaiduNetdiskDownload", "E:\BaiduNetdiskDownload", "D:\Games", "E:\Games")) {
        if ($sp -and (Test-Path -LiteralPath $sp -PathType Container)) {
            Add-IfValid $sp
            Get-ChildItem -LiteralPath $sp -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Add-IfValid $_.FullName
                if ($_.Name -match "FL|Kingdom|KR|王国|保卫战|Alliance") {
                    Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                        Add-IfValid $_.FullName
                    }
                }
            }
        }
    }
    foreach ($r in $roots) { Add-IfValid $r }

    # Fast top-level drive scan for folders named like FL / Kingdom / KR / 王国
    foreach ($drv in @("C:\", "D:\", "E:\", "F:\", "G:\")) {
        if (Test-Path -LiteralPath $drv) {
            Get-ChildItem -LiteralPath $drv -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match "FL|Kingdom|KR|王国|保卫战|Game" -and $_.Name -notmatch "^(Windows|Program Files|ProgramData|Users|\$)"
            } | ForEach-Object {
                Add-IfValid $_.FullName
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    Add-IfValid $_.FullName
                }
            }
        }
    }

    $exact = @($found | Where-Object { $_.IsExact })
    if ($exact.Count -gt 0) { return $exact }
    return @($found)
}

function Test-SakuraInstalled {
    foreach ($dir in @(
        (Join-Path $env:ProgramFiles "SakuraFrpLauncher"),
        (Join-Path ${env:ProgramFiles(x86)} "SakuraFrpLauncher"),
        (Join-Path $env:LOCALAPPDATA "SakuraFrpLauncher")
    )) {
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir "SakuraLauncher.exe"))) {
            return $true
        }
    }
    return $false
}

function Install-OfficialSakuraLauncher {
    Write-Host ""
    Write-Host "[樱花映射] 正在从官方接口获取最新 SakuraLauncher.exe..." -ForegroundColor Cyan
    $meta = $null
    foreach ($api in @("https://api.natfrp.com/v4/system/clients", "https://natfrp-api.globalslb.net/v4/system/clients")) {
        try {
            $resp = Invoke-RestMethod -Uri $api -TimeoutSec 12
            if ($resp -and $resp.windows -and $resp.windows.archs -and $resp.windows.archs.default) {
                $meta = $resp.windows
                break
            }
        } catch {}
    }
    if (-not $meta) {
        Write-Host "[警告] 无法连接樱花官方接口，请手动访问 https://www.natfrp.com/tunnel/download 下载。" -ForegroundColor Yellow
        return $false
    }
    $arch = $meta.archs.default
    $dlUrl = [string]$arch.url
    $expectMd5 = ([string]$arch.hash).ToLowerInvariant()
    $ver = ([string]$meta.ver) -replace '[^0-9A-Za-z\.\-]', ''
    $uriObj = [Uri]$dlUrl
    $hostOk = ($uriObj.Scheme -eq "https") -and ($uriObj.Host -eq "nya.globalslb.net" -or $uriObj.Host -like "*.natfrp.com" -or $uriObj.Host -like "*.globalslb.net")
    if (-not $hostOk) {
        Write-Host "[警告] 官方下载域名校验未通过，已取消下载。" -ForegroundColor Yellow
        return $false
    }
    $outPath = Join-Path $env:TEMP ("SakuraLauncher_v{0}_official.exe" -f $ver)
    $needDownload = $true
    if ((Test-Path -LiteralPath $outPath) -and $expectMd5.Length -eq 32) {
        $curHash = (Get-FileHash -LiteralPath $outPath -Algorithm MD5).Hash.ToLowerInvariant()
        if ($curHash -eq $expectMd5) { $needDownload = $false }
    }
    if ($needDownload) {
        Write-Host ("  正在下载 SakuraLauncher v{0} ({1:N1} MB)..." -f $ver, ([double]$arch.size / 1MB)) -ForegroundColor Gray
        Invoke-WebRequest -UseBasicParsing -Uri $dlUrl -OutFile $outPath -TimeoutSec 120
        if ($expectMd5.Length -eq 32) {
            $gotMd5 = (Get-FileHash -LiteralPath $outPath -Algorithm MD5).Hash.ToLowerInvariant()
            if ($gotMd5 -ne $expectMd5) {
                Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
                Write-Host "[错误] 官方樱花安装包 MD5 校验不一致，已删除损坏文件。" -ForegroundColor Red
                return $false
            }
        }
    }
    Write-Host "[樱花映射] 官方安装包校验通过 (MD5 √)，正在启动官方安装向导..." -ForegroundColor Green
    Write-Host "  提示：如弹出管理员 UAC 请点「是」，按向导点下一步即可完成安装。" -ForegroundColor Yellow
    Start-Process -FilePath $outPath
    return $true
}

function New-DesktopShortcut([string]$GameDir, [string]$ExeFullPath) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { return "" }
    $lnkPath = Join-Path $desktop "王国保卫战联机版 (FL8.2.0).lnk"
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath = $ExeFullPath
    $sc.Arguments = "-fps 60"
    $sc.WorkingDirectory = $GameDir
    $sc.IconLocation = "$ExeFullPath,0"
    $sc.Description = "赤羽的王国保卫战 FL 8.2.0 双人联机版（自动锁定 60 FPS）"
    $sc.Save()
    return $lnkPath
}

$ModVer = "2.3.0"
$mfFile = Join-Path $PatchDir "kr_mp\manifest.json"
if (Test-Path -LiteralPath $mfFile) {
    try { $ModVer = (Get-Content -LiteralPath $mfFile -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  赤羽的王国保卫战联机器 FL $TargetFlVersion (KR-MP v$ModVer) 一键安装程序" -ForegroundColor Yellow
Write-Host "  零侵入外挂补丁架构：绝不修改原版游戏主程序与素材" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $TargetDir) {
    $cands = @(Find-FlGameDirs)
    if ($Silent) {
        if ($cands.Count -eq 1) {
            $TargetDir = $cands[0].Path
        } elseif ($cands.Count -gt 1) {
            Write-Host "KR_MP_MULTI_CANDIDATES:" -ForegroundColor Yellow
            foreach ($c in $cands) { Write-Host ("  " + $c.Path + " (FL " + $c.Version + ")") }
            exit 2
        } else {
            Write-Host "KR_MP_NOT_FOUND" -ForegroundColor Red
            exit 3
        }
    } else {
        if ($cands.Count -eq 1) {
            Write-Host "已自动检测到 FL $TargetFlVersion 游戏目录: $($cands[0].Path)" -ForegroundColor Green
            $useDet = Read-Host "是否安装到此目录？直接回车确认，或输入/拖入其他游戏目录路径"
            if ($useDet -eq "" -or $useDet -match "^[Yy]$") {
                $TargetDir = $cands[0].Path
            } else {
                $TargetDir = $useDet.Trim('"').Trim()
            }
        } elseif ($cands.Count -gt 1) {
            Write-Host "检测到多个候选游戏目录：" -ForegroundColor Green
            for ($i = 0; $i -lt $cands.Count; $i++) {
                Write-Host ("  [{0}] {1} (FL {2})" -f ($i + 1), $cands[$i].Path, $cands[$i].Version)
            }
            $pick = Read-Host "请输入序号（默认 1），或直接粘贴自定义目录路径"
            if ($pick -eq "") {
                $TargetDir = $cands[0].Path
            } elseif ($pick -match "^\d+$" -and [int]$pick -ge 1 -and [int]$pick -le $cands.Count) {
                $TargetDir = $cands[[int]$pick - 1].Path
            } else {
                $TargetDir = $pick.Trim('"').Trim()
            }
        } else {
            Write-Host ""
            Write-Host "[提示] 未自动找到 FL $TargetFlVersion 游戏目录。" -ForegroundColor Yellow
            Write-Host "  · 注意：本联机补丁仅适配同人改版 FL $TargetFlVersion（不支持 Steam 原版《王国保卫战》）！" -ForegroundColor Yellow
            Write-Host "  · 如果你还没有 FL $TargetFlVersion 本体，请先按视频置顶评论或交流群文件获取并解压，再重新双击本程序。" -ForegroundColor Cyan
            Write-Host "  · 如果已经解压在别处，请在弹出的文件夹选择框中选中包含 $PreferredExe 的目录..." -ForegroundColor Gray
            try {
                Add-Type -AssemblyName System.Windows.Forms
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = "请选择王国保卫战 FL $TargetFlVersion 游戏目录（含 $PreferredExe）"
                if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                    $TargetDir = $dlg.SelectedPath
                }
            } catch {}
            if (-not $TargetDir) {
                $TargetDir = (Read-Host "请粘贴或拖入 FL $TargetFlVersion 游戏目录路径").Trim('"').Trim()
            }
        }
    }
}

if (-not $TargetDir -or -not (Test-Path -LiteralPath $TargetDir)) {
    Write-Host "[错误] 未找到目标目录: $TargetDir" -ForegroundColor Red
    exit 1
}
$TargetDir = (Resolve-Path -LiteralPath $TargetDir).Path

$ExeItem = Get-FlExe $TargetDir
if (-not $ExeItem) {
    Write-Host "[错误] 目标目录中未找到 $PreferredExe ！" -ForegroundColor Red
    Write-Host "请确认你选择的是 FL $TargetFlVersion 的实际游戏目录（解压后的 exe 所在文件夹）。" -ForegroundColor Yellow
    exit 1
}
$ExeName = $ExeItem.Name

$detVer = Get-FlVersion $TargetDir
if ($detVer -and $detVer -ne $TargetFlVersion) {
    Write-Host "[警告] 该目录的 FL 版本是 $detVer，本补丁只适配 FL $TargetFlVersion！双方版本不同会无法联机或不同步。" -ForegroundColor Red
    if (-not $Silent) {
        $go = Read-Host "仍要继续安装吗？(输入 Y 继续，其他键取消)"
        if ($go -notmatch "^[Yy]$") { exit 1 }
    }
}

# Backup any non-KR-MP third-party UH.lua safely
$TargetUH = Join-Path $TargetDir "UH.lua"
$BackupUH = Join-Path $TargetDir "UH.lua.kr_mp_backup"
if (Test-Path -LiteralPath $TargetUH) {
    $existing = Get-Content -LiteralPath $TargetUH -Raw -ErrorAction SilentlyContinue
    if ($existing -and ($existing -notmatch "kr_mp\.boot") -and (-not (Test-Path -LiteralPath $BackupUH))) {
        Copy-Item -LiteralPath $TargetUH -Destination $BackupUH -Force
        Write-Host "[备份] 已将原有 UH.lua 备份为 UH.lua.kr_mp_backup" -ForegroundColor Yellow
    }
}

# Clean-install lightweight patch (UH.lua + kr_mp/, preserving cached/running kr_mp/bin)
Copy-Item -LiteralPath (Join-Path $PatchDir "UH.lua") -Destination $TargetUH -Force
$TargetKrMp = Join-Path $TargetDir "kr_mp"
New-Item -ItemType Directory -Force -Path $TargetKrMp | Out-Null
Get-ChildItem -LiteralPath $TargetKrMp -Force | Where-Object { $_.Name -ne "bin" } | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath (Join-Path $PatchDir "kr_mp") -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetKrMp $_.Name) -Recurse -Force
}

# Verify installed files & assets against manifest.json SHA-256
$TargetManifest = Join-Path $TargetKrMp "manifest.json"
if (Test-Path -LiteralPath $TargetManifest) {
    $mf = Get-Content -LiteralPath $TargetManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $checked = 0
    foreach ($section in @($mf.files, $mf.assets)) {
        if (-not $section) { continue }
        foreach ($prop in $section.PSObject.Properties) {
            $rel = $prop.Name -replace '/', '\'
            $fp = Join-Path $TargetDir $rel
            if (-not (Test-Path -LiteralPath $fp)) {
                Write-Host "[错误] 安装校验失败，缺少文件: $rel" -ForegroundColor Red
                exit 1
            }
            $got = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($got -ne ([string]$prop.Value).ToLowerInvariant()) {
                Write-Host "[错误] 安装校验失败，文件哈希不一致: $rel" -ForegroundColor Red
                exit 1
            }
            $checked++
        }
    }
    Write-Host "[校验] 已完成 $checked 个补丁与资源文件 SHA-256 完整性校验 √" -ForegroundColor Green
}

# Remove obsolete FL 4.1.0 launcher if present
$OldLauncher = Join-Path $TargetDir "启动联机版_FL4.1.0.bat"
if (Test-Path -LiteralPath $OldLauncher) { Remove-Item -LiteralPath $OldLauncher -Force }

# Write folder-local 60 FPS launcher bat
$LauncherPath = Join-Path $TargetDir "启动联机版_FL8.2.0.bat"
$LauncherContent = @"
@echo off
cd /d "%~dp0"
start "" "$ExeName" -fps 60
"@
[System.IO.File]::WriteAllText($LauncherPath, $LauncherContent, (New-Object System.Text.UTF8Encoding($false)))

# Create Desktop .lnk shortcut with original game icon & -fps 60 (no console flash)
$ShortcutPath = ""
if (-not $NoDesktopShortcut) {
    try {
        $ShortcutPath = New-DesktopShortcut -GameDir $TargetDir -ExeFullPath $ExeItem.FullName
    } catch {
        Write-Host "[提示] 创建桌面快捷方式失败（可改用游戏目录内的 启动联机版_FL8.2.0.bat）：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$SakuraInstalled = Test-SakuraInstalled
if ($InstallSakura) {
    if ($SakuraInstalled) {
        Write-Host "[樱花映射] 本机已安装官方 SakuraFrp 启动器，无需重复安装。" -ForegroundColor Green
    } else {
        [void](Install-OfficialSakuraLauncher)
    }
} elseif (-not $Silent -and -not $SkipSakuraPrompt -and -not $SakuraInstalled) {
    Write-Host ""
    Write-Host "[可选] 检测到本机未安装官方樱花映射 (SakuraFrp)：" -ForegroundColor Cyan
    Write-Host "  · 同 Wi-Fi 局域网或只当 2P 队友 -> 不需要装（直接回车跳过）。" -ForegroundColor Gray
    Write-Host "  · 需要异地远程当 1P 房主 -> 可现在自动从官方源下载安装（也可进游戏后在「樱花助手」里一键装）。" -ForegroundColor Gray
    $ans = Read-Host "是否现在从樱花官方源下载并启动 SakuraLauncher 安装向导？(y/N)"
    if ($ans -match "^[Yy]$") {
        [void](Install-OfficialSakuraLauncher)
    }
}

Write-Host ""
Write-Host "[成功] KR-MP v$ModVer 联机补丁安装完成！" -ForegroundColor Green
Write-Host "  游戏目录  : $TargetDir"
if ($ShortcutPath) {
    Write-Host "  桌面图标  : $ShortcutPath  (已自动锁 60 FPS，无黑框)" -ForegroundColor Cyan
}
Write-Host "  目录启动器: $LauncherPath"
Write-Host ""
Write-Host "使用方法：双击桌面【王国保卫战联机版 (FL8.2.0)】，进游戏按 F10 即可联机！" -ForegroundColor Cyan
Write-Host "安全提醒：本联机补丁永久免费开源！如在闲鱼/淘宝/网盘付费购买，请立刻申请退款！" -ForegroundColor Yellow
Write-Host "KR_MP_INSTALL_OK"
Write-Host "MOD_VERSION=$ModVer"
Write-Host "TARGET_DIR=$TargetDir"
Write-Host "SHORTCUT_PATH=$ShortcutPath"
Write-Host "SAKURA_INSTALLED=$SakuraInstalled"
if (-not $Silent) {
    Write-Host ""
    $launchNow = Read-Host "现在直接启动联机版游戏吗？(直接回车立即启动，输入 N 仅退出)"
    if ($launchNow -eq "" -or $launchNow -match "^[Yy]$") {
        Start-Process -FilePath $ExeItem.FullName -ArgumentList "-fps 60" -WorkingDirectory $TargetDir
    }
}
exit 0
