@echo off
REM Registra la tarea programada de Windows "PubSync_VENTAS_Mensual":
REM   - corre todos los dias a las 23:59;
REM   - si la PC estaba apagada a esa hora, corre en cuanto se enciende (StartWhenAvailable);
REM   - run_pipeline.bat solo genera el reporte si hay un mes pendiente.
REM Se corre UNA SOLA VEZ (volver a correrlo actualiza la tarea).

set CARPETA=%~dp0
set TAREA=PubSync_VENTAS_Mensual

schtasks /create /tn "%TAREA%" /tr "\"%CARPETA%run_pipeline.bat\"" /sc DAILY /st 23:59 /f
if %ERRORLEVEL% NEQ 0 goto error

powershell -NoProfile -Command "$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 3); Set-ScheduledTask -TaskName '%TAREA%' -Settings $s | Out-Null"
if %ERRORLEVEL% NEQ 0 goto error

echo.
echo Tarea "%TAREA%" creada correctamente.
echo Corre todos los dias a las 23:59; si la PC estaba apagada, corre al encenderla.
echo Solo genera el reporte de publicaciones cuando hay un mes pendiente
echo ^(el ultimo dia del mes, o el primer dia en que la PC este encendida despues^).
echo Puedes verla en el Programador de tareas de Windows ^(busca "Task Scheduler"^).
echo.
pause
exit /b 0

:error
echo.
echo Hubo un error creando la tarea. Copia el mensaje de arriba y lo revisamos juntos.
echo.
pause
exit /b 1
