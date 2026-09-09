[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-training-test-' + [guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }
. (Join-Path $repo 'robot\ident-rpa\RobotSafety.ps1')
. (Join-Path $repo 'robot\ident-rpa\RobotCapture.ps1')
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Import-Functions {
    param([string]$Path,[string[]]$Names)
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in $Names) {
        $node=$ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name },$true)
        Set-Item "Function:global:$name" $node.Body.GetScriptBlock()
    }
}
function Assert-Rejected { param([scriptblock]$Action) try { & $Action | Out-Null } catch { return }; throw 'Expected rejection.' }
function Wait-Capture {
    param($Session,[int]$TimeoutSeconds=60)
    $until=[DateTimeOffset]::Now.AddSeconds(10)
    while ($null -ne $Session.Current -and [DateTimeOffset]::Now -lt $until) {
        Update-RobotTrainingCapture $Session $TimeoutSeconds
        Start-Sleep -Milliseconds 50
    }
    Assert-True ($null -eq $Session.Current) 'Capture process did not settle.'
}
$leases = New-Object 'System.Collections.Generic.List[object]'
$sessions = New-Object 'System.Collections.Generic.List[object]'
$owner = $null
$orphan = $null
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $writer=Enter-RobotInteractionLease $temp -Training; $leases.Add($writer)
    Assert-True ($null -ne $writer) 'Training lease unavailable.'
    Assert-True ($null -eq (Enter-RobotInteractionLease $temp)) 'Worker entered during training.'
    Assert-True ($null -eq (Enter-RobotInteractionLease $temp -Training)) 'Second training session entered.'
    Import-Functions (Join-Path $repo 'agent\ident-db-agent\IdentWorker.ps1') @('Invoke-RobotPoll')
    $script:Context=[pscustomobject]@{ RobotConfigPath=(Join-Path $temp 'config.json') }
    $script:State=@{ robot=@{ state='idle'; lastError='' } }
    $script:PollCalls=0
    function Write-RuntimeState { }
    function Invoke-RobotPollCore { $script:PollCalls++ }
    Invoke-RobotPoll
    Assert-True ($script:PollCalls -eq 0 -and $script:State.robot.state -eq 'waiting_for_training') 'A claim was attempted during training.'
    $writer.Dispose()
    $reader=Enter-RobotInteractionLease $temp; $leases.Add($reader)
    $child=Enter-RobotInteractionLease $temp; $leases.Add($child)
    Assert-True ($null -ne $reader -and $null -ne $child) 'Worker and child must share the execution lease.'
    Assert-True ($null -eq (Enter-RobotInteractionLease $temp -Training)) 'Training interrupted an execution.'
    $reader.Dispose(); $child.Dispose()
    Invoke-RobotPoll
    Assert-True ($script:PollCalls -eq 1) 'Released training lease blocked later polling.'

    Import-Functions (Join-Path $repo 'robot\ident-rpa\Start-IdentRobot.ps1') @(
        'Get-ObjectProperty','Assert-BookingContract','Resolve-TaskValue','Resolve-StepValue','Convert-PatientBirthDate'
    )
    $config=Get-Content (Join-Path $repo 'robot\ident-rpa\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $trainingConfigPath=Join-Path $temp 'training-config.json'
    $config | ConvertTo-Json -Depth 20 | Set-Content $trainingConfigPath -Encoding UTF8
    [void](Read-RobotTrainingConfiguration $trainingConfigPath)
    Assert-Rejected { Read-RobotTrainingConfiguration (Join-Path $temp 'not-found.json') }
    foreach ($invalid in @('{}','{broken', '{"ident":{"processName":"","windowTitleRegex":""}}', '{"ident":{"windowTitleRegex":"["}}')) {
        $invalid | Set-Content $trainingConfigPath -Encoding UTF8
        Assert-Rejected { Read-RobotTrainingConfiguration $trainingConfigPath }
    }
    Import-Functions (Join-Path $repo 'agent\ident-db-agent\IdentDesktop.ps1') @('Update-RobotTrainingProcess')
    foreach ($code in @(0,1)) {
        $fake=[pscustomobject]@{HasExited=$true;ExitCode=$code;Disposed=$false}
        $fake | Add-Member ScriptMethod WaitForExit { param($timeout) return $true }
        $fake | Add-Member ScriptMethod Dispose { $this.Disposed=$true }
        $script:TrainingProcess=$fake; $script:UiError=''
        Update-RobotTrainingProcess
        Assert-True ($fake.Disposed -and $null -eq $script:TrainingProcess) 'Exited training process was retained.'
        Assert-True (([bool]$script:UiError) -eq ($code -ne 0)) 'Training exit status was hidden or misreported.'
    }
    $split=New-SplitNameCandidate $config @()
    $task=[pscustomobject]@{ ticket=[pscustomobject]@{
        ClientSurname='Test'; ClientName='Patient'; ClientPatronymic=''; ClientPhone='+79990000000'; DoctorName='Fixture'
        PlanStart='2099-09-10T09:00:00+05:00'; PlanEnd='2099-09-10T09:45:00+05:00'
    } }
    Assert-BookingContract $split $task
    Assert-True ($config.workflow.PSObject.Properties.Name -notcontains 'patientNameMode') 'Original profile changed.'
    Assert-True (-not $split.workflow.allowUnsafeExecution) 'Split candidate enabled execution.'
    $task.ticket.PSObject.Properties.Remove('ClientPatronymic')
    Assert-Rejected { Assert-BookingContract $split $task }
    $task.ticket | Add-Member ClientFullName 'Patient Test'
    Assert-Rejected { Assert-BookingContract $split $task }
    $task.ticket | Add-Member ClientPatronymic ''
    Assert-Rejected { Assert-BookingContract $split $task }
    $task.ticket.PSObject.Properties.Remove('ClientFullName')
    $task.ticket.ClientSurname=''
    Assert-Rejected { Assert-BookingContract $split $task }
    $task.ticket.ClientSurname='Test'
    $split.workflow.steps[2].selector=$split.workflow.steps[1].selector
    Assert-Rejected { Assert-BookingContract $split $task }

    $fixture=Join-Path $PSScriptRoot 'fixtures\robot-capture-fixture.ps1'
    $configPath=Join-Path $temp 'fixture.json'
    @{ behavior='success' } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
    $session=New-RobotTrainingSession $temp; $sessions.Add($session)
    $now=[DateTimeOffset]::Now
    Assert-True (Set-RobotTrainingCaptureDelay $session $now) 'Delayed capture could not be armed.'
    Assert-True (-not (Test-RobotTrainingCaptureDue $session ($now.AddSeconds(7)))) 'Delayed capture fired early.'
    Assert-True (Test-RobotTrainingCaptureDue $session ($now.AddSeconds(8))) 'Delayed capture did not become ready.'
    Assert-True (-not (Test-RobotTrainingCaptureDue $session ($now.AddSeconds(9)))) 'Delayed capture fired twice.'
    Assert-True ($session.Attempt -eq 0 -and $session.Progress.Hotkeys -eq 0) 'Countdown was reported as a scan or a hotkey.'
    [void](Set-RobotTrainingCaptureDelay $session)
    $session.CaptureAt=$null
    Assert-True (-not (Test-RobotTrainingCaptureDue $session ($now.AddSeconds(10)))) 'Cancelled countdown fired.'
    [void](Set-RobotTrainingCaptureDelay $session)
    Assert-Rejected { Start-RobotTrainingCapture $session $fixture $configPath }
    Assert-True (Start-RobotTrainingCapture $session $fixture $configPath 101 102) 'First capture not started.'
    Assert-True ($null -eq $session.CaptureAt) 'Direct capture left an armed countdown.'
    Assert-True (-not (Set-RobotTrainingCaptureDelay $session)) 'Countdown armed while scanner was active.'
    Assert-True (-not (Start-RobotTrainingCapture $session $fixture $configPath 101 102)) 'Overlapping scanner started.'
    Wait-Capture $session
    Assert-True ($session.Captures.Count -eq 1 -and -not $session.LastError) ("First capture not accepted: " + $session.LastError)
    [void](Start-RobotTrainingCapture $session $fixture $configPath 101 102)
    Wait-Capture $session
    Assert-True ($session.Captures.Count -eq 2) 'Multiple stages did not accumulate.'
    $session.StartedAt=[DateTimeOffset]::Now.AddMinutes(-16)
    $session.Progress.State='expired'; $session.Progress.ErrorCode='wrong_window'
    Assert-True (-not (Set-RobotTrainingCaptureDelay $session)) 'Expired session armed a new countdown.'
    $zip=Export-RobotTrainingSession $session
    Assert-True ($session.Progress.Captured -eq 2 -and $session.Progress.State -eq 'completed' -and
        $session.Progress.ArchiveReady -and -not $session.Progress.ErrorCode) 'Expiry lost captures or retained a stale error after export.'
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $names=@($archive.Entries | ForEach-Object FullName)
        Assert-True ($names.Count -eq 5) 'Unexpected archive entries.'
        Assert-True (@($names | Where-Object { $_ -notmatch '^(session\.json|capture-\d{2}/(ui-tree|summary)\.json)$' }).Count -eq 0) 'Private files leaked into archive.'
        $reader=[IO.StreamReader]::new($archive.GetEntry('session.json').Open())
        try { $manifest=$reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        Assert-True ($manifest.actionsExecuted -eq 0 -and -not $manifest.profileActivated -and $manifest.captures.Count -eq 2) 'Misleading session status.'
    } finally { $archive.Dispose() }
    Assert-Rejected { Start-RobotTrainingCapture $session $fixture $configPath 101 102 }
    $expired=New-RobotTrainingSession $temp; $sessions.Add($expired)
    [void](Set-RobotTrainingCaptureDelay $expired)
    $expired.StartedAt=[DateTimeOffset]::Now.AddMinutes(-16)
    Assert-True (-not (Test-RobotTrainingCaptureDue $expired ([DateTimeOffset]::Now.AddSeconds(10)))) 'Countdown fired after expiry.'
    Assert-True ($null -eq $expired.CaptureAt) 'Expiry left an armed countdown.'
    Assert-Rejected { Start-RobotTrainingCapture $expired $fixture $configPath 101 102 }
    foreach ($behavior in @('stale','fail','wrong-window','hang')) {
        @{ behavior=$behavior } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8
        $failed=New-RobotTrainingSession $temp; $sessions.Add($failed)
        [void](Start-RobotTrainingCapture $failed $fixture $configPath 101 102)
        Wait-Capture $failed $(if ($behavior -eq 'hang') { 1 } else { 60 })
        Assert-True ($failed.Captures.Count -eq 0 -and $failed.LastError.Length -gt 0) "Invalid capture accepted: $behavior"
        Assert-Rejected { Export-RobotTrainingSession $failed }
    }
    $ownerScript=Join-Path $PSScriptRoot 'fixtures\robot-training-owner.ps1'
    $robotDirectory=Join-Path $repo 'robot\ident-rpa'
    $owner=Start-Process 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ownerScript`" -RobotDirectory `"$robotDirectory`" -TestDirectory `"$temp`" -ScannerPath `"$fixture`"")
    $null=$owner.Handle
    $until=[DateTimeOffset]::Now.AddSeconds(8)
    $pidPath=Join-Path $temp 'scanner.pid'
    while (-not (Test-Path $pidPath) -and [DateTimeOffset]::Now -lt $until) { Start-Sleep -Milliseconds 100 }
    $scannerId=[int](Get-Content $pidPath -Raw)
    $orphan=Get-Process -Id $scannerId
    $null=$orphan.Handle
    $owner.Kill(); Assert-True ($owner.WaitForExit(1500)) 'Training test owner did not stop.'
    Assert-True ($orphan.WaitForExit(2500)) 'Scanner survived the training owner crash.'
    $recovered=Enter-RobotInteractionLease $temp -Training; $leases.Add($recovered)
    Assert-True ($null -ne $recovered) 'Observation crash retained a stale lease.'
    $recovered.Dispose()
    $limited=New-RobotTrainingSession $temp; $sessions.Add($limited)
    $limited.Attempt=12
    Assert-True (-not (Set-RobotTrainingCaptureDelay $limited)) 'Countdown bypassed the capture limit.'
    Assert-Rejected { Start-RobotTrainingCapture $limited $fixture $configPath 101 102 }
    Write-Host 'IDENT TRAINING OK: exclusive observation, no claims, explicit split names, sequential captures, private ZIP, stale/failure/timeout/owner-crash recovery.'
}
finally {
    foreach ($process in @($owner,$orphan)) {
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
            $process.Dispose()
        }
    }
    foreach ($session in $sessions) {
        if ($null -ne $session.Current) {
            $session.Current.Job.Dispose()
            if (-not $session.Current.Process.HasExited) { $session.Current.Process.Kill(); [void]$session.Current.Process.WaitForExit(1500) }
            $session.Current.Process.Dispose()
        }
    }
    foreach ($lease in $leases) { if ($null -ne $lease) { $lease.Dispose() } }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
