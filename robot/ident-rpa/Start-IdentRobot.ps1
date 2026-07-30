param(
  [ValidateSet('Inspect', 'DryRun', 'RunOnce', 'Loop')]
  [string]$Mode = 'DryRun',

  [string]$ConfigPath = '',

  [string]$TaskFile = '',

  [int]$MaxTasks = 1,

  [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot 'config.example.json'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

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
  return ('{0},{1},{2},{3}' -f [int]$Rect.X, [int]$Rect.Y, [int]$Rect.Width, [int]$Rect.Height)
}

function Export-UiTree {
  param(
    [System.Windows.Automation.AutomationElement]$Root,
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

  Walk $Root 0 '0'
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
    [System.Windows.Automation.AutomationElement]$Window,
    [object]$Config
  )

  $result = @{}
  foreach ($step in @($Config.workflow.steps)) {
    if (-not $step.selector) {
      continue
    }
    $selector = $Config.selectors.($step.selector)
    $element = Find-RobotElement $Window $selector
    $result[$step.selector] = [bool]$element
  }
  return $result
}

function Invoke-Workflow {
  param(
    [System.Windows.Automation.AutomationElement]$Window,
    [object]$Task,
    [object]$Config,
    [bool]$Execute
  )

  $ticket = $Task.ticket
  Write-RobotLog $Config 'info' 'Prepared IDENT task' @{
    id = $Task.id
    client = $ticket.ClientFullName
    phone = $ticket.ClientPhone
    planStart = $ticket.PlanStart
    doctor = $ticket.DoctorName
  }

  if (-not $Execute) {
    $selectors = Test-WorkflowSelectors $Window $Config
    Write-RobotLog $Config 'info' 'Dry-run only; no UI actions executed' @{ selectors = $selectors }
    return
  }

  if (-not $Config.workflow.allowUnsafeExecution) {
    throw 'Real UI execution is disabled. Set workflow.allowUnsafeExecution=true in a local config and pass -Execute.'
  }

  foreach ($step in @($Config.workflow.steps)) {
    $selector = $Config.selectors.($step.selector)
    $element = Find-RobotElement $Window $selector
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

    $delayMs = if ($Config.workflow.stepDelayMs) { [int]$Config.workflow.stepDelayMs } else { 500 }
    Start-Sleep -Milliseconds $delayMs
    Write-RobotLog $Config 'info' "Executed step '$($step.name)'" @{ action = $step.action; selector = $step.selector }
  }
}

$config = Read-JsonFile $ConfigPath
$windowInfo = Get-IdentWindow $config

if ($Mode -eq 'Inspect') {
  if (-not $windowInfo) {
    throw 'IDENT window was not found. Check ident.processName and ident.windowTitleRegex in config.'
  }
  $outputPath = if ($config.inspect.outputPath) { $config.inspect.outputPath } else { Join-Path $PSScriptRoot 'ui-tree.json' }
  $maxDepth = if ($config.inspect.maxDepth) { [int]$config.inspect.maxDepth } else { 6 }
  $count = Export-UiTree $windowInfo.element $maxDepth $outputPath
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
        client = $task.ticket.ClientFullName
        phone = $task.ticket.ClientPhone
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
    Invoke-Workflow $windowInfo.element $task $config ([bool]($Execute -and ($Mode -in @('RunOnce', 'Loop'))))
  }

  if ($Mode -ne 'Loop') {
    break
  }

  $pollInterval = if ($config.pollIntervalSeconds) { [int]$config.pollIntervalSeconds } else { 30 }
  Start-Sleep -Seconds $pollInterval
  $tasks = @(Get-RobotTasks $config $TaskFile $MaxTasks)
} while ($true)
