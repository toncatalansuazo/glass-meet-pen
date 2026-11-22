$ErrorActionPreference = 'Stop'

# Update these three for each release (see ../README.md).
$url64      = 'https://github.com/toncatalansuazo/glass-meet-pen/releases/download/v1.0.0-windows/GlasspenMeet.exe'
$checksum64 = '454FF8E2BF1508B620CCF0C99BD87ECB25D42042252CE84EFBA0172FECCE1234'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$exe      = Join-Path $toolsDir 'GlasspenMeet.exe'

# An upgrade can't replace the exe while it runs.
Get-Process -Name GlasspenMeet -ErrorAction SilentlyContinue | Stop-Process -Force

Get-ChocolateyWebFile -PackageName $env:ChocolateyPackageName -FileFullPath $exe `
  -Url64bit $url64 -Checksum64 $checksum64 -ChecksumType64 'sha256'

# Chocolatey adds a `GlasspenMeet` command; the .gui file makes it start the app without waiting for it to exit.
Set-Content -Path "$exe.gui" -Value ''

$startMenu = [Environment]::GetFolderPath('CommonPrograms')
Install-ChocolateyShortcut -ShortcutFilePath (Join-Path $startMenu 'Glasspen Meet.lnk') -TargetPath $exe `
  -Description 'Draw on your screen while you share it in a call'
