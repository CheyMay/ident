[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$WorkerScriptPath = '',
    [int]$StaleAfterSeconds = 150,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}
if ([string]::IsNullOrWhiteSpace($WorkerScriptPath)) {
    $WorkerScriptPath = Join-Path $PSScriptRoot 'IdentWorker.ps1'
}

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$WorkerScriptPath = [IO.Path]::GetFullPath($WorkerScriptPath)
$baseDirectory = Split-Path -Parent $ConfigPath
$runtimeStatePath = Join-Path $baseDirectory 'runtime-state.json'
$supervisorStatePath = Join-Path $baseDirectory 'supervisor-state.json'
$updateStatusPath = Join-Path $baseDirectory 'update-status.json'
$commandDirectory = Join-Path $baseDirectory 'commands'
$restartRequestPath = Join-Path $commandDirectory 'restart-worker'
$logPath = Join-Path $baseDirectory 'logs\supervisor.log'
$script:Worker = $null
$script:RestartCount = 0
$script:LastRestartAt = $null
$script:LastError = ''
$script:StartedAt = (Get-Date).ToString('o')

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Write-SupervisorLog {
    param([string]$EventName, [hashtable]$Data = @{})

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        event = $EventName
        data = $Data
    }
    Add-Content -LiteralPath $logPath -Value ($entry | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
}

function Write-SupervisorState {
    param([string]$State)

    $workerId = 0
    if ($null -ne $script:Worker) {
        try {
            if (-not $script:Worker.HasExited) {
                $workerId = [int]$script:Worker.Id
            }
        }
        catch {}
    }
    $payload = [ordered]@{
        state = $State
        processId = $PID
        workerProcessId = $workerId
        startedAt = $script:StartedAt
        lastRestartAt = $script:LastRestartAt
        restartCount = $script:RestartCount
        lastError = $script:LastError
        updatedAt = (Get-Date).ToString('o')
    }
    $temporaryPath = "$supervisorStatePath.tmp-$PID"
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $supervisorStatePath -Force
}

function Test-UpdateInProgress {
    $status = Read-JsonFile -Path $updateStatusPath
    if ($null -eq $status -or [string]$status.status -ne 'applying') {
        return $false
    }
    $updatedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$status.updatedAt, [ref]$updatedAt)) {
        return $false
    }
    return (([DateTimeOffset]::Now - $updatedAt).TotalMinutes -le 5)
}

function Stop-WorkerTree {
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return
    }
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId, ParentProcessId)
        $pending = New-Object Collections.Generic.Queue[int]
        $pending.Enqueue($ProcessId)
        $descendants = New-Object Collections.Generic.List[int]
        while ($pending.Count -gt 0) {
            $parentId = $pending.Dequeue()
            foreach ($child in @($processes | Where-Object { [int]$_.ParentProcessId -eq $parentId })) {
                $childId = [int]$child.ProcessId
                $descendants.Add($childId)
                $pending.Enqueue($childId)
            }
        }
        for ($index = $descendants.Count - 1; $index -ge 0; $index--) {
            Stop-Process -Id $descendants[$index] -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-SupervisorLog -EventName 'process_tree_lookup_failed' -Data @{ message = $_.Exception.Message }
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Start-Worker {
    if (-not (Test-Path -LiteralPath $WorkerScriptPath -PathType Leaf)) {
        throw "Worker script not found: $WorkerScriptPath"
    }
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkerScriptPath`" -ConfigPath `"$ConfigPath`""
    $script:Worker = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -WindowStyle Hidden `
        -PassThru
    $script:RestartCount++
    $script:LastRestartAt = (Get-Date).ToString('o')
    $script:LastError = ''
    Write-SupervisorLog -EventName 'worker_started' -Data @{ processId = [int]$script:Worker.Id; restartCount = $script:RestartCount }
    Write-SupervisorState -State 'running'
}

function Test-WorkerStale {
    if ($null -eq $script:Worker -or $script:Worker.HasExited) {
        return $false
    }
    $runtime = Read-JsonFile -Path $runtimeStatePath
    $started = [DateTimeOffset]$script:Worker.StartTime
    if (
        $null -eq $runtime -or
        $runtime.PSObject.Properties.Name -notcontains 'worker' -or
        $null -eq $runtime.worker -or
        $runtime.worker.PSObject.Properties.Name -notcontains 'processId' -or
        [int]$runtime.worker.processId -ne [int]$script:Worker.Id
    ) {
        return (([DateTimeOffset]::Now - $started).TotalSeconds -gt 45)
    }
    $updatedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$runtime.updatedAt, [ref]$updatedAt)) {
        return (([DateTimeOffset]::Now - $started).TotalSeconds -gt 45)
    }
    return (([DateTimeOffset]::Now - $updatedAt).TotalSeconds -gt $StaleAfterSeconds)
}

$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\Code9IdentAgentSupervisor', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    New-Item -ItemType Directory -Force -Path $commandDirectory | Out-Null
    Write-SupervisorLog -EventName 'supervisor_started' -Data @{ processId = $PID }
    while ($true) {
        if (Test-Path -LiteralPath $restartRequestPath) {
            Remove-Item -LiteralPath $restartRequestPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $script:Worker) {
                $workerId = [int]$script:Worker.Id
                Write-SupervisorLog -EventName 'worker_restart_requested' -Data @{ processId = $workerId }
                Stop-WorkerTree -ProcessId $workerId
                try { $script:Worker.WaitForExit(10000) | Out-Null } catch {}
                $script:Worker.Dispose()
                $script:Worker = $null
            }
        }
        if ($null -ne $script:Worker) {
            $hasExited = $false
            try { $hasExited = $script:Worker.HasExited } catch { $hasExited = $true }
            if ($hasExited) {
                $exitCode = $null
                try { $exitCode = $script:Worker.ExitCode } catch {}
                $script:LastError = "Worker exited with code $exitCode."
                Write-SupervisorLog -EventName 'worker_exited' -Data @{ exitCode = $exitCode }
                $script:Worker.Dispose()
                $script:Worker = $null
            }
            elseif (Test-WorkerStale) {
                $workerId = [int]$script:Worker.Id
                $script:LastError = "Worker state was stale for more than $StaleAfterSeconds seconds."
                Write-SupervisorLog -EventName 'worker_stale' -Data @{ processId = $workerId; staleAfterSeconds = $StaleAfterSeconds }
                Stop-WorkerTree -ProcessId $workerId
                try { $script:Worker.WaitForExit(10000) | Out-Null } catch {}
                $script:Worker.Dispose()
                $script:Worker = $null
            }
        }

        if ($null -eq $script:Worker) {
            if (Test-UpdateInProgress) {
                Write-SupervisorState -State 'updating'
            }
            else {
                Start-Sleep -Seconds 3
                Start-Worker
            }
        }
        else {
            Write-SupervisorState -State 'running'
        }
        Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
    }
}
catch {
    $script:LastError = $_.Exception.Message
    try { Write-SupervisorLog -EventName 'supervisor_failed' -Data @{ message = $_.Exception.Message } } catch {}
    try { Write-SupervisorState -State 'error' } catch {}
    exit 1
}
finally {
    if ($null -ne $script:Worker) {
        try {
            if (-not $script:Worker.HasExited) {
                Stop-WorkerTree -ProcessId ([int]$script:Worker.Id)
            }
        }
        catch {}
        $script:Worker.Dispose()
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
