# bridgectl.ps1 0.1.0 - minimal PowerShell client for AsideBridge for Windows (no Python needed).
# It sends raw jobs (kind + script or argument hashtable); bridgectl.py has the friendlier command set.
#   .\bridgectl.ps1 status
#   .\bridgectl.ps1 ping
#   .\bridgectl.ps1 ps 'Get-Date'
#   .\bridgectl.ps1 input @{action='type'; text='Hello'}
#   .\bridgectl.ps1 shot @{window='Notepad'; ocr=$true}
#   .\bridgectl.ps1 uia @{window='Notepad'; op='tree'; depth=4}
#   .\bridgectl.ps1 stop | resume
# Exit codes: 0 ok, 1 job failed, 2 bridge not running.
param([Parameter(Mandatory)][string]$Kind, $Payload, [double]$Timeout = 60, [switch]$Json)
$Base = if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME }
        elseif (Test-Path (Join-Path $PSScriptRoot 'token')) { $PSScriptRoot }
        else { Join-Path $env:LOCALAPPDATA 'aside-bridge' }
if ($Kind -eq 'stop') { Set-Content (Join-Path $Base 'STOP') "stopped by agent $(Get-Date -Format o)"; 'STOP set'; exit 0 }
if ($Kind -eq 'resume') { Remove-Item (Join-Path $Base 'STOP') -ErrorAction SilentlyContinue; 'resumed'; exit 0 }
$st = Get-Content -Raw (Join-Path $Base 'status.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
$age = if ($st) { [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000 - $st.heartbeatEpoch } else { 9999 }
if ($Kind -eq 'status') {
  if (-not $st) { $st = [pscustomobject]@{ running = $false; error = "no status.json in $Base" } }
  $st | Add-Member -Force NoteProperty heartbeatAgeSec ([math]::Round($age, 1))
  $st | Add-Member -Force NoteProperty running ($age -lt 15)
  $st | Add-Member -Force NoteProperty home $Base
  $st | ConvertTo-Json; if ($age -lt 15) { exit 0 } else { exit 2 }
}
if ($age -gt 15) { Write-Error 'UNAVAILABLE: AsideBridge is not running'; exit 2 }
$id = (Get-Date -Format 'yyyyMMdd-HHmmss-') + [guid]::NewGuid().ToString('N').Substring(0, 8)
$job = [ordered]@{ id = $id; token = (Get-Content -Raw (Join-Path $Base 'token')).Trim(); kind = $Kind; timeout = $Timeout; script = ''; args = @{} }
if ($Payload -is [hashtable]) { $job.args = $Payload } elseif ($Payload) { $job.script = [string]$Payload }
$tmp = Join-Path $Base "inbox\$id.tmp"
[IO.File]::WriteAllText($tmp, ($job | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
Move-Item $tmp (Join-Path $Base "inbox\$id.json")
$out = Join-Path $Base "outbox\$id.json"; $deadline = (Get-Date).AddSeconds($Timeout + 15)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $out) { Start-Sleep -Milliseconds 50
    try { $r = Get-Content -Raw -Encoding UTF8 $out | ConvertFrom-Json; Remove-Item $out
      if ($Json) { $r | ConvertTo-Json -Depth 8 } else { if ($r.stdout) { $r.stdout }; if ($r.stderr) { Write-Host $r.stderr -ForegroundColor Yellow } }
      if ($r.ok) { exit 0 } else { exit 1 } } catch {} }
  Start-Sleep -Milliseconds 100
}
Write-Error 'timed out waiting for result'; exit 1
