@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0tools\setup_release_tokens.ps1" -OpenPages
pause
