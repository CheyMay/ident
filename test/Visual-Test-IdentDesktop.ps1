[CmdletBinding()]
param([string]$OutputPath = (Join-Path $env:TEMP 'ident-desktop-visual.png'))

$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = Join-Path $env:TEMP ('ident-desktop-visual-' + [Guid]::NewGuid().ToString('N'))
$root = [IO.Path]::GetFullPath($root)
if (-not $root.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test output directory' }
$app = $null
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'robot') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'commands') | Out-Null
    $secret = ConvertFrom-SecureString (ConvertTo-SecureString 'test-agent-key' -AsPlainText -Force)
    @{ agentApiKeyDpapi = $secret } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'secrets.json') -Encoding UTF8
    [ordered]@{
        agent = @{ id = 'clinic-demo'; version = '2.14.0' }
        features = @{ scheduleEnabled = $true; robotEnabled = $false }
        sql = @{ server = '192.168.0.3'; port = 15000; instanceName = ''; database = 'PZ' }
        backend = @{ baseUrl = 'https://ident.code9dev.ru'; timeoutSeconds = 5 }
        paths = @{
            secrets = 'secrets.json'; runtimeState = 'state.json'; commandDirectory = 'commands'
            robotConfig = 'robot\config.local.json'
        }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
    [ordered]@{
        updatedAt = (Get-Date).ToString('o'); version = '2.14.0'
        worker = @{ backendOnline = $true; lastError = '' }
        schedule = @{
            enabled = $true; state = 'ok'; lastSuccessAt = (Get-Date).ToString('o'); lastError = ''
            doctors = 8; branches = 1; intervals = 2265; freeIntervals = 1699; services = 488
        }
        schema = @{ state = 'ok'; tables = 132; columns = 1740; lastError = '' }
        robot = @{ enabled = $false; configured = $false; state = 'needs_configuration'; lastSuccessAt = ''; lastError = '' }
        update = @{ status = 'idle'; targetVersion = '' }
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $root 'state.json') -Encoding UTF8
    @{ updatedAt = (Get-Date).ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'supervisor-state.json') -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $repository 'robot\ident-rpa\config.example.json') -Destination (Join-Path $root 'robot\config.local.json')

    $scriptPath = Join-Path $repository 'agent\ident-db-agent\IdentDesktop.ps1'
    $configPath = Join-Path $root 'config.json'
    $app = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -PreviewPath `"$OutputPath`"" -WindowStyle Hidden -PassThru
    if (-not $app.WaitForExit(15000)) { throw 'Client preview timed out' }
    if ($app.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) { throw 'Client preview failed' }
    Write-Output $OutputPath
}
finally {
    if ($null -ne $app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
