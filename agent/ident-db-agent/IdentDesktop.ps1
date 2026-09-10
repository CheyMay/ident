[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$StartMinimized,
    [string]$PreviewPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'AgentLifecycle.ps1')

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}
$ConfigPath=[IO.Path]::GetFullPath($ConfigPath)
$script:PanelMutex=$null
$script:PanelShowEvent=$null
if (-not $PreviewPath) {
    $script:PanelMutex=[Threading.Mutex]::new($false,'Local\Code9IdentAgentDesktop')
    $ownsPanel=$false
    try { $ownsPanel=$script:PanelMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsPanel=$true }
    if (-not $ownsPanel) {
        if (-not $StartMinimized) {
            try {
                $signal=[Threading.EventWaitHandle]::OpenExisting('Local\Code9IdentAgentDesktopShow')
                try { $null=$signal.Set() } finally { $signal.Dispose() }
            } catch { }
        }
        $script:PanelMutex.Dispose()
        exit 0
    }
    $script:PanelShowEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,'Local\Code9IdentAgentDesktopShow')
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
        waiting_for_idle = 'ждет 1 минуту бездействия'
        waiting_for_session = 'ждет разблокировки Windows'
        waiting_for_ident = 'ждет запуска IDENT'
        waiting_for_training = 'показ экранов: автозапись приостановлена'
        retrying = 'повторяет подключение к SQL'
        needs_configuration = 'нужна настройка'
        needs_review = 'нужна проверка результата в IDENT'
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

    if ($null -ne $script:SettingsRequest -or $null -ne $script:PendingSettings) { return }
    if ([string]::IsNullOrWhiteSpace($script:AgentKey)) {
        throw 'Ключ агента не настроен. Запустите установку повторно.'
    }
    $url = ([string]$script:Config.backend.baseUrl).TrimEnd('/') + '/api/agent/config'
    $payload = @{
        agentId = [string]$script:Config.agent.id
        scheduleEnabled = $ScheduleEnabled
        robotEnabled = $RobotEnabled
    } | ConvertTo-Json -Compress
    $runner = [PowerShell]::Create()
    [void]$runner.AddScript({
        param($Url, $Key, $Payload)
        $ErrorActionPreference = 'Stop'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [void](Invoke-RestMethod -Uri $Url -Method Post -Headers @{ 'X-Agent-Key' = $Key; Accept = 'application/json' } `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($Payload)) -TimeoutSec 15 -UseBasicParsing)
    }).AddArgument($url).AddArgument($script:AgentKey).AddArgument($payload)
    try {
        $script:SettingsRequest = @{ Runner = $runner; Handle = $runner.BeginInvoke(); ScheduleEnabled = $ScheduleEnabled; RobotEnabled = $RobotEnabled }
        $scheduleCheck.Enabled = $false
        $robotCheck.Enabled = $false
        $script:UiError = ''
    }
    catch { $runner.Dispose(); throw }
}

function Update-AgentSettings {
    if ($null -eq $script:SettingsRequest -or -not $script:SettingsRequest.Handle.IsCompleted) { return }
    $runner = $script:SettingsRequest.Runner
    try {
        [void]$runner.EndInvoke($script:SettingsRequest.Handle)
        if ($runner.HadErrors) { throw 'Сервер не подтвердил переключатель. Проверьте связь и повторите.' }
        $script:PendingSettings = @{
            ScheduleEnabled = $script:SettingsRequest.ScheduleEnabled
            RobotEnabled = $script:SettingsRequest.RobotEnabled
            Deadline = [DateTimeOffset]::Now.AddSeconds(90)
        }
        $script:UiError = ''
    }
    catch { $script:UiError = 'Настройки не подтверждены сервером. Проверьте связь и повторите.' }
    finally {
        $runner.Dispose()
        $script:SettingsRequest = $null
        $scheduleCheck.Enabled = $null -eq $script:PendingSettings
    }
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
$captureHelpersPath = Join-Path $PSScriptRoot 'robot\RobotCapture.ps1'
if (-not (Test-Path -LiteralPath $captureHelpersPath)) { $captureHelpersPath = Join-Path $PSScriptRoot '..\..\robot\ident-rpa\RobotCapture.ps1' }
. $captureHelpersPath
$script:TrainingProcess = $null
$script:CalibrationReportPath = Join-Path (Split-Path -Parent $script:RobotConfigPath) 'calibration-report.json'
$script:CalibrationProcess = $null
$script:CalibrationJob = $null
$script:CalibrationStage = 'idle'
$script:CalibrationStartedAt = [DateTimeOffset]::MinValue
$script:CalibrationCaptureId = ''
$script:CalibrationProgress = $null
$script:LastCapturePath = ''
$script:CalibrationErrorPath = ''
$script:Refreshing = $false
$script:AllowClose = $false
$script:SettingsRequest = $null
$script:PendingSettings = $null
$script:UiError = ''

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Code9 IDENT'
$form.ClientSize = New-Object Drawing.Size(540, 690)
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
$robotCheck.Location = New-Object Drawing.Point(20, 408)
$robotCheck.Size = New-Object Drawing.Size(280, 26)
$robotCheck.Text = 'Робот подтверждения заявок включен'
$robotCheck.Checked = [bool]$script:Config.features.robotEnabled
$form.Controls.Add($robotCheck)

$robotStateLabel = New-StatusLabel -Parent $form -Text 'Робот: выключен' -Top 438
$robotTimeLabel = New-StatusLabel -Parent $form -Text 'Последнее выполнение: нет' -Top 464

$robotGuideLabel = New-StatusLabel -Parent $form -Text 'Откройте календарь или новое окно приема в IDENT и нажмите проверку.' -Top 491
$robotGuideLabel.Size = New-Object Drawing.Size(494, 42)
$robotGuideLabel.ForeColor = [Drawing.Color]::FromArgb(74, 91, 108)

$calibrateButton = New-Object System.Windows.Forms.Button
$calibrateButton.Location = New-Object Drawing.Point(20, 536)
$calibrateButton.Size = New-Object Drawing.Size(240, 42)
$calibrateButton.Text = 'Проверить окно IDENT'
$calibrateButton.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$calibrateButton.FlatStyle = [Windows.Forms.FlatStyle]::Flat
$calibrateButton.FlatAppearance.BorderSize = 0
$calibrateButton.BackColor = [Drawing.Color]::FromArgb(29, 112, 66)
$calibrateButton.ForeColor = [Drawing.Color]::White
$calibrateButton.Cursor = [Windows.Forms.Cursors]::Hand
$form.Controls.Add($calibrateButton)

$trainingButton = New-Object System.Windows.Forms.Button
$trainingButton.Location = New-Object Drawing.Point(274, 536)
$trainingButton.Size = New-Object Drawing.Size(240, 42)
$trainingButton.Text = 'Начать показ экранов'
$form.Controls.Add($trainingButton)
$trainingButton.Add_Click({
    try {
        if ($null -ne $script:TrainingProcess -and -not $script:TrainingProcess.HasExited) { return }
        if ($script:CalibrationStage -eq 'scanning') { throw 'Дождитесь завершения текущего скана.' }
        $state = Read-JsonFile $script:StatePath
        if ($robotCheck.Checked -or ($null -ne $state -and [bool]$state.robot.enabled)) { throw 'Сначала выключите робота.' }
        $path = Join-Path $script:BaseDirectory 'robot\Start-IdentTraining.ps1'
        if (-not (Test-Path -LiteralPath $path)) { throw 'Дождитесь завершения обновления агента.' }
        try { $null = Read-RobotTrainingConfiguration $script:RobotConfigPath }
        catch { throw 'Показ не запущен: профиль робота отсутствует или поврежден. Нужна проверка специалиста.' }
        if ($null -ne $script:TrainingProcess) { $script:TrainingProcess.Dispose() }
        $launchId = [guid]::NewGuid().ToString('N')
        $outputPath = Join-Path (Split-Path -Parent $script:RobotConfigPath) "training-$launchId-output.log"
        $errorPath = Join-Path (Split-Path -Parent $script:RobotConfigPath) "training-$launchId-error.log"
        $script:TrainingProcess = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath -ArgumentList (
            "-NoProfile -STA -ExecutionPolicy Bypass -File `"$path`" -ConfigPath `"$script:RobotConfigPath`"")
        $null = $script:TrainingProcess.Handle
        $script:UiError = ''
    } catch { $script:UiError = $_.Exception.Message }
})

$inspectButton = New-Object System.Windows.Forms.Button
$inspectButton.Location = New-Object Drawing.Point(20, 588)
$inspectButton.Size = New-Object Drawing.Size(154, 34)
$inspectButton.Text = 'Скопировать скан'
$inspectButton.Enabled = $false
$form.Controls.Add($inspectButton)

$folderButton = New-Object System.Windows.Forms.Button
$folderButton.Location = New-Object Drawing.Point(184, 588)
$folderButton.Size = New-Object Drawing.Size(154, 34)
$folderButton.Text = 'Открыть папку'
$form.Controls.Add($folderButton)

$errorLabel = New-StatusLabel -Parent $form -Text '' -Top 632
$errorLabel.Size = New-Object Drawing.Size(494, 44)
$errorLabel.ForeColor = [Drawing.Color]::FromArgb(157, 35, 32)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Code9 IDENT'
$tray.Icon = [Drawing.SystemIcons]::Information
$tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$openMenuItem = $trayMenu.Items.Add('Открыть')
$sendMenuItem = $trayMenu.Items.Add('Отправить расписание')
[void]$trayMenu.Items.Add('-')
$exitMenuItem = $trayMenu.Items.Add('Выйти из панели')
$tray.ContextMenuStrip = $trayMenu

function Show-MainWindow {
    $form.ShowInTaskbar = $true
    $form.Show()
    $form.WindowState = [Windows.Forms.FormWindowState]::Normal
    $form.Activate()
}

function Hide-MainWindow {
    $form.ShowInTaskbar = $false
    $form.Hide()
}

function Request-LocalAgentCommand {
    param([ValidateSet('sql-discovery-now','schema-now')][string]$Name)
    try {
        $null=New-Item -ItemType Directory -Force -Path $script:CommandDirectory
        $null=New-Item -ItemType File -Force -Path (Join-Path $script:CommandDirectory $Name)
        $script:UiError=''
        Refresh-Status
    } catch { $script:UiError=$_.Exception.Message }
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
        $script:UiError = $_.Exception.Message
        $errorLabel.Text = $script:UiError
    }
}

function Request-SchedulePush {
    New-Item -ItemType Directory -Force -Path $script:CommandDirectory | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $script:CommandDirectory 'send-now') | Out-Null
    $scheduleStateLabel.Text = 'Состояние: команда на отправку принята'
}

function Get-FreshRobotCapture {
    param([string]$ReportPath, [string]$CaptureId, [DateTimeOffset]$StartedAfter)
    return (Get-VerifiedRobotCapture $ReportPath $CaptureId $StartedAfter)
}

function Start-RobotCalibration {
    if ($null -ne $script:TrainingProcess -and -not $script:TrainingProcess.HasExited) { return }
    if ($script:CalibrationStage -ne 'idle' -and $script:CalibrationStage -ne 'failed' -and $script:CalibrationStage -ne 'ready') {
        return
    }
    $script:CalibrationCaptureId = [guid]::NewGuid().ToString('N')
    $script:CalibrationProgress = New-RobotCaptureProgress (Split-Path -Parent $script:RobotConfigPath) 'calibration'
    $script:CalibrationProgress.Id = $script:CalibrationCaptureId
    $script:CalibrationProgress.Attempt = 1
    $script:LastCapturePath = ''
    $inspectButton.Enabled = $false
    try {
        $state = Read-JsonFile -Path $script:StatePath
        if ($robotCheck.Checked -or ($null -ne $state -and ([bool]$state.robot.enabled -or [string]$state.robot.state -eq 'processing'))) {
            throw 'Сначала выключите робота и дождитесь завершения текущей заявки.'
        }
        $robotScript = Join-Path $script:BaseDirectory 'robot\Start-IdentRobot.ps1'
        if (-not (Test-Path -LiteralPath $robotScript)) {
            throw 'Модуль робота не найден. Дождитесь обновления приложения.'
        }
        $stdoutPath = Join-Path (Split-Path -Parent $script:RobotConfigPath) ("calibration-$($script:CalibrationCaptureId)-output.log")
        $stderrPath = Join-Path (Split-Path -Parent $script:RobotConfigPath) ("calibration-$($script:CalibrationCaptureId)-error.log")
        $script:CalibrationErrorPath = $stderrPath
        $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$robotScript`" " +
            "-Mode Calibrate -ConfigPath `"$script:RobotConfigPath`" " +
            "-ReportPath `"$script:CalibrationReportPath`" -CaptureId $($script:CalibrationCaptureId) -StartDelaySeconds 8"
        $script:CalibrationStartedAt = [DateTimeOffset]::Now
        Initialize-RobotCaptureJob
        $script:CalibrationJob = New-Object IdentCaptureJob
        $script:CalibrationProcess = Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru
        $null = $script:CalibrationProcess.Handle
        $script:CalibrationJob.Attach($script:CalibrationProcess)
        $script:CalibrationStage = 'scanning'
        $calibrateButton.Enabled = $false
        $calibrateButton.Text = 'IDENT проверяется...'
        $robotGuideLabel.Text = 'Через 8 секунд начнется скан. Вернитесь в нужное окно IDENT. Запись не сохраняется.'
        $errorLabel.Text = ''
        $script:UiError = ''
        Update-CalibrationLiveStatus
    }
    catch {
        if ($null -ne $script:CalibrationJob) { $script:CalibrationJob.Dispose(); $script:CalibrationJob = $null }
        if ($null -ne $script:CalibrationProcess) {
            if (-not $script:CalibrationProcess.HasExited) { $script:CalibrationProcess.Kill() }
            $script:CalibrationProcess.Dispose(); $script:CalibrationProcess = $null
        }
        $script:CalibrationStage = 'failed'
        $calibrateButton.Enabled = $true
        $calibrateButton.Text = 'Повторить проверку IDENT'
        $script:UiError = $_.Exception.Message
        $errorLabel.Text = $script:UiError
        Update-CalibrationLiveStatus
    }
}

function Update-CalibrationLiveStatus {
    $variable = Get-Variable -Name CalibrationProgress -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $variable -or $null -eq $variable.Value) { return }
    $progress = $variable.Value
    $previous = "$($progress.State)|$($progress.Captured)|$($progress.ErrorCode)"
    switch ($script:CalibrationStage) {
        'scanning' { $progress.State = 'scanning' }
        'failed' { $progress.State = 'failed'; $progress.ErrorCode = 'scan_failed' }
        'ready' { $progress.State = 'completed'; $progress.Captured = 1; $progress.ErrorCode = '' }
        default { return }
    }
    if ($progress.State -in @('completed','failed') -and $previous -eq "$($progress.State)|$($progress.Captured)|$($progress.ErrorCode)") { return }
    [void](Write-RobotCaptureProgress $progress -Force)
}

function Update-RobotCalibration {
    Update-CalibrationLiveStatus
    if ($script:CalibrationStage -eq 'scanning') {
        if ($null -eq $script:CalibrationProcess -or -not $script:CalibrationProcess.HasExited) {
            if (([DateTimeOffset]::Now - $script:CalibrationStartedAt).TotalSeconds -gt 60) {
                if ($null -ne $script:CalibrationJob) { $script:CalibrationJob.Dispose(); $script:CalibrationJob = $null }
                if ($null -ne $script:CalibrationProcess) {
                    Stop-Process -Id $script:CalibrationProcess.Id -Force -ErrorAction SilentlyContinue
                    $script:CalibrationProcess.Dispose()
                    $script:CalibrationProcess = $null
                }
                $script:CalibrationStage = 'failed'
                $calibrateButton.Enabled = $true
                $calibrateButton.Text = 'Повторить проверку IDENT'
                $script:UiError = 'IDENT не ответил за минуту. Агент продолжает работать. Разверните IDENT и повторите проверку.'
                Update-CalibrationLiveStatus
            }
            return
        }
        $exitCode = $script:CalibrationProcess.ExitCode
        if ($null -ne $script:CalibrationJob) { $script:CalibrationJob.Dispose(); $script:CalibrationJob = $null }
        $script:CalibrationProcess.Dispose()
        $script:CalibrationProcess = $null
        try {
            if ($null -eq $exitCode -or $exitCode -ne 0) {
                $detail = if (Test-Path -LiteralPath $script:CalibrationErrorPath) {
                    (Get-Content -LiteralPath $script:CalibrationErrorPath -TotalCount 3) -join ' '
                } else { '' }
                throw "Сканирование завершилось с кодом $exitCode. $detail"
            }
            $capture = Get-FreshRobotCapture -ReportPath $script:CalibrationReportPath `
                -CaptureId $script:CalibrationCaptureId -StartedAfter $script:CalibrationStartedAt
        }
        catch {
            $script:CalibrationStage = 'failed'
            $calibrateButton.Enabled = $true
            $calibrateButton.Text = 'Повторить проверку IDENT'
            $robotGuideLabel.Text = 'Свежий скан не получен. Робот остается выключен. Ошибка сохранена в папке robot.'
            $script:UiError = $_.Exception.Message
            $errorLabel.Text = $script:UiError
            Update-CalibrationLiveStatus
            return
        }
        $script:CalibrationStage = 'ready'
        $script:LastCapturePath = $capture.Path
        $inspectButton.Enabled = $true
        $calibrateButton.Enabled = $true
        $calibrateButton.Text = 'Проверить другое окно IDENT'
        $robotGuideLabel.Text = ('Свежий скан: {0} элементов, {1}. Профиль не активирован.' -f $capture.Report.controlsScanned, ([DateTimeOffset]::Parse($capture.Report.generatedAt).ToLocalTime().ToString('HH:mm:ss')))
        $script:UiError = ''
        if ($null -ne $script:CalibrationProgress) { $script:CalibrationProgress.Controls = [int]$capture.Report.controlsScanned }
        Update-CalibrationLiveStatus
    }
}

function Update-RobotTrainingProcess {
    if ($null -eq $script:TrainingProcess -or -not $script:TrainingProcess.HasExited) { return }
    try {
        [void]$script:TrainingProcess.WaitForExit(0)
        if ($null -eq $script:TrainingProcess.ExitCode -or $script:TrainingProcess.ExitCode -ne 0) {
            $script:UiError = 'Показ завершился с ошибкой. Журнал training сохранен в папке робота. Можно повторить запуск.'
        }
    }
    finally { $script:TrainingProcess.Dispose(); $script:TrainingProcess = $null }
}

function Refresh-Status {
    $training = $null -ne $script:TrainingProcess -and -not $script:TrainingProcess.HasExited
    $trainingButton.Enabled = -not $training -and $script:CalibrationStage -ne 'scanning'
    $calibrateButton.Enabled = -not $training -and $script:CalibrationStage -ne 'scanning'
    $state = Read-JsonFile -Path $script:StatePath
    $currentConfig = Read-JsonFile -Path $ConfigPath
    $supervisorState = Read-JsonFile -Path $script:SupervisorStatePath
    $workerOnline = $false
    $supervisorOnline = $false
    if ($null -ne $state) {
        $updated = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$state.updatedAt, [ref]$updated)) {
            $workerOnline = (([DateTimeOffset]::Now - $updated).TotalSeconds -le 90)
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
        if ($null -ne $script:PendingSettings -and [DateTimeOffset]::Now -gt $script:PendingSettings.Deadline) {
            $script:PendingSettings = $null
            $script:UiError = 'Сервер принял команду, но состояние агента недоступно. Проверьте службу.'
        }
        $scheduleCheck.Enabled = $null -eq $script:SettingsRequest -and $null -eq $script:PendingSettings
        $errorLabel.Text = $script:UiError
        $backendLabel.Text = 'Сервер Code9: нет данных'
        $tray.Icon = [Drawing.SystemIcons]::Warning
        return
    }

    $updateState = if ($state.PSObject.Properties.Name -contains 'update') { $state.update } else { $null }
    $discoveryState=if ($state.PSObject.Properties.Name -contains 'diagnostics') { $state.diagnostics } else { $null }
    $discoveryRunning=(Test-Path -LiteralPath (Join-Path $script:CommandDirectory 'sql-discovery-now')) -or
        ($null -ne $discoveryState -and [string]$discoveryState.sqlDiscoveryState -eq 'running')
    $autoSqlButton.Enabled=-not $discoveryRunning
    $autoSqlButton.Text=if ($discoveryRunning) { 'Поиск SQL...' } else { 'Найти SQL' }
    $schemaRunning=(Test-Path -LiteralPath (Join-Path $script:CommandDirectory 'schema-now')) -or
        ($state.PSObject.Properties.Name -contains 'schema' -and [string]$state.schema.state -in @('exporting','sending'))
    $sqlButton.Enabled=-not $schemaRunning
    $sqlButton.Text=if ($schemaRunning) { 'Проверка...' } else { 'Проверить базу' }
    $agentLabel.Text = "Агент: $($script:Config.agent.id)  |  версия $($state.version)" + $(if (
        $null -ne $updateState -and -not [string]::IsNullOrWhiteSpace([string]$updateState.targetVersion)
    ) {
        "  |  обновление: $($updateState.status)"
    } else {
        ''
    })

    if ($null -ne $script:PendingSettings) {
        if ($workerOnline -and [bool]$state.schedule.enabled -eq $script:PendingSettings.ScheduleEnabled -and
            [bool]$state.robot.enabled -eq $script:PendingSettings.RobotEnabled) {
            $script:PendingSettings = $null
        }
        elseif ([DateTimeOffset]::Now -gt $script:PendingSettings.Deadline) {
            $script:PendingSettings = $null
            $script:UiError = 'Сервер принял команду, но агент пока не подтвердил переключатели. Проверьте состояние службы.'
        }
        else { $workerLabel.Text = 'Фоновая служба: ожидается применение переключателей...' }
    }
    $scheduleCheck.Enabled = $null -eq $script:SettingsRequest -and $null -eq $script:PendingSettings
    $script:Refreshing = $true
    try {
        if ($null -eq $script:SettingsRequest -and $null -eq $script:PendingSettings) {
            $scheduleCheck.Checked = [bool]$state.schedule.enabled
            $robotCheck.Checked = [bool]$state.robot.enabled
        }
    }
    finally {
        $script:Refreshing = $false
    }

    $backendLabel.Text = 'Сервер Code9: ' + $(if ($workerOnline -and [bool]$state.worker.backendOnline) { 'на связи' } else { 'нет актуального подтверждения' })
    $scheduleStateLabel.Text = 'Состояние: ' + (Format-StateName -Value ([string]$state.schedule.state))
    $scheduleTimeLabel.Text = 'Последняя отправка: ' + (Format-DateValue -Value $state.schedule.lastSuccessAt)
    $serviceCount = if ($state.schedule.PSObject.Properties.Name -contains 'services') { [int]$state.schedule.services } else { 0 }
    $scheduleCountLabel.Text = 'Врачи: {0}  |  филиалы: {1}  |  окна: {2}  |  свободно: {3}  |  услуги: {4}' -f `
        $state.schedule.doctors, $state.schedule.branches, $state.schedule.intervals, $state.schedule.freeIntervals, $serviceCount
    $robotStateLabel.Text = 'Робот: ' + (Format-StateName -Value ([string]$state.robot.state)) +
        $(if ([bool]$state.robot.configured) { '' } else { ' (не откалиброван)' })
    $robotTimeLabel.Text = 'Последнее выполнение: ' + (Format-DateValue -Value $state.robot.lastSuccessAt)
    $robotCheck.Enabled = ([bool]$state.robot.configured -or $robotCheck.Checked) -and $null -eq $script:SettingsRequest -and $null -eq $script:PendingSettings -and $script:CalibrationStage -ne 'scanning' -and -not $training
    if ($script:CalibrationStage -eq 'idle' -and [bool]$state.robot.configured) {
        $robotGuideLabel.Text = $(if ([bool]$state.robot.enabled) {
            'Робот настроен и ожидает новые заявки.'
        } else {
            'Робот настроен. Для запуска используйте переключатель после контрольного приема.'
        })
    }
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
        $(if ($null -ne $discoveryState) { [string]$discoveryState.sqlDiscoveryLastError } else { '' })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $errorLabel.Text = $(if ($script:UiError) { $script:UiError } else { $errors -join ' | ' })

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
    $trayText = ('Code9 IDENT: {0}, расписание {1}' -f `
        $(if ($workerOnline) { 'работает' } else { 'остановлен' }), `
        (Format-StateName -Value ([string]$state.schedule.state))
    )
    $tray.Text = $trayText.Substring(0, [Math]::Min(63, $trayText.Length))
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
$calibrateButton.Add_Click({ Start-RobotCalibration })
$autoSqlButton.Add_Click({
    Request-LocalAgentCommand 'sql-discovery-now'
})
$sqlButton.Add_Click({
    Request-LocalAgentCommand 'schema-now'
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
    try {
        $capture = Get-FreshRobotCapture -ReportPath $script:CalibrationReportPath `
            -CaptureId $script:CalibrationCaptureId -StartedAfter $script:CalibrationStartedAt
        [Windows.Forms.Clipboard]::SetText((Get-Content -LiteralPath $capture.Path -Raw -Encoding UTF8))
        $robotGuideLabel.Text = 'Свежий скан скопирован. Передайте его специалисту. Робот не включен.'
        $script:UiError = ''
    } catch { $script:UiError = $_.Exception.Message }
})
$folderButton.Add_Click({
    $folder = Split-Path -Parent $script:RobotConfigPath
    Start-Process -FilePath 'explorer.exe' -WindowStyle Hidden -ArgumentList "`"$folder`""
})
$openMenuItem.Add_Click({ Show-MainWindow })
$tray.Add_DoubleClick({ Show-MainWindow })
$exitMenuItem.Add_Click({
    $answer=[Windows.Forms.MessageBox]::Show('Закрыть только панель? Фоновая служба и выгрузка расписания продолжат работу.',
        'Code9 IDENT',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question,[Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    $script:AllowClose = $true
    $tray.Visible = $false
    $form.Close()
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ((Get-IdentCloseAction ([string]$eventArgs.CloseReason) $script:AllowClose) -eq 'hide') {
        $eventArgs.Cancel = $true
        Hide-MainWindow
    }
})
$form.Add_Resize({
    if ($form.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) { Hide-MainWindow }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    try {
        if ($null -ne $script:PanelShowEvent -and $script:PanelShowEvent.WaitOne(0)) { Show-MainWindow }
        Update-AgentSettings
        Update-RobotTrainingProcess
        Refresh-Status
        Update-RobotCalibration
    }
    catch {
        $errorLabel.Text = $_.Exception.Message
    }
})
$timer.Start()
try { Refresh-Status } catch { $errorLabel.Text = $_.Exception.Message }

if ($StartMinimized) {
    $form.ShowInTaskbar=$false
    $form.Add_Shown({ Hide-MainWindow })
}

if ($PreviewPath) {
    # Render only this form for isolated visual tests, without displaying a desktop window.
    $form.Opacity = 0
    $form.ShowInTaskbar = $false
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
    try {
        $form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bitmap.Save([IO.Path]::GetFullPath($PreviewPath), [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}
else { [Windows.Forms.Application]::Run($form) }
$timer.Stop()
if ($null -ne $script:SettingsRequest) {
    $script:SettingsRequest.Runner.Stop()
    $script:SettingsRequest.Runner.Dispose()
}
if ($null -ne $script:CalibrationJob) { $script:CalibrationJob.Dispose() }
if ($null -ne $script:CalibrationProcess) {
    if (-not $script:CalibrationProcess.HasExited) { Stop-Process -Id $script:CalibrationProcess.Id -Force -ErrorAction SilentlyContinue }
    $script:CalibrationProcess.Dispose()
}
$tray.Visible = $false
$tray.Dispose()
$form.Dispose()
if ($null -ne $script:PanelShowEvent) { $script:PanelShowEvent.Dispose() }
if ($null -ne $script:PanelMutex) { $script:PanelMutex.ReleaseMutex(); $script:PanelMutex.Dispose() }
