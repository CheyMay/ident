[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp-reliability'))
if (-not $temp.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path' }

function Import-Functions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in $Names) {
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if ($null -eq $node) { throw "Function not found: $name" }
        Set-Item -Path "Function:global:$name" -Value $node.Body.GetScriptBlock()
    }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action } catch { if ($_.Exception.Message -notmatch $Pattern) { throw }; return }
    throw "Expected rejection: $Pattern"
}
function Assert-True { param([bool]$Value, [string]$Label) if (-not $Value) { throw $Label } }

New-Item -ItemType Directory -Force -Path $temp | Out-Null
$lock = $null
try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
    Import-Functions (Join-Path $root 'robot\ident-rpa\Start-IdentRobot.ps1') @(
        'Get-ObjectProperty', 'Resolve-TaskValue', 'Resolve-StepValue', 'Assert-BookingContract',
        'Convert-PatientBirthDate', 'Test-SkipEmptyBirthDateStep',
        'Get-CalibrationDefinitions', 'Get-CalibrationSelector', 'Get-NearbyControlText', 'Convert-BoundsText', 'Format-Bounds'
    )
    $config = Get-Content (Join-Path $root 'robot\ident-rpa\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $task = [pscustomobject]@{ ticket = [pscustomobject]@{
        ClientFullName = 'Test Patient'; ClientPhone = '+79990000000'; DoctorName = 'Test Doctor'
        PlanStart = '2099-09-09T09:00:00+05:00'; PlanEnd = '2099-09-09T09:45:00+05:00'
    } }
    foreach ($minutes in @(15,30,45,120,180,345,360)) {
        $task.ticket.PlanEnd = ([DateTimeOffset]::Parse($task.ticket.PlanStart)).AddMinutes($minutes).ToString('o')
        Assert-BookingContract $config $task
    }
    $step = [pscustomobject]@{ valueFrom = 'ticket.PlanStart'; valueFormat = 'dd.MM.yyyy HH:mm' }
    Assert-True ((Resolve-StepValue $task $step) -eq '09.09.2099 09:00') 'Clinic time must not convert to workstation timezone'
    $task.ticket.PlanEnd = '2099-09-09T15:15:00+05:00'
    Assert-Throws { Assert-BookingContract $config $task } '6 hours'
    $task.ticket.PlanEnd = '2099-09-09T15:00:00+05:00'
    $birthStep = @($config.workflow.steps | Where-Object { $_.name -eq 'set_patient_birth_date' })[0]
    Assert-True (Test-SkipEmptyBirthDateStep $task $birthStep) 'Missing birthday must not erase the IDENT patient field'
    $task.ticket | Add-Member -NotePropertyName ClientBirthDate -NotePropertyValue '2000-02-29'
    Assert-Throws { Assert-BookingContract $config $task } 'ClientBirthDate selector'
    $config.selectors.patientBirthDateInput.automationId = 'PatientBirthDateInput'
    Assert-BookingContract $config $task
    $birthStep.selector = 'patientNameInput'
    Assert-Throws { Assert-BookingContract $config $task } 'separate patient field selector'
    $birthStep.selector = 'patientBirthDateInput'
    $task.ticket | Add-Member -NotePropertyName DurationMinutes -NotePropertyValue 375
    Assert-Throws { Assert-BookingContract $config $task } 'DurationMinutes must match'
    $task.ticket.PSObject.Properties.Remove('DurationMinutes')
    Assert-True (-not (Test-SkipEmptyBirthDateStep $task $birthStep)) 'Provided birthday must not be skipped'
    Assert-True ((Resolve-StepValue $task $birthStep) -eq '29.02.2000') 'Birthday must format without a timezone conversion'
    $savedSteps = @($config.workflow.steps)
    $config.workflow.steps = @($savedSteps | Where-Object { $_.name -ne 'set_patient_birth_date' })
    Assert-Throws { Assert-BookingContract $config $task } 'ClientBirthDate exactly once'
    $config.workflow.steps = $savedSteps
    foreach ($birthDate in @('2001-02-29', '2099-01-01', '2000-02-29T00:00:00Z', '29.02.2000', '1899-01-01')) {
        $task.ticket.ClientBirthDate = $birthDate
        Assert-Throws { Assert-BookingContract $config $task } 'ClientBirthDate must be a valid'
    }
    $task.ticket.ClientBirthDate = ''
    Assert-BookingContract $config $task
    $task.ticket.PlanEnd = '2099-09-09T09:44:00+05:00'
    Assert-Throws { Assert-BookingContract $config $task } 'multiple of 15'
    $task.ticket.PlanEnd = ''
    Assert-Throws { Assert-BookingContract $config $task } 'missing'
    $task.ticket.PlanEnd = '2099-09-09T11:00:00+05:00'
    $config.workflow.successCondition.type = 'elementMissing'
    Assert-Throws { Assert-BookingContract $config $task } 'not proof'
    $config.workflow.successCondition.type = 'elementPresent'
    $config.workflow.steps = @($config.workflow.steps | Where-Object { $_.name -ne 'set_end_time' })
    Assert-Throws { Assert-BookingContract $config $task } 'PlanEnd'
    Assert-True ((Format-Bounds ([Windows.Rect]::Empty)) -eq '') 'Empty UI bounds must be safe'
    $rows = @([pscustomobject]@{
        path='0/1'; rootName='New appointment'; name='Записать пациента'; automationId='SaveButton';
        className='Button'; controlType='ControlType.Button'; bounds='10,10,200,30'; isEnabled=$true; isOffscreen=$false
    })
    Assert-True (-not (Get-CalibrationSelector 'newAppointmentButton' $rows @{}).Ok) 'Save must never be detected as opening an appointment'
    Assert-True ((Get-CalibrationSelector 'saveButton' $rows @{}).Ok) 'Save selector missing'
    $rows[0].isEnabled = $false
    Assert-True (-not (Get-CalibrationSelector 'saveButton' $rows @{}).Ok) 'Disabled controls must not calibrate'

    Import-Functions (Join-Path $root 'agent\ident-db-agent\IdentSupervisor.ps1') @('Write-SupervisorState', 'Write-SupervisorLog', 'Invoke-LogRotation', 'Read-JsonFile')
    $script:Worker = $null; $script:StartedAt = (Get-Date).ToString('o'); $script:LastRestartAt = $null
    $script:RestartCount = 1; $script:LastError = ''
    $supervisorStatePath = Join-Path $temp 'state.json'; $logPath = Join-Path $temp 'log.json'
    Write-SupervisorState 'running'
    $lock = [IO.File]::Open($supervisorStatePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    Write-SupervisorState 'running' -WarningAction SilentlyContinue
    $lock.Dispose(); $lock = $null
    Write-SupervisorState 'running'
    Assert-True ((Read-JsonFile $supervisorStatePath).state -eq 'running') 'Supervisor must recover after file lock'

    Import-Functions (Join-Path $root 'agent\ident-db-agent\IdentWorker.ps1') @('Invoke-RobotPoll')
    $script:Context = [pscustomobject]@{
        RobotConfigPath = Join-Path $temp 'robot\config.json'; BaseDirectory = $temp
        CommandDirectory = Join-Path $temp 'commands'
        Config = [pscustomobject]@{ agent = [pscustomobject]@{ id = 'test' } }
    }
    $script:State = @{ robot = @{ state='idle'; configured=$true; lastError=''; lastSuccessAt='' } }
    $script:Proof = $null; $script:Runs = 0; $script:Claims = 0; $script:Completes = 0; $script:Fails = 0
    $script:Uncertain = $false
    New-Item -ItemType Directory -Force -Path (Join-Path $temp 'robot'), $script:Context.CommandDirectory | Out-Null
    function Get-RobotSuccessMarkerPath { return (Join-Path $script:Context.CommandDirectory 'proof.json') }
    function Get-RobotSuccessMarker { param($Id,$Fingerprint) return $script:Proof }
    function Remove-RobotSuccessMarker {
        Remove-Item -LiteralPath (Get-RobotSuccessMarkerPath) -Force -ErrorAction SilentlyContinue
        $script:Proof = $null
    }
    function Get-RobotConfigurationProblem { return '' }
    function Get-MinimumUserIdleSeconds { return 60 }
    function Test-InteractiveDesktopAvailable { return $true }
    function Get-UserIdleSeconds { return 120 }
    function Write-RuntimeState {}
    function Write-WorkerLog { param($Level,$EventName,$Data) }
    function Save-RobotReceipt { param($Id,$Fingerprint,$CompletedAt) }
    function Get-RobotReceipt { param($Id,$Fingerprint) return $null }
    function Invoke-AgentRequest {
        param($Method,$Path,$Body)
        switch ($Path) {
            '/api/robot/tasks/claim' {
                $script:Claims++
                return [pscustomobject]@{ record = [pscustomobject]@{ id='test-booking'; fingerprint='fp' } }
            }
            '/api/robot/tasks/complete' {
                $script:Completes++
                if ($script:Completes -eq 1) { throw 'Simulated lost HTTP acknowledgement' }
                return @{ record = @{ status='robot_completed' } }
            }
            '/api/robot/tasks/fail' { $script:Fails++; return @{} }
            default { throw "Unexpected request $Path" }
        }
    }
    function Invoke-PowerShellChildProcess {
        param($Arguments,$TimeoutSeconds,$Label)
        $script:Runs++
        @{ id='test-booking'; fingerprint='fp' } | ConvertTo-Json | Set-Content (Join-Path $temp 'robot\execution-pending.json') -Encoding UTF8
        if (-not $script:Uncertain) {
            $script:Proof = [pscustomobject]@{ id='test-booking'; fingerprint='fp'; completedAt=(Get-Date).ToString('o') }
            $script:Proof | ConvertTo-Json | Set-Content (Get-RobotSuccessMarkerPath) -Encoding UTF8
        }
        throw 'Simulated timeout after UI action'
    }
    Invoke-RobotPoll
    Assert-True ($script:State.robot.state -eq 'awaiting_confirmation') 'Timeout after proof must retain success'
    Invoke-RobotPoll
    Assert-True ($script:Runs -eq 1 -and $script:Claims -eq 1 -and $script:Completes -eq 2 -and $script:Fails -eq 0) 'Lost acknowledgement must never execute twice'
    Assert-True ($script:State.robot.state -eq 'idle') 'Outbox must settle without claiming again'
    Assert-True (-not (Test-Path (Join-Path $temp 'robot\execution-pending.json'))) 'Recovered intent must be cleared'
    $script:Uncertain = $true
    Invoke-RobotPoll
    Invoke-RobotPoll
    Assert-True ($script:State.robot.state -eq 'needs_review' -and $script:Runs -eq 2 -and $script:Claims -eq 2 -and $script:Fails -eq 1) 'Uncertain UI action must halt subsequent bookings'

    Import-Functions (Join-Path $root 'agent\ident-db-agent\IdentDesktop.ps1') @('Invoke-AgentSettings', 'Update-AgentSettings', 'Update-RobotCalibration')
    $script:SettingsRequest = $null; $script:PendingSettings = $null; $script:AgentKey = 'test-only'; $script:UiError = ''
    $scheduleCheck = [pscustomobject]@{ Enabled=$true; Checked=$true }
    $robotCheck = [pscustomobject]@{ Enabled=$true; Checked=$false }
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $script:Config = [pscustomobject]@{
        backend = [pscustomobject]@{ baseUrl = "http://127.0.0.1:$($listener.LocalEndpoint.Port)" }
        agent = [pscustomobject]@{ id='test' }
    }
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Invoke-AgentSettings $true $false
        Assert-True ($clock.Elapsed.TotalSeconds -lt 2) 'An unanswered API must not block the desktop'
        Assert-True (-not $scheduleCheck.Enabled) 'Repeated toggle requests must be disabled while pending'
    }
    finally {
        $listener.Stop()
        if ($null -ne $script:SettingsRequest) {
            $script:SettingsRequest.Runner.Stop()
            $script:SettingsRequest.Runner.Dispose()
            $script:SettingsRequest = $null
        }
    }
    $script:CalibrationStage = 'scanning'
    $script:CalibrationStartedAt = [DateTimeOffset]::Now.AddSeconds(-61)
    $script:CalibrationProcess = $null
    $calibrateButton = [pscustomobject]@{ Enabled=$false; Text='' }
    function Show-MainWindow {}
    Update-RobotCalibration
    Assert-True ($script:CalibrationStage -eq 'failed' -and $calibrateButton.Enabled) 'Hung calibration must release the desktop after a minute'
    Write-Host 'IDENT RELIABILITY TEST OK: durations, timezone, calibration, locks, save recovery, uncertain result, responsive desktop, scan timeout.'
}
finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
