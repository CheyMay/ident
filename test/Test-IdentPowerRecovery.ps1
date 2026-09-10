Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'agent/ident-db-agent/AgentLifecycle.ps1')
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
function Import-Function([string]$File,[string]$Name) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $File),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'Source parse failure.' }
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    Set-Item ('Function:global:'+$Name) $node.Body.GetScriptBlock()
}
$real=Get-IdentPowerSample
Assert ($real.ActiveMs -ge 0 -and $real.UptimeMs -ge 0) 'Native active clock unavailable.'
$before=[pscustomobject]@{ ActiveMs=10000; UptimeMs=20000 }
$awake=[pscustomobject]@{ ActiveMs=20000; UptimeMs=30000 }
$wake=[pscustomobject]@{ ActiveMs=15000; UptimeMs=3625000 }
Assert (-not (Test-IdentPowerResume $before $awake)) 'Ordinary active work looks like sleep.'
Assert (Test-IdentPowerResume $before $wake) 'One hour of sleep was not detected.'
Assert (-not (Test-IdentPowerResume $null $wake)) 'First sample looks like wake.'
Import-Function 'agent/ident-db-agent/IdentSupervisor.ps1' 'Test-WorkerStale'
$script:sample=$wake
function Get-IdentPowerSample { return $script:sample }
function Read-JsonFile { param($Path) return $script:runtime }
$runtimeStatePath='unused'; $StaleAfterSeconds=150
$script:Worker=[pscustomobject]@{ HasExited=$false; Id=9876 }
$script:LastWorkerHeartbeatActiveMs=10000.0; $script:LastWorkerStateToken=''; $script:ResumeGraceUntilActiveMs=0.0
$script:runtime=[pscustomobject]@{ worker=[pscustomobject]@{ processId=9876 }; updatedAt=[DateTimeOffset]::Now.AddHours(-1).ToString('o') }
Assert (-not (Test-WorkerStale)) 'Sleep counted as a hung worker.'
$script:sample=[pscustomobject]@{ ActiveMs=170001; UptimeMs=3780001 }
Assert (Test-WorkerStale) 'Actually stale active worker was not detected.'
$script:ResumeGraceUntilActiveMs=180000
Assert (-not (Test-WorkerStale)) 'Resume grace did not protect a recovering worker.'
$script:sample=[pscustomobject]@{ ActiveMs=180001; UptimeMs=3790001 }
Assert (Test-WorkerStale) 'Resume grace became unlimited.'
$script:runtime.updatedAt=[DateTimeOffset]::Now.ToString('o')
Assert (-not (Test-WorkerStale)) 'Fresh heartbeat rejected.'
$script:sample=[pscustomobject]@{ ActiveMs=400001; UptimeMs=4010001 }
Assert (Test-WorkerStale) 'An unchanged heartbeat renewed itself.'
$script:runtime.updatedAt=[DateTimeOffset]::Now.AddSeconds(-1).ToString('o')
Assert (-not (Test-WorkerStale)) 'Backward wall-clock correction broke fresh heartbeat.'
$script:runtime.worker.processId=4321
$script:sample=[pscustomobject]@{ ActiveMs=560002; UptimeMs=4170002 }
Assert (Test-WorkerStale) 'Foreign worker heartbeat was accepted.'
Import-Function 'agent/ident-db-agent/IdentWorker.ps1' 'Update-WorkerPowerState'
Import-Function 'agent/ident-db-agent/IdentWorker.ps1' 'Invoke-RobotPoll'
$script:WorkerPowerSample=$before; $script:sample=$wake
$script:RobotResumeNotBeforeActiveMs=0; $script:NeedsWakeRefresh=$false
$script:logs=0; $script:polls=0
function Write-WorkerLog { param($Level,$EventName,$Data) $script:logs++ }
function Invoke-RobotPollCore { $script:polls++ }
function Enter-RobotInteractionLease { param($Directory) return [IO.MemoryStream]::new() }
$script:State=@{ robot=@{ enabled=$false; state='disabled'; lastError='' } }
$script:Context=@{ RobotConfigPath='C:\fixture\robot\config.local.json' }
$null=Update-WorkerPowerState
Assert ($script:NeedsWakeRefresh -and $script:RobotResumeNotBeforeActiveMs -eq 75000 -and $script:logs -eq 1) 'Wake did not schedule refresh and robot grace.'
Invoke-RobotPoll
Assert ($script:polls -eq 0 -and -not $script:State.robot.enabled -and $script:State.robot.state -eq 'waiting_for_idle') 'Wake claimed a booking or enabled robot.'
$script:sample=[pscustomobject]@{ ActiveMs=74999; UptimeMs=3684999 }
Invoke-RobotPoll
Assert ($script:polls -eq 0 -and $script:logs -eq 1) 'Repeated polls reset or bypassed wake grace.'
$script:sample=[pscustomobject]@{ ActiveMs=75001; UptimeMs=3685001 }
Invoke-RobotPoll
Assert ($script:polls -eq 1) 'Robot did not leave the bounded wake grace.'
Assert ((Get-IdentCloseAction 'UserClosing' $false) -eq 'hide') 'Window close must go to tray.'
Assert ((Get-IdentCloseAction 'UserClosing' $true) -eq 'close') 'Explicit panel exit must work.'
Assert ((Get-IdentCloseAction 'WindowsShutDown' $false) -eq 'close') 'Panel must not block Windows shutdown.'
Write-Host 'IDENT POWER RECOVERY OK: synthetic sleep, active watchdog, bounded resume grace, no queue claims during grace, close policy.'
