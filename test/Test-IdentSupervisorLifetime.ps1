[CmdletBinding()]
param([switch]$ScheduledTask)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-supervisor-lifetime-' + [guid]::NewGuid().ToString('N'))))
if (-not $root.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test directory.' }
$processes = New-Object 'Collections.Generic.List[Diagnostics.Process]'
$taskName = 'Code9 IDENT QA ' + [guid]::NewGuid().ToString('N')
$taskRegistered = $false
try {
    New-Item -ItemType Directory -Path (Join-Path $root 'robot') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repository 'agent\ident-db-agent\IdentSupervisor.ps1') -Destination $root
    Copy-Item -LiteralPath (Join-Path $repository 'robot\ident-rpa\RobotCapture.ps1') -Destination (Join-Path $root 'robot')
    @{ repository = $repository } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.local.json') -Encoding UTF8
    $fixture = Join-Path $PSScriptRoot 'fixtures\supervisor-lifetime-worker.ps1'
    $arguments = "-NoProfile -WindowStyle Hidden -NonInteractive -ExecutionPolicy Bypass -File `"$root\IdentSupervisor.ps1`" -ConfigPath `"$root\config.local.json`" -WorkerScriptPath `"$fixture`" -PollSeconds 2"
    if ($ScheduledTask) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2)) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
        $taskRegistered = $true
        Start-ScheduledTask -TaskName $taskName
    } else {
        $supervisor = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
            -RedirectStandardError (Join-Path $root 'supervisor-error.log') -ArgumentList $arguments
        $null = $supervisor.Handle; $processes.Add($supervisor)
    }
    $until = [DateTimeOffset]::Now.AddSeconds(20)
    while ([DateTimeOffset]::Now -lt $until -and
        (-not (Test-Path (Join-Path $root 'child.pid')) -or -not (Test-Path (Join-Path $root 'updater.pid')))) { Start-Sleep -Milliseconds 100 }
    if ($ScheduledTask) {
        $state = Get-Content -LiteralPath (Join-Path $root 'supervisor-state.json') -Raw | ConvertFrom-Json
        $supervisor = Get-Process -Id ([int]$state.processId)
        $null = $supervisor.Handle; $processes.Add($supervisor)
    }
    $owned = @{}
    foreach ($role in @('worker', 'child', 'updater')) {
        $process = Get-Process -Id ([int](Get-Content -LiteralPath (Join-Path $root "$role.pid") -Raw))
        $null = $process.Handle; $processes.Add($process); $owned[$role] = $process
    }
    if ($ScheduledTask) { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop } else { $supervisor.Kill() }
    if (-not $supervisor.WaitForExit(2000)) { throw 'Supervisor did not exit.' }
    if (-not $owned.worker.WaitForExit(3000)) { throw 'WORKER_SURVIVED_SUPERVISOR_CRASH' }
    if (-not $owned.child.WaitForExit(3000)) { throw 'ROBOT_SURVIVED_SUPERVISOR_CRASH' }
    if ($owned.updater.WaitForExit(1000)) { throw 'Independent updater was interrupted with the worker.' }
    Write-Host "IDENT SUPERVISOR LIFETIME OK: crash stops worker and robot; independent updater survives. Scheduled task: $ScheduledTask"
}
finally {
    if ($taskRegistered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    foreach ($process in $processes.ToArray()) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(2000) }
        $process.Dispose()
    }
    # Also clean fixture processes if startup failed before handles were collected.
    foreach ($role in @('worker', 'child', 'updater')) {
        $path = Join-Path $root "$role.pid"
        if (Test-Path -LiteralPath $path) {
            $processId = [int](Get-Content -LiteralPath $path -Raw)
            $candidate = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
            if ($null -ne $candidate -and $candidate.CommandLine -like "*$root*") {
                Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
