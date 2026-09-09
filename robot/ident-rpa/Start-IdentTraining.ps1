[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ConfigPath, [string]$PreviewPath = '')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $PSScriptRoot 'RobotSafety.ps1')
. (Join-Path $PSScriptRoot 'RobotCapture.ps1')
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class IdentTrainingWindow : Form {
    [DllImport("user32.dll", SetLastError=true)] static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hwnd, int id);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    public event EventHandler CaptureRequested;
    public bool RegisterCapture() { return RegisterHotKey(Handle, 901, 0x4003, 0x77); }
    public void ReleaseCapture() { UnregisterHotKey(Handle, 901); }
    public long[] ForegroundTarget() {
        IntPtr window = GetForegroundWindow(); uint pid;
        GetWindowThreadProcessId(window, out pid);
        return new long[] { window.ToInt64(), pid };
    }
    protected override void WndProc(ref Message message) {
        if (message.Msg == 0x312 && message.WParam.ToInt32() == 901 && CaptureRequested != null) CaptureRequested(this, EventArgs.Empty);
        base.WndProc(ref message);
    }
}
'@
[Windows.Forms.Application]::EnableVisualStyles()
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$directory = Split-Path -Parent $ConfigPath
$config = $null
$lease = $null
$session = $null
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$form = New-Object IdentTrainingWindow
$form.Text = 'Code9 IDENT: показ экранов'
$form.ClientSize = New-Object Drawing.Size(520, 416)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$guide = New-Object Windows.Forms.Label
$guide.Location = New-Object Drawing.Point(18, 16)
$guide.Size = New-Object Drawing.Size(484, 130)
$guide.Text = "Показ экранов IDENT: календарь, выделенный интервал, меню записи, новый прием, выбранный пациент.`r`n`r`nРобот ничего не вводит и не сохраняет. Для показа используйте согласованные тестовые данные."
$form.Controls.Add($guide)
$counter = New-Object Windows.Forms.Label
$counter.Location = New-Object Drawing.Point(18, 150)
$counter.Size = New-Object Drawing.Size(484, 24)
$counter.Text = 'Снимков: 0. Осталось: 15:00.'
$form.Controls.Add($counter)
$delayed = New-Object Windows.Forms.Button
$delayed.Location = New-Object Drawing.Point(18, 181)
$delayed.Size = New-Object Drawing.Size(236, 36)
$delayed.Text = 'Снимок через 8 секунд'
$form.Controls.Add($delayed)
$menuDelayed = New-Object Windows.Forms.Button
$menuDelayed.Location = New-Object Drawing.Point(266, 181)
$menuDelayed.Size = New-Object Drawing.Size(236, 36)
$menuDelayed.Text = 'Меню через 8 секунд'
$form.Controls.Add($menuDelayed)
$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(18, 228)
$status.Size = New-Object Drawing.Size(484, 64)
$status.Text = 'Ожидание показа. Ctrl+Alt+F8 в IDENT или снимок с задержкой.'
$form.Controls.Add($status)
$privacy = New-Object Windows.Forms.Label
$privacy.Location = New-Object Drawing.Point(18, 294)
$privacy.Size = New-Object Drawing.Size(484, 40)
$privacy.Font = New-Object Drawing.Font('Segoe UI', 9)
$privacy.Text = 'Текст IDENT остается в локальном архиве. На сервер передаются только статус показа и счетчики, без данных пациентов.'
$form.Controls.Add($privacy)
$finish = New-Object Windows.Forms.Button
$finish.Location = New-Object Drawing.Point(18, 362)
$finish.Size = New-Object Drawing.Size(236, 36)
$finish.Text = 'Завершить и собрать архив'
$finish.Enabled = $false
$form.Controls.Add($finish)
$cancel = New-Object Windows.Forms.Button
$cancel.Location = New-Object Drawing.Point(266, 362)
$cancel.Size = New-Object Drawing.Size(236, 36)
$cancel.Text = 'Закрыть показ'
$form.Controls.Add($cancel)
$script:TrainingFinished = $false

function Stop-TrainingSession {
    if ($null -ne $session -and $null -ne $session.Current) { return }
    if ($null -ne $session) { $session.CaptureAt = $null }
    $delayed.Enabled = $false
    $menuDelayed.Enabled = $false
    $timer.Stop()
    $form.ReleaseCapture()
    if ($null -ne $script:TrainingLease) { $script:TrainingLease.Dispose(); $script:TrainingLease = $null }
    $script:TrainingFinished = $true
}

function Invoke-TrainingCapture {
    param([ValidateSet('window','menu')][string]$Surface = 'window')
    try {
        if ($script:TrainingFinished -or $null -ne $session.Current) { return }
        $session.CaptureAt = $null
        $target = $form.ForegroundTarget()
        $foregroundPid = [int]$target[1]
        $targetCheck = ''
        $verifiedTarget = Get-RobotCaptureTarget $config $target[0] $foregroundPid ([ref]$targetCheck)
        $session.Progress.TargetCheck = $targetCheck
        if ($null -eq $verifiedTarget) {
            $status.Text = if ($targetCheck -eq 'self_window') {
                'Скан не начат: активно окно показа. Переключитесь в форму IDENT и нажмите Ctrl+Alt+F8. Предыдущие снимки сохранены.'
            } else {
                'Скан не начат: окно не распознано как IDENT. Код проверки: ' + $targetCheck + '. Предыдущие снимки сохранены.'
            }
            $session.Progress.State = 'waiting'; $session.Progress.ErrorCode = 'wrong_window'
            [void](Write-RobotCaptureProgress $session.Progress -Force)
            [System.Media.SystemSounds]::Exclamation.Play()
            return
        }
        if (Start-RobotTrainingCapture $session (Join-Path $PSScriptRoot 'Start-IdentRobot.ps1') $ConfigPath $target[0] $foregroundPid -Surface $Surface) {
            $status.Text = 'Сохраняется состояние IDENT. Дождитесь сигнала; затем переходите к следующему экрану.'
            $finish.Enabled = $false
            $delayed.Enabled = $false
            $menuDelayed.Enabled = $false
        }
    } catch {
        $status.Text = 'Скан не получен. Предыдущие снимки сохранены. Повторите показ нужного экрана IDENT.'
        $session.Progress.State = 'failed'; $session.Progress.ErrorCode = 'scan_failed'
        [void](Write-RobotCaptureProgress $session.Progress -Force)
        [System.Media.SystemSounds]::Exclamation.Play()
    }
}

try {
    $config = Read-RobotTrainingConfiguration $ConfigPath
    if ($PreviewPath) {
        $form.Opacity = 0
        $form.ShowInTaskbar = $false
        $form.Show()
        [Windows.Forms.Application]::DoEvents()
        $bitmap = [Drawing.Bitmap]::new($form.Width, $form.Height)
        try { $form.DrawToBitmap($bitmap, [Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save($PreviewPath) } finally { $bitmap.Dispose() }
        exit
    }
    $choice = [Windows.Forms.MessageBox]::Show(
        'Начать показ? Робот не нажимает кнопки и не создает записи. Текст IDENT остается в локальном архиве и может содержать данные пациентов. На сервер передаются только статус показа, счетчики и код ошибки, без текста экранов.',
        'Показ экранов IDENT', 'OKCancel', 'Information')
    if ($choice -ne 'OK') { exit }
    $script:TrainingLease = Enter-RobotInteractionLease -Directory $directory -Training
    if ($null -eq $script:TrainingLease) { throw 'Сейчас выполняется заявка или уже открыт показ. Дождитесь завершения, не прерывая запись.' }
    $pending = Join-Path $directory 'execution-pending.json'
    if (Test-Path -LiteralPath $pending) { throw 'Предыдущая запись требует проверки в IDENT. Показ пока не запускается.' }
    $agentConfigPath = Join-Path (Split-Path -Parent $directory) 'config.local.json'
    if (Test-Path -LiteralPath $agentConfigPath) {
        $agentConfig = Get-Content -LiteralPath $agentConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([bool]$agentConfig.features.robotEnabled) { throw 'Выключите робота в агенте перед показом.' }
    }
    $session = New-RobotTrainingSession $directory
    if (-not $form.RegisterCapture()) { throw 'Ctrl+Alt+F8 уже используется другой программой. Закройте предыдущий показ и повторите запуск.' }
    [void](Write-RobotCaptureProgress $session.Progress -Force)
    $form.add_CaptureRequested({
        if ($script:TrainingFinished -or $null -ne $session.Current) { return }
        $session.Progress.Hotkeys = [Math]::Min(10000, $session.Progress.Hotkeys + 1)
        Invoke-TrainingCapture
    })
    $delayed.Add_Click({
        if ($script:TrainingFinished) { return }
        if ($null -ne $session.CaptureAt) {
            $session.CaptureAt = $null
            $status.Text = 'Отсчет отменен. Снимки сохранены.'
        } elseif (Set-RobotTrainingCaptureDelay $session) {
            $status.Text = 'Скан через 8 секунд. Перейдите в нужное окно IDENT и оставьте его открытым.'
        }
    })
    $menuDelayed.Add_Click({
        if ($script:TrainingFinished) { return }
        if ($null -ne $session.CaptureAt) {
            $session.CaptureAt = $null
            $status.Text = 'Отсчет отменен. Снимки сохранены.'
        } elseif (Set-RobotTrainingCaptureDelay $session -Surface menu) {
            $status.Text = 'Откройте меню ПКМ в IDENT. Наведите курсор на пункт меню, не нажимая, и дождитесь сигнала.'
        }
    })
    $timer.Add_Tick({
        try {
            $wasCapturing = $null -ne $session.Current
            $completedSurface = if ($wasCapturing) { $session.Current.Surface } else { 'window' }
            Update-RobotTrainingCapture $session
            if (Test-RobotTrainingCaptureDue $session) { Invoke-TrainingCapture -Surface $session.CaptureSurface }
            $remaining = [Math]::Max(0, [int][Math]::Ceiling(900 - ([DateTimeOffset]::Now - $session.StartedAt).TotalSeconds))
            $counter.Text = 'Снимков: {0}. Осталось: {1:00}:{2:00}.' -f $session.Captures.Count, [int][Math]::Floor($remaining / 60), ($remaining % 60)
            $pendingWindow = $null -ne $session.CaptureAt -and $session.CaptureSurface -eq 'window'
            $pendingMenu = $null -ne $session.CaptureAt -and $session.CaptureSurface -eq 'menu'
            $delayed.Text = if ($pendingWindow) { 'Отменить отсчет' } else { 'Снимок через 8 секунд' }
            $menuDelayed.Text = if ($pendingMenu) { 'Отменить отсчет' } else { 'Меню через 8 секунд' }
            $canArm = -not $script:TrainingFinished -and $null -eq $session.Current -and $remaining -gt 0 -and $session.Attempt -lt 12
            $delayed.Enabled = $canArm -and -not $pendingMenu
            $menuDelayed.Enabled = $canArm -and -not $pendingWindow
            if ($null -ne $session.CaptureAt) {
                $seconds = [Math]::Max(0, [int][Math]::Ceiling(($session.CaptureAt - [DateTimeOffset]::Now).TotalSeconds))
                $status.Text = if ($pendingMenu) { "Меню через $seconds сек. Откройте ПКМ в IDENT и наведите курсор на пункт меню, не нажимая." }
                    else { "Скан через $seconds сек. Оставьте нужное окно IDENT открытым." }
            }
            [void](Write-RobotCaptureProgress $session.Progress)
            if ($wasCapturing -and $null -eq $session.Current) {
                $status.Text = if ($session.LastError -and $completedSurface -eq 'menu') {
                    'Меню не получено. Откройте его в IDENT и наведите курсор на пункт, не нажимая. Предыдущие снимки сохранены.'
                } elseif ($session.LastError) { 'Скан не получен. Повторите Ctrl+Alt+F8 на нужном экране IDENT.' }
                elseif ($completedSurface -eq 'menu') { 'Меню сохранено. Не выбирайте пункты, меняющие расписание. Можно собрать архив.' } else {
                    "Снимков: $($session.Captures.Count). Готово. Откройте следующий экран и нажмите Ctrl+Alt+F8."
                }
                if ($session.LastError) { [System.Media.SystemSounds]::Exclamation.Play() }
                else { [System.Media.SystemSounds]::Asterisk.Play() }
            }
            $finish.Enabled = $null -eq $session.Current -and $session.Captures.Count -gt 0
            if (([DateTimeOffset]::Now - $session.StartedAt).TotalMinutes -ge 15 -and $null -eq $session.Current) {
                Stop-TrainingSession
                $session.Progress.State = 'expired'
                [void](Write-RobotCaptureProgress $session.Progress -Force)
                $status.Text = 'Время показа завершилось. Снимки сохранены; соберите архив кнопкой ниже.'
            }
        } catch {
            $status.Text = 'Ошибка проверки скана. Исходные файлы сохранены, IDENT не изменен.'
            $session.Progress.State = 'failed'; $session.Progress.ErrorCode = 'status_failed'
            [void](Write-RobotCaptureProgress $session.Progress -Force)
        }
    })
    $finish.Add_Click({
        try {
            if (-not $session.Archive) { [void](Export-RobotTrainingSession $session) }
            Stop-TrainingSession
            $status.Text = "Архив готов: $($session.Captures.Count) снимков. Робот не включен. Передайте архив специалисту."
            $finish.Text = 'Показать готовый архив'
            try {
                Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($session.Archive)`""
            } catch {
                $status.Text = 'Архив сохранен, но Проводник не открылся. Исходные снимки также сохранены.'
            }
        } catch {
            $status.Text = $_.Exception.Message
            $session.Progress.State = 'failed'; $session.Progress.ErrorCode = 'export_failed'
            [void](Write-RobotCaptureProgress $session.Progress -Force)
        }
    })
    $cancel.Add_Click({ $form.Close() })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($null -ne $session.Current) {
            $eventArgs.Cancel = $true
            $status.Text = 'Скан еще выполняется. Он завершится или будет остановлен через минуту.'
        }
    })
    $timer.Start()
    [Windows.Forms.Application]::Run($form)
}
catch {
    $message = switch -Exact ($_.Exception.Message) {
        'ROBOT_TRAINING_CONFIG_MISSING' { 'Не найден профиль робота. Дождитесь завершения обновления агента и повторите показ.' }
        'ROBOT_TRAINING_CONFIG_INVALID' { 'Профиль робота поврежден или неполон. Показ не запущен; передайте ошибку специалисту.' }
        default { $_.Exception.Message }
    }
    [void][Windows.Forms.MessageBox]::Show($message, 'Показ не запущен', 'OK', 'Warning')
    exit 1
}
finally {
    if ($null -ne $session) {
        if ($session.Progress.State -notin @('completed','expired')) { $session.Progress.State = 'closed' }
        [void](Write-RobotCaptureProgress $session.Progress -Force)
    }
    $timer.Stop()
    $timer.Dispose()
    $form.ReleaseCapture()
    if ($null -ne $session -and $null -ne $session.Current) {
        $session.Current.Job.Dispose()
        try { if (-not $session.Current.Process.HasExited) { $session.Current.Process.Kill(); [void]$session.Current.Process.WaitForExit(1500) } } catch { }
        $session.Current.Process.Dispose()
    }
    if (Get-Variable TrainingLease -Scope Script -ErrorAction SilentlyContinue) {
        if ($null -ne $script:TrainingLease) { $script:TrainingLease.Dispose() }
    }
    $form.Dispose()
}
