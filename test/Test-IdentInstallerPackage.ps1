[CmdletBinding()]
param(
    [string]$PackagePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = Join-Path $PSScriptRoot '..\agent\ident-db-agent\dist\ident-desktop-2.4.1.zip'
}
$PackagePath = [IO.Path]::GetFullPath($PackagePath)
$testRoot = Join-Path $PSScriptRoot ('.tmp-installer-' + [Guid]::NewGuid().ToString('N'))

try {
    if (-not (Test-Path -LiteralPath $PackagePath)) { throw "Installer package not found: $PackagePath" }
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $testRoot)
    $rootFiles = @(Get-ChildItem -LiteralPath $testRoot -File)
    $rootDirectories = @(Get-ChildItem -LiteralPath $testRoot -Directory)
    if ($rootFiles.Count -ne 2 -or $rootDirectories.Count -ne 0) {
        throw 'Client ZIP must contain exactly one installer and one instruction file.'
    }
    $installer = @($rootFiles | Where-Object { $_.Name -like '1-*.cmd' } | Select-Object -First 1)[0]
    $instruction = @($rootFiles | Where-Object { $_.Name -like '2-*.txt' } | Select-Object -First 1)[0]
    if ($null -eq $installer -or $null -eq $instruction) { throw 'Installer or instruction file is missing.' }

    $raw = [IO.File]::ReadAllText($installer.FullName, [Text.Encoding]::ASCII)
    $marker = '__CODE9_PAYLOAD__'
    $index = $raw.LastIndexOf($marker, [StringComparison]::Ordinal)
    if ($index -lt 0) { throw 'Embedded installer payload marker is missing.' }
    $payload = [Convert]::FromBase64String($raw.Substring($index + $marker.Length))
    $releasePath = Join-Path $testRoot 'release.zip'
    [IO.File]::WriteAllBytes($releasePath, $payload)
    $releaseDirectory = Join-Path $testRoot 'release'
    [IO.Compression.ZipFile]::ExtractToDirectory($releasePath, $releaseDirectory)

    foreach ($required in @('release.json', 'Setup-IdentAgent.ps1', 'IdentWorker.ps1', 'IdentSupervisor.ps1', 'Apply-IdentAgentUpdate.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory $required) -PathType Leaf)) {
            throw "Embedded payload is missing $required"
        }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $releaseDirectory 'release.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.product -ne 'code9-ident-agent' -or [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
        throw 'Embedded release manifest is invalid.'
    }
    if ([version]$manifest.version -ge [version]'2.14.8') {
        $formBinding=@($manifest.files | Where-Object { $_.source -eq 'robot-source/IdentPatientForm.ps1' -and $_.destination -eq 'robot/IdentPatientForm.ps1' })
        if ($formBinding.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $releaseDirectory 'robot-source/IdentPatientForm.ps1'))) {
            throw 'Patient-form module is missing from update manifest or payload.'
        }
        $setup=Get-Content -LiteralPath (Join-Path $releaseDirectory 'Setup-IdentAgent.ps1') -Raw -Encoding UTF8
        if ($setup -notmatch "'IdentPatientForm.ps1'") { throw 'Initial setup does not copy the patient-form module.' }
    }
    if ([version]$manifest.version -ge [version]'2.14.9') {
        foreach($name in @('IdentFillCheck.ps1','IdentFillRuntime.ps1','Start-IdentFillCheck.ps1')) {
            $bindings=@($manifest.files | Where-Object { $_.source -eq ('robot-source/'+$name) -and $_.destination -eq ('robot/'+$name) })
            if ($bindings.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $releaseDirectory ('robot-source/'+$name))) -or
                $setup -notmatch [regex]::Escape("'$name'")) { throw 'Fill-check module missing from update or initial setup.' }
        }
    }
    if ([version]$manifest.version -ge [version]'2.14.10') {
        $binding=@($manifest.files | Where-Object { $_.source -eq 'AgentLifecycle.ps1' -and $_.destination -eq 'AgentLifecycle.ps1' })
        if ($binding.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $releaseDirectory 'AgentLifecycle.ps1')) -or
            $setup -notmatch "'AgentLifecycle.ps1'") { throw 'Agent lifecycle helper is missing from update or initial setup.' }
    }
    if ([version]$manifest.version -ge [version]'2.14.11') {
        foreach($name in @('Start-IdentFillCheck.ps1','Start-IdentRobot.ps1','IdentFillRuntime.ps1')) {
            $code=Get-Content -LiteralPath (Join-Path $releaseDirectory ('robot-source/'+$name)) -Raw -Encoding UTF8
            if ($code -notmatch '\$ObserveChanges' -or $code -notmatch 'FILL_INVALID_MODE') { throw 'Read-only observation routing or mode guard is missing.' }
        }
        $engine=Get-Content -LiteralPath (Join-Path $releaseDirectory 'robot-source/IdentFillCheck.ps1') -Raw -Encoding UTF8
        if ($engine -notmatch 'function Invoke-IdentFillObservation' -or $engine -notmatch 'WriteReturned') { throw 'Observation engine or fill diagnostics are missing.' }
    }
    $forbidden = @(Get-ChildItem -LiteralPath $releaseDirectory -Recurse -File | Where-Object {
        $_.Name -match '^(config\.local|secrets\.local|mapping\.local|runtime-state|schema-inventory|agent\.log)'
    })
    if ($forbidden.Count -gt 0) { throw 'Installer contains local configuration or secret files.' }

    Write-Host 'Single-file client installer package OK' -ForegroundColor Green
}
finally {
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if ((Split-Path -Parent $resolved) -ieq [IO.Path]::GetFullPath($PSScriptRoot) -and
        (Split-Path -Leaf $resolved) -like '.tmp-installer-*' -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
