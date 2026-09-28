param(
    [int]$Port = 0,
    [switch]$Diagnostic,
    [switch]$Silent
)

$ErrorActionPreference = "Stop"

# ============================================================
# 1. RUTAS
# ============================================================

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = Split-Path -Parent $AutomationRoot

$LogPath = Join-Path $AutomationRoot "automation.log"

$DataDir = Join-Path $RepositoryRoot "Data"
$DashboardDir = Join-Path $RepositoryRoot "Dashboard"

$JsonPath = Join-Path $DataDir "PUBLICACIONES_VENTAS.json"

$TemplatePath = Join-Path $DashboardDir "Publicaciones-Modelos-Report.template.html"
$HtmlPath = Join-Path $DashboardDir "Publicaciones-Modelos-Report.html"

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# Reutilizamos las dependencias que ya funcionan en ISSUES_VENTAS
$DepsRoot = Join-Path $env:LOCALAPPDATA "ISSUES_VENTAS\deps"

# ============================================================
# 2. LOG
# ============================================================

function Write-Log {

    param(
        [string]$Message
    )

    $line = "{0}  EXPORT  {1}" -f `
        (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"),
        $Message

    try {
        [System.IO.File]::AppendAllText(
            $LogPath,
            $line + [Environment]::NewLine,
            $Utf8NoBom
        )
    }
    catch {
    }

    if ($Diagnostic) {
        Write-Host $Message
    }
}

function Fail {

    param(
        [string]$Message,
        [int]$Code = 2
    )

    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    Write-Host "EXPORTACION FALLIDA" -ForegroundColor Red
    Write-Host "Log: $LogPath"
    Write-Host ""

    Write-Log "ERROR: $Message"

    exit $Code
}

function Ensure-Directory {

    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [void][System.IO.Directory]::CreateDirectory($Path)
    }
}

# ============================================================
# 3. CARGAR ADOMD
# ============================================================

function Load-Adomd {

    $dll = Get-ChildItem `
        -LiteralPath $DepsRoot `
        -Recurse `
        -Filter "Microsoft.AnalysisServices.AdomdClient.dll" `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '\\net472\\'
        } |
        Select-Object -First 1

    if (-not $dll) {
        throw "No se encontro Microsoft.AnalysisServices.AdomdClient.dll dentro de $DepsRoot"
    }

    $dir = Split-Path -Parent $dll.FullName

    Get-ChildItem `
        -LiteralPath $dir `
        -Filter "*.dll" `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne "Microsoft.AnalysisServices.AdomdClient.dll"
        } |
        ForEach-Object {
            try {
                [void][System.Reflection.Assembly]::LoadFrom($_.FullName)
            }
            catch {
            }
        }

    try {
        [void][System.Reflection.Assembly]::LoadFrom($dll.FullName)
    }
    catch {
    }

    if ($Diagnostic) {
        Write-Host "ADOMD:"
        Write-Host $dll.FullName
    }
}

# ============================================================
# 4. DETECTAR PUERTOS POWER BI
# ============================================================

function Get-PowerBiPorts {

    param(
        [int]$ManualPort
    )

    if ($ManualPort -gt 0) {
        return @($ManualPort)
    }

    $workspaceRoot = Join-Path `
        $env:LOCALAPPDATA `
        "Microsoft\Power BI Desktop\AnalysisServicesWorkspaces"

    $ports = @()

    if (-not (Test-Path -LiteralPath $workspaceRoot)) {
        return @()
    }

    $files = @(
        Get-ChildItem `
            -LiteralPath $workspaceRoot `
            -Recurse `
            -Filter "msmdsrv.port.txt" `
            -ErrorAction SilentlyContinue
    )

    foreach ($file in $files) {

        try {

            $raw = [System.IO.File]::ReadAllText($file.FullName)
            $clean = $raw -replace '[^0-9]', ''

            if ($clean) {

                $p = [int]$clean

                if (
                    $p -gt 0 -and
                    $ports -notcontains $p
                ) {
                    $ports += $p
                }
            }
        }
        catch {
        }
    }

    return @($ports)
}

# ============================================================
# 5. NORMALIZAR NOMBRES DE COLUMNAS
# ============================================================

function Normalize-ColumnName {

    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }

    $nameClean = $Name.Trim()

    if ($nameClean -match '\[([^\]]+)\]$') {
        return $Matches[1]
    }

    return $nameClean.TrimStart("[", " ").TrimEnd("]", " ")
}

# ============================================================
# 6. LEER DATAREADER
# ============================================================

function Read-AdomdRows {

    param(
        $Reader
    )

    $rows = @()
    $fieldCount = $Reader.FieldCount

    while ($Reader.Read()) {

        $object = [ordered]@{}

        for ($i = 0; $i -lt $fieldCount; $i++) {

            $columnName = Normalize-ColumnName `
                ([string]$Reader.GetName($i))

            if ($Reader.IsDBNull($i)) {

                $value = $null
            }
            else {

                $value = $Reader.GetValue($i)

                if ($value -is [datetime]) {
                    $value = $value.ToString("o")
                }
                elseif ($value -is [System.DBNull]) {
                    $value = $null
                }
            }

            $object[$columnName] = $value
        }

        $rows += [pscustomobject]$object
    }

    return @($rows)
}

# ============================================================
# 7. CONSULTAR DAX
# ============================================================

function Invoke-DaxQuery {

    param(
        $Connection,
        [string]$Dax
    )

    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Dax

    $reader = $cmd.ExecuteReader()

    try {
        return @(Read-AdomdRows -Reader $reader)
    }
    finally {
        try {
            $reader.Close()
        }
        catch {
        }
    }
}

# ============================================================
# 8. CONSULTAR MODELO POWER BI
# ============================================================

function Query-Model {

    param(
        [int]$P
    )

    $connectionString =
        "Data Source=localhost:$P;" +
        "Integrated Security=SSPI;" +
        "Persist Security Info=True;" +
        "Impersonation Level=Impersonate"

    $conn = New-Object `
        Microsoft.AnalysisServices.AdomdClient.AdomdConnection(
            $connectionString
        )

    try {

        $conn.Open()

        if ($Diagnostic) {
            Write-Host "Conectado a localhost:$P"
        }

        $catalogs =
            $conn.GetSchemaDataSet(
                "DBSCHEMA_CATALOGS",
                $null
            ).Tables[0]

        foreach ($catalogRow in $catalogs.Rows) {

            $catalog = [string]$catalogRow["CATALOG_NAME"]

            if ([string]::IsNullOrWhiteSpace($catalog)) {
                continue
            }

            try {

                $conn.ChangeDatabase($catalog)

                # ====================================================
                # ACTIVIDAD DIARIA
                # ====================================================

                $daxActividad = @"
EVALUATE
SELECTCOLUMNS(
    'ACTIVIDAD_DIARIA_MODELOS',

    "ProyectoConcurso",
        'ACTIVIDAD_DIARIA_MODELOS'[ProyectoConcurso],

    "Modelo",
        'ACTIVIDAD_DIARIA_MODELOS'[Modelo],

    "Disciplina",
        'ACTIVIDAD_DIARIA_MODELOS'[Disciplina],

    "Responsable Modificacion",
        'ACTIVIDAD_DIARIA_MODELOS'[Responsable Modificación],

    "Equipo",
        'ACTIVIDAD_DIARIA_MODELOS'[Equipo],

    "IdModelo",
        'ACTIVIDAD_DIARIA_MODELOS'[IdModelo],

    "Fecha",
        'ACTIVIDAD_DIARIA_MODELOS'[Fecha],

    "Modificado",
        'ACTIVIDAD_DIARIA_MODELOS'[Modificado],

    "Publicado",
        'ACTIVIDAD_DIARIA_MODELOS'[Publicado],

    "EstadoDia",
        'ACTIVIDAD_DIARIA_MODELOS'[EstadoDia],

    "MetaPublicacion",
        'ACTIVIDAD_DIARIA_MODELOS'[MetaPublicacion],

    "PublicacionCumplida",
        'ACTIVIDAD_DIARIA_MODELOS'[PublicacionCumplida],

    "LlaveCruce",
        'ACTIVIDAD_DIARIA_MODELOS'[LlaveCruce]
)
"@

                $actividad =
                    @(Invoke-DaxQuery `
                        -Connection $conn `
                        -Dax $daxActividad)

                if ($actividad.Count -eq 0) {
                    continue
                }

                # ====================================================
                # HISTORIAL PUBLICACIONES
                # ====================================================

                $daxHistorial = @"
EVALUATE
SELECTCOLUMNS(
    'HISTORIAL_PUBLICACIONES_MODELOS',

    "Modelo",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Modelo],

    "Version",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Version],

    "FechaHoraPublicacion",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Fecha y hora de publicación],

    "Fecha",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Fecha],

    "InicioMes",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Inicio de mes],

    "Ano",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Año],

    "NumeroMes",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Número de mes],

    "Mes",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Mes],

    "AnoMes",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Año-Mes],

    "IdPublicacion",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Id de publicación],

    "IdModelo",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Id de modelo],

    "ProyectoConcurso",
        'HISTORIAL_PUBLICACIONES_MODELOS'[ProyectoConcurso],

    "Disciplina",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Disciplina],

    "PublicadoPor",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Publicado por],

    "Equipo",
        'HISTORIAL_PUBLICACIONES_MODELOS'[Equipo]
)
"@

                $historial =
                    @(Invoke-DaxQuery `
                        -Connection $conn `
                        -Dax $daxHistorial)

                if ($Diagnostic) {

                    Write-Host ""
                    Write-Host "Catalogo correcto: $catalog"
                    Write-Host "Actividad: $($actividad.Count) filas"
                    Write-Host "Historial: $($historial.Count) filas"
                }

                return [pscustomobject]@{

                    Port = $P

                    Catalog = $catalog

                    ActivityRows = @($actividad)

                    HistoryRows = @($historial)
                }
            }
            catch {

                if ($Diagnostic) {

                    Write-Host `
                        "Catalogo '$catalog' no corresponde: $($_.Exception.Message)"
                }
            }
        }

        throw "Ningun catalogo en localhost:$P contiene las tablas requeridas."
    }
    finally {

        try {
            $conn.Close()
        }
        catch {
        }

        try {
            $conn.Dispose()
        }
        catch {
        }
    }
}

# ============================================================
# 9. FUNCIONES AUXILIARES
# ============================================================

function Get-PeriodoFromDate {

    param(
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    try {

        $date = [datetime]$Value

        return $date.ToString("yyyy-MM")
    }
    catch {

        return $null
    }
}

function Get-IntValue {

    param(
        $Value
    )

    if ($null -eq $Value) {
        return 0
    }

    try {
        return [int]$Value
    }
    catch {

        try {
            return [int][double]$Value
        }
        catch {
            return 0
        }
    }
}

function Get-VersionNumber {

    param(
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value

    $matches =
        [regex]::Matches(
            $text,
            '\d+'
        )

    if ($matches.Count -eq 0) {
        return $null
    }

    try {

        return [int]$matches[
            $matches.Count - 1
        ].Value
    }
    catch {

        return $null
    }
}

function Get-DistinctJoined {

    param(
        $Values
    )

    $clean =
        @(
            $Values |
            Where-Object {
                $null -ne $_ -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$_
                )
            } |
            ForEach-Object {
                ([string]$_).Trim()
            } |
            Sort-Object -Unique
        )

    return ($clean -join " | ")
}

# ============================================================
# 10. GENERAR DATA PARA HTML
# ============================================================

function Build-ReportData {

    param(
        [array]$ActivityRows,
        [array]$HistoryRows
    )

    # --------------------------------------------------------
    # NORMALIZAR ACTIVIDAD
    # --------------------------------------------------------

    $activity =
        @(
            foreach ($row in $ActivityRows) {

                $period =
                    Get-PeriodoFromDate `
                        $row.Fecha

                if (-not $period) {
                    continue
                }

                [pscustomobject]@{

                    Periodo = $period

                    Proyecto = [string]$row.ProyectoConcurso

                    Modelo = [string]$row.Modelo

                    Disciplina = [string]$row.Disciplina

                    Responsable = [string]$row.'Responsable Modificacion'

                    Equipo = [string]$row.Equipo

                    IdModelo = [string]$row.IdModelo

                    Fecha = [string]$row.Fecha

                    Modificado = Get-IntValue $row.Modificado

                    Publicado = Get-IntValue $row.Publicado

                    EstadoDia = [string]$row.EstadoDia

                    MetaPublicacion =
                        Get-IntValue $row.MetaPublicacion

                    PublicacionCumplida =
                        Get-IntValue $row.PublicacionCumplida

                    LlaveCruce = [string]$row.LlaveCruce
                }
            }
        )

    # --------------------------------------------------------
    # MODELOS
    # Agrupado por Periodo + Proyecto + Modelo
    # --------------------------------------------------------

    $modelGroups =
        @(
            $activity |
            Group-Object {
                "{0}|{1}|{2}" -f `
                    $_.Periodo,
                    $_.Proyecto,
                    $_.Modelo
            }
        )

    $models =
        @(
            foreach ($group in $modelGroups) {

                $rows = @($group.Group)

                $first = $rows[0]

                $meta =
                    (
                        $rows |
                        Measure-Object `
                            -Property MetaPublicacion `
                            -Sum
                    ).Sum

                $cumplidas =
                    (
                        $rows |
                        Measure-Object `
                            -Property PublicacionCumplida `
                            -Sum
                    ).Sum

                $meta = Get-IntValue $meta
                $cumplidas = Get-IntValue $cumplidas

                $incumplimientos =
                    [Math]::Max(
                        0,
                        $meta - $cumplidas
                    )

                $cumplimiento =
                    if ($meta -gt 0) {
                        $cumplidas / $meta
                    }
                    else {
                        0
                    }

                [pscustomobject]@{

                    Periodo = $first.Periodo

                    Proyecto = $first.Proyecto

                    Modelo = $first.Modelo

                    IdModelo = $first.IdModelo

                    Disciplina =
                        Get-DistinctJoined `
                            ($rows.Disciplina)

                    Responsable =
                        Get-DistinctJoined `
                            ($rows.Responsable)

                    Equipo =
                        Get-DistinctJoined `
                            ($rows.Equipo)

                    Publicaciones = $cumplidas

                    Meta = $meta

                    Incumplimientos = $incumplimientos

                    Cumplimiento = [double]$cumplimiento
                }
            }
        )

    # --------------------------------------------------------
    # PROYECTOS
    # --------------------------------------------------------

    $projectGroups =
        @(
            $models |
            Group-Object {
                "{0}|{1}" -f `
                    $_.Periodo,
                    $_.Proyecto
            }
        )

    $projects =
        @(
            foreach ($group in $projectGroups) {

                $rows = @($group.Group)

                $first = $rows[0]

                $meta =
                    (
                        $rows |
                        Measure-Object `
                            -Property Meta `
                            -Sum
                    ).Sum

                $publicaciones =
                    (
                        $rows |
                        Measure-Object `
                            -Property Publicaciones `
                            -Sum
                    ).Sum

                $meta = Get-IntValue $meta
                $publicaciones = Get-IntValue $publicaciones

                $cumplimiento =
                    if ($meta -gt 0) {
                        $publicaciones / $meta
                    }
                    else {
                        0
                    }

                [pscustomobject]@{

                    Periodo = $first.Periodo

                    Proyecto = $first.Proyecto

                    Modelos =
                        @(
                            $rows.Modelo |
                            Sort-Object -Unique
                        ).Count

                    Publicaciones = $publicaciones

                    Meta = $meta

                    Cumplimiento = [double]$cumplimiento

                    Brecha =
                        [Math]::Max(
                            0,
                            $meta - $publicaciones
                        )
                }
            }
        )

    # --------------------------------------------------------
    # PORTAFOLIO
    # --------------------------------------------------------

    $portfolioGroups =
        @(
            $projects |
            Group-Object Periodo
        )

    $portfolio =
        @(
            foreach ($group in $portfolioGroups) {

                $projectRows = @($group.Group)

                $period = $group.Name

                $periodModels =
                    @(
                        $models |
                        Where-Object {
                            $_.Periodo -eq $period
                        }
                    )

                $meta =
                    (
                        $projectRows |
                        Measure-Object `
                            -Property Meta `
                            -Sum
                    ).Sum

                $publicaciones =
                    (
                        $projectRows |
                        Measure-Object `
                            -Property Publicaciones `
                            -Sum
                    ).Sum

                $meta = Get-IntValue $meta
                $publicaciones = Get-IntValue $publicaciones

                $cumplimiento =
                    if ($meta -gt 0) {
                        $publicaciones / $meta
                    }
                    else {
                        0
                    }

                [pscustomobject]@{

                    Periodo = $period

                    Proyectos =
                        @(
                            $projectRows.Proyecto |
                            Sort-Object -Unique
                        ).Count

                    # CORRECCION:
                    # $periodModels YA esta agrupado por
                    # Periodo + Proyecto + Modelo.
                    # Cada fila representa un modelo unico
                    # dentro del proyecto y periodo.
                    Modelos =
                        $periodModels.Count

                    Publicaciones = $publicaciones

                    Meta = $meta

                    Cumplimiento = [double]$cumplimiento

                    Brecha =
                        [Math]::Max(
                            0,
                            $meta - $publicaciones
                        )
                }
            }
        )

    # --------------------------------------------------------
    # HISTORIAL / VERSIONES
    # --------------------------------------------------------

    $history =
        @(
            foreach ($row in $HistoryRows) {

                $period = [string]$row.AnoMes

                if ([string]::IsNullOrWhiteSpace($period)) {

                    $period =
                        Get-PeriodoFromDate `
                            $row.Fecha
                }

                if (-not $period) {
                    continue
                }

                $fechaHora = $null

                try {
                    $fechaHora =
                        [datetime]$row.FechaHoraPublicacion
                }
                catch {

                    try {
                        $fechaHora =
                            [datetime]$row.Fecha
                    }
                    catch {
                    }
                }

                [pscustomobject]@{

                    Periodo = $period

                    Proyecto = [string]$row.ProyectoConcurso

                    Modelo = [string]$row.Modelo

                    IdModelo = [string]$row.IdModelo

                    VersionRaw = [string]$row.Version

                    VersionNumber =
                        Get-VersionNumber `
                            $row.Version

                    FechaHora = $fechaHora

                    IdPublicacion = [string]$row.IdPublicacion

                    Disciplina = [string]$row.Disciplina

                    PublicadoPor = [string]$row.PublicadoPor

                    Equipo = [string]$row.Equipo
                }
            }
        )

    $versionGroups =
        @(
            $history |
            Group-Object {
                "{0}|{1}|{2}" -f `
                    $_.Periodo,
                    $_.Proyecto,
                    $_.Modelo
            }
        )

    $versions =
        @(
            foreach ($group in $versionGroups) {

                $rows =
                    @(
                        $group.Group |
                        Sort-Object FechaHora
                    )

                if ($rows.Count -eq 0) {
                    continue
                }

                $first = $rows[0]

                $last =
                    $rows[$rows.Count - 1]

                $versionInitial = $first.VersionNumber

                $versionCurrent = $last.VersionNumber

                $advance =
                    if (
                        $null -ne $versionInitial -and
                        $null -ne $versionCurrent
                    ) {

                        $versionCurrent - $versionInitial
                    }
                    else {
                        0
                    }

                [pscustomobject]@{

                    Periodo = $first.Periodo

                    Proyecto = $first.Proyecto

                    Modelo = $first.Modelo

                    IdModelo = $first.IdModelo

                    VersionInicial = $versionInitial

                    VersionActual = $versionCurrent

                    VersionInicialTexto = $first.VersionRaw

                    VersionActualTexto = $last.VersionRaw

                    AvanceVersion = $advance

                    PublicacionesMesTotal = $rows.Count
                }
            }
        )

    # --------------------------------------------------------
    # DETALLE INTERACTIVO
    # --------------------------------------------------------

    $detail =
        @(
            foreach ($model in $models) {

                [pscustomobject]@{

                    Periodo = $model.Periodo

                    Proyecto = $model.Proyecto

                    Modelo = $model.Modelo

                    IdModelo = $model.IdModelo

                    Disciplina = $model.Disciplina

                    Responsable = $model.Responsable

                    Equipo = $model.Equipo

                    Meta = $model.Meta

                    PublicacionesCumplidas =
                        $model.Publicaciones

                    Incumplimientos =
                        $model.Incumplimientos

                    Cumplimiento =
                        $model.Cumplimiento
                }
            }
        )

    # --------------------------------------------------------
    # ACTIVIDAD DIARIA COMPLETA
    # --------------------------------------------------------

    $activityDetail =
        @(
            $activity |
            Sort-Object `
                Periodo,
                Proyecto,
                Modelo,
                Fecha
        )

    return [ordered]@{

        portfolio = @($portfolio)

        projects = @($projects)

        models = @($models)

        versions = @($versions)

        detail = @($detail)

        activity = @($activityDetail)
    }
}

# ============================================================
# 11. PROCESO PRINCIPAL
# ============================================================

try {

    Write-Log "Inicio de exportacion."

    Load-Adomd

    Write-Host ""
    Write-Host "============================================"
    Write-Host " PUBLICACIONES_VENTAS - EXPORTADOR HTML"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "Buscando PUBLICACIONES_VENTAS abierto en Power BI Desktop..."

    $ports = @(
        Get-PowerBiPorts -ManualPort $Port
    )

    if ((-not $ports) -or ($ports.Count -eq 0)) {
        throw "No se encontro ninguna instancia local de Power BI Desktop."
    }

    Write-Host "Instancias locales detectadas: $($ports -join ', ')"

    $result = $null
    $errors = @()

    foreach ($p in $ports) {

        try {

            $result = Query-Model -P $p

            if ($result) {
                break
            }
        }
        catch {

            $errors += "Puerto $p -> $($_.Exception.Message)"
        }
    }

    if (-not $result) {
        throw "Power BI esta abierto, pero no fue posible localizar PUBLICACIONES_VENTAS. $($errors -join ' | ')"
    }

    $activityRows = @($result.ActivityRows)
    $historyRows = @($result.HistoryRows)
    $activityCount = $activityRows.Count
    $historyCount = $historyRows.Count

    Write-Host ""
    Write-Host "Modelo encontrado." -ForegroundColor Green
    Write-Host "Puerto: $($result.Port)"
    Write-Host "Catalogo: $($result.Catalog)"
    Write-Host "Actividad diaria: $activityCount"
    Write-Host "Historial publicaciones: $historyCount"

    if ($activityCount -eq 0) {
        Write-Host ""
        Write-Host "SIN ACTUALIZACION" -ForegroundColor Yellow
        Write-Host "ACTIVIDAD_DIARIA_MODELOS devolvio 0 registros."
        Write-Host "Se conserva intacto el ultimo JSON y HTML validos."
        Write-Log "Exportacion omitida: ACTIVIDAD_DIARIA_MODELOS devolvio 0 registros. Se conserva el ultimo JSON y HTML validos."
        exit 0
    }

    if ($historyCount -eq 0) {
        Write-Host ""
        Write-Host "SIN ACTUALIZACION" -ForegroundColor Yellow
        Write-Host "HISTORIAL_PUBLICACIONES_MODELOS devolvio 0 registros."
        Write-Host "Se conserva intacto el ultimo JSON y HTML validos."
        Write-Log "Exportacion omitida: HISTORIAL_PUBLICACIONES_MODELOS devolvio 0 registros. Se conserva el ultimo JSON y HTML validos."
        exit 0
    }

    $reportData = Build-ReportData -ActivityRows $activityRows -HistoryRows $historyRows

    $portfolioCount = @($reportData.portfolio).Count
    $projectsCount = @($reportData.projects).Count
    $modelsCount = @($reportData.models).Count
    $versionsCount = @($reportData.versions).Count

    if ($modelsCount -eq 0) {
        Write-Host ""
        Write-Host "SIN ACTUALIZACION" -ForegroundColor Yellow
        Write-Host "Los datos fueron leidos, pero el procesamiento genero 0 modelos."
        Write-Host "Se conserva intacto el ultimo JSON y HTML validos."
        Write-Log "Exportacion omitida: Build-ReportData genero 0 modelos. Se conserva el ultimo JSON y HTML validos."
        exit 0
    }

    $snapshot = [ordered]@{
        generatedAt = (Get-Date).ToString("o")
        source = "Power BI Desktop / PUBLICACIONES_VENTAS"
        port = $result.Port
        catalog = $result.Catalog
        activityRowCount = $activityCount
        historyRowCount = $historyCount
        portfolio = @($reportData.portfolio)
        projects = @($reportData.projects)
        models = @($reportData.models)
        versions = @($reportData.versions)
        detail = @($reportData.detail)
        activity = @($reportData.activity)
    }

    $currentComparable = [ordered]@{
        activityRowCount = $activityCount
        historyRowCount = $historyCount
        portfolio = @($reportData.portfolio)
        projects = @($reportData.projects)
        models = @($reportData.models)
        versions = @($reportData.versions)
        detail = @($reportData.detail)
        activity = @($reportData.activity)
    }

    $currentComparableJson = $currentComparable | ConvertTo-Json -Depth 10 -Compress

    $previousSnapshot = $null
    $previousComparableJson = $null

    if (Test-Path -LiteralPath $JsonPath) {
        try {
            $previousJson = [System.IO.File]::ReadAllText($JsonPath)
            if (-not [string]::IsNullOrWhiteSpace($previousJson)) {
                $previousSnapshot = $previousJson | ConvertFrom-Json
                $previousComparable = [ordered]@{
                    activityRowCount = [int]$previousSnapshot.activityRowCount
                    historyRowCount = [int]$previousSnapshot.historyRowCount
                    portfolio = @($previousSnapshot.portfolio)
                    projects = @($previousSnapshot.projects)
                    models = @($previousSnapshot.models)
                    versions = @($previousSnapshot.versions)
                    detail = @($previousSnapshot.detail)
                    activity = @($previousSnapshot.activity)
                }
                $previousComparableJson = $previousComparable | ConvertTo-Json -Depth 10 -Compress
            }
        }
        catch {
            if ($Diagnostic) {
                Write-Host "No fue posible comparar contra el JSON anterior: $($_.Exception.Message)"
            }
        }
    }

    if ((-not [string]::IsNullOrWhiteSpace($previousComparableJson)) -and ($previousComparableJson -eq $currentComparableJson)) {
        Write-Host ""
        Write-Host "SIN CAMBIOS EN PUBLICACIONES_VENTAS" -ForegroundColor Cyan
        Write-Host "Actividad: $activityCount"
        Write-Host "Historial: $historyCount"
        Write-Host "Modelos: $modelsCount"
        Write-Host "El JSON y el HTML existentes se conservan intactos."
        if (($null -ne $previousSnapshot) -and ($null -ne $previousSnapshot.generatedAt)) {
            Write-Host "Ultima exportacion valida: $($previousSnapshot.generatedAt)"
        }
        Write-Log "Sin cambios en PUBLICACIONES_VENTAS. Se conservan JSON y HTML existentes. Activity=$activityCount, History=$historyCount, Models=$modelsCount."
        exit 0
    }

    Ensure-Directory $DataDir
    Ensure-Directory $DashboardDir

    $json = $snapshot | ConvertTo-Json -Depth 10

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        throw "No se encontro la plantilla HTML: $TemplatePath. Se conserva el ultimo JSON y HTML validos."
    }

    $template = [System.IO.File]::ReadAllText($TemplatePath)

    if ([string]::IsNullOrWhiteSpace($template)) {
        throw "La plantilla HTML esta vacia. Se conserva el ultimo JSON y HTML validos."
    }

    $safeJson = $json.Replace("</script>", "<\/script>")
    $marker = '<script id="publicaciones-data" type="application/json"></script>'
    $html = $null

    if ($template.Contains($marker)) {
        $html = $template.Replace($marker, '<script id="publicaciones-data" type="application/json">' + $safeJson + '</script>')
    }
    elseif ($template.Contains('__PUBLICACIONES_DATA_JSON__')) {
        $html = $template.Replace('__PUBLICACIONES_DATA_JSON__', $safeJson)
    }
    elseif ($template.Contains('</body>')) {
        $html = $template.Replace('</body>', '<script id="publicaciones-data" type="application/json">' + $safeJson + '</script></body>')
    }
    else {
        throw "La plantilla HTML no contiene un punto valido para insertar los datos. Se conserva el ultimo JSON y HTML validos."
    }

    if ([string]::IsNullOrWhiteSpace($html)) {
        throw "No fue posible generar el nuevo HTML. Se conserva el ultimo JSON y HTML validos."
    }

    [System.IO.File]::WriteAllText($JsonPath, $json, $Utf8NoBom)
    [System.IO.File]::WriteAllText($HtmlPath, $html, $Utf8NoBom)

    Write-Host ""
    Write-Host "EXPORTACION COMPLETADA" -ForegroundColor Green
    Write-Host ""
    Write-Host "Puerto: $($result.Port)"
    Write-Host "Catalogo: $($result.Catalog)"
    Write-Host ""
    Write-Host "Actividad: $activityCount"
    Write-Host "Historial: $historyCount"
    Write-Host ""
    Write-Host "Portfolio: $portfolioCount"
    Write-Host "Projects: $projectsCount"
    Write-Host "Models: $modelsCount"
    Write-Host "Versions: $versionsCount"
    Write-Host ""
    Write-Host "JSON:"
    Write-Host $JsonPath
    Write-Host ""
    Write-Host "HTML:"
    Write-Host $HtmlPath

    Write-Log "Exportacion completada. Activity=$activityCount, History=$historyCount, Models=$modelsCount."
    exit 0
}
catch {
    Write-Log "Exportacion cancelada. Se conserva el ultimo JSON y HTML validos. Motivo: $($_.Exception.Message)"
    Fail -Message $_.Exception.Message
}
