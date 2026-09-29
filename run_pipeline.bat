@echo off
REM Genera el reporte de PUBLICACIONES_VENTAS SOLO el ultimo dia de cada mes (igual que PLANOS_VENTAS).
REM Se lanza todos los dias a las 23:59 (ver programar_tarea.bat), pero internamente
REM verifica si "manana" cae en dia 1 -- si no es el ultimo dia del mes, no hace nada.
REM Para generarlo en cualquier otro momento: Generar-Reporte-PUBLICACIONES.cmd

cd /d "%~dp0"

powershell -NoProfile -Command "if ((Get-Date).AddDays(1).Day -ne 1) { exit 1 }"
if %ERRORLEVEL% NEQ 0 (
    exit /b 0
)

set PYTHONIOENCODING=utf-8
echo ============================================== >> Automation\pub_sync.log
echo Corrida automatica (ultimo dia del mes): %date% %time% >> Automation\pub_sync.log

python -m pub_sync run >> Automation\pub_sync.log 2>&1

echo Fin de corrida: %date% %time% >> Automation\pub_sync.log
echo ============================================== >> Automation\pub_sync.log
