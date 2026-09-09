[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-capture-privacy-'+[guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }
$process=$null
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $config=Get-Content (Join-Path $repository 'robot\ident-rpa\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $config.ident.processName='ident-absent-fixture-'+[guid]::NewGuid().ToString('N')
    $config.ident.windowTitleRegex='^IDENT privacy fixture$'
    $config.backend.baseUrl='http://127.0.0.1:1'
    $config.backend.serviceApiKey='fixture'
    $config.logDir=Join-Path $temp 'logs'
    $config.inspect.outputPath=Join-Path $temp 'ui-tree.json'
    $config.calibration.reportPath=Join-Path $temp 'report.json'
    $path=Join-Path $temp 'config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content $path -Encoding UTF8
    $before=(Get-FileHash $path).Hash
    $scriptPath=Join-Path $repository 'robot\ident-rpa\Start-IdentRobot.ps1'
    foreach ($mode in @('Calibrate','Inspect','Verify','Observe')) {
        $process=Start-Process powershell.exe -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $temp "$mode-output.log") -RedirectStandardError (Join-Path $temp "$mode-error.log") `
            -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode $mode -ConfigPath `"$path`" -ReportPath `"$temp\report.json`" -CaptureId privacy -ObservedWindowHandle 101 -ObservedProcessId 102"
        $null=$process.Handle
        if (-not $process.WaitForExit(15000)) { throw "Privacy fixture timed out: $mode" }
        if ($process.ExitCode -eq 0) { throw "Missing IDENT must not report success: $mode" }
        $process.Dispose(); $process=$null
        if (@(Get-ChildItem -LiteralPath $temp -Filter '*.png' -Recurse).Count -ne 0) { throw "Read-only $mode saved a screenshot." }
        if ((Get-FileHash $path).Hash -ne $before) { throw 'Capture mode changed the active profile.' }
    }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Save-FailureScreenshot'},$true)
    Set-Item Function:Save-FailureScreenshot $node.Body.GetScriptBlock()
    if ((Save-FailureScreenshot $config $null) -ne '') { throw 'Missing IDENT must not fall back to desktop capture.' }
    if (@(Get-ChildItem -LiteralPath $temp -Filter '*.png' -Recurse).Count -ne 0) { throw 'Whole desktop screenshot was created.' }
    $branch=$ast.Find({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$Mode -eq ''Calibrate'''},$true)
    if ($null -eq $branch) { throw 'Calibration entry point not found.' }
    $script:ScreenshotCalls=0
    function Save-FailureScreenshot { $script:ScreenshotCalls++; return 'forbidden.png' }
    function Invoke-AutomaticCalibration { return [pscustomobject]@{ok=$false;issues=@('Fixture incomplete form')} }
    function Write-RobotLog { }
    $Mode='Calibrate'; $windowInfo=[pscustomobject]@{process='fixture'}
    $ReportPath=Join-Path $temp 'incomplete.json'; $ConfigPath=$path; $CaptureId='incomplete'
    $rejected=$false
    try { & ([scriptblock]::Create($branch.Extent.Text)) } catch { $rejected=$true }
    if (-not $rejected -or $script:ScreenshotCalls -ne 0) { throw 'Incomplete calibration captured a screenshot or reported success.' }
    Write-Host 'IDENT CAPTURE PRIVACY OK: read-only errors produce no screenshots; missing IDENT never captures the desktop; active profile unchanged.'
}
finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
