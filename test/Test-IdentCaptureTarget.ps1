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
Assert-True (@(Get-RobotCaptureSiblingHandles 0 0).Count -eq 0) 'Invalid PID enumerated windows.'
$config = [pscustomobject]@{ ident = [pscustomobject]@{ processName='IdentFixture'; windowTitleRegex='IDENT' } }
$script:metadata = [pscustomobject]@{
    Handle=101; ProcessId=102; Visible=$true; Title='Appointment'
    OwnerHandle=100; OwnerProcessId=102; OwnerTitle='IDENT fixture'
}
$script:process = [pscustomobject]@{ Id=102; ProcessName='IdentFixture'; MainWindowTitle=''; MainWindowHandle=999 }
function Get-Process { param([int]$Id) if ($Id -ne 102) { throw 'Unexpected process lookup.' }; return $script:process }
function Get-RobotCaptureWindowMetadata {
    param([long]$WindowHandle)
    if ($WindowHandle -eq 201) { return $script:sibling }
    return $script:metadata
}
$script:siblingHandles = @()
function Get-RobotCaptureSiblingHandles { param([int]$ProcessId,[long]$ExcludedHandle) return $script:siblingHandles }
$result = Get-RobotCaptureTarget $config 101 102
Assert-True ($null -ne $result -and $result.handle -eq 101) 'Owned dialog with a titleless process main window was rejected or replaced.'
$script:metadata.OwnerProcessId=999
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Foreign owner authorized a capture.'
$script:metadata.OwnerProcessId=102; $script:metadata.OwnerTitle='Other application'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Unrecognized owner authorized a capture.'
$script:metadata.Title=''; $script:metadata.OwnerHandle=0
$script:sibling = [pscustomobject]@{ Handle=201; ProcessId=102; Visible=$true; Title='IDENT fixture' }
$script:siblingHandles = @(201)
$reason = ''
$result = Get-RobotCaptureTarget $config 101 102 ([ref]$reason)
Assert-True ($null -ne $result -and $result.handle -eq 101 -and $reason -eq 'accepted_sibling') 'Independent titleless appointment was rejected or replaced by the calendar.'
$script:sibling.ProcessId=999
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102 ([ref]$reason)) -and $reason -eq 'title_mismatch') 'Foreign sibling authorized capture.'
$script:sibling.ProcessId=102; $script:sibling.Visible=$false
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Hidden sibling authorized capture.'
$script:sibling.Visible=$true; $script:sibling.Handle=999
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Reused sibling HWND authorized capture.'
$script:sibling.Handle=201; $script:sibling.Title='Code9 IDENT'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Training title authorized capture.'
$script:sibling.Title='IDENT fixture'; $script:metadata.Visible=$false
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102 ([ref]$reason)) -and $reason -eq 'window_hidden') 'Valid sibling authorized hidden target.'
$script:metadata.Visible=$true; $script:siblingHandles=@()
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Missing sibling authorized capture.'
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
foreach ($hostProcess in @('powershell','pwsh','cmd','WindowsTerminal','explorer','chrome','msedge','firefox')) {
    $script:process.ProcessName=$hostProcess
    Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102 ([ref]$reason)) -and $reason -eq 'disallowed_process') 'Host application authorized capture.'
}
$script:process.ProcessName='IdentFixture'; $config.ident.windowTitleRegex=''
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 102)) 'Unrestricted configuration authorized a capture.'
Assert-True ($null -eq (Get-RobotCaptureTarget $config 101 $PID ([ref]$reason)) -and $reason -eq 'self_window') 'Training process authorized its own capture.'
Write-Host 'IDENT CAPTURE TARGET OK: exact HWND, same-process owner/sibling, independent titleless window, safe reason codes, no foreign/hidden/reused target or host application.'
