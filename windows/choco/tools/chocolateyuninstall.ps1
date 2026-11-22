$ErrorActionPreference = 'Stop'

# Chocolatey removes the files in this package; the running app and the Start menu shortcut are ours.
Get-Process -Name GlasspenMeet -ErrorAction SilentlyContinue | Stop-Process -Force

$shortcut = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Glasspen Meet.lnk'
if (Test-Path $shortcut) { Remove-Item $shortcut -Force }
