[CmdletBinding()]
param(
    [string]$PackagePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $PSScriptRoot '..\agent\ident-db-agent\dist\ident-agent-release-2.4.1.zip'
}
$PackagePath = [IO.Path]::GetFullPath($PackagePath)
$updaterPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\agent\ident-db-agent\Apply-IdentAgentUpdate.ps1'))
$testRoot = Join-Path $PSScriptRoot ('.tmp-update-' + [Guid]::NewGuid().ToString('N'))
$installDirectory = Join-Path $testRoot 'install'

function Invoke-UpdaterProcess {
    param(
        [string]$Archive,
        [string]$Version,
        [string]$Hash
    )

    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$updaterPath`" " +
        "-ArchivePath `"$Archive`" -InstallDirectory `"$installDirectory`" " +
        "-ExpectedVersion `"$Version`" -ExpectedSha256 `"$Hash`" -TestMode"
    $previousModulePath = $env:PSModulePath
    try {
        $env:PSModulePath = @(
            (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules')
            (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
            (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Modules')
        ) -join ';'
        return Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    }
    finally {
        $env:PSModulePath = $previousModulePath
    }
}

try {
    if (-not (Test-Path -LiteralPath $PackagePath)) {
        throw "Agent package was not found: $PackagePath"
    }
    $inspectionDirectory = Join-Path $testRoot 'inspection'
    New-Item -ItemType Directory -Force -Path $inspectionDirectory | Out-Null
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $inspectionDirectory -Force
    $releaseManifest = Get-Content -LiteralPath (Join-Path $inspectionDirectory 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $expectedVersion = [string]$releaseManifest.version
    if ([string]::IsNullOrWhiteSpace($expectedVersion)) { throw 'Release version is missing.' }

    New-Item -ItemType Directory -Force -Path (Join-Path $installDirectory 'robot') | Out-Null
    $config = [ordered]@{
        version = 2
        agent = [ordered]@{ id = 'test-clinic'; version = '2.3.0' }
    }
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $installDirectory 'config.local.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installDirectory 'secrets.local.json') -Value '{"agentApiKeyDpapi":"KEEP-SECRET"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installDirectory 'mapping.local.json') -Value '{"doctorsSql":"KEEP-MAPPING"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installDirectory 'robot\config.local.json') -Value '{"selector":"KEEP-ROBOT"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $installDirectory 'IdentWorker.ps1') -Value '# OLD-WORKER' -Encoding UTF8

    $secretHash = (Get-FileHash -LiteralPath (Join-Path $installDirectory 'secrets.local.json') -Algorithm SHA256).Hash
    $mappingHash = (Get-FileHash -LiteralPath (Join-Path $installDirectory 'mapping.local.json') -Algorithm SHA256).Hash
    $robotHash = (Get-FileHash -LiteralPath (Join-Path $installDirectory 'robot\config.local.json') -Algorithm SHA256).Hash
    $packageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
    $success = Invoke-UpdaterProcess -Archive $PackagePath -Version $expectedVersion -Hash $packageHash
    if ($success.ExitCode -ne 0) {
        throw "Successful update test returned exit code $($success.ExitCode)."
    }

    $updatedConfig = Get-Content -LiteralPath (Join-Path $installDirectory 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$updatedConfig.agent.version -ne $expectedVersion) { throw 'Agent version was not updated.' }
    if ((Get-FileHash -LiteralPath (Join-Path $installDirectory 'secrets.local.json') -Algorithm SHA256).Hash -ne $secretHash) { throw 'Secrets changed during update.' }
    if ((Get-FileHash -LiteralPath (Join-Path $installDirectory 'mapping.local.json') -Algorithm SHA256).Hash -ne $mappingHash) { throw 'SQL mapping changed during update.' }
    if ((Get-FileHash -LiteralPath (Join-Path $installDirectory 'robot\config.local.json') -Algorithm SHA256).Hash -ne $robotHash) { throw 'Robot calibration changed during update.' }
    if ((Get-Content -LiteralPath (Join-Path $installDirectory 'IdentWorker.ps1') -Raw) -match 'OLD-WORKER') { throw 'Runtime files were not replaced.' }

    Set-Content -LiteralPath (Join-Path $installDirectory 'IdentWorker.ps1') -Value '# STABLE-WORKER' -Encoding UTF8
    $badSource = Join-Path $testRoot 'bad-release'
    New-Item -ItemType Directory -Force -Path $badSource | Out-Null
    Set-Content -LiteralPath (Join-Path $badSource 'IdentWorker.ps1') -Value '# BROKEN-WORKER' -Encoding UTF8
    $badManifest = [ordered]@{
        product = 'code9-ident-agent'
        version = '2.5.0'
        files = @(
            @{ source = 'IdentWorker.ps1'; destination = 'IdentWorker.ps1' },
            @{ source = 'missing.ps1'; destination = 'IdentDesktop.ps1' }
        )
    }
    $badManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $badSource 'release.json') -Encoding UTF8
    $badArchive = Join-Path $testRoot 'bad-release.zip'
    Compress-Archive -Path (Join-Path $badSource '*') -DestinationPath $badArchive
    $badHash = (Get-FileHash -LiteralPath $badArchive -Algorithm SHA256).Hash
    $failure = Invoke-UpdaterProcess -Archive $badArchive -Version '2.5.0' -Hash $badHash
    if ($failure.ExitCode -eq 0) { throw 'Broken update unexpectedly succeeded.' }
    if ((Get-Content -LiteralPath (Join-Path $installDirectory 'IdentWorker.ps1') -Raw) -notmatch 'STABLE-WORKER') { throw 'Runtime rollback did not restore the previous file.' }
    $rolledBackConfig = Get-Content -LiteralPath (Join-Path $installDirectory 'config.local.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$rolledBackConfig.agent.version -ne $expectedVersion) { throw 'Configuration rollback did not preserve the installed version.' }
    $failureStatus = Get-Content -LiteralPath (Join-Path $installDirectory 'update-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$failureStatus.status -ne 'failed') { throw 'Failed update status was not recorded.' }

    Write-Host 'Agent update lifecycle OK' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
