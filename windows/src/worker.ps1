# AsideBridge for Windows - warm worker. Loads the native helpers once, then runs jobs handed over by bridge.ps1
# through <Dir>\job.json (+ <Dir>\out.txt = result path). Exits when the parent bridge process is gone.
param([Parameter(Mandatory)][string]$Dir)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
Initialize-ABUia
New-Item -ItemType Directory -Force $Dir | Out-Null
$jf = Join-Path $Dir 'job.json'; $of = Join-Path $Dir 'out.txt'
Set-Content (Join-Path $Dir 'ready') $PID
$runner = Join-Path $PSScriptRoot 'runner.ps1'
$parent = [int](Get-Content (Join-Path $Dir 'parent') -ErrorAction SilentlyContinue)
$tick = 0
while ($true) {
  if ((Test-Path $jf) -and (Test-Path $of)) {
    $out = (Get-Content -Raw $of).Trim()
    try { & $runner -JobFile $jf -OutFile $out } catch { }
    Remove-Item $jf, $of -Force -ErrorAction SilentlyContinue
    [GC]::Collect()
  } else { Start-Sleep -Milliseconds 15 }
  if ((++$tick % 400) -eq 0 -and $parent -and -not (Get-Process -Id $parent -ErrorAction SilentlyContinue)) { exit 0 }
}
