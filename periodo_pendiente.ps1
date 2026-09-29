# Devuelve el mes (AAAA-MM) cuyo reporte mensual esta pendiente, o nada si ya se genero.
#   - El ultimo dia del mes, el mes pendiente es el actual.
#   - Cualquier otro dia, es el mes anterior: si la PC estuvo apagada el ultimo dia,
#     el reporte de ese mes se genera en cuanto vuelva a correr la tarea.
# El ultimo mes generado se guarda en el archivo -Marcador (lo escribe run_pipeline.bat).
param([string]$Marcador)

$hoy = Get-Date

if ($hoy.AddDays(1).Day -eq 1) {
    $objetivo = $hoy.ToString('yyyy-MM')
}
else {
    $objetivo = $hoy.AddMonths(-1).ToString('yyyy-MM')
}

$ultimo = ''
if (Test-Path -LiteralPath $Marcador) {
    $ultimo = ([string](Get-Content -LiteralPath $Marcador -Raw)).Trim()
}

if ([string]::CompareOrdinal($ultimo, $objetivo) -ge 0) {
    exit 0
}

Write-Output $objetivo
