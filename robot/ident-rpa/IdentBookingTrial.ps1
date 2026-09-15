function New-IdentBookingTrialPlan {
    param([object]$Request,[DateTimeOffset]$Now=[DateTimeOffset]::Now)
    try {
        if ($Request.schemaVersion -ne 1 -or $Request.purpose -cne 'ident-booking-trial' -or
            $Request.patientMode -cnotin @('new','existing_or_new')) { throw 'invalid' }
        $calendar=New-IdentCalendarRequest ([pscustomobject]@{
            schemaVersion=1; purpose='ident-calendar-check'; doctorCaption=$Request.doctorCaption
            doctorId=$Request.doctorId; branchId=$Request.branchId; checkAvailability=$true
            planStart=$Request.planStart; planEnd=$Request.planEnd
        }) $Now
        if ($calendar.DoctorId -le 0 -or $calendar.BranchId -le 0) { throw 'invalid' }
        $fill=New-IdentFillCheckPlan ([pscustomobject]@{
            schemaVersion=1; purpose='ident-patient-fill-test'; doctorCaption=$calendar.DoctorCaption
            planStart=$Request.planStart; planEnd=$Request.planEnd
            patient=$Request.patient; comment=$Request.comment
        }) $Now
        return [pscustomobject]@{ Calendar=$calendar; Fill=$fill; PatientMode=$Request.patientMode }
    } catch { throw 'BOOKING_TRIAL_INVALID_REQUEST' }
}

function Get-IdentBookingTrialHolds {
    param([string]$RobotDirectory)
    $directory=[IO.Path]::GetFullPath($RobotDirectory)
    $holds=[Collections.Generic.List[object]]::new()
    try {
        $folderInfo=Get-Item -LiteralPath $directory -ErrorAction Stop
        if (-not $folderInfo.PSIsContainer -or ($folderInfo.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'invalid' }
    } catch {
        return [pscustomobject]@{ Ok=$false; Holds=@([pscustomobject]@{
            Kind='directory'; RunId=''; Stage=''; ReportPresent=$false; Readable=$false
        }) }
    }
    foreach($kind in @('fill-check','calendar-open','execution')) {
        $path=Join-Path $directory ($kind+'-pending.json')
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $hold=[ordered]@{ Kind=$kind; RunId=''; Stage=''; ReportPresent=$false; Readable=$false }
        try {
            $file=Get-Item -LiteralPath $path
            if ($file.PSIsContainer -or $file.Length -gt 16KB -or
                ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'invalid' }
            $before=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $receipt=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $id=[string]$receipt.runId
            if ($id -cnotmatch '^[a-f0-9]{32}$') { throw 'invalid' }
            $hold.RunId=$id
            $stages=@('write_intent','filled','input_intent','menu_invocation_intent','menu_invoke_armed',
                'navigate_calendar','open_appointment','prepare_patient','fill_patient','filled_not_saved')
            if ([string]$receipt.stage -cin $stages) { $hold.Stage=[string]$receipt.stage }
            $folder=if ($kind -ceq 'fill-check') { 'fill-checks' } elseif ($kind -ceq 'calendar-open') { 'calendar-checks' } else { '' }
            if ($folder) {
                $reportDirectory=Join-Path (Join-Path $directory $folder) $id
                $hold.ReportPresent=Test-Path -LiteralPath (Join-Path $reportDirectory 'result.json') -PathType Leaf
            }
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $before) { throw 'changed' }
            $hold.Readable=$true
        } catch { $hold.Readable=$false; $hold.ReportPresent=$false }
        $holds.Add([pscustomobject]$hold)
    }
    return [pscustomobject]@{ Ok=($holds.Count -eq 0); Holds=$holds.ToArray() }
}

function Get-IdentBookingTrialError {
    param([Exception]$Exception)
    $allowed=@('BOOKING_TRIAL_INVALID_REQUEST','BOOKING_TRIAL_CONSENT_REQUIRED','BOOKING_TRIAL_REVIEW_PENDING',
        'BOOKING_TRIAL_NAVIGATION_UNSUPPORTED','BOOKING_TRIAL_PATIENT_UNSUPPORTED','BOOKING_TRIAL_NAVIGATION_FAILED',
        'BOOKING_TRIAL_OPEN_FAILED','BOOKING_TRIAL_PATIENT_FAILED','BOOKING_TRIAL_FILL_FAILED','BOOKING_TRIAL_UNEXPECTED_SAVE',
        'FILL_FORM_CHANGED','FILL_UNSAFE_FORM','FILL_VALUE_MISMATCH','FILL_EXISTING_VALUE','FILL_USER_ACTIVE',
        'FILL_WINDOW_CHANGED','FILL_ROBOT_ENABLED','FILL_REVIEW_PENDING','FILL_EXPIRED',
        'IDENT_FORM_CONTEXT_UNAVAILABLE','IDENT_FORM_CONTEXT_MISMATCH')
    for($i=0;$i -lt 6 -and $null -ne $Exception;$i++) {
        if ([string]$Exception.Message -cin $allowed) { return [string]$Exception.Message }
        $Exception=$Exception.InnerException
    }
    return 'BOOKING_TRIAL_FAILED'
}

function Invoke-IdentBookingTrial {
    param([object]$Plan,[scriptblock]$Preflight,[scriptblock]$Guard,[scriptblock]$NavigateCalendar,
        [scriptblock]$OpenAppointment,[scriptblock]$PreparePatient,[scriptblock]$FillPatient,
        [scriptblock]$ReadFinal,[scriptblock]$Journal,[switch]$OperatorConfirmed)
    $result=[ordered]@{ Ok=$false; State='rejected'; ErrorCode=''; FailurePhase='';
        StageAttempts=0; StagesReturned=0; CompletedStages=@(); WriteAttempts=0; WriteReturned=0; Written=0; Skipped=0;
        SaveInvoked=$false; RequiresManualReview=$false; ReadyForUnattendedExecution=$false }
    $phase='consent'; $armed=$false
    try {
        if (-not $OperatorConfirmed) { throw 'BOOKING_TRIAL_CONSENT_REQUIRED' }
        foreach($callback in @($Preflight,$Guard,$NavigateCalendar,$OpenAppointment,$PreparePatient,$FillPatient,$ReadFinal,$Journal)) {
            if ($null -eq $callback) { throw 'BOOKING_TRIAL_INVALID_REQUEST' }
        }
        if ($null -eq $Plan -or $Plan.Calendar.DoctorId -le 0 -or $Plan.Calendar.BranchId -le 0 -or
            -not $Plan.Calendar.CheckAvailability -or $Plan.Calendar.Start -ne $Plan.Fill.Start -or
            $Plan.Calendar.End -ne $Plan.Fill.End -or $Plan.Calendar.DoctorCaption -cne $Plan.Fill.DoctorCaption) {
            throw 'BOOKING_TRIAL_INVALID_REQUEST'
        }
        $phase='preflight'; $null = & $Guard
        $ready=& $Preflight $Plan
        if ($ready.ReviewClear -ne $true) { throw 'BOOKING_TRIAL_REVIEW_PENDING' }
        if ($ready.NavigationSupported -ne $true) { throw 'BOOKING_TRIAL_NAVIGATION_UNSUPPORTED' }
        if ($ready.PatientSupported -ne $true) { throw 'BOOKING_TRIAL_PATIENT_UNSUPPORTED' }
        $null = & $Guard
        $phase='navigate_calendar'
        # One durable receipt covers navigation as well as later patient input.
        $armed=$true; $result.RequiresManualReview=$true
        $null = & $Journal $phase
        $null = & $Guard
        $result.StageAttempts++
        $navigation=& $NavigateCalendar $Plan
        $result.StagesReturned++
        $result.SaveInvoked=$navigation.SaveInvoked -eq $true
        if ($result.SaveInvoked) { throw 'BOOKING_TRIAL_UNEXPECTED_SAVE' }
        if ($navigation.Ok -ne $true -or $navigation.Date -cne $Plan.Calendar.Date -or
            $navigation.SaveInvoked -ne $false) { throw 'BOOKING_TRIAL_NAVIGATION_FAILED' }
        $null = & $Guard
        $result.CompletedStages+='navigate_calendar'

        $phase='open_appointment'; $null = & $Journal $phase; $null = & $Guard
        $result.StageAttempts++
        $opened=& $OpenAppointment $Plan
        $result.StagesReturned++
        $result.SaveInvoked=$opened.SaveInvoked -eq $true
        if ($result.SaveInvoked) { throw 'BOOKING_TRIAL_UNEXPECTED_SAVE' }
        if ($opened.Ok -ne $true -or $opened.State -cne 'opened_verified' -or $opened.SaveInvoked -ne $false) { throw 'BOOKING_TRIAL_OPEN_FAILED' }
        $null = & $Guard
        $result.CompletedStages+='open_appointment'

        $phase='prepare_patient'; $null = & $Journal $phase; $null = & $Guard
        $result.StageAttempts++
        $prepared=& $PreparePatient $Plan
        $result.StagesReturned++
        $result.SaveInvoked=$prepared.SaveInvoked -eq $true
        if ($result.SaveInvoked) { throw 'BOOKING_TRIAL_UNEXPECTED_SAVE' }
        if ($prepared.Ok -ne $true -or $prepared.SaveInvoked -ne $false -or
            $prepared.IdentityVerified -ne $true -or $prepared.PatientMode -cnotin @('new','existing') -or
            ($Plan.PatientMode -ceq 'new' -and $prepared.PatientMode -cne 'new')) { throw 'BOOKING_TRIAL_PATIENT_FAILED' }
        Assert-IdentFillSnapshot $prepared.Snapshot $Plan.Fill
        $null = & $Guard
        $result.CompletedStages+='prepare_patient'

        $phase='fill_patient'; $null = & $Journal $phase; $null = & $Guard
        $result.StageAttempts++
        $filled=& $FillPatient $Plan $prepared
        $result.StagesReturned++
        $result.SaveInvoked=$filled.SaveInvoked -eq $true
        if ($result.SaveInvoked) { throw 'BOOKING_TRIAL_UNEXPECTED_SAVE' }
        foreach($counter in @('WriteAttempts','WriteReturned','Written','Skipped')) {
            $value=$filled.$counter
            if (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 6) { throw 'BOOKING_TRIAL_FILL_FAILED' }
            $result[$counter]=$value
        }
        if ($filled.Ok -ne $true -or $filled.State -cne 'filled_not_saved' -or $filled.SaveInvoked -ne $false -or
            $filled.WriteAttempts -ne $filled.WriteReturned -or $filled.Written -ne $filled.WriteReturned -or
            ($filled.Written+$filled.Skipped) -ne 6) { throw 'BOOKING_TRIAL_FILL_FAILED' }
        $null = & $Guard
        $result.CompletedStages+='fill_patient'

        $phase='final_readback'
        $snapshot=& $ReadFinal $Plan $prepared
        $written=@{}; foreach($role in $Plan.Fill.Values.Keys) { $written[$role]=$true }
        Assert-IdentFillSnapshot $snapshot $Plan.Fill $prepared.Snapshot $written
        $null = & $Guard
        $phase='completion'; $null = & $Journal 'filled_not_saved'
        $result.CompletedStages+='final_readback'
        $result.Ok=$true; $result.State='filled_not_saved'
    } catch {
        $result.ErrorCode=Get-IdentBookingTrialError $_.Exception
        $result.FailurePhase=$phase
        $result.RequiresManualReview=$armed -or $result.StageAttempts -gt 0
        if ($result.StageAttempts -gt 0) { $result.State='partial' }
    }
    return [pscustomobject]$result
}
