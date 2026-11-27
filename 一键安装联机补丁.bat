@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "%~dp0tools\install_patch.ps1" goto :run
echo ============================================================
echo   [Error] Please UNZIP the archive before running!
echo   检测到你直接在压缩包预览窗口里双击了本程序，尚未解压！
echo   请先右键压缩包选择「全部解压缩」到桌面，再双击解压出来的安装程序！
echo ============================================================
pause
exit /b 1
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install_patch.ps1"
if errorlevel 1 pause
