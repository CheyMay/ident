param($Mode,$ConfigPath,$TaskFile,$ReportPath,$CaptureId,[switch]$Execute,[switch]$ObserveChanges)
$ErrorActionPreference='Stop'
$runDirectory=Split-Path -Parent $ReportPath
$deadline=[datetime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath (Join-Path $runDirectory 'armed'))) {
    if ([datetime]::UtcNow -gt $deadline) { exit 8 }
    Start-Sleep -Milliseconds 100
}
Set-Content -LiteralPath (Join-Path $runDirectory 'fixture-pid.txt') -Value $PID -Encoding ASCII
if ((Get-Content -LiteralPath $TaskFile -Raw).Trim() -eq 'hang') {
    @{ stage='write_intent'; runId=$CaptureId } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path -Parent $ConfigPath) 'fill-check-pending.json') -Encoding UTF8
    Start-Sleep -Seconds 60
    exit 9
}
@{ Ok=$true; State=$(if($ObserveChanges){'no_change'}else{'preview'}); ErrorCode='' } | ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding UTF8
