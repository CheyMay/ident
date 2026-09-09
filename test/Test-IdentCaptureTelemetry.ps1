[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-capture-telemetry-' + [guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }
. (Join-Path $repo 'robot\ident-rpa\RobotCapture.ps1')
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Import-Functions {
    param([string]$Path,[string[]]$Names)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in $Names) {
        $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        Set-Item "Function:global:$name" $node.Body.GetScriptBlock()
    }
}
function Write-FixtureStatus { param($Data) $Data | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $temp 'training-status.json') -Encoding UTF8 }
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    Import-Functions (Join-Path $repo 'agent\ident-db-agent\IdentWorker.ps1') @('Get-LiveCaptureTelemetry','Test-LiveCaptureHeartbeatDue','Send-Heartbeat')
    Import-Functions (Join-Path $repo 'agent\ident-db-agent\IdentDesktop.ps1') @('Update-CalibrationLiveStatus')
    $script:Context=[pscustomobject]@{RobotConfigPath=(Join-Path $temp 'config.json');Config=[pscustomobject]@{agent=[pscustomobject]@{id='telemetry-fixture';version='2.14.4'}}}
    $script:State=@{worker=@{startedAt='fixture';backendOnline=$false;lastHeartbeatAt='';lastError=''};schedule=@{};schema=@{};robot=@{enabled=$false};diagnostics=@{state='idle'}}
    $script:ApplyCalls=0; $script:Payload=$null; $script:RequestFails=$false
    function Apply-DesiredState {param($Desired) $script:ApplyCalls++}
    function Write-RuntimeState {}
    function Write-WorkerLog {param($Level,$EventName,$Data)}
    function Invoke-AgentRequest {
        param($Method,$Path,$Body)
        Assert-True ($Method -eq 'POST' -and $Path -eq '/api/agent/heartbeat') 'Unexpected remote operation.'
        $script:Payload=$Body
        if($script:RequestFails){throw 'Fixture network failure'}
        return @{desired=@{}}
    }
    Assert-True ((Read-RobotCaptureProgress $temp 'training').State -eq 'not_started') 'Missing file should not look active.'
    $p=New-RobotCaptureProgress $temp 'training'
    $p | Add-Member patientName 'MUST-NOT-LEAK'
    Assert-True (Write-RobotCaptureProgress $p -Force) 'Initial progress not written.'
    $initialTime=(Read-RobotCaptureProgress $temp 'training').UpdatedAt
    Assert-True (Write-RobotCaptureProgress $p) 'Throttled write failed.'
    Assert-True ((Read-RobotCaptureProgress $temp 'training').UpdatedAt -eq $initialTime) 'Progress writes were not throttled.'
    $lockedFile=[IO.File]::Open((Join-Path $temp 'training-status.json'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        Assert-True (-not (Write-RobotCaptureProgress $p -Force)) 'Locked status file was overwritten.'
        Send-Heartbeat -HeartbeatOnly
        Assert-True ($script:State.worker.backendOnline -and $script:Payload.diagnostics.trainingState -eq 'unavailable') 'Locked status file broke heartbeat.'
    } finally { $lockedFile.Dispose() }
    $script:LastHeartbeatAttempt=[DateTimeOffset]::Now.AddSeconds(-6)
    Assert-True (Test-LiveCaptureHeartbeatDue) 'Active training did not request fast heartbeat.'
    Send-Heartbeat -HeartbeatOnly
    Assert-True ($script:ApplyCalls -eq 0 -and $script:Payload.diagnostics.trainingState -eq 'waiting') 'Heartbeat-only applied configuration or lost progress.'
    Assert-True (-not (Test-LiveCaptureHeartbeatDue)) 'Heartbeat flooded after sending.'
    Assert-True (($script:Payload | ConvertTo-Json -Depth 8) -notmatch 'MUST-NOT-LEAK') 'Unexpected UI data leaked.'
    foreach($captureState in @('scanning','captured','failed','completed')) {
        $p.State=$captureState; $p.Attempt=1; $p.Hotkeys=2
        if($captureState -eq 'captured'){$p.Captured=1;$p.Controls=24}
        if($captureState -eq 'failed'){$p.ErrorCode='scan_timeout'}
        if($captureState -eq 'completed'){$p.ArchiveReady=$true;$p.ErrorCode=''}
        [void](Write-RobotCaptureProgress $p -Force)
        Send-Heartbeat -HeartbeatOnly
        Assert-True ($script:Payload.diagnostics.trainingState -eq $captureState) "State not transmitted: $captureState"
    }
    Assert-True ($script:Payload.diagnostics.trainingArchiveReady -and $script:Payload.diagnostics.trainingCaptured -eq 1) 'Archive progress lost.'
    Assert-True (-not $script:Payload.robot.enabled) 'Telemetry enabled the robot.'
    $data=Get-Content (Join-Path $temp 'training-status.json') -Raw | ConvertFrom-Json
    $data.state='waiting'; $data.updatedAt=[DateTimeOffset]::Now.AddSeconds(-40).ToString('o')
    Write-FixtureStatus $data
    Assert-True ((Read-RobotCaptureProgress $temp 'training').State -eq 'unresponsive') 'Old active status remained live.'
    $data.state='completed'; Write-FixtureStatus $data
    $script:LastHeartbeatAttempt=[DateTimeOffset]::Now.AddSeconds(-6)
    Assert-True (-not (Test-LiveCaptureHeartbeatDue)) 'Old completed session kept fast polling.'
    $data.updatedAt=[DateTimeOffset]::Now.ToString('o'); $data.errorCode='MUST-NOT-LEAK patient phone'; Write-FixtureStatus $data
    Assert-True ((Get-LiveCaptureTelemetry | ConvertTo-Json) -notmatch 'MUST-NOT-LEAK') 'Raw error text leaked into telemetry.'
    $data.state='MUST-NOT-LEAK'; Write-FixtureStatus $data
    Assert-True ((Read-RobotCaptureProgress $temp 'training').State -eq 'unavailable') 'Unexpected state was accepted.'
    $data.state='waiting'; $data.errorCode=''; $data.captured=10001; Write-FixtureStatus $data
    Assert-True ((Read-RobotCaptureProgress $temp 'training').State -eq 'unavailable') 'Oversized counter was accepted.'
    $data.captured=0; $data.updatedAt=[DateTimeOffset]::Now.AddHours(1).ToString('o'); Write-FixtureStatus $data
    Assert-True ((Read-RobotCaptureProgress $temp 'training').State -eq 'unavailable') 'Future status time was accepted.'
    foreach($invalid in @('{broken','{}',('x' * 20000))) {
        $invalid | Set-Content -LiteralPath (Join-Path $temp 'training-status.json') -Encoding UTF8
        Send-Heartbeat -HeartbeatOnly
        Assert-True ($script:State.worker.backendOnline -and $script:Payload.diagnostics.trainingState -eq 'unavailable') 'Damaged telemetry broke heartbeat.'
    }
    $p.State='waiting'; [void](Write-RobotCaptureProgress $p -Force)
    $script:RequestFails=$true; Send-Heartbeat -HeartbeatOnly
    Assert-True (-not (Test-LiveCaptureHeartbeatDue)) 'Failed network request caused immediate retries.'
    $script:RequestFails=$false; Send-Heartbeat
    Assert-True ($script:ApplyCalls -eq 1) 'Normal heartbeat lost desired-state handling.'
    $script:CalibrationProgress=New-RobotCaptureProgress $temp 'calibration'
    $script:CalibrationStage='scanning'; Update-CalibrationLiveStatus
    Assert-True ((Read-RobotCaptureProgress $temp 'calibration').Active) 'Calibration progress missing.'
    $script:CalibrationStage='ready'; Update-CalibrationLiveStatus
    $done=Read-RobotCaptureProgress $temp 'calibration'
    Update-CalibrationLiveStatus
    Assert-True ($done.State -eq 'completed' -and -not $done.Active -and (Read-RobotCaptureProgress $temp 'calibration').UpdatedAt -eq $done.UpdatedAt) 'Completed calibration remained active.'
    Write-Host 'IDENT CAPTURE TELEMETRY OK: safe heartbeat metadata, state transitions, stale detection, bounded polling, network failure, corrupt files, calibration lifecycle, no robot activation.'
}
finally {
    if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
