# AGENTS.md — KR-MP (Kingdom Rush FL 8.2.0 联机 MOD) AI 协作开发与修复宪法

> 本文档面向所有 AI 编程助手（Cursor、Antigravity、Trae、Claude Code、Codex、DeepSeek 等）与开源贡献者。修改本项目任何代码前，请务必先阅读本文件中的架构地图、铁律与验证方法。

---

## 1. 项目定位与架构铁律（绝对不可违反）

1. **零侵入外挂补丁架构**：
   - 本项目只包含纯外挂 Lua Hook（`client/UH.lua` + `client/kr_mp/`）与独立 Go 服务端（`server/`）。
   - **严禁**修改、覆盖或提交 FL 8.2.0 原版 `.exe`、`.dll`、贴图、音频或任何游戏资源文件（游戏目录约 3 GB，仅作只读参考）。
   - FL 8.2.0（启动器 `Kingdom Rush FL_Alliance-FL8.1.0.exe`，`main_globals.lua` 中 `KR_FL_VERSION = "8.2.0"`）启动时会通过 `mod.lua` / `all/director.lua` 自动加载同目录下的 `UH.lua -> UH:init()`，这是唯一入口。
2. **60Hz 确定性帧同步铁律（防 DESYNC 核心）**：
   - 双端只同步操作指令（每 3 帧一个 Turn，2 个 Turn 输入缓冲），不广播实体坐标。
   - **严禁**在战斗逻辑（`sim:do_tick`）内直接调用原生 `math.random` 或依赖无序 `pairs()`。
     - 纯视觉/音效/UI 逻辑中若用到随机，必须包在 `prng:enter_visual()` / `prng:exit_visual()` 内。
     - `store.entities` / `store.waves_active` / `store.manual_wave_cos` 必须通过 `hooks.lua` 的确定性排序迭代器遍历。
     - FL 8.2.0 新增的 `klove.sso` 空间索引：网格原点固定为 `(0, 0, 2048, 1280)`（不随窗口比例变化），`SSO.filter` 结果按 `e.id` 升序，`SSO.persistent_lists` 走确定性数字键遍历。
     - FL 8.2.0 的 `all/simulation.lua:prepare_render()` 以渲染帧率运行（含 `particle_system` 到期），只能做纯视觉；纯视觉粒子不计入 `state_hash.lua` 的实体数。
   - **纯本地 UI 实体隔离**：任何仅本地渲染的预览/悬浮/路径指示实体，必须带有 `_kr_mp_local = true` 且分配在 `LOCAL_ID_BASE = 100000000` 空间内，绝不能污染仿真 `E.last_id`，且在 `state_hash.lua` 中必须跳过。
   - **UI 坐标量化**：所有发往联机的世界坐标（英雄移动、技能落点、地图打点）必须经 `commands.lua` 整数/固定精度量化，避免不同窗口分辨率导致浮点分叉。
   - **禁止使用 `os.clock()` / `love.timer.getTime()` 驱动战斗逻辑**：只可用于 UI 动画、Toast 倒计时、网络心跳与重连超时。
3. **跨平台/中文编码与体积控制**：
   - 所有 Lua、Go、文档与脚本统一使用 **UTF-8（无 BOM）**。
   - 中文字体直接复用 FL 8.2.0 内置的 `all-desktop/assets/fonts/HarmonyOS_Sans_SC.ttf`（经 `client/kr_mp/fonts.lua` 加载），不要塞入外部字体文件。注意不要使用鸿蒙简中字体缺失的生僻符号（例如勾选请用 `√`，不要用 `✓`）。
4. **先验证再提交**：
   - 修改 `client/` 代码后必须同步到沙盒并跑通回归验证；修改 `server/` 代码后必须通过 `go vet ./...` 与 `go build`。
5. **防“屎山”模块化与可维护性铁律**：
   - **扁平模块结构**：所有客户端 Lua 模块统一扁平放在 `client/kr_mp/*.lua`（不要建子目录），确保 PC/安卓增量 OTA 热更新器与打包脚本 100% 兼容。
   - **统一补丁注册**：新增引擎 Hook 必须通过 `hooks.wrap_once(tbl, key, tag, builder)` 或 `hooks.wrap_local_ui(tbl, method)` 注册，**禁止**往原版引擎对象上零散粘贴新的 `_kr_mp_*_wrapped` 标记。
   - **体积与职责边界**：新文件及重构后模块尽量控制在 **≤ 1,000 行**、单个业务/渲染函数尽量 **≤ 150 行**；超过 6 个分支的指令/消息/按钮分发优先使用表驱动（`HANDLERS[key]`）。
   - **测试与业务解耦**：多进程自动化回归测试逻辑统一放在 `client/kr_mp/autotest.lua`，禁止混入正式大厅状态机或 UI 渲染文件。
   - **校验规则单点收口**：前后端（拦截层 `hooks_gui_actions.lua` 与执行层 `commands.lua`）共用的权限、价格或坐标量化逻辑只写一份共享函数，禁止双边手抄。

---

## 2. 仓库目录地图

```text
kr-mp-mod/
├── client/                     # 客户端外挂补丁源码（发给玩家的全部代码）
│   ├── UH.lua                  # FL 8.2.0 自动加载入口（调用 kr_mp.boot）
│   └── kr_mp/
│       ├── boot.lua            # 引导器、日志（含崩溃保留上一份日志）、love.* 回调包装、HUD 动作分发
│       ├── proto.lua           # 协议版本号、纯 Lua 安全 JSON 编解码、FL 核心脚本哈希（FNV-1a）
│       ├── prng.lua            # 双流 Mulberry32 确定性 PRNG（sim 战斗流 vs vis 视觉流）
│       ├── state_hash.lua      # 每 30 帧 32-bit FNV-1a 状态哈希（金币/血量/波次/PRNG/实体）
│       ├── hooks.lua           # Hook 总协调器与弱表注册器（hooks.wrap_once / hooks.wrap_local_ui / 本地实体隔离判定）
│       ├── hooks_determinism.lua # 确定性 pairs/filter/协程、SSO 空间网格、双 ID 空间、A*缓存绕过、跳过漫画、存档快照
│       ├── hooks_sim.lua       # sim.init/update/do_tick 锁步驱动、main_script 隔离排序、医疗包确定性、game 生命周期
│       ├── hooks_gui_actions.lua # 战斗操作拦截（技能/英雄/援军拖拽/建塔升级/换塔/打点/出怪/快捷键）
│       ├── hooks_gui_guards.lua  # UI 到仿真泄露隔离（trigger_deselect/menu_shown/PauseView/DragEntityView 保护）
│       ├── commands.lua        # 表驱动指令队列与执行器（HANDLERS[op]，含单点价格/坐标量化）
│       ├── lockstep.lua        # 60Hz 帧同步状态机（LOAD_DONE 屏障、1x/2x 倍速、断线保局、对称 DESYNC_DIAG、高速追帧重连）
│       ├── coop.lua            # 2P 合作层（双英雄归属、独立/共享经济账本、红蓝塔权、上下文护栏、世界标签与打点渲染）
│       ├── coop_loadout.lua    # 2P 战前军械配置（天灾/援军/满科技补丁、G4/G5 分支模板与双端资源预加载）
│       ├── stage_flow.lua      # 战后自动下一关、原地重开与双人表决流转器
│       ├── catalog.lua         # FL 8.2.0 完整中文目录（201 关 + 105 英雄 + 59 座防御塔）
│       ├── fonts.lua           # 复用内置 HarmonyOS_Sans_SC.ttf 的字号缓存器
│       ├── ui_assets.lua       # 皇家战桌铁皮羊皮纸/木纹/蜡封/缩略图/声波等复用 UI 组件库
│       ├── lobby_ui.lua        # 联机大厅核心状态机、房间消息路由（MSG_HANDLERS）、开局与不断线返回战桌
│       ├── lobby_net.lua       # 局域网/樱花/公网连接动作、自动重连定时器与表驱动传输事件分发
│       ├── lobby_prefs.lua     # 偏好与上次房间配置持久化、直连/公网重连会话、樱花电信/移动线路切换与剪贴板工具
│       ├── lobby_input.lua     # 大厅键盘/鼠标输入与表驱动按钮分发（BTN_HANDLERS）
│       ├── lobby_draw.lua      # 皇家战桌首页与备战房间主渲染器
│       ├── lobby_draw_modals.lua # 新手教程 / 201 关 / 105 英雄 / 59 选 12 塔 / 战前军械 / 语音调音弹窗渲染器
│       ├── lobby_draw_sakura.lua # 樱花映射专属助手弹窗（免密钥感知/官方下载进度/4步新手向导/翻页节点/防窥打码）
│       ├── lobby_draw_server.lua # 傻瓜式一键开服助手弹窗（本机零成本开17780服/樱花17780联动/云服1行命令）
│       ├── lobby_draw_report.lua # 报错诊断与反馈弹窗（云端一键生成 #R-XXXX 反馈码 + 本地离线 .json 导出）
│       ├── diagnostics.lua     # 滚存黑匣子记录、脱敏、manifest 完整性校验、崩溃自救与一键本地导出
│       ├── diagnostics_cloud.lua # 第 3 层自愿云端报错上传引擎（复用公网连接或独立非阻塞短连，绝不打断樱花/局域网房）
│       ├── win_util.lua        # 共享 Windows FFI / 路径 / WinINet 网络工具（sakura / server_host / updater 单点复用）
│       ├── sakura.lua          # 樱花映射深度适配（只读状态与日志感知、官方安装器一键下载、三线测速、OpenAPI v4、无窗 frpc 托管）
│       ├── sakura_workers.lua  # 樱花后台 love.thread 线程脚本（三线测速 / OpenAPI v4 / 官方安装器流式下载与 MD5 校验）
│       ├── server_host.lua     # 本机公网中继服一键下载校验、无窗托管启停（退游戏保活）与樱花 17780 联动
│       ├── autotest.lua        # M1/M2 多进程自动化联机回归测试驱动（与正式 UI 完全解耦）
│       ├── overlay.lua         # 顶部居中紧凑中文 HUD（金币/延迟/校验/倍速/暂停/转50金/语音调音/追帧进度条）
│       ├── voice.lua           # 内置低延迟双向连麦语音控制状态机与安卓 LÖVE Audio 后端
│       ├── voice_codec.lua     # 共享 RFC 4648 Base64 与 16kHz IMA-ADPCM 编解码（PC/安卓逐位互通单点实现）
│       ├── voice_winmm.lua     # Windows WinMM 独立采集/播放 love.thread 线程脚本
│       ├── transport.lua       # 局域网与公网统一传输层抽象
│       ├── tcp_stream.lua      # 共享非阻塞 DNS + TCP 行协议流引擎（防 HoL 语音队列、O(N) 分帧、心跳与 12s 看门狗）
│       ├── net_lan.lua         # 局域网/樱花直连 TCP + UDP 17778 广播自动发现
│       ├── net_online.lua      # 公网 Go 中继服 TCP 客户端
│       ├── updater.lua         # love.thread + WinINet/LuaHTTPS 后台检查与 SHA-256 增量热更新（Gitee 主源 / GitHub 备源）
│       ├── replay.lua          # M0 单机录制/回放确定性验证器（F6/F7/F8）
│       └── manifest.json       # 自动生成的官方文件 SHA-256 清单（供 OTA 热更、报错诊断与修改导出比对）
├── server/                     # 零依赖 Go 公网大厅与帧中继服务端
│   ├── go.mod
│   ├── protocol.go             # 协议结构（原样透传 Lua JSON，SetEscapeHTML(false)）
│   ├── room.go                 # Hub/Room/Seat 核心结构、IP 限流、房间列表与过期清理
│   ├── room_lobby.go           # 消息分发、大厅建房/加房/更新/房客配置与返回战桌
│   ├── room_match.go           # 开局同步、LOAD_DONE 屏障、帧转发、连关流转与语音/诊断透传
│   ├── room_reconnect.go       # 断线保局、大厅/对局高速追帧重连与补帧
│   ├── report_store.go         # 第 3 层云端报错接收/限流/滚存/6位反馈码 (#R-XXXX) 与受保护 HTTP 检索
│   ├── report_test.go          # 云端报错存储、限流、防路径穿越与 HTTP 鉴权单元测试
│   ├── security_test.go        # 服务端防 OOM / IP 限流 / 大厅重连 / 直接连关单元测试
│   └── main.go                 # 非阻塞 TCP 连接循环 + 可选 HTTP /health 探针
├── tools/                      # 构建、测试、安装、社区报错与修复脚本
│   ├── sync_client.ps1         # 同步 client/ -> D:\FL8.2.0\（本机 FL 8.2.0 测试目录）
│   ├── generate_manifest.ps1   # 生成 client/kr_mp/manifest.json
│   ├── build_server.ps1        # 编译 Windows + Linux 静态单文件服务端
│   ├── build_android_apk.py    # 安卓 FL 8.2.0 联机整合 APK 构建工具
│   ├── package_release.ps1     # 打包轻量客户端包 & 完整服务端包到 dist/
│   ├── publish_release.ps1     # GitHub + Gitee 双平台自动推送与 Release 附件发布脚本
│   ├── setup_release_tokens.ps1 # 维护者本机发行版发布 Token 配置助手
│   ├── setup_sandbox.ps1       # 从原始 FL 8.2.0 压缩包初始化独立沙盒目录
│   ├── check_replay.py         # 对比两份每 30 帧哈希日志，精确定位首帧分叉字段
│   ├── run_m0.ps1              # M0 单机录制/回放确定性回归测试
│   ├── run_m1_dual.ps1         # 局域网双开自动联机回归测试
│   ├── run_m2_test.ps1         # 公网三进程（含 960 帧强退追帧重连 + 混搭卡组 + 2x 倍速）回归测试
│   ├── run_m4_sakura_test.ps1  # 樱花映射热续传/冷重连自动化回归测试
│   ├── collect_bug_report.ps1  # 群友双击：一键打包报错日志、哈希与 AI 提问词
│   ├── replay_blackbox.ps1     # 维护者：读取玩家 .json 黑匣子以 30 倍速本地确定性复现（可选 DESYNC 帧深度追踪）
│   ├── fetch_report.ps1        # 维护者：按反馈码 (#R-XXXX) 列表/拉取公网服报错速览，支持 -Replay 一键联动复现
│   ├── install_patch.ps1       # 离线补丁安装器（自动找目录 / SHA-256 校验 / 自动建桌面快捷方式 / 可选下载官方樱花）
│   ├── uninstall_patch.ps1     # 一键干净卸载联机外挂补丁脚本
│   ├── onekey_install.ps1      # 在线/离线统一懒人安装器（支持 irm|iex 与 AI 智能体 -AutoFind -Silent 静默全自动安装）
│   ├── deploy_server.sh        # Linux 云服务器 1 行全自动开服脚本（自动下载校验 + systemd 常驻 + 防火墙放行）
│   ├── export_my_fix.ps1       # 群友双击：比对 manifest.json 一键导出精简修复补丁包
│   ├── apply_community_fix.ps1 # 维护者双击：预览、备份、应用并自动测试群友提交的修复包
│   └── setup_repo_sync.ps1     # 维护者双击：配置 GitHub + Gitee 双远端并同步推送
├── version.json                # 线上最新版本号元数据（大厅检查更新读取此文件）
├── AI_INSTALL.md               # 面向 AI 智能体的单地址全自动安装与创建桌面快捷方式标准协议
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
   - 某关卡需要特殊前置状态或过场（参考 `hooks.lua` 中对 `level_utils` / `level_utils_5` / `level_utils_57` / `level_utils_6` 的 `load_level` 跳过漫画处理）；
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

# 3. 跑全自动确定性联机回归（需本机存在 D:\FL8.2.0\，可用 tools\setup_sandbox.ps1 从 FL 8.2.0 压缩包解压）
powershell -ExecutionPolicy Bypass -File tools\run_m2_test.ps1
powershell -ExecutionPolicy Bypass -File tools\run_m1_dual.ps1 -AutoCoopTest

# 4. 打包最新双份发行包（输出到 dist/）
powershell -ExecutionPolicy Bypass -File tools\package_release.ps1
```
