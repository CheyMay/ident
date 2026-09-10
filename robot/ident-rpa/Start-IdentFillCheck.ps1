param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [Parameter(Mandatory=$true)][string]$TaskFile,
    [ValidateRange(15,180)][int]$TimeoutSeconds=180,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'RobotCapture.ps1')
. (Join-Path $PSScriptRoot 'IdentFillCheck.ps1')
$child=$null; $job=$null; $runDirectory=''; $directory=''
try {
    $ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
    $TaskFile=[IO.Path]::GetFullPath($TaskFile)
    foreach($path in @($ConfigPath,$TaskFile,$PSScriptRoot)) {
        if ($path -match '["\x00-\x1f]' -or -not (Test-Path -LiteralPath $path)) { throw 'Invalid path.' }
    }
    $directory=Split-Path -Parent $ConfigPath
    Assert-IdentFillCheckInstallation $directory -Execute:$Execute
    $runId=[guid]::NewGuid().ToString('N')
    $runDirectory=Join-Path $directory ('fill-checks\'+$runId)
    $null=New-Item -ItemType Directory -Path $runDirectory
    $resultPath=Join-Path $runDirectory 'result.json'
    Initialize-RobotCaptureJob
    $job=[IdentCaptureJob]::new()
    $arguments='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'Start-IdentRobot.ps1')+
        '" -Mode PatientFillCheck -ConfigPath "'+$ConfigPath+'" -TaskFile "'+$TaskFile+'" -ReportPath "'+$resultPath+'" -CaptureId '+$runId
    if ($Execute) { $arguments+=' -Execute' }
    $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runDirectory 'status.log') `
        -RedirectStandardError (Join-Path $runDirectory 'errors.log')
    $job.Attach($child)
    $child.PriorityClass=[Diagnostics.ProcessPriorityClass]::BelowNormal
    # Child cannot begin confirmation or UI work until its lifetime is bounded by this job.
    $null=New-Item -ItemType File -Path (Join-Path $runDirectory 'armed')
    Write-Host 'IDENT fill check: activate the expanded patient form within 8 seconds after confirmation. No automatic save.'
    $deadline=[datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $child.WaitForExit(250)) {
        if ([datetime]::UtcNow -ge $deadline) { throw 'FILL_TIMEOUT' }
    }
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'FILL_CHECK_FAILED' }
    $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('IDENT_FILL_CHECK '+$result.State+' '+$result.ErrorCode)
    Write-Host ('Report: '+$resultPath)
    if (-not $result.Ok -or $child.ExitCode -ne 0) { exit 1 }
} catch {
    # Do not forward provider stderr or request contents to logs or the backend.
    $code=if ($_.Exception.Message -in @('FILL_TIMEOUT','FILL_REVIEW_PENDING','FILL_ROBOT_ENABLED')) { $_.Exception.Message } else { 'FILL_CHECK_FAILED' }
    Write-Host ('IDENT_FILL_CHECK '+$code+'; no automatic retry. Inspect the form before another attempt.')
    exit 1
} finally {
    if ($null -ne $job) { $job.Dispose() }
    if ($null -ne $child) {
        if (-not $child.HasExited) { $child.Kill() }
        $null=$child.WaitForExit(5000)
        $child.Dispose()
    }
}
