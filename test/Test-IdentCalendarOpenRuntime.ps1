Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $repo 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendar.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentCalendarOpen.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-patient-form.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-calendar.ps1')
Add-Type -TypeDefinition @'
namespace Code9IdentRobot { public static class NativeInput {
    public static long ForegroundHandle() { return 456; }
} }
'@
$script:checks=0
function Assert-Test([bool]$Condition,[string]$Message) { $script:checks++; if (-not $Condition) { throw $Message } }
function Assert-IdentCalendarOpenOperator($Context) {
    if ($script:interrupted) { throw 'CALENDAR_USER_ACTIVE' }
    $script:guards++
}
function Get-ObservedElement($Handle) { return $script:formElements['0'] }
function Assert-ObservedElement($Element,$Handle,$ProcessId,$RuntimeId='') {
    if ($Element.Current.ProcessId -ne $ProcessId -or ($RuntimeId -and $Element.Identity -cne $RuntimeId)) { throw 'CALENDAR_WINDOW_CHANGED' }
    return $Element.Identity
}
function Format-Bounds($Rect) { return $Rect }
function Get-IdentAutomationRoots($WindowInfo) { return @($script:menuRoot) }
function Get-UiTreeRows($Roots,$Depth,$ProcessId) {
    Assert-Test ($ProcessId -eq 9876 -and $Roots.Count -eq 1 -and $Depth -le 8) 'Unscoped UI walk.'
    if ($Roots[0].Current.ControlType.ProgrammaticName -ceq 'ControlType.Menu') { return $script:menuRows }
    return ConvertTo-IdentCalendarScannerRows $script:formRows
}
function Resolve-ElementPath($Root,$Path) {
    if ($Root.Current.ControlType.ProgrammaticName -ceq 'ControlType.Menu') { return $script:menuItem }
    return $script:formElements[$Path]
}
function Reset-Runtime {
    $script:interrupted=$false; $script:guards=0; $script:invoked=0
    $script:context=[pscustomobject]@{ Handle=123; ProcessId=9876; WindowInfo=[pscustomobject]@{} }
    $script:formRows=@(New-IdentPatientFormFixture)
    $script:formElements=@{}
    foreach($row in $formRows) {
        $element=[pscustomobject]@{ Identity=('field-'+$row.path); PatternAvailable=$true;
            Current=[pscustomobject]@{ ProcessId=9876; ControlType=[pscustomobject]@{ProgrammaticName=$row.controlType};
                Name=$row.name; ClassName=$row.className; AutomationId=$row.automationId; IsEnabled=$row.isEnabled;
                IsOffscreen=$row.isOffscreen; BoundingRectangle=$row.bounds };
            Pattern=[pscustomobject]@{Current=[pscustomobject]@{Value=''}} }
        $element | Add-Member ScriptMethod GetRuntimeId { return $this.Identity }
        $element | Add-Member ScriptMethod TryGetCurrentPattern {
            param($Kind,[ref]$Result)
            if (-not $this.PatternAvailable) { return $false }
            $Result.Value=$this.Pattern; return $true
        }
        $script:formElements[$row.path]=$element
    }
    $caption=[regex]::Unescape('\u0417\u0430\u043f\u0438\u0441\u0430\u0442\u044c \u043d\u0430 \u043f\u0440\u0438\u0435\u043c...')
    $script:menuRows=@([pscustomobject]@{path='0/0';name=$caption;controlType='ControlType.MenuItem';isEnabled=$true;isOffscreen=$false;
        patterns=@('InvokePatternIdentifiers.Pattern');bounds='10,10,200,30'})
    $script:menuRoot=[pscustomobject]@{Current=[pscustomobject]@{ProcessId=9876;ControlType=[pscustomobject]@{ProgrammaticName='ControlType.Menu'};
        IsOffscreen=$false;IsEnabled=$true;BoundingRectangle='10,10,400,200'}}
    $menuRoot | Add-Member ScriptMethod GetRuntimeId { return 'menu-root' }
    $menuRoot | Add-Member ScriptMethod FindAll { param($Scope,$Condition) return @($this) }
    $script:menuItem=[pscustomobject]@{Current=[pscustomobject]@{ProcessId=9876;ControlType=[pscustomobject]@{ProgrammaticName='ControlType.MenuItem'};
        Name=$caption;IsOffscreen=$false;IsEnabled=$true;BoundingRectangle='10,10,200,30'};Pattern=[pscustomobject]@{};PatternAvailable=$true}
    $menuItem | Add-Member ScriptMethod GetRuntimeId { return 'menu-item' }
    $menuItem.Pattern | Add-Member ScriptMethod Invoke { $script:invoked++ }
    $menuItem | Add-Member ScriptMethod TryGetCurrentPattern {
        param($Kind,[ref]$Result)
        if (-not $this.PatternAvailable) { return $false }
        $Result.Value=$this.Pattern; return $true
    }
}
function Assert-FormRejected {
    $failed=$false
    try { $null=Read-IdentCalendarOpenedForm $context } catch { $failed=$true }
    Assert-Test ($failed -and $invoked -eq 0) 'Unsafe form readback was accepted.'
}
Reset-Runtime
$diagnostics=@{}
$form=Read-IdentCalendarOpenedForm $context $diagnostics
Assert-Test ($form.Empty -and $form.Bindings.Layout -ceq 'compact' -and $guards -ge 2 -and $invoked -eq 0) 'Blank compact form not recognized.'
Assert-Test ($diagnostics.FormReadback.Step -ceq 'verified' -and $diagnostics.FormReadback.FieldsChecked -eq 6 -and
    $diagnostics.FormReadback.FormWindowSeen -and -not $diagnostics.FormReadback.Role) 'Form readback stages were not recorded.'
$roles=$form.Bindings.Fields
foreach($role in $roles.Keys) {
    Reset-Runtime; $formElements[$roles[$role].Path].Pattern.Current.Value='unexpected'; Assert-FormRejected
    Reset-Runtime; $formElements[$roles[$role].Path].Current.ProcessId=1234; Assert-FormRejected
    Reset-Runtime; $formElements[$roles[$role].Path].Current.BoundingRectangle='0,0,2,2'; Assert-FormRejected
    Reset-Runtime; $formElements[$roles[$role].Path].PatternAvailable=$false; Assert-FormRejected
}
Reset-Runtime
$formElements[$roles.patientPhoneInput.Path].Pattern.Current.Value='+7 (***) ***-**-**'
$formElements[$roles.patientBirthDateInput.Path].Pattern.Current.Value='00.00.0000'
$form=Read-IdentCalendarOpenedForm $context
Assert-Test $form.Empty 'Empty IDENT masks should be recognized.'
Reset-Runtime; $script:formRows=@(New-IdentPatientFormFixture -Expanded); Assert-FormRejected
Reset-Runtime; $script:interrupted=$true; Assert-FormRejected
Reset-Runtime; $script:interrupted=$true; $diagnostics=@{}
try { $null=Read-IdentCalendarOpenedForm $context $diagnostics } catch { }
Assert-Test ($diagnostics.FormReadback.Step -ceq 'parent_guard' -and $diagnostics.FormReadback.FieldsChecked -eq 0 -and
    -not $diagnostics.FormReadback.FormWindowSeen) 'Parent guard failure must be distinguishable from scanning the new form.'
Reset-Runtime; $diagnostics=@{}
$formElements[$roles.patientFirstNameInput.Path].Pattern.Current.Value='private patient text'
try { $null=Read-IdentCalendarOpenedForm $context $diagnostics } catch { }
Assert-Test ($diagnostics.FormReadback.Step -ceq 'field_value' -and $diagnostics.FormReadback.Role -ceq 'patientFirstNameInput' -and
    ($diagnostics | ConvertTo-Json -Depth 4) -notmatch 'private patient text') 'Readback diagnostics leaked a value or lost the failing role.'
Reset-Runtime
$menu=Get-IdentCalendarOpenMenu $context
Assert-Test ($menu.Identity -ceq 'menu-root' -and $menu.ItemIdentity -ceq 'menu-item' -and $invoked -eq 0) 'Exact menu candidate not recognized.'
foreach($case in @('name','process','hidden','outside','pattern','buffer')) {
    Reset-Runtime
    switch($case) {
        'name' { $menuItem.Current.Name='wrong' }
        'process' { $menuItem.Current.ProcessId=1234 }
        'hidden' { $menuItem.Current.IsOffscreen=$true }
        'outside' { $menuItem.Current.BoundingRectangle='1000,1000,200,30' }
        'pattern' { $menuItem.PatternAvailable=$false }
        'buffer' { $menuRows[0].name='(Continue) '+$menuRows[0].name; $menuItem.Current.Name=$menuRows[0].name }
    }
    $failed=$false
    try { $null=Get-IdentCalendarOpenMenu $context } catch { $failed=$true }
    Assert-Test ($failed -and $invoked -eq 0) ('Unsafe menu target accepted: '+$case)
}
Write-Host ('IDENT CALENDAR OPEN RUNTIME TESTS OK: '+$script:checks+' (mock UIA only; no desktop input)')
