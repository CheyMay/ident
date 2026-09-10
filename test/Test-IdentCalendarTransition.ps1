Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendar.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendarOpen.ps1')
. (Join-Path $repo 'test/fixtures/ident-calendar.ps1')
$checks=0
function Assert-Test([bool]$Condition,[string]$Message) { $script:checks++; if (-not $Condition) { throw $Message } }
$request=New-IdentCalendarRequest ([pscustomobject]@{ schemaVersion=1; purpose='ident-calendar-check'; doctorCaption='Doctor B';
    planStart='2099-09-20T09:00:00+05:00'; planEnd='2099-09-20T09:30:00+05:00' })
function Snapshot([object[]]$Rows) { return [pscustomobject]@{ GridIdentity='fixture-grid'; Plan=(New-IdentCalendarPlan $Rows $request) } }
$before=Snapshot (New-IdentCalendarFixture)
Assert-Test $before.Plan.Ok 'Fixture plan must be valid.'
$same=Compare-IdentCalendarMenuTransition $before (Snapshot (New-IdentCalendarFixture))
Assert-Test ($same.Ok -and $same.Reason -ceq 'unchanged' -and -not $same.FullTreeChanged) 'Unchanged calendar rejected.'

# Incidental state may change after right-click, never during the strict preflight comparison.
foreach($kind in @('grid-name','scroll-button','scroll-thumb')) {
    $rows=New-IdentCalendarFixture
    switch($kind) {
        'grid-name' { $rows[0].name='selection changed'; foreach($row in $rows){$row.rootName='selection changed'} }
        'scroll-button' { ($rows | Where-Object path -eq '0/50/1').isEnabled=$false }
        'scroll-thumb' { ($rows | Where-Object path -eq '0/50/3').bounds='1899,177,14,610' }
    }
    $after=Snapshot $rows; $result=Compare-IdentCalendarMenuTransition $before $after
    Assert-Test ($after.Plan.Ok -and $result.Ok -and $result.FullTreeChanged -and $result.Reason -ceq 'incidental_tree_changed') ('Incidental transition rejected: '+$kind)
    Assert-Test ($before.Plan.Fingerprint -cne $after.Plan.Fingerprint) 'Strict preflight fingerprint was weakened.'
}
foreach($kind in @('grid-bounds','date','chair','doctor','other-doctor','label-path','label-bounds','label-disabled','label-hidden','scroll','target','identity','missing-proof')) {
    $rows=New-IdentCalendarFixture
    switch($kind) {
        'grid-bounds' { $rows[0].bounds='514,153,1406,854' }
        'date' { ($rows | Where-Object path -eq '0/0').name='21.09.2099' }
        'chair' { ($rows | Where-Object path -eq '0/2').name='Chair X' }
        'doctor' { ($rows | Where-Object path -eq '0/6').name='Doctor X' }
        'other-doctor' { ($rows | Where-Object path -eq '0/4').name='Doctor X' }
        'label-path' { ($rows | Where-Object path -eq '0/4').path='0/90' }
        'label-bounds' { ($rows | Where-Object path -eq '0/4').bounds='592,268,233,23' }
        'label-disabled' { ($rows | Where-Object path -eq '0/4').isEnabled=$false }
        'label-hidden' { ($rows | Where-Object path -eq '0/4').isOffscreen=$true }
        'scroll' {
            foreach($row in $rows | Where-Object name -match '^\d{2}:\d{2}$') {
                $bounds=$row.bounds.Split(','); $bounds[1]=[string]([int]$bounds[1]+10); $row.bounds=$bounds -join ','
            }
        }
    }
    $after=Snapshot $rows
    if ($kind -eq 'target') { $after.Plan.ContextParts.Selection='A'*64 }
    if ($kind -eq 'identity') { $after.GridIdentity='replaced-grid' }
    if ($kind -eq 'missing-proof') { $after.Plan.ContextParts=$null }
    $result=Compare-IdentCalendarMenuTransition $before $after
    Assert-Test (-not $result.Ok) ('Unsafe transition accepted: '+$kind)
    Assert-Test ($result.Reason -cnotmatch 'Doctor |Chair |2099|1899') 'Report exposed a UI value.'
}
$after=Snapshot (New-IdentCalendarFixture); $after.Plan.Ok=$false; $after.Plan.ErrorCode='private patient text'
$result=Compare-IdentCalendarMenuTransition $before $after
Assert-Test ($result.Reason -ceq 'plan_rejected') 'Provider error text leaked.'
$after.Plan.ErrorCode='CALENDAR_TIME_AXIS'
$result=Compare-IdentCalendarMenuTransition $before $after
Assert-Test ($result.Reason -ceq 'CALENDAR_TIME_AXIS') 'Safe plan rejection detail lost.'

# Exercise the production callback ordering with mock SQL/UI/input; journal files are real temporary data.
function Assert-IdentCalendarOpenOperator($Context) { }
function Get-IdentCalendarPreflight($Reader,$AvailabilityReader,$Request) { return $script:checked }
function Get-IdentAvailabilitySnapshot($Directory,$Request) { return 'mock-live-snapshot' }
function Get-IdentAvailabilityProof($Snapshot,$Request,$Plan) { return $script:checked.Proof }
function Get-IdentCalendarRuntimeSnapshot($Context) { return $script:runtimeAfter }
function Get-IdentCalendarOpenMenu($Context) { return $script:runtimeMenu }
function Read-IdentCalendarOpenedForm($Context) {
    return [pscustomobject]@{ Empty=$true; Bindings=[pscustomobject]@{ Ok=$true; Appointment=[pscustomobject]@{
        DoctorCaption='Doctor B'; Date='2099-09-20'; Start='09:00'; End='09:30' } } }
}
function Write-JsonFileAtomic($Path,$Value) { $Value | ConvertTo-Json | Set-Content -LiteralPath $Path -Encoding UTF8 }
$request.CheckAvailability=$true; $request.DoctorId=10; $request.BranchId=1
$directory=Join-Path ([IO.Path]::GetTempPath()) ('ident-calendar-transition-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
$pending=Join-Path $directory 'calendar-open-pending.json'
try {
    foreach($kind in @('unchanged','incidental','changed','rejected')) {
        $script:checked=[pscustomobject]@{ Snapshot=$before; Proof=[pscustomobject]@{ Ok=$true; AvailabilityVerified=$true;
            DoctorId=10; BranchId=1; Fingerprint='mock-availability' } }
        $rows=New-IdentCalendarFixture
        if ($kind -eq 'incidental') { ($rows | Where-Object path -eq '0/50/1').isEnabled=$false }
        if ($kind -eq 'changed') { ($rows | Where-Object path -eq '0/4').name='Doctor X' }
        if ($kind -eq 'rejected') { ($rows | Where-Object path -eq '0/0').name='21.09.2099' }
        $script:runtimeAfter=Snapshot $rows
        $pattern=[pscustomobject]@{ Calls=0; PendingPath=$pending; ArmedBeforeInvoke=$false }
        $pattern | Add-Member ScriptMethod Invoke {
            $this.ArmedBeforeInvoke=(Get-Content -LiteralPath $this.PendingPath -Raw | ConvertFrom-Json).stage -ceq 'menu_invoke_armed'
            $this.Calls++
        }
        $script:runtimeMenu=[pscustomobject]@{Identity='menu';ItemIdentity='item';Name='mock-new-appointment';Bounds='10,10,100,30';Pattern=$pattern}
        $input=[pscustomobject]@{Clicks=0;LastOwnTick=1}
        $input | Add-Member ScriptMethod RightClick {param($X,$Y,$Handle,$ProcessId,$Tick) $this.Clicks++}
        $context=[pscustomobject]@{Directory=$directory;Request=$request;InputGuard=$input;InputTick=0;Handle=1;ProcessId=2}
        $result=Invoke-IdentSupervisedCalendarOpen $context $directory ([guid]::NewGuid().ToString('N')) {} {}
        Assert-Test ($input.Clicks -eq 1 -and -not $result.SaveInvoked -and -not $result.ReadyForInput) 'Wrong production input scope.'
        if ($kind -in @('unchanged','incidental')) {
            Assert-Test ($result.Ok -and $pattern.Calls -eq 1 -and $pattern.ArmedBeforeInvoke -and $result.MenuInvokeAttempted -and
                -not (Test-Path -LiteralPath $pending)) ('Verified callback transition failed: '+$kind+' '+$result.ErrorCode)
        } else {
            Assert-Test (-not $result.Ok -and $pattern.Calls -eq 0 -and -not $result.MenuInvokeAttempted -and
                $result.ActionsAttempted -eq 2 -and $result.ActionsReturned -eq 1 -and $result.FailurePhase -ceq 'menu_recheck') 'Changed calendar reached menu invocation.'
            $receipt=Get-Content -LiteralPath $pending -Raw | ConvertFrom-Json
            Assert-Test ($receipt.stage -ceq 'menu_invocation_intent' -and $receipt.requiresManualReview) 'Failure receipt was removed or advanced.'
            Assert-Test ($null -ne $result.CalendarRecheck -and -not $result.CalendarRecheck.Ok) 'Comparison reason missing.'
            Remove-Item -LiteralPath $pending
        }
    }
} finally {
    if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
    Remove-Item -LiteralPath $directory
}
Write-Host ('IDENT CALENDAR TRANSITION TESTS OK: '+$checks+' (synthetic transitions; no desktop input)')
