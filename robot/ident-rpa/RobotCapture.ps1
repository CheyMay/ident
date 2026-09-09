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

function New-RobotTrainingSession {
    param([string]$Directory)
    $sessionId = [guid]::NewGuid().ToString('N')
    $path = Join-Path $Directory ('training\' + $sessionId)
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return [pscustomobject]@{
        Id = $sessionId; Directory = $path; StartedAt = [DateTimeOffset]::Now
        Captures = (New-Object 'System.Collections.Generic.List[object]')
        Attempt = 0; Current = $null; Archive = ''; LastError = ''
    }
}

function Start-RobotTrainingCapture {
    param([object]$Session, [string]$ScannerPath, [string]$ConfigPath)
    if ($null -ne $Session.Current) { return $false }
    if ($Session.Attempt -ge 12) { throw 'Capture limit reached. Finish this session.' }
    $Session.Attempt++
    $directory = Join-Path $Session.Directory ('capture-{0:d2}' -f $Session.Attempt)
    New-Item -ItemType Directory -Path $directory | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $reportPath = Join-Path $directory 'report.json'
    $started = [DateTimeOffset]::Now
    $args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScannerPath`" -Mode Calibrate " +
        "-ConfigPath `"$ConfigPath`" -ReportPath `"$reportPath`" -CaptureId $id"
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
        $job.Dispose()
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
            $process.Dispose()
        }
        throw
    }
    try { $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $Session.Current = [pscustomobject]@{ Process = $process; Job = $job; ReportPath = $reportPath; CaptureId = $id; StartedAt = $started }
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
        $Session.Captures.Add([pscustomobject]@{
            Number = $Session.Attempt; ReportPath = $capture.ReportPath; CaptureId = $capture.CaptureId
            StartedAt = $capture.StartedAt; Path = $verified.Path; Sha256 = [string]$verified.Report.captureSha256
        })
    }
    catch { $Session.LastError = $_.Exception.Message }
    finally {
        # Keep the handle while a provider is still stopping; never launch a second scanner.
        if ($capture.Process.HasExited) { $capture.Job.Dispose(); $capture.Process.Dispose(); $Session.Current = $null }
    }
}

function Export-RobotTrainingSession {
    param([object]$Session)
    if ($null -ne $Session.Current) { throw 'Wait for the current capture to finish.' }
    if ($Session.Captures.Count -eq 0) { throw 'There are no successful captures in this session.' }
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
    return $archivePath
}
