param(
  [ValidateSet('Inspect', 'Observe', 'Calibrate', 'Verify', 'DryRun', 'RunOnce', 'Loop', 'SelfTest', 'PatientFillCheck')]
  [string]$Mode = 'DryRun',

  [string]$ConfigPath = '',

  [string]$TaskFile = '',

  [int]$MaxTasks = 1,

  [int]$MinUserIdleSeconds = 0,

  [string]$ReportPath = '',

  [string]$CaptureId = '',

  [long]$ObservedWindowHandle = 0,

  [int]$ObservedProcessId = 0,

  [ValidateSet('window','menu')]
  [string]$ObservedSurface = 'window',

  [ValidateRange(0, 15)]
  [int]$StartDelaySeconds = 0,

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

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    public static long ForegroundHandle() { return GetForegroundWindow().ToInt64(); }
    public static uint LastInputTick() {
      var input = new LASTINPUTINFO();
      input.cbSize = (uint)Marshal.SizeOf(input);
      if (!GetLastInputInfo(ref input)) throw new InvalidOperationException("FILL_USER_ACTIVE");
      return input.dwTime;
    }
    public static int ForegroundProcessId() {
      uint processId;
      GetWindowThreadProcessId(GetForegroundWindow(), out processId);
      return (int)processId;
    }

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

. (Join-Path $PSScriptRoot 'RobotSafety.ps1')
. (Join-Path $PSScriptRoot 'IdentPatientForm.ps1')

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
    ConvertTo-Json -InputObject $Value -Depth $Depth | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
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
    if ($null -eq $WindowInfo -or $null -eq $WindowInfo.element -or
        $WindowInfo.element.Current.IsOffscreen -or
        [Code9IdentRobot.NativeInput]::ForegroundProcessId() -ne [int]$WindowInfo.process.Id) {
      return ''
    }
    $logDir = if ($Config.logDir) { [string]$Config.logDir } else { Join-Path $PSScriptRoot 'logs' }
    $directory = Join-Path $logDir 'screenshots'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $bounds = $WindowInfo.element.Current.BoundingRectangle
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
    $_.Id -ne $PID -and $_.MainWindowTitle -notmatch 'Code9 IDENT|PowerShell|Windows Terminal' -and
    ((-not $processName) -or $_.ProcessName -eq $processName) -and
    ((-not $titleRegex) -or $_.MainWindowTitle -match $titleRegex)
  }

  if (-not $candidates) {
    return $null
  }

  if (@($candidates).Count -ne 1) { throw 'Several IDENT windows match. Close the extra IDENT instance before calibration.' }
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
    [int]$MaxDepth,
    [int]$ExpectedProcessId = 0
  )

  $rows = New-Object System.Collections.Generic.List[object]
  $scanStarted = [Diagnostics.Stopwatch]::StartNew()

  function Walk {
    param(
      [System.Windows.Automation.AutomationElement]$Element,
      [int]$Depth,
      [string]$Path,
      [string]$RootName
    )

    if ($scanStarted.Elapsed.TotalSeconds -gt 40 -or $rows.Count -ge 5000) {
      throw 'IDENT scan limit reached. Open only the required IDENT screen and retry.'
    }
    if ($Depth -gt $MaxDepth) {
      return
    }

    $current = $Element.Current
    if ($ExpectedProcessId -gt 0 -and $current.ProcessId -ne $ExpectedProcessId) {
      throw 'Observed UI contains an element from another process.'
    }
    $rows.Add([ordered]@{
      depth = $Depth
      path = $Path
      rootName = $RootName
      name = $current.Name
      automationId = $current.AutomationId
      className = $current.ClassName
      controlType = $current.ControlType.ProgrammaticName
      isEnabled = $current.IsEnabled
      isOffscreen = $current.IsOffscreen
      patterns = @($Element.GetSupportedPatterns() | ForEach-Object { $_.ProgrammaticName })
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
  # PowerShell's array wrapper can fail on List[object]; materialize explicitly.
  return $rows.ToArray()
}

function Export-UiTree {
  param(
    [object[]]$Roots,
    [int]$MaxDepth,
    [string]$OutputPath
  )

  $rows = @(Get-UiTreeRows -Roots $Roots -MaxDepth $MaxDepth)
  New-Item -ItemType Directory -Path (Split-Path -Parent $OutputPath) -Force | Out-Null
  ConvertTo-Json -InputObject @($rows) -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
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
  if ([string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Selector 'automationId' '')) -and
      [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $Selector 'name' ''))) {
    throw 'IDENT selector needs a stable name or AutomationId, not just a position or control type.'
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

  $matches = $Root.FindAll([System.Windows.Automation.TreeScope]::Subtree, $condition)
  if ($matches.Count -gt 1) { throw 'Ambiguous IDENT selector; execution stopped before choosing an element.' }
  if ($matches.Count -eq 1) { return $matches.Item(0) }
  return $null
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
  return $roots.ToArray()
}

function Find-RobotElementInIdent {
  param(
    [object]$WindowInfo,
    [object]$Selector
  )

  $found = $null
  foreach ($root in @(Get-IdentAutomationRoots $WindowInfo)) {
    try {
      $rootRegex = [string](Get-ObjectProperty $Selector 'rootTitleRegex' '')
      if ($rootRegex -and [string]$root.Current.Name -notmatch $rootRegex) {
        continue
      }
      $path = [string](Get-ObjectProperty $Selector 'path' '')
      $element = Find-RobotElement $root $Selector
      if ($path) {
        $pathElement = Resolve-ElementPath -Root $root -Path $path
        # A moved anonymous control must never fall back to the first TextBox/Button.
        if ($null -eq $element -or $null -eq $pathElement -or -not [System.Windows.Automation.AutomationElement]::Compare($element, $pathElement)) {
          continue
        }
      }
      if ($element) {
        if ($null -ne $found) { throw 'Selector matches more than one IDENT window.' }
        $found = $element
      }
    }
    catch [System.Windows.Automation.ElementNotAvailableException] {
    }
  }
  return $found
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
    [pscustomobject]@{ Name = 'newAppointmentButton'; Types = @('ControlType.Button', 'ControlType.MenuItem', 'ControlType.Hyperlink'); Pattern = '(нов(ый|ая).*(прием|запис)|записать\s+на\s+прием|new.*appointment)' },
    [pscustomobject]@{ Name = 'patientPhoneInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox'); Pattern = '(телефон|мобильн|phone|mobile)' },
    [pscustomobject]@{ Name = 'patientNameInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox'); Pattern = '(фио|фамилия\s+имя\s+отчество|fullname|full.?name)' },
    [pscustomobject]@{ Name = 'patientLastNameInput'; Types = @('ControlType.Edit'); Pattern = '(^|\W)(фамилия|surname|last.?name)(\W|$)'; AutomationIds = @('_surnameTextBox') },
    [pscustomobject]@{ Name = 'patientFirstNameInput'; Types = @('ControlType.Edit'); Pattern = '(^|\W)(имя|given.?name|first.?name)(\W|$)' },
    [pscustomobject]@{ Name = 'patientMiddleNameInput'; Types = @('ControlType.Edit'); Pattern = '(отчество|patronymic|middle.?name)' },
    [pscustomobject]@{ Name = 'patientBirthDateInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox'); Pattern = '(дата.?рожд|день.?рожд|birth.?date|birth.?day|date.?of.?birth)' },
    [pscustomobject]@{ Name = 'doctorInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox', 'ControlType.ListItem'); Pattern = '(врач|доктор|специалист|doctor|physician)' },
    [pscustomobject]@{ Name = 'startTimeInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox', 'ControlType.Custom'); Pattern = '(дата.*врем|время.*прием|начал|plan.?start|start.?time|appointment.?time)' },
    [pscustomobject]@{ Name = 'endTimeInput'; Types = @('ControlType.Edit', 'ControlType.ComboBox', 'ControlType.Custom'); Pattern = '(конец|окончан|plan.?end|end.?time)' },
    [pscustomobject]@{ Name = 'commentInput'; Types = @('ControlType.Edit', 'ControlType.Document'); Pattern = '(комментар|примечан|пожелан|comment|note)' },
    [pscustomobject]@{ Name = 'saveButton'; Types = @('ControlType.Button'); Pattern = '(^|\s)(записать пациента|сохранить|создать прием|готово|save|create appointment|ok)(\s|$)' },
    [pscustomobject]@{ Name = 'bookingConfirmed'; Types = @('ControlType.Text'); Pattern = '(запись успешно создана|прием успешно создан|appointment successfully created)' }
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
    if ([string]$row.controlType -notin @($definition.Types) -or $UsedPaths.ContainsKey($rowKey) -or
        -not [bool](Get-ObjectProperty $row 'isEnabled' $true) -or [bool](Get-ObjectProperty $row 'isOffscreen' $false) -or
        $null -eq (Convert-BoundsText ([string]$row.bounds))) {
      continue
    }
    $ownText = (([string]$row.name) + ' ' + ([string]$row.automationId) + ' ' + ([string]$row.className)).ToLowerInvariant().Replace('ё', 'е')
    $nearbyText = (Get-NearbyControlText -Row $row -Rows $Rows).ToLowerInvariant().Replace('ё', 'е')
    $score = 0
    $knownId = [string]$row.automationId -in @(Get-ObjectProperty $definition 'AutomationIds' @())
    if ($ownText -match [string]$definition.Pattern -or $knownId) { $score += 140 }
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
  if ([string]::IsNullOrWhiteSpace([string]$row.name) -and [string]::IsNullOrWhiteSpace([string]$row.automationId)) {
    return [pscustomobject]@{ Ok = $false; Name = $Name; Reason = 'У элемента нет надежного имени или AutomationId. Один путь по индексам небезопасен.' }
  }
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

function Select-CalibrationRoots {
  param([object[]]$Roots)
  # A large calendar must not consume the scan budget before an open dialog.
  $dialogs = @($Roots | Where-Object {
    -not $_.Current.IsOffscreen -and $_.Current.Name -match '^\s*(Новый при[её]м|New appointment)(\s|$|-)'
  })
  if ($dialogs.Count -gt 0) { return $dialogs }
  return $Roots
}

function Test-ObservedWindowVisible {
  param([long]$WindowHandle)
  if (-not ('IdentObservationWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class IdentObservationWindow {
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
}
'@
  }
  $handle = [IntPtr]::new($WindowHandle)
  return [IdentObservationWindow]::IsWindowVisible($handle) -and -not [IdentObservationWindow]::IsIconic($handle)
}

function Get-ObservedElement {
  param([long]$WindowHandle)
  if (-not (Test-ObservedWindowVisible $WindowHandle)) { throw 'Observed IDENT window is closed or hidden.' }
  return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new($WindowHandle))
}

function Assert-ObservedElement {
  param([object]$Element, [long]$WindowHandle, [int]$ProcessId, [string]$RuntimeId = '')
  if ($null -eq $Element -or $Element.Current.ProcessId -ne $ProcessId -or
      $Element.Current.NativeWindowHandle -ne $WindowHandle -or $Element.Current.IsOffscreen -or
      $null -eq (Convert-BoundsText (Format-Bounds $Element.Current.BoundingRectangle))) {
    throw 'Observed IDENT window is closed, hidden or changed. Repeat the capture on the required screen.'
  }
  $identity = $Element.GetRuntimeId() -join ','
  if (-not $identity -or ($RuntimeId -and $identity -cne $RuntimeId)) {
    throw 'Observed IDENT window changed during capture. Repeat the capture.'
  }
  return $identity
}

function Get-ObservedPointerElement {
  # Only the operator's pointer, never an enumeration of the desktop.
  $point = [System.Windows.Forms.Cursor]::Position
  return [System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new($point.X, $point.Y))
}

function Get-ObservedParent {
  param([object]$Element)
  return [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($Element)
}

function Get-ObservedMenuContext {
  param([int]$ProcessId)
  $node = Get-ObservedPointerElement
  $menu = $null
  for ($depth = 0; $depth -lt 24 -and $null -ne $node; $depth++) {
    if ($node.Current.ProcessId -ne $ProcessId) { break }
    if ($node.Current.ControlType.ProgrammaticName -eq 'ControlType.Menu') { $menu = $node }
    $handle = [long]$node.Current.NativeWindowHandle
    if ($null -ne $menu -and $handle -ne 0) {
      $container = Get-ObservedElement $handle
      $identity = Assert-ObservedElement $container $handle $ProcessId
      $context = [pscustomobject]@{
        Element = $menu; Handle = $handle; ContainerIdentity = $identity
        MenuIdentity = ($menu.GetRuntimeId() -join ',')
      }
      Assert-ObservedMenuContext $context $ProcessId
      return $context
    }
    $node = Get-ObservedParent $node
  }
  throw 'IDENT menu was not found under the pointer. Keep the menu open and point at a menu item without clicking.'
}

function Assert-ObservedMenuContext {
  param([object]$Context, [int]$ProcessId)
  $menu = $Context.Element
  if ($null -eq $menu -or $menu.Current.ProcessId -ne $ProcessId -or
      $menu.Current.ControlType.ProgrammaticName -ne 'ControlType.Menu' -or $menu.Current.IsOffscreen -or
      $null -eq (Convert-BoundsText (Format-Bounds $menu.Current.BoundingRectangle)) -or
      -not $Context.MenuIdentity -or ($menu.GetRuntimeId() -join ',') -cne $Context.MenuIdentity) {
    throw 'Observed IDENT menu closed or changed. No menu capture was saved.'
  }
  [void](Assert-ObservedElement (Get-ObservedElement $Context.Handle) $Context.Handle $ProcessId $Context.ContainerIdentity)
}

function Invoke-ObservedCapture {
  param([object]$WindowInfo, [long]$WindowHandle, [int]$ProcessId, [string]$OutputReportPath, [string]$ScanId,
    [ValidateSet('window','menu')][string]$Surface = 'window')
  if ($WindowHandle -eq 0 -or $ProcessId -le 0 -or $null -eq $WindowInfo -or
      $WindowInfo.process.Id -ne $ProcessId -or [string]::IsNullOrWhiteSpace($ScanId)) {
    throw 'Observation must target the IDENT window selected for this attempt.'
  }
  $element = Get-ObservedElement $WindowHandle
  $identity = Assert-ObservedElement $element $WindowHandle $ProcessId
  $menu = $null
  $captureRoot = $element
  if ($Surface -eq 'menu') {
    $menu = Get-ObservedMenuContext $ProcessId
    $captureRoot = $menu.Element
  }
  $rows = @(Get-UiTreeRows -Roots @($captureRoot) -MaxDepth 28 -ExpectedProcessId $ProcessId)
  # Never fall back to the calendar when the demonstrated dialog has closed.
  [void](Assert-ObservedElement $element $WindowHandle $ProcessId $identity)
  [void](Assert-ObservedElement (Get-ObservedElement $WindowHandle) $WindowHandle $ProcessId $identity)
  $menuItems = 0
  if ($Surface -eq 'menu') {
    Assert-ObservedMenuContext $menu $ProcessId
    $currentMenu = Get-ObservedMenuContext $ProcessId
    if ($currentMenu.MenuIdentity -cne $menu.MenuIdentity -or $currentMenu.Handle -ne $menu.Handle) {
      throw 'Pointer or IDENT menu changed during capture.'
    }
    $menuItems = @($rows | Where-Object { $_.controlType -eq 'ControlType.MenuItem' -and -not $_.isOffscreen }).Count
    if ($menuItems -eq 0) { throw 'No visible menu items were captured. The calendar is not a menu capture.' }
  }
  $visible = @($rows | Where-Object {
    -not [bool]$_.isOffscreen -and $null -ne (Convert-BoundsText ([string]$_.bounds))
  })
  if ($visible.Count -eq 0) { throw 'No visible controls were captured. Repeat the capture.' }
  $directory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputReportPath))
  $path = Join-Path $directory ('ui-tree-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
  Write-JsonFileAtomic -Path $path -Value @($rows)
  $report = [ordered]@{
    ok = $true; mode = 'observation'; captureId = $ScanId; scanSchemaVersion = 2
    generatedAt = (Get-Date).ToString('o'); capturePath = $path
    captureSha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    captureBytes = (Get-Item -LiteralPath $path).Length
    controlsScanned = $rows.Count; visibleControls = $visible.Count
    observedWindowHandle = $WindowHandle; observedProcessId = $ProcessId
    observedSurface = $Surface; menuItemsScanned = $menuItems
    splitNameFieldsDetected = $false; selectorsComplete = $false
    readyForUnattendedExecution = $false; checks = @(); issues = @()
  }
  Write-JsonFileAtomic -Path $OutputReportPath -Value ([pscustomobject]$report)
  return [pscustomobject]$report
}

function Invoke-AutomaticCalibration {
  param(
    [object]$WindowInfo,
    [object]$Config,
    [string]$ConfigFile,
    [string]$OutputReportPath,
    [string]$ScanId = ([guid]::NewGuid().ToString('N'))
  )

  $roots = @(Select-CalibrationRoots -Roots @(Get-IdentAutomationRoots $WindowInfo))
  $maxDepth = [Math]::Max(20, [Math]::Min(28, [int](Get-ObjectProperty $Config.inspect 'maxDepth' 24)))
  $rows = @(Get-UiTreeRows -Roots $roots -MaxDepth $maxDepth)
  $outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputReportPath))
  $capturePath = Join-Path $outputDirectory ('ui-tree-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
  Write-JsonFileAtomic -Path $capturePath -Value @($rows)
  $visibleControls = @($rows | Where-Object {
    -not [bool]$_.isOffscreen -and $null -ne (Convert-BoundsText ([string]$_.bounds))
  })
  $nameParts = @('patientLastNameInput', 'patientFirstNameInput', 'patientMiddleNameInput' | ForEach-Object {
    Get-CalibrationSelector -Name $_ -Rows $rows -UsedPaths @{}
  })
  $patientForm = Get-IdentPatientFormBindings -Rows $rows
  $splitNameFieldsDetected = $patientForm.Ok -or @($nameParts | Where-Object Ok).Count -ge 2
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
  if ($splitNameFieldsDetected -and $required.Contains('patientNameInput')) {
    $issues += 'В IDENT раздельные поля ФИО. Нужен отдельный профиль; полное ФИО нельзя вводить в поле фамилии.'
    $resolved.Remove('patientNameInput')
  }
  foreach ($step in @($Config.workflow.steps)) {
    $name = [string]$step.selector
    $candidate = @($checks | Where-Object { $_.Name -eq $name -and $_.Ok })
    if ($candidate.Count -eq 0) { continue }
    $row = @($rows | Where-Object { (([string]$_.rootName) + "`n" + ([string]$_.path)) -eq $candidate[0].PathKey })[0]
    $requiredPattern = if ([string]$step.action -eq 'setText') { 'ValuePatternIdentifiers.Pattern' } else { 'InvokePatternIdentifiers.Pattern' }
    if (@($row.patterns) -notcontains $requiredPattern) { $issues += "$name : IDENT does not expose $requiredPattern." }
  }
  if ($visibleControls.Count -lt 8) {
    $issues += 'Окно IDENT свернуто или элементы формы недоступны. Разверните IDENT и откройте окно новой записи.'
  }
  $report = [ordered]@{
    ok = ($visibleControls.Count -ge 8)
    selectorsComplete = ($issues.Count -eq 0)
    generatedAt = (Get-Date).ToString('o')
    mode = 'automatic'
    captureId = $ScanId
    scanSchemaVersion = 2
    capturePath = $capturePath
    captureSha256 = (Get-FileHash -LiteralPath $capturePath -Algorithm SHA256).Hash
    captureBytes = (Get-Item -LiteralPath $capturePath).Length
    splitNameFieldsDetected = $splitNameFieldsDetected
    patientNameFields = @($nameParts | Where-Object Ok)
    patientFormBindings = $patientForm
    readyForUnattendedExecution = $false
    processName = [string]$WindowInfo.process.ProcessName
    windowTitle = [string]$WindowInfo.process.MainWindowTitle
    controlsScanned = $rows.Count
    visibleControls = $visibleControls.Count
    requiredSelectors = $required.ToArray()
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

  if ($visibleControls.Count -ge 8) {
    # Screen capture is evidence for calibration, never proof of a working workflow.
    Write-JsonFileAtomic -Path (Join-Path $outputDirectory 'patient-form-candidate.json') -Value $patientForm
    $candidatePath = Join-Path $outputDirectory 'calibration-candidate.json'
    foreach ($name in $required) {
      $replacement = if ($resolved.Contains($name)) { $resolved[$name] } else {
        [pscustomobject]@{ name = ''; automationId = ''; className = ''; controlType = '' }
      }
      if ($Config.selectors.PSObject.Properties.Name -contains $name) {
        $Config.selectors.$name = $replacement
      } else {
        $Config.selectors | Add-Member -NotePropertyName $name -NotePropertyValue $replacement
      }
    }
    $calibration = [pscustomobject]@{
      status = 'selectors_detected'
      profileVersion = 2
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
    $Config.workflow.allowUnsafeExecution = $false
    $Config.workflow.confirmBeforeEachStep = $false
    Write-JsonFileAtomic -Path $candidatePath -Value $Config
    if ($splitNameFieldsDetected) {
      $splitCandidate = New-SplitNameCandidate -Config $Config -NameParts $nameParts
      Write-JsonFileAtomic -Path (Join-Path $outputDirectory 'calibration-split-candidate.json') -Value $splitCandidate
    }
  }
  Write-JsonFileAtomic -Path $OutputReportPath -Value ([pscustomobject]$report)
  return [pscustomobject]$report
}

function Invoke-Click {
  param([System.Windows.Automation.AutomationElement]$Element)

  Assert-ElementUsable $Element
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

  Assert-ElementUsable $Element
  $pattern = $null
  if ($Element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
    if ($pattern.Current.IsReadOnly) { throw 'IDENT field is read-only.' }
    $pattern.SetValue($Value)
    if ([string]$pattern.Current.Value -cne $Value) { throw 'IDENT field did not retain the requested value; save cancelled.' }
    return
  }

  throw 'Element does not support ValuePattern; add a safer selector or implement a deliberate keyboard fallback.'
}

function Assert-ElementUsable {
  param([System.Windows.Automation.AutomationElement]$Element)
  if ($null -eq $Element -or -not $Element.Current.IsEnabled -or $Element.Current.IsOffscreen) {
    throw 'IDENT control is hidden or disabled; no action was performed.'
  }
}

function Assert-BookingContract {
  param([object]$Config, [object]$Task)
  $steps = @($Config.workflow.steps)
  $saves = @($steps | Where-Object { $_.selector -eq 'saveButton' -or $_.name -eq 'save' })
  if ($saves.Count -ne 1 -or $steps[-1] -ne $saves[0] -or $saves[0].action -ne 'click') {
    throw 'Exactly one save action must be the final workflow step.'
  }
  foreach ($step in $steps) {
    if ([string]$step.action -notin @('click', 'setText')) { throw 'Unsupported booking workflow action.' }
  }
  $boundSelectors = @{}
  $nameFields = @(Get-BookingNameFields $Config)
  if ($nameFields -contains 'ticket.ClientSurname' -and -not [string]::IsNullOrWhiteSpace((Resolve-TaskValue $Task 'ticket.ClientFullName'))) {
    throw 'Split-name booking requires explicit name parts, not a second full-name representation.'
  }
  foreach ($field in $nameFields + @('ticket.ClientPhone', 'ticket.DoctorName', 'ticket.PlanStart', 'ticket.PlanEnd')) {
    $fieldSteps = @($steps | Where-Object { $_.action -eq 'setText' -and (Get-ObjectProperty $_ 'valueFrom' '') -eq $field })
    if ($fieldSteps.Count -ne 1) {
      throw "Booking workflow must set and verify $field exactly once."
    }
    $binding = [string]$fieldSteps[0].selector
    if ([string]::IsNullOrWhiteSpace($binding) -or $boundSelectors.ContainsKey($binding) -or
        @($steps | Where-Object { [string]$_.selector -eq $binding }).Count -ne 1) {
      throw 'Each required booking value must use a separate field selector.'
    }
    $boundSelectors[$binding] = $true
    if ($field -eq 'ticket.ClientPatronymic') {
      # An explicit empty patronymic is valid; a missing property is not consent to guess it.
      if ($Task.ticket.PSObject.Properties.Name -notcontains 'ClientPatronymic' -or $null -eq $Task.ticket.ClientPatronymic) {
        throw 'ClientPatronymic must be provided explicitly, including an empty string if absent.'
      }
    } elseif ([string]::IsNullOrWhiteSpace((Resolve-TaskValue $Task $field))) { throw "Required booking value is missing: $field" }
    if ($field -in @('ticket.ClientSurname', 'ticket.ClientName', 'ticket.ClientPatronymic') -and
        (Resolve-TaskValue $Task $field) -match '[\r\n\t]') { throw 'Patient name fields must not contain control characters.' }
    if ([bool](Get-ObjectProperty $fieldSteps[0] 'skipIfEmpty' $false)) { throw 'Required booking fields must not use skipIfEmpty.' }
  }
  $start = [DateTimeOffset]::Parse([string]$Task.ticket.PlanStart, [Globalization.CultureInfo]::InvariantCulture)
  $end = [DateTimeOffset]::Parse([string]$Task.ticket.PlanEnd, [Globalization.CultureInfo]::InvariantCulture)
  if ($start -le [DateTimeOffset]::Now) { throw 'Appointment start is in the past. Review the ticket; no UI action was performed.' }
  $minutes = ($end - $start).TotalMinutes
  if ($minutes -le 0 -or $minutes % 15 -ne 0 -or $start.Date -ne $end.Date -or $start.Offset -ne $end.Offset) {
    throw 'Booking duration must be a positive multiple of 15 minutes within one day and timezone.'
  }
  if ($minutes -gt 360) { throw 'Booking duration must not exceed 6 hours (360 minutes).' }
  $declaredMinutes = Get-ObjectProperty $Task.ticket 'DurationMinutes' $null
  if ($null -ne $declaredMinutes -and [double]$declaredMinutes -ne $minutes) {
    throw 'DurationMinutes must match PlanStart and PlanEnd.'
  }
  $birthDate = Resolve-TaskValue $Task 'ticket.ClientBirthDate'
  if (-not [string]::IsNullOrEmpty($birthDate)) {
    $null = Convert-PatientBirthDate $birthDate
    $birthSteps = @($steps | Where-Object { $_.action -eq 'setText' -and (Get-ObjectProperty $_ 'valueFrom' '') -eq 'ticket.ClientBirthDate' })
    if ($birthSteps.Count -ne 1) { throw 'Booking workflow must set and verify ticket.ClientBirthDate exactly once. Calibrate the birth-date field first.' }
    if (@($steps | Where-Object { $_.selector -eq $birthSteps[0].selector }).Count -ne 1) {
      throw 'ClientBirthDate must use a separate patient field selector.'
    }
    $birthSelector = Get-ObjectProperty $Config.selectors ([string]$birthSteps[0].selector) $null
    if ($null -eq $birthSelector -or (
        [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $birthSelector 'name' '')) -and
        [string]::IsNullOrWhiteSpace([string](Get-ObjectProperty $birthSelector 'automationId' '')))) {
      throw 'ClientBirthDate selector is not configured. Calibrate the birth-date field first.'
    }
  }
  if ([string]$Config.workflow.successCondition.type -ne 'elementPresent') {
    throw 'A disappearing dialog is not proof of a booking. Configure a positive IDENT success indicator.'
  }
  if (@($steps | Where-Object { $_.selector -eq $Config.workflow.successCondition.selector }).Count -gt 0) {
    throw 'Success indicator must be separate from editable fields and action buttons.'
  }
}

function Convert-PatientBirthDate {
  param([string]$Value)
  $date = [datetime]::MinValue
  if (-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::None, [ref]$date) -or $date.Year -lt 1900 -or $date -gt [datetime]::UtcNow.Date) {
    throw 'ClientBirthDate must be a valid YYYY-MM-DD date from 1900-01-01 through today.'
  }
  return $date
}

function Test-SkipEmptyBirthDateStep {
  param([object]$Task, [object]$Step)
  return ($Step.action -eq 'setText' -and (Get-ObjectProperty $Step 'valueFrom' '') -eq 'ticket.ClientBirthDate' -and
    [bool](Get-ObjectProperty $Step 'skipIfEmpty' $false) -and
    [string]::IsNullOrEmpty((Resolve-TaskValue $Task 'ticket.ClientBirthDate')))
}

function Resolve-StepValue {
  param([object]$Task, [object]$Step)
  $value = Resolve-TaskValue $Task ([string]$Step.valueFrom)
  $format = [string](Get-ObjectProperty $Step 'valueFormat' '')
  if ($format) {
    if ([string]$Step.valueFrom -eq 'ticket.ClientBirthDate') {
      return (Convert-PatientBirthDate $value).ToString($format, [Globalization.CultureInfo]::InvariantCulture)
    }
    if ([string]$Step.valueFrom -notin @('ticket.PlanStart', 'ticket.PlanEnd')) { throw 'valueFormat is only supported for appointment date/time.' }
    return [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture).ToString($format, [Globalization.CultureInfo]::InvariantCulture)
  }
  return $value
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
    Assert-InteractiveDesktop
    if ($WindowInfo.process.HasExited) { throw 'IDENT exited before confirming the booking.' }
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
  Assert-BookingContract $Config $Task
  $pendingPath = Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))) 'execution-pending.json'
  if (Test-Path -LiteralPath $pendingPath) {
    throw 'ROBOT_REVIEW_REQUIRED: previous UI execution has no confirmed outcome. Check IDENT before clearing execution-pending.json.'
  }
  if ([bool](Find-RobotElementInIdent $WindowInfo $Config.selectors.($Config.workflow.successCondition.selector))) {
    throw 'Success indicator already exists before execution; cannot distinguish this booking.'
  }

  Assert-InteractiveDesktop
  Assert-UserIdle -MinimumSeconds $MinUserIdleSeconds
  $saveInvoked = $false
  $writtenValues = @{}
  foreach ($step in @($Config.workflow.steps)) {
    if (Test-SkipEmptyBirthDateStep $Task $step) { continue }
    if (-not $saveInvoked) {
      Assert-InteractiveDesktop
      Assert-UserIdle -MinimumSeconds $MinUserIdleSeconds
    }
    if ($WindowInfo.process.HasExited) { throw 'IDENT closed during the workflow. Review the pending booking before retrying.' }
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
      foreach ($name in $writtenValues.Keys) {
        $field = Find-RobotElementInIdent $WindowInfo $Config.selectors.$name
        Assert-ElementUsable $field
        $pattern = $null
        if (-not $field.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern) -or
            [string]$pattern.Current.Value -cne [string]$writtenValues[$name]) {
          throw "IDENT value changed before save: $name. Save cancelled."
        }
      }
      Assert-UserIdle -MinimumSeconds $MinUserIdleSeconds
      $script:SaveInvoked = $true
    }
    # Persist intent before touching IDENT, including before Invoke can block or crash.
    Write-JsonFileAtomic -Path $pendingPath -Value ([pscustomobject]@{
      id = [string]$Task.id
      fingerprint = [string](Get-ObjectProperty $Task 'fingerprint' '')
      stage = $(if ($isSaveStep) { 'saving' } else { 'editing' })
      updatedAt = (Get-Date).ToString('o')
    })
    switch ($step.action) {
      'click' {
        Invoke-Click $element
      }
      'setText' {
        $value = Resolve-StepValue $Task $step
        Set-ElementValue $element $value
        $writtenValues[[string]$step.selector] = $value
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
    Remove-Item -LiteralPath $pendingPath -Force
  }
  Write-RobotLog $Config 'info' 'IDENT save operation verified' @{ id = $Task.id }
}

$robotMutex = New-Object Threading.Mutex($false, 'Local\Code9IdentRobotExecution')
$ownsRobotMutex = $false
$interactionLease = $null
$config = $null
$windowInfo = $null
$fillReportPath = ''
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
  if ($Execute -and $Mode -in @('RunOnce', 'Loop')) {
    $interactionLease = Enter-RobotInteractionLease -Directory (Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath)))
    if ($null -eq $interactionLease) { Write-Host 'ROBOT_DEFER_BUSY'; exit 75 }
    if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))) 'fill-check-pending.json')) {
      throw 'FILL_REVIEW_PENDING'
    }
  }

  if ($Mode -eq 'PatientFillCheck') {
    . (Join-Path $PSScriptRoot 'IdentFillCheck.ps1')
    . (Join-Path $PSScriptRoot 'IdentFillRuntime.ps1')
    . (Join-Path $PSScriptRoot 'RobotCapture.ps1')
    $directory=Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
    # Only the bounded launcher creates this handshake after attaching the child to its job.
    if ($CaptureId -notmatch '^[a-f0-9]{32}$') { throw 'FILL_LAUNCHER_REQUIRED' }
    $runDirectory=Join-Path $directory ('fill-checks\'+$CaptureId)
    if ([IO.Path]::GetFullPath($ReportPath) -ine (Join-Path $runDirectory 'result.json')) { throw 'FILL_LAUNCHER_REQUIRED' }
    $armPath=Join-Path $runDirectory 'armed'
    $armDeadline=[datetime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $armPath) -and [datetime]::UtcNow -lt $armDeadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $armPath)) { throw 'FILL_LAUNCHER_REQUIRED' }
    $fillReportPath=$ReportPath
    $interactionLease=Enter-RobotInteractionLease -Directory $directory -Training
    if ($null -eq $interactionLease) { throw 'FILL_BUSY' }
    $fillResult=Invoke-IdentSupervisedFill $ConfigPath $TaskFile $runDirectory $CaptureId -Execute:$Execute
    Write-JsonFileAtomic $ReportPath $fillResult
    Write-Host ('IDENT_FILL_CHECK '+$fillResult.State+' '+$fillResult.ErrorCode)
    return
  }

  if ($Mode -eq 'SelfTest') {
    $definitions = @(Get-CalibrationDefinitions)
    if ($definitions.Count -ne 14 -or @($definitions | Select-Object -ExpandProperty Name -Unique).Count -ne 14) {
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

  if ($StartDelaySeconds -gt 0 -and $Mode -in @('Inspect', 'Calibrate')) {
    Start-Sleep -Seconds $StartDelaySeconds
  }
  $config = Read-JsonFile $ConfigPath
  $windowInfo = $null
  if ($Mode -eq 'Observe') {
    . (Join-Path $PSScriptRoot 'RobotCapture.ps1')
    $windowInfo = Get-RobotCaptureTarget (Read-RobotTrainingConfiguration $ConfigPath) $ObservedWindowHandle $ObservedProcessId
  } else {
    $windowInfo = Get-IdentWindow $config
  }

if ($Mode -eq 'Observe') {
  if ([string]::IsNullOrWhiteSpace($ReportPath)) { throw 'Observation report path is required.' }
  $null = Invoke-ObservedCapture -WindowInfo $windowInfo -WindowHandle $ObservedWindowHandle `
    -ProcessId $ObservedProcessId -OutputReportPath $ReportPath -ScanId $CaptureId -Surface $ObservedSurface
  Write-Host 'ROBOT_OBSERVATION_OK profileVerified=false actionsExecuted=0'
  return
}

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
    -OutputReportPath $resolvedReportPath `
    -ScanId $(if ([string]::IsNullOrWhiteSpace($CaptureId)) { [guid]::NewGuid().ToString('N') } else { $CaptureId })
  if (-not [bool]$report.ok) {
    Write-RobotLog $config 'warn' 'Automatic calibration was not accepted' @{
      reportPath = $resolvedReportPath
      issues = @($report.issues)
    }
    Write-Host 'ROBOT_CALIBRATION_INCOMPLETE'
    throw (@($report.issues) -join ' ')
  }
  Write-RobotLog $config 'info' 'IDENT UI capture completed; profile not activated' @{
    reportPath = $resolvedReportPath
    selectors = @($report.requiredSelectors).Count
  }
  Write-Host "ROBOT_CAPTURE_OK profileVerified=false selectorsComplete=$($report.selectorsComplete)"
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
  if ($Mode -eq 'PatientFillCheck') {
    # UIA provider errors can contain field contents. Never log or rethrow them.
    $safeCode=if ($_.Exception.Message -in @('FILL_LAUNCHER_REQUIRED','FILL_BUSY','FILL_INVALID_REQUEST','FILL_REVIEW_PENDING',
        'FILL_ROBOT_ENABLED','FILL_CONSENT_REQUIRED','FILL_WINDOW_CHANGED')) { $_.Exception.Message } else { 'FILL_CHECK_FAILED' }
    if ($fillReportPath) {
      try {
        Write-JsonFileAtomic $fillReportPath ([pscustomobject]@{ Ok=$false; State='rejected'; ErrorCode=$safeCode;
          SaveInvoked=$false; ReadyForUnattendedExecution=$false;
          RequiresManualReview=(Test-Path -LiteralPath (Join-Path $directory 'fill-check-pending.json')) })
      } catch { }
    }
    Write-Host ('IDENT_FILL_CHECK rejected '+$safeCode)
    exit 1
  }
  if ($null -ne $config) {
    $screenshot = ''
    if ($Execute -and $Mode -in @('RunOnce', 'Loop')) {
      $screenshot = Save-FailureScreenshot -Config $config -WindowInfo $windowInfo -Prefix $(if ($script:SaveInvoked) { 'ambiguous-after-save' } else { 'robot-error' })
    }
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
  if ($null -ne $interactionLease) { $interactionLease.Dispose() }
  if ($ownsRobotMutex) {
    $robotMutex.ReleaseMutex()
  }
  $robotMutex.Dispose()
}
