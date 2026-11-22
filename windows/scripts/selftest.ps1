# End-to-end self test through the bridge. Run it as the logged-in user with the screen unlocked.
# It opens Notepad, types a test string with Unicode characters, reads it back through UI Automation and closes
# Notepad without saving. Do not touch the keyboard or mouse while it runs.
$ErrorActionPreference = 'Continue'
$Dir = if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME } else { Join-Path $env:LOCALAPPDATA 'aside-bridge' }
$ctl = Join-Path $Dir 'bridgectl.ps1'
function T($name, [scriptblock]$sb) {
  try { $r = & $sb; $s = (($r | Out-String).Trim() -replace '\s+', ' '); if ($s.Length -gt 160) { $s = $s.Substring(0, 160) + '...' }
    Write-Host "[PASS] $name :: $s" -ForegroundColor Green }
  catch { Write-Host "[FAIL] $name :: $_" -ForegroundColor Red }
}
function Call($k, $p, $t = 30) { $j = & $ctl $k $p -Timeout $t -Json | Out-String | ConvertFrom-Json; if (-not $j.ok) { throw ($j.stderr + $j.error) }; $j }

T 'status' { $s = & $ctl status | Out-String | ConvertFrom-Json; if (-not $s.running) { throw 'not running' }; "version=$($s.version) admin=$($s.admin) arch=$($s.arch)" }
T 'ping' { (Call ping $null).stdout }
T 'parallel (slow job does not block)' {
  $slow = Start-Job { & $using:ctl ps 'Start-Sleep 8; "slow"' -Timeout 20 }; Start-Sleep 1
  $sw = [Diagnostics.Stopwatch]::StartNew(); $null = Call ping $null; $ms = $sw.ElapsedMilliseconds
  Receive-Job -Wait $slow | Out-Null; if ($ms -gt 3000) { throw "fast job took $ms ms" }; "fast job $ms ms" }
T 'timeout kill' { $j = & $ctl ps 'Start-Sleep 30' -Timeout 3 -Json | Out-String | ConvertFrom-Json; if (-not $j.timedOut) { throw 'no timeout' }; 'timed out as expected' }
T 'window list' { $w = (Call windows $null).data; "$(@($w).Count) windows" }
T 'sysinfo' { (Call sysinfo $null).stdout }
T 'Notepad Unicode typing + UIA read-back' {
  $script:before = @(Get-Process notepad -ErrorAction SilentlyContinue | ForEach-Object Id)
  Start-Process notepad.exe
  $title = $null
  for ($i = 0; $i -lt 20 -and -not $title; $i++) { Start-Sleep -Milliseconds 500
    $title = ((Call windows $null).data | Where-Object { $_.Title -like '*Notepad*' -or $_.Title -like '*메모장*' } | Select-Object -First 1).Title }
  if (-not $title) { throw 'Notepad window not found' }
  Call focus @{ title = $title } | Out-Null
  $txt = 'AsideBridge self test: ABC 123 한글 éü 😀'
  Call input @{ action = 'type'; text = $txt; force = $true } | Out-Null; Start-Sleep 1
  $doc = Call uia @{ window = $title; op = 'action'; type = 'Document'; action = 'text' }
  if ($doc.stdout -notlike "*$txt*") { $doc = Call uia @{ window = $title; op = 'action'; type = 'Edit'; action = 'text' } }
  if ($doc.stdout -notlike "*$txt*") { throw "read back: $($doc.stdout)" }; 'typed and read back OK' }
T 'screenshot + OCR' { $r = (Call shot @{ ocr = $true } 60).data; "ocr lang=$($r.ocr.language) lines=$(@($r.ocr.lines).Count) (image: $($r.path))" }
T 'close the test Notepad (no save)' { Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $script:before -notcontains $_.Id } | Stop-Process -Force; 'closed' }
T 'CDP (optional: run start-browser-cdp.ps1 first)' { $r = Call cdp @{ op = 'tabs'; port = 9222 } 15; "$(@($r.data).Count) tabs" }
