Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$repo=Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'agent/ident-db-agent/AgentLifecycle.ps1')
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'agent/ident-db-agent/IdentDesktop.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'Desktop source does not parse.' }
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
foreach($name in @('Hide-MainWindow','Show-MainWindow')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Invoke-Expression $node.Extent.Text
}
function Handler([string]$Name) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq $Name},$true)
    return $node.Arguments[0].ScriptBlock.GetScriptBlock()
}
$form=[pscustomobject]@{ Hidden=$false; Activated=$false; ShowInTaskbar=$true; WindowState=[Windows.Forms.FormWindowState]::Normal }
$form | Add-Member ScriptMethod Hide { $this.Hidden=$true }
$form | Add-Member ScriptMethod Show { $this.Hidden=$false }
$form | Add-Member ScriptMethod Activate { $this.Activated=$true }
$script:AllowClose=$false
$close=Handler 'Add_FormClosing'
$args=[pscustomobject]@{ CloseReason='UserClosing'; Cancel=$false }
& $close $form $args
Assert ($args.Cancel -and $form.Hidden -and -not $form.ShowInTaskbar) 'X must retain the panel in tray.'
Show-MainWindow
Assert (-not $form.Hidden -and $form.Activated -and $form.ShowInTaskbar -and
    $form.WindowState -eq [Windows.Forms.FormWindowState]::Normal) 'Tray restore failed.'
$form.WindowState=[Windows.Forms.FormWindowState]::Minimized
& (Handler 'Add_Resize')
Assert ($form.Hidden -and -not $form.ShowInTaskbar) 'Minimize must go to tray.'
foreach($case in @(@('WindowsShutDown',$false),@('UserClosing',$true))) {
    $script:AllowClose=$case[1]; $args=[pscustomobject]@{ CloseReason=$case[0]; Cancel=$false }
    & $close $form $args
    Assert (-not $args.Cancel) 'Shutdown or explicit panel exit was blocked.'
}
$source=$ast.Extent.Text
Assert ($source -notmatch '-NoExit') 'SQL buttons still leave a persistent console.'
Assert ($source -match "Request-LocalAgentCommand 'sql-discovery-now'" -and $source -match "Request-LocalAgentCommand 'schema-now'") 'SQL buttons do not use background commands.'
Assert ($source -match 'Code9IdentAgentDesktopShow' -and $source -match '\$script:PanelMutex.WaitOne\(0\)' -and
    $source -match '\$script:PanelShowEvent.WaitOne\(0\)') 'Single-instance open signal missing.'
$launches=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-Process'},$true))
foreach($launch in $launches) { Assert ($launch.Extent.Text -match '-WindowStyle Hidden') 'Desktop starts a visible helper process.' }
Write-Host 'IDENT TRAY OK: actual close/resize handlers on a fake form, restore, shutdown, explicit exit, hidden helpers, queued SQL.'
