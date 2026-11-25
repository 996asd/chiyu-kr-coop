@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tools\publish_release.ps1"
pause
