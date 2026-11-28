param(
    [string]$TargetDir = "",
    [switch]$AutoFind,
    [switch]$Silent,
    [switch]$NoDesktopShortcut,
    [switch]$InstallSakura,
    [switch]$SkipPatch,
    [switch]$SkipSakuraPrompt,
    [string]$SourceDir = ""
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TargetFlVersion = "8.2.0"
$PreferredExe = "Kingdom Rush FL_Alliance-FL8.1.0.exe"
$Mirrors = @(
    "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/client",
    "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/client"
)

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

    foreach ($d in @((Get-Location).Path, "D:\FL8.2.0", "C:\FL8.2.0", "E:\FL8.2.0", "F:\FL8.2.0", "G:\FL8.2.0",
                     "C:\Program Files (x86)\Steam\steamapps\common\Kingdom Rush Alliance",
                     "D:\SteamLibrary\steamapps\common\Kingdom Rush Alliance",
                     "E:\SteamLibrary\steamapps\common\Kingdom Rush Alliance")) {
        Add-IfValid $d
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
        Write-Host "[警告] 无法连接樱花官方接口，请手动前往 https://www.natfrp.com/tunnel/download 下载。" -ForegroundColor Yellow
        return $false
    }
    $arch = $meta.archs.default
    $dlUrl = [string]$arch.url
    $expectMd5 = ([string]$arch.hash).ToLowerInvariant()
    $ver = ([string]$meta.ver) -replace '[^0-9A-Za-z\.\-]', ''
    $uriObj = [Uri]$dlUrl
    $hostOk = ($uriObj.Scheme -eq "https") -and ($uriObj.Host -eq "nya.globalslb.net" -or $uriObj.Host -like "*.natfrp.com" -or $uriObj.Host -like "*.globalslb.net")
    if (-not $hostOk) {
        Write-Host "[警告] 官方下载域名校验未通过，已中止。" -ForegroundColor Yellow
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
    Write-Host "[樱花映射] 官方安装包 MD5 校验通过 √，正在拉起安装向导..." -ForegroundColor Green
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

function Download-OnlinePatch([string]$StageDir) {
    $mfText = $null
    $activeMirror = $null
    foreach ($m in $Mirrors) {
        try {
            Write-Host "[下载] 正在连接官方源: $m" -ForegroundColor Cyan
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "$m/kr_mp/manifest.json" -TimeoutSec 15
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300 -and $resp.Content) {
                $mfText = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
                $activeMirror = $m
                break
            }
        } catch {
            Write-Host "  源暂不可达，尝试备用源..." -ForegroundColor Yellow
        }
    }
    if (-not $mfText -or -not $activeMirror) {
        throw "无法连接 Gitee/GitHub 官方更新源，请检查网络或下载离线压缩包安装。"
    }
    $mf = $mfText | ConvertFrom-Json
    $mfDest = Join-Path $StageDir "kr_mp\manifest.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mfDest) | Out-Null
    [System.IO.File]::WriteAllText($mfDest, $mfText, (New-Object System.Text.UTF8Encoding($false)))

    $props = New-Object System.Collections.Generic.List[object]
    if ($mf.files) {
        foreach ($p in $mf.files.PSObject.Properties) { $props.Add($p) }
    }
    if ($mf.assets) {
        foreach ($p in $mf.assets.PSObject.Properties) { $props.Add($p) }
    }
    $total = $props.Count
    Write-Host ("[下载] 发现官方最新版 KR-MP v{0}（共 {1} 个文件），正在下载并逐个校验 SHA-256..." -f $mf.version, $total) -ForegroundColor Green

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "KR-MP-OneKeyInstaller/2.3")
    $idx = 0
    foreach ($prop in $props) {
        $idx++
        $rel = $prop.Name
        if ($rel -match '\.\.' -or $rel.StartsWith("/") -or $rel.StartsWith("\")) {
            throw "清单中发现非法文件路径: $rel"
        }
        $expectSha = ([string]$prop.Value).ToLowerInvariant()
        $dest = Join-Path $StageDir ($rel -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
        $url = "$activeMirror/$rel"
        $wc.DownloadFile($url, $dest)
        $gotSha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($gotSha -ne $expectSha) {
            throw "文件完整性校验失败 (SHA-256 不一致): $rel"
        }
    }
    $wc.Dispose()
    return [string]$mf.version
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  赤羽的王国保卫战 FL $TargetFlVersion 联机补丁 · 一键全自动懒人安装器" -ForegroundColor Yellow
Write-Host "  自动定位游戏 + SHA-256 校验安装 + 自动建桌面 60FPS 快捷方式" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# If user only wants to install SakuraFrp launcher (e.g. AI agent Step 3)
if ($SkipPatch -and $InstallSakura) {
    $skNow = Test-SakuraInstalled
    if ($skNow) {
        Write-Host "[樱花映射] 本机已安装官方 SakuraFrp 启动器。" -ForegroundColor Green
    } else {
        [void](Install-OfficialSakuraLauncher)
    }
    Write-Host "SAKURA_INSTALLED=$skNow"
    exit 0
}

# Resolve target FL 8.2.0 game directory
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
            $scanDirs = @(
                (Join-Path $env:USERPROFILE "Downloads"),
                ([Environment]::GetFolderPath("Desktop"))
            ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
            $archives = New-Object System.Collections.Generic.List[object]
            foreach ($sd in $scanDirs) {
                Get-ChildItem -LiteralPath $sd -File -ErrorAction SilentlyContinue | Where-Object {
                    $_.Extension -match '^\.(zip|7z|rar)$' -and $_.Length -gt 50MB -and $_.Name -match 'FL|8\.2|Kingdom|王国|保卫战'
                } | ForEach-Object { $archives.Add($_) }
            }
            if ($archives.Count -gt 0) {
                Write-Host "KR_MP_FOUND_ARCHIVES:" -ForegroundColor Yellow
                foreach ($a in $archives) {
                    Write-Host ("  {0} ({1:N0} MB)" -f $a.FullName, ($a.Length / 1MB))
                }
            }
            $steamHits = New-Object System.Collections.Generic.List[string]
            foreach ($sr in @("C:\Program Files (x86)\Steam\steamapps\common", "D:\SteamLibrary\steamapps\common", "E:\SteamLibrary\steamapps\common")) {
                if (Test-Path -LiteralPath $sr) {
                    Get-ChildItem -LiteralPath $sr -Directory -Filter "Kingdom Rush*" -ErrorAction SilentlyContinue | ForEach-Object {
                        $steamHits.Add($_.FullName)
                    }
                }
            }
            if ($steamHits.Count -gt 0) {
                Write-Host "KR_MP_FOUND_STEAM:" -ForegroundColor Yellow
                foreach ($sh in $steamHits) { Write-Host ("  " + $sh) }
            }
            exit 3
        }
    } else {
        if ($cands.Count -eq 1) {
            Write-Host "已自动找到 FL $TargetFlVersion 游戏目录: $($cands[0].Path)" -ForegroundColor Green
            $useDet = Read-Host "直接回车安装到此目录，或输入/拖入其他 FL $TargetFlVersion 游戏目录"
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
            $pick = Read-Host "请输入序号（默认 1），或直接粘贴游戏目录路径"
            if ($pick -eq "") {
                $TargetDir = $cands[0].Path
            } elseif ($pick -match "^\d+$" -and [int]$pick -ge 1 -and [int]$pick -le $cands.Count) {
                $TargetDir = $cands[[int]$pick - 1].Path
            } else {
                $TargetDir = $pick.Trim('"').Trim()
            }
        } else {
            Write-Host "未自动找到 FL $TargetFlVersion 目录，请在弹窗中选择包含 $PreferredExe 的文件夹..." -ForegroundColor Yellow
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
    Write-Host "[错误] 目录中未找到 $PreferredExe ！请确认选择的是 FL $TargetFlVersion 解压后的游戏目录。" -ForegroundColor Red
    exit 1
}

$detVer = Get-FlVersion $TargetDir
if ($detVer -and $detVer -ne $TargetFlVersion) {
    Write-Host "[警告] 该目录的 FL 版本为 $detVer，本联机补丁仅适配 FL $TargetFlVersion！" -ForegroundColor Red
    if (-not $Silent) {
        $go = Read-Host "仍要继续吗？(输入 Y 继续，其他键取消)"
        if ($go -notmatch "^[Yy]$") { exit 1 }
    }
}

$StageDir = $null
$PatchSource = $null
$ModVer = "2.4.6"
try {
    if ($SourceDir -and (Test-Path -LiteralPath (Join-Path $SourceDir "UH.lua"))) {
        $PatchSource = (Resolve-Path -LiteralPath $SourceDir).Path
        $mfPath = Join-Path $PatchSource "kr_mp\manifest.json"
        if (Test-Path -LiteralPath $mfPath) {
            try { $ModVer = (Get-Content -LiteralPath $mfPath -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
        }
    } else {
        $StageDir = Join-Path $env:TEMP ("krmp_stage_" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $StageDir | Out-Null
        $ModVer = Download-OnlinePatch -StageDir $StageDir
        $PatchSource = $StageDir
    }

    # Backup non-KR-MP UH.lua if present
    $TargetUH = Join-Path $TargetDir "UH.lua"
    $BackupUH = Join-Path $TargetDir "UH.lua.kr_mp_backup"
    if (Test-Path -LiteralPath $TargetUH) {
        $existing = Get-Content -LiteralPath $TargetUH -Raw -ErrorAction SilentlyContinue
        if ($existing -and ($existing -notmatch "kr_mp\.boot") -and (-not (Test-Path -LiteralPath $BackupUH))) {
            Copy-Item -LiteralPath $TargetUH -Destination $BackupUH -Force
            Write-Host "[备份] 已将原有 UH.lua 备份为 UH.lua.kr_mp_backup" -ForegroundColor Yellow
        }
    }

    # Install UH.lua + kr_mp/ (preserving cached/running kr_mp/bin)
    Copy-Item -LiteralPath (Join-Path $PatchSource "UH.lua") -Destination $TargetUH -Force
    $TargetKrMp = Join-Path $TargetDir "kr_mp"
    New-Item -ItemType Directory -Force -Path $TargetKrMp | Out-Null
    Get-ChildItem -LiteralPath $TargetKrMp -Force | Where-Object { $_.Name -ne "bin" } | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath (Join-Path $PatchSource "kr_mp") -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $TargetKrMp $_.Name) -Recurse -Force
    }

    # Verify installed manifest SHA-256 (files + assets)
    $TargetManifest = Join-Path $TargetKrMp "manifest.json"
    if (Test-Path -LiteralPath $TargetManifest) {
        $mf = Get-Content -LiteralPath $TargetManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $checked = 0
        foreach ($section in @($mf.files, $mf.assets)) {
            if (-not $section) { continue }
            foreach ($prop in $section.PSObject.Properties) {
                $rel = $prop.Name -replace '/', '\'
                $fp = Join-Path $TargetDir $rel
                if (-not (Test-Path -LiteralPath $fp)) { throw "安装校验失败，缺少文件: $rel" }
                $got = (Get-FileHash -LiteralPath $fp -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($got -ne ([string]$prop.Value).ToLowerInvariant()) { throw "安装校验失败，哈希不匹配: $rel" }
                $checked++
            }
        }
        Write-Host "[校验] 全部 $checked 个补丁与资源文件 SHA-256 校验通过 √" -ForegroundColor Green
    }

    # Write folder-local 60 FPS launcher bat
    $LauncherPath = Join-Path $TargetDir "启动联机版_FL8.2.0.bat"
    $LauncherContent = @"
@echo off
cd /d "%~dp0"
start "" "$($ExeItem.Name)" -fps 60
"@
    [System.IO.File]::WriteAllText($LauncherPath, $LauncherContent, (New-Object System.Text.UTF8Encoding($false)))

    # Create Desktop .lnk shortcut
    $ShortcutPath = ""
    if (-not $NoDesktopShortcut) {
        try {
            $ShortcutPath = New-DesktopShortcut -GameDir $TargetDir -ExeFullPath $ExeItem.FullName
        } catch {
            Write-Host "[提示] 桌面快捷方式创建失败（可用目录内 bat 启动）：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $SakuraInstalled = Test-SakuraInstalled
    if ($InstallSakura) {
        if ($SakuraInstalled) {
            Write-Host "[樱花映射] 本机已安装官方 SakuraFrp 启动器。" -ForegroundColor Green
        } else {
            [void](Install-OfficialSakuraLauncher)
        }
    } elseif (-not $Silent -and -not $SkipSakuraPrompt -and -not $SakuraInstalled) {
        Write-Host ""
        Write-Host "[可选] 检测到本机未安装官方樱花映射 (SakuraFrp)：" -ForegroundColor Cyan
        Write-Host "  · 同局域网或只当 2P 队友 -> 不需要装（直接回车跳过）。" -ForegroundColor Gray
        Write-Host "  · 异地远程当 1P 房主 -> 可现在自动从官方源下载并安装（也可进游戏点「樱花助手」一键装）。" -ForegroundColor Gray
        $ans = Read-Host "是否现在从官方源下载并启动 SakuraLauncher 安装程序？(y/N)"
        if ($ans -match "^[Yy]$") {
            [void](Install-OfficialSakuraLauncher)
        }
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  [安装成功] 赤羽的王国保卫战联机补丁 KR-MP v$ModVer 已就绪！" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "  游戏目录  : $TargetDir"
    if ($ShortcutPath) {
        Write-Host "  桌面图标  : $ShortcutPath  (自动锁 60 FPS，无黑框)" -ForegroundColor Cyan
    }
    Write-Host "  目录启动器: $LauncherPath"
    Write-Host "  启动方法  : 双击桌面【王国保卫战联机版 (FL8.2.0)】，进游戏按 F10 开黑！" -ForegroundColor Yellow
    Write-Host "  防骗声明  : 本联机补丁永久免费开源！如付费购买请立刻退款！" -ForegroundColor Yellow
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
} finally {
    if ($StageDir -and (Test-Path -LiteralPath $StageDir)) {
        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
