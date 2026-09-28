# RevitSyncLogger — compilación e instalación

Add-in de Revit para **PUBLICACIONES_VENTAS**. Registra, después de cada
`Synchronize with Central` exitoso en un modelo Cloud Worksharing, una fila en
un CSV compartido (`RevitSyncLog/`) con el modelo, el proyecto real (resuelto
igual que en PLANOS_VENTAS/revit_addin_sync/SheetSync.cs — desplegable de
confirmación una sola vez por modelo, nunca texto libre), usuario, equipo,
fecha/hora y estado.

## Compilar (una vez, en una máquina con Visual Studio o .NET SDK 8 y Revit
instalado)

```powershell
cd "revit_addin_sync"
dotnet build -c Release
```

Verifica primero que `RevitSyncLogger.csproj` apunte a tu instalación local de
Revit (`RevitAPI.dll` / `RevitAPIUI.dll`).

## Empacar el instalador

**IMPORTANTE — el mismo gotcha que en SheetSync:** `Instalador\instalar.bat`
copia el `.dll` que está **dentro de la propia carpeta `Instalador`**, no el
que acaba de compilar `dotnet build`. Después de cada recompilación:

```powershell
copy /Y "bin\Release\net8.0-windows\RevitSyncLogger.dll" "Instalador\RevitSyncLogger.dll"
```

y sube ese archivo (junto con el resto del repo) a ACC antes de pedirle a
alguien que corra `instalar.bat`, o van a seguir instalando una versión
vieja sin darse cuenta.

## Instalar en cada equipo (sin tocar código)

Ver `Instalador\LEEME.txt`. En resumen: copiar la carpeta `Instalador` y
correr `instalar.bat` — detecta sola la carpeta `PUBLICACIONES_VENTAS` en el
Desktop Connector de esa persona y configura `synclogger-config.txt`.

## Migración desde el piloto anterior

El add-in original (`PUBLICACIONES_VENTAS.RevitSyncLogger`, instalado suelto
fuera de cualquier repo, solo en la máquina de Juan Pablo) debe desinstalarse
con su propio manifest antes de instalar esta versión, para no tener dos
`.addin` apuntando al mismo `AddInId` a la vez:

```powershell
Remove-Item "$env:AppData\Autodesk\Revit\Addins\2025\PUBLICACIONES_VENTAS.RevitSyncLogger.addin" -Force
```

(El `.dll` viejo, en `Documents\Codex\...`, puede quedarse ahí sin problema —
ya no se carga sin su `.addin`.)
