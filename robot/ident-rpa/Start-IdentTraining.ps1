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
$form.ClientSize = New-Object Drawing.Size(520, 346)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$guide = New-Object Windows.Forms.Label
$guide.Location = New-Object Drawing.Point(18, 16)
$guide.Size = New-Object Drawing.Size(484, 154)
$guide.Text = "Откройте нужный экран IDENT и нажмите Ctrl+Alt+F8.`r`n`r`nСохраните по очереди: календарь, новый прием, выбранного пациента, настройки даты и времени.`r`n`r`nРобот ничего не вводит и не сохраняет. Для показа используйте согласованные тестовые данные."
$form.Controls.Add($guide)
$status = New-Object Windows.Forms.Label
$status.Location = New-Object Drawing.Point(18, 176)
$status.Size = New-Object Drawing.Size(484, 64)
$status.Text = 'Снимков: 0. Ожидание показа.'
$form.Controls.Add($status)
$privacy = New-Object Windows.Forms.Label
$privacy.Location = New-Object Drawing.Point(18, 240)
$privacy.Size = New-Object Drawing.Size(484, 40)
$privacy.Font = New-Object Drawing.Font('Segoe UI', 9)
$privacy.Text = 'Сохраняется текст интерфейса, в том числе видимые данные пациентов. Архив остается на этом ПК и автоматически не отправляется.'
$form.Controls.Add($privacy)
$finish = New-Object Windows.Forms.Button
$finish.Location = New-Object Drawing.Point(18, 292)
$finish.Size = New-Object Drawing.Size(236, 36)
$finish.Text = 'Завершить и собрать архив'
$finish.Enabled = $false
$form.Controls.Add($finish)
$cancel = New-Object Windows.Forms.Button
$cancel.Location = New-Object Drawing.Point(266, 292)
$cancel.Size = New-Object Drawing.Size(236, 36)
$cancel.Text = 'Закрыть показ'
$form.Controls.Add($cancel)
$script:TrainingFinished = $false

function Stop-TrainingSession {
    if ($null -ne $session -and $null -ne $session.Current) { return }
    $timer.Stop()
    $form.ReleaseCapture()
    if ($null -ne $script:TrainingLease) { $script:TrainingLease.Dispose(); $script:TrainingLease = $null }
    $script:TrainingFinished = $true
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
        'Начать показ? Робот не нажимает кнопки и не создает записи. В локальном архиве сохранится видимый текст IDENT, который может содержать данные пациентов. Автоматической отправки нет.',
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
    $form.add_CaptureRequested({
        try {
            if ($script:TrainingFinished -or $null -ne $session.Current) { return }
            $target = $form.ForegroundTarget()
            $foregroundPid = [int]$target[1]
            $process = Get-Process -Id $foregroundPid -ErrorAction Stop
            if ($process.Id -eq $PID -or $process.MainWindowTitle -match 'Code9 IDENT|PowerShell|Windows Terminal' -or
                ([string]$config.ident.processName -and $process.ProcessName -ne [string]$config.ident.processName) -or
                ([string]$config.ident.windowTitleRegex -and $process.MainWindowTitle -notmatch [string]$config.ident.windowTitleRegex)) {
                $status.Text = 'Перейдите в IDENT и нажмите Ctrl+Alt+F8 там.'
                return
            }
            if (Start-RobotTrainingCapture $session (Join-Path $PSScriptRoot 'Start-IdentRobot.ps1') $ConfigPath $target[0] $foregroundPid) {
                $status.Text = 'Сохраняется состояние IDENT. Дождитесь сигнала; затем переходите к следующему экрану.'
                $finish.Enabled = $false
            }
        } catch { $status.Text = $_.Exception.Message }
    })
    $timer.Add_Tick({
        try {
            $wasCapturing = $null -ne $session.Current
            Update-RobotTrainingCapture $session
            if ($wasCapturing -and $null -eq $session.Current) {
                $status.Text = if ($session.LastError) { 'Скан не получен. Повторите Ctrl+Alt+F8 на нужном экране IDENT.' } else {
                    "Снимков: $($session.Captures.Count). Готово. Откройте следующий экран и нажмите Ctrl+Alt+F8."
                }
                if ($session.LastError) { [System.Media.SystemSounds]::Exclamation.Play() }
                else { [System.Media.SystemSounds]::Asterisk.Play() }
            }
            $finish.Enabled = $null -eq $session.Current -and $session.Captures.Count -gt 0
            if (([DateTimeOffset]::Now - $session.StartedAt).TotalMinutes -ge 15 -and $null -eq $session.Current) {
                Stop-TrainingSession
                $status.Text = 'Время показа завершилось. Снимки сохранены; соберите архив кнопкой ниже.'
            }
        } catch { $status.Text = 'Ошибка проверки скана. Исходные файлы сохранены, IDENT не изменен.' }
    })
    $finish.Add_Click({
        try {
            if (-not $session.Archive) { [void](Export-RobotTrainingSession $session) }
            Stop-TrainingSession
            $status.Text = "Архив готов: $($session.Captures.Count) снимков. Робот не включен. Передайте архив специалисту."
            $finish.Text = 'Показать готовый архив'
            Start-Process -FilePath 'explorer.exe' -WindowStyle Hidden -ArgumentList "/select,`"$($session.Archive)`""
        } catch { $status.Text = $_.Exception.Message }
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
