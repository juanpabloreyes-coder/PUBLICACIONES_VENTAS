@echo off
title Quitar RevitSyncLogger (PUBLICACIONES_VENTAS)

set "ADDIN_DIR=%AppData%\Autodesk\Revit\Addins\2025"

echo.
echo  Quitando RevitSyncLogger...
echo.

del /F /Q "%ADDIN_DIR%\RevitSyncLogger.dll" 2>nul
del /F /Q "%ADDIN_DIR%\RevitSyncLogger.addin" 2>nul
del /F /Q "%ADDIN_DIR%\synclogger-config.txt" 2>nul
del /F /Q "%ADDIN_DIR%\RevitSyncLogger.pdb" 2>nul

echo  Listo, RevitSyncLogger ya no se cargara la proxima vez que abras Revit.
echo.
pause
