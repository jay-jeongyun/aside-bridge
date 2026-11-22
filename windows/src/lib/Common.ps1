# Shared helpers for AsideBridge for Windows (Windows PowerShell 5.1; native on x64 and ARM64).
# Layout: code lives in <home>\app (this file is <home>\app\lib\Common.ps1), data in <home>.
# <home> = $env:ASIDEBRIDGE_HOME, or the parent of the app folder (default %LOCALAPPDATA%\aside-bridge).
$ErrorActionPreference = 'Stop'
$Global:ABApp = Split-Path -Parent $PSScriptRoot
$Global:ABBase = if ($env:ASIDEBRIDGE_HOME) { $env:ASIDEBRIDGE_HOME } else { Split-Path -Parent $Global:ABApp }
if (-not ('AsideBridge.Native' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Native.cs') -ReferencedAssemblies System.Drawing }
if (-not ('AsideBridge.Native2' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Native2.cs') -ReferencedAssemblies System.Drawing }

[AsideBridge.Native]::InitDpi()   # all coordinates = physical pixels (UIA, capture and input agree)

# ---------- OCR (Windows.Media.Ocr, built in; OCR languages come from installed Windows language packs) ----------
function Invoke-ABAwait($op, [Type]$resultType) {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $m = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  $t = $m.MakeGenericMethod($resultType).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result
}
# $Lang: BCP-47 tag such as 'en-US' or 'ko'. Empty = the user's profile languages.
function Invoke-ABOcr([string]$Path, [string]$Lang = '', [int]$OffX = 0, [int]$OffY = 0) {
  $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
  $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
  $null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
  $full = (Resolve-Path $Path).Path
  $file = Invoke-ABAwait ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
  $stream = Invoke-ABAwait ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $dec = Invoke-ABAwait ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bmp = Invoke-ABAwait ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $engine = $null
  if ($Lang) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($Lang)) }
  if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
  if (-not $engine) { throw "No OCR engine for '$Lang'. Add the language in Settings > Time & language > Language & region." }
  $res = Invoke-ABAwait ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
  $stream.Dispose()
  $lines = foreach ($l in $res.Lines) {
    $ws = @($l.Words); $x1 = ($ws | ForEach-Object { $_.BoundingRect.X } | Measure-Object -Minimum).Minimum
    $y1 = ($ws | ForEach-Object { $_.BoundingRect.Y } | Measure-Object -Minimum).Minimum
    $x2 = ($ws | ForEach-Object { $_.BoundingRect.X + $_.BoundingRect.Width } | Measure-Object -Maximum).Maximum
    $y2 = ($ws | ForEach-Object { $_.BoundingRect.Y + $_.BoundingRect.Height } | Measure-Object -Maximum).Maximum
    [pscustomobject]@{ text = $l.Text; x = [int]($OffX + ($x1 + $x2) / 2); y = [int]($OffY + ($y1 + $y2) / 2) }
  }
  [pscustomobject]@{ language = $engine.RecognizerLanguage.LanguageTag; text = $res.Text; lines = @($lines) }
}

# ---------- UI Automation ----------
function Initialize-ABUia { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes }
function Get-ABUiaRoot([string]$WindowTitle, [long]$Handle) {
  Initialize-ABUia
  if ($Handle) { return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Handle) }
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  if (-not $WindowTitle) { return $root }
  $wins = $root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($w in $wins) { if ($w.Current.Name -like "*$WindowTitle*") { return $w } }
  throw "window not found: $WindowTitle"
}
function ConvertTo-ABUiaInfo($e, [int]$depth = 0) {
  $c = $e.Current; $r = $c.BoundingRectangle
  $o = [ordered]@{ name = $c.Name; type = $c.ControlType.ProgrammaticName -replace 'ControlType\.', ''; id = $c.AutomationId; cls = $c.ClassName;
    x = if ($r.IsEmpty) { $null } else { [int]($r.X + $r.Width / 2) }; y = if ($r.IsEmpty) { $null } else { [int]($r.Y + $r.Height / 2) };
    enabled = $c.IsEnabled; depth = $depth }
  try { $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $o.value = $vp.Current.Value } catch {}
  [pscustomobject]$o
}
function Get-ABUiaTree($root, [int]$MaxDepth = 6, [int]$Max = 800) {
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker; $out = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack; $stack.Push(@($root, 0))
  while ($stack.Count -gt 0 -and $out.Count -lt $Max) {
    $item = $stack.Pop(); $e = $item[0]; $d = $item[1]
    try { [void]$out.Add((ConvertTo-ABUiaInfo $e $d)) } catch { continue }
    if ($d -ge $MaxDepth) { continue }
    $kids = @(); $ch = $walker.GetFirstChild($e); while ($ch) { $kids += $ch; $ch = $walker.GetNextSibling($ch) }
    for ($i = $kids.Count - 1; $i -ge 0; $i--) { $stack.Push(@($kids[$i], $d + 1)) }
  }
  $out
}
function Find-ABUia($root, [string]$Name, [string]$Type, [string]$AutomationId, [int]$Index = 0) {
  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
  $hits = foreach ($e in $all) {
    $c = $e.Current
    if ($Name -and $c.Name -notlike $Name) { continue }
    if ($Type -and ($c.ControlType.ProgrammaticName -replace 'ControlType\.', '') -ne $Type) { continue }
    if ($AutomationId -and $c.AutomationId -ne $AutomationId) { continue }
    $e
  }
  $hits = @($hits); if ($hits.Count -le $Index) { throw "element not found (name=$Name type=$Type id=$AutomationId)" }
  $hits[$Index]
}
function Invoke-ABUiaAction($e, [string]$Action, [string]$Value) {
  switch ($Action) {
    'invoke'   { $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); 'invoked' }
    'setvalue' { $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Value); 'set' }
    'focus'    { $e.SetFocus(); 'focused' }
    'toggle'   { $e.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle(); 'toggled' }
    'select'   { $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); 'selected' }
    'expand'   { $e.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand(); 'expanded' }
    'text'     { try { $e.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1) } catch { $e.Current.Name } }
    'click'    { $r = $e.Current.BoundingRectangle; [AsideBridge.Native]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2), 'left', 1); 'clicked' }
    default    { ConvertTo-ABUiaInfo $e }
  }
}
