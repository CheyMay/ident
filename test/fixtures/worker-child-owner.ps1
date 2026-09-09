param([string]$Repository, [string]$TestDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'robot\ident-rpa\RobotCapture.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'agent\ident-db-agent\IdentWorker.ps1'),[ref]$tokens,[ref]$errors)
$node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PowerShellChildProcess'},$true)
Set-Item Function:Invoke-PowerShellChildProcess $node.Body.GetScriptBlock()
$script:State=$null; $script:Context=$null
$fixture=Join-Path $PSScriptRoot 'worker-child-wait.ps1'
$pidFile=Join-Path $TestDirectory 'child.pid'
Invoke-PowerShellChildProcess -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fixture`" -PidFile `"$pidFile`"" -TimeoutSeconds 120 -Label 'Crash test child'
