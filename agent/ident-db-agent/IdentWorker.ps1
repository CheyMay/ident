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
        LogPath = Resolve-LocalPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.log)
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
}

function Send-Heartbeat {
    $payload = [ordered]@{
        agentId = [string]$script:Context.Config.agent.id
        deviceName = $env:COMPUTERNAME
        version = [string]$script:Context.Config.agent.version
        startedAt = $script:State.worker.startedAt
        status = 'online'
        schedule = $script:State.schedule
        robot = $script:State.robot
        system = [ordered]@{
            user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
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

function Invoke-SchedulePush {
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

function Test-RobotConfigured {
    if (-not (Test-Path -LiteralPath $script:Context.RobotConfigPath)) {
        return $false
    }
    try {
        $config = Read-JsonFile -Path $script:Context.RobotConfigPath
        if (-not [bool]$config.workflow.allowUnsafeExecution) {
            return $false
        }
        if ([bool]$config.workflow.confirmBeforeEachStep) {
            return $false
        }
        foreach ($step in @($config.workflow.steps)) {
            $selector = $config.selectors.([string]$step.selector)
            if ($null -eq $selector) {
                return $false
            }
            $values = @(
                [string]$selector.name,
                [string]$selector.automationId,
                [string]$selector.className,
                [string]$selector.controlType
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            if ($values.Count -eq 0) {
                return $false
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Invoke-RobotPoll {
    $configured = Test-RobotConfigured
    $script:State.robot.configured = $configured
    $script:State.robot.lastAttemptAt = (Get-Date).ToString('o')
    if (-not $configured) {
        $script:State.robot.state = 'needs_configuration'
        $script:State.robot.lastError = 'Robot UI selectors are not configured.'
        Write-RuntimeState
        return
    }

    $script:State.robot.state = 'checking'
    $script:State.robot.lastError = ''
    Write-RuntimeState

    $record = $null
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

        [void](Invoke-AgentRequest -Method POST -Path '/api/robot/tasks/complete' -Body @{
            id = [string]$record.id
            agentId = [string]$script:Context.Config.agent.id
            result = @{
                appointmentCreated = $true
                completedAt = (Get-Date).ToString('o')
            }
        })
        $script:State.robot.state = 'idle'
        $script:State.robot.lastSuccessAt = (Get-Date).ToString('o')
        $script:State.robot.lastError = ''
        Write-WorkerLog -Level 'info' -EventName 'robot_task_completed' -Data @{ id = [string]$record.id }
    }
    catch {
        $message = $_.Exception.Message
        $script:State.robot.state = 'error'
        $script:State.robot.lastError = $message
        if ($null -ne $record) {
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
$createdNew = $false
$mutex = New-Object Threading.Mutex($true, 'Local\Code9IdentAgentWorker', [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    $script:Context = Get-ConfigContext
    New-Item -ItemType Directory -Force -Path $script:Context.CommandDirectory | Out-Null
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
            lastAttemptAt = $null
            lastSuccessAt = $null
            lastError = ''
            doctors = 0
            branches = 0
            intervals = 0
            freeIntervals = 0
            busyIntervals = 0
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
        updatedAt = (Get-Date).ToString('o')
    }

    Write-WorkerLog -Level 'info' -EventName 'worker_started' -Data @{
        agentId = [string]$script:Context.Config.agent.id
        processId = $PID
    }
    Write-RuntimeState

    $nextHeartbeat = [DateTime]::MinValue
    $nextSchedule = [DateTime]::MinValue
    $nextRobot = [DateTime]::MinValue

    while ($true) {
        $now = Get-Date
        $sendNowPath = Join-Path $script:Context.CommandDirectory 'send-now'
        if (Test-Path -LiteralPath $sendNowPath) {
            Remove-Item -LiteralPath $sendNowPath -Force
            $nextSchedule = [DateTime]::MinValue
        }

        if ($now -ge $nextHeartbeat) {
            Send-Heartbeat
            $nextHeartbeat = $now.AddSeconds([Math]::Max(30, [int]$script:Context.Config.intervals.heartbeatSeconds))
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
