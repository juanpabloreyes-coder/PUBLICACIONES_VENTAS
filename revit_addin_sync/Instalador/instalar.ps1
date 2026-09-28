$ErrorActionPreference = 'Stop'
$addinDir = Join-Path $env:AppData 'Autodesk\Revit\Addins\2025'
$nombreCarpeta = '03372_PUBLICACIONES_VENTAS'

Write-Host ""
Write-Host " Buscando la carpeta de registro ($nombreCarpeta)..."
Write-Host " Esto puede tardar unos segundos, espera por favor."
Write-Host ""

function Buscar-Carpeta($nombre) {
    $dcRoot = Join-Path $env:USERPROFILE 'DC'
    if (Test-Path $dcRoot) {
        $found = Get-ChildItem -Path $dcRoot -Recurse -Directory -Filter $nombre -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    foreach ($drive in @('C', 'D', 'E', 'F')) {
        $root = "$drive`:\"
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Recurse -Directory -Filter $nombre -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

$logDir = Buscar-Carpeta $nombreCarpeta

if (-not $logDir) {
    Write-Host " No se encontro la carpeta `"$nombreCarpeta`" en este equipo."
    Write-Host ""
    Write-Host " Es posible que el proyecto TEMPORAL_GCP_BIM aun no este disponible"
    Write-Host " en tu Desktop Connector, o que no tengas acceso a el todavia."
    Write-Host ""
    Write-Host " Avisale a Juan Pablo con este mensaje para revisarlo juntos."
    Write-Host ""
    Read-Host " Presiona Enter para salir"
    exit 1
}

# La carpeta compartida con SheetSync (PLANOS_VENTAS) es la carpeta padre -- 03371_PLANOS_VENTAS
# y 03372_PUBLICACIONES_VENTAS viven juntas dentro de 0337_SQDCM.
$carpetaCompartida = Split-Path $logDir -Parent

New-Item -ItemType Directory -Force -Path $addinDir | Out-Null

Copy-Item (Join-Path $PSScriptRoot 'RevitSyncLogger.dll') (Join-Path $addinDir 'RevitSyncLogger.dll') -Force
Copy-Item (Join-Path $PSScriptRoot 'RevitSyncLogger.addin') (Join-Path $addinDir 'RevitSyncLogger.addin') -Force
Set-Content -Path (Join-Path $addinDir 'synclogger-config.txt') -Value $logDir -NoNewline -Encoding UTF8
Set-Content -Path (Join-Path $addinDir 'carpeta-compartida-config.txt') -Value $carpetaCompartida -NoNewline -Encoding UTF8

if (Test-Path (Join-Path $addinDir 'RevitSyncLogger.dll')) {
    Write-Host " Listo. RevitSyncLogger quedo instalado."
    Write-Host " Carpeta de registro detectada: $logDir"
    Write-Host " Carpeta compartida de confirmaciones: $carpetaCompartida"
    Write-Host ""
    Write-Host " Siguiente paso: abre Revit normalmente."
    Write-Host " Si aparece un aviso de seguridad `"Unsigned Add-In`", elige `"Always Load`"."
    Write-Host " No hay que hacer nada mas - se activa solo cada vez que sincronizas."
}
else {
    Write-Host " Algo no se copio bien. Avisale a Juan Pablo con una captura de esta ventana."
}

Write-Host ""
Read-Host " Presiona Enter para cerrar"
