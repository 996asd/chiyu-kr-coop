@echo off
chcp 65001 >nul
echo ============================================================
echo   Kingdom Rush FL 8.2.0 - 联机 MOD (M0 确定性录制回放测试)
echo ============================================================
echo.
echo 进入任意关卡后，直接用鼠标点左上角状态条上的按钮即可（也支持快捷键）：
echo   [REC START (F6)]   : 开始新一局录制（自动重开本关并固定随机种子）
echo   [STOP & SAVE (F8)] : 停止录制并保存回放
echo   [REPLAY (F7)]      : 开始回放校验（默认 2 倍速 + 蓝色进度条实时滚动）
echo   [SPEED: 2x (F5)]   : 回放时循环切换 2倍速 / 4倍速 / 1倍速
echo   [RESUME GAME (F8)] : 回放结束后恢复正常手操
echo.
echo 正在同步最新 MOD 文件并启动 D:\FL8.2.0（不会影响 D:\kr 原游戏）...
powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\run_m0.ps1"
