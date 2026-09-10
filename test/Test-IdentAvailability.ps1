Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $root 'robot/ident-rpa/IdentCalendar.ps1')
. (Join-Path $root 'robot/ident-rpa/IdentAvailability.ps1')
. (Join-Path $root 'robot/ident-rpa/IdentCalendarRuntime.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-calendar.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-availability.ps1')
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function New-Request([int]$Duration=30) {
    return New-IdentCalendarRequest ([pscustomobject]@{ schemaVersion=1; purpose='ident-calendar-check'; doctorCaption='Sample O. M.';
        planStart='2099-09-20T09:00:00+05:00'; planEnd=([DateTimeOffset]'2099-09-20T09:00:00+05:00').AddMinutes($Duration).ToString('yyyy-MM-ddTHH:mm:sszzz');
        doctorId=10; branchId=1; checkAvailability=$true })
}
function Assert-Rejected([object]$Snapshot,[string]$Code) {
    $proof=Get-IdentAvailabilityProof $Snapshot $request $plan
    Assert-Test (-not $proof.Ok -and -not $proof.AvailabilityVerified -and $proof.ErrorCode -ceq $Code) ('Expected '+$Code+', got '+$proof.ErrorCode)
}
$request=New-Request
$calendar=New-IdentCalendarFixture
$calendar[7].name='Sample O. M.'
$plan=New-IdentCalendarPlan $calendar $request
Assert-Test $plan.Ok 'Calendar fixture did not match.'
$snapshot=New-IdentAvailabilityFixture
$proof=Get-IdentAvailabilityProof $snapshot $request $plan
Assert-Test ($proof.Ok -and $proof.AvailabilityVerified -and -not $proof.ReadyForInput -and $proof.DoctorId -eq 10 -and
    $proof.BranchId -eq 1 -and $proof.ChairId -eq 2 -and $proof.SlotCount -eq 1) ('Free slot rejected: '+$proof.ErrorCode)
foreach($duration in @(120,360)) {
    $long=New-Request $duration
    $longPlan=$plan.PSObject.Copy(); $longPlan.DurationMinutes=$duration
    $proof=Get-IdentAvailabilityProof (New-IdentAvailabilityFixture) $long $longPlan
    Assert-Test ($proof.Ok -and $proof.SlotCount -eq $duration/30) 'Contiguous multi-slot coverage failed.'
}
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].IsBusy=$true
Assert-Rejected $snapshot 'AVAILABILITY_BUSY'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].IsWorkingTime=$false
Assert-Rejected $snapshot 'AVAILABILITY_NOT_WORKING'
$snapshot=New-IdentAvailabilityFixture; foreach($row in $snapshot.Rows){ $row.ChairArchived=$true }
Assert-Rejected $snapshot 'AVAILABILITY_NOT_WORKING'
$snapshot=New-IdentAvailabilityFixture; foreach($row in $snapshot.Rows){ $row.DoctorArchived=$true }
Assert-Rejected $snapshot 'AVAILABILITY_NOT_WORKING'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].DoctorId=$null
Assert-Rejected $snapshot 'AVAILABILITY_NOT_WORKING'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].DoctorId=20; $snapshot.Rows[0].DoctorFirstName='Peter'
Assert-Rejected $snapshot 'AVAILABILITY_WRONG_DOCTOR'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows=@($snapshot.Rows | Select-Object -Skip 1)
Assert-Rejected $snapshot 'AVAILABILITY_GAP'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].TimeEnd=[timespan]::FromMinutes(555)
Assert-Rejected $snapshot 'AVAILABILITY_GAP'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].TimeStart=[timespan]::FromMinutes(525)
Assert-Rejected $snapshot 'AVAILABILITY_SPLIT_REQUIRED'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].TimeEnd=[timespan]::FromMinutes(585)
Assert-Rejected $snapshot 'AVAILABILITY_SPLIT_REQUIRED'
$snapshot=New-IdentAvailabilityFixture; $copy=$snapshot.Rows[0].PSObject.Copy(); $copy.SlotId=999; $snapshot.Rows+= $copy
Assert-Rejected $snapshot 'AVAILABILITY_CONFLICT'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows+= $snapshot.Rows[0]
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].DoctorFirstName='Different'
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].BranchId=2
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$snapshot=New-IdentAvailabilityFixture; $copy=$snapshot.Rows[0].PSObject.Copy(); $copy.SlotId=999; $copy.DoctorId=999; $snapshot.Rows+= $copy
Assert-Rejected $snapshot 'AVAILABILITY_IDENTITY_AMBIGUOUS'
$snapshot=New-IdentAvailabilityFixture; $copy=$snapshot.Rows[0].PSObject.Copy(); $copy.SlotId=999; $copy.ChairId=999; $snapshot.Rows+= $copy
Assert-Rejected $snapshot 'AVAILABILITY_IDENTITY_AMBIGUOUS'
$snapshot=New-IdentAvailabilityFixture; $snapshot.CapturedAt=[DateTimeOffset]::UtcNow.AddSeconds(-16)
Assert-Rejected $snapshot 'AVAILABILITY_STALE'
$snapshot.CapturedAt=[DateTimeOffset]::UtcNow.AddSeconds(60)
Assert-Rejected $snapshot 'AVAILABILITY_STALE'
$snapshot=New-IdentAvailabilityFixture; $snapshot.CapturedAt=$snapshot.CapturedAt.ToString('o')
Assert-Rejected $snapshot 'AVAILABILITY_STALE'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Source='cached-timetable'
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
foreach($bad in @($null,'false','0',0)) {
    $snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].IsBusy=$bad
    Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
}
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].SlotVersion=[byte[]]@(1,2)
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].WorkDate=[datetime]'2099-09-21'
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$snapshot=New-IdentAvailabilityFixture; $snapshot.Rows[0].TimeStart=[timespan]::FromMinutes(541)
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$wrong=$request.PSObject.Copy(); $wrong.DoctorId=999
$proof=Get-IdentAvailabilityProof (New-IdentAvailabilityFixture) $wrong $plan
Assert-Test ($proof.ErrorCode -ceq 'AVAILABILITY_WRONG_DOCTOR') 'Wrong requested doctor ID accepted.'
$wrong=$request.PSObject.Copy(); $wrong.BranchId=999
$proof=Get-IdentAvailabilityProof (New-IdentAvailabilityFixture) $wrong $plan
Assert-Test ($proof.ErrorCode -ceq 'AVAILABILITY_WRONG_BRANCH') 'Wrong requested branch ID accepted.'
$quoted=$plan.PSObject.Copy(); $quoted.Selection=$plan.Selection.PSObject.Copy()
$quoted.Selection.ChairCaption=[regex]::Unescape('\u041a\u0440\u0435\u0441\u043b\u043e "Surgery"')
$snapshot=New-IdentAvailabilityFixture; foreach($row in $snapshot.Rows){ $row.ChairName='Surgery' }
$proof=Get-IdentAvailabilityProof $snapshot $request $quoted
Assert-Test $proof.Ok 'Exact quoted IDENT chair caption should match its database name.'
$snapshot.Rows[0].ChairName='Another'
Assert-Rejected $snapshot 'AVAILABILITY_INVALID_DATA'
$ui=[pscustomobject]@{ GridIdentity='fixture'; Plan=$plan }
$result=Invoke-IdentCalendarReadCheck { $ui } { New-IdentAvailabilityFixture } $request
Assert-Test ($result.Ok -and $result.State -ceq 'available_read_only' -and $result.AvailabilityVerified -and
    -not $result.ReadyForInput -and $result.ActionsExecuted -eq 0) 'Live availability not integrated into read check.'
$script:reads=0
$result=Invoke-IdentCalendarReadCheck { $ui } {
    $script:reads++; $s=New-IdentAvailabilityFixture
    if ($script:reads -eq 2) { $s.Rows[0].SlotVersion[7]=99 }
    return $s
} $request
Assert-Test ($result.ErrorCode -ceq 'AVAILABILITY_CHANGED' -and -not $result.Ok) 'Version changed between database reads.'
$script:reads=0
$result=Invoke-IdentCalendarReadCheck { $ui } {
    $script:reads++; $s=New-IdentAvailabilityFixture
    if ($script:reads -eq 2) { $s.Rows[0].IsBusy=$true }
    return $s
} $request
Assert-Test ($result.ErrorCode -ceq 'AVAILABILITY_BUSY' -and -not $result.Ok) 'Concurrent booking was ignored.'
$result=Invoke-IdentCalendarReadCheck { $ui } { throw 'AVAILABILITY_QUERY_FAILED' } $request
Assert-Test ($result.ErrorCode -ceq 'AVAILABILITY_QUERY_FAILED') 'Database failures should not fall back to old availability.'

# Library import must not resolve configuration, connect, upload, discover, or exit the caller.
& {
    . (Join-Path $root 'agent/ident-db-agent/IdentAgent.ps1') -LibraryOnly -ConfigPath 'does-not-exist.json'
    $sql=Get-IdentAvailabilitySql
    $null=Assert-ReadOnlySql $sql 'availability-test'
    Assert-Test ($sql -match '@WorkDate' -and $sql -match 'TOP \(5001\)' -and $sql -match 'MAXDOP 1' -and
        $sql -notmatch '(?i)NOLOCK|SELECT\s+\*|JOIN\s+dbo\.(Patients|Receptions)|IsWorkingTime\s*=\s*1') 'SQL scope/safety contract changed.'
    Assert-Test ($null -ne (Get-Command Invoke-SqlQuery).Parameters['Parameters']) 'Typed query parameters missing.'
}
$failed=$false
try { $null=Get-IdentAvailabilitySnapshot (Join-Path $PSScriptRoot 'missing-agent-directory') $request }
catch { $failed=$_.Exception.Message -ceq 'AVAILABILITY_QUERY_FAILED' }
Assert-Test $failed 'Provider/configuration failures leaked or fell back.'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('ident-availability-test-'+[guid]::NewGuid().ToString('N'))
try {
    $null=New-Item -ItemType Directory -Path $temporary
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/availability-agent.ps1') -Destination (Join-Path $temporary 'IdentAgent.ps1')
    $snapshot=Get-IdentAvailabilitySnapshot $temporary $request
    Assert-Test ($snapshot.Rows.Count -eq 12 -and $snapshot.Rows[0].SlotVersion -is [byte[]] -and
        $snapshot.Rows[0].IsBusy -is [bool] -and $snapshot.Rows[0].TimeStart -is [timespan]) 'ADO.NET types were lost while copying rows.'
    $proof=Get-IdentAvailabilityProof $snapshot $request $plan
    Assert-Test $proof.Ok 'Real snapshot adapter failed typed DataTable fixture.'
} finally {
    $resolved=[IO.Path]::GetFullPath($temporary)
    if ((Split-Path -Parent $resolved) -ieq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -and
        (Split-Path -Leaf $resolved) -like 'ident-availability-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host ('IDENT AVAILABILITY TESTS OK: '+$script:checks+' (synthetic rows; no SQL connection)')
