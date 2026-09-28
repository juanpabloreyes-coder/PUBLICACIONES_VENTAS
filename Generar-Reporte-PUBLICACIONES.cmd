@echo off
REM Genera Data\PUBLICACIONES_VENTAS.json y Dashboard\Publicaciones-Modelos-Report.html
REM leyendo Forma (APS) + RevitSyncLog + Excel de equipos. No necesita Power BI.
cd /d "%~dp0"
python -m pub_sync run
if errorlevel 1 pause
