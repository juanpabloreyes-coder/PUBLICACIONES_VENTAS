$ErrorActionPreference = "Stop"

$AutomationRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StartFile = Join-Path $AutomationRoot "Start-PUBLICACIONES_VENTAS-Monitor.cmd"

$StartupFolder = [Environment]::GetFolderPath("Startup")

$ShortcutPath = Join-Path $StartupFolder "PUBLICACIONES_VENTAS Monitor.lnk"

$Shell = New-Object -ComObject WScript.Shell
$Shortcut = $Shell.CreateShortcut($ShortcutPath)

$Shortcut.TargetPath = $StartFile
$Shortcut.WorkingDirectory = $AutomationRoot
$Shortcut.WindowStyle = 7
$Shortcut.Description = "Inicia el monitor de sincronizaciones Revit para PUBLICACIONES_VENTAS"

$Shortcut.Save()

Write-Host ""
Write-Host "Inicio automatico configurado."
Write-Host ""
Write-Host "Acceso directo:"
Write-Host $ShortcutPath
Write-Host ""