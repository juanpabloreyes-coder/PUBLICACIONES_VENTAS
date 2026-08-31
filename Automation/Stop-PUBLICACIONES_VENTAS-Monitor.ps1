$ErrorActionPreference = "Stop"

# ============================================================
# ESTADO OPERATIVO LOCAL
# ============================================================

$LocalStateRoot = Join-Path $env:LOCALAPPDATA "PUBLICACIONES_VENTAS"
$PidPath = Join-Path $LocalStateRoot "monitor.pid"

if (-not (Test-Path -LiteralPath $PidPath)) {
    Write-Host "No hay monitor activo registrado."
    exit 0
}

try {

    $MonitorPid = [int](
        Get-Content -LiteralPath $PidPath -Raw
    )

    $Process = Get-Process `
        -Id $MonitorPid `
        -ErrorAction SilentlyContinue

    if ($Process) {

        Stop-Process `
            -Id $MonitorPid `
            -Force

        Write-Host "Monitor detenido. PID: $MonitorPid"
    }
    else {

        Write-Host "El proceso ya no estaba activo."
    }

    Remove-Item `
        -LiteralPath $PidPath `
        -Force `
        -ErrorAction SilentlyContinue
}
catch {

    Write-Host "No se pudo detener el monitor:"
    Write-Host $_.Exception.Message

    exit 1
}