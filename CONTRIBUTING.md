# 参与贡献与提交修复指南（CONTRIBUTING）

非常欢迎各位王国保卫战玩家、MOD 同好以及使用 AI 辅助编程的朋友一起完善 **KR-MP**！无论你懂不懂 Git，都可以通过下面任一通道轻松参与：

---

## 通道一：普通群友（零门槛，无需懂 Git）

1. **反馈 Bug / 不同步**：
   - 双击补丁包里的 **`一键收集报错包.bat`** 生成 `KR-MP-报错诊断包-*.zip`。
   - 将压缩包发到玩家群，或在 GitHub / Gitee 仓库的 **Issues** 页面新建工单并拖入附件。
2. **提交你用 AI 修好的补丁**：
   - 改好本机 `kr_mp\` 并实测联机无分叉后，双击 **`一键导出我的修改.bat`**。
   - 将生成的 `KR-MP-群友修复补丁-*.zip` 发到群里或贴在 Issue 评论区。
   - 维护者会使用 `tools\apply_community_fix.ps1` 自动预览差异并跑 M1/M2 双开同步回归测试，通过后即合入正式版！

---

## 通道二：GitHub / Gitee 开发者与 AI 编程工具（PR 流程）

仓库同时托管在 **GitHub** 与 **Gitee（国内直连镜像）**，两边均接受 Issue 与 Pull Request：

1. 先阅读根目录的 **[AGENTS.md](./AGENTS.md)**（架构地图与 60Hz 确定性铁律）。
2. Fork 本仓库并创建功能/修复分支（如 `fix/stage-35-desync`）。
3. **严禁提交原版游戏文件**（`.exe`、`.dll`、`game-sandbox/`、`dist/`、`logs/` 已由 `.gitignore` 屏蔽，请勿强制添加）。
4. 修改客户端代码后，运行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\generate_manifest.ps1
   ```
5. 若本机已配置测试沙盒，请运行双开回归测试确认 100% 同步匹配：
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\run_m2_test.ps1
   powershell -ExecutionPolicy Bypass -File tools\run_m1_dual.ps1 -AutoCoopTest
   ```
6. 提交 PR，按模板写明修复的场景（关卡/英雄/现象）及测试结果即可。
