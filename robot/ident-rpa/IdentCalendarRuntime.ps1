function Assert-IdentCalendarOperator {
    param([object]$Context)
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

function Invoke-IdentCalendarReadCheck {
    param([scriptblock]$Reader)
    $result=[ordered]@{ Ok=$false; State='rejected'; ErrorCode='CALENDAR_CHECK_FAILED'; ReadOnly=$true;
        ActionsExecuted=0; SaveInvoked=$false; ReadyForInput=$false; ReadyForUnattendedExecution=$false;
        AvailabilityVerified=$false; StableSnapshots=0; SlotCount=0; RequiresDrag=$false }
    try {
        $first=& $Reader
        if (-not $first.Plan.Ok) { $result.ErrorCode=$first.Plan.ErrorCode; return [pscustomobject]$result }
        $second=& $Reader
        if (-not $second.Plan.Ok) { $result.ErrorCode=$second.Plan.ErrorCode; return [pscustomobject]$result }
        if (-not $first.GridIdentity -or $first.GridIdentity -cne $second.GridIdentity -or
            -not $first.Plan.Fingerprint -or $first.Plan.Fingerprint -cne $second.Plan.Fingerprint) {
            $result.ErrorCode='CALENDAR_CHANGED'; return [pscustomobject]$result
        }
        $result.Ok=$true; $result.State='planned_read_only'; $result.ErrorCode=''; $result.StableSnapshots=2
        $result.SlotCount=$second.Plan.Selection.SlotCount; $result.RequiresDrag=$second.Plan.Selection.RequiresDrag
    } catch {
        $code=[string]$_.Exception.Message
        if ($code -in @('CALENDAR_EXPIRED','CALENDAR_WINDOW_CHANGED','CALENDAR_USER_ACTIVE','CALENDAR_GRID_AMBIGUOUS','CALENDAR_CHANGED',
            'FILL_ROBOT_ENABLED','FILL_REVIEW_PENDING')) { $result.ErrorCode=$code }
    }
    return [pscustomobject]$result
}

function Invoke-IdentSupervisedCalendarCheck {
    param([string]$RobotConfig,[string]$RequestPath)
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($RobotConfig))
    Assert-IdentFillCheckInstallation $directory
    $file=Get-Item -LiteralPath $RequestPath
    if ($file.PSIsContainer -or $file.Length -gt 16KB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'CALENDAR_INVALID_REQUEST'
    }
    $request=New-IdentCalendarRequest (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    Start-Sleep -Seconds 8
    $handle=[Code9IdentRobot.NativeInput]::ForegroundHandle()
    $processId=[Code9IdentRobot.NativeInput]::ForegroundProcessId()
    $target=Get-RobotCaptureTarget (Read-RobotTrainingConfiguration $RobotConfig) $handle $processId
    if ($null -eq $target) { throw 'CALENDAR_WINDOW_CHANGED' }
    $context=[pscustomobject]@{ Handle=$handle; ProcessId=$processId; InputTick=[Code9IdentRobot.NativeInput]::LastInputTick();
        RootIdentity=''; Directory=$directory; Request=$request }
    $context.RootIdentity=Assert-ObservedElement (Get-ObservedElement $handle) $handle $processId
    $reader={ Get-IdentCalendarRuntimeSnapshot $context }.GetNewClosure()
    return Invoke-IdentCalendarReadCheck $reader
}
