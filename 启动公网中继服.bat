@echo off
title KR-MP Go Public Lobby ^& Frame-Relay Server (Port 17780)
cd /d D:\kr-mp-mod\server
if not exist "kr-mp-server.exe" (
    echo [KR-MP] Building kr-mp-server.exe...
    powershell -ExecutionPolicy Bypass -File "D:\kr-mp-mod\tools\build_server.ps1"
)
echo [KR-MP] Starting Go Relay Server on TCP :17780 (HTTP status :17781/health)...
echo [KR-MP] Press Ctrl+C to stop.
kr-mp-server.exe -addr :17780 -http :17781 -grace 300
pause
