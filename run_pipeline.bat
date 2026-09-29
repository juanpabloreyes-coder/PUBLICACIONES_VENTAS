@echo off
setlocal
REM Genera el reporte mensual de PUBLICACIONES_VENTAS (mismo esquema que PLANOS_VENTAS).
REM La tarea corre todos los dias a las 23:59 y, si la PC estaba apagada, en cuanto se enciende.
REM periodo_pendiente.ps1 decide si hay un mes sin generar:
REM   - el ultimo dia del mes genera el mes actual;
REM   - si ese dia no corrio, lo genera el siguiente dia que corra la tarea.
REM Para generarlo en cualquier otro momento: Generar-Reporte-PUBLICACIONES.cmd

cd /d "%~dp0"
set "MARCADOR=%~dp0cache\ultima_corrida_mensual.txt"
set "OBJETIVO="

for /f "usebackq delims=" %%T in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0periodo_pendiente.ps1" -Marcador "%MARCADOR%"`) do set "OBJETIVO=%%T"

if not defined OBJETIVO exit /b 0

if not exist cache mkdir cache
set PYTHONIOENCODING=utf-8
echo ============================================== >> Automation\pub_sync.log
echo Corrida mensual %OBJETIVO%: %date% %time% >> Automation\pub_sync.log

python -m pub_sync run >> Automation\pub_sync.log 2>&1

if %ERRORLEVEL% EQU 0 (
    > "%MARCADOR%" echo %OBJETIVO%
    echo Reporte mensual %OBJETIVO% generado. >> Automation\pub_sync.log
) else (
    echo ERROR: no se genero el reporte %OBJETIVO%. Se reintentara en la siguiente corrida. >> Automation\pub_sync.log
)

echo Fin de corrida: %date% %time% >> Automation\pub_sync.log
echo ============================================== >> Automation\pub_sync.log
