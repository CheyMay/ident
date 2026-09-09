param([string]$RobotDirectory, [string]$TestDirectory, [string]$ScannerPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $RobotDirectory 'RobotSafety.ps1')
. (Join-Path $RobotDirectory 'RobotCapture.ps1')
$lease = Enter-RobotInteractionLease $TestDirectory -Training
$session = New-RobotTrainingSession $TestDirectory
[void](Start-RobotTrainingCapture $session $ScannerPath (Join-Path $TestDirectory 'fixture.json') 101 102)
$session.Current.Process.Id | Set-Content -LiteralPath (Join-Path $TestDirectory 'scanner.pid')
Start-Sleep -Seconds 120
