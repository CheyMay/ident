function Assert-IdentCalendarOperator {
    param([object]$Context)
    if ($Context.PSObject.Properties.Name -contains 'InputGuard' -and $null -ne $Context.InputGuard) {
        Assert-IdentCalendarOpenOperator $Context
        return
    }
    Assert-IdentFillCheckInstallation $Context.Directory
    if ($Context.Request.Start -le [DateTimeOffset]::Now) { throw 'CALENDAR_EXPIRED' }
    if (-not [Code9IdentRobot.NativeInput]::InteractiveDesktopAvailable() -or
        [Code9IdentRobot.NativeInput]::ForegroundHandle() -ne $Context.Handle -or
        [Code9IdentRobot.NativeInput]::ForegroundProcessId() -ne $Context.ProcessId) { throw 'CALENDAR_WINDOW_CHANGED' }
    if ([Code9IdentRobot.NativeInput]::LastInputTick() -ne $Context.InputTick) { throw 'CALENDAR_USER_ACTIVE' }
}

function Get-IdentCalendarRuntimeSnapshot {
    param([object]$Context)
    Assert-IdentCalendarOperator $Context
    $root=Get-ObservedElement $Context.Handle
    $null=Assert-ObservedElement $root $Context.Handle $Context.ProcessId $Context.RootIdentity
    $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty,'cttGrid')
    $candidates=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
    $grids=@($candidates | Where-Object { $_.Current.ProcessId -eq $Context.ProcessId -and
        $_.Current.ClassName -ceq 'TimeTableGridControl' -and $_.Current.ControlType.ProgrammaticName -ceq 'ControlType.Custom' -and
        $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
    if ($grids.Count -ne 1) { throw 'CALENDAR_GRID_AMBIGUOUS' }
    $grid=$grids[0]; $identity=$grid.GetRuntimeId() -join ','
    $bounds=Format-Bounds $grid.Current.BoundingRectangle
    $rootBounds=ConvertTo-IdentFormRectangle (Format-Bounds $root.Current.BoundingRectangle)
    if (-not $identity -or -not (Test-IdentFormContained (ConvertTo-IdentFormRectangle $bounds) $rootBounds)) {
        throw 'CALENDAR_WINDOW_CHANGED'
    }
    # Scope the UIA walk to the grid, not the patient's history or the whole desktop.
    $rows=@(Get-UiTreeRows @($grid) 4 $Context.ProcessId)
    if (($grid.GetRuntimeId() -join ',') -cne $identity -or (Format-Bounds $grid.Current.BoundingRectangle) -cne $bounds) {
        throw 'CALENDAR_CHANGED'
    }
    $plan=New-IdentCalendarPlan $rows $Context.Request
    $null=Assert-ObservedElement (Get-ObservedElement $Context.Handle) $Context.Handle $Context.ProcessId $Context.RootIdentity
    Assert-IdentCalendarOperator $Context
    return [pscustomobject]@{ GridIdentity=$identity; Plan=$plan }
}

function Get-IdentCalendarPreflight {
    param([scriptblock]$Reader,[scriptblock]$AvailabilityReader,[object]$Request)
    $first=& $Reader
    if (-not $first.Plan.Ok) { throw $first.Plan.ErrorCode }
    $firstAvailability=$null
    if ($null -ne $AvailabilityReader) { $firstAvailability=& $AvailabilityReader }
    $second=& $Reader
    if (-not $second.Plan.Ok) { throw $second.Plan.ErrorCode }
    if (-not $first.GridIdentity -or $first.GridIdentity -cne $second.GridIdentity -or
        -not $first.Plan.Fingerprint -or $first.Plan.Fingerprint -cne $second.Plan.Fingerprint) { throw 'CALENDAR_CHANGED' }
    $proof=$null
    if ($null -ne $AvailabilityReader) {
        $secondAvailability=& $AvailabilityReader
        $now=[DateTimeOffset]::UtcNow
        $firstProof=Get-IdentAvailabilityProof $firstAvailability $Request $first.Plan $now
        $proof=Get-IdentAvailabilityProof $secondAvailability $Request $second.Plan $now
        if (-not $firstProof.Ok) { throw $firstProof.ErrorCode }
        if (-not $proof.Ok) { throw $proof.ErrorCode }
        if (-not $proof.Fingerprint -or $firstProof.Fingerprint -cne $proof.Fingerprint) { throw 'AVAILABILITY_CHANGED' }
    }
    return [pscustomobject]@{ Snapshot=$second; Proof=$proof }
}

function Invoke-IdentCalendarReadCheck {
    param([scriptblock]$Reader,[scriptblock]$AvailabilityReader,[object]$Request)
    $result=[ordered]@{ Ok=$false; State='rejected'; ErrorCode='CALENDAR_CHECK_FAILED'; ReadOnly=$true;
        ActionsExecuted=0; SaveInvoked=$false; ReadyForInput=$false; ReadyForUnattendedExecution=$false;
        AvailabilityVerified=$false; StableSnapshots=0; SlotCount=0; RequiresDrag=$false; DoctorId=0; BranchId=0; ChairId=0 }
    try {
        $preflight=Get-IdentCalendarPreflight $Reader $AvailabilityReader $Request
        $second=$preflight.Snapshot
        $result.Ok=$true; $result.State='planned_read_only'; $result.ErrorCode=''; $result.StableSnapshots=2
        $result.SlotCount=$second.Plan.Selection.SlotCount; $result.RequiresDrag=$second.Plan.Selection.RequiresDrag
        if ($null -ne $preflight.Proof) {
            $result.State='available_read_only'; $result.AvailabilityVerified=$true
            $result.DoctorId=$preflight.Proof.DoctorId; $result.BranchId=$preflight.Proof.BranchId; $result.ChairId=$preflight.Proof.ChairId
        }
    } catch {
        $code=[string]$_.Exception.Message
        if ($code -in @('CALENDAR_EXPIRED','CALENDAR_WINDOW_CHANGED','CALENDAR_USER_ACTIVE','CALENDAR_GRID_AMBIGUOUS','CALENDAR_CHANGED',
            'CALENDAR_INVALID_TREE','CALENDAR_COLUMNS_AMBIGUOUS','CALENDAR_DATE_UNREADABLE','CALENDAR_WRONG_DATE','CALENDAR_TIME_AXIS',
            'CALENDAR_SCROLL_REQUIRED','CALENDAR_SPLIT_REQUIRED','CALENDAR_DOCTOR_AMBIGUOUS','CALENDAR_SHIFT_BOUNDARY',
            'AVAILABILITY_INVALID_DATA','AVAILABILITY_STALE','AVAILABILITY_IDENTITY_AMBIGUOUS','AVAILABILITY_BUSY','AVAILABILITY_NOT_WORKING',
            'AVAILABILITY_WRONG_DOCTOR','AVAILABILITY_WRONG_BRANCH','AVAILABILITY_SPLIT_REQUIRED','AVAILABILITY_CONFLICT','AVAILABILITY_GAP',
            'AVAILABILITY_CHANGED','AVAILABILITY_QUERY_FAILED','AVAILABILITY_TOO_LARGE','FILL_ROBOT_ENABLED','FILL_REVIEW_PENDING')) { $result.ErrorCode=$code }
    }
    return [pscustomobject]$result
}

function Invoke-IdentSupervisedCalendarCheck {
    param([string]$RobotConfig,[string]$RequestPath,[string]$RunDirectory='',[string]$RunId='',[switch]$OpenForm)
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($RobotConfig))
    Assert-IdentFillCheckInstallation $directory
    $file=Get-Item -LiteralPath $RequestPath
    if ($file.PSIsContainer -or $file.Length -gt 16KB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'CALENDAR_INVALID_REQUEST'
    }
    $request=New-IdentCalendarRequest (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($OpenForm) {
        if (-not $request.CheckAvailability -or $request.DoctorId -le 0 -or $request.BranchId -le 0) { throw 'CALENDAR_INVALID_MODE' }
        if (Test-Path -LiteralPath (Join-Path $directory 'calendar-open-pending.json')) { throw 'CALENDAR_OPEN_REVIEW_PENDING' }
        $answer=[System.Windows.Forms.MessageBox]::Show(
            "Open ONE empty appointment in IDENT? No patient input. NO SAVE.`n`nDoctor: $($request.DoctorCaption)`n"+
            "$($request.Start.ToString('dd.MM.yyyy HH:mm')) - $($request.End.ToString('HH:mm'))`n`n"+
            'After Yes, activate the calendar within 8 seconds, then do not touch mouse or keyboard. Split and drag are disabled.',
            'Code9 IDENT', [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'CALENDAR_CONSENT_REQUIRED' }
        Initialize-IdentCalendarInput
    }
    $inputGuard=$null; $oldDpi=[IntPtr]::Zero
    try {
    if ($OpenForm) {
        $oldDpi=[Code9.CalendarInputGuard]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
        if ($oldDpi -eq [IntPtr]::Zero) { throw 'CALENDAR_INPUT_GUARD' }
    }
    Start-Sleep -Seconds 8
    $handle=[Code9IdentRobot.NativeInput]::ForegroundHandle()
    $processId=[Code9IdentRobot.NativeInput]::ForegroundProcessId()
    $target=Get-RobotCaptureTarget (Read-RobotTrainingConfiguration $RobotConfig) $handle $processId
    if ($null -eq $target) { throw 'CALENDAR_WINDOW_CHANGED' }
    $context=[pscustomobject]@{ Handle=$handle; ProcessId=$processId; InputTick=[Code9IdentRobot.NativeInput]::LastInputTick();
        RootIdentity=''; Directory=$directory; Request=$request; InputGuard=$null; WindowInfo=$null }
    $context.RootIdentity=Assert-ObservedElement (Get-ObservedElement $handle) $handle $processId
    $context.WindowInfo=[pscustomobject]@{ process=$target.process; element=(Get-ObservedElement $handle) }
    if ($OpenForm) {
        $inputGuard=[Code9.CalendarInputGuard]::new()
        $context.InputGuard=$inputGuard
        Assert-IdentCalendarOperator $context
    }
    $reader={ Get-IdentCalendarRuntimeSnapshot $context }.GetNewClosure()
    $availabilityReader=$null
    if ($request.CheckAvailability) {
        $availabilityReader={
            Assert-IdentCalendarOperator $context
            $snapshot=Get-IdentAvailabilitySnapshot (Split-Path -Parent $context.Directory) $context.Request
            Assert-IdentCalendarOperator $context
            return $snapshot
        }.GetNewClosure()
    }
    if ($OpenForm) { return Invoke-IdentSupervisedCalendarOpen $context $RunDirectory $RunId $reader $availabilityReader }
    return Invoke-IdentCalendarReadCheck $reader $availabilityReader $request
    } finally {
        if ($null -ne $inputGuard) { $inputGuard.Dispose() }
        if ($oldDpi -ne [IntPtr]::Zero) { $null=[Code9.CalendarInputGuard]::SetThreadDpiAwarenessContext($oldDpi) }
    }
}
