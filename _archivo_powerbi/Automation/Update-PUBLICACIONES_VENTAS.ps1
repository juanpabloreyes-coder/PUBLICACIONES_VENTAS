param(
    [string]$Reason = "Revision de sincronizaciones Revit",
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

# ============================================================
# RUTAS
# ============================================================

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot

$PbipPath = Join-Path $RepositoryRoot "PUBLICACIONES_VENTAS.pbip"
$RevitSyncRoot = Join-Path $RepositoryRoot "RevitSyncLog"

$LocalStateRoot = Join-Path $env:LOCALAPPDATA "PUBLICACIONES_VENTAS"

if (-not (Test-Path -LiteralPath $LocalStateRoot)) {
    New-Item `
        -ItemType Directory `
        -Path $LocalStateRoot `
        -Force |
    Out-Null
}

$PendingPath = Join-Path $LocalStateRoot "update-pending.flag"
$StatePath = Join-Path $LocalStateRoot "sync-state.json"
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

    $line = "{0}  UPDATE  {1}" -f `
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
        $Message

    [System.IO.File]::AppendAllText(
        $LogPath,
        $line + [Environment]::NewLine,
        $Utf8NoBom
    )
}


# ============================================================
# NOTIFICACIONES DE WINDOWS
# ============================================================

function Show-Notification {

    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )

    if ($Silent) {
        return
    }

    try {

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $icon = [System.Windows.Forms.NotifyIcon]::new()

        $icon.Icon =
            switch ($Level) {

                "Warning" {
                    [System.Drawing.SystemIcons]::Warning
                }

                "Error" {
                    [System.Drawing.SystemIcons]::Error
                }

                default {
                    [System.Drawing.SystemIcons]::Information
                }
            }

        $icon.Visible = $true

        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message

        $icon.BalloonTipIcon =
            switch ($Level) {

                "Warning" {
                    [System.Windows.Forms.ToolTipIcon]::Warning
                }

                "Error" {
                    [System.Windows.Forms.ToolTipIcon]::Error
                }

                default {
                    [System.Windows.Forms.ToolTipIcon]::Info
                }
            }

        $icon.ShowBalloonTip(8000)

        Start-Sleep -Milliseconds 1200

        $icon.Dispose()
    }
    catch {

        Write-Log `
            "No se pudo mostrar notificacion: $($_.Exception.Message)"
    }
}


# ============================================================
# GUARDAR ESTADO DEL UPDATER
# ============================================================

function Save-UpdateState {

    param(
        [string]$Status,
        [string]$Reason,
        [int]$CsvCount,
        [int]$RowCount,
        [string]$LastCsv,
        [string]$LastCsvModified,
        [bool]$Pending
    )

    $state = [ordered]@{

        LastChecked =
            (Get-Date).ToString("o")

        Status =
            $Status

        Reason =
            $Reason

        CsvCount =
            $CsvCount

        RowCount =
            $RowCount

        LastCsv =
            $LastCsv

        LastCsvModified =
            $LastCsvModified

        Pending =
            $Pending
    }

    $json =
        $state |
        ConvertTo-Json -Depth 5

    [System.IO.File]::WriteAllText(
        $UpdateStatePath,
        $json,
        $Utf8NoBom
    )
}


# ============================================================
# DETECTAR SI PUBLICACIONES_VENTAS ESTA ABIERTO
# ============================================================

function Test-TargetPowerBiOpen {

    $escapedPbip =
        [regex]::Escape(
            $PbipPath
        )

    try {

        $processes =
            @(
                Get-CimInstance `
                    Win32_Process `
                    -Filter "Name='PBIDesktop.exe'" `
                    -ErrorAction Stop
            )

        foreach ($process in $processes) {

            if (
                $process.CommandLine -and
                $process.CommandLine -match $escapedPbip
            ) {

                return $true
            }
        }
    }
    catch {

        Write-Log `
            "No se pudo revisar CommandLine de Power BI: $($_.Exception.Message)"
    }

    $windows =
        @(
            Get-Process `
                PBIDesktop `
                -ErrorAction SilentlyContinue
        )

    foreach ($window in $windows) {

        if (
            $window.MainWindowTitle -match
            "(^|\s)PUBLICACIONES_VENTAS(\s|-|$)"
        ) {

            return $true
        }
    }

    return $false
}


# ============================================================
# OBTENER LOS CSV
# ============================================================

function Get-SyncCsvFiles {

    if (-not (Test-Path -LiteralPath $RevitSyncRoot)) {

        return @()
    }

    return @(
        Get-ChildItem `
            -LiteralPath $RevitSyncRoot `
            -Filter "*.csv" `
            -File `
            -Recurse `
            -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending
    )
}


# ============================================================
# VALIDAR CONTENIDO DE LOS CSV
# ============================================================

function Get-SyncRowCount {

    param(
        [array]$Files
    )

    $totalRows = 0

    foreach ($file in $Files) {

        try {

            $rows =
                @(
                    Import-Csv `
                        -LiteralPath $file.FullName `
                        -Encoding UTF8 `
                        -ErrorAction Stop
                )

            $totalRows +=
                $rows.Count
        }
        catch {

            Write-Log `
                "No se pudo leer CSV: $($file.FullName). $($_.Exception.Message)"
        }
    }

    return $totalRows
}


# ============================================================
# PROCESO PRINCIPAL
# ============================================================

try {

    Write-Log `
        "Inicio: $Reason"


    # --------------------------------------------------------
    # 1. VERIFICAR SI HAY ACTUALIZACION PENDIENTE
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $PendingPath)) {

        Write-Log `
            "No existe actualizacion pendiente."

        exit 0
    }


    # --------------------------------------------------------
    # 2. VALIDAR CSV
    # --------------------------------------------------------

    $csvFiles =
        Get-SyncCsvFiles

    $csvCount =
        $csvFiles.Count


    if ($csvCount -eq 0) {

        Save-UpdateState `
            -Status "Error" `
            -Reason $Reason `
            -CsvCount 0 `
            -RowCount 0 `
            -LastCsv "" `
            -LastCsvModified "" `
            -Pending $true

        Write-Log `
            "ERROR: update-pending.flag existe, pero no hay CSV."

        Show-Notification `
            -Title "PUBLICACIONES_VENTAS - ERROR" `
            -Message "Hay una actualizacion pendiente, pero RevitSyncLog no contiene archivos CSV." `
            -Level Error

        exit 1
    }


    # --------------------------------------------------------
    # 3. VALIDAR FILAS
    # --------------------------------------------------------

    $rowCount =
        Get-SyncRowCount `
            -Files $csvFiles

    $lastCsv =
        $csvFiles[0]

    $lastCsvName =
        $lastCsv.Name

    $lastCsvModified =
        $lastCsv.LastWriteTime.ToString(
            "dd/MM/yyyy HH:mm:ss"
        )


    # --------------------------------------------------------
    # 4. COMPROBAR POWER BI
    # --------------------------------------------------------

    $powerBiOpen =
        Test-TargetPowerBiOpen


    # ========================================================
    # POWER BI ESTA ABIERTO
    # ========================================================

    if ($powerBiOpen) {

        Save-UpdateState `
            -Status "Pendiente de refrescar Power BI" `
            -Reason $Reason `
            -CsvCount $csvCount `
            -RowCount $rowCount `
            -LastCsv $lastCsvName `
            -LastCsvModified $lastCsvModified `
            -Pending $true

        Write-Log `
            "Datos Revit validados: $csvCount CSV, $rowCount registros. PUBLICACIONES_VENTAS esta abierto y requiere Refresh."

        Show-Notification `
            -Title "PUBLICACIONES_VENTAS" `
            -Message "Nuevos datos Revit detectados. En Power BI Desktop pulsa Actualizar para incorporarlos." `
            -Level Warning

        exit 10
    }


    # ========================================================
    # POWER BI ESTA CERRADO
    # ========================================================

    Save-UpdateState `
        -Status "Datos listos para Power BI" `
        -Reason $Reason `
        -CsvCount $csvCount `
        -RowCount $rowCount `
        -LastCsv $lastCsvName `
        -LastCsvModified $lastCsvModified `
        -Pending $true

    Write-Log `
        "Datos Revit listos: $csvCount CSV, $rowCount registros. Power BI esta cerrado."

    Show-Notification `
        -Title "PUBLICACIONES_VENTAS" `
        -Message "Nuevos datos Revit disponibles. Abre Power BI Desktop y pulsa Actualizar." `
        -Level Info

    exit 0
}
catch {

    $message =
        $_.Exception.Message

    Write-Log `
        "ERROR: $message"

    Save-UpdateState `
        -Status "Error" `
        -Reason $Reason `
        -CsvCount 0 `
        -RowCount 0 `
        -LastCsv "" `
        -LastCsvModified "" `
        -Pending $true

    Show-Notification `
        -Title "Error PUBLICACIONES_VENTAS" `
        -Message $message `
        -Level Error

    exit 1
}