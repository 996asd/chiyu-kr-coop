# CLAUDE.md

请优先完整阅读根目录的 [AGENTS.md](./AGENTS.md)，其中包含本项目的完整目录地图、60Hz 帧同步确定性铁律、常见 DESYNC/崩溃定位手册与标准回归验证命令。

核心速记：
- **零侵入原则**：只修改 `client/UH.lua`、`client/kr_mp/*.lua`、`server/*.go` 或 `tools/*`，绝不触碰原版 FL 8.2.0 游戏 `.exe` 或素材。
- **同步红线**：战斗内禁止引入无序 `pairs()`、未隔离的 `math.random` 或墙钟时间；纯本地 UI 实体必须走 `LOCAL_ID_BASE`（`_kr_mp_local = true`）。
- **改动后必做**：更新 `client/kr_mp/manifest.json`（`tools\generate_manifest.ps1`），并尽量通过 `tools\run_m2_test.ps1` 与 `tools\run_m1_dual.ps1 -AutoCoopTest` 验证零分叉。
