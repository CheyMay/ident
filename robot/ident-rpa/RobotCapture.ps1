function Initialize-RobotCaptureJob {
    if ('IdentCaptureJob' -as [type]) { return }
    # https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public sealed class IdentCaptureJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern SafeFileHandle CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(SafeFileHandle job, int type, ref ExtendedLimits info, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
    readonly SafeFileHandle handle;
    public IdentCaptureJob() : this(false) {}
    public IdentCaptureJob(bool independentChildren) {
        handle = CreateJobObject(IntPtr.Zero, null);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
        var limits = new ExtendedLimits();
        limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        // Supervisor owns the worker, while the worker owns execution jobs.
        // The separately launched updater must survive the worker's exit.
        if (independentChildren) limits.Basic.Flags |= 0x1000; // JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK
        if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf(limits))) {
            int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error);
        }
    }
    public void Attach(Process process) {
        if (!AssignProcessToJobObject(handle, process.Handle) && !process.HasExited) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose() { handle.Dispose(); }
}
'@
}

function Get-RobotCaptureWindowMetadata {
    param([long]$WindowHandle)
    if (-not ('IdentCaptureWindowMetadata' -as [type])) {
        # https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getancestor
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public sealed class IdentCaptureWindowMetadata {
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    public long Handle, OwnerHandle;
    public uint ProcessId, OwnerProcessId;
    public bool Visible;
    public string Title, OwnerTitle;
    static string TitleOf(IntPtr hwnd) {
        var text = new StringBuilder(1024);
        GetWindowText(hwnd, text, text.Capacity);
        return text.ToString();
    }
    public static IdentCaptureWindowMetadata Read(long handle) {
        var window = new IntPtr(handle);
        var owner = GetAncestor(window, 3);
        var result = new IdentCaptureWindowMetadata();
        result.Handle = handle; result.OwnerHandle = owner.ToInt64();
        GetWindowThreadProcessId(window, out result.ProcessId);
        GetWindowThreadProcessId(owner, out result.OwnerProcessId);
        result.Visible = IsWindowVisible(window) && !IsIconic(window);
        result.Title = TitleOf(window); result.OwnerTitle = TitleOf(owner);
        return result;
    }
}
'@
    }
    return [IdentCaptureWindowMetadata]::Read($WindowHandle)
}

function Get-RobotCaptureTarget {
    param([object]$Config, [long]$WindowHandle, [int]$ProcessId)
    if ($WindowHandle -eq 0 -or $ProcessId -le 0 -or $ProcessId -eq $PID) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if ($process.ProcessName -match '^(powershell|pwsh|cmd|WindowsTerminal|explorer|AnyDesk)$') { return $null }
    $processName = [string]$Config.ident.processName
    $titleRegex = [string]$Config.ident.windowTitleRegex
    if ((-not $processName -and -not $titleRegex) -or ($processName -and $process.ProcessName -ne $processName)) { return $null }
    $window = Get-RobotCaptureWindowMetadata $WindowHandle
    if ($null -eq $window -or $window.Handle -ne $WindowHandle -or
        $window.ProcessId -ne $ProcessId -or -not $window.Visible) { return $null }
    $ownTitleMatches = $window.Title -notmatch 'Code9 IDENT|PowerShell|Windows Terminal' -and $window.Title -match $titleRegex
    $ownerTitleMatches = $window.OwnerHandle -ne 0 -and $window.OwnerProcessId -eq $ProcessId -and
        $window.OwnerTitle -notmatch 'Code9 IDENT|PowerShell|Windows Terminal' -and $window.OwnerTitle -match $titleRegex
    if ($titleRegex -and -not $ownTitleMatches -and -not $ownerTitleMatches) { return $null }
    # Verify ownership only; the scanner still captures the exact requested HWND, never its owner as a fallback.
    return [pscustomobject]@{ process = $process; handle = $WindowHandle }
}

function Get-VerifiedRobotCapture {
    param([string]$ReportPath, [string]$CaptureId, [DateTimeOffset]$StartedAfter)
    $reportFile = Get-Item -LiteralPath $ReportPath -ErrorAction Stop
    if ($reportFile.Length -gt 1MB) { throw 'Capture report exceeds the size limit.' }
    $report = Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($report.PSObject.Properties.Name -notcontains 'captureId' -or
        [string]$report.captureId -cne $CaptureId -or [string]::IsNullOrWhiteSpace($CaptureId)) {
        throw 'Stale capture report. Repeat the capture.'
    }
    $generated = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$report.generatedAt, [ref]$generated) -or
        $generated -lt $StartedAfter -or $generated -gt [DateTimeOffset]::Now.AddMinutes(1)) {
        throw 'Capture timestamp does not match this attempt.'
    }
    $directory = [IO.Path]::GetFullPath((Split-Path -Parent $ReportPath)).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath([string]$report.capturePath)
    if (-not $path.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetDirectoryName($path).TrimEnd('\') -ine $directory.TrimEnd('\') -or
        [IO.Path]::GetFileName($path) -notmatch '^ui-tree-[0-9-]+\.json$') {
        throw 'Invalid capture path.'
    }
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.Length -le 0 -or $file.Length -gt 5MB -or $file.Length -ne [long]$report.captureBytes -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine [string]$report.captureSha256) {
        throw 'Capture file is damaged or changed.'
    }
    $decoded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = @($decoded)
    if ([int]$report.scanSchemaVersion -ne 2 -or $rows.Count -ne [int]$report.controlsScanned -or
        $rows.Count -eq 0 -or $rows[0].PSObject.Properties.Name -notcontains 'rootName' -or
        $rows[0].PSObject.Properties.Name -notcontains 'patterns') { throw 'Unsupported or incomplete capture schema.' }
    if (-not [bool]$report.ok) { throw 'IDENT window is hidden or unavailable. Open it and repeat the capture.' }
    return [pscustomobject]@{ Path = $path; Report = $report }
}

function Read-RobotTrainingConfiguration {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'ROBOT_TRAINING_CONFIG_MISSING' }
    try {
        if ((Get-Item -LiteralPath $Path).Length -gt 1MB) { throw 'Profile size limit.' }
        $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $config -or $null -eq $config.ident) { throw 'IDENT target missing.' }
        foreach ($field in @('processName', 'windowTitleRegex')) {
            if ($config.ident.PSObject.Properties.Name -notcontains $field) {
                $config.ident | Add-Member -NotePropertyName $field -NotePropertyValue ''
            }
            if ($config.ident.$field -isnot [string]) { throw 'Target must be a string.' }
        }
        if ([string]::IsNullOrWhiteSpace($config.ident.processName) -and [string]::IsNullOrWhiteSpace($config.ident.windowTitleRegex)) {
            throw 'Unrestricted desktop capture is not allowed.'
        }
        if ($config.ident.windowTitleRegex) { $null = [regex]::new($config.ident.windowTitleRegex) }
        if ($null -eq $config.workflow -or $null -eq $config.selectors -or $null -eq $config.workflow.steps) { throw 'Incomplete profile.' }
        return $config
    }
    catch { throw 'ROBOT_TRAINING_CONFIG_INVALID' }
}

function New-RobotCaptureProgress {
    param([string]$Directory, [ValidateSet('training','calibration')][string]$Kind)
    return [pscustomobject]@{
        Directory = [IO.Path]::GetFullPath($Directory); Kind = $Kind; Id = [guid]::NewGuid().ToString('N')
        State = 'waiting'; Captured = 0; Attempt = 0; Hotkeys = 0; Controls = 0
        ErrorCode = ''; ArchiveReady = $false; LastWrittenAt = [DateTimeOffset]::MinValue
    }
}

function Write-RobotCaptureProgress {
    param([object]$Progress, [switch]$Force)
    if ($null -eq $Progress) { return $false }
    if (-not $Force -and ([DateTimeOffset]::Now - $Progress.LastWrittenAt).TotalSeconds -lt 3) { return $true }
    $temporary = ''
    try {
        if ($Progress.Kind -notin @('training','calibration') -or $Progress.Id -cnotmatch '^[a-f0-9]{32}$') { return $false }
        $path = Join-Path $Progress.Directory ($Progress.Kind + '-status.json')
        $temporary = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
        # Only operational metadata; never serialize exceptions, controls or config objects.
        $payload = [ordered]@{
            schemaVersion = 1; sessionId = $Progress.Id; state = $Progress.State
            updatedAt = [DateTimeOffset]::Now.ToString('o'); captured = [int]$Progress.Captured
            attempt = [int]$Progress.Attempt; hotkeys = [int]$Progress.Hotkeys; controls = [int]$Progress.Controls
            errorCode = [string]$Progress.ErrorCode; archiveReady = [bool]$Progress.ArchiveReady
        }
        $payload | ConvertTo-Json -Compress | Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $path -Force
        $Progress.LastWrittenAt = [DateTimeOffset]::Now
        return $true
    }
    catch { return $false }
    finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Read-RobotCaptureProgress {
    param([string]$Directory, [ValidateSet('training','calibration')][string]$Kind)
    $result = [ordered]@{
        State = 'not_started'; SessionId = ''; Captured = 0; Attempt = 0; Hotkeys = 0; Controls = 0
        ErrorCode = ''; ArchiveReady = $false; UpdatedAt = ''; Active = $false; Recent = $false
    }
    try {
        $path = Join-Path $Directory ($Kind + '-status.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
        $file = Get-Item -LiteralPath $path
        if ($file.Length -gt 16KB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid status file.' }
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try { $data = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose(); $stream.Dispose() }
        if ($data.schemaVersion -ne 1 -or $data.sessionId -cnotmatch '^[a-f0-9]{32}$' -or
            $data.state -notin @('waiting','scanning','captured','failed','completed','closed','expired')) { throw 'Invalid status.' }
        $time = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$data.updatedAt, [ref]$time) -or $time -gt [DateTimeOffset]::Now.AddSeconds(60)) { throw 'Invalid status time.' }
        foreach ($field in @('captured','attempt','hotkeys','controls')) {
            $number = 0
            if (-not [int]::TryParse([string]$data.$field, [ref]$number) -or $number -lt 0 -or $number -gt 10000) { throw 'Invalid counter.' }
        }
        if ($data.archiveReady -isnot [bool]) { throw 'Invalid archive state.' }
        $errorCode = if ([string]$data.errorCode -in @('', 'wrong_window','scan_failed','scan_timeout','capture_invalid','export_failed','start_failed','status_failed')) {
            [string]$data.errorCode
        } else { 'status_failed' }
        $age = ([DateTimeOffset]::Now - $time).TotalSeconds
        $active = $data.state -in @('waiting','scanning','captured','failed') -and -not ($Kind -eq 'calibration' -and $data.state -eq 'failed')
        $result.State = if ($active -and $age -gt 20) { 'unresponsive' } else { [string]$data.state }
        $result.SessionId = [string]$data.sessionId
        foreach ($field in @('Captured','Attempt','Hotkeys','Controls')) { $result[$field] = [int]$data.$field }
        $result.ErrorCode = $errorCode; $result.ArchiveReady = [bool]$data.archiveReady
        $result.UpdatedAt = $time.ToString('o'); $result.Active = $active -and $age -le 20
        $result.Recent = $age -le 30
    }
    catch { $result.State = 'unavailable'; $result.ErrorCode = 'status_failed' }
    return $result
}

function New-RobotTrainingSession {
    param([string]$Directory)
    $sessionId = [guid]::NewGuid().ToString('N')
    $path = Join-Path $Directory ('training\' + $sessionId)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $progress = New-RobotCaptureProgress $Directory 'training'
    $progress.Id = $sessionId
    return [pscustomobject]@{
        Id = $sessionId; Directory = $path; StartedAt = [DateTimeOffset]::Now
        Captures = (New-Object 'System.Collections.Generic.List[object]')
        Attempt = 0; Current = $null; Archive = ''; LastError = ''; CaptureAt = $null
        Progress = $progress
    }
}

function Set-RobotTrainingCaptureDelay {
    param([object]$Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -ne $Session.Current -or $Session.Archive -or $Session.Attempt -ge 12 -or
        $Session.Progress.State -in @('closed','completed','expired') -or
        ($Now - $Session.StartedAt).TotalMinutes -ge 15) { return $false }
    $Session.CaptureAt = $Now.AddSeconds(8)
    $Session.Progress.State = 'waiting'; $Session.Progress.ErrorCode = ''
    [void](Write-RobotCaptureProgress $Session.Progress -Force)
    return $true
}

function Test-RobotTrainingCaptureDue {
    param([object]$Session, [DateTimeOffset]$Now = [DateTimeOffset]::Now)
    if ($null -eq $Session.CaptureAt) { return $false }
    if ($null -ne $Session.Current -or $Session.Archive -or $Session.Attempt -ge 12 -or
        $Session.Progress.State -in @('closed','completed','expired') -or
        ($Now - $Session.StartedAt).TotalMinutes -ge 15) {
        $Session.CaptureAt = $null
        return $false
    }
    if ($Now -lt $Session.CaptureAt) { return $false }
    $Session.CaptureAt = $null
    return $true
}

function Start-RobotTrainingCapture {
    param([object]$Session, [string]$ScannerPath, [string]$ConfigPath, [long]$WindowHandle = 0, [int]$ProcessId = 0)
    if ($null -ne $Session.Current) { return $false }
    if ($WindowHandle -eq 0 -or $ProcessId -le 0) { throw 'Select an IDENT window before capturing.' }
    if ($Session.Archive -or ([DateTimeOffset]::Now - $Session.StartedAt).TotalMinutes -ge 15) {
        throw 'This observation session has ended. Finish it and start a new session.'
    }
    if ($Session.Attempt -ge 12) { throw 'Capture limit reached. Finish this session.' }
    $Session.CaptureAt = $null
    $Session.Attempt++
    $Session.Progress.Attempt = $Session.Attempt
    $Session.Progress.State = 'scanning'; $Session.Progress.ErrorCode = ''
    [void](Write-RobotCaptureProgress $Session.Progress -Force)
    $directory = Join-Path $Session.Directory ('capture-{0:d2}' -f $Session.Attempt)
    New-Item -ItemType Directory -Path $directory | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $reportPath = Join-Path $directory 'report.json'
    $started = [DateTimeOffset]::Now
    $args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScannerPath`" -Mode Observe " +
        "-ConfigPath `"$ConfigPath`" -ReportPath `"$reportPath`" -CaptureId $id " +
        "-ObservedWindowHandle $WindowHandle -ObservedProcessId $ProcessId"
    Initialize-RobotCaptureJob
    $job = New-Object IdentCaptureJob
    $process = $null
    try {
        $process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $args -PassThru `
            -RedirectStandardOutput (Join-Path $directory 'output.log') -RedirectStandardError (Join-Path $directory 'error.log')
        $null = $process.Handle
        $job.Attach($process)
    }
    catch {
        $Session.Progress.State = 'failed'; $Session.Progress.ErrorCode = 'start_failed'
        [void](Write-RobotCaptureProgress $Session.Progress -Force)
        $job.Dispose()
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
            $process.Dispose()
        }
        throw
    }
    try { $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $Session.Current = [pscustomobject]@{
        Process = $process; Job = $job; ReportPath = $reportPath; CaptureId = $id; StartedAt = $started
        WindowHandle = $WindowHandle; TargetProcessId = $ProcessId
    }
    $Session.LastError = ''
    return $true
}

function Update-RobotTrainingCapture {
    param([object]$Session, [int]$TimeoutSeconds = 60)
    $capture = $Session.Current
    if ($null -eq $capture) { return }
    $timedOut = ([DateTimeOffset]::Now - $capture.StartedAt).TotalSeconds -ge $TimeoutSeconds
    if (-not $capture.Process.HasExited -and -not $timedOut) { return }
    try {
        if ($timedOut -and -not $capture.Process.HasExited) {
            $capture.Process.Kill()
            if (-not $capture.Process.WaitForExit(1500)) { throw 'Scanner is stopping. Wait before the next capture.' }
            throw 'Scanner timed out. No actions were sent to IDENT. Repeat the capture.'
        }
        [void]$capture.Process.WaitForExit(0)
        if ($null -eq $capture.Process.ExitCode -or $capture.Process.ExitCode -ne 0) { throw "Scanner exited with code $($capture.Process.ExitCode). Repeat the capture." }
        $verified = Get-VerifiedRobotCapture $capture.ReportPath $capture.CaptureId $capture.StartedAt
        if ($verified.Report.mode -ne 'observation' -or
            $verified.Report.observedWindowHandle -ne $capture.WindowHandle -or
            $verified.Report.observedProcessId -ne $capture.TargetProcessId -or
            [bool]$verified.Report.readyForUnattendedExecution) {
            throw 'The scanner returned a different window or an unexpected capture mode.'
        }
        $Session.Captures.Add([pscustomobject]@{
            Number = $Session.Attempt; ReportPath = $capture.ReportPath; CaptureId = $capture.CaptureId
            StartedAt = $capture.StartedAt; Path = $verified.Path; Sha256 = [string]$verified.Report.captureSha256
        })
        $Session.Progress.State = 'captured'; $Session.Progress.Captured = $Session.Captures.Count
        $Session.Progress.Controls = [int]$verified.Report.controlsScanned; $Session.Progress.ErrorCode = ''
    }
    catch {
        $Session.LastError = $_.Exception.Message
        $Session.Progress.State = 'failed'
        $Session.Progress.ErrorCode = if ($timedOut) { 'scan_timeout' } else { 'capture_invalid' }
    }
    finally {
        [void](Write-RobotCaptureProgress $Session.Progress -Force)
        # Keep the handle while a provider is still stopping; never launch a second scanner.
        if ($capture.Process.HasExited) { $capture.Job.Dispose(); $capture.Process.Dispose(); $Session.Current = $null }
    }
}

function Export-RobotTrainingSession {
    param([object]$Session)
    if ($null -ne $Session.Current) { throw 'Wait for the current capture to finish.' }
    if ($Session.Captures.Count -eq 0) { throw 'There are no successful captures in this session.' }
    $Session.CaptureAt = $null
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archivePath = Join-Path $Session.Directory 'IDENT-training.zip'
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $manifest = [ordered]@{
            schemaVersion = 1; sessionId = $Session.Id; startedAt = $Session.StartedAt.ToString('o')
            generatedAt = [DateTimeOffset]::Now.ToString('o'); actionsExecuted = 0; profileActivated = $false
            containsUiText = $true; captures = @()
        }
        foreach ($capture in $Session.Captures) {
            $verified = Get-VerifiedRobotCapture $capture.ReportPath $capture.CaptureId $capture.StartedAt
            if ($verified.Report.captureSha256 -ine $capture.Sha256) { throw 'Capture changed since it was recorded.' }
            $prefix = 'capture-{0:d2}/' -f $capture.Number
            # Explicit allowlist: never collect the config, credentials, screenshots or logs.
            $bytes = [IO.File]::ReadAllBytes($verified.Path)
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '') } finally { $hasher.Dispose() }
            if ($hash -ine $capture.Sha256) { throw 'Capture changed during export.' }
            $stream = $archive.CreateEntry($prefix + 'ui-tree.json', [IO.Compression.CompressionLevel]::Fastest).Open()
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            $entry = $archive.CreateEntry($prefix + 'summary.json')
            $summary = [ordered]@{
                captureId = $capture.CaptureId; generatedAt = $verified.Report.generatedAt
                sha256 = $verified.Report.captureSha256; bytes = $verified.Report.captureBytes
                controlsScanned = $verified.Report.controlsScanned; visibleControls = $verified.Report.visibleControls
                splitNameFieldsDetected = $verified.Report.splitNameFieldsDetected
                selectorsComplete = $verified.Report.selectorsComplete; readyForUnattendedExecution = $false
                checks = $verified.Report.checks; issues = $verified.Report.issues
            }
            $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
            try { $writer.Write(($summary | ConvertTo-Json -Depth 20)) } finally { $writer.Dispose() }
            $manifest.captures += [ordered]@{ number = $capture.Number; captureId = $capture.CaptureId; path = ($prefix + 'ui-tree.json'); sha256 = $capture.Sha256 }
        }
        $writer = [IO.StreamWriter]::new($archive.CreateEntry('session.json').Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write(($manifest | ConvertTo-Json -Depth 10)) } finally { $writer.Dispose() }
    }
    catch {
        $archive.Dispose()
        Remove-Item -LiteralPath $archivePath -Force
        throw
    }
    finally { $archive.Dispose() }
    $Session.Archive = $archivePath
    $Session.Progress.State = 'completed'; $Session.Progress.ArchiveReady = $true; $Session.Progress.ErrorCode = ''
    [void](Write-RobotCaptureProgress $Session.Progress -Force)
    return $archivePath
}
