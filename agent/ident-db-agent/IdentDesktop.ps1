[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$StartMinimized
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}

function Read-JsonFile {
    param([string]$Path)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $null
        }
        try {
            $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.FileStream]::new(
                $Path,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                $share
            )
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
                try {
                    $raw = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
            }
            finally {
                $stream.Dispose()
            }
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return $null
            }
            return $raw | ConvertFrom-Json
        }
        catch [IO.IOException] {
            if ($attempt -eq 5) {
                return $null
            }
            Start-Sleep -Milliseconds 40
        }
    }
    return $null
}

function Resolve-LocalPath {
    param(
        [string]$BaseDirectory,
        [string]$Value
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Get-PlainTextSecret {
    param([string]$EncryptedValue)

    if ([string]::IsNullOrWhiteSpace($EncryptedValue)) {
        return ''
    }
    $secure = ConvertTo-SecureString -String $EncryptedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Format-DateValue {
    param([object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return 'нет'
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.LocalDateTime.ToString('dd.MM.yyyy HH:mm:ss')
    }
    return [string]$Value
}

function Format-StateName {
    param([string]$Value)

    $names = @{
        starting = 'запускается'
        sending = 'отправка'
        ok = 'работает'
        error = 'ошибка'
        disabled = 'выключено'
        checking = 'проверка заявок'
        processing = 'обработка заявки'
        idle = 'ожидание'
        needs_configuration = 'нужна настройка'
        needs_mapping = 'нужна настройка расписания'
        not_available = 'структура еще не найдена'
        awaiting_confirmation = 'ожидает подтверждения сервера'
    }
    if ($names.ContainsKey($Value)) {
        return $names[$Value]
    }
    return $Value
}

function Invoke-AgentSettings {
    param(
        [bool]$ScheduleEnabled,
        [bool]$RobotEnabled
    )

    if ([string]::IsNullOrWhiteSpace($script:AgentKey)) {
        throw 'Ключ агента не настроен. Запустите установку повторно.'
    }
    $url = ([string]$script:Config.backend.baseUrl).TrimEnd('/') + '/api/agent/config'
    $payload = @{
        agentId = [string]$script:Config.agent.id
        scheduleEnabled = $ScheduleEnabled
        robotEnabled = $RobotEnabled
    } | ConvertTo-Json -Compress
    [void](Invoke-RestMethod `
        -Uri $url `
        -Method Post `
        -Headers @{ 'X-Agent-Key' = $script:AgentKey; Accept = 'application/json' } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
        -TimeoutSec ([int]$script:Config.backend.timeoutSeconds) `
        -UseBasicParsing)
}

function New-StatusLabel {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Text,
        [int]$Top,
        [bool]$Bold = $false
    )

    $label = New-Object System.Windows.Forms.Label
    $label.AutoSize = $false
    $label.Location = New-Object Drawing.Point(20, $Top)
    $label.Size = New-Object Drawing.Size(494, 24)
    $label.Text = $Text
    $label.Font = New-Object Drawing.Font('Segoe UI', 9, $(if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
    $Parent.Controls.Add($label)
    return $label
}

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$script:BaseDirectory = Split-Path -Parent $ConfigPath
$script:Config = Read-JsonFile -Path $ConfigPath
if ($null -eq $script:Config) {
    [Windows.Forms.MessageBox]::Show('Не найден config.local.json. Запустите 1-Setup.cmd.', 'Code9 IDENT') | Out-Null
    exit 1
}
$secretsPath = Resolve-LocalPath -BaseDirectory $script:BaseDirectory -Value ([string]$script:Config.paths.secrets)
$secrets = Read-JsonFile -Path $secretsPath
$script:AgentKey = if ($null -ne $secrets -and $secrets.PSObject.Properties.Name -contains 'agentApiKeyDpapi') {
    Get-PlainTextSecret -EncryptedValue ([string]$secrets.agentApiKeyDpapi)
} else {
    ''
}
$script:StatePath = Resolve-LocalPath -BaseDirectory $script:BaseDirectory -Value ([string]$script:Config.paths.runtimeState)
$script:CommandDirectory = Resolve-LocalPath -BaseDirectory $script:BaseDirectory -Value ([string]$script:Config.paths.commandDirectory)
$script:SupervisorStatePath = Join-Path $script:BaseDirectory 'supervisor-state.json'
$script:RestartRequestPath = Join-Path $script:CommandDirectory 'restart-worker'
$script:RobotConfigPath = Resolve-LocalPath -BaseDirectory $script:BaseDirectory -Value ([string]$script:Config.paths.robotConfig)
$script:Refreshing = $false
$script:AllowClose = $false

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Code9 IDENT'
$form.ClientSize = New-Object Drawing.Size(540, 635)
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.BackColor = [Drawing.Color]::FromArgb(247, 249, 251)

$title = New-StatusLabel -Parent $form -Text 'IDENT: расписание и заявки' -Top 16 -Bold $true
$title.Font = New-Object Drawing.Font('Segoe UI', 14, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::FromArgb(25, 38, 52)

$agentLabel = New-StatusLabel -Parent $form -Text ("Агент: {0}  |  версия {1}" -f $script:Config.agent.id, $script:Config.agent.version) -Top 48
$agentLabel.ForeColor = [Drawing.Color]::FromArgb(90, 108, 124)

$workerLabel = New-StatusLabel -Parent $form -Text 'Фоновая служба: проверка...' -Top 86 -Bold $true
$autostartLabel = New-StatusLabel -Parent $form -Text 'Автозапуск: проверка...' -Top 112
$backendLabel = New-StatusLabel -Parent $form -Text 'Сервер Code9: проверка...' -Top 138

$separator1 = New-Object System.Windows.Forms.Label
$separator1.BorderStyle = [Windows.Forms.BorderStyle]::Fixed3D
$separator1.Location = New-Object Drawing.Point(20, 170)
$separator1.Size = New-Object Drawing.Size(494, 2)
$form.Controls.Add($separator1)

$scheduleCheck = New-Object System.Windows.Forms.CheckBox
$scheduleCheck.Location = New-Object Drawing.Point(20, 188)
$scheduleCheck.Size = New-Object Drawing.Size(260, 26)
$scheduleCheck.Text = 'Выгрузка расписания включена'
$scheduleCheck.Checked = [bool]$script:Config.features.scheduleEnabled
$form.Controls.Add($scheduleCheck)

$scheduleStateLabel = New-StatusLabel -Parent $form -Text 'Состояние: ожидание запуска' -Top 218
$scheduleTimeLabel = New-StatusLabel -Parent $form -Text 'Последняя отправка: нет' -Top 244
$scheduleCountLabel = New-StatusLabel -Parent $form -Text 'Врачи: 0  |  филиалы: 0  |  окна: 0' -Top 270
$sqlConnectionLabel = New-StatusLabel -Parent $form -Text 'SQL: поиск еще не выполнялся' -Top 294
$schemaLabel = New-StatusLabel -Parent $form -Text 'Структура БД: ожидает проверки' -Top 318

$sendButton = New-Object System.Windows.Forms.Button
$sendButton.Location = New-Object Drawing.Point(20, 346)
$sendButton.Size = New-Object Drawing.Size(118, 34)
$sendButton.Text = 'Отправить сейчас'
$form.Controls.Add($sendButton)

$autoSqlButton = New-Object System.Windows.Forms.Button
$autoSqlButton.Location = New-Object Drawing.Point(148, 346)
$autoSqlButton.Size = New-Object Drawing.Size(118, 34)
$autoSqlButton.Text = 'Найти SQL'
$form.Controls.Add($autoSqlButton)

$sqlButton = New-Object System.Windows.Forms.Button
$sqlButton.Location = New-Object Drawing.Point(276, 346)
$sqlButton.Size = New-Object Drawing.Size(118, 34)
$sqlButton.Text = 'Проверить базу'
$form.Controls.Add($sqlButton)

$restartButton = New-Object System.Windows.Forms.Button
$restartButton.Location = New-Object Drawing.Point(404, 346)
$restartButton.Size = New-Object Drawing.Size(110, 34)
$restartButton.Text = 'Перезапуск'
$form.Controls.Add($restartButton)

$separator2 = New-Object System.Windows.Forms.Label
$separator2.BorderStyle = [Windows.Forms.BorderStyle]::Fixed3D
$separator2.Location = New-Object Drawing.Point(20, 398)
$separator2.Size = New-Object Drawing.Size(494, 2)
$form.Controls.Add($separator2)

$robotCheck = New-Object System.Windows.Forms.CheckBox
$robotCheck.Location = New-Object Drawing.Point(20, 416)
$robotCheck.Size = New-Object Drawing.Size(280, 26)
$robotCheck.Text = 'Робот подтверждения заявок включен'
$robotCheck.Checked = [bool]$script:Config.features.robotEnabled
$form.Controls.Add($robotCheck)

$robotStateLabel = New-StatusLabel -Parent $form -Text 'Робот: выключен' -Top 446
$robotTimeLabel = New-StatusLabel -Parent $form -Text 'Последнее выполнение: нет' -Top 472

$inspectButton = New-Object System.Windows.Forms.Button
$inspectButton.Location = New-Object Drawing.Point(20, 506)
$inspectButton.Size = New-Object Drawing.Size(154, 34)
$inspectButton.Text = 'Сканировать IDENT'
$form.Controls.Add($inspectButton)

$folderButton = New-Object System.Windows.Forms.Button
$folderButton.Location = New-Object Drawing.Point(184, 506)
$folderButton.Size = New-Object Drawing.Size(154, 34)
$folderButton.Text = 'Открыть папку'
$form.Controls.Add($folderButton)

$errorLabel = New-StatusLabel -Parent $form -Text '' -Top 558
$errorLabel.Size = New-Object Drawing.Size(494, 60)
$errorLabel.ForeColor = [Drawing.Color]::FromArgb(157, 35, 32)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Code9 IDENT'
$tray.Icon = [Drawing.SystemIcons]::Information
$tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openMenuItem = $trayMenu.Items.Add('Открыть')
$sendMenuItem = $trayMenu.Items.Add('Отправить расписание')
[void]$trayMenu.Items.Add('-')
$exitMenuItem = $trayMenu.Items.Add('Закрыть панель')
$tray.ContextMenuStrip = $trayMenu

function Show-MainWindow {
    $form.Show()
    $form.WindowState = [Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

function Set-FeatureSwitches {
    if ($script:Refreshing) {
        return
    }
    try {
        Invoke-AgentSettings -ScheduleEnabled $scheduleCheck.Checked -RobotEnabled $robotCheck.Checked
        $errorLabel.Text = ''
    }
    catch {
        $errorLabel.Text = $_.Exception.Message
    }
}

function Request-SchedulePush {
    New-Item -ItemType Directory -Force -Path $script:CommandDirectory | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $script:CommandDirectory 'send-now') | Out-Null
    $scheduleStateLabel.Text = 'Состояние: команда на отправку принята'
}

function Refresh-Status {
    $state = Read-JsonFile -Path $script:StatePath
    $currentConfig = Read-JsonFile -Path $ConfigPath
    $supervisorState = Read-JsonFile -Path $script:SupervisorStatePath
    $workerOnline = $false
    $supervisorOnline = $false
    if ($null -ne $state) {
        $updated = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$state.updatedAt, [ref]$updated)) {
            $workerOnline = (([DateTimeOffset]::Now - $updated).TotalSeconds -le 15)
        }
    }
    if ($null -ne $supervisorState) {
        $supervisorUpdated = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$supervisorState.updatedAt, [ref]$supervisorUpdated)) {
            $supervisorOnline = (([DateTimeOffset]::Now - $supervisorUpdated).TotalSeconds -le 20)
        }
    }

    $workerLabel.Text = 'Фоновая служба: ' + $(if ($workerOnline) { 'работает' } else { 'не отвечает' })
    $workerLabel.ForeColor = $(if ($workerOnline) { [Drawing.Color]::FromArgb(31, 106, 51) } else { [Drawing.Color]::FromArgb(157, 35, 32) })

    $autostartLabel.Text = 'Самовосстановление и автозапуск: ' + $(if ($supervisorOnline) { 'работает' } else { 'не отвечает' })
    $autostartLabel.ForeColor = $(if ($supervisorOnline) { [Drawing.Color]::FromArgb(31, 106, 51) } else { [Drawing.Color]::FromArgb(157, 35, 32) })
    if ($null -ne $currentConfig) {
        $sqlAddress = [string]$currentConfig.sql.server
        if ([int]$currentConfig.sql.port -gt 0) {
            $sqlAddress += ':' + [string]$currentConfig.sql.port
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$currentConfig.sql.instanceName)) {
            $sqlAddress += '\' + [string]$currentConfig.sql.instanceName
        }
        $sqlDatabase = if ([string]::IsNullOrWhiteSpace([string]$currentConfig.sql.database)) {
            'база не найдена'
        } else {
            [string]$currentConfig.sql.database
        }
        $sqlConnectionLabel.Text = "SQL: $sqlAddress  |  база: $sqlDatabase"
    }

    if ($null -eq $state) {
        $backendLabel.Text = 'Сервер Code9: нет данных'
        $tray.Icon = [Drawing.SystemIcons]::Warning
        return
    }

    $updateState = if ($state.PSObject.Properties.Name -contains 'update') { $state.update } else { $null }
    $agentLabel.Text = "Агент: $($script:Config.agent.id)  |  версия $($state.version)" + $(if (
        $null -ne $updateState -and -not [string]::IsNullOrWhiteSpace([string]$updateState.targetVersion)
    ) {
        "  |  обновление: $($updateState.status)"
    } else {
        ''
    })

    $script:Refreshing = $true
    try {
        $scheduleCheck.Checked = [bool]$state.schedule.enabled
        $robotCheck.Checked = [bool]$state.robot.enabled
    }
    finally {
        $script:Refreshing = $false
    }

    $backendLabel.Text = 'Сервер Code9: ' + $(if ([bool]$state.worker.backendOnline) { 'на связи' } else { 'нет связи' })
    $scheduleStateLabel.Text = 'Состояние: ' + (Format-StateName -Value ([string]$state.schedule.state))
    $scheduleTimeLabel.Text = 'Последняя отправка: ' + (Format-DateValue -Value $state.schedule.lastSuccessAt)
    $serviceCount = if ($state.schedule.PSObject.Properties.Name -contains 'services') { [int]$state.schedule.services } else { 0 }
    $scheduleCountLabel.Text = 'Врачи: {0}  |  филиалы: {1}  |  окна: {2}  |  свободно: {3}  |  услуги: {4}' -f `
        $state.schedule.doctors, $state.schedule.branches, $state.schedule.intervals, $state.schedule.freeIntervals, $serviceCount
    $robotStateLabel.Text = 'Робот: ' + (Format-StateName -Value ([string]$state.robot.state)) +
        $(if ([bool]$state.robot.configured) { '' } else { ' (не откалиброван)' })
    $robotTimeLabel.Text = 'Последнее выполнение: ' + (Format-DateValue -Value $state.robot.lastSuccessAt)
    $schemaState = if ($state.PSObject.Properties.Name -contains 'schema') { $state.schema } else { $null }
    if ($null -ne $schemaState) {
        $schemaLabel.Text = 'Структура БД: ' + (Format-StateName -Value ([string]$schemaState.state)) +
            $(if ([string]$schemaState.state -eq 'ok') {
                "  |  таблиц: $($schemaState.tables)  |  колонок: $($schemaState.columns)"
            } else {
                ''
            })
    }

    $errors = @(
        [string]$state.worker.lastError,
        [string]$state.schedule.lastError,
        $(if ($null -ne $schemaState) { [string]$schemaState.lastError } else { '' }),
        [string]$state.robot.lastError
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $errorLabel.Text = ($errors -join ' | ')

    if (-not $workerOnline -or -not [bool]$state.worker.backendOnline -or [string]$state.schedule.state -eq 'error') {
        $tray.Icon = [Drawing.SystemIcons]::Error
    }
    elseif ([string]$state.robot.state -eq 'needs_configuration' -and [bool]$state.robot.enabled) {
        $tray.Icon = [Drawing.SystemIcons]::Warning
    }
    elseif (
        [string]$state.schedule.state -eq 'needs_mapping' -or
        ($null -ne $schemaState -and [string]$schemaState.state -eq 'error')
    ) {
        $tray.Icon = [Drawing.SystemIcons]::Warning
    }
    else {
        $tray.Icon = [Drawing.SystemIcons]::Information
    }
    $tray.Text = ('Code9 IDENT: {0}, расписание {1}' -f `
        $(if ($workerOnline) { 'работает' } else { 'остановлен' }), `
        (Format-StateName -Value ([string]$state.schedule.state))
    )
}

$scheduleCheck.Add_CheckedChanged({ Set-FeatureSwitches })
$robotCheck.Add_CheckedChanged({
    if (-not $script:Refreshing -and $robotCheck.Checked) {
        $answer = [Windows.Forms.MessageBox]::Show(
            'Робот начнет выполнять заявки только после калибровки элементов интерфейса IDENT. Включить переключатель?',
            'Code9 IDENT',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            $script:Refreshing = $true
            $robotCheck.Checked = $false
            $script:Refreshing = $false
            return
        }
    }
    Set-FeatureSwitches
})
$sendButton.Add_Click({ Request-SchedulePush })
$sendMenuItem.Add_Click({ Request-SchedulePush })
$autoSqlButton.Add_Click({
    $agentScript = Join-Path $script:BaseDirectory 'IdentAgent.ps1'
    $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$agentScript`" -ConfigPath `"$ConfigPath`" -AutoConfigureSql"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
})
$sqlButton.Add_Click({
    $agentScript = Join-Path $script:BaseDirectory 'IdentAgent.ps1'
    $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$agentScript`" -ConfigPath `"$ConfigPath`" -TestConnection"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
})
$restartButton.Add_Click({
    try {
        New-Item -ItemType Directory -Force -Path $script:CommandDirectory | Out-Null
        New-Item -ItemType File -Force -Path $script:RestartRequestPath | Out-Null
        $workerLabel.Text = 'Фоновая служба: перезапускается...'
        $errorLabel.Text = ''
    }
    catch {
        $errorLabel.Text = $_.Exception.Message
    }
})
$inspectButton.Add_Click({
    $robotScript = Join-Path $script:BaseDirectory 'robot\Start-IdentRobot.ps1'
    $arguments = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$robotScript`" -Mode Inspect -ConfigPath `"$script:RobotConfigPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
})
$folderButton.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$script:BaseDirectory`"" })
$openMenuItem.Add_Click({ Show-MainWindow })
$tray.Add_DoubleClick({ Show-MainWindow })
$exitMenuItem.Add_Click({
    $script:AllowClose = $true
    $tray.Visible = $false
    $form.Close()
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:AllowClose) {
        $eventArgs.Cancel = $true
        $form.Hide()
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try {
        Refresh-Status
    }
    catch {
        $errorLabel.Text = $_.Exception.Message
    }
})
$timer.Start()
try { Refresh-Status } catch { $errorLabel.Text = $_.Exception.Message }

if ($StartMinimized) {
    $form.Add_Shown({ $form.Hide() })
}

[Windows.Forms.Application]::Run($form)
$timer.Stop()
$tray.Visible = $false
$tray.Dispose()
$form.Dispose()
