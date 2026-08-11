[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$DiagnosticsCapturePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Get-PlainTextSecret {
    param([string]$EncryptedValue)
    if ([string]::IsNullOrWhiteSpace($EncryptedValue)) { return '' }
    $secure = ConvertTo-SecureString -String $EncryptedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
}

function Resolve-LocalPath {
    param([string]$BaseDirectory, [string]$Value)
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Test-ObjectProperty {
    param([object]$Value, [string]$Name)
    return $null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name]
}

function Get-ApiErrorMessage {
    param([object]$ErrorRecord)
    $message = [string]$ErrorRecord.Exception.Message
    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response) {
        try {
            $stream = $response.GetResponseStream()
            $reader = New-Object IO.StreamReader($stream)
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            if (-not [string]::IsNullOrWhiteSpace($body)) {
                try {
                    $parsed = $body | ConvertFrom-Json
                    if (Test-ObjectProperty -Value $parsed -Name 'error') { return [string]$parsed.error }
                } catch { return $body }
            }
        } catch {}
    }
    return $message
}

function Invoke-AdminApi {
    param(
        [ValidateSet('GET', 'POST')][string]$Method,
        [string]$Path,
        [object]$Body = $null
    )
    $url = ([string]$script:Config.backend.baseUrl).TrimEnd('/') + '/' + $Path.TrimStart('/')
    $parameters = @{
        Uri = $url
        Method = $Method
        Headers = @{ Accept = 'application/json'; 'X-API-Key' = $script:ServiceKey }
        TimeoutSec = [int]$script:Config.backend.timeoutSeconds
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 16 -Compress
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    try { return Invoke-RestMethod @parameters }
    catch { throw (Get-ApiErrorMessage -ErrorRecord $_) }
}

function Try-AdminGet {
    param([string]$Path)
    try { return Invoke-AdminApi -Method GET -Path $Path }
    catch { return $null }
}

function Format-DateValue {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'нет' }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed.LocalDateTime.ToString('dd.MM.yyyy HH:mm:ss')
    }
    return [string]$Value
}

function Format-AgentState {
    param([string]$Value)
    $states = @{
        ok = 'Работает'; online = 'Работает'; idle = 'Ожидание'; disabled = 'Выключено'
        error = 'Ошибка'; failed = 'Ошибка'; starting = 'Запускается'; sending = 'Отправка'
        needs_mapping = 'Нужна настройка'; mapping_error = 'Ошибка SQL'; not_available = 'Нет данных'
        downloading = 'Скачивание'; applying = 'Установка'; succeeded = 'Установлено'
    }
    if ($states.ContainsKey($Value)) { return $states[$Value] }
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'нет' }
    return $Value
}

function New-Label {
    param([Windows.Forms.Control]$Parent, [string]$Text, [int]$Left, [int]$Top, [int]$Width, [int]$Height = 24, [bool]$Bold = $false)
    $label = New-Object Windows.Forms.Label
    $label.Location = New-Object Drawing.Point($Left, $Top)
    $label.Size = New-Object Drawing.Size($Width, $Height)
    $label.Text = $Text
    $label.Font = New-Object Drawing.Font('Segoe UI', 9, $(if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
    $label.AutoEllipsis = $true
    $Parent.Controls.Add($label)
    return $label
}

function New-Button {
    param([Windows.Forms.Control]$Parent, [string]$Text, [int]$Left, [int]$Top, [int]$Width, [int]$Height = 34)
    $button = New-Object Windows.Forms.Button
    $button.Location = New-Object Drawing.Point($Left, $Top)
    $button.Size = New-Object Drawing.Size($Width, $Height)
    $button.Text = $Text
    $button.FlatStyle = [Windows.Forms.FlatStyle]::System
    $Parent.Controls.Add($button)
    return $button
}

function Initialize-Grid {
    param([Windows.Forms.DataGridView]$Grid)
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.AutoGenerateColumns = $false
    $Grid.BackgroundColor = [Drawing.Color]::White
    $Grid.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $Grid.CellBorderStyle = [Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $Grid.ColumnHeadersHeight = 34
    $Grid.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::DisableResizing
    $Grid.RowHeadersVisible = $false
    $Grid.RowTemplate.Height = 30
    $Grid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $Grid.MultiSelect = $false
    $Grid.ReadOnly = $true
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(235, 239, 242)
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(35, 46, 56)
    $Grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(221, 237, 228)
    $Grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::FromArgb(25, 38, 32)
}

function Add-GridColumn {
    param([Windows.Forms.DataGridView]$Grid, [string]$Name, [string]$Header, [int]$Width, [bool]$Fill = $false)
    $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.HeaderText = $Header
    if ($Fill) { $column.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill }
    else { $column.Width = $Width }
    [void]$Grid.Columns.Add($column)
}

$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$baseDirectory = Split-Path -Parent $ConfigPath
$script:Config = Read-JsonFile -Path $ConfigPath
if ($null -eq $script:Config) {
    [Windows.Forms.MessageBox]::Show('Не найдены настройки. Запустите 1-Setup.cmd.', 'Code9 IDENT Admin') | Out-Null
    exit 1
}
$secretsPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$script:Config.paths.secrets)
$secrets = Read-JsonFile -Path $secretsPath
$script:ServiceKey = if ($null -ne $secrets) { Get-PlainTextSecret -EncryptedValue ([string]$secrets.serviceApiKeyDpapi) } else { '' }
if ([string]::IsNullOrWhiteSpace($script:ServiceKey)) {
    [Windows.Forms.MessageBox]::Show('Не найден ключ администратора. Запустите установку повторно.', 'Code9 IDENT Admin') | Out-Null
    exit 1
}

$script:AgentStatus = $null
$script:Timetable = $null
$script:Releases = @()
$script:SelectedAgentId = ''
$script:Refreshing = $false

$form = New-Object Windows.Forms.Form
$form.Text = 'Code9 IDENT Admin'
$form.ClientSize = New-Object Drawing.Size(1180, 760)
$form.MinimumSize = New-Object Drawing.Size(1000, 680)
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)

$header = New-Object Windows.Forms.Panel
$header.Dock = [Windows.Forms.DockStyle]::Top
$header.Height = 68
$header.BackColor = [Drawing.Color]::FromArgb(30, 41, 49)
$form.Controls.Add($header)
$title = New-Label -Parent $header -Text 'Code9 IDENT' -Left 20 -Top 11 -Width 240 -Height 28 -Bold $true
$title.Font = New-Object Drawing.Font('Segoe UI', 15, [Drawing.FontStyle]::Bold)
$title.ForeColor = [Drawing.Color]::White
$subtitle = New-Label -Parent $header -Text 'Управление интеграцией клиники' -Left 21 -Top 39 -Width 330 -Height 20
$subtitle.ForeColor = [Drawing.Color]::FromArgb(180, 194, 202)
$connectionLabel = New-Label -Parent $header -Text 'Сервер: проверка...' -Left 690 -Top 23 -Width 300 -Height 24 -Bold $true
$connectionLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$connectionLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$connectionLabel.ForeColor = [Drawing.Color]::FromArgb(244, 190, 71)
$refreshButton = New-Button -Parent $header -Text 'Обновить' -Left 1010 -Top 17 -Width 145 -Height 36
$refreshButton.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right

$statusStrip = New-Object Windows.Forms.StatusStrip
$statusStrip.SizingGrip = $false
$statusText = New-Object Windows.Forms.ToolStripStatusLabel
$statusText.Spring = $true
$statusText.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$statusText.Text = 'Готово'
[void]$statusStrip.Items.Add($statusText)
$form.Controls.Add($statusStrip)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Dock = [Windows.Forms.DockStyle]::Fill
$tabs.Padding = New-Object Drawing.Point(18, 7)
$form.Controls.Add($tabs)
$tabs.BringToFront()

$statusTab = New-Object Windows.Forms.TabPage
$statusTab.Text = 'Состояние'
$statusTab.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
[void]$tabs.TabPages.Add($statusTab)
$scheduleTab = New-Object Windows.Forms.TabPage
$scheduleTab.Text = 'Расписание'
$scheduleTab.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
[void]$tabs.TabPages.Add($scheduleTab)
$mappingTab = New-Object Windows.Forms.TabPage
$mappingTab.Text = 'База IDENT'
$mappingTab.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
[void]$tabs.TabPages.Add($mappingTab)
$diagnosticsTab = New-Object Windows.Forms.TabPage
$diagnosticsTab.Text = 'Диагностика'
$diagnosticsTab.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
[void]$tabs.TabPages.Add($diagnosticsTab)
$updatesTab = New-Object Windows.Forms.TabPage
$updatesTab.Text = 'Версии'
$updatesTab.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
[void]$tabs.TabPages.Add($updatesTab)

$summaryLabel = New-Label -Parent $statusTab -Text 'Сервер: ожидание  |  Агенты: 0  |  Заявки: 0  |  Ошибки очереди: 0' -Left 16 -Top 14 -Width 1100 -Height 28 -Bold $true
$summaryLabel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$agentGrid = New-Object Windows.Forms.DataGridView
$agentGrid.Location = New-Object Drawing.Point(16, 50)
$agentGrid.Size = New-Object Drawing.Size(1128, 330)
$agentGrid.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
Initialize-Grid -Grid $agentGrid
Add-GridColumn -Grid $agentGrid -Name 'online' -Header 'Связь' -Width 90
Add-GridColumn -Grid $agentGrid -Name 'agent' -Header 'Агент' -Width 200
Add-GridColumn -Grid $agentGrid -Name 'computer' -Header 'Компьютер' -Width 145
Add-GridColumn -Grid $agentGrid -Name 'version' -Header 'Версия' -Width 80
Add-GridColumn -Grid $agentGrid -Name 'seen' -Header 'Последний сигнал' -Width 155
Add-GridColumn -Grid $agentGrid -Name 'schedule' -Header 'Расписание' -Width 120
Add-GridColumn -Grid $agentGrid -Name 'counts' -Header 'Врачи / окна' -Width 110
Add-GridColumn -Grid $agentGrid -Name 'update' -Header 'Обновление' -Width 0 -Fill $true
$statusTab.Controls.Add($agentGrid)

$controlsPanel = New-Object Windows.Forms.Panel
$controlsPanel.Location = New-Object Drawing.Point(16, 392)
$controlsPanel.Size = New-Object Drawing.Size(1128, 210)
$controlsPanel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
$controlsPanel.BackColor = [Drawing.Color]::White
$controlsPanel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$statusTab.Controls.Add($controlsPanel)
$selectedLabel = New-Label -Parent $controlsPanel -Text 'Агент не выбран' -Left 16 -Top 12 -Width 650 -Height 26 -Bold $true
$selectedLabel.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$scheduleCheck = New-Object Windows.Forms.CheckBox
$scheduleCheck.Location = New-Object Drawing.Point(18, 50)
$scheduleCheck.Size = New-Object Drawing.Size(245, 28)
$scheduleCheck.Text = 'Выгрузка расписания включена'
$controlsPanel.Controls.Add($scheduleCheck)
$robotCheck = New-Object Windows.Forms.CheckBox
$robotCheck.Location = New-Object Drawing.Point(280, 50)
$robotCheck.Size = New-Object Drawing.Size(240, 28)
$robotCheck.Text = 'Робот заявок включен'
$controlsPanel.Controls.Add($robotCheck)
$applySettingsButton = New-Button -Parent $controlsPanel -Text 'Применить' -Left 18 -Top 88 -Width 130
$sendNowButton = New-Button -Parent $controlsPanel -Text 'Отправить сейчас' -Left 158 -Top 88 -Width 160
$openSchemaButton = New-Button -Parent $controlsPanel -Text 'Открыть базу IDENT' -Left 328 -Top 88 -Width 180
$agentDetailLabel = New-Label -Parent $controlsPanel -Text '' -Left 18 -Top 138 -Width 1080 -Height 54
$agentDetailLabel.Anchor = [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
$agentDetailLabel.ForeColor = [Drawing.Color]::FromArgb(76, 91, 101)

$scheduleSummary = New-Label -Parent $scheduleTab -Text 'Расписание еще не получено' -Left 16 -Top 14 -Width 1100 -Height 28 -Bold $true
$scheduleGrid = New-Object Windows.Forms.DataGridView
$scheduleGrid.Location = New-Object Drawing.Point(16, 50)
$scheduleGrid.Size = New-Object Drawing.Size(1128, 552)
$scheduleGrid.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
Initialize-Grid -Grid $scheduleGrid
Add-GridColumn -Grid $scheduleGrid -Name 'start' -Header 'Начало' -Width 165
Add-GridColumn -Grid $scheduleGrid -Name 'doctor' -Header 'Врач' -Width 0 -Fill $true
Add-GridColumn -Grid $scheduleGrid -Name 'branch' -Header 'Филиал' -Width 240
Add-GridColumn -Grid $scheduleGrid -Name 'duration' -Header 'Минут' -Width 80
Add-GridColumn -Grid $scheduleGrid -Name 'state' -Header 'Состояние' -Width 120
$scheduleTab.Controls.Add($scheduleGrid)

$mappingToolbar = New-Object Windows.Forms.Panel
$mappingToolbar.Dock = [Windows.Forms.DockStyle]::Top
$mappingToolbar.Height = 52
$mappingToolbar.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
$mappingTab.Controls.Add($mappingToolbar)
$mappingAgentLabel = New-Label -Parent $mappingToolbar -Text 'Агент не выбран' -Left 12 -Top 15 -Width 360 -Height 24 -Bold $true
$loadSchemaButton = New-Button -Parent $mappingToolbar -Text 'Загрузить структуру' -Left 480 -Top 8 -Width 160
$loadMappingButton = New-Button -Parent $mappingToolbar -Text 'Текущие запросы' -Left 650 -Top 8 -Width 150
$saveMappingButton = New-Button -Parent $mappingToolbar -Text 'Сохранить агенту' -Left 810 -Top 8 -Width 160
$mappingSplit = New-Object Windows.Forms.SplitContainer
$mappingSplit.Size = New-Object Drawing.Size(1128, 550)
$mappingSplit.Dock = [Windows.Forms.DockStyle]::Fill
$mappingSplit.SplitterDistance = 365
$mappingSplit.Panel1MinSize = 280
$mappingSplit.Panel2MinSize = 520
$mappingTab.Controls.Add($mappingSplit)
$mappingSplit.BringToFront()
$schemaTree = New-Object Windows.Forms.TreeView
$schemaTree.Dock = [Windows.Forms.DockStyle]::Fill
$schemaTree.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$schemaTree.Font = New-Object Drawing.Font('Consolas', 9)
$mappingSplit.Panel1.Controls.Add($schemaTree)
$sqlTabs = New-Object Windows.Forms.TabControl
$sqlTabs.Dock = [Windows.Forms.DockStyle]::Fill
$mappingSplit.Panel2.Controls.Add($sqlTabs)
$doctorsSqlTab = New-Object Windows.Forms.TabPage
$doctorsSqlTab.Text = 'Врачи'
$branchesSqlTab = New-Object Windows.Forms.TabPage
$branchesSqlTab.Text = 'Филиалы'
$intervalsSqlTab = New-Object Windows.Forms.TabPage
$intervalsSqlTab.Text = 'Окна'
[void]$sqlTabs.TabPages.Add($doctorsSqlTab)
[void]$sqlTabs.TabPages.Add($branchesSqlTab)
[void]$sqlTabs.TabPages.Add($intervalsSqlTab)
function New-SqlEditor {
    param([Windows.Forms.TabPage]$Parent)
    $editor = New-Object Windows.Forms.TextBox
    $editor.Dock = [Windows.Forms.DockStyle]::Fill
    $editor.Multiline = $true
    $editor.AcceptsReturn = $true
    $editor.AcceptsTab = $true
    $editor.ScrollBars = [Windows.Forms.ScrollBars]::Both
    $editor.WordWrap = $false
    $editor.Font = New-Object Drawing.Font('Consolas', 9)
    $Parent.Controls.Add($editor)
    return $editor
}
$doctorsSql = New-SqlEditor -Parent $doctorsSqlTab
$branchesSql = New-SqlEditor -Parent $branchesSqlTab
$intervalsSql = New-SqlEditor -Parent $intervalsSqlTab

$diagnosticsReport = New-Object Windows.Forms.TextBox
$diagnosticsReport.Location = New-Object Drawing.Point(0, 126)
$diagnosticsReport.Size = New-Object Drawing.Size(1128, 476)
$diagnosticsReport.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Bottom -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$diagnosticsReport.Multiline = $true
$diagnosticsReport.ReadOnly = $true
$diagnosticsReport.ScrollBars = [Windows.Forms.ScrollBars]::Both
$diagnosticsReport.WordWrap = $false
$diagnosticsReport.Font = New-Object Drawing.Font('Consolas', 9)
$diagnosticsReport.BackColor = [Drawing.Color]::White
$diagnosticsTab.Controls.Add($diagnosticsReport)
$diagnosticsToolbar = New-Object Windows.Forms.Panel
$diagnosticsToolbar.Location = New-Object Drawing.Point(0, 0)
$diagnosticsToolbar.Size = New-Object Drawing.Size(1128, 126)
$diagnosticsToolbar.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$diagnosticsToolbar.Height = 126
$diagnosticsToolbar.BackColor = [Drawing.Color]::FromArgb(244, 247, 248)
$diagnosticsTab.Controls.Add($diagnosticsToolbar)
$diagnosticsToolbar.BringToFront()
$diagnosticsAgentLabel = New-Label -Parent $diagnosticsToolbar -Text 'Агент не выбран' -Left 12 -Top 9 -Width 225 -Height 26 -Bold $true
$requestDiagnosticsButton = New-Button -Parent $diagnosticsToolbar -Text 'Запросить отчет' -Left 245 -Top 5 -Width 140
$loadDiagnosticsButton = New-Button -Parent $diagnosticsToolbar -Text 'Загрузить отчет' -Left 395 -Top 5 -Width 140
$discoverSqlButton = New-Button -Parent $diagnosticsToolbar -Text 'Найти SQL удаленно' -Left 545 -Top 5 -Width 170
$restartAgentButton = New-Button -Parent $diagnosticsToolbar -Text 'Перезапустить агент' -Left 725 -Top 5 -Width 170
[void](New-Label -Parent $diagnosticsToolbar -Text 'Data Source' -Left 12 -Top 50 -Width 85 -Height 24)
$remoteDataSource = New-Object Windows.Forms.TextBox
$remoteDataSource.Location = New-Object Drawing.Point(100, 48)
$remoteDataSource.Size = New-Object Drawing.Size(360, 28)
$remoteDataSource.Font = New-Object Drawing.Font('Consolas', 9)
$diagnosticsToolbar.Controls.Add($remoteDataSource)
[void](New-Label -Parent $diagnosticsToolbar -Text 'База' -Left 470 -Top 50 -Width 40 -Height 24)
$remoteDatabase = New-Object Windows.Forms.TextBox
$remoteDatabase.Location = New-Object Drawing.Point(515, 48)
$remoteDatabase.Size = New-Object Drawing.Size(175, 28)
$remoteDatabase.Font = New-Object Drawing.Font('Consolas', 9)
$diagnosticsToolbar.Controls.Add($remoteDatabase)
$applySqlConnectionButton = New-Button -Parent $diagnosticsToolbar -Text 'Применить подключение' -Left 705 -Top 44 -Width 190
$diagnosticsHint = New-Label -Parent $diagnosticsToolbar -Text 'Команды выполняются при следующем сигнале агента. Пароль SQL остается зашифрованным на компьютере клиники.' -Left 12 -Top 88 -Width 1080 -Height 24
$diagnosticsHint.ForeColor = [Drawing.Color]::FromArgb(76, 91, 101)

$releaseGrid = New-Object Windows.Forms.DataGridView
$releaseGrid.Location = New-Object Drawing.Point(16, 50)
$releaseGrid.Size = New-Object Drawing.Size(1128, 330)
$releaseGrid.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
Initialize-Grid -Grid $releaseGrid
Add-GridColumn -Grid $releaseGrid -Name 'version' -Header 'Версия' -Width 110
Add-GridColumn -Grid $releaseGrid -Name 'published' -Header 'Опубликована' -Width 170
Add-GridColumn -Grid $releaseGrid -Name 'size' -Header 'Размер' -Width 100
Add-GridColumn -Grid $releaseGrid -Name 'hash' -Header 'SHA-256' -Width 260
Add-GridColumn -Grid $releaseGrid -Name 'notes' -Header 'Описание' -Width 0 -Fill $true
$updatesTab.Controls.Add($releaseGrid)
$releaseTitle = New-Label -Parent $updatesTab -Text 'Версии клиентского агента' -Left 16 -Top 14 -Width 500 -Height 28 -Bold $true
$updatesPanel = New-Object Windows.Forms.Panel
$updatesPanel.Location = New-Object Drawing.Point(16, 392)
$updatesPanel.Size = New-Object Drawing.Size(1128, 210)
$updatesPanel.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
$updatesPanel.BackColor = [Drawing.Color]::White
$updatesPanel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$updatesTab.Controls.Add($updatesPanel)
$updateAgentLabel = New-Label -Parent $updatesPanel -Text 'Агент не выбран' -Left 16 -Top 15 -Width 700 -Height 26 -Bold $true
$publishButton = New-Button -Parent $updatesPanel -Text 'Опубликовать ZIP' -Left 16 -Top 55 -Width 170
$assignButton = New-Button -Parent $updatesPanel -Text 'Назначить версию' -Left 196 -Top 55 -Width 170
$clearUpdateButton = New-Button -Parent $updatesPanel -Text 'Отменить назначение' -Left 376 -Top 55 -Width 180
$updateDetailLabel = New-Label -Parent $updatesPanel -Text '' -Left 16 -Top 108 -Width 1080 -Height 70
$updateDetailLabel.ForeColor = [Drawing.Color]::FromArgb(76, 91, 101)

function Set-StatusMessage {
    param([string]$Text, [bool]$Error = $false)
    $statusText.Text = $Text
    $statusText.ForeColor = $(if ($Error) { [Drawing.Color]::FromArgb(166, 42, 42) } else { [Drawing.Color]::FromArgb(55, 70, 80) })
}

function Update-TabLayouts {
    $contentWidth = [Math]::Max(700, $statusTab.ClientSize.Width - 32)
    $statusPanelHeight = 190
    $statusGridHeight = [Math]::Max(170, $statusTab.ClientSize.Height - 50 - 12 - $statusPanelHeight - 16)
    $summaryLabel.Width = $contentWidth
    $agentGrid.Size = New-Object Drawing.Size($contentWidth, $statusGridHeight)
    $controlsPanel.Location = New-Object Drawing.Point(16, (50 + $statusGridHeight + 12))
    $controlsPanel.Size = New-Object Drawing.Size($contentWidth, $statusPanelHeight)
    $agentDetailLabel.Width = [Math]::Max(300, $contentWidth - 36)

    $scheduleSummary.Width = $contentWidth
    $scheduleGrid.Size = New-Object Drawing.Size($contentWidth, ([Math]::Max(220, $scheduleTab.ClientSize.Height - 66)))

    $diagnosticsToolbar.Width = [Math]::Max(700, $diagnosticsTab.ClientSize.Width)
    $diagnosticsReport.Size = New-Object Drawing.Size(
        ([Math]::Max(700, $diagnosticsTab.ClientSize.Width)),
        ([Math]::Max(220, $diagnosticsTab.ClientSize.Height - $diagnosticsToolbar.Height))
    )

    $updatesWidth = [Math]::Max(700, $updatesTab.ClientSize.Width - 32)
    $updatesPanelHeight = 190
    $releaseGridHeight = [Math]::Max(170, $updatesTab.ClientSize.Height - 50 - 12 - $updatesPanelHeight - 16)
    $releaseGrid.Size = New-Object Drawing.Size($updatesWidth, $releaseGridHeight)
    $updatesPanel.Location = New-Object Drawing.Point(16, (50 + $releaseGridHeight + 12))
    $updatesPanel.Size = New-Object Drawing.Size($updatesWidth, $updatesPanelHeight)
    $updateDetailLabel.Width = [Math]::Max(300, $updatesWidth - 36)
}

function Get-DesiredForAgent {
    param([string]$AgentId)
    if ($null -eq $script:AgentStatus -or $null -eq $script:AgentStatus.desired) { return $null }
    $property = $script:AgentStatus.desired.PSObject.Properties[$AgentId]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SelectedAgent {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId) -or $null -eq $script:AgentStatus) { return $null }
    return @($script:AgentStatus.agents | Where-Object { [string]$_.agentId -eq $script:SelectedAgentId } | Select-Object -First 1)[0]
}

function Sync-AgentSelection {
    if ($script:Refreshing -or $agentGrid.SelectedRows.Count -eq 0) { return }
    $row = $agentGrid.SelectedRows[0]
    $script:SelectedAgentId = [string]$row.Cells['agent'].Value
    $agent = Get-SelectedAgent
    $desired = Get-DesiredForAgent -AgentId $script:SelectedAgentId
    $selectedLabel.Text = "Агент: $($script:SelectedAgentId)"
    $mappingAgentLabel.Text = "Агент: $($script:SelectedAgentId)"
    $diagnosticsAgentLabel.Text = "Агент: $($script:SelectedAgentId)"
    $updateAgentLabel.Text = "Агент: $($script:SelectedAgentId)"
    $remoteDataSource.Text = ''
    $remoteDatabase.Text = ''
    if ($null -ne $desired) {
        $scheduleCheck.Checked = [bool]$desired.scheduleEnabled
        $robotCheck.Checked = [bool]$desired.robotEnabled
        if ((Test-ObjectProperty -Value $desired -Name 'sqlConfiguration') -and $null -ne $desired.sqlConfiguration) {
            $remoteDataSource.Text = [string]$desired.sqlConfiguration.dataSource
            $remoteDatabase.Text = [string]$desired.sqlConfiguration.database
        }
    }
    if ($null -ne $agent) {
        $agentUpdate = if (Test-ObjectProperty -Value $agent -Name 'update') { $agent.update } else { $null }
        $agentUpdateStatus = if (Test-ObjectProperty -Value $agentUpdate -Name 'status') { [string]$agentUpdate.status } else { '' }
        $agentUpdateMessage = if (Test-ObjectProperty -Value $agentUpdate -Name 'message') { [string]$agentUpdate.message } else { '' }
        $lastError = @([string]$agent.schedule.lastError, [string]$agent.schema.lastError, [string]$agent.robot.lastError) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        $agentDetailLabel.Text = "Компьютер: $($agent.deviceName)  |  последний сигнал: $(Format-DateValue $agent.lastSeenAt)`r`n" +
            "SQL: $(Format-AgentState ([string]$agent.schema.state))  |  робот: $(Format-AgentState ([string]$agent.robot.state))" +
            $(if ($lastError) { "  |  ошибка: $lastError" } else { '' })
        $target = if ($null -ne $desired -and $null -ne $desired.update) { [string]$desired.update.version } else { 'не назначена' }
        $updateDetailLabel.Text = "Текущая версия: $($agent.version)  |  назначенная версия: $target`r`n" +
            "Состояние: $(Format-AgentState $agentUpdateStatus)" +
            $(if (-not [string]::IsNullOrWhiteSpace($agentUpdateMessage)) { "  |  $agentUpdateMessage" } else { '' })
    }
}

function Render-Agents {
    $selectedBefore = $script:SelectedAgentId
    $script:Refreshing = $true
    try {
        $agentGrid.Rows.Clear()
        if ($null -eq $script:AgentStatus) { return }
        foreach ($agent in @($script:AgentStatus.agents)) {
            $agentUpdate = if (Test-ObjectProperty -Value $agent -Name 'update') { $agent.update } else { $null }
            $updateTarget = if (Test-ObjectProperty -Value $agentUpdate -Name 'targetVersion') { [string]$agentUpdate.targetVersion } else { '' }
            $updateStatus = if (Test-ObjectProperty -Value $agentUpdate -Name 'status') { [string]$agentUpdate.status } else { '' }
            $updateText = if (-not [string]::IsNullOrWhiteSpace($updateTarget)) {
                "$updateTarget`: $(Format-AgentState $updateStatus)"
            } else { 'нет' }
            $rowIndex = $agentGrid.Rows.Add(
                $(if ([bool]$agent.online) { 'На связи' } else { 'Нет связи' }),
                [string]$agent.agentId,
                [string]$agent.deviceName,
                [string]$agent.version,
                (Format-DateValue $agent.lastSeenAt),
                (Format-AgentState ([string]$agent.schedule.state)),
                ("{0} / {1}" -f $agent.schedule.doctors, $agent.schedule.intervals),
                $updateText
            )
            $row = $agentGrid.Rows[$rowIndex]
            if (-not [bool]$agent.online) { $row.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(155, 48, 45) }
            if ([string]$agent.agentId -eq $selectedBefore) {
                $row.Selected = $true
                $agentGrid.CurrentCell = $row.Cells[0]
            }
        }
        if ($agentGrid.Rows.Count -gt 0 -and $agentGrid.SelectedRows.Count -eq 0) {
            $agentGrid.Rows[0].Selected = $true
            $agentGrid.CurrentCell = $agentGrid.Rows[0].Cells[0]
        }
    }
    finally { $script:Refreshing = $false }
    if ($agentGrid.SelectedRows.Count -gt 0) {
        $script:SelectedAgentId = [string]$agentGrid.SelectedRows[0].Cells['agent'].Value
        Sync-AgentSelection
    }
}

function Render-Timetable {
    $scheduleGrid.Rows.Clear()
    if ($null -eq $script:Timetable) {
        $scheduleSummary.Text = 'Расписание еще не получено'
        return
    }
    $doctors = @{}
    foreach ($doctor in @($script:Timetable.Doctors)) { $doctors[[string]$doctor.Id] = [string]$doctor.Name }
    $branches = @{}
    foreach ($branch in @($script:Timetable.Branches)) { $branches[[string]$branch.Id] = [string]$branch.Name }
    $free = 0
    foreach ($interval in @($script:Timetable.Intervals | Sort-Object StartDateTime)) {
        if (-not [bool]$interval.IsBusy) { $free += 1 }
        $rowIndex = $scheduleGrid.Rows.Add(
            (Format-DateValue $interval.StartDateTime),
            $doctors[[string]$interval.DoctorId],
            $branches[[string]$interval.BranchId],
            [string]$interval.LengthInMinutes,
            $(if ([bool]$interval.IsBusy) { 'Занято' } else { 'Свободно' })
        )
        if (-not [bool]$interval.IsBusy) {
            $scheduleGrid.Rows[$rowIndex].DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(34, 112, 62)
        }
    }
    $scheduleSummary.Text = "Получено: $(Format-DateValue $script:Timetable.receivedAt)  |  врачи: $(@($script:Timetable.Doctors).Count)  |  филиалы: $(@($script:Timetable.Branches).Count)  |  окна: $(@($script:Timetable.Intervals).Count)  |  свободно: $free"
}

function Render-Releases {
    $releaseGrid.Rows.Clear()
    foreach ($release in @($script:Releases)) {
        [void]$releaseGrid.Rows.Add(
            [string]$release.version,
            (Format-DateValue $release.publishedAt),
            ("{0:N0} КБ" -f ([double]$release.size / 1KB)),
            [string]$release.sha256,
            [string]$release.notes
        )
    }
}

function Refresh-All {
    if ($script:Refreshing) { return }
    $script:Refreshing = $true
    $refreshButton.Enabled = $false
    Set-StatusMessage -Text 'Получение данных с сервера...'
    try {
        $health = Invoke-AdminApi -Method GET -Path '/health'
        $script:AgentStatus = Invoke-AdminApi -Method GET -Path '/api/agent/status'
        $diagnostics = Invoke-AdminApi -Method GET -Path '/api/diagnostics'
        $tickets = Invoke-AdminApi -Method GET -Path '/api/tickets/summary'
        $jobs = Invoke-AdminApi -Method GET -Path '/api/jobs/summary'
        $script:Timetable = Try-AdminGet -Path '/api/timetable'
        $releaseResponse = Invoke-AdminApi -Method GET -Path '/api/agent/releases'
        $script:Releases = @($releaseResponse.releases)
        $connectionLabel.Text = 'Сервер: на связи'
        $connectionLabel.ForeColor = [Drawing.Color]::FromArgb(111, 203, 144)
        $failedJobs = if ($null -ne $jobs.statuses) { [int]$jobs.statuses.failed } else { 0 }
        $summaryLabel.Text = "Сервер: $($diagnostics.status)  |  Агенты: $(@($script:AgentStatus.agents).Count)  |  Заявки: $($tickets.total)  |  Ошибки очереди: $failedJobs  |  amoCRM: $(if ([bool]$health.amoConfigured) { 'подключена' } else { 'не подключена' })"
        $script:Refreshing = $false
        Render-Agents
        Render-Timetable
        Render-Releases
        if ($tabs.SelectedTab -eq $diagnosticsTab) { Load-AgentDiagnostics -Silent }
        Set-StatusMessage -Text ("Обновлено: " + (Get-Date).ToString('HH:mm:ss'))
    }
    catch {
        $connectionLabel.Text = 'Сервер: нет связи'
        $connectionLabel.ForeColor = [Drawing.Color]::FromArgb(244, 126, 114)
        Set-StatusMessage -Text $_.Exception.Message -Error $true
    }
    finally {
        $script:Refreshing = $false
        $refreshButton.Enabled = $true
    }
}

function Save-AgentSettings {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    if ($robotCheck.Checked) {
        $answer = [Windows.Forms.MessageBox]::Show(
            'Включить робота заявок для выбранного агента?',
            'Code9 IDENT Admin',
            [Windows.Forms.MessageBoxButtons]::YesNo,
            [Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        scheduleEnabled = $scheduleCheck.Checked
        robotEnabled = $robotCheck.Checked
    })
    Refresh-All
}

function Request-ScheduleNow {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        requestScheduleNow = $true
    })
    Set-StatusMessage -Text 'Команда на отправку расписания передана агенту.'
}

function Request-AgentDiagnostics {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        requestDiagnosticsNow = $true
    })
    Set-StatusMessage -Text 'Диагностика запрошена. Отчет появится после следующего сигнала агента.'
}

function Request-AgentSqlDiscovery {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    $answer = [Windows.Forms.MessageBox]::Show(
        'Запустить повторный поиск SQL на компьютере клиники? На время поиска выгрузка может остановиться примерно на минуту.',
        'Code9 IDENT Admin',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        requestSqlDiscovery = $true
    })
    Set-StatusMessage -Text 'Команда поиска SQL передана агенту. Через минуту загрузите диагностический отчет.'
}

function Request-AgentRestart {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    $answer = [Windows.Forms.MessageBox]::Show(
        "Перезапустить агент $($script:SelectedAgentId)?",
        'Code9 IDENT Admin',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        requestRestart = $true
    })
    Set-StatusMessage -Text 'Перезапуск назначен. Агент вернется на связь автоматически.'
}

function Save-AgentSqlConnection {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    $dataSource = $remoteDataSource.Text.Trim()
    $database = $remoteDatabase.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($dataSource) -or [string]::IsNullOrWhiteSpace($database)) {
        throw 'Заполните Data Source и базу данных.'
    }
    if ($dataSource -match '[;\r\n]' -or $database -match '[;\r\n]') {
        throw 'Data Source и название базы не должны содержать точку с запятой или перенос строки.'
    }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        sqlConfiguration = @{
            dataSource = $dataSource
            database = $database
        }
        requestDiagnosticsNow = $true
        requestScheduleNow = $true
    })
    Set-StatusMessage -Text 'Подключение сохранено. Агент проверит базу и отправит новый отчет.'
}

function Load-AgentDiagnostics {
    param([switch]$Silent)

    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) {
        if ($Silent) { return }
        throw 'Сначала выберите агент.'
    }
    $encoded = [Uri]::EscapeDataString($script:SelectedAgentId)
    try {
        $report = Invoke-AdminApi -Method GET -Path "/api/agent/diagnostics?agentId=$encoded"
    }
    catch {
        if ($Silent) { return }
        throw
    }

    $builder = New-Object Text.StringBuilder
    [void]$builder.AppendLine("ОТЧЕТ АГЕНТА: $($report.agentId)")
    [void]$builder.AppendLine("Получен: $(Format-DateValue $report.receivedAt)  |  сформирован: $(Format-DateValue $report.generatedAt)")
    [void]$builder.AppendLine("Компьютер: $($report.agent.deviceName)  |  версия: $($report.agent.version)  |  PID: $($report.agent.processId)")
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('SQL')
    [void]$builder.AppendLine("  Data Source: $($report.sql.dataSource)")
    [void]$builder.AppendLine("  База: $($report.sql.database)  |  пользователь: $($report.sql.user)")
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('АВТОЗАПУСК')
    [void]$builder.AppendLine("  Служба: $($report.autostart.workerTask)  |  панель: $($report.autostart.desktopTask)")
    [void]$builder.AppendLine("  Резервные ярлыки: служба=$($report.autostart.workerShortcut), панель=$($report.autostart.desktopShortcut)")
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine("ПОИСК SQL: $($report.discovery.result)  |  $(Format-DateValue $report.discovery.timestamp)")
    foreach ($attempt in @($report.discovery.attempts)) {
        $databases = if (Test-ObjectProperty -Value $attempt -Name 'databases') { [string]$attempt.databases } else { '' }
        $errorText = if (Test-ObjectProperty -Value $attempt -Name 'error') { [string]$attempt.error } else { '' }
        [void]$builder.AppendLine("  $($attempt.dataSource)  |  источник: $($attempt.source)  |  подключение: $($attempt.connected)")
        if (-not [string]::IsNullOrWhiteSpace($databases)) { [void]$builder.AppendLine("    базы: $databases") }
        if (-not [string]::IsNullOrWhiteSpace($errorText)) { [void]$builder.AppendLine("    ошибка: $errorText") }
    }
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('СОСТОЯНИЕ')
    foreach ($section in @('worker', 'schedule', 'schema', 'robot', 'update', 'diagnostics')) {
        if (Test-ObjectProperty -Value $report.state -Name $section) {
            [void]$builder.AppendLine("  ${section}: " + (($report.state.$section | ConvertTo-Json -Compress -Depth 4)))
        }
    }
    [void]$builder.AppendLine('')
    [void]$builder.AppendLine('ПОСЛЕДНИЕ СОБЫТИЯ')
    foreach ($line in @($report.logs)) { [void]$builder.AppendLine([string]$line) }
    $diagnosticsReport.Text = $builder.ToString()
    if (-not [string]::IsNullOrWhiteSpace([string]$report.sql.dataSource)) {
        $remoteDataSource.Text = [string]$report.sql.dataSource
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$report.sql.database)) {
        $remoteDatabase.Text = [string]$report.sql.database
    }
    if (-not $Silent) { Set-StatusMessage -Text 'Диагностический отчет загружен.' }
}

function Load-AgentSchema {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    $encoded = [Uri]::EscapeDataString($script:SelectedAgentId)
    $schema = Invoke-AdminApi -Method GET -Path "/api/agent/schema?agentId=$encoded"
    $schemaTree.BeginUpdate()
    try {
        $schemaTree.Nodes.Clear()
        $root = $schemaTree.Nodes.Add("$($schema.database)  ($($schema.summary.tables) таблиц, $($schema.summary.columns) колонок)")
        foreach ($table in @($schema.tables | Sort-Object schema, name)) {
            $tableNode = $root.Nodes.Add("$($table.schema).$($table.name)")
            foreach ($column in @($table.columns | Sort-Object position)) {
                $nullable = if ([bool]$column.nullable) { 'NULL' } else { 'NOT NULL' }
                [void]$tableNode.Nodes.Add("$($column.name)  $($column.type)  $nullable")
            }
        }
        $root.Expand()
    }
    finally { $schemaTree.EndUpdate() }
    Set-StatusMessage -Text 'Структура базы загружена.'
}

function Load-AgentMapping {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    $desired = Get-DesiredForAgent -AgentId $script:SelectedAgentId
    if ($null -eq $desired -or $null -eq $desired.scheduleMapping) {
        $doctorsSql.Text = ''
        $branchesSql.Text = ''
        $intervalsSql.Text = ''
        Set-StatusMessage -Text 'SQL-запросы для агента еще не настроены.'
        return
    }
    $doctorsSql.Text = [string]$desired.scheduleMapping.doctorsSql
    $branchesSql.Text = [string]$desired.scheduleMapping.branchesSql
    $intervalsSql.Text = [string]$desired.scheduleMapping.intervalsSql
    Set-StatusMessage -Text 'Текущие SQL-запросы загружены.'
}

function Save-AgentMapping {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент.' }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        scheduleMapping = @{
            doctorsSql = $doctorsSql.Text
            branchesSql = $branchesSql.Text
            intervalsSql = $intervalsSql.Text
            notes = @('Настроено через Code9 IDENT Admin')
        }
    })
    Refresh-All
    Set-StatusMessage -Text 'SQL-запросы сохранены и будут применены агентом.'
}

function Get-ReleaseManifestFromZip {
    param([string]$Path)
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = @($zip.Entries | Where-Object { $_.FullName.Replace('\\', '/') -eq 'release.json' } | Select-Object -First 1)[0]
        if ($null -eq $entry) { throw 'В архиве нет release.json.' }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { return $reader.ReadToEnd() | ConvertFrom-Json }
        finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

function Publish-Release {
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = 'Выберите ZIP клиентского агента'
    $dialog.Filter = 'ZIP (*.zip)|*.zip'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK) { return }
    $manifest = Get-ReleaseManifestFromZip -Path $dialog.FileName
    if ([string]$manifest.product -ne 'code9-ident-agent') { throw 'Выбранный ZIP не является релизом агента Code9 IDENT.' }
    $bytes = [IO.File]::ReadAllBytes($dialog.FileName)
    $hash = (Get-FileHash -LiteralPath $dialog.FileName -Algorithm SHA256).Hash
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/releases' -Body @{
        version = [string]$manifest.version
        sha256 = $hash
        notes = $(if (Test-ObjectProperty -Value $manifest -Name 'notes') { [string]$manifest.notes } else { "Code9 IDENT Desktop $($manifest.version)" })
        archiveBase64 = [Convert]::ToBase64String($bytes)
    })
    Refresh-All
    Set-StatusMessage -Text "Версия $($manifest.version) опубликована."
}

function Get-SelectedReleaseVersion {
    if ($releaseGrid.SelectedRows.Count -eq 0) { return '' }
    return [string]$releaseGrid.SelectedRows[0].Cells['version'].Value
}

function Assign-Release {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент на вкладке Состояние.' }
    $version = Get-SelectedReleaseVersion
    if ([string]::IsNullOrWhiteSpace($version)) { throw 'Сначала выберите версию.' }
    $answer = [Windows.Forms.MessageBox]::Show(
        "Назначить версию $version агенту $($script:SelectedAgentId)?",
        'Code9 IDENT Admin',
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Question
    )
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        targetVersion = $version
    })
    Refresh-All
    Set-StatusMessage -Text "Версия $version назначена агенту."
}

function Clear-AssignedRelease {
    if ([string]::IsNullOrWhiteSpace($script:SelectedAgentId)) { throw 'Сначала выберите агент на вкладке Состояние.' }
    [void](Invoke-AdminApi -Method POST -Path '/api/agent/settings' -Body @{
        agentId = $script:SelectedAgentId
        targetVersion = ''
    })
    Refresh-All
    Set-StatusMessage -Text 'Назначение версии отменено.'
}

function Invoke-UiAction {
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        Set-StatusMessage -Text $_.Exception.Message -Error $true
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Code9 IDENT Admin', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
}

$agentGrid.Add_SelectionChanged({ Sync-AgentSelection })
$refreshButton.Add_Click({ Refresh-All })
$applySettingsButton.Add_Click({ Invoke-UiAction { Save-AgentSettings } })
$sendNowButton.Add_Click({ Invoke-UiAction { Request-ScheduleNow } })
$openSchemaButton.Add_Click({ $tabs.SelectedTab = $mappingTab; Invoke-UiAction { Load-AgentSchema; Load-AgentMapping } })
$loadSchemaButton.Add_Click({ Invoke-UiAction { Load-AgentSchema } })
$loadMappingButton.Add_Click({ Invoke-UiAction { Load-AgentMapping } })
$saveMappingButton.Add_Click({ Invoke-UiAction { Save-AgentMapping } })
$requestDiagnosticsButton.Add_Click({ Invoke-UiAction { Request-AgentDiagnostics } })
$loadDiagnosticsButton.Add_Click({ Invoke-UiAction { Load-AgentDiagnostics } })
$discoverSqlButton.Add_Click({ Invoke-UiAction { Request-AgentSqlDiscovery } })
$restartAgentButton.Add_Click({ Invoke-UiAction { Request-AgentRestart } })
$applySqlConnectionButton.Add_Click({ Invoke-UiAction { Save-AgentSqlConnection } })
$publishButton.Add_Click({ Invoke-UiAction { Publish-Release } })
$assignButton.Add_Click({ Invoke-UiAction { Assign-Release } })
$clearUpdateButton.Add_Click({ Invoke-UiAction { Clear-AssignedRelease } })

$refreshTimer = New-Object Windows.Forms.Timer
$refreshTimer.Interval = [Math]::Max(15, [int]$script:Config.backend.refreshSeconds) * 1000
$refreshTimer.Add_Tick({ Refresh-All })
$statusTab.Add_Resize({ Update-TabLayouts })
$scheduleTab.Add_Resize({ Update-TabLayouts })
$updatesTab.Add_Resize({ Update-TabLayouts })
$form.Add_Shown({
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticsCapturePath)) {
        $tabs.SelectedTab = $diagnosticsTab
    }
    Update-TabLayouts
    Refresh-All
    if ([string]::IsNullOrWhiteSpace($DiagnosticsCapturePath)) {
        $refreshTimer.Start()
        return
    }
    $capturePath = [IO.Path]::GetFullPath($DiagnosticsCapturePath)
    $captureDirectory = Split-Path -Parent $capturePath
    New-Item -ItemType Directory -Force -Path $captureDirectory | Out-Null
    $form.Refresh()
    [Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object Drawing.Bitmap($diagnosticsTab.Width, $diagnosticsTab.Height)
    try {
        $diagnosticsTab.DrawToBitmap(
            $bitmap,
            (New-Object Drawing.Rectangle(0, 0, $diagnosticsTab.Width, $diagnosticsTab.Height))
        )
        $bitmap.Save($capturePath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
    $form.Close()
})
$form.Add_FormClosed({ $refreshTimer.Stop(); $refreshTimer.Dispose() })

[void]$form.ShowDialog()

