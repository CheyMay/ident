[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-LocalPath {
    param(
        [string]$BaseDirectory,
        [string]$Value
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Get-PlainTextSecret {
    param([string]$EncryptedValue)

    if ([string]::IsNullOrWhiteSpace($EncryptedValue)) {
        return ''
    }
    $secure = ConvertTo-SecureString -String $EncryptedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-ConfigContext {
    $resolvedConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    $baseDirectory = Split-Path -Parent $resolvedConfigPath
    $config = Read-JsonFile -Path $resolvedConfigPath
    $secretsPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.secrets)
    $secrets = Read-JsonFile -Path $secretsPath
    $encryptedAgentKey = if ($secrets.PSObject.Properties.Name -contains 'agentApiKeyDpapi') {
        [string]$secrets.agentApiKeyDpapi
    } else {
        ''
    }

    return [pscustomobject]@{
        Config = $config
        ConfigPath = $resolvedConfigPath
        BaseDirectory = $baseDirectory
        AgentKey = Get-PlainTextSecret -EncryptedValue $encryptedAgentKey
        StatePath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.runtimeState)
        CommandDirectory = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.commandDirectory)
        PushResultPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.pushResult)
        RobotConfigPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.robotConfig)
        RobotReceiptsPath = if ($config.paths.PSObject.Properties.Name -contains 'robotReceipts') {
            Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.robotReceipts)
        } else {
            Join-Path $baseDirectory 'robot-receipts.json'
        }
        MappingPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.mapping)
        SchemaPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.schemaOutput)
        LogPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.log)
        UpdateDirectory = if ($config.paths.PSObject.Properties.Name -contains 'updateDirectory') {
            Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.updateDirectory)
        } else {
            Join-Path $baseDirectory 'updates'
        }
        UpdateStatusPath = if ($config.paths.PSObject.Properties.Name -contains 'updateStatus') {
            Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.updateStatus)
        } else {
            Join-Path $baseDirectory 'update-status.json'
        }
        UpdaterPath = Join-Path $baseDirectory 'Apply-IdentAgentUpdate.ps1'
    }
}

function Write-WorkerLog {
    param(
        [string]$Level,
        [string]$EventName,
        [hashtable]$Data = @{}
    )

    $directory = Split-Path -Parent $script:Context.LogPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        event = $EventName
        data = $Data
    }
    Add-Content -LiteralPath $script:Context.LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 8) -Encoding UTF8
}

function Write-RuntimeState {
    $script:State.updatedAt = (Get-Date).ToString('o')
    $directory = Split-Path -Parent $script:Context.StatePath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$($script:Context.StatePath).tmp-$PID"
    $script:State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:Context.StatePath -Force
}

function Invoke-AgentRequest {
    param(
        [ValidateSet('GET', 'POST')]
        [string]$Method,
        [string]$Path,
        [object]$Body = $null
    )

    if ([string]::IsNullOrWhiteSpace($script:Context.AgentKey)) {
        throw 'Code9 agent key is empty. Run setup again.'
    }
    $url = ([string]$script:Context.Config.backend.baseUrl).TrimEnd('/') + '/' + $Path.TrimStart('/')
    $headers = @{
        Accept = 'application/json'
        'X-Agent-Key' = $script:Context.AgentKey
    }
    $parameters = @{
        Uri = $url
        Method = $Method
        Headers = $headers
        TimeoutSec = [int]$script:Context.Config.backend.timeoutSeconds
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 12 -Compress
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes($json)
    }
    return Invoke-RestMethod @parameters
}

function Write-UpdateStatus {
    param(
        [string]$Status,
        [string]$TargetVersion,
        [string]$Message
    )

    $payload = [ordered]@{
        targetVersion = $TargetVersion
        currentVersion = [string]$script:Context.Config.agent.version
        status = $Status
        message = $Message
        updatedAt = (Get-Date).ToString('o')
    }
    $temporaryPath = "$($script:Context.UpdateStatusPath).tmp-$PID"
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:Context.UpdateStatusPath -Force
    $script:State.update.targetVersion = $TargetVersion
    $script:State.update.currentVersion = [string]$script:Context.Config.agent.version
    $script:State.update.status = $Status
    $script:State.update.message = $Message
    $script:State.update.updatedAt = $payload.updatedAt
}

function Request-AgentUpdate {
    param([object]$Update)

    if ($null -eq $Update) {
        if (
            -not [string]::IsNullOrWhiteSpace([string]$script:State.update.targetVersion) -or
            [string]$script:State.update.status -ne 'idle'
        ) {
            Write-UpdateStatus -Status 'idle' -TargetVersion '' -Message ''
        }
        return
    }
    $targetVersion = [string]$Update.version
    $expectedHash = ([string]$Update.sha256).Trim().ToUpperInvariant()
    $downloadPath = [string]$Update.downloadPath
    $expectedSize = [long]$Update.size
    if ($targetVersion -eq [string]$script:Context.Config.agent.version) {
        if ([string]$script:State.update.status -ne 'succeeded') {
            Write-UpdateStatus -Status 'succeeded' -TargetVersion $targetVersion -Message 'Assigned version is installed.'
        }
        return
    }
    if (
        [string]$script:State.update.targetVersion -eq $targetVersion -and
        @('downloading', 'applying', 'failed') -contains [string]$script:State.update.status
    ) {
        return
    }

    try {
        if ($targetVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
            throw 'Server assigned an invalid update version.'
        }
        if ($expectedHash -notmatch '^[A-F0-9]{64}$' -or $expectedSize -le 0) {
            throw 'Server assigned invalid update integrity data.'
        }
        if ($downloadPath -notmatch '^/api/agent/releases/[^/]+/download$') {
            throw 'Server assigned an invalid update download path.'
        }
        if (-not (Test-Path -LiteralPath $script:Context.UpdaterPath)) {
            throw 'The local update component is missing.'
        }

        New-Item -ItemType Directory -Force -Path $script:Context.UpdateDirectory | Out-Null
        $temporaryArchive = Join-Path $script:Context.UpdateDirectory ("ident-desktop-$targetVersion.zip.part")
        $archivePath = Join-Path $script:Context.UpdateDirectory ("ident-desktop-$targetVersion.zip")
        Write-UpdateStatus -Status 'downloading' -TargetVersion $targetVersion -Message 'Downloading assigned update.'
        $url = ([string]$script:Context.Config.backend.baseUrl).TrimEnd('/') + $downloadPath
        Invoke-WebRequest `
            -Uri $url `
            -Method Get `
            -Headers @{ 'X-Agent-Key' = $script:Context.AgentKey } `
            -OutFile $temporaryArchive `
            -TimeoutSec ([int]$script:Context.Config.backend.timeoutSeconds) `
            -UseBasicParsing
        $downloaded = Get-Item -LiteralPath $temporaryArchive
        if ($downloaded.Length -ne $expectedSize) {
            throw 'Downloaded update size does not match the release metadata.'
        }
        $actualHash = (Get-FileHash -LiteralPath $temporaryArchive -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actualHash -ne $expectedHash) {
            throw 'Downloaded update failed SHA-256 verification.'
        }
        Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
        Write-UpdateStatus -Status 'applying' -TargetVersion $targetVersion -Message 'Update is ready to install.'

        $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:Context.UpdaterPath)`" " +
            "-ArchivePath `"$archivePath`" -InstallDirectory `"$($script:Context.BaseDirectory)`" " +
            "-ExpectedVersion `"$targetVersion`" -ExpectedSha256 `"$expectedHash`" -WorkerProcessId $PID"
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden
        Write-WorkerLog -Level 'info' -EventName 'update_started' -Data @{ version = $targetVersion; sha256 = $expectedHash }
        $script:StopRequested = $true
    }
    catch {
        Write-UpdateStatus -Status 'failed' -TargetVersion $targetVersion -Message $_.Exception.Message
        Write-WorkerLog -Level 'error' -EventName 'update_failed' -Data @{ version = $targetVersion; message = $_.Exception.Message }
    }
}

function Save-FeatureState {
    param(
        [bool]$ScheduleEnabled,
        [bool]$RobotEnabled
    )

    $config = Read-JsonFile -Path $script:Context.ConfigPath
    $config.features.scheduleEnabled = $ScheduleEnabled
    $config.features.robotEnabled = $RobotEnabled
    $temporaryPath = "$($script:Context.ConfigPath).tmp-$PID"
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:Context.ConfigPath -Force
    $script:Context.Config = $config
}

function Assert-ReadOnlyMappingSql {
    param(
        [string]$Sql,
        [string]$Label
    )

    $raw = [string]$Sql
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "$Label is empty."
    }
    if ($raw.Length -gt 20000) {
        throw "$Label is too long."
    }
    $normalized = [regex]::Replace($raw, '(?s)/\*.*?\*/', ' ')
    $normalized = [regex]::Replace($normalized, '(?m)--.*$', ' ').Trim()
    if ($normalized -notmatch '(?i)^(select|with)\b') {
        throw "$Label must start with SELECT or WITH."
    }
    if ($normalized.Contains(';')) {
        throw "$Label must contain one statement without semicolons."
    }
    if ($normalized -match '(?i)\b(insert|update|delete|merge|drop|alter|truncate|create|exec|execute|grant|revoke|backup|restore)\b') {
        throw "$Label contains a forbidden SQL keyword."
    }
    return $raw.Trim()
}

function Save-ScheduleMapping {
    param(
        [object]$Mapping,
        [string]$Revision
    )

    if ($null -eq $Mapping) {
        throw 'Remote schedule mapping is empty.'
    }
    $normalized = [ordered]@{
        doctorsSql = Assert-ReadOnlyMappingSql -Sql ([string]$Mapping.doctorsSql) -Label 'doctorsSql'
        branchesSql = Assert-ReadOnlyMappingSql -Sql ([string]$Mapping.branchesSql) -Label 'branchesSql'
        intervalsSql = Assert-ReadOnlyMappingSql -Sql ([string]$Mapping.intervalsSql) -Label 'intervalsSql'
        notes = @(
            if ($Mapping.PSObject.Properties.Name -contains 'notes') {
                @($Mapping.notes | Select-Object -First 20 | ForEach-Object { ([string]$_).Substring(0, [Math]::Min(([string]$_).Length, 500)) })
            }
        )
    }
    $directory = Split-Path -Parent $script:Context.MappingPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporaryPath = "$($script:Context.MappingPath).tmp-$PID"
    $normalized | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:Context.MappingPath -Force
    $script:State.schedule.mappingRevision = $Revision
    $script:State.schedule.mappingConfigured = $true
    $script:State.schedule.state = 'starting'
    $script:State.schedule.lastError = ''
    New-Item -ItemType File -Force -Path (Join-Path $script:Context.CommandDirectory 'send-now') | Out-Null
    Write-WorkerLog -Level 'info' -EventName 'schedule_mapping_applied' -Data @{ revision = $Revision }
}

function Test-ScheduleMappingConfigured {
    if (-not (Test-Path -LiteralPath $script:Context.MappingPath)) {
        return $false
    }
    try {
        $mapping = Read-JsonFile -Path $script:Context.MappingPath
        foreach ($property in @('doctorsSql', 'branchesSql', 'intervalsSql')) {
            if (
                $mapping.PSObject.Properties.Name -notcontains $property -or
                [string]::IsNullOrWhiteSpace([string]$mapping.$property)
            ) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Read-RobotReceipts {
    if (-not (Test-Path -LiteralPath $script:Context.RobotReceiptsPath)) {
        return [pscustomobject]@{ version = 1; receipts = @() }
    }
    try {
        $data = Read-JsonFile -Path $script:Context.RobotReceiptsPath
        if ($data.PSObject.Properties.Name -notcontains 'receipts') {
            return [pscustomobject]@{ version = 1; receipts = @() }
        }
        return $data
    }
    catch {
        Write-WorkerLog -Level 'error' -EventName 'robot_receipts_read_failed' -Data @{ message = $_.Exception.Message }
        return [pscustomobject]@{ version = 1; receipts = @() }
    }
}

function Get-RobotReceipt {
    param(
        [string]$Id,
        [string]$Fingerprint
    )

    $data = Read-RobotReceipts
    return @($data.receipts | Where-Object {
        [string]$_.id -eq $Id -and [string]$_.fingerprint -eq $Fingerprint
    } | Select-Object -First 1)
}

function Save-RobotReceipt {
    param(
        [string]$Id,
        [string]$Fingerprint,
        [string]$CompletedAt
    )

    $data = Read-RobotReceipts
    $receipts = @($data.receipts | Where-Object {
        -not ([string]$_.id -eq $Id -and [string]$_.fingerprint -eq $Fingerprint)
    })
    $receipts += [pscustomobject]@{
        id = $Id
        fingerprint = $Fingerprint
        completedAt = $CompletedAt
    }
    $receipts = @($receipts | Sort-Object completedAt -Descending | Select-Object -First 500)
    $payload = [ordered]@{
        version = 1
        updatedAt = (Get-Date).ToString('o')
        receipts = $receipts
    }
    $temporaryPath = "$($script:Context.RobotReceiptsPath).tmp-$PID"
    $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:Context.RobotReceiptsPath -Force
}

function Apply-DesiredState {
    param([object]$Desired)

    if ($null -eq $Desired) {
        return
    }
    $scheduleEnabled = [bool]$script:State.schedule.enabled
    $robotEnabled = [bool]$script:State.robot.enabled
    if ($Desired.PSObject.Properties.Name -contains 'scheduleEnabled') {
        $scheduleEnabled = [bool]$Desired.scheduleEnabled
    }
    if ($Desired.PSObject.Properties.Name -contains 'robotEnabled') {
        $robotEnabled = [bool]$Desired.robotEnabled
    }
    if (
        $scheduleEnabled -ne [bool]$script:State.schedule.enabled -or
        $robotEnabled -ne [bool]$script:State.robot.enabled
    ) {
        Save-FeatureState -ScheduleEnabled $scheduleEnabled -RobotEnabled $robotEnabled
    }
    $script:State.schedule.enabled = $scheduleEnabled
    $script:State.robot.enabled = $robotEnabled

    if (
        $Desired.PSObject.Properties.Name -contains 'scheduleRequestRevision' -and
        -not [string]::IsNullOrWhiteSpace([string]$Desired.scheduleRequestRevision) -and
        [string]$Desired.scheduleRequestRevision -ne [string]$script:State.schedule.requestRevision
    ) {
        $script:State.schedule.requestRevision = [string]$Desired.scheduleRequestRevision
        New-Item -ItemType File -Force -Path (Join-Path $script:Context.CommandDirectory 'send-now') | Out-Null
    }

    if (
        $Desired.PSObject.Properties.Name -contains 'scheduleMapping' -and
        $Desired.PSObject.Properties.Name -contains 'mappingRevision' -and
        $null -ne $Desired.scheduleMapping -and
        -not [string]::IsNullOrWhiteSpace([string]$Desired.mappingRevision) -and
        [string]$Desired.mappingRevision -ne [string]$script:State.schedule.mappingRevision
    ) {
        try {
            Save-ScheduleMapping -Mapping $Desired.scheduleMapping -Revision ([string]$Desired.mappingRevision)
        }
        catch {
            $script:State.schedule.state = 'mapping_error'
            $script:State.schedule.lastError = $_.Exception.Message
            Write-WorkerLog -Level 'error' -EventName 'schedule_mapping_rejected' -Data @{ message = $_.Exception.Message }
        }
    }

    if ($Desired.PSObject.Properties.Name -contains 'update') {
        Request-AgentUpdate -Update $Desired.update
    }
}

function Send-Heartbeat {
    $payload = [ordered]@{
        agentId = [string]$script:Context.Config.agent.id
        deviceName = $env:COMPUTERNAME
        version = [string]$script:Context.Config.agent.version
        startedAt = $script:State.worker.startedAt
        status = 'online'
        schedule = $script:State.schedule
        schema = $script:State.schema
        robot = $script:State.robot
        system = [ordered]@{
            processId = $PID
            windowsVersion = [Environment]::OSVersion.VersionString
        }
    }

    try {
        $response = Invoke-AgentRequest -Method POST -Path '/api/agent/heartbeat' -Body $payload
        $script:State.worker.backendOnline = $true
        $script:State.worker.lastHeartbeatAt = (Get-Date).ToString('o')
        $script:State.worker.lastError = ''
        Apply-DesiredState -Desired $response.desired
    }
    catch {
        $script:State.worker.backendOnline = $false
        $script:State.worker.lastError = $_.Exception.Message
        Write-WorkerLog -Level 'error' -EventName 'heartbeat_failed' -Data @{ message = $_.Exception.Message }
    }
    Write-RuntimeState
}

function Invoke-SchemaUpload {
    if (-not (Test-Path -LiteralPath $script:Context.SchemaPath)) {
        $script:State.schema.state = 'not_available'
        $script:State.schema.lastError = ''
        Write-RuntimeState
        return
    }

    $script:State.schema.state = 'sending'
    $script:State.schema.lastAttemptAt = (Get-Date).ToString('o')
    $script:State.schema.lastError = ''
    Write-RuntimeState

    try {
        $schema = Read-JsonFile -Path $script:Context.SchemaPath
        $response = Invoke-AgentRequest -Method POST -Path '/api/agent/schema' -Body @{
            agentId = [string]$script:Context.Config.agent.id
            schema = $schema
        }
        $script:State.schema.state = 'ok'
        $script:State.schema.lastSuccessAt = (Get-Date).ToString('o')
        $script:State.schema.lastError = ''
        $script:State.schema.tables = [int]$response.summary.tables
        $script:State.schema.columns = [int]$response.summary.columns
    }
    catch {
        $script:State.schema.state = 'error'
        $script:State.schema.lastError = $_.Exception.Message
        Write-WorkerLog -Level 'error' -EventName 'schema_upload_failed' -Data @{ message = $_.Exception.Message }
    }
    Write-RuntimeState
}

function Invoke-SchedulePush {
    $mappingConfigured = Test-ScheduleMappingConfigured
    $script:State.schedule.mappingConfigured = $mappingConfigured
    if (-not $mappingConfigured) {
        $script:State.schedule.state = 'needs_mapping'
        $script:State.schedule.lastError = ''
        Write-RuntimeState
        return
    }

    $script:State.schedule.state = 'sending'
    $script:State.schedule.lastAttemptAt = (Get-Date).ToString('o')
    $script:State.schedule.lastError = ''
    Write-RuntimeState

    $agentScript = Join-Path $script:Context.BaseDirectory 'IdentAgent.ps1'
    $output = & powershell.exe `
        -NoProfile `
        -WindowStyle Hidden `
        -ExecutionPolicy Bypass `
        -File $agentScript `
        -ConfigPath $script:Context.ConfigPath `
        -Push 2>&1 | Out-String
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $message = ($output.Trim() -split '\r?\n' | Select-Object -Last 1)
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "Schedule process exited with code $exitCode."
        }
        $script:State.schedule.state = 'error'
        $script:State.schedule.lastError = $message
        Write-WorkerLog -Level 'error' -EventName 'schedule_failed' -Data @{ message = $message; exitCode = $exitCode }
        Write-RuntimeState
        return
    }

    $result = if (Test-Path -LiteralPath $script:Context.PushResultPath) {
        Read-JsonFile -Path $script:Context.PushResultPath
    } else {
        $null
    }
    $script:State.schedule.state = 'ok'
    $script:State.schedule.lastSuccessAt = (Get-Date).ToString('o')
    $script:State.schedule.lastError = ''
    if ($null -ne $result) {
        $script:State.schedule.doctors = [int]$result.doctors
        $script:State.schedule.branches = [int]$result.branches
        $script:State.schedule.intervals = [int]$result.intervals
        $script:State.schedule.freeIntervals = [int]$result.freeIntervals
        $script:State.schedule.busyIntervals = [int]$result.busyIntervals
    }
    Write-RuntimeState
}

function Get-RobotConfigurationProblem {
    if (-not (Test-Path -LiteralPath $script:Context.RobotConfigPath)) {
        return 'Robot configuration file was not found.'
    }
    try {
        $config = Read-JsonFile -Path $script:Context.RobotConfigPath
        if (-not [bool]$config.workflow.allowUnsafeExecution) {
            return 'Real robot execution is not allowed in robot configuration.'
        }
        if ([bool]$config.workflow.confirmBeforeEachStep) {
            return 'Interactive confirmation must be disabled for background execution.'
        }
        foreach ($step in @($config.workflow.steps)) {
            $selector = $config.selectors.([string]$step.selector)
            if ($null -eq $selector) {
                return "Selector '$($step.selector)' is missing."
            }
            $values = @(@(
                    [string]$selector.name,
                    [string]$selector.automationId,
                    [string]$selector.className,
                    [string]$selector.controlType
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($values.Count -eq 0) {
                return "Selector '$($step.selector)' is empty."
            }
        }
        if ($config.workflow.PSObject.Properties.Name -notcontains 'successCondition') {
            return 'Robot success condition is missing.'
        }
        $successCondition = $config.workflow.successCondition
        if ([string]$successCondition.type -notin @('elementPresent', 'elementMissing')) {
            return 'Robot success condition type is invalid.'
        }
        $successSelector = $config.selectors.([string]$successCondition.selector)
        if ($null -eq $successSelector) {
            return "Success selector '$($successCondition.selector)' is missing."
        }
        $successValues = @(@(
                [string]$successSelector.name,
                [string]$successSelector.automationId,
                [string]$successSelector.className,
                [string]$successSelector.controlType
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($successValues.Count -eq 0) {
            return "Success selector '$($successCondition.selector)' is empty."
        }
        return ''
    }
    catch {
        return $_.Exception.Message
    }
}

function Test-RobotConfigured {
    return [string]::IsNullOrWhiteSpace((Get-RobotConfigurationProblem))
}

function Invoke-RobotPoll {
    $configurationProblem = Get-RobotConfigurationProblem
    $configured = [string]::IsNullOrWhiteSpace($configurationProblem)
    $script:State.robot.configured = $configured
    $script:State.robot.lastAttemptAt = (Get-Date).ToString('o')
    if (-not $configured) {
        $script:State.robot.state = 'needs_configuration'
        $script:State.robot.lastError = $configurationProblem
        Write-RuntimeState
        return
    }

    $script:State.robot.state = 'checking'
    $script:State.robot.lastError = ''
    Write-RuntimeState

    $record = $null
    $localExecutionSucceeded = $false
    try {
        $claim = Invoke-AgentRequest -Method POST -Path '/api/robot/tasks/claim' -Body @{
            agentId = [string]$script:Context.Config.agent.id
        }
        if ($null -eq $claim.record) {
            $script:State.robot.state = 'idle'
            Write-RuntimeState
            return
        }

        $record = $claim.record
        $script:State.robot.state = 'processing'
        $script:State.robot.lastTaskId = [string]$record.id
        Write-RuntimeState

        $fingerprint = [string]$record.fingerprint
        $receipt = Get-RobotReceipt -Id ([string]$record.id) -Fingerprint $fingerprint
        if ($null -ne $receipt) {
            [void](Invoke-AgentRequest -Method POST -Path '/api/robot/tasks/complete' -Body @{
                id = [string]$record.id
                agentId = [string]$script:Context.Config.agent.id
                result = @{
                    appointmentCreated = $true
                    recoveredFromLocalReceipt = $true
                    completedAt = [string]$receipt.completedAt
                }
            })
            $script:State.robot.state = 'idle'
            $script:State.robot.lastSuccessAt = [string]$receipt.completedAt
            $script:State.robot.lastError = ''
            Write-WorkerLog -Level 'info' -EventName 'robot_task_recovered' -Data @{ id = [string]$record.id }
            Write-RuntimeState
            return
        }

        New-Item -ItemType Directory -Force -Path $script:Context.CommandDirectory | Out-Null
        $taskPath = Join-Path $script:Context.CommandDirectory 'robot-task.json'
        $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $taskPath -Encoding UTF8
        $robotScript = Join-Path $script:Context.BaseDirectory 'robot\Start-IdentRobot.ps1'
        try {
            $output = & powershell.exe `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File $robotScript `
                -Mode RunOnce `
                -ConfigPath $script:Context.RobotConfigPath `
                -TaskFile $taskPath `
                -MaxTasks 1 `
                -Execute 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
        finally {
            if (Test-Path -LiteralPath $taskPath) {
                Remove-Item -LiteralPath $taskPath -Force
            }
        }

        if ($exitCode -ne 0) {
            $message = ($output.Trim() -split '\r?\n' | Select-Object -Last 1)
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = "Robot process exited with code $exitCode."
            }
            throw $message
        }

        $completedAt = (Get-Date).ToString('o')
        Save-RobotReceipt `
            -Id ([string]$record.id) `
            -Fingerprint $fingerprint `
            -CompletedAt $completedAt
        $localExecutionSucceeded = $true
        [void](Invoke-AgentRequest -Method POST -Path '/api/robot/tasks/complete' -Body @{
            id = [string]$record.id
            agentId = [string]$script:Context.Config.agent.id
            result = @{
                appointmentCreated = $true
                completedAt = $completedAt
            }
        })
        $script:State.robot.state = 'idle'
        $script:State.robot.lastSuccessAt = $completedAt
        $script:State.robot.lastError = ''
        Write-WorkerLog -Level 'info' -EventName 'robot_task_completed' -Data @{ id = [string]$record.id }
    }
    catch {
        $message = $_.Exception.Message
        $script:State.robot.state = if ($localExecutionSucceeded) { 'awaiting_confirmation' } else { 'error' }
        $script:State.robot.lastError = $message
        if ($null -ne $record -and -not $localExecutionSucceeded) {
            try {
                [void](Invoke-AgentRequest -Method POST -Path '/api/robot/tasks/fail' -Body @{
                    id = [string]$record.id
                    agentId = [string]$script:Context.Config.agent.id
                    error = $message
                })
            }
            catch {
                Write-WorkerLog -Level 'error' -EventName 'robot_fail_report_failed' -Data @{ message = $_.Exception.Message }
            }
        }
        Write-WorkerLog -Level 'error' -EventName 'robot_task_failed' -Data @{ message = $message }
    }
    Write-RuntimeState
}

$script:Context = $null
$script:State = $null
$script:StopRequested = $false
$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\Code9IdentAgentWorker', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    $script:Context = Get-ConfigContext
    New-Item -ItemType Directory -Force -Path $script:Context.CommandDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $script:Context.UpdateDirectory | Out-Null
    $previousUpdate = $null
    if (Test-Path -LiteralPath $script:Context.UpdateStatusPath) {
        try {
            $previousUpdate = Read-JsonFile -Path $script:Context.UpdateStatusPath
        }
        catch {
            $previousUpdate = $null
        }
    }
    $script:State = [ordered]@{
        version = [string]$script:Context.Config.agent.version
        agentId = [string]$script:Context.Config.agent.id
        worker = [ordered]@{
            processId = $PID
            startedAt = (Get-Date).ToString('o')
            backendOnline = $false
            lastHeartbeatAt = $null
            lastError = ''
        }
        schedule = [ordered]@{
            enabled = [bool]$script:Context.Config.features.scheduleEnabled
            state = 'starting'
            mappingConfigured = Test-ScheduleMappingConfigured
            mappingRevision = ''
            requestRevision = ''
            lastAttemptAt = $null
            lastSuccessAt = $null
            lastError = ''
            doctors = 0
            branches = 0
            intervals = 0
            freeIntervals = 0
            busyIntervals = 0
        }
        schema = [ordered]@{
            state = 'starting'
            lastAttemptAt = $null
            lastSuccessAt = $null
            lastError = ''
            tables = 0
            columns = 0
        }
        robot = [ordered]@{
            enabled = [bool]$script:Context.Config.features.robotEnabled
            configured = Test-RobotConfigured
            state = 'disabled'
            lastAttemptAt = $null
            lastSuccessAt = $null
            lastTaskId = ''
            lastError = ''
        }
        update = [ordered]@{
            targetVersion = $(if ($null -ne $previousUpdate) { [string]$previousUpdate.targetVersion } else { '' })
            currentVersion = [string]$script:Context.Config.agent.version
            status = $(if ($null -ne $previousUpdate) { [string]$previousUpdate.status } else { 'idle' })
            message = $(if ($null -ne $previousUpdate) { [string]$previousUpdate.message } else { '' })
            updatedAt = $(if ($null -ne $previousUpdate) { [string]$previousUpdate.updatedAt } else { $null })
        }
        updatedAt = (Get-Date).ToString('o')
    }

    Write-WorkerLog -Level 'info' -EventName 'worker_started' -Data @{
        agentId = [string]$script:Context.Config.agent.id
        processId = $PID
    }
    Write-RuntimeState

    $nextHeartbeat = [DateTime]::MinValue
    $nextSchedule = [DateTime]::MinValue
    $nextSchema = [DateTime]::MinValue
    $nextRobot = [DateTime]::MinValue

    while (-not $script:StopRequested) {
        $now = Get-Date
        $sendNowPath = Join-Path $script:Context.CommandDirectory 'send-now'
        if (Test-Path -LiteralPath $sendNowPath) {
            Remove-Item -LiteralPath $sendNowPath -Force
            $nextSchedule = [DateTime]::MinValue
        }

        if ($now -ge $nextHeartbeat) {
            Send-Heartbeat
            $nextHeartbeat = $now.AddSeconds([Math]::Max(30, [int]$script:Context.Config.intervals.heartbeatSeconds))
            if ($script:StopRequested) {
                break
            }
        }

        if ($now -ge $nextSchema) {
            Invoke-SchemaUpload
            $schemaSeconds = if ($script:Context.Config.intervals.PSObject.Properties.Name -contains 'schemaSeconds') {
                [int]$script:Context.Config.intervals.schemaSeconds
            } else {
                600
            }
            $nextSchema = $now.AddSeconds([Math]::Max(300, $schemaSeconds))
            $nextHeartbeat = [DateTime]::MinValue
        }

        if ([bool]$script:State.schedule.enabled -and $now -ge $nextSchedule) {
            Invoke-SchedulePush
            $nextSchedule = $now.AddSeconds([Math]::Max(60, [int]$script:Context.Config.intervals.scheduleSeconds))
            $nextHeartbeat = [DateTime]::MinValue
        }
        elseif (-not [bool]$script:State.schedule.enabled) {
            $script:State.schedule.state = 'disabled'
        }

        if ([bool]$script:State.robot.enabled -and $now -ge $nextRobot) {
            Invoke-RobotPoll
            $nextRobot = $now.AddSeconds([Math]::Max(15, [int]$script:Context.Config.intervals.robotSeconds))
            $nextHeartbeat = [DateTime]::MinValue
        }
        elseif (-not [bool]$script:State.robot.enabled) {
            $script:State.robot.state = 'disabled'
            $script:State.robot.lastError = ''
        }

        Write-RuntimeState
        Start-Sleep -Seconds 2
    }
}
catch {
    if ($null -ne $script:Context) {
        Write-WorkerLog -Level 'error' -EventName 'worker_stopped' -Data @{ message = $_.Exception.Message }
    }
    exit 1
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
