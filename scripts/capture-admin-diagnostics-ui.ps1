[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $root 'admin\ident-admin-desktop\dist\admin-diagnostics-ui.png'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("ident-admin-ui-{0}" -f [Guid]::NewGuid().ToString('N'))
$installRoot = Join-Path $testRoot 'admin'
$dataRoot = Join-Path $testRoot 'server-data'
$port = Get-Random -Minimum 56001 -Maximum 62000
$baseUrl = "http://127.0.0.1:$port"
$agentKey = "agent-{0}" -f [Guid]::NewGuid().ToString('N')
$serviceKey = "service-{0}" -f [Guid]::NewGuid().ToString('N')
$serverProcess = $null
$adminProcess = $null
$previousEnvironment = @{}

function Invoke-TestApi {
    param(
        [ValidateSet('GET', 'POST')][string]$Method,
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
        $parameters.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
    }
    return Invoke-RestMethod @parameters
}

try {
    New-Item -ItemType Directory -Force -Path $testRoot, $dataRoot, (Split-Path -Parent $OutputPath) | Out-Null
    $serverEnvironment = @{
        PORT = [string]$port
        DATA_DIR = $dataRoot
        STORAGE_DRIVER = 'json'
        JOB_WORKER_ENABLED = 'false'
        AGENT_API_KEY = $agentKey
        SERVICE_API_KEY = $serviceKey
        IDENT_INTEGRATION_KEY = 'ui-test-ident-key'
    }
    foreach ($name in $serverEnvironment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$serverEnvironment[$name], 'Process')
    }
    $serverInfo = New-Object Diagnostics.ProcessStartInfo
    $serverInfo.FileName = 'node.exe'
    $serverInfo.Arguments = 'src/index.js'
    $serverInfo.WorkingDirectory = $root
    $serverInfo.UseShellExecute = $false
    $serverInfo.CreateNoWindow = $true
    $serverProcess = [Diagnostics.Process]::Start($serverInfo)
    foreach ($name in $serverEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }

    $deadline = (Get-Date).AddSeconds(15)
    do {
        try { $healthy = (Invoke-TestApi -Method GET -Path '/health').ok -eq $true } catch { $healthy = $false }
        if (-not $healthy) { Start-Sleep -Milliseconds 300 }
    } while (-not $healthy -and (Get-Date) -lt $deadline)
    if (-not $healthy) { throw 'Temporary backend did not become healthy.' }

    $agentHeaders = @{ 'X-Agent-Key' = $agentKey }
    [void](Invoke-TestApi -Method POST -Path '/api/agent/heartbeat' -Headers $agentHeaders -Body @{
        agentId = 'stomazub-ui-test'
        deviceName = 'IDENT-CLINIC'
        version = '2.6.0'
        startedAt = (Get-Date).AddMinutes(-12).ToString('o')
        status = 'online'
        schedule = @{
            enabled = $true; state = 'ok'; mappingConfigured = $true
            lastSuccessAt = (Get-Date).AddMinutes(-2).ToString('o'); doctors = 8; branches = 2; intervals = 146
            freeIntervals = 41; busyIntervals = 105; lastError = ''
        }
        schema = @{ state = 'ok'; tables = 187; columns = 1320; lastError = '' }
        robot = @{ enabled = $false; configured = $false; state = 'disabled'; lastError = '' }
        diagnostics = @{ state = 'ok'; sqlDiscoveryState = 'ok'; lastError = '' }
        update = @{ status = 'idle'; currentVersion = '2.6.0'; message = '' }
        system = @{ processId = 4242; windowsVersion = 'Windows 11 Pro' }
    })
    [void](Invoke-TestApi -Method POST -Path '/api/agent/diagnostics' -Headers $agentHeaders -Body @{
        agentId = 'stomazub-ui-test'
        report = @{
            generatedAt = (Get-Date).ToString('o')
            agent = @{ agentId = 'stomazub-ui-test'; version = '2.6.0'; deviceName = 'IDENT-CLINIC'; processId = 4242 }
            sql = @{ dataSource = 'tcp:192.168.0.3,51433'; database = 'IDENT'; user = 'readonly_user'; encrypt = $false; trustServerCertificate = $true }
            autostart = @{ workerTask = 'Running'; desktopTask = 'Ready'; workerShortcut = $false; desktopShortcut = $false }
            state = @{
                worker = @{ backendOnline = $true; lastHeartbeatAt = (Get-Date).ToString('o'); lastError = '' }
                schedule = @{ state = 'ok'; doctors = 8; branches = 2; intervals = 146; lastError = '' }
                diagnostics = @{ state = 'ok'; sqlDiscoveryState = 'ok'; lastError = '' }
            }
            discovery = @{
                timestamp = (Get-Date).AddMinutes(-5).ToString('o')
                result = 'configured'
                configuredServer = '192.168.0.3'
                attempts = @(@{ dataSource = 'tcp:192.168.0.3,51433'; source = 'configured'; connected = $true; databases = @('IDENT'); error = '' })
            }
            logs = [string[]]@(
                '{"timestamp":"2026-08-11T12:00:00+03:00","level":"info","event":"worker_started"}',
                '{"timestamp":"2026-08-11T12:00:02+03:00","level":"info","event":"diagnostics_uploaded"}'
            )
        }
    })

    $secureServiceKey = ConvertTo-SecureString -String $serviceKey -AsPlainText -Force
    & (Join-Path $root 'admin\ident-admin-desktop\Setup-IdentAdmin.ps1') `
        -InstallDirectory $installRoot `
        -BackendUrl $baseUrl `
        -ServiceApiKey $secureServiceKey `
        -NoShortcut `
        -NoLaunch

    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File (Join-Path $installRoot 'IdentAdminDesktop.ps1') `
        -DiagnosticsCapturePath $OutputPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "Admin UI capture failed with exit code $LASTEXITCODE."
    }
    $image = [Drawing.Image]::FromFile($OutputPath)
    try {
        if ($image.Width -lt 900 -or $image.Height -lt 600) { throw 'Admin UI capture dimensions are invalid.' }
    }
    finally { $image.Dispose() }
    Write-Host "ADMIN UI CAPTURE OK: $OutputPath"
}
finally {
    if ($null -ne $adminProcess -and -not $adminProcess.HasExited) {
        [void]$adminProcess.CloseMainWindow()
        if (-not $adminProcess.WaitForExit(3000)) { $adminProcess.Kill() }
    }
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        $serverProcess.Kill()
        [void]$serverProcess.WaitForExit(3000)
    }
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
    if (
        (Test-Path -LiteralPath $testRoot) -and
        [IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
