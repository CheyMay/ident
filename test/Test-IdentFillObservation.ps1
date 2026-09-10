Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentFillCheck.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentFillRuntime.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-patient-form.ps1')
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
$request=[pscustomobject]@{ schemaVersion=1; purpose='ident-patient-fill-test'; doctorCaption='Fixture D. A.';
    planStart='2099-09-20T09:00:00+05:00'; planEnd='2099-09-20T09:45:00+05:00';
    patient=[pscustomobject]@{ surname='Fixture'; name='Test'; patronymic='Example'; phone='+79990000000'; birthDate='1990-01-01' }; comment='Synthetic' }
$plan=New-IdentFillCheckPlan $request
function New-Snapshot {
    $fields=[ordered]@{}
    foreach($role in $plan.Values.Keys) {
        $fields[$role]=[pscustomobject]@{ Identity=('PRIVATE_ID_'+$role); Bounds='PRIVATE_BOUNDS'; Value=''; ReadOnly=$false }
    }
    $fields.patientLastNameInput.Value=$plan.Values.patientLastNameInput
    return [pscustomobject]@{ Form=(Get-IdentPatientFormBindings @(New-IdentPatientFormFixture -Expanded));
        RootIdentity='PRIVATE_ROOT'; NotificationsOff=$true; Fields=$fields }
}
function Check-Privacy($Result) {
    $json=$Result | ConvertTo-Json -Depth 8
    Assert ($json -notmatch 'PRIVATE|79990000000|Fixture|Synthetic') 'Observation leaked field contents or UI metadata.'
    Assert ($Result.ReadOnly -and $Result.WriteAttempts -eq 0 -and $Result.WriteReturned -eq 0 -and $Result.Written -eq 0 -and
        -not $Result.SaveInvoked -and -not $Result.ReadyForUnattendedExecution -and $Result.RequiresManualReview) 'Observation reported write authority.'
}
$script:reads=0; $script:ready=0
$r=Invoke-IdentFillObservation $plan {
    $script:reads++; $s=New-Snapshot
    if ($script:reads -gt 1) {
        $s.Fields.patientFirstNameInput.Value='Test'
        $s.Fields.patientMiddleNameInput.Identity='PRIVATE_RECREATED'
        $s.Fields.patientFirstNameInput.Bounds='PRIVATE_MOVED'
    }
    return $s
} { $script:ready++ } -MaxSnapshots 2 -PollMilliseconds 0
Assert ($r.Ok -and $r.State -eq 'observed_change' -and $r.Snapshots -eq 3 -and $ready -eq 1 -and
    $r.ValueChangedRoles.Count -eq 1 -and $r.ValueChangedRoles[0] -eq 'patientFirstNameInput' -and
    $r.IdentityChangedRoles[0] -eq 'patientMiddleNameInput' -and $r.BoundsChangedRoles[0] -eq 'patientFirstNameInput' -and
    $r.ExpectedFirstNameObserved) 'Read-only change summary incorrect.'
Check-Privacy $r
$r=Invoke-IdentFillObservation $plan { New-Snapshot } -MaxSnapshots 2 -PollMilliseconds 0
Assert ($r.Ok -and $r.State -eq 'no_change' -and -not $r.ExpectedFirstNameObserved) 'No-change result implied fill success.'
Check-Privacy $r
$script:reads=0
$r=Invoke-IdentFillObservation $plan {
    $script:reads++
    if ($reads -eq 2) { throw 'FILL_USER_ACTIVE' }
    return New-Snapshot
} -MaxSnapshots 2 -PollMilliseconds 0
Assert ($r.Ok -and $r.UnstableSnapshots -eq 1 -and $r.Snapshots -eq 2) 'Manual input during a sample was not discarded.'
$script:reads=0
$r=Invoke-IdentFillObservation $plan {
    $script:reads++; if ($reads -gt 1) { throw 'FILL_USER_ACTIVE' }; return New-Snapshot
} -MaxSnapshots 2 -PollMilliseconds 0
Assert (-not $r.Ok -and $r.ErrorCode -eq 'FILL_USER_ACTIVE') 'No stable follow-up sample was reported as success.'
foreach($failure in @('FILL_WINDOW_CHANGED','FILL_ROBOT_ENABLED','PRIVATE_PROVIDER_ERROR')) {
    $script:reads=0
    $r=Invoke-IdentFillObservation $plan {
        $script:reads++; if ($reads -gt 1) { throw $failure }; return New-Snapshot
    } -MaxSnapshots 2 -PollMilliseconds 0
    Assert (-not $r.Ok -and $r.FailurePhase -eq 'observation' -and $reads -eq 2) 'Observation continued after a safety failure.'
    Check-Privacy $r
}
$script:reads=0
$r=Invoke-IdentFillObservation $plan {
    $script:reads++; $s=New-Snapshot; if ($reads -gt 1) { $s.RootIdentity='PRIVATE_OTHER_ROOT' }; return $s
} -MaxSnapshots 2 -PollMilliseconds 0
Assert (-not $r.Ok -and $r.FailureReason -eq 'root_identity') 'Observer adopted another form.'
$script:reads=0
$r=Invoke-IdentFillObservation $plan {
    $script:reads++
    if ($reads -gt 1) { throw (New-IdentFillFailure 'FILL_FORM_CHANGED' 'field_geometry' 'patientFirstNameInput') }
    return New-Snapshot
} -MaxSnapshots 2 -PollMilliseconds 0
Assert (-not $r.Ok -and $r.FailureReason -eq 'field_geometry' -and $r.FailureRole -eq 'patientFirstNameInput') 'Geometry race was not diagnosed.'
$r=Invoke-IdentFillObservation $plan { $s=New-Snapshot; $s.Fields.patientFirstNameInput.Value='PRIVATE_NONEMPTY'; return $s } `
    { throw 'Ready callback must not run' } -MaxSnapshots 1 -PollMilliseconds 0
Assert (-not $r.Ok -and $r.ErrorCode -eq 'FILL_EXISTING_VALUE' -and -not $r.BaselineCaptured) 'Nonempty first-name baseline was accepted.'
Check-Privacy $r
$r=Invoke-IdentFillObservation $plan { $s=New-Snapshot; $s.NotificationsOff=$false; return $s } -MaxSnapshots 1 -PollMilliseconds 0
Assert (-not $r.Ok -and $r.ErrorCode -eq 'FILL_UNSAFE_FORM') 'Notifications-on baseline was accepted.'
$rejected=$false
try { Invoke-IdentSupervisedFill -Execute -ObserveChanges } catch { $rejected=$_.Exception.Message -eq 'FILL_INVALID_MODE' }
Assert $rejected 'Runtime accepted observation with execution.'
Write-Host 'IDENT FILL OBSERVATION TESTS OK (synthetic read-only snapshots)'
