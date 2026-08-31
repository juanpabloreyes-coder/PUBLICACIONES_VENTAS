@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Confirm-PUBLICACIONES_VENTAS-Updated.ps1"
pause