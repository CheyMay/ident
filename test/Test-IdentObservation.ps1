[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, WindowsBase
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-observation-' + [guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe test directory.'
}
. (Join-Path $repo 'robot\ident-rpa\RobotCapture.ps1')
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'robot\ident-rpa\Start-IdentRobot.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Test-ObservedWindowVisible','Get-ObservedElement','Assert-ObservedElement','Invoke-ObservedCapture','Write-JsonFileAtomic','Convert-BoundsText','Format-Bounds')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $node) { throw "Missing function $name" }
    Set-Item "Function:$name" $node.Body.GetScriptBlock()
}
function Assert-True { param([bool]$Value,[string]$Message) if (-not $Value) { throw $Message } }
function Assert-Rejected { param([scriptblock]$Action) try { & $Action | Out-Null } catch { return }; throw 'Expected rejection.' }
function New-FixtureElement {
    param([int]$Identity = 1)
    $element = [pscustomobject]@{
        Identity = $Identity
        Current = [pscustomobject]@{
            Name = 'Appointment settings'; ProcessId = 102; NativeWindowHandle = 101; IsOffscreen = $false
            BoundingRectangle = [System.Windows.Rect]::new(10,10,200,80)
        }
    }
    $element | Add-Member ScriptMethod GetRuntimeId { return @(42,$this.Identity) }
    return $element
}
$form = New-Object Windows.Forms.Form
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    # UIA may report a hidden HWND as on-screen; native visibility must also be checked.
    $native = [System.Windows.Automation.AutomationElement]::FromHandle($form.Handle)
    Assert-True ($native.Current.ProcessId -eq $PID) 'UIA did not resolve the supplied HWND.'
    Assert-Rejected { Get-ObservedElement $form.Handle.ToInt64() }

    function Get-ObservedElement {
        param([long]$WindowHandle)
        Assert-True ($WindowHandle -eq 101) 'Scanner changed the selected HWND.'
        $script:ElementReads++
        if ($script:Behavior -eq 'replaced' -and $script:ElementReads -gt 1) { return (New-FixtureElement 2) }
        return $script:Element
    }
    function Get-UiTreeRows {
        param($Roots,$MaxDepth)
        Assert-True ($Roots.Count -eq 1 -and $Roots[0] -eq $script:Element) 'Calendar was scanned instead of selected dialog.'
        if ($script:Behavior -eq 'closed') { $script:Element.Current.IsOffscreen = $true }
        if ($script:Behavior -eq 'wrong-process') { $script:Element.Current.ProcessId = 999 }
        return @([ordered]@{
            depth = 0; path = '0'; rootName = 'Appointment settings'; name = 'Appointment settings'
            patterns = @(); isOffscreen = $false; bounds = '10,10,200,80'
        })
    }
    $window = [pscustomobject]@{ process = [pscustomobject]@{ Id = 102 } }
    foreach ($behavior in @('small','closed','replaced','wrong-process')) {
        $script:Behavior = $behavior; $script:ElementReads = 0; $script:Element = New-FixtureElement
        $directory = Join-Path $temp $behavior
        New-Item -ItemType Directory -Path $directory | Out-Null
        $reportPath = Join-Path $directory 'report.json'
        $started = [DateTimeOffset]::Now
        if ($behavior -eq 'small') {
            $report = Invoke-ObservedCapture $window 101 102 $reportPath 'small-screen'
            Assert-True ($report.ok -and $report.visibleControls -eq 1 -and $report.mode -eq 'observation') 'Small dialog rejected.'
            Assert-True (-not $report.selectorsComplete -and -not $report.readyForUnattendedExecution) 'Observation authorized execution.'
            [void](Get-VerifiedRobotCapture $reportPath 'small-screen' $started)
            Assert-True (@(Get-ChildItem $directory -Filter '*candidate*').Count -eq 0) 'Observation wrote a calibration candidate.'
        } else {
            Assert-Rejected { Invoke-ObservedCapture $window 101 102 $reportPath 'failed-screen' }
            Assert-True (-not (Test-Path $reportPath)) 'Changed window produced a successful report.'
        }
    }
    Assert-Rejected { Invoke-ObservedCapture $window 101 999 (Join-Path $temp 'bad.json') 'wrong-target' }
    Assert-Rejected { Invoke-ObservedCapture $window 0 102 (Join-Path $temp 'bad.json') 'missing-target' }
    Write-Host 'IDENT OBSERVATION OK: exact HWND/process, small dialogs, hidden/closed/replaced window rejection, no calendar fallback or profile changes.'
}
finally {
    $form.Dispose()
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
