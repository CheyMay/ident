[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Code9\IdentAgent')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Protect-Secret {
    param([Security.SecureString]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        return ''
    }
    return ConvertFrom-SecureString -SecureString $Value
}

Write-Host ''
Write-Host 'Code9 IDENT Desktop setup' -ForegroundColor Cyan
Write-Host 'The agent sends the schedule, reports its status and can run the optional booking robot.'
Write-Host 'Passwords and keys are encrypted by Windows for the current user and computer.'
Write-Host ''

New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDirectory 'logs') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDirectory 'commands') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDirectory 'robot') | Out-Null

$runtimeFiles = @(
    'IdentAgent.ps1',
    'IdentWorker.ps1',
    'IdentDesktop.ps1',
    'Install-IdentAgentTask.ps1',
    'Uninstall-IdentAgentTask.ps1'
)
foreach ($file in $runtimeFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $InstallDirectory $file) -Force
}

$robotSource = Join-Path $PSScriptRoot 'robot-source'
if (-not (Test-Path -LiteralPath $robotSource)) {
    $robotSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\robot\ident-rpa'))
}
if (-not (Test-Path -LiteralPath (Join-Path $robotSource 'Start-IdentRobot.ps1'))) {
    throw 'Robot source files are missing from the installation package.'
}
Copy-Item `
    -LiteralPath (Join-Path $robotSource 'Start-IdentRobot.ps1') `
    -Destination (Join-Path $InstallDirectory 'robot\Start-IdentRobot.ps1') `
    -Force

$mappingTarget = Join-Path $InstallDirectory 'mapping.local.json'
if (-not (Test-Path -LiteralPath $mappingTarget)) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mapping.example.json') -Destination $mappingTarget
}

$robotConfigTarget = Join-Path $InstallDirectory 'robot\config.local.json'
if (-not (Test-Path -LiteralPath $robotConfigTarget)) {
    $robotConfig = Get-Content -LiteralPath (Join-Path $robotSource 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $robotConfig.backend.baseUrl = ''
    $robotConfig.backend.serviceApiKey = ''
    $robotConfig.inspect.outputPath = Join-Path $InstallDirectory 'robot\ui-tree.json'
    $robotConfig.logDir = Join-Path $InstallDirectory 'logs\robot'
    $robotConfig.workflow.allowUnsafeExecution = $false
    $robotConfig.workflow.confirmBeforeEachStep = $false
    $robotConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $robotConfigTarget -Encoding UTF8
}

$defaultAgentId = ('stomazub-' + $env:COMPUTERNAME).ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
$agentId = Read-WithDefault -Prompt 'Agent ID' -Default $defaultAgentId
$sqlServer = Read-WithDefault -Prompt 'IDENT SQL server IP or name' -Default '192.168.0.3'
$sqlUser = Read-WithDefault -Prompt 'SQL login' -Default 'readonly_user'
$sqlPassword = Read-Host 'SQL password' -AsSecureString
$backendUrl = Read-WithDefault -Prompt 'Code9 backend URL' -Default 'https://ident.code9dev.ru'
$agentKey = Read-Host 'Code9 agent key' -AsSecureString

if ($sqlPassword.Length -eq 0) {
    throw 'SQL password cannot be empty.'
}
if ($agentKey.Length -eq 0) {
    throw 'Code9 agent key cannot be empty.'
}

$config = [ordered]@{
    version = 2
    agent = [ordered]@{
        id = $agentId
        version = '2.1.0'
    }
    features = [ordered]@{
        scheduleEnabled = $true
        robotEnabled = $false
    }
    intervals = [ordered]@{
        heartbeatSeconds = 60
        scheduleSeconds = 600
        robotSeconds = 30
    }
    sql = [ordered]@{
        server = $sqlServer
        instanceName = ''
        port = 0
        database = ''
        user = $sqlUser
        encrypt = $false
        trustServerCertificate = $true
        connectTimeoutSeconds = 8
        commandTimeoutSeconds = 60
    }
    backend = [ordered]@{
        baseUrl = $backendUrl.TrimEnd('/')
        timeoutSeconds = 60
    }
    paths = [ordered]@{
        secrets = 'secrets.local.json'
        mapping = 'mapping.local.json'
        schemaOutput = 'schema-inventory.json'
        log = 'logs\agent.log'
        pushResult = 'last-push-result.json'
        runtimeState = 'runtime-state.json'
        commandDirectory = 'commands'
        robotConfig = 'robot\config.local.json'
    }
}

$secrets = [ordered]@{
    version = 2
    sqlPasswordDpapi = Protect-Secret -Value $sqlPassword
    agentApiKeyDpapi = Protect-Secret -Value $agentKey
}

$configPath = Join-Path $InstallDirectory 'config.local.json'
$secretsPath = Join-Path $InstallDirectory 'secrets.local.json'
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
$secrets | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $secretsPath -Encoding UTF8

Write-Host ''
Write-Host "Agent installed to: $InstallDirectory" -ForegroundColor Green
Write-Host 'Searching for SQL Server and the IDENT database...'
& (Join-Path $InstallDirectory 'IdentAgent.ps1') -ConfigPath $configPath -AutoConfigureSql
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Automatic SQL discovery did not finish. The agent will still be installed.' -ForegroundColor Yellow
    Write-Host 'Keep IDENT open and use "Find SQL automatically" in the status panel.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Installing startup tasks...'
& (Join-Path $InstallDirectory 'Install-IdentAgentTask.ps1') -InstallDirectory $InstallDirectory

Write-Host ''
Write-Host 'Setup finished. The status panel is available in the Windows notification area.' -ForegroundColor Green
Write-Host 'The booking robot remains disabled until its IDENT controls are calibrated.'
