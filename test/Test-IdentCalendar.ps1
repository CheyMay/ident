Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $root 'robot/ident-rpa/IdentCalendar.ps1')
. (Join-Path $root 'robot/ident-rpa/IdentCalendarRuntime.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-calendar.ps1')
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Message) {
    $script:checks++
    if (-not $Condition) { throw $Message }
}
function New-TestRequest([string]$Start='09:00',[int]$Duration=30,[string]$Doctor='Doctor B') {
    $startValue=[DateTimeOffset]::Parse('2099-09-20T'+$Start+':00+05:00',[Globalization.CultureInfo]::InvariantCulture)
    return New-IdentCalendarRequest ([pscustomobject]@{ schemaVersion=1; purpose='ident-calendar-check'; doctorCaption=$Doctor;
        planStart=$startValue.ToString('yyyy-MM-ddTHH:mm:sszzz'); planEnd=$startValue.AddMinutes($Duration).ToString('yyyy-MM-ddTHH:mm:sszzz') })
}
function Assert-Rejected([object[]]$Rows,[object]$Request,[string]$Code) {
    $plan=New-IdentCalendarPlan $Rows $Request
    Assert-Test (-not $plan.Ok -and $plan.ErrorCode -ceq $Code -and $null -eq $plan.Selection -and -not $plan.ReadyForInput) ('Expected '+$Code+', got '+$plan.ErrorCode)
}
$rows=New-IdentCalendarFixture
Assert-Test ($rows.Count -eq 57) 'Recovered geometry fixture must contain the grid plus 56 descendants.'
$request=New-TestRequest
$plan=New-IdentCalendarPlan $rows $request
Assert-Test $plan.Ok ('30 minute plan rejected: '+$plan.ErrorCode)
Assert-Test ($plan.Selection.X -eq 951 -and $plan.Selection.StartY -eq 325 -and $plan.Selection.LastY -eq 325) 'Wrong doctor column or row center.'
Assert-Test ($plan.Selection.SlotCount -eq 1 -and -not $plan.Selection.RequiresDrag) 'One slot must not need a drag.'
Assert-Test (-not $plan.AvailabilityVerified -and -not $plan.ReadyForInput -and -not $plan.ReadyForUnattendedExecution) 'Geometry does not authorize booking.'
$liveRows=@(ConvertTo-IdentCalendarScannerRows $rows)
$live=New-IdentCalendarPlan $liveRows $request
Assert-Test $live.Ok ('Live scanner dictionaries rejected: '+$live.ErrorCode)
Assert-Test ($live.Fingerprint -ceq $plan.Fingerprint -and
    ($live.ContextParts | ConvertTo-Json -Compress) -ceq ($plan.ContextParts | ConvertTo-Json -Compress) -and
    ($live.PathParts | ConvertTo-Json -Compress) -ceq ($plan.PathParts | ConvertTo-Json -Compress)) 'Live and JSON row formats must prove the same content.'
Assert-Test ($liveRows[0] -is [Collections.Specialized.OrderedDictionary] -and $liveRows[1].name -ceq $rows[1].name) 'Planner mutated the caller scan.'
Assert-Test (@($live.TargetAnchors | Where-Object { -not $_.Node.name -or -not $_.Node.bounds -or $_.Occurrences -ne 1 }).Count -eq 0 -and
    $live.TargetAnchors.Count -eq 7 -and $live.LabelCount -eq $plan.LabelCount) 'Live target labels lost their values or uniqueness.'
$liveRows[0].bounds='514,153,1406,854'
$liveChanged=New-IdentCalendarPlan $liveRows $request
Assert-Test ($liveChanged.Ok -and $liveChanged.Fingerprint -cne $live.Fingerprint -and
    $liveChanged.ContextParts.Grid -cne $live.ContextParts.Grid) 'Live grid geometry must affect the strict proofs.'
$liveRows=@(ConvertTo-IdentCalendarScannerRows $rows)
$liveRows[1].rootName='other root'
Assert-Rejected $liveRows $request 'CALENDAR_INVALID_TREE'
$liveRows=@(ConvertTo-IdentCalendarScannerRows $rows)
$liveRows[1].path=$liveRows[2].path
Assert-Rejected $liveRows $request 'CALENDAR_INVALID_TREE'
$liveRows=@(ConvertTo-IdentCalendarScannerRows $rows)
$liveRows[7].name='Wrong doctor'
Assert-Rejected $liveRows $request 'CALENDAR_DOCTOR_AMBIGUOUS'
$mixedRows=@($rows)
$mixedRows[0]=$liveRows[0]
$mixed=New-IdentCalendarPlan $mixedRows $request
Assert-Test ($mixed.Ok -and $mixed.Fingerprint -ceq $plan.Fingerprint) 'Mixed dictionary and object scan rejected.'
$long=New-IdentCalendarPlan $rows (New-TestRequest '09:00' 120)
Assert-Test ($long.Ok -and $long.Selection.SlotCount -eq 4 -and $long.Selection.LastY -eq 460 -and $long.Selection.RequiresDrag) 'Drag endpoint must be the last included cell, not the end boundary.'
$afternoon=New-IdentCalendarPlan $rows (New-TestRequest '14:00' 60 'Doctor E')
Assert-Test ($afternoon.Ok -and $afternoon.Selection.StartY -eq 825) 'Afternoon header must start a separate band.'
Assert-Rejected $rows (New-TestRequest '09:00' 45) 'CALENDAR_SPLIT_REQUIRED'
Assert-Rejected $rows (New-TestRequest '09:15' 30) 'CALENDAR_SPLIT_REQUIRED'
Assert-Rejected $rows (New-TestRequest '08:30') 'CALENDAR_SCROLL_REQUIRED'
Assert-Rejected $rows (New-TestRequest '15:30' 30 'Doctor E') 'CALENDAR_SCROLL_REQUIRED'
Assert-Rejected $rows (New-TestRequest '14:00' 30 'Doctor B') 'CALENDAR_DOCTOR_AMBIGUOUS'
Assert-Rejected $rows (New-TestRequest '13:30' 60) 'CALENDAR_SHIFT_BOUNDARY'
Assert-Rejected $rows (New-TestRequest '13:30' 30) 'CALENDAR_SHIFT_BOUNDARY'
Assert-Rejected $rows (New-TestRequest '09:00' 360) 'CALENDAR_SHIFT_BOUNDARY'
$changed=New-IdentCalendarFixture
$changed[1].name='21.09.2099'
Assert-Rejected $changed $request 'CALENDAR_WRONG_DATE'
$changed[1].name='20 September'
Assert-Rejected $changed $request 'CALENDAR_DATE_UNREADABLE'
$russian=[regex]::Unescape('20 \u0441\u0435\u043d 2099')
Assert-Test ((ConvertFrom-IdentCalendarDate $russian) -ceq '2099-09-20') 'Observed IDENT September abbreviation must parse.'
Assert-Test ((ConvertFrom-IdentCalendarDate ('20.09.2099 '+[regex]::Unescape('\u0432\u043e\u0441\u043a\u0440\u0435\u0441\u0435\u043d\u044c\u0435'))) -ceq '2099-09-20') 'Full visible date with weekday must parse.'
Assert-Test ($null -eq (ConvertFrom-IdentCalendarDate '31.02.2099')) 'Invalid calendar date accepted.'
$changed=New-IdentCalendarFixture
$changed[9].name='Doctor B'
Assert-Rejected $changed $request 'CALENDAR_DOCTOR_AMBIGUOUS'
$changed=New-IdentCalendarFixture
$changed[3].bounds='800,217,233,23'
Assert-Rejected $changed $request 'CALENDAR_COLUMNS_AMBIGUOUS'
$changed=New-IdentCalendarFixture
$changed[12].name='09:15'
Assert-Rejected $changed $request 'CALENDAR_TIME_AXIS'
$changed=New-IdentCalendarFixture
$changed[13].bounds='538,300,44,25'
Assert-Rejected $changed $request 'CALENDAR_TIME_AXIS'
$changed=New-IdentCalendarFixture
$changed[7].isOffscreen=$true
Assert-Rejected $changed $request 'CALENDAR_DOCTOR_AMBIGUOUS'
$changed=New-IdentCalendarFixture
$changed[11].isOffscreen=$true
Assert-Rejected $changed $request 'CALENDAR_SCROLL_REQUIRED'
$changed=New-IdentCalendarFixture
$changed[1].path=$changed[2].path
Assert-Rejected $changed $request 'CALENDAR_INVALID_TREE'
$changed=New-IdentCalendarFixture
$changed[1].rootName='Other window'
Assert-Rejected $changed $request 'CALENDAR_INVALID_TREE'
$changed=New-IdentCalendarFixture
$copy=$changed[0].PSObject.Copy(); $copy.path='1'
Assert-Rejected (@($changed)+@($copy)) $request 'CALENDAR_GRID_AMBIGUOUS'

# Existing 15-minute boundaries are usable; the planner must not split the calendar itself.
$quarter=New-IdentCalendarFixture
$quarter[13].name='09:15'; $quarter[14].name='09:15'
$quarter[13].bounds='538,344,44,25'; $quarter[14].bounds='1321,344,44,25'
# Shift the remaining labels by 15 minutes without fabricating any missing boundary.
for($i=15;$i -le 50;$i++) {
    $value=[timespan]::ParseExact($quarter[$i].name,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture)
    $quarter[$i].name=$value.Subtract([timespan]::FromMinutes(15)).ToString('hh\:mm')
}
$fifteen=New-IdentCalendarPlan $quarter (New-TestRequest '09:00' 15)
Assert-Test ($fifteen.Ok -and $fifteen.Selection.SlotCount -eq 1) 'An explicit visible quarter-hour boundary should work.'

# Six hours is the contract maximum; crossing shifts or the viewport still fails separately.
$max=New-TestRequest '09:00' 360
Assert-Test ($max.DurationMinutes -eq 360) 'Six hours should be valid in the request contract.'
$unbroken=@(New-IdentCalendarFixture | Where-Object { $_.path -notin @('0/5','0/7','0/9') })
$unbroken[0].bounds='514,153,1406,1300'
foreach($row in $unbroken) {
    if ($row.name -match '^\d{2}:\d{2}$') {
        $minute=[timespan]::ParseExact($row.name,'hh\:mm',[Globalization.CultureInfo]::InvariantCulture).TotalMinutes
        $rect=ConvertTo-IdentFormRectangle $row.bounds
        $row.bounds=('{0},{1},44,25' -f $rect.X,(313+($minute-540)*1.5))
    }
}
$six=New-IdentCalendarPlan $unbroken $max
Assert-Test ($six.Ok -and $six.Selection.SlotCount -eq 12) 'Six hours in one visible unbroken shift should be plannable.'
foreach($scale in @(1.25,1.5)) {
    $scaled=New-IdentCalendarFixture
    foreach($row in $scaled) {
        $rect=ConvertTo-IdentFormRectangle $row.bounds
        if ($null -ne $rect) {
            $row.bounds=('{0},{1},{2},{3}' -f [int][math]::Floor($rect.X*$scale-2500),[int][math]::Floor($rect.Y*$scale),
                [int][math]::Floor($rect.Width*$scale),[int][math]::Floor($rect.Height*$scale))
        }
    }
    $scaledPlan=New-IdentCalendarPlan $scaled $request
    Assert-Test ($scaledPlan.Ok -and $scaledPlan.Selection.X -lt 0) 'Scaled/negative-monitor coordinates must come from the current scan.'
}
foreach($duration in @(0,14,16,361,375,900)) {
    $failed=$false
    try { $null=New-TestRequest '09:00' $duration } catch { $failed=$_.Exception.Message -ceq 'CALENDAR_INVALID_REQUEST' }
    Assert-Test $failed ('Invalid duration accepted: '+$duration)
}
$failed=$false
try { $null=New-TestRequest '09:01' } catch { $failed=$true }
Assert-Test $failed 'Unaligned start accepted.'
foreach($pair in @(
    @('2020-09-20T09:00:00+05:00','2020-09-20T09:30:00+05:00'),
    @('2099-09-20T23:30:00+05:00','2099-09-21T00:00:00+05:00'),
    @('2099-09-20T09:00:00+05:00','2099-09-20T09:30:00+04:00'),
    @('2099-09-20T09:00:00','2099-09-20T09:30:00'),
    @('2099-09-20T09:00:01+05:00','2099-09-20T09:30:01+05:00')
)) {
    $failed=$false
    try { $null=New-IdentCalendarRequest ([pscustomobject]@{schemaVersion=1;purpose='ident-calendar-check';doctorCaption='Doctor B';planStart=$pair[0];planEnd=$pair[1]}) }
    catch { $failed=$_.Exception.Message -ceq 'CALENDAR_INVALID_REQUEST' }
    Assert-Test $failed 'Unsafe date range accepted.'
}

$snapshot=[pscustomobject]@{ GridIdentity='synthetic-grid'; Plan=$plan }
$report=Invoke-IdentCalendarReadCheck { $snapshot }
Assert-Test ($report.Ok -and $report.StableSnapshots -eq 2 -and $report.ActionsExecuted -eq 0 -and -not $report.ReadyForInput) 'Stable read-only planning failed.'
$script:readCount=0
$report=Invoke-IdentCalendarReadCheck { $script:readCount++; [pscustomobject]@{ GridIdentity=('grid-'+$script:readCount); Plan=$plan } }
Assert-Test (-not $report.Ok -and $report.ErrorCode -ceq 'CALENDAR_CHANGED') 'Grid recreation was ignored.'
$changed=New-IdentCalendarFixture; $changed[5].name='Changed unrelated header'
$different=New-IdentCalendarPlan $changed $request
Assert-Test ($different.Ok -and $different.Fingerprint -cne $plan.Fingerprint) 'Layout fingerprint must include other headers.'
$script:readCount=0
$report=Invoke-IdentCalendarReadCheck { $script:readCount++; [pscustomobject]@{ GridIdentity='grid'; Plan=$(if ($script:readCount -eq 1) {$plan} else {$different}) } }
Assert-Test (-not $report.Ok -and $report.ErrorCode -ceq 'CALENDAR_CHANGED') 'Calendar change between scans was ignored.'
$report=Invoke-IdentCalendarReadCheck { throw 'provider private patient data' }
Assert-Test ($report.ErrorCode -ceq 'CALENDAR_CHECK_FAILED' -and ($report | ConvertTo-Json) -notmatch 'private|patient') 'Provider errors must be redacted.'
$report=Invoke-IdentCalendarReadCheck { throw 'CALENDAR_USER_ACTIVE' }
Assert-Test ($report.ErrorCode -ceq 'CALENDAR_USER_ACTIVE' -and -not $report.Ok) 'User activity must cancel checking.'

$caption=[regex]::Unescape('\u0417\u0430\u043f\u0438\u0441\u0430\u0442\u044c \u043d\u0430 \u043f\u0440\u0438\u0435\u043c...')
$item=[pscustomobject]@{ path='0/0'; name=$caption; controlType='ControlType.MenuItem'; isEnabled=$true; isOffscreen=$false;
    patterns=@('InvokePatternIdentifiers.Pattern'); bounds='10,10,300,30' }
$buffer=$item.PSObject.Copy(); $buffer.path='0/1'; $buffer.name='(Continue) '+$caption
$child=$item.PSObject.Copy(); $child.path='0/0/0'; $child.controlType='ControlType.Text'
$candidate=Get-IdentNewAppointmentMenuCandidate @($item,$buffer,$child)
Assert-Test ($null -ne $candidate -and $candidate.Path -ceq '0/0' -and -not $candidate.ReadyForInput) 'Only the exact new-appointment MenuItem can be a candidate.'
Assert-Test ($null -eq (Get-IdentNewAppointmentMenuCandidate @($buffer,$child))) 'Continue-from-buffer must never substitute for new appointment.'
Assert-Test ($null -eq (Get-IdentNewAppointmentMenuCandidate @($item,$item))) 'Duplicate menu item is ambiguous.'
$item.isEnabled=$false
Assert-Test ($null -eq (Get-IdentNewAppointmentMenuCandidate @($item))) 'Disabled menu item accepted.'
Write-Host ('IDENT CALENDAR TESTS OK: '+$script:checks)
