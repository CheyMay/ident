function Get-IdentCalendarFailureDetail {
    param([object]$Record)
    $detail=[ordered]@{ Source=''; Line=0; ExceptionType='unknown'; HResult=0 }
    try {
        $files=@('Start-IdentRobot.ps1','IdentCalendarRuntime.ps1','IdentCalendarOpen.ps1','IdentPatientForm.ps1')
        $source=[IO.Path]::GetFileName([string]$Record.InvocationInfo.ScriptName)
        $line=[int]$Record.InvocationInfo.ScriptLineNumber
        if ($source -cin $files -and $line -gt 0 -and $line -lt 100000) { $detail.Source=$source; $detail.Line=$line }
        $types=@('System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException',
            'System.Management.Automation.ParameterBindingException','System.Management.Automation.PropertyNotFoundException',
            'System.Management.Automation.MethodException','System.Management.Automation.PSInvalidOperationException',
            'System.Windows.Automation.ElementNotAvailableException','System.Runtime.InteropServices.COMException',
            'System.InvalidOperationException','System.ArgumentException','System.NullReferenceException','System.TimeoutException')
        $exception=$Record.Exception
        for($i=0;$i -lt 6 -and $null -ne $exception;$i++) {
            $type=$exception.GetType().FullName
            if ($type -cin $types) { $detail.ExceptionType=$type; $detail.HResult=[int]$exception.HResult }
            $exception=$exception.InnerException
        }
    } catch { }
    # Never include provider messages, source lines, stack text, field values or full local paths.
    return [pscustomobject]$detail
}

function Get-IdentCalendarOpenError {
    param([object]$Exception)
    $allowed=@('CALENDAR_CONSENT_REQUIRED','CALENDAR_INVALID_MODE','CALENDAR_SINGLE_SLOT_ONLY','CALENDAR_INPUT_GUARD',
        'CALENDAR_USER_ACTIVE','CALENDAR_WINDOW_CHANGED','CALENDAR_NO_RETRY','CALENDAR_INPUT_FAILED','CALENDAR_CHANGED',
        'CALENDAR_MENU_AMBIGUOUS','CALENDAR_MENU_CHANGED','CALENDAR_FORM_TIMEOUT','CALENDAR_FORM_NOT_EMPTY','CALENDAR_FORM_MISMATCH',
        'CALENDAR_OPEN_REVIEW_PENDING','CALENDAR_EXPIRED','CALENDAR_DOCTOR_AMBIGUOUS','CALENDAR_WRONG_DATE','CALENDAR_SPLIT_REQUIRED',
        'CALENDAR_SCROLL_REQUIRED','CALENDAR_SHIFT_BOUNDARY','CALENDAR_GRID_AMBIGUOUS',
        'CALENDAR_INVALID_TREE','CALENDAR_COLUMNS_AMBIGUOUS','CALENDAR_DATE_UNREADABLE','CALENDAR_TIME_AXIS',
        'FILL_ROBOT_ENABLED','FILL_REVIEW_PENDING',
        'AVAILABILITY_INVALID_DATA','AVAILABILITY_STALE','AVAILABILITY_IDENTITY_AMBIGUOUS','AVAILABILITY_BUSY','AVAILABILITY_NOT_WORKING',
        'AVAILABILITY_WRONG_DOCTOR','AVAILABILITY_WRONG_BRANCH','AVAILABILITY_SPLIT_REQUIRED','AVAILABILITY_CONFLICT','AVAILABILITY_GAP',
        'AVAILABILITY_CHANGED','AVAILABILITY_QUERY_FAILED','AVAILABILITY_TOO_LARGE')
    for($i=0;$i -lt 6 -and $null -ne $Exception;$i++) {
        if ([string]$Exception.Message -cin $allowed) { return [string]$Exception.Message }
        $Exception=$Exception.InnerException
    }
    return 'CALENDAR_OPEN_FAILED'
}

function Compare-IdentCalendarMenuTransition {
    param([object]$Before,[object]$After)
    $result=[ordered]@{ Ok=$false; Reason='missing_context'; ChangedParts=@(); ReindexedParts=@();
        SelectionChangedFields=@(); CoordinateDelta=$null; FullTreeChanged=$false; OtherLabelsChanged=$false;
        LabelCounts=$null; ChangedAnchors=@() }
    if ($null -eq $Before -or $null -eq $After) { return [pscustomobject]$result }
    if (-not $After.Plan.Ok) {
        $result.Reason='plan_rejected'
        $allowed=@('CALENDAR_INVALID_TREE','CALENDAR_GRID_AMBIGUOUS','CALENDAR_COLUMNS_AMBIGUOUS','CALENDAR_DATE_UNREADABLE',
            'CALENDAR_WRONG_DATE','CALENDAR_TIME_AXIS','CALENDAR_SCROLL_REQUIRED','CALENDAR_SPLIT_REQUIRED',
            'CALENDAR_DOCTOR_AMBIGUOUS','CALENDAR_SHIFT_BOUNDARY')
        if ($After.Plan.ErrorCode -cin $allowed) { $result.Reason=$After.Plan.ErrorCode }
        return [pscustomobject]$result
    }
    if (-not $Before.GridIdentity -or $Before.GridIdentity -cne $After.GridIdentity) {
        $result.Reason='grid_identity_changed'; return [pscustomobject]$result
    }
    foreach($snapshot in @($Before,$After)) {
        if (-not $snapshot.Plan.Ok -or -not $snapshot.Plan.Fingerprint -or
            $snapshot.Plan.PSObject.Properties.Name -notcontains 'ContextParts' -or $null -eq $snapshot.Plan.ContextParts) {
            return [pscustomobject]$result
        }
        foreach($part in @('Grid','Labels','TargetLabels','Selection')) {
            if ([string]$snapshot.Plan.ContextParts[$part] -cnotmatch '^[A-F0-9]{64}$') { return [pscustomobject]$result }
        }
        if ($snapshot.Plan.PSObject.Properties.Name -notcontains 'TargetAnchors' -or $null -eq $snapshot.Plan.TargetAnchors -or
            $snapshot.Plan.TargetAnchors.Count -lt 7 -or $snapshot.Plan.TargetAnchors.Count -gt 53 -or
            (Get-IdentCalendarDigest $snapshot.Plan.TargetAnchors) -cne $snapshot.Plan.ContextParts.TargetLabels) { return [pscustomobject]$result }
    }
    $result.FullTreeChanged=$Before.Plan.Fingerprint -cne $After.Plan.Fingerprint
    $result.ChangedParts=@('Grid','TargetLabels','Selection' | Where-Object { $Before.Plan.ContextParts[$_] -cne $After.Plan.ContextParts[$_] })
    $result.OtherLabelsChanged=$Before.Plan.ContextParts.Labels -cne $After.Plan.ContextParts.Labels -and
        $Before.Plan.ContextParts.TargetLabels -ceq $After.Plan.ContextParts.TargetLabels
    $result.LabelCounts=[ordered]@{ Before=$Before.Plan.LabelCount; After=$After.Plan.LabelCount }
    $anchorChanges=[Collections.Generic.List[object]]::new()
    foreach($anchor in $Before.Plan.TargetAnchors) {
        $match=@($After.Plan.TargetAnchors | Where-Object Role -CEQ $anchor.Role)
        if ($match.Count -ne 1) { $result.Reason='anchor_missing'; return [pscustomobject]$result }
        $properties=@('name','automationId','className','controlType','bounds','isEnabled','isOffscreen' | Where-Object {
            $anchor.Node.$_ -cne $match[0].Node.$_
        })
        if ($anchor.Occurrences -ne $match[0].Occurrences) { $properties+='occurrences' }
        if ($properties.Count -gt 0) {
            $anchorChanges.Add([pscustomobject]@{ Role=$anchor.Role; Properties=$properties;
                BeforeBounds=$anchor.Node.bounds; AfterBounds=$match[0].Node.bounds })
        }
    }
    $result.ChangedAnchors=$anchorChanges.ToArray()
    $result.SelectionChangedFields=@('X','StartY','LastY','SlotCount','RequiresDrag','ChairCaption' | Where-Object {
        $Before.Plan.Selection.$_ -cne $After.Plan.Selection.$_
    })
    $result.CoordinateDelta=[ordered]@{
        X=($After.Plan.Selection.X-$Before.Plan.Selection.X)
        StartY=($After.Plan.Selection.StartY-$Before.Plan.Selection.StartY)
        LastY=($After.Plan.Selection.LastY-$Before.Plan.Selection.LastY)
    }
    if ($result.ChangedParts.Count -gt 0) { $result.Reason='context_changed'; return [pscustomobject]$result }
    foreach($snapshot in @($Before,$After)) {
        if ($snapshot.Plan.PSObject.Properties.Name -notcontains 'PathParts' -or $null -eq $snapshot.Plan.PathParts) { return [pscustomobject]$result }
        foreach($part in @('Labels','Selection')) {
            if ([string]$snapshot.Plan.PathParts[$part] -cnotmatch '^[A-F0-9]{64}$') { return [pscustomobject]$result }
        }
    }
    $result.ReindexedParts=@('Labels','Selection' | Where-Object {
        $Before.Plan.PathParts[$_] -cne $After.Plan.PathParts[$_] -and
        ($_ -cne 'Labels' -or $Before.Plan.ContextParts.Labels -ceq $After.Plan.ContextParts.Labels)
    })
    $result.Ok=$true
    $result.Reason=if ($result.OtherLabelsChanged) { 'other_labels_changed' }
        elseif ($result.ReindexedParts.Count -gt 0) { 'element_paths_changed' }
        elseif ($result.FullTreeChanged) { 'incidental_tree_changed' } else { 'unchanged' }
    return [pscustomobject]$result
}

function Invoke-IdentCalendarOpenCheck {
    param([object]$Request,[scriptblock]$Preflight,[scriptblock]$Guard,[scriptblock]$RightClick,
        [scriptblock]$ReadMenu,[scriptblock]$InvokeMenu,[scriptblock]$ReadForm,[scriptblock]$Journal,[switch]$OperatorConfirmed,
        [hashtable]$Diagnostics=@{})
    $result=[ordered]@{ Ok=$false; State='rejected'; ErrorCode=''; ReadOnly=$false; ActionsAttempted=0; ActionsReturned=0;
        FormOpened=$false; SaveInvoked=$false; ReadyForInput=$false; ReadyForUnattendedExecution=$false; RequiresManualReview=$false;
        FailurePhase=''; CalendarRecheck=$null; MenuInvokeAttempted=$false; FailureDetail=$null; FormReadback=$null }
    $intentJournaled=$false; $phase='consent'
    try {
        if (-not $OperatorConfirmed) { throw 'CALENDAR_CONSENT_REQUIRED' }
        if (-not $Request.CheckAvailability -or $Request.DoctorId -le 0 -or $Request.BranchId -le 0) { throw 'CALENDAR_INVALID_MODE' }
        $phase='preflight'; $checked=& $Preflight
        if ($null -eq $checked.Proof -or -not $checked.Proof.Ok -or -not $checked.Proof.AvailabilityVerified -or
            $checked.Proof.DoctorId -ne $Request.DoctorId -or $checked.Proof.BranchId -ne $Request.BranchId) { throw 'AVAILABILITY_INVALID_DATA' }
        $selection=$checked.Snapshot.Plan.Selection
        if (-not $checked.Snapshot.Plan.Ok -or $selection.RequiresDrag -or $selection.SlotCount -ne 1) { throw 'CALENDAR_SINGLE_SLOT_ONLY' }
        $phase='input_intent'; & $Journal 'input_intent'
        $intentJournaled=$true
        & $Guard
        $result.ActionsAttempted++
        $phase='right_click'; & $RightClick $selection
        $result.ActionsReturned++
        & $Guard
        $phase='menu_lookup'; $menu=& $ReadMenu
        if ($null -eq $menu) { throw 'CALENDAR_MENU_AMBIGUOUS' }
        & $Journal 'menu_invocation_intent'
        & $Guard
        $result.ActionsAttempted++
        $phase='menu_recheck'; & $InvokeMenu $menu $checked
        $result.ActionsReturned++
        $phase='form_readback'; $form=& $ReadForm
        if ($null -eq $form -or -not $form.Empty) { throw 'CALENDAR_FORM_NOT_EMPTY' }
        $phase='form_context'
        try { Assert-IdentPatientFormContext $form.Bindings $Request.DoctorCaption $Request.Start $Request.End }
        catch { throw 'CALENDAR_FORM_MISMATCH' }
        & $Guard
        $result.FormOpened=$true
        $phase='completion'; & $Journal 'opened_verified'
        $result.Ok=$true; $result.State='opened_verified'
    } catch {
        $result.ErrorCode=Get-IdentCalendarOpenError $_.Exception
        $result.FailurePhase=$phase
        $result.FailureDetail=Get-IdentCalendarFailureDetail $_
        $result.RequiresManualReview=$intentJournaled -or $result.ActionsAttempted -gt 0
        if ($result.ActionsAttempted -gt 0) { $result.State='partial' }
    }
    if ($Diagnostics.ContainsKey('CalendarRecheck')) { $result.CalendarRecheck=$Diagnostics.CalendarRecheck }
    if ($Diagnostics.ContainsKey('FormReadback')) { $result.FormReadback=$Diagnostics.FormReadback }
    $result.MenuInvokeAttempted=$Diagnostics['MenuInvokeAttempted'] -eq $true
    return [pscustomobject]$result
}

function Assert-IdentCalendarOpenOperator {
    param([object]$Context)
    Assert-IdentFillCheckInstallation $Context.Directory
    if ($Context.Request.Start -le [DateTimeOffset]::Now) { throw 'CALENDAR_EXPIRED' }
    if (-not [Code9IdentRobot.NativeInput]::InteractiveDesktopAvailable() -or
        [Code9IdentRobot.NativeInput]::ForegroundProcessId() -ne $Context.ProcessId) { throw 'CALENDAR_WINDOW_CHANGED' }
    $Context.InputGuard.AssertUntouched([uint32]$Context.InputTick)
    $null=Assert-ObservedElement (Get-ObservedElement $Context.Handle) $Context.Handle $Context.ProcessId $Context.RootIdentity
}

function Get-IdentCalendarOpenMenu {
    param([object]$Context)
    Assert-IdentCalendarOpenOperator $Context
    $condition=[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Menu)
    $menus=@{}; $roots=@(Get-IdentAutomationRoots $Context.WindowInfo)
    foreach($root in $roots) {
        if ($root.Current.ProcessId -ne $Context.ProcessId -or $root.Current.IsOffscreen) { continue }
        $found=@($root.FindAll([System.Windows.Automation.TreeScope]::Subtree,$condition))
        foreach($menu in $found) {
            if ($menu.Current.ProcessId -eq $Context.ProcessId -and $menu.Current.IsEnabled -and -not $menu.Current.IsOffscreen -and
                $null -ne (ConvertTo-IdentFormRectangle (Format-Bounds $menu.Current.BoundingRectangle))) {
                $id=$menu.GetRuntimeId() -join ','
                if ($id) { $menus[$id]=$menu }
            }
        }
    }
    if ($menus.Count -ne 1) { throw 'CALENDAR_MENU_AMBIGUOUS' }
    $identity=@($menus.Keys)[0]; $menu=$menus[$identity]
    $rows=@(Get-UiTreeRows @($menu) 3 $Context.ProcessId)
    $candidate=Get-IdentNewAppointmentMenuCandidate $rows
    if ($null -eq $candidate) { throw 'CALENDAR_MENU_AMBIGUOUS' }
    $element=Resolve-ElementPath $menu $candidate.Path
    $menuBounds=ConvertTo-IdentFormRectangle (Format-Bounds $menu.Current.BoundingRectangle)
    if ($null -eq $element -or $element.Current.ProcessId -ne $Context.ProcessId -or
        $element.Current.ControlType.ProgrammaticName -cne 'ControlType.MenuItem' -or $element.Current.Name -cne $candidate.Name -or
        $element.Current.IsOffscreen -or -not $element.Current.IsEnabled -or
        -not (Test-IdentFormContained (ConvertTo-IdentFormRectangle (Format-Bounds $element.Current.BoundingRectangle)) $menuBounds)) { throw 'CALENDAR_MENU_CHANGED' }
    $pattern=$null
    if (-not $element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)) { throw 'CALENDAR_MENU_CHANGED' }
    Assert-IdentCalendarOpenOperator $Context
    return [pscustomobject]@{ Identity=$identity; ItemIdentity=($element.GetRuntimeId() -join ','); Name=$candidate.Name;
        Bounds=(Format-Bounds $element.Current.BoundingRectangle); Pattern=$pattern }
}

function Read-IdentCalendarOpenedForm {
    param([object]$Context,[hashtable]$Diagnostics=@{})
    $readback=[ordered]@{ Step='wait_for_form'; Role=''; FormWindowSeen=$false; FieldsChecked=0 }
    $Diagnostics.FormReadback=$readback
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    while ([datetime]::UtcNow -lt $deadline) {
        $readback.Step='parent_guard'
        Assert-IdentCalendarOpenOperator $Context
        $readback.Step='foreground'
        $handle=[Code9IdentRobot.NativeInput]::ForegroundHandle()
        if ($handle -eq $Context.Handle) { Start-Sleep -Milliseconds 150; continue }
        $readback.FormWindowSeen=$true; $readback.Step='form_root'
        $root=Get-ObservedElement $handle
        $identity=Assert-ObservedElement $root $handle $Context.ProcessId
        $readback.Step='form_scan'
        $rows=@(Get-UiTreeRows @($root) 8 $Context.ProcessId)
        $readback.Step='form_bindings'
        $form=Get-IdentPatientFormBindings $rows
        if (-not $form.Ok -or $form.Layout -cne 'compact') { throw 'CALENDAR_FORM_MISMATCH' }
        foreach($role in $form.Fields.Keys) {
            $readback.Step='field_resolve'; $readback.Role=$role
            $binding=$form.Fields[$role]; $element=Resolve-ElementPath $root $binding.Path; $pattern=$null
            $row=@($rows | Where-Object { $_.path -ceq $binding.Path })
            $readback.Step='field_identity'
            if ($null -eq $element -or $element.Current.ProcessId -ne $Context.ProcessId -or $element.Current.IsOffscreen -or
                -not $element.Current.IsEnabled -or $element.Current.ControlType.ProgrammaticName -cne 'ControlType.Edit' -or
                $element.Current.ClassName -cne 'TextBox' -or $element.Current.AutomationId -cne $binding.AutomationId -or $row.Count -ne 1 -or
                (Format-Bounds $element.Current.BoundingRectangle) -cne $row[0].bounds -or
                -not $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)) { throw 'CALENDAR_FORM_MISMATCH' }
            $readback.Step='field_value'
            $value=[string]$pattern.Current.Value
            if ($role -ceq 'patientBirthDateInput') {
                if ($value -notin @('','00.00.0000')) { throw 'CALENDAR_FORM_NOT_EMPTY' }
            } elseif ($role -ceq 'patientPhoneInput') {
                if ($value -match '[^+7\s()_*\-]' -or ($value -replace '\D','') -notin @('','7')) { throw 'CALENDAR_FORM_NOT_EMPTY' }
            } elseif ($value) { throw 'CALENDAR_FORM_NOT_EMPTY' }
            $readback.FieldsChecked++
        }
        $readback.Step='form_recheck'; $readback.Role=''
        $null=Assert-ObservedElement (Get-ObservedElement $handle) $handle $Context.ProcessId $identity
        if ([Code9IdentRobot.NativeInput]::ForegroundHandle() -ne $handle) { throw 'CALENDAR_WINDOW_CHANGED' }
        $readback.Step='parent_recheck'
        Assert-IdentCalendarOpenOperator $Context
        $readback.Step='verified'
        return [pscustomobject]@{ Empty=$true; Bindings=$form }
    }
    throw 'CALENDAR_FORM_TIMEOUT'
}

function Invoke-IdentSupervisedCalendarOpen {
    param([object]$Context,[string]$RunDirectory,[string]$RunId,[scriptblock]$Reader,[scriptblock]$AvailabilityReader)
    $pending=Join-Path $Context.Directory 'calendar-open-pending.json'
    $diagnostics=@{ MenuInvokeAttempted=$false }
    if (Test-Path -LiteralPath $pending) { throw 'CALENDAR_OPEN_REVIEW_PENDING' }
    $journal={
        param($stage)
        $receipt=[pscustomobject]@{ runId=$RunId; stage=$stage; saveInvoked=$false; requiresManualReview=$true }
        if ($stage -ceq 'input_intent') {
            $stream=[IO.File]::Open($pending,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $bytes=[Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Compress))
                $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
            } finally { $stream.Dispose() }
        } else {
            $existing=Get-Content -LiteralPath $pending -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing.runId -cne $RunId) { throw 'CALENDAR_OPEN_REVIEW_PENDING' }
            if ($stage -ceq 'opened_verified') { Remove-Item -LiteralPath $pending }
            else { Write-JsonFileAtomic $pending $receipt }
        }
    }.GetNewClosure()
    $preflight={ Get-IdentCalendarPreflight $Reader $AvailabilityReader $Context.Request }.GetNewClosure()
    $guard={ Assert-IdentCalendarOpenOperator $Context }.GetNewClosure()
    $click={
        param($selection)
        $Context.InputGuard.RightClick($selection.X,$selection.StartY,$Context.Handle,$Context.ProcessId,[uint32]$Context.InputTick)
        $Context.InputTick=$Context.InputGuard.LastOwnTick
        Start-Sleep -Milliseconds 250
    }.GetNewClosure()
    $readMenu={ Get-IdentCalendarOpenMenu $Context }.GetNewClosure()
    $invokeMenu={
        param($previous,$checked)
        # Re-read occupancy after opening the menu, and re-resolve the exact item immediately before Invoke.
        Assert-IdentCalendarOpenOperator $Context
        $live=Get-IdentAvailabilitySnapshot (Split-Path -Parent $Context.Directory) $Context.Request
        $proof=Get-IdentAvailabilityProof $live $Context.Request $checked.Snapshot.Plan
        if (-not $proof.Ok) { throw $proof.ErrorCode }
        if ($proof.Fingerprint -cne $checked.Proof.Fingerprint) { throw 'AVAILABILITY_CHANGED' }
        try { $grid=Get-IdentCalendarRuntimeSnapshot $Context }
        catch {
            $diagnostics.CalendarRecheck=[pscustomobject]@{ Ok=$false; Reason='snapshot_failed'; ChangedParts=@(); ReindexedParts=@(); FullTreeChanged=$false }
            throw
        }
        $comparison=Compare-IdentCalendarMenuTransition $checked.Snapshot $grid
        $diagnostics.CalendarRecheck=$comparison
        if (-not $comparison.Ok) { throw 'CALENDAR_CHANGED' }
        $current=Get-IdentCalendarOpenMenu $Context
        if ($current.Identity -cne $previous.Identity -or $current.ItemIdentity -cne $previous.ItemIdentity -or
            $current.Name -cne $previous.Name -or $current.Bounds -cne $previous.Bounds) { throw 'CALENDAR_MENU_CHANGED' }
        $proof=Get-IdentAvailabilityProof $live $Context.Request $checked.Snapshot.Plan
        if (-not $proof.Ok) { throw $proof.ErrorCode }
        Assert-IdentCalendarOpenOperator $Context
        & $journal 'menu_invoke_armed'
        Assert-IdentCalendarOpenOperator $Context
        $diagnostics.MenuInvokeAttempted=$true
        $current.Pattern.Invoke()
    }.GetNewClosure()
    $readForm={ Read-IdentCalendarOpenedForm $Context $diagnostics }.GetNewClosure()
    return Invoke-IdentCalendarOpenCheck $Context.Request $preflight $guard $click $readMenu $invokeMenu $readForm $journal -OperatorConfirmed -Diagnostics $diagnostics
}
