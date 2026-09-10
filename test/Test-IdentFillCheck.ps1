Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentFillCheck.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-patient-form.ps1')
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
function Request {
    return [pscustomobject]@{ schemaVersion=1; purpose='ident-patient-fill-test'; doctorCaption='Fixture D. A.';
        planStart='2099-09-20T09:00:00+05:00'; planEnd='2099-09-20T09:45:00+05:00';
        patient=[pscustomobject]@{ surname='Fixture'; name='Test'; patronymic='Example'; phone='+79990000000'; birthDate='1990-01-01' };
        comment='Synthetic test only' }
}
function Reset-State {
    $script:plan=New-IdentFillCheckPlan (Request)
    $script:form=Get-IdentPatientFormBindings @(New-IdentPatientFormFixture -Expanded)
    $script:values=@{}; $script:ids=@{}
    foreach($role in $plan.Values.Keys) { $script:values[$role]=''; $script:ids[$role]='runtime-'+$role }
    $script:values.patientPhoneInput='+7 (***) ***-**-**'; $script:values.patientBirthDateInput='00.00.0000'
    $script:rootId='root'; $script:notifications=$true; $script:readOnly=$false
    $script:reads=0; $script:writes=0; $script:journals=0
    $script:events=New-Object 'System.Collections.Generic.List[string]'
    $script:onRead={}; $script:onWrite={}; $script:onJournal={}
}
$reader={
    $script:reads++; & $script:onRead
    $fields=[ordered]@{}
    foreach($role in $script:plan.Values.Keys) {
        $fields[$role]=[pscustomobject]@{ Identity=$script:ids[$role]; Value=$script:values[$role]; ReadOnly=$script:readOnly }
    }
    return [pscustomobject]@{ Form=$script:form; RootIdentity=$script:rootId; NotificationsOff=$script:notifications; Fields=$fields }
}
$writer={ param($role,$value,$snapshot)
    $script:writes++; $script:events.Add('write'); & $script:onWrite
    $script:values[$role]=$value
}
$journal={ param($stage,$attempts)
    $script:journals++; $script:events.Add($stage); & $script:onJournal
}
function Run { Invoke-IdentFillCheck $script:plan $reader $writer $journal -Execute -OperatorConfirmed }
function Rejected([string]$Code) {
    $result=Run
    Assert (-not $result.Ok -and $result.ErrorCode -ceq $Code -and $script:writes -eq 0) ('Expected no-write rejection: '+$Code+'; got '+$result.ErrorCode)
}
Reset-State
$r=Invoke-IdentFillCheck $plan $reader $writer $journal
Assert ($r.Ok -and $r.State -ceq 'preview' -and $writes -eq 0 -and $journals -eq 0) 'Default must only preview.'
$r=Invoke-IdentFillCheck $plan $reader $writer $journal -Execute
Assert ($r.ErrorCode -ceq 'FILL_CONSENT_REQUIRED' -and $writes -eq 0) 'Missing consent accepted.'
Reset-State; $r=Run
Assert ($r.Ok -and $r.Written -eq 6 -and $r.WriteAttempts -eq 6 -and $r.State -ceq 'filled_not_saved' -and
    -not $r.SaveInvoked -and -not $r.ReadyForUnattendedExecution -and $r.RequiresManualReview) 'Fill result is not guarded.'
Assert (($events -join ',') -ceq 'write_intent,write,write_intent,write,write_intent,write,write_intent,write,write_intent,write,write_intent,write,filled') 'Journal must precede every write.'
Reset-State
foreach($role in $plan.Values.Keys) { $values[$role]=$plan.Values[$role] }
$values.patientPhoneInput='8 (999) 000-00-00'
$r=Run
Assert ($r.Ok -and $writes -eq 0 -and $r.Skipped -eq 6) 'Already matching values should not be entered again.'
Reset-State; $plan.Values.patientMiddleNameInput=''; $plan.Values.commentInput=''; $r=Run
Assert ($r.Ok -and $r.Written -eq 4 -and $r.Skipped -eq 2) 'Empty optional values are mishandled.'
foreach($role in (New-IdentFillCheckPlan (Request)).Values.Keys) {
    Reset-State; $values[$role]='UNRELATED_EXISTING_VALUE'; Rejected 'FILL_EXISTING_VALUE'
}
Reset-State; $form=Get-IdentPatientFormBindings @(New-IdentPatientFormFixture); Rejected 'FILL_UNSAFE_FORM'
Reset-State; $notifications=$false; Rejected 'FILL_UNSAFE_FORM'
Reset-State; $readOnly=$true; Rejected 'FILL_UNSAFE_FORM'
Reset-State; $ids.patientFirstNameInput=$ids.patientLastNameInput; Rejected 'FILL_UNSAFE_FORM'
Reset-State; $onRead={ if ($script:reads -eq 2) { $script:rootId='different' } }; Rejected 'FILL_FORM_CHANGED'
Reset-State; $onRead={ if ($script:reads -eq 2) { $script:ids.patientFirstNameInput='different' } }; Rejected 'FILL_FORM_CHANGED'
Reset-State; $onRead={ if ($script:reads -eq 2) { throw 'FILL_USER_ACTIVE' } }; Rejected 'FILL_USER_ACTIVE'
Reset-State; $plan.DoctorCaption='Other D. A.'; Rejected 'IDENT_FORM_CONTEXT_MISMATCH'
Reset-State; $plan.End=$plan.End.AddMinutes(15); Rejected 'IDENT_FORM_CONTEXT_MISMATCH'
Reset-State; $plan.Start=[DateTimeOffset]::Now.AddMinutes(-1); Rejected 'FILL_EXPIRED'
Reset-State; $onJournal={ throw 'PRIVATE_PROVIDER_DETAIL' }; Rejected 'FILL_CHECK_FAILED'
Reset-State; $onWrite={ throw 'PRIVATE_PROVIDER_DETAIL' }; $r=Run
Assert ($r.State -eq 'partial' -and $r.RequiresManualReview -and $r.WriteAttempts -eq 1 -and $r.Written -eq 0 -and
    $writes -eq 1 -and $r.ErrorCode -eq 'FILL_CHECK_FAILED' -and ($r | ConvertTo-Json) -notmatch 'PRIVATE') 'Setter exception was retried or leaked.'
Reset-State; $onRead={ if ($script:reads -eq 3) { $script:values.patientLastNameInput='WRONG' } }; $r=Run
Assert ($r.ErrorCode -eq 'FILL_VALUE_MISMATCH' -and $writes -eq 1 -and $r.RequiresManualReview) 'Readback mismatch did not stop.'
Reset-State; $onRead={ if ($script:reads -eq 3) { $script:values.patientFirstNameInput='AUTOFILL' } }; $r=Run
Assert ($r.ErrorCode -eq 'FILL_FORM_CHANGED' -and $writes -eq 1) 'Unexpected autofill did not stop.'
Reset-State; $onRead={ if ($script:reads -eq 4) { throw 'FILL_WINDOW_CHANGED' } }; $r=Run
Assert ($r.ErrorCode -eq 'FILL_WINDOW_CHANGED' -and $writes -eq 1) 'Foreground change did not stop.'
Reset-State; $onWrite={ if ($script:writes -eq 2) { throw 'FILL_USER_ACTIVE' } }; $r=Run
Assert ($r.ErrorCode -eq 'FILL_USER_ACTIVE' -and $r.WriteAttempts -eq 2 -and $r.Written -eq 1 -and $writes -eq 2) 'Partial input was retried.'
foreach($change in @(
    { $q.purpose='booking' }, { $q.schemaVersion=2 }, { $q.planStart='2099-09-20T09:00:00' },
    { $q.planStart='2099-09-20T09:00:01+05:00' }, { $q.planEnd='2099-09-20T15:15:00+05:00' },
    { $q.planEnd='2099-09-21T09:45:00+05:00' }, { $q.planEnd='2099-09-20T09:45:00+03:00' },
    { $q.patient.surname='' }, { $q.patient.name="bad`nname" }, { $q.patient.phone='+19990000000' },
    { $q.patient.birthDate='2099-01-01' }, { $q.patient.birthDate='2001-02-29' }, { $q.comment=('X'*1001) }
)) {
    $q=Request; & $change; $rejected=$false
    try { $null=New-IdentFillCheckPlan $q } catch { $rejected=$_.Exception.Message -ceq 'FILL_INVALID_REQUEST' }
    Assert $rejected 'Invalid request accepted or request details leaked.'
}
$q=Request; $q.planEnd='2099-09-20T15:00:00+05:00'; $null=New-IdentFillCheckPlan $q
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ident-fill-check-test-'+[guid]::NewGuid().ToString('N'))
try {
    $robot=Join-Path $temp 'robot'; $null=New-Item -ItemType Directory -Path $robot
    @{ features=@{ robotEnabled=$false } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'config.local.json') -Encoding UTF8
    Assert-IdentFillCheckInstallation $robot -Execute
    $null=New-Item -ItemType File -Path (Join-Path $robot 'fill-check-pending.json')
    $rejected=$false
    try { Assert-IdentFillCheckInstallation $robot -Execute } catch { $rejected=$_.Exception.Message -ceq 'FILL_REVIEW_PENDING' }
    Assert $rejected 'A pending fill test allowed another execution.'
    Assert-IdentFillCheckInstallation $robot
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'agent/ident-db-agent/IdentWorker.ps1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-RobotConfigurationProblem' },$true)
    Invoke-Expression $fn.Extent.Text
    $script:Context=@{ RobotConfigPath=(Join-Path $robot 'config.local.json') }
    Assert ((Get-RobotConfigurationProblem) -like 'FILL_REVIEW_PENDING:*') 'Worker did not stop at pending fill review.'
    Remove-Item -LiteralPath (Join-Path $robot 'fill-check-pending.json')
    @{ features=@{ robotEnabled=$true } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $temp 'config.local.json') -Encoding UTF8
    $rejected=$false
    try { Assert-IdentFillCheckInstallation $robot } catch { $rejected=$_.Exception.Message -ceq 'FILL_ROBOT_ENABLED' }
    Assert $rejected 'Enabled robot allowed a supervised test.'
} finally {
    $resolved=[IO.Path]::GetFullPath($temp)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'ident-fill-check-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'IDENT FILL CHECK TESTS OK (synthetic data; no IDENT input or save)'
