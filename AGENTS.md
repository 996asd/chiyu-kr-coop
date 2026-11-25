# AGENTS.md — KR-MP (Kingdom Rush FL 4.1.0 联机 MOD) AI 协作开发与修复宪法

> 本文档面向所有 AI 编程助手（Cursor、Antigravity、Trae、Claude Code、Codex、DeepSeek 等）与开源贡献者。修改本项目任何代码前，请务必先阅读本文件中的架构地图、铁律与验证方法。

---

## 1. 项目定位与架构铁律（绝对不可违反）

1. **零侵入外挂补丁架构**：
   - 本项目只包含纯外挂 Lua Hook（`client/UH.lua` + `client/kr_mp/`）与独立 Go 服务端（`server/`）。
   - **严禁**修改、覆盖或提交 FL 4.1.0 原版 `.exe`（1.5 GB）、贴图、音频或任何游戏资源文件。
   - FL 4.1.0 启动时会通过 `all/director.lua` 自动加载同目录下的 `UH.lua -> mod:init()`，这是唯一入口。
2. **60Hz 确定性帧同步铁律（防 DESYNC 核心）**：
   - 双端只同步操作指令（每 3 帧一个 Turn，2 个 Turn 输入缓冲），不广播实体坐标。
   - **严禁**在战斗逻辑（`sim:do_tick`）内直接调用原生 `math.random` 或依赖无序 `pairs()`。
     - 纯视觉/音效/UI 逻辑中若用到随机，必须包在 `prng:enter_visual()` / `prng:exit_visual()` 内。
     - `store.entities` / `store.waves_active` / `store.manual_wave_cos` 必须通过 `hooks.lua` 的确定性排序迭代器遍历。
   - **纯本地 UI 实体隔离**：任何仅本地渲染的预览/悬浮/路径指示实体，必须带有 `_kr_mp_local = true` 且分配在 `LOCAL_ID_BASE = 100000000` 空间内，绝不能污染仿真 `E.last_id`，且在 `state_hash.lua` 中必须跳过。
   - **UI 坐标量化**：所有发往联机的世界坐标（英雄移动、技能落点、地图打点）必须经 `commands.lua` 整数/固定精度量化，避免不同窗口分辨率导致浮点分叉。
   - **禁止使用 `os.clock()` / `love.timer.getTime()` 驱动战斗逻辑**：只可用于 UI 动画、Toast 倒计时、网络心跳与重连超时。
3. **跨平台/中文编码与体积控制**：
   - 所有 Lua、Go、文档与脚本统一使用 **UTF-8（无 BOM）**。
   - 中文字体直接复用 FL 4.1.0 内置的 `kr3-desktop/assets/fonts/HarmonyOS_Sans_SC_Regular.ttf`（经 `client/kr_mp/fonts.lua` 加载），不要塞入外部字体文件。注意不要使用鸿蒙简中字体缺失的生僻符号（例如勾选请用 `√`，不要用 `✓`）。
4. **先验证再提交**：
   - 修改 `client/` 代码后必须同步到沙盒并跑通回归验证；修改 `server/` 代码后必须通过 `go vet ./...` 与 `go build`。

---

## 2. 仓库目录地图

```text
kr-mp-mod/
├── client/                     # 客户端外挂补丁源码（发给玩家的全部代码）
│   ├── UH.lua                  # FL 4.1.0 自动加载入口（调用 kr_mp.boot）
│   └── kr_mp/
│       ├── boot.lua            # 引导器、日志（含崩溃保留上一份日志）、love.* 回调包装、HUD 动作分发
│       ├── proto.lua           # 协议版本号、纯 Lua 安全 JSON 编解码、FL 核心脚本哈希（FNV-1a）
│       ├── prng.lua            # 双流 Mulberry32 确定性 PRNG（sim 战斗流 vs vis 视觉流）
│       ├── state_hash.lua      # 每 30 帧 32-bit FNV-1a 状态哈希（金币/血量/波次/PRNG/实体）
│       ├── hooks.lua           # 核心引擎钩子（确定性 pairs/filter/协程、双 ID 空间、A*缓存绕过、跳过漫画、sim.update 锁步驱动）
│       ├── commands.lua        # 12 类原版操作 + SEND_GOLD / MAP_PING / SYNC_PAUSE 的拦截、校验与重放
│       ├── lockstep.lua        # 60Hz 帧同步状态机（LOAD_DONE 屏障、1x/2x 倍速、断线保局、高速追帧重连）
│       ├── coop.lua            # 2P 合作层（双英雄归属、独立/共享经济账本、红蓝塔权、41选12卡组快照、世界标签与打点渲染）
│       ├── catalog.lua         # FL 4.1.0 完整中文目录（100 关 + 67 英雄 + 41 座防御塔）
│       ├── fonts.lua           # 复用内置 HarmonyOS_Sans_SC_Regular.ttf 的字号缓存器
│       ├── lobby_ui.lua        # 全中文双模式大厅（局域网 + 公网服务器 + 三大选择器 + 一键重连 + 自动化测试驱动）
│       ├── overlay.lua         # 顶部居中紧凑中文 HUD（金币/延迟/校验/倍速/暂停/转50金/追帧进度条）
│       ├── transport.lua       # 局域网与公网统一传输层抽象
│       ├── net_lan.lua         # 局域网 TCP + UDP 17778 广播自动发现
│       ├── net_online.lua      # 公网 Go 中继服 TCP 客户端
│       ├── updater.lua         # love.thread + WinINet 后台无黑框异步检查新版本（Gitee 主源 / GitHub 备源）
│       ├── replay.lua          # M0 单机录制/回放确定性验证器（F6/F7/F8）
│       └── manifest.json       # 自动生成的官方文件 SHA-256 清单（供报错诊断与修改导出比对）
├── server/                     # 零依赖 Go 公网大厅与帧中继服务端
│   ├── go.mod
│   ├── protocol.go             # 协议结构（原样透传 Lua JSON，SetEscapeHTML(false)）
│   ├── room.go                 # 房间状态机、历史帧缓存与高速追帧重连计算、定时清理
│   └── main.go                 # 非阻塞 TCP 连接循环 + 可选 HTTP /health 探针
├── tools/                      # 构建、测试、安装、社区报错与修复脚本
│   ├── sync_client.ps1         # 同步 client/ -> game-sandbox/
│   ├── generate_manifest.ps1   # 生成 client/kr_mp/manifest.json
│   ├── build_server.ps1        # 编译 Windows + Linux 静态单文件服务端
│   ├── package_release.ps1     # 打包轻量客户端包 & 完整服务端包到 dist/
│   ├── check_replay.py         # 对比两份每 30 帧哈希日志，精确定位首帧分叉字段
│   ├── run_m1_dual.ps1         # 局域网双开自动联机回归测试
│   ├── run_m2_test.ps1         # 公网三进程（含 960 帧强退追帧重连 + 混搭卡组 + 2x 倍速）回归测试
│   ├── collect_bug_report.ps1  # 群友双击：一键打包报错日志、哈希与 AI 提问词
│   ├── export_my_fix.ps1       # 群友双击：比对 manifest.json 一键导出精简修复补丁包
│   ├── apply_community_fix.ps1 # 维护者双击：预览、备份、应用并自动测试群友提交的修复包
│   └── setup_repo_sync.ps1     # 维护者双击：配置 GitHub + Gitee 双远端并同步推送
├── version.json                # 线上最新版本号元数据（大厅检查更新读取此文件）
├── AI修复指南.md                # 面向群友的 AI 自助排错与投稿说明（随补丁包一起分发）
├── CONTRIBUTING.md             # 贡献规范（小白压缩包投稿 + GitHub/Gitee PR 双通道）
└── README.md                   # 完整玩家使用与自建公网服说明书
```

---

## 3. 常见 Bug 定位手册（AI 排错速查）

### 场景 A：联机中途提示「同步异常 / DESYNC」
1. 对比双方日志里的每 30 帧校验记录（`kr_mp_hashes.log` 或 `mp_p1_hashes.log` vs `mp_p2_hashes.log`）：
   ```powershell
   python tools\check_replay.py <P1哈希日志> <P2哈希日志>
   ```
2. 看首帧分叉是哪个字段先变：
   - **`rng` 先分叉**：某个英雄技能、塔特效或 UI 回调在战斗外消费了 `sim` 随机数流 → 检查对应回调是否漏加 `prng:enter_visual()` / `exit_visual()`。
   - **`ents` 或 `hp` 先分叉**：某个实体模板或关卡脚本依赖了原生 `pairs()` 遍历顺序，或漏同步了一个点击操作 → 检查 `commands.lua` 是否拦截了该 GUI 方法，或 `hooks.lua` 是否需把新表加入确定性排序。
   - **`gold` 先分叉**：某特殊机制直接改写了 `store.player_gold` → 检查 `coop.lua` 中的 `on_tick_begin` / `on_system_gold_delta` 逻辑。
3. 深度抓帧环境变量（本地双开复现时可开启）：
   - `KR_MP_TRACE_RNG_FROM=900` & `KR_MP_TRACE_RNG_TO=960`：逐次打印指定帧区间内所有 `math.random` 调用栈；
   - `KR_MP_TRACE_ENTITIES=1`：追踪实体创建属于 `[SIM]` 还是 `[LOCAL]`。

### 场景 B：特定关卡或英雄进入战斗时 Lua 报错崩溃
1. 查看玩家报错包里的 `kr_mp.log`（或 `kr_mp_prev.log`）末尾的 `!!! LUA CRASH !!!` 堆栈。
2. 常见问题来源：
   - 某关卡需要特殊前置状态或过场（参考 `hooks.lua` 中 `LU.load_level` 跳过漫画的处理）；
   - 某英雄在 `slot_snapshot.heroes.status` 中缺少默认字段（检查 `coop.lua:build_host_slot_snapshot`）；
   - 某塔或英雄贴图组未预加载（参考原版 `all/director.lua` 的 `scale_required_textures` 逻辑）。

### 场景 C：大厅/公网/重连异常
- 协议变更必须同步更新 `client/kr_mp/proto.lua` 和 `server/protocol.go` 的 `PROTOCOL_VER`（仅破坏性变更时递增）。
- Go 服务端所有发往 Lua 的房间/指令字段保持 `json.RawMessage` 原样透传，且编码器必须保持 `SetEscapeHTML(false)`。

---

## 4. 改完代码后的标准验证命令

```powershell
# 1. 同步客户端并生成最新文件校验清单
powershell -ExecutionPolicy Bypass -File tools\generate_manifest.ps1
powershell -ExecutionPolicy Bypass -File tools\sync_client.ps1

# 2. 若改了服务端，检查 Go 代码并重新编译
cd server; go vet ./...; cd ..
powershell -ExecutionPolicy Bypass -File tools\build_server.ps1 -Linux

# 3. 跑全自动确定性联机回归（需本机存在 game-sandbox/）
powershell -ExecutionPolicy Bypass -File tools\run_m2_test.ps1
powershell -ExecutionPolicy Bypass -File tools\run_m1_dual.ps1 -AutoCoopTest

# 4. 打包最新双份发行包（输出到 dist/）
powershell -ExecutionPolicy Bypass -File tools\package_release.ps1
```
