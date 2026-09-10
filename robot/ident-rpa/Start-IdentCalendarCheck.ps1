param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$DoctorCaption,
    [Parameter(Mandatory=$true)][string]$Start,
    [ValidateRange(15,360)][int]$DurationMinutes=30,
    [ValidateRange(15,120)][int]$TimeoutSeconds=120
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RobotCapture.ps1')
. (Join-Path $PSScriptRoot 'IdentFillCheck.ps1')
. (Join-Path $PSScriptRoot 'IdentCalendar.ps1')
$child=$null; $job=$null
try {
    $ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
    foreach($path in @($ConfigPath,$PSScriptRoot)) {
        if ($path -match '["\x00-\x1f]' -or -not (Test-Path -LiteralPath $path)) { throw 'CALENDAR_INVALID_REQUEST' }
    }
    try {
        $startTime=[DateTimeOffset]::ParseExact($Start,"yyyy-MM-dd'T'HH:mm:ssK",[Globalization.CultureInfo]::InvariantCulture)
        $request=[pscustomobject]@{ schemaVersion=1; purpose='ident-calendar-check'; doctorCaption=$DoctorCaption;
            planStart=$Start; planEnd=$startTime.AddMinutes($DurationMinutes).ToString('yyyy-MM-ddTHH:mm:sszzz') }
        $null=New-IdentCalendarRequest $request
    } catch { throw 'CALENDAR_INVALID_REQUEST' }
    $directory=Split-Path -Parent $ConfigPath
    Assert-IdentFillCheckInstallation $directory
    $runId=[guid]::NewGuid().ToString('N')
    $runDirectory=Join-Path $directory ('calendar-checks\'+$runId)
    $null=New-Item -ItemType Directory -Path $runDirectory
    $resultPath=Join-Path $runDirectory 'result.json'
    $requestPath=Join-Path $runDirectory 'request.json'
    $request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    Initialize-RobotCaptureJob
    $job=[IdentCaptureJob]::new()
    $arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Start-IdentRobot.ps1')+
        '" -Mode CalendarCheck -ConfigPath "'+$ConfigPath+'" -TaskFile "'+$requestPath+'" -ReportPath "'+$resultPath+'" -CaptureId '+$runId
    $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDirectory 'status.log') `
        -RedirectStandardError (Join-Path $runDirectory 'errors.log')
    $job.Attach($child)
    $child.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    $null=New-Item -ItemType File -Path (Join-Path $runDirectory 'armed')
    Write-Host 'READ ONLY: within 8 seconds activate the IDENT calendar on the requested date. Then leave mouse and keyboard untouched.'
    Write-Host 'No selection, split, patient input, save, or queue activation will be performed.'
    if (-not $child.WaitForExit($TimeoutSeconds*1000)) { throw 'CALENDAR_TIMEOUT' }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'CALENDAR_CHECK_FAILED' }
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('IDENT_CALENDAR_CHECK '+$result.State+' '+$result.ErrorCode)
    Write-Host ('Report: '+$resultPath)
    if (-not $result.Ok -or $child.ExitCode -ne 0) { exit 1 }
} catch {
    $code=if ($_.Exception.Message -in @('CALENDAR_TIMEOUT','CALENDAR_INVALID_REQUEST','FILL_ROBOT_ENABLED','FILL_REVIEW_PENDING')) {
        $_.Exception.Message
    } else { 'CALENDAR_CHECK_FAILED' }
    Write-Host ('IDENT_CALENDAR_CHECK '+$code+'; no automatic retry.')
    exit 1
} finally {
    if ($null -ne $job) { $job.Dispose() }
    if ($null -ne $child) {
        if (-not $child.HasExited) { $child.Kill() }
        $null=$child.WaitForExit(5000)
        $child.Dispose()
    }
}
