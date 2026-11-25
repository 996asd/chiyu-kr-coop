@echo off
chcp 65001 >nul
echo ============================================================
echo   Kingdom Rush FL 8.2.0 - 联机 MOD (M1 本机双开 / 局域网 2P 合作)
echo ============================================================
echo.
echo 双开操作只需 3 步：
echo   1. 左边窗口 (1P 蓝队)：点 [CREATE LAN ROOM (1P Host)] 创建局域网房间
echo   2. 右边窗口 (2P 红队)：点 [QUICK JOIN 127.0.0.1] 或下方自动发现的房间加入
echo   3. 左边窗口 (1P 房主)：选关卡 / 金币模式(独立或共享) / 塔权保护(红蓝或开放) / 双英雄，点 [START 2P CO-OP MATCH!]
echo.
echo 局内操作：
echo   - 1P 控 1号英雄 + 1号大招 + 自己的援军；2P 控 2号英雄 + 2号大招 + 自己的援军
echo   - Alt + 左键地图任意位置：向队友发送地图打点信号 (Map Ping)
echo   - 顶部 [+50g] 按钮：独立金币模式下随时给队友转钱
echo   - 空格键 / [PAUSE]：双方同步暂停或恢复
echo.
echo 正在同步最新 MOD 并启动左右双窗口（绝不影响 D:\kr 原游戏）...
powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\run_m1_dual.ps1"
