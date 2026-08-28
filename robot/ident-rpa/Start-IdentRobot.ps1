param(
  [ValidateSet('Inspect', 'Calibrate', 'Verify', 'DryRun', 'RunOnce', 'Loop', 'SelfTest')]
  [string]$Mode = 'DryRun',

  [string]$ConfigPath = '',

  [string]$TaskFile = '',

  [int]$MaxTasks = 1,

  [int]$MinUserIdleSeconds = 0,

  [string]$ReportPath = '',

  [string]$SuccessMarkerPath = '',

  [switch]$Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot 'config.example.json'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:SaveInvoked = $false
$script:CurrentTaskId = ''

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

function Write-JsonFileAtomic {
  param(
    [string]$Path,
    [object]$Value,
    [int]$Depth = 16
  )

  $fullPath = [IO.Path]::GetFullPath($Path)
  $directory = Split-Path -Parent $fullPath
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $temporaryPath = "$fullPath.tmp-$([Guid]::NewGuid().ToString('N'))"
  try {
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    if (Test-Path -LiteralPath $fullPath) {
      $backupPath = "$fullPath.bak"
      Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force
    }
    Move-Item -LiteralPath $temporaryPath -Destination $fullPath -Force
  }
  finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
  }
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
  if (Test-Path -LiteralPath $file) {
    $logFile = Get-Item -LiteralPath $file -ErrorAction SilentlyContinue
    if ($null -ne $logFile -and $logFile.Length -ge 5MB) {
      for ($index = 2; $index -ge 1; $index--) {
        $source = "$file.$index"
        $target = "$file.$($index + 1)"
        if (Test-Path -LiteralPath $source) {
          Move-Item -LiteralPath $source -Destination $target -Force
        }
      }
      Move-Item -LiteralPath $file -Destination "$file.1" -Force
    }
  }
  Add-Content -LiteralPath $file -Value $line -Encoding UTF8
  Write-Host ("[{0}] {1}" -f $Level.ToUpperInvariant(), $Message)
}

function Save-FailureScreenshot {
  param(
    [object]$Config,
    [object]$WindowInfo,
    [string]$Prefix = 'failure'
  )

  try {
    $logDir = if ($Config.logDir) { [string]$Config.logDir } else { Join-Path $PSScriptRoot 'logs' }
    $directory = Join-Path $logDir 'screenshots'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $bounds = if ($null -ne $WindowInfo -and $null -ne $WindowInfo.element) {
      $WindowInfo.element.Current.BoundingRectangle
    } else {
      [System.Windows.Forms.SystemInformation]::VirtualScreen
    }
    if (
      $bounds.IsEmpty -or $bounds.Width -lt 2 -or $bounds.Height -lt 2 -or
      [double]::IsNaN([double]$bounds.X) -or [double]::IsInfinity([double]$bounds.X)
    ) {
      return ''
    }
    $bitmap = New-Object Drawing.Bitmap([int]$bounds.Width, [int]$bounds.Height)
    try {
      $graphics = [Drawing.Graphics]::FromImage($bitmap)
      try {
        $graphics.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $bitmap.Size)
      }
      finally {
        $graphics.Dispose()
      }
      $safePrefix = ($Prefix -replace '[^a-zA-Z0-9_-]', '-')
      $path = Join-Path $directory ("{0}-{1}.png" -f $safePrefix, (Get-Date -Format 'yyyyMMdd-HHmmss'))
      $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
      return $path
    }
    finally {
      $bitmap.Dispose()
    }
  }
  catch {
    return ''
  }
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

function Get-UiTreeRows {
  param(
    [object[]]$Roots,
    [int]$MaxDepth
  )

  $rows = New-Object System.Collections.Generic.List[object]

  function Walk {
    param(
      [System.Windows.Automation.AutomationElement]$Element,
      [int]$Depth,
      [string]$Path,
      [string]$RootName
    )

    if ($Depth -gt $MaxDepth) {
      return
    }

    $current = $Element.Current
    $rows.Add([ordered]@{
      depth = $Depth
      path = $Path
      rootName = $RootName
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
      Walk $children.Item($i) ($Depth + 1) ("$Path/$i") $RootName
    }
  }

  for ($rootIndex = 0; $rootIndex -lt $Roots.Count; $rootIndex++) {
    $rootName = [string]$Roots[$rootIndex].Current.Name
    Walk $Roots[$rootIndex] 0 ([string]$rootIndex) $rootName
  }
  return @($rows)
}

function Export-UiTree {
  param(
    [object[]]$Roots,
    [int]$MaxDepth,
    [string]$OutputPath
  )

  $rows = @(Get-UiTreeRows -Roots $Roots -MaxDepth $MaxDepth)
  New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
  $rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
  return @($rows)
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
      $controlTypeName = ([string]$Value) -replace '^ControlType\.', ''
      $type = [System.Windows.Automation.ControlType].GetFields() |
        Where-Object { $_.Name -eq $controlTypeName } |
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

function Test-ElementMatchesSelector {
  param(
    [System.Windows.Automation.AutomationElement]$Element,
    [object]$Selector
  )

  if ($null -eq $Element -or $null -eq $Selector) {
    return $false
  }
  $current = $Element.Current
  if ($Selector.PSObject.Properties.Name -contains 'automationId' -and $Selector.automationId -and
      [string]$current.AutomationId -ne [string]$Selector.automationId) { return $false }
  if ($Selector.PSObject.Properties.Name -contains 'name' -and $Selector.name -and
      [string]$current.Name -ne [string]$Selector.name) { return $false }
  if ($Selector.PSObject.Properties.Name -contains 'className' -and $Selector.className -and
      [string]$current.ClassName -ne [string]$Selector.className) { return $false }
  if ($Selector.PSObject.Properties.Name -contains 'controlType' -and $Selector.controlType) {
    $actualType = [string]$current.ControlType.ProgrammaticName
    $expectedType = [string]$Selector.controlType
    if ($actualType -ne $expectedType -and $actualType -ne "ControlType.$expectedType") { return $false }
  }
  return $true
}

function Resolve-ElementPath {
  param(
    [System.Windows.Automation.AutomationElement]$Root,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }
  $segments = @($Path.Split('/') | Select-Object -Skip 1)
  $current = $Root
  foreach ($segment in $segments) {
    $index = 0
    if (-not [int]::TryParse($segment, [ref]$index) -or $index -lt 0) {
      return $null
    }
    $children = $current.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    if ($index -ge $children.Count) {
      return $null
    }
    $current = $children.Item($index)
  }
  return $current
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
      $rootRegex = [string](Get-ObjectProperty $Selector 'rootTitleRegex' '')
      if ($rootRegex -and [string]$root.Current.Name -notmatch $rootRegex) {
        continue
      }
      $path = [string](Get-ObjectProperty $Selector 'path' '')
      if ($path) {
        $pathElement = Resolve-ElementPath -Root $root -Path $path
        if ($null -ne $pathElement -and (Test-ElementMatchesSelector $pathElement $Selector)) {
          return $pathElement
        }
      }
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

function Convert-BoundsText {
  param([string]$Value)

  $parts = @([string]$Value -split ',')
  if ($parts.Count -ne 4) {
    return $null
  }
  $values = New-Object int[] 4
  for ($index = 0; $index -lt 4; $index++) {
    $parsed = 0
    if (-not [int]::TryParse($parts[$index], [ref]$parsed)) {
      return $null
    }
    $values[$index] = $parsed
  }
  if ($values[2] -le 0 -or $values[3] -le 0 -or $values[0] -lt -10000 -or $values[1] -lt -10000) {
    return $null
  }
  return [pscustomobject]@{
    X = $values[0]
    Y = $values[1]
    Width = $values[2]
    Height = $values[3]
    Right = $values[0] + $values[2]
    Bottom = $values[1] + $values[3]
    CenterX = $values[0] + [Math]::Floor($values[2] / 2)
    CenterY = $values[1] + [Math]::Floor($values[3] / 2)
  }
}

function Get-NearbyControlText {
  param(
    [object]$Row,
    [object[]]$Rows
  )

  $target = Convert-BoundsText ([string]$Row.bounds)
  if ($null -eq $target) {
    return ''
  }
  $nearby = New-Object System.Collections.Generic.List[string]
  foreach ($candidate in $Rows) {
    if ([string]$candidate.path -eq [string]$Row.path -or
        [string]$candidate.rootName -ne [string]$Row.rootName -or
        [string]::IsNullOrWhiteSpace([string]$candidate.name)) {
      continue
    }
    if ([string]$candidate.controlType -notin @('ControlType.Text', 'ControlType.Header', 'ControlType.Group')) {
      continue
    }
    $label = Convert-BoundsText ([string]$candidate.bounds)
    if ($null -eq $label) {
      continue
    }
    $leftAligned = $label.Right -le ($target.X + 24) -and
      ($target.X - $label.Right) -le 420 -and
      [Math]::Abs($label.CenterY - $target.CenterY) -le 42
    $above = $label.Bottom -le ($target.Y + 12) -and
      ($target.Y - $label.Bottom) -le 90 -and
      $label.Right -ge $target.X -and $label.X -le $target.Right
    if ($leftAligned -or $above) {
      $nearby.Add([string]$candidate.name)
    }
  }
  return ($nearby -join ' ')
}

function Get-CalibrationDefinitions {
  return @(
    [pscustomobject]@{ Name = 'requestsSection'; Types = @('ControlType.Button', 'ControlType.TabItem', 'ControlType.Hyperlink'); Pattern = '(заявк|обращен|расписан|request|ticket|calendar)' },
    [pscustomobject]@{ Name = 'newAppointmentButton'; Types = @('ControlType.Button', 'ControlType.MenuItem', 'ControlType.Hyperlink'); Pattern = '(нов(ый|ая).*(прием|запис)|записать.*(прием|пациент)|сохранить.*запис|new.*appointment)' },
    [pscustomobject]@{ Name = 'patientPhoneInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox'); Pattern = '(телефон|мобильн|phone|mobile)' },
    [pscustomobject]@{ Name = 'patientNameInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox'); Pattern = '(фио|фамили|пациент|patient|surname|fullname|full.?name)' },
    [pscustomobject]@{ Name = 'doctorInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox', 'ControlType.ListItem'); Pattern = '(врач|доктор|специалист|doctor|physician)' },
    [pscustomobject]@{ Name = 'startTimeInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox', 'ControlType.Custom'); Pattern = '(дата.*врем|время.*прием|начал|plan.?start|start.?time|appointment.?time)' },
    [pscustomobject]@{ Name = 'commentInput'; Types = @('ControlType.Edit', 'ControlType.Document'); Pattern = '(комментар|примечан|пожелан|comment|note)' },
    [pscustomobject]@{ Name = 'saveButton'; Types = @('ControlType.Button'); Pattern = '(^|\s)(записать пациента|сохранить|создать прием|готово|save|create appointment|ok)(\s|$)' }
  )
}

function Get-CalibrationSelector {
  param(
    [string]$Name,
    [object[]]$Rows,
    [hashtable]$UsedPaths
  )

  $definition = @(Get-CalibrationDefinitions | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
  if ($definition.Count -eq 0) {
    return [pscustomobject]@{ Ok = $false; Name = $Name; Reason = 'Неизвестная роль элемента.' }
  }
  $definition = $definition[0]
  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($row in $Rows) {
    $rowKey = ([string]$row.rootName) + "`n" + ([string]$row.path)
    if ([string]$row.controlType -notin @($definition.Types) -or $UsedPaths.ContainsKey($rowKey)) {
      continue
    }
    $ownText = (([string]$row.name) + ' ' + ([string]$row.automationId) + ' ' + ([string]$row.className)).ToLowerInvariant().Replace('ё', 'е')
    $nearbyText = (Get-NearbyControlText -Row $row -Rows $Rows).ToLowerInvariant().Replace('ё', 'е')
    $score = 0
    if ($ownText -match [string]$definition.Pattern) { $score += 140 }
    if ($nearbyText -match [string]$definition.Pattern) { $score += 100 }
    if (-not [string]::IsNullOrWhiteSpace([string]$row.automationId)) { $score += 15 }
    if (-not [string]::IsNullOrWhiteSpace([string]$row.name)) { $score += 5 }
    if ($score -gt 0) {
      $candidates.Add([pscustomobject]@{ Row = $row; Score = $score; Nearby = $nearbyText })
    }
  }
  $ordered = @($candidates | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = { [string]$_.Row.path }; Descending = $false })
  if ($ordered.Count -eq 0 -or [int]$ordered[0].Score -lt 100) {
    return [pscustomobject]@{ Ok = $false; Name = $Name; Reason = 'Подходящий элемент не найден.' }
  }
  if ($ordered.Count -gt 1 -and ([int]$ordered[0].Score - [int]$ordered[1].Score) -lt 20) {
    return [pscustomobject]@{ Ok = $false; Name = $Name; Reason = 'Найдено несколько равнозначных элементов.' }
  }
  $row = $ordered[0].Row
  $rootPattern = if ([string]$row.rootName -match '(Новый прием|Запись на прием|Добавление комментария|Обработка заявки)') {
    [Regex]::Escape([string]$Matches[1])
  } else {
    '^' + [Regex]::Escape([string]$row.rootName) + '$'
  }
  $selector = [ordered]@{
    name = [string]$row.name
    automationId = [string]$row.automationId
    className = [string]$row.className
    controlType = [string]$row.controlType
    rootTitleRegex = $rootPattern
    path = [string]$row.path
  }
  return [pscustomobject]@{
    Ok = $true
    Name = $Name
    Score = [int]$ordered[0].Score
    PathKey = ([string]$row.rootName) + "`n" + ([string]$row.path)
    Selector = [pscustomobject]$selector
  }
}

function Invoke-AutomaticCalibration {
  param(
    [object]$WindowInfo,
    [object]$Config,
    [string]$ConfigFile,
    [string]$OutputReportPath
  )

  $roots = @(Get-IdentAutomationRoots $WindowInfo)
  $maxDepth = [Math]::Max(8, [Math]::Min(16, [int](Get-ObjectProperty $Config.inspect 'maxDepth' 12)))
  $rows = @(Get-UiTreeRows -Roots $roots -MaxDepth $maxDepth)
  $visibleControls = @($rows | Where-Object { $null -ne (Convert-BoundsText ([string]$_.bounds)) })
  $required = New-Object System.Collections.Generic.List[string]
  foreach ($step in @($Config.workflow.steps)) {
    $selectorName = [string](Get-ObjectProperty $step 'selector' '')
    if ($selectorName -and -not $required.Contains($selectorName)) { $required.Add($selectorName) }
  }
  $successCondition = Get-ObjectProperty $Config.workflow 'successCondition' $null
  $successSelectorName = [string](Get-ObjectProperty $successCondition 'selector' '')
  if ($successSelectorName -and -not $required.Contains($successSelectorName)) { $required.Add($successSelectorName) }

  $usedPaths = @{}
  $resolved = [ordered]@{}
  $checks = New-Object System.Collections.Generic.List[object]
  foreach ($name in $required) {
    $candidate = Get-CalibrationSelector -Name $name -Rows $rows -UsedPaths $usedPaths
    $checks.Add($candidate)
    if ([bool]$candidate.Ok) {
      $resolved[$name] = $candidate.Selector
      $usedPaths[[string]$candidate.PathKey] = $true
    }
  }
  $issues = @($checks | Where-Object { -not [bool]$_.Ok } | ForEach-Object { "$($_.Name): $($_.Reason)" })
  if ($visibleControls.Count -lt 8) {
    $issues += 'Окно IDENT свернуто или элементы формы недоступны. Разверните IDENT и откройте окно новой записи.'
  }
  $report = [ordered]@{
    ok = ($issues.Count -eq 0)
    generatedAt = (Get-Date).ToString('o')
    mode = 'automatic'
    processName = [string]$WindowInfo.process.ProcessName
    windowTitle = [string]$WindowInfo.process.MainWindowTitle
    controlsScanned = $rows.Count
    visibleControls = $visibleControls.Count
    requiredSelectors = @($required)
    checks = @($checks | ForEach-Object {
      [ordered]@{
        name = [string]$_.Name
        ok = [bool]$_.Ok
        score = [int](Get-ObjectProperty $_ 'Score' 0)
        reason = [string](Get-ObjectProperty $_ 'Reason' '')
      }
    })
    issues = @($issues)
  }

  if ($issues.Count -eq 0) {
    foreach ($name in $resolved.Keys) {
      if ($Config.selectors.PSObject.Properties.Name -contains $name) {
        $Config.selectors.$name = $resolved[$name]
      } else {
        $Config.selectors | Add-Member -NotePropertyName $name -NotePropertyValue $resolved[$name]
      }
    }
    $calibration = [pscustomobject]@{
      status = 'verified'
      profileVersion = 1
      calibratedAt = (Get-Date).ToString('o')
      processName = [string]$WindowInfo.process.ProcessName
      windowTitle = [string]$WindowInfo.process.MainWindowTitle
      selectorCount = $resolved.Count
      reportPath = $OutputReportPath
    }
    if ($Config.PSObject.Properties.Name -contains 'calibration') {
      $Config.calibration = $calibration
    } else {
      $Config | Add-Member -NotePropertyName calibration -NotePropertyValue $calibration
    }
    $Config.workflow.allowUnsafeExecution = $true
    $Config.workflow.confirmBeforeEachStep = $false
    Write-JsonFileAtomic -Path $ConfigFile -Value $Config
  }
  Write-JsonFileAtomic -Path $OutputReportPath -Value ([pscustomobject]$report)
  return [pscustomobject]$report
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
  $stableSince = $null
  do {
    $present = [bool](Find-RobotElementInIdent $WindowInfo $selector)
    $matched = (
      ($conditionType -eq 'elementPresent' -and $present) -or
      ($conditionType -eq 'elementMissing' -and -not $present)
    )
    if ($matched) {
      if ($null -eq $stableSince) {
        $stableSince = Get-Date
      }
      if (((Get-Date) - $stableSince).TotalMilliseconds -ge 1000) {
        return
      }
    } else {
      $stableSince = $null
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
  $script:CurrentTaskId = [string]$Task.id
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
  $calibration = Get-ObjectProperty $Config 'calibration' $null
  if ($null -eq $calibration -or [string](Get-ObjectProperty $calibration 'status' '') -ne 'verified') {
    throw 'Robot calibration profile is not verified.'
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

    $isSaveStep = ([string]$step.selector -eq 'saveButton' -or [string]$step.name -eq 'save')
    if ($isSaveStep) {
      $script:SaveInvoked = $true
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

    if ($isSaveStep) {
      $saveInvoked = $true
    }

    $delayMs = if ($Config.workflow.stepDelayMs) { [int]$Config.workflow.stepDelayMs } else { 500 }
    Start-Sleep -Milliseconds $delayMs
    Write-RobotLog $Config 'info' "Executed step '$($step.name)'" @{ action = $step.action; selector = $step.selector }
  }

  Wait-WorkflowSuccess $WindowInfo $Config
  if (-not [string]::IsNullOrWhiteSpace($SuccessMarkerPath)) {
    Write-JsonFileAtomic -Path $SuccessMarkerPath -Value ([pscustomobject]@{
      id = [string]$Task.id
      fingerprint = [string](Get-ObjectProperty $Task 'fingerprint' '')
      completedAt = (Get-Date).ToString('o')
      verifiedBy = 'ident-ui-success-condition'
    })
  }
  Write-RobotLog $Config 'info' 'IDENT save operation verified' @{ id = $Task.id }
}

$robotMutex = New-Object Threading.Mutex($false, 'Local\Code9IdentRobotExecution')
$ownsRobotMutex = $false
$config = $null
$windowInfo = $null
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

  if ($Mode -eq 'SelfTest') {
    $definitions = @(Get-CalibrationDefinitions)
    if ($definitions.Count -ne 8 -or @($definitions | Select-Object -ExpandProperty Name -Unique).Count -ne 8) {
      throw 'Robot self-test failed: calibration definitions are invalid.'
    }
    $sampleRows = @(
      [pscustomobject]@{ path = '0/0'; rootName = 'Новый прием'; name = 'Телефон'; automationId = ''; className = 'TextBlock'; controlType = 'ControlType.Text'; bounds = '10,10,100,24' },
      [pscustomobject]@{ path = '0/1'; rootName = 'Новый прием'; name = ''; automationId = 'PhoneInput'; className = 'TextBox'; controlType = 'ControlType.Edit'; bounds = '120,10,220,24' },
      [pscustomobject]@{ path = '0/2'; rootName = 'Новый прием'; name = 'Записать пациента'; automationId = 'SaveButton'; className = 'Button'; controlType = 'ControlType.Button'; bounds = '120,60,180,32' }
    )
    $usedPaths = @{}
    $phoneSelector = Get-CalibrationSelector -Name 'patientPhoneInput' -Rows $sampleRows -UsedPaths $usedPaths
    $saveSelector = Get-CalibrationSelector -Name 'saveButton' -Rows $sampleRows -UsedPaths $usedPaths
    if (-not [bool]$phoneSelector.Ok -or -not [bool]$saveSelector.Ok) {
      throw 'Robot self-test failed: selector inference is invalid.'
    }
    Write-Host 'IDENT ROBOT SELF-TEST OK'
    return
  }

  $config = Read-JsonFile $ConfigPath
  $windowInfo = Get-IdentWindow $config

if ($Mode -eq 'Inspect') {
  if (-not $windowInfo) {
    throw 'IDENT window was not found. Check ident.processName and ident.windowTitleRegex in config.'
  }
  $outputPath = if ($config.inspect.outputPath) { $config.inspect.outputPath } else { Join-Path $PSScriptRoot 'ui-tree.json' }
  $maxDepth = if ($config.inspect.maxDepth) { [int]$config.inspect.maxDepth } else { 6 }
  $rows = @(Export-UiTree (Get-IdentAutomationRoots $windowInfo) $maxDepth $outputPath)
  Write-RobotLog $config 'info' 'UI tree exported' @{
    outputPath = $outputPath
    controls = $rows.Count
    processName = $windowInfo.process.ProcessName
    title = $windowInfo.process.MainWindowTitle
  }
  return
}

if ($Mode -eq 'Calibrate') {
  if (-not $windowInfo) {
    throw 'IDENT не найден. Откройте IDENT и окно новой записи, затем повторите настройку.'
  }
  $resolvedReportPath = if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath
  } elseif ($null -ne (Get-ObjectProperty $config 'calibration' $null) -and
      -not [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $config.calibration 'reportPath' ''))) {
    [string]$config.calibration.reportPath
  } else {
    Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))) 'calibration-report.json'
  }
  $report = Invoke-AutomaticCalibration `
    -WindowInfo $windowInfo `
    -Config $config `
    -ConfigFile $ConfigPath `
    -OutputReportPath $resolvedReportPath
  if (-not [bool]$report.ok) {
    $screenshot = Save-FailureScreenshot -Config $config -WindowInfo $windowInfo -Prefix 'calibration'
    Write-RobotLog $config 'warn' 'Automatic calibration was not accepted' @{
      reportPath = $resolvedReportPath
      screenshotPath = $screenshot
      issues = @($report.issues)
    }
    Write-Host 'ROBOT_CALIBRATION_INCOMPLETE'
    throw (@($report.issues) -join ' ')
  }
  Write-RobotLog $config 'info' 'Automatic calibration completed' @{
    reportPath = $resolvedReportPath
    selectors = @($report.requiredSelectors).Count
  }
  Write-Host 'ROBOT_CALIBRATION_OK'
  return
}

if ($Mode -eq 'Verify') {
  if (-not $windowInfo) {
    throw 'IDENT window was not found.'
  }
  $selectors = Test-WorkflowSelectors $windowInfo $config
  $missing = @($selectors.GetEnumerator() | Where-Object { -not [bool]$_.Value } | ForEach-Object { [string]$_.Key })
  $verificationReport = [ordered]@{
    ok = ($missing.Count -eq 0)
    generatedAt = (Get-Date).ToString('o')
    selectors = $selectors
    missing = $missing
  }
  if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
    Write-JsonFileAtomic -Path $ReportPath -Value ([pscustomobject]$verificationReport)
  }
  if ($missing.Count -gt 0) {
    throw ('Robot selector verification failed: ' + ($missing -join ', '))
  }
  Write-Host 'ROBOT_VERIFICATION_OK'
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
  Write-Host 'ROBOT_DEFER_IDENT_UNAVAILABLE'
  throw 'ROBOT_DEFER_IDENT_UNAVAILABLE'
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
catch {
  if ($null -ne $config) {
    $screenshot = Save-FailureScreenshot -Config $config -WindowInfo $windowInfo -Prefix $(if ($script:SaveInvoked) { 'ambiguous-after-save' } else { 'robot-error' })
    Write-RobotLog $config 'error' $_.Exception.Message @{
      taskId = $script:CurrentTaskId
      saveInvoked = $script:SaveInvoked
      screenshotPath = $screenshot
    }
  }
  if ($script:SaveInvoked) {
    Write-Host 'ROBOT_AMBIGUOUS_AFTER_SAVE'
  }
  throw
}
finally {
  if ($ownsRobotMutex) {
    $robotMutex.ReleaseMutex()
  }
  $robotMutex.Dispose()
}
