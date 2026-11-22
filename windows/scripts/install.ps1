# Install AsideBridge for Windows 0.1.0 (Windows 10/11, x64 or ARM64, Windows PowerShell 5.1).
# Run it yourself in a normal PowerShell window (not from inside an agent); it asks for UAC once:
#   Set-ExecutionPolicy -Scope Process Bypass -Force; .\windows\scripts\install.ps1
#
#   -Dir DIR   data + install folder (default: $env:ASIDEBRIDGE_HOME, else %LOCALAPPDATA%\aside-bridge)
#   -Limited    run the bridge WITHOUT administrator rights (no UAC needed; jobs cannot control elevated windows)
#   -NoStart    register the tasks but do not start the bridge now
#
# What it does: copies windows\src to <home>\app and the CLI to <home>, creates a random token, restricts the
# folder to you + SYSTEM + Administrators, and registers two Task Scheduler tasks for your user:
#   AsideBridge           at logon, interactive session, hidden window (wscript + launch-hidden.vbs)
#   AsideBridge-Watchdog  every 5 minutes, starts the bridge again if it died (exits at once if it is running)
param(
  [string]$Dir = $(if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME } else { Join-Path $env:LOCALAPPDATA 'aside-bridge' }),
  [switch]$Limited,
  [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Limited -and -not $isAdmin) {
  Write-Host 'Re-launching elevated (UAC)...'
  $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`" -Dir `"$Dir`""
  if ($NoStart) { $a += ' -NoStart' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $a; exit
}
$user = $me.Name        # the task runs in THIS user's interactive desktop session
$sid = $me.User.Value
$repo = Split-Path -Parent $PSScriptRoot   # ...\windows
$App = Join-Path $Dir 'app'
Write-Host "Installing AsideBridge to $Dir for $user (arch $env:PROCESSOR_ARCHITECTURE, admin=$(-not $Limited))"

# stop a running instance (by task; the bridge exits when its task stops)
foreach ($t in 'AsideBridge', 'AsideBridge-Watchdog') { Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -like "*$App\*.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $Dir, $App, "$App\lib", "$Dir\inbox", "$Dir\outbox", "$Dir\work", "$Dir\logs", "$Dir\recipes" | Out-Null
Copy-Item -Force "$repo\src\*.ps1" $App
Copy-Item -Force "$repo\src\lib\*" "$App\lib"
Copy-Item -Force "$repo\cli\bridgectl.py", "$repo\cli\bridgectl.ps1" $Dir
if (-not (Test-Path "$Dir\settings.json")) { Copy-Item "$repo\src\settings.json" "$Dir\settings.json" }
Get-ChildItem $Dir -Recurse -File | Unblock-File

# token: 24 random bytes as 48 hex chars
if (-not (Test-Path "$Dir\token")) {
  $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  [IO.File]::WriteAllText("$Dir\token", ([BitConverter]::ToString($b) -replace '-', '').ToLower())
}
# only this user, SYSTEM and Administrators can read the folder (and therefore the token)
& icacls.exe $Dir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "icacls failed ($LASTEXITCODE); check the folder permissions of $Dir" }

# hidden launcher: wscript runs PowerShell without flashing a console window
$vbs = "CreateObject(""WScript.Shell"").Run ""powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """"$App\bridge.ps1"""""", 0, False"
[IO.File]::WriteAllText("$App\launch-hidden.vbs", $vbs, [Text.Encoding]::Unicode)   # UTF-16 LE with BOM (wscript rejects UTF-8 BOM)

$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "//B //Nologo `"$App\launch-hidden.vbs`"" -WorkingDirectory $App
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$level = if ($Limited) { 'Limited' } else { 'Highest' }
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel $level
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'AsideBridge' -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
  -Description 'AsideBridge: runs local AI agent jobs (UI Automation, input, capture, OCR) in the interactive desktop session' -Force | Out-Null
$wd = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName 'AsideBridge-Watchdog' -Action $action -Trigger $wd -Principal $principal -Settings $settings `
  -Description 'AsideBridge watchdog: starts the bridge again if it is not running' -Force | Out-Null

if (-not $NoStart) {
  Start-ScheduledTask -TaskName 'AsideBridge'; Start-Sleep 4
  $st = Get-Content -Raw "$Dir\status.json" -ErrorAction SilentlyContinue | ConvertFrom-Json
  if ($st) { Write-Host "Bridge running: pid=$($st.pid) admin=$($st.admin) arch=$($st.arch) version=$($st.version)" -ForegroundColor Green }
  else { Write-Warning "The bridge did not report status yet. Check $Dir\logs\bridge.log" }
}
Write-Host @"

Done.
  Check:        python "$Dir\bridgectl.py" status      (or: powershell -File "$Dir\bridgectl.ps1" status)
  Self test:    powershell -ExecutionPolicy Bypass -File "$repo\scripts\selftest.ps1"   (types into Notepad)
  Agent skill:  copy $repo\skill\SKILL.md into your agent's skills folder
  Kill switch:  create $Dir\STOP  (delete it to resume)
  OCR in other languages: Settings > Time & language > Language & region > add the language.
"@
