param(
  [ValidateSet('Inspect', 'DryRun', 'RunOnce', 'Loop')]
  [string]$Mode = 'DryRun',

  [string]$ConfigPath = '',

  [string]$TaskFile = '',

  [int]$MaxTasks = 1,

  [int]$MinUserIdleSeconds = 0,

  [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot 'config.example.json'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

if (-not ('Code9IdentRobot.NativeInput' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Code9IdentRobot {
  public static class NativeInput {
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO {
      public uint cbSize;
      public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO input);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint desiredAccess);

    [DllImport("user32.dll")]
    private static extern bool CloseDesktop(IntPtr desktop);

    [DllImport("user32.dll")]
    private static extern bool SwitchDesktop(IntPtr desktop);

    public static int IdleSeconds() {
      var input = new LASTINPUTINFO();
      input.cbSize = (uint)Marshal.SizeOf(input);
      if (!GetLastInputInfo(ref input)) return 0;
      var elapsed = unchecked((uint)Environment.TickCount - input.dwTime);
      return (int)(elapsed / 1000);
    }

    public static bool InteractiveDesktopAvailable() {
      const uint DESKTOP_SWITCHDESKTOP = 0x0100;
      var desktop = OpenInputDesktop(0, false, DESKTOP_SWITCHDESKTOP);
      if (desktop == IntPtr.Zero) return false;
      try {
        return SwitchDesktop(desktop);
      }
      finally {
        CloseDesktop(desktop);
      }
    }
  }
}
'@
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "File not found: $Path"
  }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-ObjectProperty {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if ($null -eq $Object) {
    return $Default
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function Join-Url {
  param([string]$BaseUrl, [string]$Path)
  return ($BaseUrl.TrimEnd('/') + '/' + $Path.TrimStart('/'))
}

function Get-UserIdleSeconds {
  try {
    return [Math]::Max(0, [Code9IdentRobot.NativeInput]::IdleSeconds())
  }
  catch {
    return 0
  }
}

function Assert-UserIdle {
  param([int]$MinimumSeconds)

  if ($MinimumSeconds -le 0) {
    return
  }
  $idleSeconds = Get-UserIdleSeconds
  if ($idleSeconds -lt $MinimumSeconds) {
    Write-Host "ROBOT_DEFER_USER_ACTIVE idle=$idleSeconds required=$MinimumSeconds"
    throw 'ROBOT_DEFER_USER_ACTIVE'
  }
}

function Assert-InteractiveDesktop {
  try {
    if ([Code9IdentRobot.NativeInput]::InteractiveDesktopAvailable()) {
      return
    }
  }
  catch {
  }
  Write-Host 'ROBOT_DEFER_SESSION_LOCKED'
  throw 'ROBOT_DEFER_SESSION_LOCKED'
}

function Write-RobotLog {
  param(
    [object]$Config,
    [string]$Level,
    [string]$Message,
    [hashtable]$Data = @{}
  )

  $logDir = if ($Config.logDir) { $Config.logDir } else { Join-Path $PSScriptRoot 'logs' }
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  $entry = [ordered]@{
    ts = (Get-Date).ToString('o')
    level = $Level
    message = $Message
    data = $Data
  }
  $line = $entry | ConvertTo-Json -Depth 12 -Compress
  $file = Join-Path $logDir ("ident-rpa-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
  Add-Content -LiteralPath $file -Value $line -Encoding UTF8
  Write-Host ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message)
}

function Get-BackendRecords {
  param([object]$Config)

  if (-not $Config.backend.baseUrl) {
    return @()
  }

  if (-not $Config.backend.serviceApiKey) {
    throw 'backend.serviceApiKey is required when backend.baseUrl is set'
  }

  $status = if ($Config.backend.ticketStatus) { $Config.backend.ticketStatus } else { 'queued' }
  $url = Join-Url $Config.backend.baseUrl ("/api/tickets?status=$status")
  $headers = @{ 'X-API-Key' = [string]$Config.backend.serviceApiKey }
  $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -TimeoutSec 30
  $records = Get-ObjectProperty $response 'records' @()
  if (-not $records) {
    return @()
  }
  return @($records)
}

function Get-FileRecords {
  param([string]$Path)

  if (-not $Path) {
    return @()
  }

  $payload = Read-JsonFile $Path
  $records = Get-ObjectProperty $payload 'records' @()
  if ($records) {
    return @($records)
  }
  $ticket = Get-ObjectProperty $payload 'ticket' $null
  if ($ticket) {
    return @([pscustomobject]@{ id = $ticket.Id; status = 'queued'; ticket = $ticket })
  }
  if ($payload.PSObject.Properties.Name -contains 'Id') {
    return @([pscustomobject]@{ id = $payload.Id; status = 'queued'; ticket = $payload })
  }
  throw "Unsupported task file format: $Path"
}

function Convert-ToRobotTask {
  param([object]$Record)

  $ticket = Get-ObjectProperty $Record 'ticket' $Record
  $id = Get-ObjectProperty $Record 'id' (Get-ObjectProperty $ticket 'Id' '')
  $status = Get-ObjectProperty $Record 'status' 'queued'
  $source = Get-ObjectProperty $Record 'source' ''
  $amoLeadId = Get-ObjectProperty $Record 'amoLeadId' ''
  return [pscustomobject]@{
    id = [string]$id
    status = [string]$status
    source = [string]$source
    amoLeadId = [string]$amoLeadId
    ticket = $ticket
  }
}

function Get-RobotTasks {
  param([object]$Config, [string]$TaskFile, [int]$MaxTasks)

  $records = if ($TaskFile) {
    Get-FileRecords $TaskFile
  } else {
    Get-BackendRecords $Config
  }

  return @($records |
    Select-Object -First $MaxTasks |
    ForEach-Object { Convert-ToRobotTask $_ })
}

function Get-IdentWindow {
  param([object]$Config)

  $processName = [string]$Config.ident.processName
  $titleRegex = [string]$Config.ident.windowTitleRegex

  $candidates = Get-Process | Where-Object {
    $_.MainWindowHandle -ne 0 -and
    ((-not $processName) -or $_.ProcessName -eq $processName) -and
    ((-not $titleRegex) -or $_.MainWindowTitle -match $titleRegex)
  }

  if (-not $candidates) {
    return $null
  }

  $process = $candidates | Select-Object -First 1
  $window = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
  if (-not $window) {
    return $null
  }

  return [pscustomobject]@{
    process = $process
    element = $window
  }
}

function Format-Bounds {
  param([System.Windows.Rect]$Rect)

  $values = @($Rect.X, $Rect.Y, $Rect.Width, $Rect.Height)
  $invalid = $Rect.IsEmpty -or @($values | Where-Object {
      [double]::IsNaN([double]$_) -or
      [double]::IsInfinity([double]$_) -or
      [double]$_ -gt [int]::MaxValue -or
      [double]$_ -lt [int]::MinValue
    }).Count -gt 0
  if ($invalid) {
    return ''
  }

  return ('{0},{1},{2},{3}' -f [int]$Rect.X, [int]$Rect.Y, [int]$Rect.Width, [int]$Rect.Height)
}

function Export-UiTree {
  param(
    [object[]]$Roots,
    [int]$MaxDepth,
    [string]$OutputPath
  )

  $rows = New-Object System.Collections.Generic.List[object]

  function Walk {
    param(
      [System.Windows.Automation.AutomationElement]$Element,
      [int]$Depth,
      [string]$Path
    )

    if ($Depth -gt $MaxDepth) {
      return
    }

    $current = $Element.Current
    $rows.Add([ordered]@{
      depth = $Depth
      path = $Path
      name = $current.Name
      automationId = $current.AutomationId
      className = $current.ClassName
      controlType = $current.ControlType.ProgrammaticName
      isEnabled = $current.IsEnabled
      bounds = (Format-Bounds $current.BoundingRectangle)
    })

    $children = $Element.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition
    )

    for ($i = 0; $i -lt $children.Count; $i++) {
      Walk $children.Item($i) ($Depth + 1) ("$Path/$i")
    }
  }

  for ($rootIndex = 0; $rootIndex -lt $Roots.Count; $rootIndex++) {
    Walk $Roots[$rootIndex] 0 ([string]$rootIndex)
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
  $rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
  return $rows.Count
}

function New-PropertyCondition {
  param([string]$PropertyName, [string]$Value)

  switch ($PropertyName) {
    'automationId' {
      return [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $Value
      )
    }
    'name' {
      return [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Value
      )
    }
    'className' {
      return [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty,
        $Value
      )
    }
    'controlType' {
      $type = [System.Windows.Automation.ControlType].GetFields() |
        Where-Object { $_.Name -eq $Value } |
        Select-Object -First 1
      if (-not $type) {
        throw "Unknown controlType: $Value"
      }
      return [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        $type.GetValue($null)
      )
    }
    default {
      throw "Unsupported selector property: $PropertyName"
    }
  }
}

function Find-RobotElement {
  param(
    [System.Windows.Automation.AutomationElement]$Root,
    [object]$Selector
  )

  if (-not $Selector) {
    return $null
  }

  $conditions = New-Object System.Collections.Generic.List[System.Windows.Automation.Condition]
  foreach ($property in @('automationId', 'name', 'className', 'controlType')) {
    if ($Selector.PSObject.Properties.Name -contains $property -and $Selector.$property) {
      $conditions.Add((New-PropertyCondition $property ([string]$Selector.$property)))
    }
  }

  if ($conditions.Count -eq 0) {
    return $null
  }

  $condition = if ($conditions.Count -eq 1) {
    $conditions[0]
  } else {
    [System.Windows.Automation.AndCondition]::new($conditions.ToArray())
  }

  return $Root.FindFirst([System.Windows.Automation.TreeScope]::Subtree, $condition)
}

function Get-IdentAutomationRoots {
  param([object]$WindowInfo)

  $roots = New-Object System.Collections.Generic.List[System.Windows.Automation.AutomationElement]
  $handles = @{}
  if ($WindowInfo.element) {
    $roots.Add($WindowInfo.element)
    $handles[[int]$WindowInfo.element.Current.NativeWindowHandle] = $true
  }

  $processCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty,
    [int]$WindowInfo.process.Id
  )
  $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    $processCondition
  )
  for ($index = 0; $index -lt $windows.Count; $index++) {
    $window = $windows.Item($index)
    $handle = [int]$window.Current.NativeWindowHandle
    if (-not $handles.ContainsKey($handle)) {
      $roots.Add($window)
      $handles[$handle] = $true
    }
  }
  return @($roots)
}

function Find-RobotElementInIdent {
  param(
    [object]$WindowInfo,
    [object]$Selector
  )

  foreach ($root in @(Get-IdentAutomationRoots $WindowInfo)) {
    try {
      $element = Find-RobotElement $root $Selector
      if ($element) {
        return $element
      }
    }
    catch [System.Windows.Automation.ElementNotAvailableException] {
    }
  }
  return $null
}

function Invoke-Click {
  param([System.Windows.Automation.AutomationElement]$Element)

  $pattern = $null
  if ($Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
    $pattern.Invoke()
    return
  }

  throw 'Element does not support InvokePattern; add a safer selector or implement a deliberate mouse fallback.'
}

function Set-ElementValue {
  param(
    [System.Windows.Automation.AutomationElement]$Element,
    [string]$Value
  )

  $pattern = $null
  if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
    $pattern.SetValue($Value)
    return
  }

  throw 'Element does not support ValuePattern; add a safer selector or implement a deliberate keyboard fallback.'
}

function Resolve-TaskValue {
  param([object]$Task, [string]$Path)

  $value = $Task
  foreach ($segment in $Path.Split('.')) {
    if (-not $value) {
      return ''
    }
    if ($value.PSObject.Properties.Name -notcontains $segment) {
      return ''
    }
    $value = $value.$segment
  }
  return [string]$value
}

function Test-WorkflowSelectors {
  param(
    [object]$WindowInfo,
    [object]$Config
  )

  $result = @{}
  foreach ($step in @($Config.workflow.steps)) {
    if (-not $step.selector) {
      continue
    }
    $selector = $Config.selectors.($step.selector)
    $element = Find-RobotElementInIdent $WindowInfo $selector
    $result[$step.selector] = [bool]$element
  }
  return $result
}

function Wait-WorkflowSuccess {
  param(
    [object]$WindowInfo,
    [object]$Config
  )

  $condition = Get-ObjectProperty $Config.workflow 'successCondition' $null
  if (-not $condition) {
    throw 'workflow.successCondition is required for real execution'
  }

  $conditionType = [string](Get-ObjectProperty $condition 'type' '')
  if ($conditionType -notin @('elementPresent', 'elementMissing')) {
    throw "Unsupported workflow success condition: $conditionType"
  }

  $selectorName = [string](Get-ObjectProperty $condition 'selector' '')
  $selector = Get-ObjectProperty $Config.selectors $selectorName $null
  if (-not $selector) {
    throw "Success selector '$selectorName' is not configured"
  }

  $timeoutSeconds = [Math]::Max(1, [Math]::Min(120, [int](Get-ObjectProperty $condition 'timeoutSeconds' 15)))
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  do {
    $present = [bool](Find-RobotElementInIdent $WindowInfo $selector)
    if (
      ($conditionType -eq 'elementPresent' -and $present) -or
      ($conditionType -eq 'elementMissing' -and -not $present)
    ) {
      return
    }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)

  throw "IDENT did not confirm the save operation within $timeoutSeconds seconds"
}

function Invoke-Workflow {
  param(
    [object]$WindowInfo,
    [object]$Task,
    [object]$Config,
    [bool]$Execute
  )

  $ticket = $Task.ticket
  Write-RobotLog $Config 'info' 'Prepared IDENT task' @{
    id = $Task.id
    planStart = $ticket.PlanStart
    doctor = $ticket.DoctorName
  }

  if (-not $Execute) {
    $selectors = Test-WorkflowSelectors $WindowInfo $Config
    Write-RobotLog $Config 'info' 'Dry-run only; no UI actions executed' @{ selectors = $selectors }
    return
  }

  if (-not $Config.workflow.allowUnsafeExecution) {
    throw 'Real UI execution is disabled. Set workflow.allowUnsafeExecution=true in a local config and pass -Execute.'
  }

  Assert-InteractiveDesktop
  Assert-UserIdle -MinimumSeconds $MinUserIdleSeconds
  $saveInvoked = $false
  foreach ($step in @($Config.workflow.steps)) {
    if (-not $saveInvoked) {
      Assert-InteractiveDesktop
      Assert-UserIdle -MinimumSeconds $MinUserIdleSeconds
    }
    $selector = $Config.selectors.($step.selector)
    $element = Find-RobotElementInIdent $WindowInfo $selector
    if (-not $element) {
      throw "Selector '$($step.selector)' was not found for step '$($step.name)'"
    }

    if ($Config.workflow.confirmBeforeEachStep) {
      $answer = Read-Host "Execute step '$($step.name)'? Type YES"
      if ($answer -ne 'YES') {
        throw "Execution stopped before step '$($step.name)'"
      }
    }

    switch ($step.action) {
      'click' {
        Invoke-Click $element
      }
      'setText' {
        $value = Resolve-TaskValue $Task ([string]$step.valueFrom)
        Set-ElementValue $element $value
      }
      default {
        throw "Unsupported workflow action: $($step.action)"
      }
    }

    if ([string]$step.selector -eq 'saveButton' -or [string]$step.name -eq 'save') {
      $saveInvoked = $true
    }

    $delayMs = if ($Config.workflow.stepDelayMs) { [int]$Config.workflow.stepDelayMs } else { 500 }
    Start-Sleep -Milliseconds $delayMs
    Write-RobotLog $Config 'info' "Executed step '$($step.name)'" @{ action = $step.action; selector = $step.selector }
  }

  Wait-WorkflowSuccess $WindowInfo $Config
  Write-RobotLog $Config 'info' 'IDENT save operation verified' @{ id = $Task.id }
}

$robotMutex = New-Object Threading.Mutex($false, 'Local\Code9IdentRobotExecution')
$ownsRobotMutex = $false
try {
  try {
    $ownsRobotMutex = $robotMutex.WaitOne(0)
  }
  catch [Threading.AbandonedMutexException] {
    $ownsRobotMutex = $true
  }
  if (-not $ownsRobotMutex) {
    Write-Host 'ROBOT_DEFER_BUSY'
    exit 75
  }

  $config = Read-JsonFile $ConfigPath
  $windowInfo = Get-IdentWindow $config

if ($Mode -eq 'Inspect') {
  if (-not $windowInfo) {
    throw 'IDENT window was not found. Check ident.processName and ident.windowTitleRegex in config.'
  }
  $outputPath = if ($config.inspect.outputPath) { $config.inspect.outputPath } else { Join-Path $PSScriptRoot 'ui-tree.json' }
  $maxDepth = if ($config.inspect.maxDepth) { [int]$config.inspect.maxDepth } else { 6 }
  $count = Export-UiTree (Get-IdentAutomationRoots $windowInfo) $maxDepth $outputPath
  Write-RobotLog $config 'info' 'UI tree exported' @{
    outputPath = $outputPath
    controls = $count
    processName = $windowInfo.process.ProcessName
    title = $windowInfo.process.MainWindowTitle
  }
  return
}

$tasks = @(Get-RobotTasks $config $TaskFile $MaxTasks)
if ($tasks.Count -eq 0) {
  Write-RobotLog $config 'info' 'No tasks to process' @{}
  return
}

if (-not $windowInfo) {
  if ($Mode -eq 'DryRun') {
    foreach ($task in $tasks) {
      Write-RobotLog $config 'warn' 'IDENT window was not found; task parsed but selectors were not checked' @{
        id = $task.id
        planStart = $task.ticket.PlanStart
        doctor = $task.ticket.DoctorName
      }
    }
    return
  }
  throw 'IDENT window was not found. Start IDENT and check ident.processName/windowTitleRegex in config.'
}

  do {
    foreach ($task in $tasks) {
      Invoke-Workflow $windowInfo $task $config ([bool]($Execute -and ($Mode -in @('RunOnce', 'Loop'))))
    }

    if ($Mode -ne 'Loop') {
      break
    }

    $pollInterval = if ($config.pollIntervalSeconds) { [int]$config.pollIntervalSeconds } else { 30 }
    Start-Sleep -Seconds $pollInterval
    $tasks = @(Get-RobotTasks $config $TaskFile $MaxTasks)
  } while ($true)
}
finally {
  if ($ownsRobotMutex) {
    $robotMutex.ReleaseMutex()
  }
  $robotMutex.Dispose()
}
