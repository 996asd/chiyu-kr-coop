# KR-MP（赤羽的王国保卫战 FL 8.2.0 联机补丁）· AI 智能体一键安装协议

> 本文档专供各类具备本机终端/文件执行权限的 AI 智能体（Antigravity、Cursor、Claude Code、Codex、Trae、Windsurf、OpenClaw 等）阅读执行。
> 当用户只发给你本仓库地址并说「帮我安装王国保卫战联机补丁并建好桌面快捷方式」时，请严格按下方标准步骤完成，**无需用户手动下载或解压任何压缩包**。

---

## 0. 安全与合规铁律（绝对不可违反）

1. **零侵入保护**：严禁修改、覆盖或删除 FL 8.2.0 原版 `.exe`、`.dll` 或任何游戏素材文件；仅允许安装外挂文件 `UH.lua` 与 `kr_mp/`，以及便捷启动脚本与桌面 `.lnk` 快捷方式。
2. **禁止越权操作第三方账号**：若用户后续需要配置 SakuraFrp（樱花映射）当远程房主，**严禁**向用户索要账号密码/身份证号，**严禁**代操作实名认证、支付或绕过人机校验/UAC；下载官方安装器后交由用户本人点 UAC 与在浏览器完成注册/实名。
3. **只读原包保护**：不要把本仓库直接 `git clone` 到用户的 FL 8.2.0 游戏目录内部，避免污染游戏目录。

---

## 1. 标准全自动安装流程（Windows）

### 第 1 步：下载并运行官方统一懒人安装脚本

执行以下 PowerShell 命令（优先走国内直连 Gitee，若 Gitee 不可用自动回退 GitHub）：

```powershell
$inst = Join-Path $env:TEMP "krmp_onekey_install.ps1"
try {
    Invoke-WebRequest -UseBasicParsing -Uri "https://gitee.com/chiyu-studio/chiyu-kr-coop/raw/main/tools/onekey_install.ps1" -OutFile $inst -TimeoutSec 20
} catch {
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/996asd/chiyu-kr-coop/main/tools/onekey_install.ps1" -OutFile $inst -TimeoutSec 20
}
powershell -ExecutionPolicy Bypass -File $inst -AutoFind -Silent
```

该脚本会自动完成以下全部工作：
1. 从官方源拉取最新 `client/kr_mp/manifest.json` 及全部补丁文件，逐个做 **SHA-256 完整性校验**；
2. 自动扫描本机常见盘符、桌面、下载目录、`SteamLibrary` 等位置定位 **FL 8.2.0** 游戏目录（核验 `Kingdom Rush FL_Alliance*.exe` 与 `main_globals.lua` 中 `KR_FL_VERSION = "8.2.0"`）；
3. 安全备份原有非 KR-MP 的 `UH.lua`（如有），安装最新 `UH.lua` 与 `kr_mp/` 并二次校验文件完整性；
4. 生成目录内 `启动联机版_FL8.2.0.bat`，并自动在用户桌面创建带游戏原版图标的快捷方式：**`王国保卫战联机版 (FL8.2.0).lnk`**（自动附带 `-fps 60` 参数，双击无黑框）；
5. 静默检测本机是否已安装官方 SakuraFrp 启动器（只读检测，不改系统配置）。

### 第 2 步：根据脚本退出码处理结果

- **退出码 `0`（安装成功）**：
  - 标准输出会包含结构化结果行：
    - `KR_MP_INSTALL_OK`
    - `MOD_VERSION=...`
    - `TARGET_DIR=...`
    - `SHORTCUT_PATH=...`
    - `SAKURA_INSTALLED=True|False`
  - 直接进入第 3 步验收并向用户汇报！
- **退出码 `2`（发现多个 FL 8.2.0 目录）**：
  - 标准输出会列出 `KR_MP_MULTI_CANDIDATES:` 下的所有候选路径。
  - 向用户展示候选路径，待用户选定后重新执行：
    ```powershell
    powershell -ExecutionPolicy Bypass -File $inst -TargetDir "<用户选中的目录>" -Silent
    ```
- **退出码 `3`（未自动找到 FL 8.2.0 游戏目录）**：
  - 提示用户提供其电脑上 FL 8.2.0 游戏文件夹路径（内含 `Kingdom Rush FL_Alliance-FL8.1.0.exe`），拿到路径后执行：
    ```powershell
    powershell -ExecutionPolicy Bypass -File $inst -TargetDir "<用户提供的目录>" -Silent
    ```
- **退出码 `1`（参数无效或网络/校验异常）**：
  - 读取错误输出向用户说明原因（如目标目录不是 FL 8.2.0，或网络受限）。

### 第 3 步：樱花映射（SakuraFrp）按需引导（仅 1P 远程房主需要）

- **重要提醒**：**只有异地远程建房的房主（1P）需要樱花映射；队友（2P）与同 Wi-Fi 局域网玩家完全不需要安装或注册樱花！**
- 若用户明确表示要当异地远程房主，且输出中 `SAKURA_INSTALLED=False`：
  - 方式 A（推荐，免命令行）：告诉用户打开游戏 → 按 `F10` → 在「樱花联机」页点 **「一键装樱花」** 或 **「樱花助手」**，游戏内置了 4 步交互向导，可直接从官方源下载并校验安装包、直达注册/实名/复制密钥页面。
  - 方式 B（由脚本下载官方安装器）：若用户希望你顺手帮他把官方樱花安装包下好并打开安装向导，执行：
    ```powershell
    powershell -ExecutionPolicy Bypass -File $inst -TargetDir "<已安装的游戏目录>" -SkipPatch -InstallSakura -Silent
    ```
    脚本会从官方接口 `https://api.natfrp.com/v4/system/clients` 下载最新 `SakuraLauncher.exe`、校验 MD5 并拉起安装程序，此时请提示用户在系统弹窗中亲自确认 UAC 并按向导完成安装。

### 第 4 步：向用户清晰汇报

安装完成后，简明列出：
1. 已安装的联机补丁版本（`MOD_VERSION`）与游戏目录（`TARGET_DIR`）；
2. 已创建的桌面快捷方式路径（`SHORTCUT_PATH`，已自动配置 `-fps 60` 锁帧防不同步）；
3. 启动方式：直接双击桌面 **`王国保卫战联机版 (FL8.2.0)`** → 进游戏按 **`F10`**（或点左上角「联机大厅」）即可开黑，大厅右上角内置「新手教程」与「樱花助手」。

---

## 2. 卸载说明（若用户要求无痕卸载）

删除游戏目录中的 `kr_mp\`、将 `UH.lua.kr_mp_backup`（如有）还原为 `UH.lua`（否则删除 `UH.lua`），并删除 `启动联机版_FL8.2.0.bat` 与桌面快捷方式 `王国保卫战联机版 (FL8.2.0).lnk` 即可，不会损坏原版游戏或单机存档。
