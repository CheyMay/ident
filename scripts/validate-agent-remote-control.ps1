[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ident-agent-remote-{0}" -f [Guid]::NewGuid().ToString('N'))
$agentRoot = Join-Path $testRoot 'agent'
$dataRoot = Join-Path $testRoot 'server-data'
$port = Get-Random -Minimum 48000 -Maximum 56000
$baseUrl = "http://127.0.0.1:$port"
$agentId = "remote-control-test-{0}" -f [Guid]::NewGuid().ToString('N').Substring(0, 8)
$agentKey = "agent-{0}" -f [Guid]::NewGuid().ToString('N')
$serviceKey = "service-{0}" -f [Guid]::NewGuid().ToString('N')
$serverProcess = $null
$workerProcess = $null
$restartedWorkerId = 0
$previousServerEnvironment = @{}
$serverEnvironmentApplied = $false
$testSucceeded = $false

function Invoke-TestApi {
    param(
        [ValidateSet('GET', 'POST')]
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )

    $parameters = @{
        Uri = "$baseUrl$Path"
        Method = $Method
        Headers = $Headers
        TimeoutSec = 10
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    return Invoke-RestMethod @parameters
}

function Wait-ForCondition {
    param(
        [scriptblock]$Condition,
        [string]$FailureMessage,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $value = & $Condition
            if ($value) { return $value }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw $FailureMessage
}

try {
    New-Item -ItemType Directory -Force -Path $agentRoot, $dataRoot | Out-Null
    foreach ($file in @('IdentAgent.ps1', 'IdentWorker.ps1', 'Apply-IdentAgentUpdate.ps1')) {
        Copy-Item -LiteralPath (Join-Path $root "agent\ident-db-agent\$file") -Destination $agentRoot
    }

    $configPath = Join-Path $agentRoot 'config.local.json'
    $secretsPath = Join-Path $agentRoot 'secrets.local.json'
    $runtimePath = Join-Path $agentRoot 'runtime-state.json'
    $controlPath = Join-Path $agentRoot 'remote-control-state.json'
    $config = [ordered]@{
        version = 2
        agent = [ordered]@{ id = $agentId; version = '2.6.0-test' }
        features = [ordered]@{ scheduleEnabled = $false; robotEnabled = $false }
        intervals = [ordered]@{
            heartbeatSeconds = 30
            scheduleSeconds = 600
            schemaSeconds = 600
            robotSeconds = 30
        }
        sql = [ordered]@{
            server = '127.0.0.1'
            instanceName = ''
            port = 0
            dataSource = '127.0.0.1'
            database = 'BEFORE_REMOTE_CHANGE'
            user = 'readonly_user'
            encrypt = $false
            trustServerCertificate = $true
            connectTimeoutSeconds = 2
            commandTimeoutSeconds = 2
        }
        backend = [ordered]@{ baseUrl = $baseUrl; timeoutSeconds = 10 }
        paths = [ordered]@{
            secrets = 'secrets.local.json'
            mapping = 'mapping.local.json'
            schemaOutput = 'schema-inventory.json'
            log = 'logs\agent.log'
            pushResult = 'last-push-result.json'
            runtimeState = 'runtime-state.json'
            remoteControlState = 'remote-control-state.json'
            commandDirectory = 'commands'
            robotConfig = 'robot\config.local.json'
            robotReceipts = 'robot-receipts.json'
            updateDirectory = 'updates'
            updateStatus = 'update-status.json'
        }
    }
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $configPath -Encoding UTF8

    $encryptedAgentKey = ConvertTo-SecureString -String $agentKey -AsPlainText -Force | ConvertFrom-SecureString
    $encryptedSqlPassword = ConvertTo-SecureString -String 'integration-test-password' -AsPlainText -Force | ConvertFrom-SecureString
    [ordered]@{
        agentApiKeyDpapi = $encryptedAgentKey
        sqlPasswordDpapi = $encryptedSqlPassword
    } | ConvertTo-Json | Set-Content -LiteralPath $secretsPath -Encoding UTF8

    $serverInfo = New-Object Diagnostics.ProcessStartInfo
    $serverInfo.FileName = 'node.exe'
    $serverInfo.Arguments = 'src/index.js'
    $serverInfo.WorkingDirectory = $root
    $serverInfo.UseShellExecute = $false
    $serverInfo.CreateNoWindow = $true
    $serverInfo.RedirectStandardOutput = $true
    $serverInfo.RedirectStandardError = $true
    $serverEnvironment = @{
        PORT = [string]$port
        DATA_DIR = $dataRoot
        STORAGE_DRIVER = 'json'
        JOB_WORKER_ENABLED = 'false'
        AGENT_API_KEY = $agentKey
        SERVICE_API_KEY = $serviceKey
        IDENT_INTEGRATION_KEY = 'integration-test-ident-key'
    }
    foreach ($name in $serverEnvironment.Keys) {
        $previousServerEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$serverEnvironment[$name], 'Process')
    }
    $serverEnvironmentApplied = $true
    $serverProcess = [Diagnostics.Process]::Start($serverInfo)
    $serverProcess.BeginOutputReadLine()
    $serverProcess.BeginErrorReadLine()
    foreach ($name in $serverEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousServerEnvironment[$name], 'Process')
    }
    $serverEnvironmentApplied = $false

    [void](Wait-ForCondition -TimeoutSeconds 15 -FailureMessage 'Temporary backend did not become healthy.' -Condition {
        $health = Invoke-TestApi -Method GET -Path '/health'
        return $health.ok -eq $true
    })

    $serviceHeaders = @{ 'X-API-Key' = $serviceKey }
    [void](Invoke-TestApi -Method POST -Path '/api/agent/settings' -Headers $serviceHeaders -Body @{
        agentId = $agentId
        requestDiagnosticsNow = $true
        requestRestart = $true
        sqlConfiguration = @{
            dataSource = 'tcp:127.0.0.1,51433'
            database = 'IDENT_REMOTE_TEST'
        }
    })

    $workerInfo = New-Object Diagnostics.ProcessStartInfo
    $workerInfo.FileName = 'powershell.exe'
    $workerInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$agentRoot\IdentWorker.ps1`" -ConfigPath `"$configPath`""
    $workerInfo.WorkingDirectory = $agentRoot
    $workerInfo.UseShellExecute = $false
    $workerInfo.CreateNoWindow = $true
    $workerProcess = [Diagnostics.Process]::Start($workerInfo)
    $initialWorkerId = $workerProcess.Id

    [void](Wait-ForCondition -TimeoutSeconds 20 -FailureMessage 'Remote SQL configuration was not applied.' -Condition {
        if (-not (Test-Path -LiteralPath $configPath)) { return $false }
        $current = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$current.sql.dataSource -eq 'tcp:127.0.0.1,51433' -and [string]$current.sql.database -eq 'IDENT_REMOTE_TEST'
    })

    $report = Wait-ForCondition -TimeoutSeconds 20 -FailureMessage 'Agent diagnostics were not uploaded.' -Condition {
        try {
            return Invoke-TestApi -Method GET -Path ("/api/agent/diagnostics?agentId={0}" -f [Uri]::EscapeDataString($agentId)) -Headers $serviceHeaders
        }
        catch { return $null }
    }
    if ([string]$report.sql.dataSource -ne 'tcp:127.0.0.1,51433') {
        throw 'Diagnostic report contains an unexpected SQL data source.'
    }
    $serializedReport = $report | ConvertTo-Json -Depth 20 -Compress
    if ($serializedReport -match 'integration-test-password' -or $serializedReport -match [Regex]::Escape($agentKey)) {
        throw 'Diagnostic report exposed a protected secret.'
    }

    $restartedWorkerId = [int](Wait-ForCondition -TimeoutSeconds 25 -FailureMessage 'Agent did not restart after the remote command.' -Condition {
        if (-not (Test-Path -LiteralPath $runtimePath)) { return 0 }
        try {
            $state = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $workerId = [int]$state.worker.processId
            if ($workerId -gt 0 -and $workerId -ne $initialWorkerId -and $state.worker.backendOnline -eq $true) {
                return $workerId
            }
        }
        catch {}
        return 0
    })

    $control = Get-Content -LiteralPath $controlPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @('diagnosticsRequestRevision', 'sqlConfigurationRevision', 'restartRequestRevision')) {
        if ([string]::IsNullOrWhiteSpace([string]$control.$name)) {
            throw "Remote control revision was not persisted: $name"
        }
    }

    $status = Invoke-TestApi -Method GET -Path '/api/agent/status' -Headers $serviceHeaders
    $agentStatus = @($status.agents | Where-Object { [string]$_.agentId -eq $agentId } | Select-Object -First 1)
    if ($agentStatus.Count -ne 1 -or $agentStatus[0].online -ne $true) {
        throw 'Restarted agent is not online in backend status.'
    }

    $testSucceeded = $true
    Write-Host "REMOTE CONTROL CHECK OK: agent=$agentId initialPid=$initialWorkerId restartedPid=$restartedWorkerId"
}
finally {
    if ($serverEnvironmentApplied) {
        foreach ($name in $previousServerEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousServerEnvironment[$name], 'Process')
        }
    }
    foreach ($processId in @($restartedWorkerId, $(if ($null -ne $workerProcess) { $workerProcess.Id } else { 0 }))) {
        if ([int]$processId -gt 0) {
            Stop-Process -Id ([int]$processId) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill()
        [void]$serverProcess.WaitForExit(5000)
    }
    if (
        $testSucceeded -and
        (Test-Path -LiteralPath $testRoot) -and
        [IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    elseif (Test-Path -LiteralPath $testRoot) {
        Write-Warning "Remote control test data kept for inspection: $testRoot"
    }
}
