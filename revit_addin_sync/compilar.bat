@echo off
REM Compila RevitSyncLogger.dll (Release) y la copia a la carpeta Instalador.
cd /d "%~dp0"
dotnet build RevitSyncLogger.csproj -c Release
if errorlevel 1 (
  echo.
  echo ERROR: no compilo. No se copio nada.
  pause
  exit /b 1
)
copy /Y "bin\Release\net8.0-windows\RevitSyncLogger.dll" "Instalador\RevitSyncLogger.dll"
echo.
echo Listo: Instalador\RevitSyncLogger.dll actualizado.
pause
