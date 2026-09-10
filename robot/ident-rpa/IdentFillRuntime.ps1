function Assert-IdentFillOperator {
    param([object]$Context)
    if (-not [Code9IdentRobot.NativeInput]::InteractiveDesktopAvailable() -or
        [Code9IdentRobot.NativeInput]::ForegroundHandle() -ne $Context.Handle -or
        [Code9IdentRobot.NativeInput]::ForegroundProcessId() -ne $Context.ProcessId) { throw 'FILL_WINDOW_CHANGED' }
    if ([Code9IdentRobot.NativeInput]::LastInputTick() -ne $Context.InputTick) { throw 'FILL_USER_ACTIVE' }
    if ($Context.Plan.Start -le [DateTimeOffset]::Now) { throw 'FILL_EXPIRED' }
    Assert-IdentFillCheckInstallation $Context.Directory
}

function Get-IdentFillRuntimeSnapshot {
    param([object]$Context)
    Assert-IdentFillOperator $Context
    $root=Get-ObservedElement $Context.Handle
    $identity=Assert-ObservedElement $root $Context.Handle $Context.ProcessId $Context.RootIdentity
    $rows=@(Get-UiTreeRows @($root) 8 $Context.ProcessId)
    $form=Get-IdentPatientFormBindings $rows
    if (-not $form.Ok -or $form.Layout -cne 'expanded') { throw 'FILL_UNSAFE_FORM' }
    Assert-IdentPatientFormContext $form $Context.Plan.DoctorCaption $Context.Plan.Start $Context.Plan.End
    $fields=[ordered]@{}; $patterns=@{}
    foreach($role in $form.Fields.Keys) {
        $binding=$form.Fields[$role]
        $row=@($rows | Where-Object { $_.path -ceq $binding.Path })
        if ($row.Count -ne 1) { throw 'FILL_FORM_CHANGED' }
        $element=Resolve-ElementPath $root $binding.Path
        if ($null -eq $element -or $element.Current.ProcessId -ne $Context.ProcessId -or
            $element.Current.ControlType.ProgrammaticName -cne 'ControlType.Edit' -or
            $element.Current.ClassName -cne 'TextBox' -or $element.Current.AutomationId -cne $binding.AutomationId -or
            -not $element.Current.IsEnabled -or $element.Current.IsOffscreen -or
            (Format-Bounds $element.Current.BoundingRectangle) -cne $row[0].bounds) { throw 'FILL_FORM_CHANGED' }
        $pattern=$null
        if (-not $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern) -or
            $pattern.Current.IsReadOnly) { throw 'FILL_UNSAFE_FORM' }
        $fields[$role]=[pscustomobject]@{ Identity=($element.GetRuntimeId() -join ','); Value=[string]$pattern.Current.Value; ReadOnly=$false }
        $patterns[$role]=$pattern
    }
    # Check the appointment notification control, not similarly named patient controls.
    $panelPath=$form.Fields.commentInput.Path -replace '/\d+/\d+$',''
    $notify=@($rows | Where-Object { $_.path -match ('^'+[regex]::Escape($panelPath)+'/\d+$') -and
        $_.controlType -ceq 'ControlType.CheckBox' -and $_.name -cmatch '^\u041e\u0442\u043f\u0440\u0430\u0432\u0438\u0442\u044c$' })
    if ($notify.Count -ne 1) { throw 'FILL_UNSAFE_FORM' }
    $element=Resolve-ElementPath $root $notify[0].path
    $toggle=$null
    if ($null -eq $element -or $element.Current.ProcessId -ne $Context.ProcessId -or
        $element.Current.ControlType.ProgrammaticName -cne 'ControlType.CheckBox' -or
        $element.Current.Name -cne $notify[0].name -or $element.Current.IsOffscreen -or
        -not $element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern,[ref]$toggle) -or
        $toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw 'FILL_UNSAFE_FORM' }
    $null=Assert-ObservedElement $root $Context.Handle $Context.ProcessId $identity
    Assert-IdentFillOperator $Context
    $Context.Patterns=$patterns
    return [pscustomobject]@{ Form=$form; RootIdentity=$identity; NotificationsOff=$true; Fields=$fields }
}

function Set-IdentFillRuntimeValue {
    param([object]$Context,[string]$Role,[string]$Value,[object]$Previous)
    # Re-resolve immediately before SetValue; a saved scan path alone never authorizes a write.
    $fresh=Get-IdentFillRuntimeSnapshot $Context
    Assert-IdentFillSnapshot $fresh $Context.Plan $Previous
    Assert-IdentFillOperator $Context
    $Context.Patterns[$Role].SetValue($Value)
}

function Invoke-IdentSupervisedFill {
    param([string]$RobotConfig,[string]$RequestPath,[string]$RunDirectory,[string]$RunId,[switch]$Execute)
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($RobotConfig))
    Assert-IdentFillCheckInstallation $directory -Execute:$Execute
    $requestFile=Get-Item -LiteralPath $RequestPath
    if ($requestFile.PSIsContainer -or $requestFile.Length -gt 16KB -or
        ($requestFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'FILL_INVALID_REQUEST' }
    try { $plan=New-IdentFillCheckPlan (Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw 'FILL_INVALID_REQUEST' }
    if ($Execute) {
        $answer=[System.Windows.Forms.MessageBox]::Show(
            "Code9 IDENT: пробное заполнение, БЕЗ сохранения.`n`nВрач: $($plan.DoctorCaption)`n$($plan.Start.ToString('dd.MM.yyyy HH:mm')) - $($plan.End.ToString('HH:mm'))`n"+
            "Пациент: $($plan.Values.patientLastNameInput) $($plan.Values.patientFirstNameInput) $($plan.Values.patientMiddleNameInput)`n"+
            "Телефон: $($plan.Values.patientPhoneInput)`nДата рождения: $($plan.Values.patientBirthDateInput)`nКомментарий: $($plan.Values.commentInput)`n`n"+
            "Подтверждаете использование этих согласованных тестовых данных? После Да за 8 секунд откройте расширенную анкету нового пациента в IDENT. Оповещение о записи должно быть выключено. Затем не трогайте мышь и клавиатуру до результата. Изменения полей могут обрабатываться самим IDENT; сохранение робот не нажимает.",
            'Code9 IDENT', [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { throw 'FILL_CONSENT_REQUIRED' }
    }
    Start-Sleep -Seconds 8
    Assert-IdentFillCheckInstallation $directory -Execute:$Execute
    $handle=[Code9IdentRobot.NativeInput]::ForegroundHandle()
    $processId=[Code9IdentRobot.NativeInput]::ForegroundProcessId()
    $target=Get-RobotCaptureTarget (Read-RobotTrainingConfiguration $RobotConfig) $handle $processId
    if ($null -eq $target) { throw 'FILL_WINDOW_CHANGED' }
    $context=[pscustomobject]@{ Handle=$handle; ProcessId=$processId; InputTick=[Code9IdentRobot.NativeInput]::LastInputTick();
        RootIdentity=''; Directory=$directory; Plan=$plan; Patterns=@{} }
    $context.RootIdentity=Assert-ObservedElement (Get-ObservedElement $handle) $handle $processId
    $receiptPath=Join-Path $directory 'fill-check-pending.json'
    $reader={ Get-IdentFillRuntimeSnapshot $context }.GetNewClosure()
    $writer={ param($role,$value,$snapshot) Set-IdentFillRuntimeValue $context $role $value $snapshot }.GetNewClosure()
    $journal={
        param($stage,$attempts)
        if (Test-Path -LiteralPath $receiptPath) {
            $previous=Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($previous.runId -cne $RunId) { throw 'FILL_REVIEW_PENDING' }
        }
        Write-JsonFileAtomic $receiptPath ([pscustomobject]@{ runId=$RunId; stage=$stage; writeAttempts=$attempts;
            saveInvoked=$false; requiresManualReview=$true; updatedAt=[DateTimeOffset]::Now.ToString('o') })
    }.GetNewClosure()
    return Invoke-IdentFillCheck $plan $reader $writer $journal -Execute:$Execute -OperatorConfirmed:$Execute
}
