$ErrorActionPreference = "Continue"

# ============================================================
# RUTAS
# ============================================================

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot

# Generador sin Power BI: python -m pub_sync run (Forma + RevitSyncLog + Excel)
# El updater anterior (Update-PUBLICACIONES_VENTAS.ps1, requiere Power BI) ya no se usa.
$PubSyncPackage = Join-Path $RepositoryRoot "pub_sync"
$PythonExe = "python"

# Carpeta donde escriben los add-ins: la misma que lee pub_sync ("revit_sync_log" en config.json).
$RevitSyncRoot = Join-Path $RepositoryRoot "RevitSyncLog"

try {

    $cfg =
        Get-Content `
            -LiteralPath (Join-Path $RepositoryRoot "config.json") `
            -Raw `
            -Encoding UTF8 |
        ConvertFrom-Json

    if ($cfg.revit_sync_log) {

        $RevitSyncRoot =
            if ([System.IO.Path]::IsPathRooted($cfg.revit_sync_log)) {
                $cfg.revit_sync_log
            }
            else {
                Join-Path $RepositoryRoot $cfg.revit_sync_log
            }
    }
}
catch {
}


# ============================================================
# ESTADO OPERATIVO LOCAL
# No se sincroniza con Autodesk Desktop Connector
# ============================================================

$LocalStateRoot = Join-Path $env:LOCALAPPDATA "PUBLICACIONES_VENTAS"

if (-not (Test-Path -LiteralPath $LocalStateRoot)) {

    New-Item `
        -ItemType Directory `
        -Path $LocalStateRoot `
        -Force |
    Out-Null
}

$SignalPath = Join-Path $LocalStateRoot "sync-change.signal"
$PendingPath = Join-Path $LocalStateRoot "update-pending.flag"
$PidPath = Join-Path $LocalStateRoot "monitor.pid"
$LogPath = Join-Path $LocalStateRoot "automation.log"
$StatePath = Join-Path $LocalStateRoot "sync-state.json"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)


# ============================================================
# LOG
# ============================================================

function Write-MonitorLog {

    param(
        [string]$Message
    )

    $line = "{0}  MONITOR  {1}" -f `
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

function Show-MonitorNotification {

    param(
        [string]$Title,
        [string]$Message,
        [string]$Level = "Info"
    )

    try {

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        $icon = [System.Windows.Forms.NotifyIcon]::new()

        $icon.Icon =
            if ($Level -eq "Warning") {
                [System.Drawing.SystemIcons]::Warning
            }
            else {
                [System.Drawing.SystemIcons]::Information
            }

        $icon.Visible = $true
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Message

        $icon.BalloonTipIcon =
            if ($Level -eq "Warning") {
                [System.Windows.Forms.ToolTipIcon]::Warning
            }
            else {
                [System.Windows.Forms.ToolTipIcon]::Info
            }

        $icon.ShowBalloonTip(8000)

        Start-Sleep -Milliseconds 1200

        $icon.Dispose()
    }
    catch {

        Write-MonitorLog `
            "No se pudo mostrar notificacion: $($_.Exception.Message)"
    }
}


# ============================================================
# ESTADO
# ============================================================

function Save-State {

    param(
        [string]$Status,
        [string]$Reason,
        [int]$CsvCount,
        [string]$Signature
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

        Signature =
            $Signature
    }

    $json =
        $state |
        ConvertTo-Json -Depth 5

    [System.IO.File]::WriteAllText(
        $StatePath,
        $json,
        $Utf8NoBom
    )
}


# ============================================================
# FIRMA DEL CONTENIDO
# ============================================================

function Get-SyncSignature {

    if (-not (Test-Path -LiteralPath $RevitSyncRoot)) {

        return $null
    }

    try {

        $files =
            Get-ChildItem `
                -LiteralPath $RevitSyncRoot `
                -Filter "*.csv" `
                -File `
                -Recurse `
                -ErrorAction Stop |
            Sort-Object FullName

        $rows = @()

        foreach ($file in $files) {

            $relative =
                $file.FullName.Substring(
                    $RevitSyncRoot.Length
                ).TrimStart("\")

            $rows +=
                "{0}|{1}|{2}" -f `
                    $relative,
                    $file.Length,
                    $file.LastWriteTimeUtc.Ticks
        }

        $canonical =
            $rows -join "`n"

        $sha =
            [System.Security.Cryptography.SHA256]::Create()

        try {

            $bytes =
                $Utf8NoBom.GetBytes(
                    $canonical
                )

            return (
                [BitConverter]::ToString(
                    $sha.ComputeHash($bytes)
                )
            ).Replace("-", "").ToLowerInvariant()
        }
        finally {

            $sha.Dispose()
        }
    }
    catch {

        Write-MonitorLog `
            "No se pudo calcular la firma: $($_.Exception.Message)"

        return $null
    }
}


# ============================================================
# CONTAR CSV
# ============================================================

function Get-CsvCount {

    if (-not (Test-Path -LiteralPath $RevitSyncRoot)) {

        return 0
    }

    try {

        return @(
            Get-ChildItem `
                -LiteralPath $RevitSyncRoot `
                -Filter "*.csv" `
                -File `
                -Recurse `
                -ErrorAction Stop
        ).Count
    }
    catch {

        return 0
    }
}


# ============================================================
# EJECUTAR UPDATER
# ============================================================

function Invoke-Updater {

    param(
        [string]$Reason
    )

    if (-not (Test-Path -LiteralPath $PubSyncPackage)) {

        Write-MonitorLog `
            "ERROR: No se encontro la carpeta pub_sync en $RepositoryRoot."

        return
    }

    try {

        Write-MonitorLog `
            "Ejecutando pub_sync ($Reason)."

        Push-Location -LiteralPath $RepositoryRoot

        try {

            $env:PYTHONIOENCODING = "utf-8"

            $output =
                & $PythonExe -m pub_sync run 2>&1 |
                ForEach-Object { [string]$_ }

            $UpdaterExitCode =
                $LASTEXITCODE
        }
        finally {

            Pop-Location
        }

        $status =
            @($output |
              Where-Object {
                  $_ -match '^(EXPORTACION|SIN CAMBIOS|SIN ACTUALIZACION|ERROR)'
              }) |
            Select-Object -Last 1

        Write-MonitorLog `
            "pub_sync finalizo con codigo $UpdaterExitCode. $status"

        if ($UpdaterExitCode -ne 0) {

            Show-MonitorNotification `
                -Title "PUBLICACIONES_VENTAS" `
                -Message "No se pudo actualizar el reporte. Se conserva el anterior. Revisa automation.log." `
                -Level Warning
        }
        elseif ($status -match '^EXPORTACION') {

            Show-MonitorNotification `
                -Title "PUBLICACIONES_VENTAS" `
                -Message "Reporte de publicaciones actualizado."
        }
    }
    catch {

        Write-MonitorLog `
            "ERROR al ejecutar pub_sync: $($_.Exception.Message)"
    }
}


# ============================================================
# PROCESAR CAMBIO
# ============================================================

function Invoke-SyncCheck {

    param(
        [string]$Reason
    )

    $signature =
        Get-SyncSignature

    $csvCount =
        Get-CsvCount


    # --------------------------------------------------------
    # NO HAY DATOS
    # --------------------------------------------------------

    if (-not $signature) {

        Save-State `
            -Status "Sin datos" `
            -Reason $Reason `
            -CsvCount $csvCount `
            -Signature ""

        Write-MonitorLog `
            "Sin datos disponibles. CSV: $csvCount"

        return
    }


    # --------------------------------------------------------
    # LEER ESTADO ANTERIOR
    # --------------------------------------------------------

    $previous = $null

    if (Test-Path -LiteralPath $StatePath) {

        try {

            $previous =
                Get-Content `
                    -LiteralPath $StatePath `
                    -Raw |
                ConvertFrom-Json
        }
        catch {

            Write-MonitorLog `
                "No se pudo leer sync-state.json: $($_.Exception.Message)"
        }
    }


    # --------------------------------------------------------
    # FIRMA IGUAL = NO HAY CAMBIOS
    # --------------------------------------------------------

    if (
        $previous -and
        $previous.Signature -eq $signature
    ) {

        Save-State `
            -Status "Sin cambios" `
            -Reason $Reason `
            -CsvCount $csvCount `
            -Signature $signature

        Write-MonitorLog `
            "Sin cambios: $csvCount archivos CSV."

        return
    }


    # --------------------------------------------------------
    # FIRMA DIFERENTE = ACTUALIZACION PENDIENTE
    # --------------------------------------------------------

    Save-State `
        -Status "Actualizacion pendiente" `
        -Reason $Reason `
        -CsvCount $csvCount `
        -Signature $signature

    [System.IO.File]::WriteAllText(
        $PendingPath,
        (Get-Date).ToString("o"),
        $Utf8NoBom
    )

    Write-MonitorLog `
        "Actualizacion pendiente: $csvCount archivos CSV."


    # --------------------------------------------------------
    # NOTIFICAR
    # --------------------------------------------------------

    Show-MonitorNotification `
        -Title "PUBLICACIONES_VENTAS" `
        -Message "Se detectaron nuevos datos de sincronizacion Revit."


    # --------------------------------------------------------
    # EJECUTAR UPDATER AUTOMATICAMENTE
    # --------------------------------------------------------

    Invoke-Updater `
        -Reason $Reason

    return $true
}


# ============================================================
# REVISION PERIODICA DE FORMA
#
# Una publicacion en Forma no siempre coincide con un cambio en
# RevitSyncLog. Por eso, al iniciar y cada hora, se corre pub_sync
# aunque los CSV no hayan cambiado (usa cache: solo descarga las
# versiones de los modelos que tengan una version nueva).
# ============================================================

function Invoke-PeriodicCheck {

    param(
        [string]$Reason
    )

    $ran =
        Invoke-SyncCheck `
            -Reason $Reason

    if (-not $ran) {

        Invoke-Updater `
            -Reason "$Reason (publicaciones en Forma)"
    }
}


# ============================================================
# EVITAR DOS MONITORES A LA VEZ
# ============================================================

$createdNew = $false

$mutex =
    [System.Threading.Mutex]::new(
        $true,
        "Local\PUBLICACIONES_VENTAS_RevitSync_Monitor",
        [ref]$createdNew
    )

if (-not $createdNew) {

    exit 0
}

[System.IO.File]::WriteAllText(
    $PidPath,
    [string]$PID,
    $Utf8NoBom
)


# ============================================================
# MONITOR
# ============================================================

$watcher = $null

try {

    Write-MonitorLog `
        "Monitor iniciado."


    # --------------------------------------------------------
    # COMPROBACION INICIAL
    # --------------------------------------------------------

    Invoke-PeriodicCheck `
        -Reason "Inicio del monitor"


    # --------------------------------------------------------
    # ASEGURAR QUE EXISTA RevitSyncLog
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $RevitSyncRoot)) {

        New-Item `
            -ItemType Directory `
            -Path $RevitSyncRoot `
            -Force |
        Out-Null
    }


    # --------------------------------------------------------
    # FILESYSTEMWATCHER
    # --------------------------------------------------------

    $watcher =
        [System.IO.FileSystemWatcher]::new(
            $RevitSyncRoot
        )

    $watcher.IncludeSubdirectories = $true

    $watcher.Filter = "*.csv"

    $watcher.NotifyFilter =
        [System.IO.NotifyFilters]::FileName `
        -bor `
        [System.IO.NotifyFilters]::LastWrite `
        -bor `
        [System.IO.NotifyFilters]::Size

    $watcher.EnableRaisingEvents = $true


    # --------------------------------------------------------
    # EVENTO
    # --------------------------------------------------------

    $action = {

        try {

            [System.IO.File]::WriteAllText(
                $using:SignalPath,
                (Get-Date).ToString("o"),
                [System.Text.UTF8Encoding]::new($false)
            )
        }
        catch {
        }
    }


    Register-ObjectEvent `
        -InputObject $watcher `
        -EventName Created `
        -Action $action |
    Out-Null


    Register-ObjectEvent `
        -InputObject $watcher `
        -EventName Changed `
        -Action $action |
    Out-Null


    Register-ObjectEvent `
        -InputObject $watcher `
        -EventName Deleted `
        -Action $action |
    Out-Null


    Register-ObjectEvent `
        -InputObject $watcher `
        -EventName Renamed `
        -Action $action |
    Out-Null


    # --------------------------------------------------------
    # ESTADOS DE CONTROL
    # --------------------------------------------------------

    $nextHourlyCheck =
        (Get-Date).AddHours(1)

    $lastSignature =
        Get-SyncSignature

    $nextSafetyScan =
        (Get-Date).AddSeconds(15)


    Write-MonitorLog `
        "Vigilando $RevitSyncRoot"


    # ========================================================
    # BUCLE PRINCIPAL
    # ========================================================

    while ($true) {


        # ====================================================
        # EVENTO DE FILESYSTEMWATCHER
        #
        # Esperamos 5 segundos para evitar leer mientras
        # el add-in sigue escribiendo el CSV.
        # ====================================================

        if (Test-Path -LiteralPath $SignalPath) {

            $signalAge =
                (Get-Date) -
                (Get-Item -LiteralPath $SignalPath).LastWriteTime

            if ($signalAge.TotalSeconds -ge 5) {

                Remove-Item `
                    -LiteralPath $SignalPath `
                    -Force `
                    -ErrorAction SilentlyContinue

                $null = Invoke-SyncCheck `
                    -Reason "Cambio detectado en RevitSyncLog"

                $lastSignature =
                    Get-SyncSignature
            }
        }


        # ====================================================
        # ESCANEO DE SEGURIDAD
        # ====================================================

        if ((Get-Date) -ge $nextSafetyScan) {

            $currentSignature =
                Get-SyncSignature

            if (
                $currentSignature -and
                $lastSignature -and
                $currentSignature -ne $lastSignature
            ) {

                $null = Invoke-SyncCheck `
                    -Reason "Cambio detectado por revision de seguridad"

                $lastSignature =
                    $currentSignature
            }


            if (
                $currentSignature -and
                -not $lastSignature
            ) {

                $lastSignature =
                    $currentSignature
            }


            $nextSafetyScan =
                (Get-Date).AddSeconds(15)
        }


        # ====================================================
        # REVISION HORARIA
        # ====================================================

        if ((Get-Date) -ge $nextHourlyCheck) {

            Invoke-PeriodicCheck `
                -Reason "Revision horaria"

            $lastSignature =
                Get-SyncSignature

            $nextHourlyCheck =
                (Get-Date).AddHours(1)
        }


        Start-Sleep -Seconds 5
    }
}
catch {

    Write-MonitorLog `
        "Monitor detenido por error: $($_.Exception.Message)"

    Show-MonitorNotification `
        -Title "Monitor PUBLICACIONES_VENTAS" `
        -Message "El monitor se detuvo: $($_.Exception.Message)" `
        -Level Warning
}
finally {

    Get-EventSubscriber |
        Where-Object {
            $_.SourceObject -eq $watcher
        } |
        Unregister-Event `
            -Force `
            -ErrorAction SilentlyContinue


    if ($watcher) {

        $watcher.Dispose()
    }


    Remove-Item `
        -LiteralPath $PidPath `
        -Force `
        -ErrorAction SilentlyContinue


    if ($mutex) {

        try {

            $mutex.ReleaseMutex()
        }
        catch {
        }

        $mutex.Dispose()
    }
}