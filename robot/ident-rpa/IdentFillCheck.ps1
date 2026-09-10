function ConvertTo-IdentFillPhone {
    param([string]$Value)
    if ($Value -match '[^0-9+() .-]') { throw 'FILL_INVALID_REQUEST' }
    $digits=$Value -replace '[^0-9]',''
    if ($digits -notmatch '^[78][0-9]{10}$') { throw 'FILL_INVALID_REQUEST' }
    return '+7'+$digits.Substring(1)
}

function New-IdentFillCheckPlan {
    param([object]$Request, [DateTimeOffset]$Now=[DateTimeOffset]::Now)
    try {
        if ($Request.schemaVersion -ne 1 -or $Request.purpose -cne 'ident-patient-fill-test') { throw 'Invalid purpose.' }
        $doctor=[string]$Request.doctorCaption
        if ([string]::IsNullOrWhiteSpace($doctor) -or $doctor.Length -gt 160 -or $doctor -match '[\r\n\x00-\x1f]') { throw 'Invalid caption.' }
        $start=[DateTimeOffset]::MinValue; $end=[DateTimeOffset]::MinValue
        foreach($field in @('planStart','planEnd')) {
            if ([string]$Request.$field -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00(?:Z|[+-]\d{2}:\d{2})$') { throw 'Explicit timezone required.' }
        }
        if (-not [DateTimeOffset]::TryParse([string]$Request.planStart,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$start) -or
            -not [DateTimeOffset]::TryParse([string]$Request.planEnd,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$end) -or
            $start -le $Now -or $end -le $start -or $start.Date -ne $end.Date -or $start.Offset -ne $end.Offset -or
            $start.Minute % 15 -ne 0 -or $end.Minute % 15 -ne 0 -or ($end-$start).TotalMinutes -gt 360) { throw 'Invalid interval.' }
        $values=[ordered]@{}
        foreach($pair in @(@('patientLastNameInput','surname'),@('patientFirstNameInput','name'),@('patientMiddleNameInput','patronymic'))) {
            $text=([string]$Request.patient.($pair[1])).Trim().Normalize()
            if ($text.Length -gt 80 -or $text -match '[\x00-\x1f\x7f]' -or ($pair[1] -ne 'patronymic' -and -not $text)) { throw 'Invalid name.' }
            $values[$pair[0]]=$text
        }
        $values.patientPhoneInput=ConvertTo-IdentFillPhone ([string]$Request.patient.phone)
        $birth=[datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$Request.patient.birthDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,[ref]$birth) -or $birth.Year -lt 1900 -or $birth.Date -gt $Now.ToOffset($start.Offset).Date) { throw 'Invalid birth date.' }
        $values.patientBirthDateInput=$birth.ToString('dd.MM.yyyy',[Globalization.CultureInfo]::InvariantCulture)
        $comment=[string]$Request.comment
        if ($comment.Length -gt 1000 -or $comment -match '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]') { throw 'Invalid comment.' }
        $values.commentInput=$comment
        return [pscustomobject]@{ DoctorCaption=$doctor; Start=$start; End=$end; Values=$values }
    }
    catch { throw 'FILL_INVALID_REQUEST' }
}

function Test-IdentFillValue {
    param([string]$Role,[string]$Actual,[string]$Expected)
    if ($Role -eq 'patientPhoneInput') {
        try { return (ConvertTo-IdentFillPhone $Actual) -ceq $Expected } catch { return $false }
    }
    if ($Role -eq 'patientBirthDateInput') {
        $date=[datetime]::MinValue
        return [datetime]::TryParseExact($Actual,'dd.MM.yyyy',[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,[ref]$date) -and $date.ToString('dd.MM.yyyy',[Globalization.CultureInfo]::InvariantCulture) -ceq $Expected
    }
    return $Actual.Normalize() -ceq $Expected.Normalize()
}

function Test-IdentFillEmpty {
    param([string]$Role,[string]$Value)
    if (-not $Value) { return $true }
    if ($Role -eq 'patientBirthDateInput') { return $Value -match '^[0_. /-]+$' }
    if ($Role -eq 'patientPhoneInput') {
        return $Value -match '^\+?7?[() _*.-]*$' -and ($Value -replace '[^0-9]','') -in @('','7')
    }
    return $false
}

function Assert-IdentFillSnapshot {
    param([object]$Snapshot,[object]$Plan,[object]$Baseline=$null,[hashtable]$Written=@{})
    if ($null -eq $Snapshot -or -not $Snapshot.Form.Ok -or $Snapshot.Form.Layout -cne 'expanded' -or
        -not $Snapshot.RootIdentity -or $Snapshot.NotificationsOff -ne $true -or $Snapshot.Fields.Count -ne 6) { throw 'FILL_UNSAFE_FORM' }
    Assert-IdentPatientFormContext $Snapshot.Form $Plan.DoctorCaption $Plan.Start $Plan.End
    $identities=@{}
    foreach($role in $Plan.Values.Keys) {
        if (-not $Snapshot.Fields.Contains($role)) { throw 'FILL_UNSAFE_FORM' }
        $field=$Snapshot.Fields[$role]
        if (-not $field.Identity -or $field.ReadOnly -or $identities.ContainsKey([string]$field.Identity)) { throw 'FILL_UNSAFE_FORM' }
        $identities[[string]$field.Identity]=$true
        if ($null -ne $Baseline) {
            if ($Snapshot.RootIdentity -cne $Baseline.RootIdentity -or $field.Identity -cne $Baseline.Fields[$role].Identity) { throw 'FILL_FORM_CHANGED' }
            if ($Written.ContainsKey($role)) {
                if (-not (Test-IdentFillValue $role ([string]$field.Value) ([string]$Plan.Values[$role]))) { throw 'FILL_VALUE_MISMATCH' }
            } elseif ([string]$field.Value -cne [string]$Baseline.Fields[$role].Value) { throw 'FILL_FORM_CHANGED' }
        }
    }
}

function Invoke-IdentFillCheck {
    param([object]$Plan,[scriptblock]$ReadSnapshot,[scriptblock]$WriteValue,[scriptblock]$Journal,
        [switch]$Execute,[switch]$OperatorConfirmed,[DateTimeOffset]$Now=[DateTimeOffset]::Now)
    $result=[ordered]@{ Ok=$false; State='rejected'; ErrorCode=''; WriteAttempts=0; Written=0; Skipped=0;
        SaveInvoked=$false; RequiresManualReview=$false; ReadyForUnattendedExecution=$false }
    $written=@{}
    try {
        if ($Plan.Start -le $Now) { throw 'FILL_EXPIRED' }
        if ($Execute -and (-not $OperatorConfirmed -or $null -eq $WriteValue -or $null -eq $Journal)) { throw 'FILL_CONSENT_REQUIRED' }
        $baseline=& $ReadSnapshot
        Assert-IdentFillSnapshot $baseline $Plan
        foreach($role in $Plan.Values.Keys) {
            $value=[string]$baseline.Fields[$role].Value
            if (-not (Test-IdentFillEmpty $role $value) -and -not (Test-IdentFillValue $role $value ([string]$Plan.Values[$role]))) { throw 'FILL_EXISTING_VALUE' }
        }
        if (-not $Execute) { $result.Ok=$true; $result.State='preview'; return [pscustomobject]$result }
        foreach($role in $Plan.Values.Keys) {
            $snapshot=& $ReadSnapshot
            Assert-IdentFillSnapshot $snapshot $Plan $baseline $written
            $expected=[string]$Plan.Values[$role]; $actual=[string]$snapshot.Fields[$role].Value
            if ((Test-IdentFillValue $role $actual $expected) -or (-not $expected -and (Test-IdentFillEmpty $role $actual))) { $result.Skipped++; continue }
            # Persist intent before every possible write. Never retry or roll back a partial form.
            $null = & $Journal 'write_intent' ($result.WriteAttempts + 1)
            $result.WriteAttempts++; $result.RequiresManualReview=$true
            $null = & $WriteValue $role $expected $snapshot
            $written[$role]=$true
            $check=& $ReadSnapshot
            Assert-IdentFillSnapshot $check $Plan $baseline $written
            $result.Written++
        }
        $check=& $ReadSnapshot
        Assert-IdentFillSnapshot $check $Plan $baseline $written
        foreach($role in $Plan.Values.Keys) {
            if (-not (Test-IdentFillValue $role ([string]$check.Fields[$role].Value) ([string]$Plan.Values[$role])) -and
                -not (-not $Plan.Values[$role] -and (Test-IdentFillEmpty $role ([string]$check.Fields[$role].Value)))) { throw 'FILL_VALUE_MISMATCH' }
        }
        $null = & $Journal 'filled' $result.WriteAttempts
        $result.RequiresManualReview=$true; $result.Ok=$true; $result.State='filled_not_saved'
    }
    catch {
        $code=[string]$_.Exception.Message
        $result.ErrorCode=if ($code -in @('FILL_INVALID_REQUEST','FILL_EXPIRED','FILL_CONSENT_REQUIRED','FILL_UNSAFE_FORM','FILL_FORM_CHANGED',
            'FILL_VALUE_MISMATCH','FILL_EXISTING_VALUE','FILL_USER_ACTIVE','FILL_WINDOW_CHANGED','FILL_ROBOT_ENABLED','FILL_REVIEW_PENDING',
            'IDENT_FORM_CONTEXT_UNAVAILABLE','IDENT_FORM_CONTEXT_MISMATCH')) { $code } else { 'FILL_CHECK_FAILED' }
        $result.State=if($result.WriteAttempts -gt 0){'partial'}else{'rejected'}
    }
    return [pscustomobject]$result
}

function Assert-IdentFillCheckInstallation {
    param([string]$RobotDirectory,[switch]$Execute)
    $directory=[IO.Path]::GetFullPath($RobotDirectory)
    if (Test-Path -LiteralPath (Join-Path $directory 'execution-pending.json')) { throw 'FILL_REVIEW_PENDING' }
    if ($Execute -and (Test-Path -LiteralPath (Join-Path $directory 'fill-check-pending.json'))) { throw 'FILL_REVIEW_PENDING' }
    try {
        $config=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $directory) 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.features.robotEnabled -isnot [bool] -or $config.features.robotEnabled -ne $false) { throw 'Robot enabled.' }
    } catch { throw 'FILL_ROBOT_ENABLED' }
}
