# AsideBridge for Windows 0.1.0 - runs ONE job. Called by a warm worker (worker.ps1) or spawned by bridge.ps1
# as its own process, so jobs run in parallel. Writes the result object to -OutFile.
param([Parameter(Mandatory)][string]$JobFile, [Parameter(Mandatory)][string]$OutFile)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$job = Get-Content -Raw -Encoding UTF8 $JobFile | ConvertFrom-Json
$a = if ($job.args) { $job.args } else { [pscustomobject]@{} }
$started = Get-Date
$result = [ordered]@{ id = $job.id; kind = $job.kind; ok = $false; exitCode = 1; stdout = ''; stderr = ''; data = $null; timedOut = $false; startedAt = $started.ToString('o') }

function Arg($name, $default = $null) { if ($a.PSObject.Properties[$name] -ne $null -and $a.$name -ne $null) { $a.$name } else { $default } }

# ---------- CDP (Chrome / Edge / Whale started with --remote-debugging-port) ----------
function Invoke-ABCdp {
  $port = [int](Arg 'port' 9222); $op = Arg 'op' 'tabs'
  $tabs = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 5
  $pages = @($tabs | Where-Object { $_.type -eq 'page' })
  if ($op -eq 'tabs') { return $pages | Select-Object id, title, url }
  if ($op -eq 'new') { return Invoke-RestMethod -Method Put "http://127.0.0.1:$port/json/new?$(Arg 'url' 'about:blank')" }
  $tabSel = Arg 'tab' 0
  $tab = if ($tabSel -is [string]) { $pages | Where-Object { $_.id -eq $tabSel -or $_.url -like "*$tabSel*" -or $_.title -like "*$tabSel*" } | Select-Object -First 1 } else { $pages[[int]$tabSel] }
  if (-not $tab) { throw "tab not found: $tabSel" }
  if ($op -eq 'navigate') { $method = 'Page.navigate'; $params = @{ url = (Arg 'url') } }
  elseif ($op -eq 'eval') { $method = 'Runtime.evaluate'; $params = @{ expression = (Arg 'expr'); returnByValue = $true; awaitPromise = $true } }
  elseif ($op -eq 'raw') { $method = Arg 'method'; $params = Arg 'params' @{} }
  else { throw "unknown cdp op $op" }
  $ws = New-Object System.Net.WebSockets.ClientWebSocket
  $ct = [Threading.CancellationToken]::None
  $ws.ConnectAsync([Uri]$tab.webSocketDebuggerUrl, $ct).Wait()
  $msg = @{ id = 1; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
  $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, $ct).Wait()
  $buf = New-Object byte[] 65536; $sb = New-Object Text.StringBuilder
  while ($true) {
    $sb.Clear() | Out-Null
    do { $r = $ws.ReceiveAsync([ArraySegment[byte]]$buf, $ct).Result; $sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)) | Out-Null } while (-not $r.EndOfMessage)
    $resp = $sb.ToString() | ConvertFrom-Json
    if ($resp.id -eq 1) { break }
  }
  $ws.Dispose()
  if ($resp.error) { throw ($resp.error | ConvertTo-Json -Compress) }
  if ($op -eq 'eval') { if ($resp.result.exceptionDetails) { throw ($resp.result.exceptionDetails.text + ' ' + $resp.result.exceptionDetails.exception.description) }; return $resp.result.result.value }
  $resp.result
}

# ---------- input guard, capture, wait/watch, file dialogs, sysinfo, sequences ----------
function AB-Fuzzy([string]$hay, [string]$needle) {
  $h = $hay -replace '\s', ''; $n = $needle -replace '\s', ''
  if (-not $n) { return $false }; if ($h.Contains($n)) { return $true }
  if ($n.Length -lt 3) { return $false }
  # LCS ratio: tolerate small OCR misreads (one or two wrong characters)
  $m = $h.Length; $k = $n.Length; $prev = New-Object int[] ($k + 1); $best = 0
  for ($i = 1; $i -le $m; $i++) { $cur = New-Object int[] ($k + 1)
    for ($j = 1; $j -le $k; $j++) { if ($h[$i-1] -eq $n[$j-1]) { $cur[$j] = $prev[$j-1] + 1 } else { $cur[$j] = [math]::Max($prev[$j], $cur[$j-1]) } }
    $prev = $cur }
  return ($prev[$k] / $k) -ge [double](Arg 'fuzzy' 0.75)
}
function AB-Cfg {
  # <home>\settings.json overrides these defaults
  $c = [ordered]@{ idleGuardSec = 3; idleWaitSec = 20; stepShots = $false; ocrLang = ''; sysinfoServices = @() }
  $p = Join-Path $ABBase 'settings.json'
  if (Test-Path $p) { try { $j = Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json; foreach ($k in @($c.Keys)) { if ($j.PSObject.Properties[$k]) { $c[$k] = $j.$k } } } catch {} }
  [pscustomobject]$c
}
function AB-Lang { [string](Arg 'lang' (AB-Cfg).ocrLang) }
function AB-SelfFile { Join-Path $ABBase 'work\self-input.tick' }
$ABToastApp = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
function AB-Toast([string]$title, [string]$msg) {
  try {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $x = New-Object Windows.Data.Xml.Dom.XmlDocument
    $x.LoadXml("<toast scenario='reminder'><visual><binding template='ToastGeneric'><text>$(& $esc $title)</text><text>$(& $esc $msg)</text></binding></visual><actions><action content='OK' arguments='ok' activationType='system'/></actions><audio silent='true'/></toast>")
    $n = [Windows.UI.Notifications.ToastNotification]::new($x); $n.Tag = 'guard'; $n.Group = 'aside'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($ABToastApp).Show($n)
  } catch {}
}
function AB-ToastClear { try { [Windows.UI.Notifications.ToastNotificationManager]::History.Remove('guard', 'aside', $ABToastApp) } catch {} }
function AB-Guard {
  if (Test-Path (Join-Path $ABBase 'STOP')) { throw 'STOPPED: the STOP switch is on (delete <home>\STOP or run bridgectl resume)' }
  if (-not [AsideBridge.Native]::InputDesktopAvailable()) { throw 'LOCKED: input desktop not available (screen locked or UAC secure desktop)' }
  $exp = [string](Arg 'expect' '')
  if ($exp -and -not (Arg 'force' $false)) {
    $fh = [AsideBridge.Native2]::Foreground(); $fw = [AsideBridge.Native]::Windows() | Where-Object Handle -eq $fh | Select-Object -First 1
    if (-not $fw -or $fw.Title -notlike "*$exp*") { throw "FRONT_CHANGED: foreground window is '$($fw.Title)', expected '*$exp*'" }
  }
  $cfg = AB-Cfg; $need = [double]$cfg.idleGuardSec
  if ($need -le 0 -or (Arg 'force' $false)) { return }
  $end = (Get-Date).AddSeconds([double]$cfg.idleWaitSec); $shown = $false
  while ($true) {
    $last = [double][AsideBridge.Native2]::LastInputTick(); $idle = [AsideBridge.Native2]::IdleSeconds()
    $self = 0; $sf = AB-SelfFile; if (Test-Path $sf) { $self = [double](Get-Content $sf -ErrorAction SilentlyContinue) }
    if ($idle -ge $need -or ($self -gt 0 -and $last -le ($self + 300))) { if ($shown) { AB-ToastClear }; return }
    if (-not $shown) { AB-Toast 'AsideBridge is waiting' "An agent wants to use the keyboard/mouse. Let go for $need s; it gives up after $([double]$cfg.idleWaitSec) s."; $shown = $true }
    if ((Get-Date) -gt $end) { AB-ToastClear; AB-Toast 'AsideBridge paused an action' 'You were using the PC, so the agent did not type or click.'; throw "USER_ACTIVE: the user is using the PC (idle $([math]::Round($idle,1)) s < $need s). --force skips this check" }
    Start-Sleep -Milliseconds 500
  }
}
function AB-MarkSelf { Set-Content (AB-SelfFile) ([AsideBridge.Native2]::Tick()) }
function AB-Step([string]$tag) {
  $cfg = AB-Cfg; if (-not $cfg.stepShots) { return }
  if ($tag -eq 'before') { $k = [string](Arg 'keys' ''); $ac = [string](Arg 'action' ''); if (-not ($k -match 'enter' -or $ac -match 'click' -or $job.kind -eq 'clip')) { return } }
  try {
    $dir = Join-Path $ABBase ("work\steps\" + (Get-Date -Format 'yyyyMMdd')); New-Item -ItemType Directory -Force $dir | Out-Null
    $png = Join-Path $dir "tmp-$($job.id).png"; [void][AsideBridge.Native]::Screenshot($png, 0, 0, 0, 0)
    $jpg = Join-Path $dir ("{0}-{1}-{2}-{3}.jpg" -f (Get-Date -Format 'HHmmss'), $job.id.Substring($job.id.Length - 8), $job.kind, $tag)
    [AsideBridge.Native2]::ToJpegScaled($png, $jpg, 0.5); Remove-Item $png -ErrorAction SilentlyContinue
  } catch {}
}
function AB-FindWin([string]$title, $handle) {
  if ($handle) { return [AsideBridge.Native]::Windows() | Where-Object Handle -eq ([long]$handle) | Select-Object -First 1 }
  $all = [AsideBridge.Native]::Windows()
  $w = $all | Where-Object Title -eq $title | Select-Object -First 1
  if (-not $w) { $w = $all | Where-Object Title -like "*$title*" | Select-Object -First 1 }
  $w
}
function AB-shotbg {
  $w = AB-FindWin (Arg 'window') (Arg 'handle'); if (-not $w) { throw 'window not found' }
  $path = Arg 'path' (Join-Path $ABBase "work\shotbg-$($job.id).png")
  $rect = [AsideBridge.Native2]::CaptureWindow($w.Handle, $path)
  $d = [ordered]@{ path = $path; rect = $rect; title = $w.Title; darkPercent = [math]::Round([AsideBridge.Native2]::DarkPercent($path), 1) }
  if ($d.darkPercent -gt 90) { $result.stderr += "warning: capture is mostly black (app may block background capture; use shot --window instead)`n" }
  if (Arg 'ocr' $false) { $p = $rect.Split(','); $d.ocr = Invoke-ABOcr $path (AB-Lang) ([int]$p[0]) ([int]$p[1]) }
  [pscustomobject]$d
}
function AB-watch {
  $limit = [double](Arg 'timeoutSec' 60); $iv = [int](Arg 'intervalMs' 1000); $th = [double](Arg 'threshold' 1.0)
  $title = Arg 'window'; $base = Join-Path $ABBase "work\watch-$($job.id)-a.png"; $cur = Join-Path $ABBase "work\watch-$($job.id)-b.png"
  $grab = {
    param($p)
    if ($title) { $w = AB-FindWin $title $null; if (-not $w) { throw 'window not found' }; [void][AsideBridge.Native2]::CaptureWindow($w.Handle, $p) }
    else { [void][AsideBridge.Native]::Screenshot($p, [int](Arg 'x' 0), [int](Arg 'y' 0), [int](Arg 'w' 0), [int](Arg 'h' 0)) }
  }
  & $grab $base; $end = (Get-Date).AddSeconds($limit); $n = 0
  while ((Get-Date) -lt $end) {
    Start-Sleep -Milliseconds $iv; $n++; & $grab $cur
    $d = [AsideBridge.Native2]::DiffPercent($base, $cur)
    if ($d -ge $th) { $keep = Arg 'path' (Join-Path $ABBase "work\watch-$($job.id).png"); Move-Item -Force $cur $keep; Remove-Item $base -ErrorAction SilentlyContinue
      return [pscustomobject]@{ changed = $true; diffPercent = [math]::Round($d, 2); checks = $n; path = $keep } }
  }
  Remove-Item $base, $cur -ErrorAction SilentlyContinue
  [pscustomobject]@{ changed = $false; checks = $n }
}
function AB-filedlg {
  $path = [string](Arg 'path'); if (-not $path) { throw 'need path' }
  # common Open/Save dialog titles (Korean and English Windows); pass --title for other languages
  $names = @('열기', '다른 이름으로 저장', '저장', '파일 열기', '파일 선택', '업로드할 파일 선택', 'Open', 'Save As', 'Save')
  $t = Arg 'title'; $end = (Get-Date).AddSeconds([double](Arg 'timeoutSec' 10)); $w = $null
  while (-not $w -and (Get-Date) -lt $end) {
    $all = [AsideBridge.Native]::Windows()
    $w = if ($t) { $all | Where-Object Title -like "*$t*" | Select-Object -First 1 } else { $all | Where-Object { $names -contains $_.Title } | Select-Object -First 1 }
    if (-not $w) { Start-Sleep -Milliseconds 400 }
  }
  if (-not $w) { throw 'file dialog not found' }
  $root = Get-ABUiaRoot $null ([long]$w.Handle)
  $edit = $null; try { $edit = Find-ABUia $root $null 'Edit' '1148' 0 } catch {}
  if (-not $edit) { try { $edit = Find-ABUia $root $null $null '1148' 0 } catch {} }
  if (-not $edit) { throw 'file name box not found' }
  $filled = $false
  try { [void](Invoke-ABUiaAction $edit 'setvalue' $path); $filled = $true } catch {}
  if (-not $filled) {
    [void][AsideBridge.Native]::Focus($w.Handle); try { [void](Invoke-ABUiaAction $edit 'focus' $null) } catch {}
    $prev = Get-Clipboard -Raw -ErrorAction SilentlyContinue; Set-Clipboard -Value $path; Start-Sleep -Milliseconds 120
    [AsideBridge.Native]::Keys('ctrl+a'); [AsideBridge.Native]::Keys('ctrl+v'); AB-MarkSelf; Start-Sleep -Milliseconds 250
    if ($prev) { Set-Clipboard -Value $prev }
  }
  Start-Sleep -Milliseconds 200
  if (Arg 'noconfirm' $false) { return "filled $path (not confirmed)" }
  try { $btn = Find-ABUia $root $null $null '1' 0; [void](Invoke-ABUiaAction $btn 'invoke' $null) } catch {}
  Start-Sleep -Milliseconds 900
  if ([AsideBridge.Native]::Windows() | Where-Object Handle -eq $w.Handle) {
    AB-Guard; [void][AsideBridge.Native]::Focus($w.Handle); try { [void](Invoke-ABUiaAction $edit 'focus' $null) } catch {}
    [AsideBridge.Native]::Keys('enter'); AB-MarkSelf; Start-Sleep -Milliseconds 900
  }
  $still = [AsideBridge.Native]::Windows() | Where-Object Handle -eq $w.Handle
  [pscustomobject]@{ dialog = $w.Title; path = $path; closed = (-not $still) }
}
function AB-clicktext {
  # OCR the window (or the whole screen), click the best fuzzy match of --find
  $find = [string](Arg 'find'); if (-not $find) { throw 'need the text to click' }
  $title = Arg 'window'
  AB-Guard
  $p = Join-Path $ABBase "work\clicktext-$($job.id).png"
  if ($title) { $win = AB-FindWin $title $null; if (-not $win) { throw 'window not found' }
    [void][AsideBridge.Native]::Focus($win.Handle); $rect = [AsideBridge.Native]::Screenshot($p, $win.X, $win.Y, $win.W, $win.H) }
  else { $rect = [AsideBridge.Native]::Screenshot($p, 0, 0, 0, 0) }
  $rp = $rect.Split(','); $ocr = Invoke-ABOcr $p (AB-Lang) ([int]$rp[0]) ([int]$rp[1]); Remove-Item $p -ErrorAction SilentlyContinue
  $hit = @($ocr.lines) | Where-Object { AB-Fuzzy $_.text $find } | Select-Object -First 1
  if (-not $hit) { throw "NOT_FOUND: '$find' was not found by OCR" }
  AB-Step 'before'
  [AsideBridge.Native]::Click([int]$hit.x, [int]$hit.y, 'left', 1); AB-MarkSelf; Start-Sleep -Milliseconds 250; AB-Step 'after'
  [pscustomobject]@{ clicked = $true; text = $hit.text; x = $hit.x; y = $hit.y }
}
function AB-sysinfo {
  $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
  $pw = { param($sub, $set) $o = powercfg /qh SCHEME_CURRENT $sub $set | Out-String; $m = [regex]::Matches($o, '(AC|DC)[^:\r\n]*:\s*(0x[0-9a-fA-F]+)'); $h = [ordered]@{}; foreach ($x in $m) { $h[$x.Groups[1].Value] = [Convert]::ToInt32($x.Groups[2].Value, 16) }; $h }
  $wl = (netsh wlan show interfaces) -join "`n"
  $ssid = if ($wl -match '(?m)^\s*SSID\s*:\s*(.+)$') { $matches[1].Trim() } else { $null }
  $sig = if ($wl -match '(?m)^\s*(신호|Signal)\s*:\s*(.+)$') { $matches[2].Trim() } else { $null }
  $os = Get-CimInstance Win32_OperatingSystem
  # optional services to report (settings.json "sysinfoServices"); a service that is not installed reports $null instead of failing
  $svc = [ordered]@{}
  foreach ($n in @((AB-Cfg).sysinfoServices)) { if ($n) { $sv = Get-Service -Name $n -ErrorAction SilentlyContinue; $svc[[string]$n] = if ($sv) { [string]$sv.Status } else { $null } } }
  [pscustomobject][ordered]@{
    batteryPercent = if ($bat) { $bat.EstimatedChargeRemaining } else { $null }
    onAC = if ($bat) { $bat.BatteryStatus -eq 2 -or $bat.BatteryStatus -ge 6 } else { $true }
    sleepSec = & $pw 'SUB_SLEEP' 'STANDBYIDLE'; lidAction = & $pw 'SUB_BUTTONS' 'LIDACTION'; powerButton = & $pw 'SUB_BUTTONS' 'PBUTTONACTION'
    wifi = $ssid; signal = $sig; internet = (Test-Connection 8.8.8.8 -Count 1 -Quiet -ErrorAction SilentlyContinue)
    uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    idleSec = [math]::Round([AsideBridge.Native2]::IdleSeconds(), 1); inputDesktop = [AsideBridge.Native]::InputDesktopAvailable()
    diskFreeGB = $(try { [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 0) } catch { $null })
    autoLogon = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue).AutoAdminLogon
    services = $svc
  }
}
function AB-seq {
  $steps = @(Arg 'steps' @()); $res = @(); $i = 0
  foreach ($st in $steps) {
    $i++
    if ($st.kind -eq 'sleep') { Start-Sleep -Milliseconds ([int]$st.args.ms); $res += [pscustomobject]@{ step = $i; kind = 'sleep'; ok = $true }; continue }
    $sid = "$($job.id)-s$i"; $sj = Join-Path $ABBase "work\$sid.job.json"; $so = Join-Path $ABBase "work\$sid.out.json"
    $argsObj = if ($st.args) { $st.args } else { @{} }
    if (Arg 'force' $false) { $argsObj | Add-Member -NotePropertyName force -NotePropertyValue $true -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($sj, ([pscustomobject]@{ id = $sid; kind = $st.kind; script = $st.script; args = $argsObj } | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
    & (Join-Path $ABApp 'runner.ps1') -JobFile $sj -OutFile $so
    $r = Get-Content -Raw -Encoding UTF8 $so | ConvertFrom-Json; Remove-Item $sj, $so -ErrorAction SilentlyContinue
    $o = [string]$r.stdout; if ($o.Length -gt 400) { $o = $o.Substring(0, 400) + '...' }
    $res += [pscustomobject]@{ step = $i; kind = $st.kind; ok = $r.ok; out = $o; err = ([string]$r.stderr).Split("`n")[0] }
    if (-not $r.ok -and -not $st.optional) {
      $p = Join-Path $ABBase "work\seqfail-$($job.id).png"; try { [void][AsideBridge.Native]::Screenshot($p, 0, 0, 0, 0) } catch {}
      throw ("SEQ_FAILED at step $i ($($st.kind)): " + ([string]$r.stderr).Split("`n")[0] + " | screen: $p | done: " + (($res | ForEach-Object { "$($_.step):$($_.ok)" }) -join ' '))
    }
  }
  $res
}
# ---------- clipboard, wait, run, registry, window management ----------
function AB-clip {
      switch (Arg 'op' 'get') {
        'get'   { Get-Clipboard -Raw }
        'set'   { Set-Clipboard -Value ([string](Arg 'text')); "clip set $(([string](Arg 'text')).Length) chars" }
        'paste' {
          AB-Guard; AB-Step 'before'
          $prev = Get-Clipboard -Raw -ErrorAction SilentlyContinue
          Set-Clipboard -Value ([string](Arg 'text')); Start-Sleep -Milliseconds 120
          [AsideBridge.Native]::Keys('ctrl+v'); AB-MarkSelf; Start-Sleep -Milliseconds 250; AB-Step 'after'
          if (Arg 'restore' $true) { if ($prev) { Set-Clipboard -Value $prev } }
          "pasted $(([string](Arg 'text')).Length) chars"
        }
        default { throw 'unknown clip op' }
      }
    }
function AB-wait {
      $limit = [double](Arg 'timeoutSec' 20); $iv = [int](Arg 'intervalMs' 700); $gone = [bool](Arg 'gone' $false)
      $title = Arg 'window'; $text = Arg 'text'; $end = (Get-Date).AddSeconds($limit); $hit = $null; $n = 0
      while ((Get-Date) -lt $end) {
        $n++
        $wins = [AsideBridge.Native]::Windows()
        $win = if ($title) { $wins | Where-Object Title -like "*$title*" | Select-Object -First 1 } else { $null }
        if ($text) {
          if (-not $title -or $win) {
            $x = [int](Arg 'x' 0); $y = [int](Arg 'y' 0); $w = [int](Arg 'w' 0); $h = [int](Arg 'h' 0)
            $p = Join-Path $ABBase "work\wait-$($job.id).png"
            if ($win) { $rect = [AsideBridge.Native2]::CaptureWindow($win.Handle, $p) } else { $rect = [AsideBridge.Native]::Screenshot($p, $x, $y, $w, $h) }; $rp = $rect.Split(',')
            $ocr = Invoke-ABOcr $p (AB-Lang) ([int]$rp[0]) ([int]$rp[1]); Remove-Item $p -ErrorAction SilentlyContinue
            $hit = @($ocr.lines) | Where-Object { AB-Fuzzy $_.text $text } | Select-Object -First 1
            $found = [bool]$hit
          } else { $found = $false }
        } else { $found = [bool]$win; $hit = $win }
        if ($found -ne $gone) { return [pscustomobject]@{ ok = $true; tries = $n; match = $hit } }
        Start-Sleep -Milliseconds $iv
      }
      throw "wait timeout after $limit s (tries=$n)"
    }
function AB-run {
      $name = Arg 'name'; $path = Arg 'path'; $argl = [string](Arg 'argv' ''); $cwd = Arg 'cwd'
      if ($name) {
        $app = Get-StartApps | Where-Object Name -like "*$name*" | Select-Object -First 1
        if (-not $app) { throw "start menu app not found: $name" }
        Start-Process explorer.exe "shell:AppsFolder\$($app.AppID)"; return "launched (normal user) $($app.Name) [$($app.AppID)]"
      }
      if (-not $path) { throw 'need --name or path' }
      if (Arg 'elevated' $false) {
        $sp = @{ FilePath = $path; PassThru = $true }; if ($argl) { $sp.ArgumentList = $argl }; if ($cwd) { $sp.WorkingDirectory = $cwd }
        $pr = Start-Process @sp; return "launched (admin) pid=$($pr.Id)"
      }
      $tn = "AB-run-$($job.id)"
      $act = if ($argl) { New-ScheduledTaskAction -Execute $path -Argument $argl } else { New-ScheduledTaskAction -Execute $path }
      if ($cwd) { $act.WorkingDirectory = $cwd }
      $pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
      Register-ScheduledTask -TaskName $tn -Action $act -Principal $pri -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0) -Force | Out-Null
      Start-ScheduledTask -TaskName $tn; Start-Sleep -Milliseconds 1500
      Unregister-ScheduledTask -TaskName $tn -Confirm:$false
      "launched (normal user) $path"
    }
function AB-reg {
      $rp = [string](Arg 'path'); $rn = [string](Arg 'name'); $op = Arg 'op' 'get'
      $secret = $rn -match 'pass|pwd|secret|token'
      if ($op -eq 'set') {
        if (-not (Test-Path $rp)) { New-Item -Path $rp -Force | Out-Null }
        $val = [string](Arg 'value' ''); $ty = Arg 'type' 'String'
        $v2 = if ($ty -in 'DWord','QWord') { [long]$val } else { $val }
        New-ItemProperty -Path $rp -Name $rn -Value $v2 -PropertyType $ty -Force | Out-Null
        $back = (Get-ItemProperty -Path $rp -Name $rn).$rn
        if ([string]$back -ne [string]$v2) { throw "VERIFY FAILED: wrote '$v2' read '$back'" }
        return [pscustomobject]@{ path = $rp; name = $rn; type = $ty; verified = $true; value = $(if ($secret) { "(hidden, len=$(([string]$back).Length))" } else { $back }) }
      }
      if ($op -eq 'del') { Remove-ItemProperty -Path $rp -Name $rn -ErrorAction Stop; if ((Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue).PSObject.Properties[$rn]) { throw 'VERIFY FAILED: still exists' }; return "deleted $rp\$rn (verified)" }
      $v = (Get-ItemProperty -Path $rp -Name $rn -ErrorAction Stop).$rn
      [pscustomobject]@{ path = $rp; name = $rn; value = $(if ($secret) { "(hidden, len=$(([string]$v).Length))" } else { $v }) }
    }
function AB-win {
      if (-not ('AB.W' -as [type])) { Add-Type -Namespace AB -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);' }
      $w = if (Arg 'handle') { [AsideBridge.Native]::Windows() | Where-Object Handle -eq ([long](Arg 'handle')) } else { [AsideBridge.Native]::Windows() | Where-Object Title -like "*$(Arg 'title')*" | Select-Object -First 1 }
      if (-not $w) { throw 'window not found' }; $h = [IntPtr]$w.Handle
      switch (Arg 'op') {
        'move'    { [AB.W]::ShowWindow($h, 9) | Out-Null; [AB.W]::SetWindowPos($h, [IntPtr]::Zero, [int](Arg 'x' $w.X), [int](Arg 'y' $w.Y), [int](Arg 'w' $w.W), [int](Arg 'h' $w.H), 0x0044) | Out-Null }
        'min'     { [AB.W]::ShowWindow($h, 6) | Out-Null }
        'max'     { [AB.W]::ShowWindow($h, 3) | Out-Null }
        'restore' { [AB.W]::ShowWindow($h, 9) | Out-Null }
        'close'   { [AB.W]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
        'top'     { [AB.W]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null }
        'notop'   { [AB.W]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x0003) | Out-Null }
        default   { throw 'unknown win op' }
      }
      Start-Sleep -Milliseconds 200
      [AsideBridge.Native]::Windows() | Where-Object Handle -eq $w.Handle
    }

try {
  $out = switch ($job.kind) {
    'ping' { 'pong' }
    'ps' {
      $sb = [ScriptBlock]::Create([string]$job.script)
      (& $sb 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $result.stderr += "$_`n" } else { $_ } } | Out-String -Width 4096)
    }
    'cmd' {
      $p = Start-Process cmd.exe -ArgumentList '/d', '/s', '/c', "`"$($job.script)`"" -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput "$OutFile.o" -RedirectStandardError "$OutFile.e"
      $result.stderr += (Get-Content -Raw "$OutFile.e" -ErrorAction SilentlyContinue)
      $o = Get-Content -Raw "$OutFile.o" -ErrorAction SilentlyContinue; Remove-Item "$OutFile.o", "$OutFile.e" -ErrorAction SilentlyContinue
      if ($p.ExitCode -ne 0) { $result.exitCode = $p.ExitCode; throw "cmd exit $($p.ExitCode)" }; $o
    }
    'input' {
      $act = Arg 'action'
      AB-Guard; AB-Step 'before'
      $r = switch ($act) {
        'type'   { "typed $([AsideBridge.Native]::TypeText([string](Arg 'text'), [int](Arg 'delayMs' 5)))" }
        'keys'   { [AsideBridge.Native]::Keys([string](Arg 'keys')); "keys $(Arg 'keys')" }
        'move'   { [AsideBridge.Native]::Move([int](Arg 'x'), [int](Arg 'y')); 'moved' }
        'click'  { [AsideBridge.Native]::Click([int](Arg 'x'), [int](Arg 'y'), 'left', 1); 'click' }
        'dclick' { [AsideBridge.Native]::Click([int](Arg 'x'), [int](Arg 'y'), 'left', 2); 'dclick' }
        'rclick' { [AsideBridge.Native]::Click([int](Arg 'x'), [int](Arg 'y'), 'right', 1); 'rclick' }
        'drag'   { [AsideBridge.Native]::Drag([int](Arg 'x'), [int](Arg 'y'), [int](Arg 'x2'), [int](Arg 'y2')); 'drag' }
        'scroll' { [AsideBridge.Native]::Scroll([int](Arg 'x' 0), [int](Arg 'y' 0), [int](Arg 'lines' -3), [int](Arg 'hlines' 0)); 'scroll' }
        default  { throw "unknown input action: $act" }
      }
      AB-MarkSelf; Start-Sleep -Milliseconds 250; AB-Step 'after'; $r
    }
    'windows' { [AsideBridge.Native]::Windows() | Sort-Object Title }
    'focus' {
      $w = if (Arg 'handle') { [AsideBridge.Native]::Windows() | Where-Object Handle -eq ([long](Arg 'handle')) } else { [AsideBridge.Native]::Windows() | Where-Object Title -like "*$(Arg 'title')*" | Select-Object -First 1 }
      if (-not $w) { throw 'window not found' }; "focused=$([AsideBridge.Native]::Focus($w.Handle)) $($w.Title)"
    }
    'shot' {
      $path = Arg 'path' (Join-Path $ABBase "work\shot-$($job.id).png")
      $x = [int](Arg 'x' 0); $y = [int](Arg 'y' 0); $w = [int](Arg 'w' 0); $h = [int](Arg 'h' 0)
      if (Arg 'window') { $win = [AsideBridge.Native]::Windows() | Where-Object Title -like "*$(Arg 'window')*" | Select-Object -First 1
        if (-not $win) { throw 'window not found' }; if ($win.Affinity -ne 0) { $result.stderr += "warning: window has display affinity $($win.Affinity) (capture-protected, will be black)`n" }
        $x = $win.X; $y = $win.Y; $w = $win.W; $h = $win.H }
      $rect = [AsideBridge.Native]::Screenshot($path, $x, $y, $w, $h)
      $d = [ordered]@{ path = $path; rect = $rect }
      if (Arg 'ocr' $false) { $p = $rect.Split(','); $d.ocr = Invoke-ABOcr $path (AB-Lang) ([int]$p[0]) ([int]$p[1]) }
      [pscustomobject]$d
    }
    'ocr' { Invoke-ABOcr (Arg 'path') (AB-Lang) ([int](Arg 'offX' 0)) ([int](Arg 'offY' 0)) }
    'uia' {
      $root = Get-ABUiaRoot (Arg 'window') ([long](Arg 'handle' 0))
      switch (Arg 'op' 'tree') {
        'tree'   { Get-ABUiaTree $root ([int](Arg 'depth' 6)) ([int](Arg 'max' 800)) }
        'find'   { ConvertTo-ABUiaInfo (Find-ABUia $root (Arg 'name') (Arg 'type') (Arg 'id') ([int](Arg 'index' 0))) }
        'action' { Invoke-ABUiaAction (Find-ABUia $root (Arg 'name') (Arg 'type') (Arg 'id') ([int](Arg 'index' 0))) (Arg 'action') (Arg 'value') }
        'windows'{ Get-ABUiaTree $root 1 200 }
        default  { throw 'unknown uia op' }
      }
    }
    'clip' { AB-clip }
    'seq' { AB-seq }
    'shotbg' { AB-shotbg }
    'watch' { AB-watch }
    'filedlg' { AB-filedlg }
    'sysinfo' { AB-sysinfo }
    'wait' { AB-wait }
    'run' { AB-run }
    'reg' { AB-reg }
    'win' { AB-win }
    'cdp' { Invoke-ABCdp }
    'clicktext' { AB-clicktext }
    'idle' { [pscustomobject]@{ idleSec = [math]::Round([AsideBridge.Native2]::IdleSeconds(), 2); inputDesktop = [AsideBridge.Native]::InputDesktopAvailable() } }
    'front' { $fh = [AsideBridge.Native2]::Foreground(); $fw = [AsideBridge.Native]::Windows() | Where-Object Handle -eq $fh | Select-Object -First 1
      if ($fw) { $fw } else { [pscustomobject]@{ Handle = $fh; Title = $null } } }
    'notify' { AB-Toast ([string](Arg 'title' 'AsideBridge')) ([string](Arg 'text' '')); 'notified' }
    default { throw "unknown kind: $($job.kind)" }
  }
  if ($out -is [string]) { $result.stdout = $out } else { $result.data = $out; $result.stdout = ($out | ConvertTo-Json -Depth 8 -Compress) }
  $result.ok = $true; $result.exitCode = 0
} catch {
  $result.stderr += ($_ | Out-String)
}
$result.finishedAt = (Get-Date).ToString('o'); $result.durationMs = [int]((Get-Date) - $started).TotalMilliseconds
$json = [pscustomobject]$result | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText("$OutFile.tmp", $json, (New-Object Text.UTF8Encoding $false))
Move-Item -Force "$OutFile.tmp" $OutFile
