param([string]$Mode,[string]$ConfigPath,[string]$TaskFile,[string]$ReportPath,[string]$CaptureId)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$directory=Split-Path -Parent $ReportPath
if ($Mode -notin @('CalendarCheck','CalendarOpenCheck') -or $CaptureId -notmatch '^[a-f0-9]{32}$') { exit 2 }
$deadline=[datetime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath (Join-Path $directory 'armed')) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
if (-not (Test-Path -LiteralPath (Join-Path $directory 'armed'))) { exit 2 }
$PID | Set-Content -LiteralPath (Join-Path $directory 'fixture-pid.txt') -Encoding ASCII
$request=Get-Content -LiteralPath $TaskFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($request.doctorCaption -ceq 'Hang Fixture') { Start-Sleep -Seconds 60; exit 3 }
$state=if ($Mode -eq 'CalendarOpenCheck') { 'opened_verified' } else { 'planned_read_only' }
@{ Ok=$true; State=$state; ErrorCode=''; ReadOnly=($Mode -eq 'CalendarCheck'); ActionsExecuted=0;
    SaveInvoked=$false; ReadyForInput=$false; ReadyForUnattendedExecution=$false } |
    ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8
