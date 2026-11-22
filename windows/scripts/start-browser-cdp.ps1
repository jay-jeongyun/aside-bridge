# Start Chrome / Edge / Whale with the DevTools protocol port so an agent can drive pages via `bridgectl cdp`.
# Chromium 136+ refuses --remote-debugging-port on the DEFAULT profile, so a dedicated profile folder is used
# (<home>\browser-profiles\<browser>; sign in there once if needed, it persists).
#   .\start-browser-cdp.ps1 chrome|edge|whale [-Port 9222] [-Url https://example.com]
# The port listens on 127.0.0.1 only, but any local process can then control that browser profile.
param([ValidateSet('chrome', 'edge', 'whale')][string]$Browser = 'chrome', [int]$Port = 0, [string]$Url = 'about:blank')
$Dir = if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME } else { Join-Path $env:LOCALAPPDATA 'aside-bridge' }
$paths = @{
  chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")
  edge   = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
  whale  = @("$env:ProgramFiles\Naver\Naver Whale\Application\whale.exe", "${env:ProgramFiles(x86)}\Naver\Naver Whale\Application\whale.exe", "$env:LOCALAPPDATA\Naver\Naver Whale\Application\whale.exe")
}
if (-not $Port) { $Port = @{ chrome = 9222; edge = 9223; whale = 9224 }[$Browser] }
$exe = $paths[$Browser] | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $exe) { throw "$Browser not found" }
$prof = Join-Path $Dir "browser-profiles\$Browser"; New-Item -ItemType Directory -Force $prof | Out-Null
Start-Process $exe -ArgumentList "--remote-debugging-port=$Port", "--remote-debugging-address=127.0.0.1", "--user-data-dir=`"$prof`"", '--no-first-run', $Url
Write-Host "$Browser started with CDP on 127.0.0.1:$Port (profile $prof). Test: python bridgectl.py cdp tabs --port $Port"
