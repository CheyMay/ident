Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('ident-autostart-test-'+[guid]::NewGuid().ToString('N'))
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
$global:IdentTaskTestRegistered=New-Object 'System.Collections.Generic.List[object]'
$global:IdentTaskTestStarted=''
function New-ScheduledTaskAction { param($Execute,$Argument) return [pscustomobject]@{ Execute=$Execute; Argument=$Argument } }
function New-ScheduledTaskTrigger {
    param([switch]$AtLogOn,$User,[switch]$Once,$At,$RepetitionInterval)
    return [pscustomobject]@{ AtLogOn=$AtLogOn.IsPresent; Once=$Once.IsPresent; Interval=$RepetitionInterval }
}
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) return [pscustomobject]@{ LogonType=$LogonType; RunLevel=$RunLevel } }
function New-ScheduledTaskSettingsSet {
    param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,[switch]$StartWhenAvailable,$RestartCount,$RestartInterval,$ExecutionTimeLimit,$MultipleInstances)
    Assert ($AllowStartIfOnBatteries -and $DontStopIfGoingOnBatteries -and $StartWhenAvailable -and
        $ExecutionTimeLimit -eq [TimeSpan]::Zero -and $MultipleInstances -eq 'IgnoreNew') 'Recovery task settings regressed.'
    return [pscustomobject]@{ Valid=$true }
}
function Register-ScheduledTask {
    param($TaskName,$Action,$Trigger,$Principal,$Settings,$Description,[switch]$Force)
    $global:IdentTaskTestRegistered.Add([pscustomobject]@{ Name=$TaskName; Action=$Action; Triggers=@($Trigger); Principal=$Principal })
}
function Start-ScheduledTask { param($TaskName) $global:IdentTaskTestStarted=$TaskName }
try {
    $null=New-Item -ItemType Directory -Path $root
    foreach($file in @('IdentWorker.ps1','IdentSupervisor.ps1','IdentDesktop.ps1','config.local.json')) {
        $null=New-Item -ItemType File -Path (Join-Path $root $file)
    }
    # Source helper only touches an existing shortcut if it names this exact temporary installation.
    & (Join-Path $repo 'agent/ident-db-agent/Install-IdentAgentTask.ps1') -InstallDirectory $root
    Assert ($global:IdentTaskTestRegistered.Count -eq 2 -and $global:IdentTaskTestStarted -eq 'Code9 IDENT Agent') 'Wrong tasks registered.'
    $worker=$global:IdentTaskTestRegistered[0]; $panel=$global:IdentTaskTestRegistered[1]
    Assert ($worker.Triggers.Count -eq 2 -and $worker.Triggers[0].AtLogOn -and $worker.Triggers[1].Once -and
        $worker.Triggers[1].Interval.TotalMinutes -eq 1) 'Worker must recover after successful exit or missed wake.'
    Assert ($panel.Triggers.Count -eq 1 -and $panel.Triggers[0].AtLogOn) 'Explicit panel exit must not respawn every minute.'
    foreach($task in $global:IdentTaskTestRegistered) {
        Assert ($task.Action.Argument -match '-WindowStyle Hidden' -and $task.Principal.LogonType -eq 'Interactive' -and
            $task.Principal.RunLevel -eq 'Limited') 'Hidden interactive least-privilege launch missing.'
    }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'agent/ident-db-agent/Setup-IdentAgent.ps1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-PowerShellShortcut'},$true)
    Invoke-Expression $fn.Extent.Text
    $shortcutPath=Join-Path $root 'fixture.lnk'
    New-PowerShellShortcut -ShortcutPath $shortcutPath -ScriptPath (Join-Path $root 'IdentDesktop.ps1') -Arguments '-StartMinimized'
    $shell=New-Object -ComObject WScript.Shell; $shortcut=$shell.CreateShortcut($shortcutPath)
    Assert ($shortcut.Arguments -match '-WindowStyle Hidden' -and $shortcut.WindowStyle -eq 7) 'Shortcut can leave a visible console.'
    $nativeTrigger=ScheduledTasks\New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Assert ($nativeTrigger.Repetition.Interval -eq 'PT1M' -and -not $nativeTrigger.Repetition.Duration) 'Native trigger does not repeat indefinitely.'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/autostart-registration.ps1') -Destination (Join-Path $root 'Install-IdentAgentTask.ps1')
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'agent/ident-db-agent/Apply-IdentAgentUpdate.ps1'),[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resume-AgentTask'},$true)
    Invoke-Expression $fn.Extent.Text
    $TestMode=$false; $InstallDirectory=$root; $WorkerTaskName='Fixture task'
    function Get-ScheduledTask { param($TaskName,$ErrorAction) return [pscustomobject]@{ State=$global:IdentTaskTestState } }
    function Stop-ScheduledTask { param($TaskName,$ErrorAction) $global:IdentTaskTestState='Ready' }
    foreach($state in @('Ready','Running')) {
        $global:IdentTaskTestState=$state
        Resume-AgentTask
        Assert ((Get-Content -LiteralPath (Join-Path $root 'fixture-registration.txt') -Raw).Trim() -eq 'Fixture task') 'Update did not migrate existing task configuration.'
        Remove-Item -LiteralPath (Join-Path $root 'fixture-registration.txt')
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'ident-autostart-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'IDENT AUTOSTART RECOVERY OK: task registration mocked, hidden temporary shortcut, no actual tasks changed.'
