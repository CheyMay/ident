[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$path = Join-Path $PSScriptRoot '..\agent\ident-db-agent\Apply-IdentAgentUpdate.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
$function = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resume-AgentTask'}, $true)
Set-Item Function:Resume-AgentTask $function.Body.GetScriptBlock()
$TestMode = $false
$WorkerTaskName = 'FIXTURE ONLY'
$InstallDirectory = 'C:\ident-fixture'
$script:calls = New-Object 'Collections.Generic.List[string]'
function Get-ScheduledTask { param($TaskName, $ErrorAction) return [pscustomobject]@{State=$script:taskState} }
function Stop-ScheduledTask {
    param($TaskName, $ErrorAction)
    if ($TaskName -ne 'FIXTURE ONLY') { throw 'Unexpected task target.' }
    $script:calls.Add('stop')
    if ($script:stopFails) { throw 'fixture stop failure' }
    $script:taskState = 'Ready'
}
function Start-ScheduledTask {
    param($TaskName, $ErrorAction)
    if ($TaskName -ne 'FIXTURE ONLY') { throw 'Unexpected task target.' }
    $script:calls.Add('start'); $script:taskState = 'Running'
}
foreach ($initialState in @('Running', 'Ready')) {
    $script:calls.Clear(); $script:taskState = $initialState; $script:stopFails = $false
    Resume-AgentTask
    $expected = if ($initialState -eq 'Running') { 'stop,start' } else { 'start' }
    if (($script:calls.ToArray() -join ',') -ne $expected) { throw "Updated supervisor was not reloaded from state $initialState." }
}
$script:calls.Clear(); $script:taskState = 'Running'; $script:stopFails = $true
$rejected = $false
try { Resume-AgentTask } catch { $rejected = $true }
if (-not $rejected -or ($script:calls.ToArray() -join ',') -ne 'stop') { throw 'Restart ignored a stop failure.' }
Write-Host 'IDENT TASK RESTART OK: updated supervisor reloads; failed stop never starts a duplicate.'
