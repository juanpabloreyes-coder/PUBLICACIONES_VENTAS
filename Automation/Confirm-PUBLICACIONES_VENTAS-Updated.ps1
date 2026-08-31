$ErrorActionPreference = "Stop"

# ============================================================
# RUTAS
# ============================================================

$LocalStateRoot = Join-Path $env:LOCALAPPDATA "PUBLICACIONES_VENTAS"

$PendingPath = Join-Path $LocalStateRoot "update-pending.flag"
$UpdateStatePath = Join-Path $LocalStateRoot "update-state.json"
$LogPath = Join-Path $LocalStateRoot "automation.log"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)


# ============================================================
# LOG
# ============================================================

function Write-Log {

    param(
        [string]$Message
    )

    $line = "{0}  CONFIRM  {1}" -f `
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
        $Message

    [System.IO.File]::AppendAllText(
        $LogPath,
        $line + [Environment]::NewLine,
        $Utf8NoBom
    )
}


# ============================================================
# NOTIFICACION
# ============================================================

function Show-Notification {

    param(
        [string]$Title,
        [string]$Message
    )

    try {

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $icon = [System.Windows.Forms.NotifyIcon]::new()

        $icon.Icon =
            [System.Drawing.SystemIcons]::Information

        $icon.Visible = $true

        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message
        $icon.BalloonTipIcon =
            [System.Windows.Forms.ToolTipIcon]::Info

        $icon.ShowBalloonTip(8000)

        Start-Sleep -Milliseconds 1200

        $icon.Dispose()
    }
    catch {
    }
}


# ============================================================
# PROCESO
# ============================================================

try {

    if (-not (Test-Path -LiteralPath $LocalStateRoot)) {

        Write-Host "No existe estado local de PUBLICACIONES_VENTAS."
        exit 1
    }


    if (-not (Test-Path -LiteralPath $PendingPath)) {

        Write-Host ""
        Write-Host "No hay ninguna actualizacion pendiente."
        Write-Host ""

        Write-Log `
            "Confirmacion solicitada, pero no habia actualizacion pendiente."

        exit 0
    }


    # --------------------------------------------------------
    # LEER ESTADO ACTUAL
    # --------------------------------------------------------

    $currentState = $null

    if (Test-Path -LiteralPath $UpdateStatePath) {

        try {

            $currentState =
                Get-Content `
                    -LiteralPath $UpdateStatePath `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json
        }
        catch {
        }
    }


    # --------------------------------------------------------
    # ELIMINAR BANDERA PENDIENTE
    # --------------------------------------------------------

    Remove-Item `
        -LiteralPath $PendingPath `
        -Force


    # --------------------------------------------------------
    # CREAR ESTADO CONFIRMADO
    # --------------------------------------------------------

    $state = [ordered]@{

        LastChecked =
            (Get-Date).ToString("o")

        Status =
            "Actualizado en Power BI"

        Reason =
            "Confirmacion manual despues de Refresh"

        CsvCount =
            if ($currentState) {
                $currentState.CsvCount
            }
            else {
                0
            }

        RowCount =
            if ($currentState) {
                $currentState.RowCount
            }
            else {
                0
            }

        LastCsv =
            if ($currentState) {
                $currentState.LastCsv
            }
            else {
                ""
            }

        LastCsvModified =
            if ($currentState) {
                $currentState.LastCsvModified
            }
            else {
                ""
            }

        Pending =
            $false

        ConfirmedAt =
            (Get-Date).ToString("o")
    }


    $json =
        $state |
        ConvertTo-Json -Depth 5


    [System.IO.File]::WriteAllText(
        $UpdateStatePath,
        $json,
        $Utf8NoBom
    )


    Write-Log `
        "Actualizacion confirmada en Power BI. Pending=false."


    Show-Notification `
        -Title "PUBLICACIONES_VENTAS" `
        -Message "Actualizacion confirmada. No quedan datos Revit pendientes."


    Write-Host ""
    Write-Host "Actualizacion confirmada correctamente."
    Write-Host "Pending = false"
    Write-Host ""

    exit 0
}
catch {

    Write-Host ""
    Write-Host "ERROR:"
    Write-Host $_.Exception.Message
    Write-Host ""

    Write-Log `
        "ERROR al confirmar actualizacion: $($_.Exception.Message)"

    exit 1
}