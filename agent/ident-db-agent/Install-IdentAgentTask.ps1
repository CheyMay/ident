[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Code9\IdentAgent'),
    [string]$WorkerTaskName = 'Code9 IDENT Agent',
    [string]$DesktopTaskName = 'Code9 IDENT Agent Status'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AgentLifecycle.ps1')
$workerPath = Join-Path $InstallDirectory 'IdentWorker.ps1'
$supervisorPath = Join-Path $InstallDirectory 'IdentSupervisor.ps1'
$desktopPath = Join-Path $InstallDirectory 'IdentDesktop.ps1'
$configPath = Join-Path $InstallDirectory 'config.local.json'

if (
    -not (Test-Path -LiteralPath $workerPath) -or
    -not (Test-Path -LiteralPath $supervisorPath) -or
    -not (Test-Path -LiteralPath $desktopPath) -or
    -not (Test-Path -LiteralPath $configPath)
) {
    throw 'Agent is not installed. Run 1-Setup.cmd first.'
}

$workerArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$supervisorPath`" -ConfigPath `"$configPath`" -WorkerScriptPath `"$workerPath`""
$workerAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $workerArguments
$desktopArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$desktopPath`" -ConfigPath `"$configPath`" -StartMinimized"
$desktopAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $desktopArguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
# A successful process exit or a missed wake must also recover, not only nonzero exit codes.
$recoveryTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal `
    -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $WorkerTaskName `
    -Action $workerAction `
    -Trigger @($trigger,$recoveryTrigger) `
    -Principal $principal `
    -Settings $settings `
    -Description 'Runs the Code9 IDENT schedule and booking agent while this Windows user is signed in.' `
    -Force | Out-Null

Register-ScheduledTask `
    -TaskName $DesktopTaskName `
    -Action $desktopAction `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Shows Code9 IDENT agent status and controls.' `
    -Force | Out-Null

try { Repair-IdentHiddenShortcuts -Directory $InstallDirectory }
catch { Write-Warning 'Code9 shortcuts could not be migrated; background task installation continues.' }
Start-ScheduledTask -TaskName $WorkerTaskName

Write-Host "Autostart installed: $WorkerTaskName" -ForegroundColor Green
Write-Host "Status panel installed: $DesktopTaskName" -ForegroundColor Green
Write-Host 'Both will start automatically when this Windows user signs in.'
