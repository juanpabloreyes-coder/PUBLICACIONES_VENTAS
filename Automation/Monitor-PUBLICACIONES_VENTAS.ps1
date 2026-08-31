$ErrorActionPreference = "Continue"

# ============================================================
# RUTAS
# ============================================================

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot

$RevitSyncRoot = Join-Path $RepositoryRoot "RevitSyncLog"

# ============================================================
# ESTADO OPERATIVO LOCAL
# No se sincroniza con Autodesk Desktop Connector
# ============================================================

$LocalStateRoot = Join-Path $env:LOCALAPPDATA "PUBLICACIONES_VENTAS"

if (-not (Test-Path -LiteralPath $LocalStateRoot)) {
    New-Item -ItemType Directory -Path $LocalStateRoot -Force | Out-Null
}

$SignalPath = Join-Path $LocalStateRoot "sync-change.signal"
$PidPath = Join-Path $LocalStateRoot "monitor.pid"
$LogPath = Join-Path $LocalStateRoot "automation.log"
$StatePath = Join-Path $LocalStateRoot "sync-state.json"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ============================================================
# LOG
# ============================================================

function Write-MonitorLog {
    param([string]$Message)

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
        }
    }

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

    Save-State `
        -Status "Cambio detectado" `
        -Reason $Reason `
        -CsvCount $csvCount `
        -Signature $signature

    Write-MonitorLog `
        "Cambio detectado: $csvCount archivos CSV."

    Show-MonitorNotification `
        -Title "PUBLICACIONES_VENTAS" `
        -Message "Se detectaron nuevos datos de sincronizacion Revit."
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

    Invoke-SyncCheck `
        -Reason "Inicio del monitor"

    if (-not (Test-Path -LiteralPath $RevitSyncRoot)) {

        New-Item `
            -ItemType Directory `
            -Path $RevitSyncRoot `
            -Force |
        Out-Null
    }

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

    $nextHourlyCheck =
        (Get-Date).AddHours(1)

    $lastSignature =
        Get-SyncSignature

    $nextSafetyScan =
        (Get-Date).AddSeconds(15)

    Write-MonitorLog `
        "Vigilando RevitSyncLog."

    while ($true) {

        # ====================================================
        # EVENTO DE FILESYSTEMWATCHER
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

                Invoke-SyncCheck `
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

                Invoke-SyncCheck `
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

            Invoke-SyncCheck `
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

        $mutex.ReleaseMutex()

        $mutex.Dispose()
    }
}