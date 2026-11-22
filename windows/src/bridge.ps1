# AsideBridge for Windows 0.1.0 - main loop.
# Started at logon by Task Scheduler in the user's interactive desktop session (see scripts\install.ps1).
# Watches <home>\inbox\*.json, checks the token, hands each job to a warm worker (worker.ps1) or a fresh
# runner.ps1 process (jobs run in parallel), enforces timeouts and writes <home>\outbox\<id>.json.
$ErrorActionPreference = 'Continue'
$App = $PSScriptRoot
$Base = if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME } else { Split-Path -Parent $App }
$Inbox = Join-Path $Base 'inbox'; $Outbox = Join-Path $Base 'outbox'; $Work = Join-Path $Base 'work'; $Logs = Join-Path $Base 'logs'
foreach ($d in $Inbox, $Outbox, $Work, $Logs) { New-Item -ItemType Directory -Force $d | Out-Null }
$LogFile = Join-Path $Logs 'bridge.log'
$Version = '0.1.0'
function Log($m) { $line = "$((Get-Date).ToString('o')) [$PID] $m"; Add-Content -Path $LogFile -Value $line -Encoding UTF8 }
function Short($s, [int]$n = 160) { $s = [string]$s -replace "`r?`n", ' \n '; if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }

$mutex = New-Object Threading.Mutex($false, 'Global\AsideBridgeWin')
if (-not $mutex.WaitOne(0)) { exit 0 }  # watchdog tick while already running: exit quietly

$TokenFile = Join-Path $Base 'token'
if (-not (Test-Path $TokenFile)) { Log 'no token file; run scripts\install.ps1'; exit 1 }
$Token = (Get-Content -Raw $TokenFile).Trim()
$PsExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$running = @{}   # id -> @{ proc | worker; deadline; out }
$done = 0; $startedAt = Get-Date; $lastBeat = [datetime]::MinValue; $lastClean = [datetime]::MinValue
Log "started v$Version admin=$isAdmin session=$([Diagnostics.Process]::GetCurrentProcess().SessionId) arch=$env:PROCESSOR_ARCHITECTURE"

function Write-Json($path, $obj) {
  $tmp = "$path.tmp"; [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false)); Move-Item -Force $tmp $path
}

# warm worker pool: PowerShell + Add-Type startup costs ~1 s, a warm worker answers in ~0.2 s
$PoolSize = 3
$Workers = @{}   # name -> @{ proc; dir; busy(id or $null) }
function Start-Worker($name) {
  $dir = Join-Path $Work "pool\$name"; New-Item -ItemType Directory -Force $dir | Out-Null
  Remove-Item (Join-Path $dir '*') -Force -ErrorAction SilentlyContinue
  Set-Content (Join-Path $dir 'parent') $PID
  $p = Start-Process -FilePath $PsExe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $App 'worker.ps1')`"", '-Dir', "`"$dir`"")
  $Workers[$name] = @{ proc = $p; dir = $dir; busy = $null }
}
for ($i = 1; $i -le $PoolSize; $i++) { Start-Worker "w$i" }
function Get-FreeWorker {
  foreach ($n in @($Workers.Keys)) { $w = $Workers[$n]
    if ($w.proc.HasExited) { Start-Worker $n; continue }
    if (-not $w.busy -and (Test-Path (Join-Path $w.dir 'ready'))) { return $n } }
  $null
}

while ($true) {
  $now = Get-Date
  if (($now - $lastBeat).TotalSeconds -ge 2) {
    Write-Json (Join-Path $Base 'status.json') ([ordered]@{ version = $Version; pid = $PID; admin = $isAdmin; arch = $env:PROCESSOR_ARCHITECTURE
      startedAt = $startedAt.ToString('o'); heartbeat = $now.ToString('o'); heartbeatEpoch = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() / 1000
      paused = (Test-Path (Join-Path $Base 'STOP')); running = $running.Count; jobsDone = $done })
    $lastBeat = $now
  }
  if (($now - $lastClean).TotalMinutes -ge 30) {
    # housekeeping: files older than 2 days in work\ (incl. step screenshots, not the worker pool) and outbox\; rotate the log at 5 MB
    $lastClean = $now; $cut = $now.AddDays(-2); $del = 0
    $old = @(Get-ChildItem $Work -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$Work\pool\*" -and $_.LastWriteTime -lt $cut })
    $old += @(Get-ChildItem $Outbox -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })
    foreach ($f in $old) { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue; $del++ }
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) { Move-Item -Force $LogFile "$LogFile.1"; Log 'log rotated' }
    if ($del) { Log "cleanup removed $del old files" }
  }
  # timeouts / completions
  foreach ($id in @($running.Keys)) {
    $r = $running[$id]
    if ($r.worker) {
      $wk = $Workers[$r.worker]
      if (-not (Test-Path (Join-Path $wk.dir 'job.json'))) { $running.Remove($id); $done++; $wk.busy = $null
        if (-not (Test-Path $r.out)) { Write-Json $r.out ([ordered]@{ id = $id; ok = $false; exitCode = 1; stderr = 'worker finished without result'; timedOut = $false }) }
        continue }
      if ($wk.proc.HasExited -or $now -gt $r.deadline) {
        $why = if ($wk.proc.HasExited) { 'worker crashed' } else { 'timed out' }
        try { & taskkill.exe /T /F /PID $wk.proc.Id | Out-Null } catch {}
        $running.Remove($id); $done++
        Write-Json $r.out ([ordered]@{ id = $id; ok = $false; exitCode = 124; stdout = ''; stderr = $why; timedOut = $true })
        Log "job $id TIMEOUT/CRASH on $($r.worker)"; Start-Worker $r.worker; continue }
      continue
    }
    if ($r.proc.HasExited) { $running.Remove($id); $done++
      if (-not (Test-Path $r.out)) { Write-Json $r.out ([ordered]@{ id = $id; ok = $false; exitCode = $r.proc.ExitCode; stderr = 'runner exited without result'; timedOut = $false }) }
      Log "job $id done exit=$($r.proc.ExitCode)" }
    elseif ($now -gt $r.deadline) {
      try { & taskkill.exe /T /F /PID $r.proc.Id | Out-Null } catch {}
      $running.Remove($id); $done++
      Write-Json $r.out ([ordered]@{ id = $id; ok = $false; exitCode = 124; stdout = ''; stderr = 'timed out'; timedOut = $true })
      Log "job $id TIMEOUT"
    }
  }
  if (-not (Test-Path (Join-Path $Base 'STOP'))) {
    foreach ($f in Get-ChildItem $Inbox -Filter *.json -ErrorAction SilentlyContinue) {
      $job = $null
      try { $job = Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json } catch { continue }  # partially written; retry next tick
      $jf = Join-Path $Work "$($f.BaseName).job.json"; Move-Item -Force $f.FullName $jf
      $id = if ($job.id) { [string]$job.id -replace '[^\w\-]', '' } else { $f.BaseName }
      $out = Join-Path $Outbox "$id.json"
      if ($job.token -ne $Token) { Log "job $id REJECTED bad token"; Write-Json $out ([ordered]@{ id = $id; ok = $false; stderr = 'bad token' }); Remove-Item $jf; continue }
      if ($job.kind -eq 'quit') { foreach ($w in $Workers.Values) { try { Stop-Process -Id $w.proc.Id -Force } catch {} }; Log 'quit requested'; Write-Json $out ([ordered]@{ id = $id; ok = $true; stdout = 'quitting' }); Remove-Item $jf; $mutex.ReleaseMutex(); exit 0 }
      $timeout = if ($job.timeout) { [math]::Min([math]::Max([double]$job.timeout, 1), 900) } else { 60 }
      Log "job $id kind=$($job.kind) timeout=$timeout args=$(Short ($job.args | ConvertTo-Json -Compress -Depth 4)) script=$(Short $job.script)"
      $wn = Get-FreeWorker
      if ($wn) { $wk = $Workers[$wn]; $wk.busy = $id
        Set-Content -Path (Join-Path $wk.dir 'out.txt') -Value $out -Encoding UTF8
        Move-Item -Force $jf (Join-Path $wk.dir 'job.json.tmp'); Move-Item -Force (Join-Path $wk.dir 'job.json.tmp') (Join-Path $wk.dir 'job.json')
        $running[$id] = @{ worker = $wn; deadline = (Get-Date).AddSeconds($timeout); out = $out }; continue }
      $p = Start-Process -FilePath $PsExe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$(Join-Path $App 'runner.ps1')`"", '-JobFile', "`"$jf`"", '-OutFile', "`"$out`"")
      $running[$id] = @{ proc = $p; deadline = (Get-Date).AddSeconds($timeout); out = $out }
    }
  }
  Start-Sleep -Milliseconds 20
}
