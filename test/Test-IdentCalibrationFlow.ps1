[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$script:CalibrationJob = $null
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repo 'robot\ident-rpa\RobotSafety.ps1')
. (Join-Path $repo 'robot\ident-rpa\RobotCapture.ps1')
. (Join-Path $repo 'robot\ident-rpa\IdentPatientForm.ps1')
. (Join-Path $PSScriptRoot 'fixtures\ident-patient-form.ps1')
$temp = Join-Path $env:TEMP ('ident-calibration-test-' + [guid]::NewGuid().ToString('N'))
$temp = [IO.Path]::GetFullPath($temp)
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
function Import-Functions {
    param([string]$Path, [string[]]$Names)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    foreach ($name in $Names) {
        $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if ($null -eq $node) { throw "Missing function $name" }
        Set-Item "Function:global:$name" $node.Body.GetScriptBlock()
    }
}
function Assert-True { param([bool]$Value, [string]$Message) if (-not $Value) { throw $Message } }
function Assert-Rejected {
    param([scriptblock]$Action)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Expected failure was accepted.' }
}
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    Import-Functions (Join-Path $repo 'robot\ident-rpa\Start-IdentRobot.ps1') @(
        'Get-ObjectProperty', 'Write-JsonFileAtomic', 'Convert-BoundsText', 'Get-NearbyControlText',
        'Get-CalibrationDefinitions', 'Get-CalibrationSelector', 'Invoke-AutomaticCalibration',
        'Assert-BookingContract', 'Resolve-TaskValue', 'Convert-PatientBirthDate', 'Select-CalibrationRoots'
    )
    Import-Functions (Join-Path $repo 'agent\ident-db-agent\IdentDesktop.ps1') @('Read-JsonFile', 'Get-FreshRobotCapture', 'Update-RobotCalibration', 'Update-CalibrationLiveStatus')
    $script:CalibrationProgress = $null
    $calendar = [pscustomobject]@{ Current = [pscustomobject]@{ Name='IDENT calendar'; IsOffscreen=$false } }
    $dialog = [pscustomobject]@{ Current = [pscustomobject]@{ Name='New appointment - fixture'; IsOffscreen=$false } }
    $chosen = @(Select-CalibrationRoots @($calendar, $dialog))
    Assert-True ($chosen.Count -eq 1 -and $chosen[0] -eq $dialog) 'Visible appointment dialog must have priority.'
    $dialog.Current.IsOffscreen = $true
    Assert-True (@(Select-CalibrationRoots @($calendar, $dialog)).Count -eq 2) 'Hidden dialog must not replace the calendar.'
    function Get-IdentAutomationRoots { param($WindowInfo) return @($calendar) }
    function Get-UiTreeRows { param($Roots,$MaxDepth) return $script:FixtureRows }
    $script:FixtureRows = @(0..8 | ForEach-Object {
        $names = @('LastName','FirstName','MiddleName','Phone','BirthDate','Comment','StartTime','EndTime','Save')
        [pscustomobject]@{
            depth=1; path="0/$_"; rootName='Test appointment'; name=$names[$_]; automationId=$names[$_]
            className='TextBox'; controlType='ControlType.Edit'; isEnabled=$true; isOffscreen=$false
            patterns=@('ValuePatternIdentifiers.Pattern'); bounds="100,$(100 + $_ * 100),200,24"
        }
    })
    $fullName = Get-CalibrationSelector -Name 'patientNameInput' -Rows $script:FixtureRows -UsedPaths @{}
    Assert-True (-not $fullName.Ok) 'Surname must never be mistaken for full name.'
    $lastName = Get-CalibrationSelector -Name 'patientLastNameInput' -Rows $script:FixtureRows -UsedPaths @{}
    Assert-True ($lastName.Ok -and $lastName.Selector.automationId -eq 'LastName') 'Separate surname role missing.'
    $identSurname = [pscustomobject]@{
        depth=1; path='0/3'; rootName='New appointment - fixture'; name=''; automationId='_surnameTextBox'
        className='TextBox'; controlType='ControlType.Edit'; isEnabled=$true; isOffscreen=$false
        patterns=@('ValuePatternIdentifiers.Pattern'); bounds='200,200,250,34'
    }
    $lastName = Get-CalibrationSelector -Name 'patientLastNameInput' -Rows @($identSurname) -UsedPaths @{}
    Assert-True ($lastName.Ok -and $lastName.Selector.automationId -ceq '_surnameTextBox') 'Observed IDENT surname ID was not recognized.'
    Assert-True (-not (Get-CalibrationSelector -Name 'patientNameInput' -Rows @($identSurname) -UsedPaths @{}).Ok) 'IDENT surname was promoted to full name.'
    $duplicateSurname = $identSurname.PSObject.Copy()
    $duplicateSurname.path = '0/4'
    Assert-True (-not (Get-CalibrationSelector -Name 'patientLastNameInput' -Rows @($identSurname,$duplicateSurname) -UsedPaths @{}).Ok) 'Duplicate IDENT surname ID was accepted.'
    $duplicateSurname.automationId = '_surnameTextBoxHistory'
    Assert-True (-not (Get-CalibrationSelector -Name 'patientLastNameInput' -Rows @($duplicateSurname) -UsedPaths @{}).Ok) 'IDENT surname alias matched a different ID.'
    $identSurname.isEnabled = $false
    Assert-True (-not (Get-CalibrationSelector -Name 'patientLastNameInput' -Rows @($identSurname) -UsedPaths @{}).Ok) 'Disabled IDENT surname field was accepted.'
    $configPath = Join-Path $temp 'config.local.json'
    Copy-Item -LiteralPath (Join-Path $repo 'robot\ident-rpa\config.example.json') -Destination $configPath
    $config = Read-JsonFile $configPath
    $config.selectors.patientNameInput.automationId = 'OLD-UNVERIFIED-NAME'
    $config | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $before = (Get-FileHash $configPath).Hash
    $reportPath = Join-Path $temp 'calibration-report.json'
    $started = [DateTimeOffset]::Now.AddSeconds(-1)
    $window = [pscustomobject]@{ process = [pscustomobject]@{ ProcessName='Fixture'; MainWindowTitle='Test appointment' } }
    $report = Invoke-AutomaticCalibration $window $config $configPath $reportPath 'fixture-run'
    Assert-True ($report.ok -and $report.splitNameFieldsDetected -and -not $report.selectorsComplete) 'Split form must require an adapter.'
    Assert-True (-not $report.readyForUnattendedExecution) 'A capture must not authorize booking.'
    Assert-True ((Get-FileHash $configPath).Hash -eq $before) 'Active profile was changed.'
    $candidate = Read-JsonFile (Join-Path $temp 'calibration-candidate.json')
    Assert-True (-not $candidate.workflow.allowUnsafeExecution -and $candidate.calibration.status -ne 'verified') 'Candidate was activated.'
    Assert-True ($candidate.selectors.patientNameInput.automationId -eq '') 'Unresolved candidate retained a stale binding.'
    $oldRows=$script:FixtureRows
    try {
        $script:FixtureRows=@(New-IdentPatientFormFixture -Expanded)
        $formReportPath=Join-Path $temp 'patient-form-report.json'
        $formConfig=Read-JsonFile $configPath
        $formReport=Invoke-AutomaticCalibration $window $formConfig $configPath $formReportPath 'patient-form-fixture'
        Assert-True ($formReport.patientFormBindings.Ok -and $formReport.patientFormBindings.Fields.Count -eq 6 -and $formReport.splitNameFieldsDetected) 'Form-specific discovery missing from calibration.'
        Assert-True (-not $formReport.selectorsComplete -and -not $formReport.readyForUnattendedExecution -and -not $formReport.patientFormBindings.ReadyForInput) 'Form discovery authorized generic execution.'
        Assert-True ((Get-FileHash $configPath).Hash -eq $before) 'Form discovery changed active profile.'
        $formCandidate=Read-JsonFile (Join-Path $temp 'patient-form-candidate.json')
        Assert-True ($formCandidate.Fields.commentInput.Path -eq '0/36/5/0' -and -not $formCandidate.ReadyForInput) 'Wrong candidate comment or unsafe readiness.'
    } finally { $script:FixtureRows=$oldRows }
    $fresh = Get-FreshRobotCapture $reportPath 'fixture-run' $started
    Assert-True ($fresh.Path -eq $report.capturePath) 'Fresh output was not selected.'
    Assert-Rejected { Get-FreshRobotCapture $reportPath 'old-run' $started }
    Assert-Rejected { Get-FreshRobotCapture $reportPath 'fixture-run' ([DateTimeOffset]::Now.AddMinutes(2)) }
    $original = Get-Content -LiteralPath $report.capturePath -Raw
    Add-Content -LiteralPath $report.capturePath -Value ' '
    Assert-Rejected { Get-FreshRobotCapture $reportPath 'fixture-run' $started }
    [IO.File]::WriteAllText($report.capturePath, $original, [Text.UTF8Encoding]::new($true))
    $report.captureBytes = (Get-Item $report.capturePath).Length
    $report.captureSha256 = (Get-FileHash $report.capturePath).Hash
    $report.capturePath = Join-Path $temp '..\ui-tree-20000101-000000-000.json'
    Write-JsonFileAtomic $reportPath $report
    Assert-Rejected { Get-FreshRobotCapture $reportPath 'fixture-run' $started }
    $script:FixtureRows | ForEach-Object { $_.isOffscreen = $true }
    $config = Read-JsonFile $configPath
    $report = Invoke-AutomaticCalibration $window $config $configPath $reportPath 'hidden-run'
    Assert-True (-not $report.ok -and $report.visibleControls -eq 0) 'Offscreen window accepted as visible.'
    Assert-Rejected { Get-FreshRobotCapture $reportPath 'hidden-run' $started }

    $script:CalibrationStage = 'scanning'
    $script:CalibrationStartedAt = [DateTimeOffset]::Now
    $script:CalibrationReportPath = $reportPath
    $script:CalibrationCaptureId = 'different-run'
    $script:CalibrationErrorPath = Join-Path $temp 'error.log'
    $script:CalibrationProcess = [pscustomobject]@{ HasExited=$true; ExitCode=0 }
    $script:CalibrationProcess | Add-Member ScriptMethod Dispose {}
    $calibrateButton = [pscustomobject]@{ Enabled=$false; Text='' }
    $robotGuideLabel = [pscustomobject]@{ Text='' }
    $errorLabel = [pscustomobject]@{ Text='' }
    Update-RobotCalibration
    Assert-True ($script:CalibrationStage -eq 'failed' -and $calibrateButton.Enabled) 'Stale report left UI stuck or ready.'

    Import-Functions (Join-Path $repo 'agent\ident-db-agent\IdentWorker.ps1') @('Get-RobotConfigurationProblem','Get-RobotCalibrationSummary')
    $script:Context = [pscustomobject]@{ RobotConfigPath = $configPath }
    $summary = Get-RobotCalibrationSummary
    Assert-True ($summary.captureId -eq 'hidden-run') 'Remote scan metadata missing.'
    Assert-True (-not $summary.Contains('patientNameFields') -and -not $summary.Contains('capturePath')) 'Remote metadata leaked UI contents.'
    $config = Read-JsonFile $configPath
    $config.calibration.status = 'verified'
    $config.calibration.calibratedAt = [DateTimeOffset]::Now.ToString('o')
    $config.workflow.allowUnsafeExecution = $true
    $config.workflow.confirmBeforeEachStep = $false
    foreach ($entry in $config.selectors.PSObject.Properties) { $entry.Value.name = $entry.Name }
    Write-JsonFileAtomic $configPath $config
    Assert-True ((Get-RobotConfigurationProblem) -eq '') 'Valid synthetic profile was rejected.'
    $config.selectors.patientPhoneInput.name = ''
    $config.selectors.patientPhoneInput.className = 'TextBox'
    Write-JsonFileAtomic $configPath $config
    Assert-True ((Get-RobotConfigurationProblem) -match 'stable name') 'Class-only selector was accepted.'
    $config.selectors.patientPhoneInput.name = 'Phone'
    $nameStep = @($config.workflow.steps | Where-Object { (Get-ObjectProperty $_ 'valueFrom' '') -eq 'ticket.ClientFullName' })[0]
    $nameStep.selector = 'patientPhoneInput'
    Write-JsonFileAtomic $configPath $config
    Assert-True ((Get-RobotConfigurationProblem) -match 'separate field') 'Duplicate field binding was accepted.'
    $nameStep.selector = 'patientNameInput'
    $config.workflow.successCondition.selector = 'saveButton'
    Write-JsonFileAtomic $configPath $config
    Assert-True ((Get-RobotConfigurationProblem) -match 'separate from') 'Save button was accepted as proof.'
    $config.workflow.successCondition.selector = 'bookingConfirmed'
    $task = [pscustomobject]@{ ticket = [pscustomobject]@{
        ClientFullName='Test Patient'; ClientPhone='+79990000000'; DoctorName='Test Doctor'
        PlanStart='2099-09-09T10:00:00+05:00'; PlanEnd='2099-09-09T10:45:00+05:00'
    } }
    Assert-BookingContract $config $task
    $task.ticket.PlanStart = '2000-01-01T10:00:00+05:00'
    $task.ticket.PlanEnd = '2000-01-01T10:45:00+05:00'
    Assert-Rejected { Assert-BookingContract $config $task }
    Write-Host 'IDENT CALIBRATION FLOW OK: split fields, freshness, profile isolation, metadata privacy, UI recovery, binding guards, expired bookings.'
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
