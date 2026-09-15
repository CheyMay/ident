Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
foreach($file in @('IdentPatientForm.ps1','IdentFillCheck.ps1','IdentCalendar.ps1','IdentBookingTrial.ps1')) {
    . (Join-Path $repo ('robot/ident-rpa/'+$file))
}
$script:checks=0
function Assert-Test([bool]$Ok,[string]$Message) {
    if (-not $Ok) { throw $Message }
    $script:checks++
}
function Reset-Trial {
    $script:request=[pscustomobject]@{ schemaVersion=1; purpose='ident-booking-trial'; patientMode='new';
        doctorCaption='Fixture D. A.'; doctorId=10; branchId=1;
        planStart='2099-09-20T09:00:00+05:00'; planEnd='2099-09-20T09:30:00+05:00';
        patient=[pscustomobject]@{ surname='Fixture'; name='Test'; patronymic='Example'; phone='+79990000000'; birthDate='2000-01-01' };
        comment='PRIVATE_TEST_VALUE' }
    $script:plan=New-IdentBookingTrialPlan $request
    $script:calls=[Collections.Generic.List[string]]::new()
    $script:journals=[Collections.Generic.List[string]]::new()
    $script:guardCount=0; $script:failGuardAt=0; $script:failStage=''; $script:failJournal=''
    $script:noisyCallbacks=$false
    $script:ready=[pscustomobject]@{ ReviewClear=$true; NavigationSupported=$true; PatientSupported=$true }
    $fields=[ordered]@{}
    foreach($role in $plan.Fill.Values.Keys) {
        $fields[$role]=[pscustomobject]@{ Identity=('synthetic-'+$role); Value=''; ReadOnly=$false }
    }
    $script:prepared=[pscustomobject]@{ Ok=$true; SaveInvoked=$false; PatientMode='new'; IdentityVerified=$true;
        Snapshot=[pscustomobject]@{ Form=[pscustomobject]@{ Ok=$true; Layout='expanded';
            Appointment=[pscustomobject]@{ DoctorCaption='Fixture D. A.'; Date='2099-09-20'; Start='09:00'; End='09:30' } };
            RootIdentity='root-1'; NotificationsOff=$true; Fields=$fields } }
    $script:final=$prepared.Snapshot | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $finalFields=[ordered]@{}
    foreach($role in $plan.Fill.Values.Keys) {
        $finalFields[$role]=[pscustomobject]@{ Identity=('synthetic-'+$role); Value=$plan.Fill.Values[$role]; ReadOnly=$false }
    }
    $script:final.Fields=$finalFields
    $script:nav=[pscustomobject]@{ Ok=$true; Date='2099-09-20'; SaveInvoked=$false }
    $script:open=[pscustomobject]@{ Ok=$true; State='opened_verified'; SaveInvoked=$false }
    $script:fill=[pscustomobject]@{ Ok=$true; State='filled_not_saved'; SaveInvoked=$false;
        WriteAttempts=6; WriteReturned=6; Written=6; Skipped=0 }
}
function Invoke-Trial([bool]$Confirmed=$true) {
    Invoke-IdentBookingTrial $plan -OperatorConfirmed:$Confirmed -Preflight { $ready } -Guard {
        $script:guardCount++
        if ($script:failGuardAt -eq $script:guardCount) { throw 'FILL_USER_ACTIVE' }
        if ($script:noisyCallbacks) { 'PRIVATE_GUARD_OUTPUT' }
    } -NavigateCalendar { $calls.Add('navigate_calendar'); if($failStage -eq 'navigate_calendar'){throw 'PRIVATE_EXCEPTION'}; $nav } `
      -OpenAppointment { $calls.Add('open_appointment'); if($failStage -eq 'open_appointment'){throw 'PRIVATE_EXCEPTION'}; $open } `
      -PreparePatient { $calls.Add('prepare_patient'); if($failStage -eq 'prepare_patient'){throw 'PRIVATE_EXCEPTION'}; $prepared } `
      -FillPatient { $calls.Add('fill_patient'); if($failStage -eq 'fill_patient'){throw 'PRIVATE_EXCEPTION'}; $fill } `
      -ReadFinal { $calls.Add('final_readback'); if($failStage -eq 'final_readback'){throw 'PRIVATE_EXCEPTION'}; $final } `
      -Journal { param($stage) $journals.Add($stage); if($failJournal -eq $stage){throw 'PRIVATE_JOURNAL_ERROR'}; if($noisyCallbacks){'PRIVATE_JOURNAL_OUTPUT'} }
}
Reset-Trial
$r=Invoke-Trial
Assert-Test ($r.Ok -and $r.State -ceq 'filled_not_saved' -and $r.Written -eq 6 -and $r.RequiresManualReview -and
    -not $r.ReadyForUnattendedExecution -and -not $r.SaveInvoked) 'Trial success is not a saved or unattended booking.'
Assert-Test (($calls -join ',') -ceq 'navigate_calendar,open_appointment,prepare_patient,fill_patient,final_readback' -and
    $r.StageAttempts -eq 4 -and $r.StagesReturned -eq 4 -and $r.CompletedStages.Count -eq 5) 'Trial order or stage counters changed.'
Assert-Test (($journals -join ',') -ceq 'navigate_calendar,open_appointment,prepare_patient,fill_patient,filled_not_saved') 'Every UI stage needs a prior receipt.'
Assert-Test (($r | ConvertTo-Json -Depth 6) -notmatch 'PRIVATE|Fixture|7999|root-1') 'Trial report leaked request or window data.'
Reset-Trial; $script:noisyCallbacks=$true; $r=@(Invoke-Trial)
Assert-Test ($r.Count -eq 1 -and $r[0].Ok -and ($r | ConvertTo-Json -Depth 6) -notmatch 'PRIVATE') 'Guard or journal output escaped into the trial report.'
Reset-Trial; $r=Invoke-Trial $false
Assert-Test ($r.ErrorCode -ceq 'BOOKING_TRIAL_CONSENT_REQUIRED' -and $calls.Count -eq 0 -and $journals.Count -eq 0) 'Trial ran without consent.'
foreach($flag in @('ReviewClear','NavigationSupported','PatientSupported')) {
    Reset-Trial; $ready.$flag=$false; $r=Invoke-Trial
    Assert-Test (-not $r.Ok -and $calls.Count -eq 0 -and $journals.Count -eq 0 -and -not $r.RequiresManualReview) ('Preflight ignored '+$flag)
}
$stages=@('navigate_calendar','open_appointment','prepare_patient','fill_patient','final_readback')
for($i=0;$i -lt $stages.Count;$i++) {
    Reset-Trial; $script:failStage=$stages[$i]; $r=Invoke-Trial
    Assert-Test (-not $r.Ok -and $r.FailurePhase -ceq $failStage -and $calls.Count -eq ($i+1) -and
        $r.RequiresManualReview -and -not $r.SaveInvoked -and ($r | ConvertTo-Json -Depth 6) -notmatch 'PRIVATE') 'Failed stage retried, continued, or leaked its exception.'
}
for($i=1;$i -le 11;$i++) {
    Reset-Trial; $script:failGuardAt=$i; $r=Invoke-Trial
    Assert-Test (-not $r.Ok -and $r.ErrorCode -ceq 'FILL_USER_ACTIVE' -and $guardCount -eq $i) 'Operator guard was bypassed.'
}
Reset-Trial; $nav.Date='2099-09-21'; $r=Invoke-Trial
Assert-Test ($r.ErrorCode -ceq 'BOOKING_TRIAL_NAVIGATION_FAILED' -and $calls.Count -eq 1) 'Wrong date reached appointment opening.'
Reset-Trial; $open.State='partial'; $r=Invoke-Trial
Assert-Test ($r.ErrorCode -ceq 'BOOKING_TRIAL_OPEN_FAILED' -and $calls.Count -eq 2) 'Unverified form reached patient input.'
Reset-Trial; $prepared.IdentityVerified=$false; $r=Invoke-Trial
Assert-Test ($r.ErrorCode -ceq 'BOOKING_TRIAL_PATIENT_FAILED' -and $calls.Count -eq 3) 'Ambiguous patient reached fill.'
Reset-Trial; $prepared.Snapshot.NotificationsOff=$false; $r=Invoke-Trial
Assert-Test ($r.ErrorCode -ceq 'FILL_UNSAFE_FORM' -and $calls.Count -eq 3) 'Enabled notifications reached fill.'
Reset-Trial; $fill.Ok=$false; $fill.State='partial'; $fill.Written=0; $fill.WriteAttempts=1; $fill.WriteReturned=1; $r=Invoke-Trial
Assert-Test ($r.ErrorCode -ceq 'BOOKING_TRIAL_FILL_FAILED' -and $r.WriteAttempts -eq 1 -and $r.Written -eq 0 -and $calls.Count -eq 4) 'Partial fill retried or reported success.'
foreach($role in @($plan.Fill.Values.Keys)) {
    Reset-Trial; $final.Fields[$role].Value='wrong'; $r=Invoke-Trial
    Assert-Test ($r.ErrorCode -ceq 'FILL_VALUE_MISMATCH' -and $r.FailurePhase -ceq 'final_readback' -and
        $journals[-1] -ceq 'fill_patient') 'Wrong final value reached completion.'
}
Reset-Trial; $final.RootIdentity='another-root'; $r=Invoke-Trial
Assert-Test ($r.ErrorCode -ceq 'FILL_FORM_CHANGED' -and -not $r.Ok) 'A different final form was accepted.'
foreach($item in @('nav','open','prepared','fill')) {
    Reset-Trial; (Get-Variable -Name $item -Scope Script).Value.SaveInvoked=$true; $r=Invoke-Trial
    Assert-Test ($r.ErrorCode -ceq 'BOOKING_TRIAL_UNEXPECTED_SAVE' -and $r.SaveInvoked -and -not $r.Ok) 'Unexpected save was concealed.'
}
Reset-Trial; $script:failJournal='navigate_calendar'; $r=Invoke-Trial
Assert-Test ($calls.Count -eq 0 -and $r.RequiresManualReview -and -not $r.Ok) 'Journal failure allowed input or discarded review requirement.'
foreach($field in @('doctorId','branchId')) {
    Reset-Trial; $request.$field=0; $failed=$false
    try { $null=New-IdentBookingTrialPlan $request } catch { $failed=$_.Exception.Message -ceq 'BOOKING_TRIAL_INVALID_REQUEST' }
    Assert-Test $failed 'Trial accepted an unverified doctor/branch identity.'
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ident-trial-test-'+[guid]::NewGuid().ToString('N'))
try {
    $r=Get-IdentBookingTrialHolds $root
    Assert-Test (-not $r.Ok -and -not $r.Holds[0].Readable) 'A missing robot directory was treated as clear.'
    $null=New-Item -ItemType Directory -Path $root
    $r=Get-IdentBookingTrialHolds $root
    Assert-Test ($r.Ok -and $r.Holds.Count -eq 0) 'Empty review directory rejected.'
    $id='00000000000000000000000000000001'
    $path=Join-Path $root 'fill-check-pending.json'
    @{runId=$id;stage='write_intent'} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    $hash=(Get-FileHash -LiteralPath $path).Hash
    $r=Get-IdentBookingTrialHolds $root
    Assert-Test (-not $r.Ok -and $r.Holds[0].RunId -ceq $id -and $r.Holds[0].Readable -and
        -not $r.Holds[0].ReportPresent -and (Get-FileHash -LiteralPath $path).Hash -ceq $hash) 'Missing report removed or guessed a receipt.'
    $reportFolder=Join-Path (Join-Path $root 'fill-checks') $id
    $null=New-Item -ItemType Directory -Path $reportFolder -Force
    @{State='partial'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $reportFolder 'result.json') -Encoding UTF8
    $r=Get-IdentBookingTrialHolds $root
    Assert-Test (-not $r.Ok -and $r.Holds[0].ReportPresent -and (Get-FileHash -LiteralPath $path).Hash -ceq $hash) 'Hold reader used a hardcoded run ID or modified evidence.'
    @{runId='../PRIVATE';stage='PRIVATE'} | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    $r=Get-IdentBookingTrialHolds $root
    Assert-Test (-not $r.Ok -and -not $r.Holds[0].Readable -and ($r | ConvertTo-Json -Depth 4) -notmatch 'PRIVATE') 'Malformed receipt escaped its report directory or leaked data.'
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if ($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'ident-trial-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host ('IDENT BOOKING TRIAL TESTS OK: '+$script:checks+' (orchestration and private receipt fixtures only; no UI adapter or input)')
