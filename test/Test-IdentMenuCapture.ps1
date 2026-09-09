[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.IO.Compression.FileSystem
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-menu-test-'+[guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }
. (Join-Path $repo 'robot\ident-rpa\RobotCapture.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'robot\ident-rpa\Start-IdentRobot.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Assert-ObservedElement','Get-ObservedMenuContext','Assert-ObservedMenuContext','Invoke-ObservedCapture','Write-JsonFileAtomic','Convert-BoundsText','Format-Bounds')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    Set-Item "Function:$name" $node.Body.GetScriptBlock()
}
function Assert-True {param([bool]$Value,[string]$Message) if (-not $Value) {throw $Message}}
function Assert-Rejected {param([scriptblock]$Action) try {& $Action | Out-Null} catch {return};throw 'Expected rejection.'}
function Element([string]$Type,[long]$Handle,[int]$Identity) {
    $e=[pscustomobject]@{Identity=$Identity;Parent=$null;Current=[pscustomobject]@{
        Name='Fixture';ProcessId=102;NativeWindowHandle=$Handle;IsOffscreen=$false
        ControlType=[pscustomobject]@{ProgrammaticName=$Type};BoundingRectangle=[System.Windows.Rect]::new(20,20,200,100)
    }}
    $e | Add-Member ScriptMethod GetRuntimeId {return @(42,$this.Identity)}
    return $e
}
function Reset-Elements {
    $script:main=Element 'ControlType.Window' 101 1
    $script:popup=Element 'ControlType.Window' 201 2
    $script:menu=Element 'ControlType.Menu' 0 3
    $script:item=Element 'ControlType.MenuItem' 0 4
    $script:item.Parent=$script:menu;$script:menu.Parent=$script:popup
    $script:behavior='ok';$script:scanned=$false;$script:parentReads=0
}
function Get-ObservedElement([long]$WindowHandle) {
    if ($WindowHandle -eq 101) {return $script:main}
    if ($WindowHandle -eq 201) {
        if ($script:scanned -and $script:behavior -eq 'container-closed') {throw 'Closed popup.'}
        return $script:popup
    }
    throw 'Unexpected HWND.'
}
function Get-ObservedPointerElement {
    if ($script:scanned -and $script:behavior -eq 'pointer-moved') {return $script:main}
    return $script:item
}
function Get-ObservedParent([object]$Element) {$script:parentReads++;return $Element.Parent}
function Get-UiTreeRows($Roots,$MaxDepth,$ExpectedProcessId) {
    Assert-True ($Roots.Count -eq 1 -and $Roots[0] -eq $script:menu) 'Menu capture fell back to the calendar or desktop.'
    Assert-True ($ExpectedProcessId -eq 102) 'Menu descendants were not scoped to the IDENT process.'
    $script:scanned=$true
    if ($script:behavior -eq 'menu-closed') {$script:menu.Current.IsOffscreen=$true}
    if ($script:behavior -eq 'menu-replaced') {$script:menu.Identity=99}
    if ($script:behavior -eq 'foreign-menu') {$script:menu.Current.ProcessId=999}
    $rows=@([ordered]@{depth=0;path='0';rootName='Menu';name='Menu';controlType='ControlType.Menu';patterns=@();isOffscreen=$false;bounds='20,20,200,100'})
    if ($script:behavior -ne 'empty') {$rows+=@([ordered]@{depth=1;path='0/0';rootName='Menu';name='Split interval';controlType='ControlType.MenuItem';patterns=@('InvokePatternIdentifiers.Pattern');isOffscreen=$false;bounds='20,20,200,25'})}
    return $rows
}
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    Reset-Elements
    $context=Get-ObservedMenuContext 102
    Assert-True ($context.Element -eq $script:menu -and $context.Handle -eq 201) 'Separate native popup was not recognized.'
    $script:item.Current.ProcessId=999
    Assert-Rejected {Get-ObservedMenuContext 102}
    Reset-Elements
    $script:popup.Current.ProcessId=999
    Assert-Rejected {Get-ObservedMenuContext 102}
    Reset-Elements
    $script:menu.Current.IsOffscreen=$true
    Assert-Rejected {Get-ObservedMenuContext 102}
    Reset-Elements
    $script:item.Parent=$script:item
    Assert-Rejected {Get-ObservedMenuContext 102}
    Assert-True ($script:parentReads -le 24) 'Parent traversal was unbounded.'
    foreach ($scenario in @('ok','menu-closed','menu-replaced','foreign-menu','container-closed','pointer-moved','empty')) {
        Reset-Elements;$script:behavior=$scenario
        $dir=Join-Path $temp $scenario;New-Item -ItemType Directory -Path $dir | Out-Null
        $reportPath=Join-Path $dir 'report.json'
        $window=[pscustomobject]@{process=[pscustomobject]@{Id=102}}
        $started=[DateTimeOffset]::Now
        if ($scenario -eq 'ok') {
            $r=Invoke-ObservedCapture $window 101 102 $reportPath 'menu-fixture' -Surface menu
            Assert-True ($r.observedSurface -eq 'menu' -and $r.menuItemsScanned -eq 1 -and $r.controlsScanned -eq 2) 'Missing menu evidence.'
            Assert-True (-not $r.readyForUnattendedExecution) 'Menu capture enabled execution.'
            [void](Get-VerifiedRobotCapture $reportPath 'menu-fixture' $started)
            $session=New-RobotTrainingSession $temp
            $session.Captures.Add([pscustomobject]@{Number=1;ReportPath=$reportPath;CaptureId='menu-fixture';StartedAt=$started;Path=$r.capturePath;Sha256=$r.captureSha256})
            $archive=[IO.Compression.ZipFile]::OpenRead((Export-RobotTrainingSession $session))
            try {
                $reader=[IO.StreamReader]::new($archive.GetEntry('capture-01/summary.json').Open())
                try {$summary=$reader.ReadToEnd() | ConvertFrom-Json} finally {$reader.Dispose()}
                Assert-True ($summary.observedSurface -eq 'menu' -and $summary.menuItemsScanned -eq 1) 'ZIP lost the menu evidence.'
            } finally {$archive.Dispose()}
            $r.menuItemsScanned=2;Write-JsonFileAtomic $reportPath $r
            Assert-Rejected {Get-VerifiedRobotCapture $reportPath 'menu-fixture' $started}
        } else {
            Assert-Rejected {Invoke-ObservedCapture $window 101 102 $reportPath 'menu-fixture' -Surface menu}
            Assert-True (-not (Test-Path $reportPath)) 'Failed menu capture produced a success report.'
        }
    }
    Write-Host 'IDENT MENU CAPTURE OK: separate popup under pointer, bounded same-process scope, no calendar fallback, closed/replaced/foreign/empty menu rejection, evidence integrity.'
} finally {
    if (Test-Path -LiteralPath $temp) {Remove-Item -LiteralPath $temp -Recurse -Force}
}
