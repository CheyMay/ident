param([string]$Mode, [string]$ConfigPath, [string]$ReportPath, [string]$CaptureId, [long]$ObservedWindowHandle, [int]$ObservedProcessId, [string]$ObservedSurface = 'window')
$ErrorActionPreference = 'Stop'
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($config.behavior -eq 'hang') { Start-Sleep -Seconds 120; exit }
if ($config.behavior -eq 'fail') { exit 3 }
if ($config.behavior -eq 'stale') { $CaptureId = 'old-attempt' }
if ($config.behavior -eq 'wrong-window') { $ObservedWindowHandle++ }
if ($Mode -ne 'Observe' -or $ObservedWindowHandle -eq 0 -or $ObservedProcessId -le 0) { exit 4 }
$directory = Split-Path -Parent $ReportPath
$path = Join-Path $directory ('ui-tree-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
$rows = @(0..7 | ForEach-Object {
    [pscustomobject]@{ rootName='Test appointment'; name="Fixture $_"; patterns=@('ValuePatternIdentifiers.Pattern'); path="0/$_" }
})
ConvertTo-Json -InputObject $rows -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
@{
    ok=$true; captureId=$CaptureId; generatedAt=[DateTimeOffset]::Now.ToString('o'); scanSchemaVersion=2
    mode='observation'; observedWindowHandle=$ObservedWindowHandle; observedProcessId=$ObservedProcessId
    capturePath=$path; captureSha256=(Get-FileHash $path).Hash; captureBytes=(Get-Item $path).Length
    controlsScanned=8; visibleControls=8; splitNameFieldsDetected=$true; selectorsComplete=$false
    readyForUnattendedExecution=$false; checks=@(); issues=@('Fixture only')
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
'MUST-NOT-EXPORT' | Set-Content -LiteralPath (Join-Path $directory 'config.local.json')
'MUST-NOT-EXPORT' | Set-Content -LiteralPath (Join-Path $directory 'secrets.local.json')
