Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendar.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendarOpen.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendarInput.ps1')
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Message) { $script:checks++; if (-not $Condition) { throw $Message } }
function Reset-Test {
    $script:events=[Collections.Generic.List[string]]::new(); $script:fail=''; $script:guards=0
    $script:request=New-IdentCalendarRequest ([pscustomobject]@{ schemaVersion=1; purpose='ident-calendar-check'; doctorCaption='Sample O. M.';
        planStart='2099-09-20T09:00:00+05:00'; planEnd='2099-09-20T09:30:00+05:00'; doctorId=10; branchId=1; checkAvailability=$true })
    $script:checked=[pscustomobject]@{ Proof=[pscustomobject]@{ Ok=$true; AvailabilityVerified=$true; DoctorId=10; BranchId=1 };
        Snapshot=[pscustomobject]@{ Plan=[pscustomobject]@{ Ok=$true; Selection=[pscustomobject]@{ SlotCount=1; RequiresDrag=$false; X=951; StartY=325 } } } }
    $script:form=[pscustomobject]@{ Empty=$true; Bindings=[pscustomobject]@{ Ok=$true; Appointment=[pscustomobject]@{
        DoctorCaption='Sample O. M.'; Date='2099-09-20'; Start='09:00'; End='09:30' } } }
}
function Run-Open([bool]$Consent=$true) {
    return Invoke-IdentCalendarOpenCheck $request {
        $events.Add('preflight'); return $checked
    } {
        $script:guards++; $events.Add('guard')
        if ($fail -ceq ('guard-'+$guards)) { throw 'CALENDAR_USER_ACTIVE' }
    } {
        param($selection)
        $events.Add('right-click')
        Assert-Test ($selection.X -eq 951 -and $selection.StartY -eq 325) 'Click did not use the checked selection.'
        if ($fail -ceq 'click') { throw [InvalidOperationException]::new('wrapper',[Exception]::new('CALENDAR_INPUT_FAILED')) }
    } {
        $events.Add('read-menu')
        if ($fail -ceq 'menu') { return $null }
        return [pscustomobject]@{ Identity='fixture-menu' }
    } {
        param($menu,$verified)
        $events.Add('invoke-menu')
        if ($fail -ceq 'busy') { throw 'AVAILABILITY_BUSY' }
        if ($fail -ceq 'provider') { throw 'private patient text' }
    } {
        $events.Add('read-form'); return $form
    } {
        param($stage)
        $events.Add($stage)
        if ($fail -ceq 'journal') { throw 'CALENDAR_OPEN_REVIEW_PENDING' }
    } -OperatorConfirmed:$Consent
}
Reset-Test
$result=Run-Open
Assert-Test ($result.Ok -and $result.State -ceq 'opened_verified' -and $result.FormOpened -and $result.ActionsAttempted -eq 2 -and
    $result.ActionsReturned -eq 2 -and -not $result.SaveInvoked -and -not $result.ReadyForInput -and -not $result.RequiresManualReview) 'Supervised opening sequence failed.'
Assert-Test (($events -join ',') -ceq 'preflight,input_intent,guard,right-click,guard,read-menu,menu_invocation_intent,guard,invoke-menu,read-form,guard,opened_verified') 'Input must be journaled and guarded in order.'
Reset-Test; $result=Run-Open $false
Assert-Test ($result.ErrorCode -ceq 'CALENDAR_CONSENT_REQUIRED' -and $events.Count -eq 0) 'No consent should mean no input or scan.'
foreach($field in @('CheckAvailability','DoctorId','BranchId')) {
    Reset-Test; $request.$field=0; $result=Run-Open
    Assert-Test ($result.ErrorCode -ceq 'CALENDAR_INVALID_MODE' -and $events.Count -eq 0) 'Opening requires explicit IDs and live availability.'
}
Reset-Test; $checked.Proof.AvailabilityVerified=$false; $result=Run-Open
Assert-Test ($result.ErrorCode -ceq 'AVAILABILITY_INVALID_DATA' -and $result.ActionsAttempted -eq 0) 'Geometry cannot authorize opening.'
Reset-Test; $checked.Snapshot.Plan.Selection.RequiresDrag=$true; $result=Run-Open
Assert-Test ($result.ErrorCode -ceq 'CALENDAR_SINGLE_SLOT_ONLY' -and $result.ActionsAttempted -eq 0) 'Dragging must not happen in this release.'
Reset-Test; $checked.Snapshot.Plan.Selection.SlotCount=2; $result=Run-Open
Assert-Test ($result.ErrorCode -ceq 'CALENDAR_SINGLE_SLOT_ONLY') 'Multi-slot range accepted.'
foreach($case in @(
    @('guard-1','CALENDAR_USER_ACTIVE',0,0),
    @('click','CALENDAR_INPUT_FAILED',1,0),
    @('guard-2','CALENDAR_USER_ACTIVE',1,1),
    @('menu','CALENDAR_MENU_AMBIGUOUS',1,1),
    @('guard-3','CALENDAR_USER_ACTIVE',1,1),
    @('busy','AVAILABILITY_BUSY',2,1),
    @('provider','CALENDAR_OPEN_FAILED',2,1),
    @('guard-4','CALENDAR_USER_ACTIVE',2,2)
)) {
    Reset-Test; $script:fail=$case[0]; $result=Run-Open
    Assert-Test (-not $result.Ok -and $result.ErrorCode -ceq $case[1] -and $result.ActionsAttempted -eq $case[2] -and
        $result.ActionsReturned -eq $case[3] -and $result.RequiresManualReview -and -not $result.SaveInvoked -and
        @($events | Where-Object { $_ -eq 'right-click' }).Count -le 1 -and $events -notcontains 'opened_verified') ('Unsafe failure handling: '+$case[0])
}
Reset-Test; $form.Empty=$false; $result=Run-Open
Assert-Test ($result.ErrorCode -ceq 'CALENDAR_FORM_NOT_EMPTY' -and $result.RequiresManualReview) 'Buffered patient form accepted.'
foreach($field in @('DoctorCaption','Date','Start','End')) {
    Reset-Test; $form.Bindings.Appointment.$field='wrong'; $result=Run-Open
    Assert-Test ($result.ErrorCode -ceq 'CALENDAR_FORM_MISMATCH' -and -not $result.Ok) ('Wrong appointment '+$field+' accepted.')
}
Reset-Test; $script:fail='journal'; $result=Run-Open
Assert-Test ($result.ActionsAttempted -eq 0 -and $events -notcontains 'right-click') 'Journal failure must prevent input.'

# Compile and inspect the real interop definitions, but do not construct a guard, install hooks, or call SendInput.
Initialize-IdentCalendarInput
$expected=if ([IntPtr]::Size -eq 8) { 40 } else { 28 }
Assert-Test ([Runtime.InteropServices.Marshal]::SizeOf([type][Code9.CalendarInputGuard+Input]) -eq $expected) 'Win32 INPUT packing mismatch.'
Assert-Test ([Code9.CalendarInputGuard]::NormalizeCoordinate(-1920,-1920,3840) -ge 0) 'Negative-monitor normalization failed.'
Assert-Test ([Code9.CalendarInputGuard]::NormalizeCoordinate(1919,-1920,3840) -le 65535) 'Virtual desktop boundary overflow.'
foreach($point in @(-1921,1920)) {
    $rejected=$false
    try { $null=[Code9.CalendarInputGuard]::NormalizeCoordinate($point,-1920,3840) } catch { $rejected=$true }
    Assert-Test $rejected 'Out-of-screen point accepted.'
}
Write-Host ('IDENT CALENDAR OPEN TESTS OK: '+$script:checks+' (mock actions; interop compile only)')
