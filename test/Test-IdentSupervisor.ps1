[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$supervisorSource = Join-Path $repositoryRoot 'agent\ident-db-agent\IdentSupervisor.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ident-supervisor-' + [Guid]::NewGuid().ToString('N'))
$supervisorProcess = $null

try {
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testRoot 'commands') | Out-Null
    Copy-Item -LiteralPath $supervisorSource -Destination (Join-Path $testRoot 'IdentSupervisor.ps1')
    Set-Content -LiteralPath (Join-Path $testRoot 'config.local.json') -Value '{}' -Encoding UTF8

    $fakeWorker = @'
param([string]$ConfigPath = '')
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$counterPath = Join-Path $root 'worker-launches.txt'
$count = 0
if (Test-Path -LiteralPath $counterPath) { $count = [int](Get-Content -LiteralPath $counterPath -Raw) }
$count++
Set-Content -LiteralPath $counterPath -Value $count -Encoding ASCII
if ($count -eq 1) {
    $state = @{ worker = @{ processId = $PID }; updatedAt = (Get-Date).AddMinutes(-10).ToString('o') }
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'runtime-state.json') -Encoding UTF8
    Start-Sleep -Seconds 60
    exit 0
}
while ($true) {
    $state = @{ worker = @{ processId = $PID }; updatedAt = (Get-Date).ToString('o') }
    $temporary = Join-Path $root "runtime-state.json.tmp-$PID"
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination (Join-Path $root 'runtime-state.json') -Force
    Start-Sleep -Milliseconds 500
}
'@
    Set-Content -LiteralPath (Join-Path $testRoot 'FakeWorker.ps1') -Value $fakeWorker -Encoding UTF8

    $supervisorInfo = New-Object Diagnostics.ProcessStartInfo
    $supervisorInfo.FileName = 'powershell.exe'
    $supervisorInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$testRoot\IdentSupervisor.ps1`" " +
        "-ConfigPath `"$testRoot\config.local.json`" -WorkerScriptPath `"$testRoot\FakeWorker.ps1`" " +
        '-StaleAfterSeconds 3 -PollSeconds 1'
    $supervisorInfo.UseShellExecute = $false
    $supervisorInfo.CreateNoWindow = $true
    $supervisorProcess = [Diagnostics.Process]::Start($supervisorInfo)

    $deadline = (Get-Date).AddSeconds(25)
    $launches = 0
    while ((Get-Date) -lt $deadline) {
        $counterPath = Join-Path $testRoot 'worker-launches.txt'
        if (Test-Path -LiteralPath $counterPath) {
            try { $launches = [int](Get-Content -LiteralPath $counterPath -Raw) } catch { $launches = 0 }
        }
        if ($launches -ge 2) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($launches -lt 2) {
        throw 'Supervisor did not restart the stale worker.'
    }

    $supervisorState = Get-Content -LiteralPath (Join-Path $testRoot 'supervisor-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$supervisorState.restartCount -lt 2 -or [string]$supervisorState.state -ne 'running') {
        throw 'Supervisor state does not report a recovered worker.'
    }
    Write-Host 'IDENT supervisor recovery check OK' -ForegroundColor Green
}
finally {
    $statePath = Join-Path $testRoot 'supervisor-state.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([int]$state.workerProcessId -gt 0) {
                Stop-Process -Id ([int]$state.workerProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
        catch {}
    }
    if ($null -ne $supervisorProcess) {
        Stop-Process -Id $supervisorProcess.Id -Force -ErrorAction SilentlyContinue
        $supervisorProcess.Dispose()
    }
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
