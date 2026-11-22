# Remove AsideBridge for Windows: unregisters the scheduled tasks and stops the bridge and its workers.
# Keeps <home> (token, logs, recipes) unless -Purge is given.
#   .\windows\scripts\uninstall.ps1 [-Dir DIR] [-Purge]
# Run it in an elevated PowerShell if the bridge was installed with administrator rights (the default).
param(
  [string]$Dir = $(if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME } else { Join-Path $env:LOCALAPPDATA 'aside-bridge' }),
  [switch]$Purge
)
$App = Join-Path $Dir 'app'
foreach ($t in 'AsideBridge', 'AsideBridge-Watchdog') {
  Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false
  }
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$App\*.ps1*" } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($Purge -and (Test-Path (Join-Path $Dir 'app\bridge.ps1'))) { Remove-Item -Recurse -Force $Dir; Write-Host "Removed $Dir" }
elseif ($Purge) { Write-Warning "$Dir does not look like an AsideBridge folder; not deleting it" }
Write-Host 'AsideBridge removed.'
