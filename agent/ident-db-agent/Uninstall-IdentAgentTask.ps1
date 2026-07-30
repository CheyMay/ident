[CmdletBinding()]
param(
    [string]$WorkerTaskName = 'Code9 IDENT Agent',
    [string]$DesktopTaskName = 'Code9 IDENT Agent Status'
)

$ErrorActionPreference = 'Stop'

foreach ($taskName in @($WorkerTaskName, $DesktopTaskName, 'Code9 IDENT Schedule Agent')) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "Scheduled task removed: $taskName" -ForegroundColor Green
    }
}
