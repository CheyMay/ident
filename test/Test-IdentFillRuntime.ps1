Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
. (Join-Path $repo 'robot/ident-rpa/IdentPatientForm.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentFillCheck.ps1')
. (Join-Path $repo 'robot/ident-rpa/IdentFillRuntime.ps1')
. (Join-Path $PSScriptRoot 'fixtures/ident-patient-form.ps1')
function Assert([bool]$Ok,[string]$Message) { if (-not $Ok) { throw $Message } }
function Assert-IdentFillOperator($Context) { $script:guards++; if ($script:interrupted) { throw 'FILL_USER_ACTIVE' } }
function Get-ObservedElement($Handle) { return $script:elements['0'] }
function Assert-ObservedElement($Element,$Handle,$ProcessId,$RuntimeId) {
    if ($Element.Current.ProcessId -ne $ProcessId -or $Element.Identity -cne $RuntimeId) { throw 'FILL_WINDOW_CHANGED' }
    return $Element.Identity
}
function Format-Bounds($Rect) { return $Rect }
function Get-UiTreeRows($Roots,$Depth,$ProcessId) { Assert ($ProcessId -eq 9876 -and $Roots.Count -eq 1 -and $Depth -le 8) 'Unscoped UI scan.'; return $script:rows }
function Resolve-ElementPath($Root,$Path) { return $script:elements[$Path] }
function Reset-Runtime {
    $script:interrupted=$false; $script:guards=0; $script:setCalls=0
    $script:rows=@(New-IdentPatientFormFixture -Expanded)
    $script:rows+= [pscustomobject]@{ path='0/36/7'; rootName=$rows[0].rootName;
        name=[regex]::Unescape('\u041e\u0442\u043f\u0440\u0430\u0432\u0438\u0442\u044c'); automationId=''; className='CheckBox';
        controlType='ControlType.CheckBox'; bounds='1530,270,130,30'; isEnabled=$false; isOffscreen=$false; patterns=@() }
    $script:elements=@{}
    foreach($row in $script:rows) {
        $element=[pscustomobject]@{ Identity=('id-'+$row.path); AvailablePattern=$true;
            Current=[pscustomobject]@{ ProcessId=9876; ControlType=[pscustomobject]@{ ProgrammaticName=$row.controlType };
                Name=$row.name; ClassName=$row.className; AutomationId=$row.automationId; IsEnabled=$row.isEnabled;
                IsOffscreen=$row.isOffscreen; BoundingRectangle=$row.bounds };
            Pattern=[pscustomobject]@{ Current=[pscustomobject]@{ Value=''; IsReadOnly=$false; ToggleState=[System.Windows.Automation.ToggleState]::Off } } }
        $element | Add-Member ScriptMethod GetRuntimeId { return $this.Identity }
        $element | Add-Member ScriptMethod TryGetCurrentPattern {
            param($Kind,[ref]$Result)
            $wanted=if ($this.Current.ControlType.ProgrammaticName -eq 'ControlType.CheckBox') {
                [System.Windows.Automation.TogglePattern]::Pattern
            } else { [System.Windows.Automation.ValuePattern]::Pattern }
            if (-not $this.AvailablePattern -or $Kind -ne $wanted) { return $false }
            $Result.Value=$this.Pattern; return $true
        }
        $element.Pattern | Add-Member ScriptMethod SetValue { param($Value) $script:setCalls++; $this.Current.Value=$Value }
        $script:elements[$row.path]=$element
    }
    $request=[pscustomobject]@{ schemaVersion=1; purpose='ident-patient-fill-test'; doctorCaption='Fixture D. A.';
        planStart='2099-09-20T09:00:00+05:00'; planEnd='2099-09-20T09:45:00+05:00';
        patient=[pscustomobject]@{ surname='Fixture'; name='Test'; patronymic='Example'; phone='+79990000000'; birthDate='1990-01-01' }; comment='Synthetic' }
    $script:context=[pscustomobject]@{ Handle=123; ProcessId=9876; RootIdentity='id-0'; Plan=(New-IdentFillCheckPlan $request); Patterns=@{} }
}
function Reject-Snapshot([string]$Message) {
    $rejected=$false
    try { $null=Get-IdentFillRuntimeSnapshot $context } catch { $rejected=$true }
    Assert ($rejected -and $setCalls -eq 0) $Message
}
Reset-Runtime
$r=Invoke-IdentFillCheck $context.Plan { Get-IdentFillRuntimeSnapshot $context } `
    { param($role,$value,$snapshot) Set-IdentFillRuntimeValue $context $role $value $snapshot } {} -Execute -OperatorConfirmed
Assert ($r.Ok -and $r.Written -eq 6 -and $setCalls -eq 6 -and $guards -gt 30) 'Runtime failed a guarded synthetic fill.'
foreach($path in @('0/3','0/4','0/5','0/6','0/13','0/36/5/0')) {
    Reset-Runtime; $elements[$path].Current.ProcessId=4321; Reject-Snapshot 'Foreign process accepted.'
    Reset-Runtime; $elements[$path].Current.BoundingRectangle='0,0,2,2'; Reject-Snapshot 'Stale geometry accepted.'
    Reset-Runtime; $elements[$path].Current.AutomationId='changed'; Reject-Snapshot 'Changed control accepted.'
    Reset-Runtime; $elements[$path].Current.IsOffscreen=$true; Reject-Snapshot 'Hidden control accepted.'
    Reset-Runtime; $elements[$path].Pattern.Current.IsReadOnly=$true; Reject-Snapshot 'Read-only control accepted.'
    Reset-Runtime; $elements[$path].AvailablePattern=$false; Reject-Snapshot 'Unavailable ValuePattern accepted.'
}
Reset-Runtime; $elements['0/36/7'].Pattern.Current.ToggleState=[System.Windows.Automation.ToggleState]::On; Reject-Snapshot 'Notifications enabled accepted.'
Reset-Runtime; $elements['0/36/7'].AvailablePattern=$false; Reject-Snapshot 'Unverifiable notification checkbox accepted.'
Reset-Runtime; $elements['0/36/7'].Current.ProcessId=4321; Reject-Snapshot 'Foreign notification checkbox accepted.'
Reset-Runtime; $interrupted=$true; Reject-Snapshot 'Operator input ignored.'
Reset-Runtime; $prior=Get-IdentFillRuntimeSnapshot $context; $elements['0/4'].Identity='replaced'
$rejected=$false
try { Set-IdentFillRuntimeValue $context 'patientFirstNameInput' 'Test' $prior } catch { $rejected=$_.Exception.Message -eq 'FILL_FORM_CHANGED' }
Assert ($rejected -and $setCalls -eq 0) 'Writer used a cached control after replacement.'
Reset-Runtime; $prior=Get-IdentFillRuntimeSnapshot $context; $elements['0/3'].Pattern.Current.Value='operator-change'
$rejected=$false
try { Set-IdentFillRuntimeValue $context 'patientFirstNameInput' 'Test' $prior } catch { $rejected=$_.Exception.Message -eq 'FILL_FORM_CHANGED' }
Assert ($rejected -and $setCalls -eq 0) 'Writer ignored another changed field.'
Reset-Runtime
$elements['0/3'].Pattern.Current.Value=$context.Plan.Values.patientLastNameInput
$elements['0/4'].Pattern | Add-Member -Force ScriptMethod SetValue {
    param($Value)
    $script:setCalls++; $this.Current.Value=$Value
    $script:elements['0/4'].Identity='replaced-after-set'
}
$r=Invoke-IdentFillCheck $context.Plan { Get-IdentFillRuntimeSnapshot $context } `
    {param($role,$value,$snapshot) Set-IdentFillRuntimeValue $context $role $value $snapshot} {} -Execute -OperatorConfirmed
Assert (-not $r.Ok -and $r.WriteAttempts -eq 1 -and $r.WriteReturned -eq 1 -and $r.Written -eq 0 -and $r.Skipped -eq 1 -and
    $r.FailurePhase -eq 'readback' -and $r.FailureRole -eq 'patientFirstNameInput' -and $r.FailureReason -eq 'field_identity' -and
    $setCalls -eq 1 -and -not $r.SaveInvoked -and $r.RequiresManualReview) 'Replaced first-name field was retried or incorrectly diagnosed.'
Reset-Runtime
$elements['0/3'].Pattern.Current.Value=$context.Plan.Values.patientLastNameInput
$r=Invoke-IdentFillCheck $context.Plan { Get-IdentFillRuntimeSnapshot $context } `
    {param($role,$value,$snapshot) Set-IdentFillRuntimeValue $context $role $value $snapshot} `
    { $script:elements['0/4'].Current.BoundingRectangle='0,0,2,2' } -Execute -OperatorConfirmed
Assert ($r.WriteAttempts -eq 1 -and $r.WriteReturned -eq 0 -and $r.Skipped -eq 1 -and $r.Written -eq 0 -and $setCalls -eq 0 -and
    $r.FailurePhase -eq 'write' -and $r.FailureReason -eq 'field_geometry' -and $r.FailureRole -eq 'patientFirstNameInput' -and
    $r.RequiresManualReview) 'Pre-set geometry rejection was conflated with a returned setter.'
Reset-Runtime
$elements['0/3'].Pattern | Add-Member -Force ScriptMethod SetValue { param($Value) $script:setCalls++; throw 'PRIVATE_PROVIDER_MESSAGE' }
$r=Invoke-IdentFillCheck $context.Plan { Get-IdentFillRuntimeSnapshot $context } `
    {param($role,$value,$snapshot) Set-IdentFillRuntimeValue $context $role $value $snapshot} {} -Execute -OperatorConfirmed
Assert ($r.ErrorCode -eq 'FILL_CHECK_FAILED' -and $r.FailureReason -eq 'setter_exception' -and $r.WriteReturned -eq 0 -and
    $r.FailurePhase -eq 'write' -and $setCalls -eq 1 -and ($r | ConvertTo-Json) -notmatch 'PRIVATE') 'Setter exception was retried or leaked.'
# Restore the production operator guard against a synthetic native-input provider.
Add-Type -TypeDefinition @'
namespace Code9IdentRobot {
    public static class NativeInput {
        public static uint Tick = 10;
        public static int Handle = 123;
        public static int ProcessId = 9876;
        public static bool InteractiveDesktopAvailable() { return true; }
        public static int ForegroundHandle() { return Handle; }
        public static int ForegroundProcessId() { return ProcessId; }
        public static uint LastInputTick() { return Tick; }
    }
}
'@
. (Join-Path $repo 'robot/ident-rpa/IdentFillRuntime.ps1')
function Assert-IdentFillCheckInstallation($Directory) { if ($script:robotEnabled) { throw 'FILL_ROBOT_ENABLED' } }
$script:robotEnabled=$false
Reset-Runtime
$context | Add-Member NoteProperty InputTick 9
$context | Add-Member NoteProperty Directory 'synthetic'
$rejected=$false
try { $null=Get-IdentFillRuntimeSnapshot $context } catch { $rejected=$_.Exception.Message -eq 'FILL_USER_ACTIVE' }
Assert $rejected 'Ordinary fill guard accepted input between operations.'
$sample=Get-IdentFillObservationSnapshot $context
Assert ($sample.Fields.Count -eq 6 -and $context.InputTick -eq 10 -and $context.Patterns.Count -eq 0 -and $setCalls -eq 0) 'Read-only sampler retained a writer or ignored manual input semantics.'
[Code9IdentRobot.NativeInput]::Handle=456
$rejected=$false
try { $null=Get-IdentFillObservationSnapshot $context } catch { $rejected=$_.Exception.Message -eq 'FILL_WINDOW_CHANGED' }
Assert ($rejected -and $setCalls -eq 0) 'Read-only sampler followed another foreground window.'
[Code9IdentRobot.NativeInput]::Handle=123
$script:robotEnabled=$true
$rejected=$false
try { $null=Get-IdentFillObservationSnapshot $context } catch { $rejected=$_.Exception.Message -eq 'FILL_ROBOT_ENABLED' }
Assert $rejected 'Read-only sampler ignored robot enablement.'
$script:robotEnabled=$false
function Get-UiTreeRows($Roots,$Depth,$ProcessId) { [Code9IdentRobot.NativeInput]::Tick++; return $script:rows }
$rejected=$false
try { $null=Get-IdentFillObservationSnapshot $context } catch { $rejected=$_.Exception.Message -eq 'FILL_USER_ACTIVE' }
Assert ($rejected -and $context.Patterns.Count -eq 0 -and $setCalls -eq 0) 'Read-only sampler accepted input during a scan.'
Write-Host 'IDENT FILL RUNTIME TESTS OK (mock UIA only; no desktop actions)'
