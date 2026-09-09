[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repo 'robot\ident-rpa\RobotCapture.ps1')
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
# Compile the native helper without reading or activating a user's window.
$empty = Get-RobotCaptureWindowMetadata 0
Assert-True (-not $empty.Visible -and $empty.ProcessId -eq 0) 'Invalid HWND was accepted.'
$config = [pscustomobject]@{ ident = [pscustomobject]@{ processName='IdentFixture'; windowTitleRegex='IDENT' } }
$script:metadata = [pscustomobject]@{
    Handle=101; ProcessId=102; Visible=$true; Title='Appointment'
    OwnerHandle=100; OwnerProcessId=102; OwnerTitle='IDENT fixture'
}
$script:process = [pscustomobject]@{ Id=102; ProcessName='IdentFixture'; MainWindowTitle=''; MainWindowHandle=999 }
function Get-Process { param([int]$Id) if ($Id -ne 102) { throw 'Unexpected process lookup.' }; return $script:process }
function Get-RobotCaptureWindowMetadata { param([long]$WindowHandle) return $script:metadata }
$result = Get-RobotCaptureTarget $config 101 102
Assert-True ($null -ne $result -and $result.handle -eq 101) 'Owned dialog with a titleless process main window was rejected or replaced.'
$script:metadata.OwnerProcessId=999
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Foreign owner authorized a capture.'
$script:metadata.OwnerProcessId=102; $script:metadata.OwnerTitle='Other application'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Unrecognized owner authorized a capture.'
$script:metadata.Title='IDENT calendar'
Assert-True ($null -ne (Get-RobotCaptureTarget $config 101 102)) 'Direct calendar title was rejected.'
$script:metadata.ProcessId=999
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Changed PID authorized a capture.'
$script:metadata.ProcessId=102; $script:metadata.Visible=$false
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Hidden window authorized a capture.'
$script:metadata.Visible=$true; $script:metadata.Handle=999
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Changed HWND authorized a capture.'
$script:metadata.Handle=101; $script:process.ProcessName='OtherApp'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Configured process restriction was bypassed.'
$config.ident.processName=''; $script:process.ProcessName='AnyDesk'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Remote-control window authorized a capture.'
$script:process.ProcessName='IdentFixture'; $config.ident.windowTitleRegex=''
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Unrestricted configuration authorized a capture.'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 $PID)) 'Training process authorized its own capture.'
Write-Host 'IDENT CAPTURE TARGET OK: exact HWND, same-process owner, titleless main window, no foreign/hidden/reused target or unrestricted fallback.'
