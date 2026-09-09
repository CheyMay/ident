param([string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $ConfigPath
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
. (Join-Path $config.repository 'robot\ident-rpa\RobotCapture.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $config.repository 'agent\ident-db-agent\IdentWorker.ps1'), [ref]$tokens, [ref]$errors)
$node = $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PowerShellChildProcess'}, $true)
Set-Item Function:Invoke-PowerShellChildProcess $node.Body.GetScriptBlock()
$script:State = $null; $script:Context = $null
$PID | Set-Content -LiteralPath (Join-Path $root 'worker.pid') -Encoding ASCII
$fixture = Join-Path $config.repository 'test\fixtures\worker-child-wait.ps1'
# An updater deliberately outlives the worker that launched it.
$updaterPid = Join-Path $root 'updater.pid'
$updater = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList (
    "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fixture`" -PidFile `"$updaterPid`"")
$updater.Dispose()
$childPid = Join-Path $root 'child.pid'
Invoke-PowerShellChildProcess -Arguments "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fixture`" -PidFile `"$childPid`"" -TimeoutSeconds 120 -Label 'Protected test child'
