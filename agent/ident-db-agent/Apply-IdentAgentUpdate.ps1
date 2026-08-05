[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,
    [Parameter(Mandatory = $true)]
    [string]$InstallDirectory,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedSha256,
    [int]$WorkerProcessId = 0,
    [string]$WorkerTaskName = 'Code9 IDENT Agent',
    [switch]$TestMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-UpdateStatus {
    param(
        [string]$Status,
        [string]$Message,
        [string]$CurrentVersion = ''
    )

    $statusPath = Join-Path $InstallDirectory 'update-status.json'
    $payload = [ordered]@{
        targetVersion = $ExpectedVersion
        currentVersion = $CurrentVersion
        status = $Status
        message = $Message
        updatedAt = (Get-Date).ToString('o')
    }
    $temporaryPath = "$statusPath.tmp-$PID"
    $payload | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $statusPath -Force
}

function Resolve-SafeChildPath {
    param(
        [string]$Root,
        [string]$RelativePath
    )

    $normalizedRelative = ([string]$RelativePath).Replace('/', [IO.Path]::DirectorySeparatorChar)
    if ([IO.Path]::IsPathRooted($normalizedRelative) -or $normalizedRelative -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Unsafe update path: $RelativePath"
    }
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolved = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $normalizedRelative))
    if (-not $resolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Update path leaves the installation directory: $RelativePath"
    }
    return $resolved
}

function Assert-AllowedDestination {
    param([string]$RelativePath)

    $normalized = ([string]$RelativePath).Replace('\\', '/').TrimStart('./').ToLowerInvariant()
    $protected = @(
        'config.local.json',
        'secrets.local.json',
        'mapping.local.json',
        'schema-inventory.json',
        'runtime-state.json',
        'robot-receipts.json',
        'update-status.json'
    )
    if (
        $protected -contains $normalized -or
        $normalized.StartsWith('logs/') -or
        $normalized.StartsWith('commands/') -or
        $normalized.StartsWith('updates/') -or
        $normalized -eq 'robot/config.local.json' -or
        $normalized -eq 'robot/ui-tree.json'
    ) {
        throw "Release cannot overwrite local data: $RelativePath"
    }
}

$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$ExpectedSha256 = $ExpectedSha256.Trim().ToUpperInvariant()
$stagingRoot = Join-Path $InstallDirectory 'updates\staging'
$stagingDirectory = Join-Path $stagingRoot ("$ExpectedVersion-$PID")
$backupDirectory = Join-Path $InstallDirectory ("updates\backups\$ExpectedVersion-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$configPath = Join-Path $InstallDirectory 'config.local.json'
$copiedDestinations = New-Object Collections.Generic.List[string]
$existingDestinations = New-Object Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
$currentVersion = ''

try {
    if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw 'Invalid target version.'
    }
    if ($ExpectedSha256 -notmatch '^[A-F0-9]{64}$') {
        throw 'Invalid expected SHA-256.'
    }
    if (-not (Test-Path -LiteralPath $ArchivePath)) {
        throw 'Downloaded update archive was not found.'
    }
    $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -ne $ExpectedSha256) {
        throw 'Downloaded update archive failed SHA-256 verification.'
    }

    if ($WorkerProcessId -gt 0 -and $WorkerProcessId -ne $PID) {
        try {
            Wait-Process -Id $WorkerProcessId -Timeout 45 -ErrorAction Stop
        }
        catch {
            $worker = Get-Process -Id $WorkerProcessId -ErrorAction SilentlyContinue
            if ($null -ne $worker) {
                throw 'The running agent did not stop for the update.'
            }
        }
    }

    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $stagingDirectory -Force

    $manifestPath = Join-Path $stagingDirectory 'release.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw 'release.json is missing from the update archive.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$manifest.product -ne 'code9-ident-agent' -or [string]$manifest.version -ne $ExpectedVersion) {
        throw 'The release manifest does not match the assigned update.'
    }
    if ($null -eq $manifest.files -or @($manifest.files).Count -eq 0) {
        throw 'The release manifest contains no update files.'
    }

    if (Test-Path -LiteralPath $configPath) {
        $currentConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $currentVersion = [string]$currentConfig.agent.version
        Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory 'config.local.json') -Force
    }
    else {
        throw 'config.local.json is missing from the installation directory.'
    }

    Write-UpdateStatus -Status 'applying' -Message 'Update files are being installed.' -CurrentVersion $currentVersion

    foreach ($operation in @($manifest.files)) {
        $sourceRelative = [string]$operation.source
        $destinationRelative = [string]$operation.destination
        Assert-AllowedDestination -RelativePath $destinationRelative
        $source = Resolve-SafeChildPath -Root $stagingDirectory -RelativePath $sourceRelative
        $destination = Resolve-SafeChildPath -Root $InstallDirectory -RelativePath $destinationRelative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Update file is missing: $sourceRelative"
        }

        $destinationDirectory = Split-Path -Parent $destination
        New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            [void]$existingDestinations.Add($destinationRelative)
            $backupPath = Resolve-SafeChildPath -Root $backupDirectory -RelativePath $destinationRelative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backupPath) | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backupPath -Force
        }

        $temporaryDestination = "$destination.update-$PID"
        Copy-Item -LiteralPath $source -Destination $temporaryDestination -Force
        Move-Item -LiteralPath $temporaryDestination -Destination $destination -Force
        $copiedDestinations.Add($destinationRelative)
    }

    $updatedConfig = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $updatedConfig.agent.version = $ExpectedVersion
    $temporaryConfig = "$configPath.update-$PID"
    $updatedConfig | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryConfig -Encoding UTF8
    Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force
    Write-UpdateStatus -Status 'succeeded' -Message 'Update installed successfully.' -CurrentVersion $ExpectedVersion

    if (-not $TestMode) {
        $workerTask = Get-ScheduledTask -TaskName $WorkerTaskName -ErrorAction SilentlyContinue
        if ($null -ne $workerTask) {
            Start-ScheduledTask -TaskName $WorkerTaskName
        }
        else {
            & (Join-Path $InstallDirectory 'Install-IdentAgentTask.ps1') -InstallDirectory $InstallDirectory
        }
    }
}
catch {
    $failure = $_.Exception.Message
    foreach ($destinationRelative in @($copiedDestinations)) {
        $destination = Resolve-SafeChildPath -Root $InstallDirectory -RelativePath $destinationRelative
        $backupPath = Resolve-SafeChildPath -Root $backupDirectory -RelativePath $destinationRelative
        if ($existingDestinations.Contains($destinationRelative) -and (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $backupPath -Destination $destination -Force
        }
        elseif (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    $configBackup = Join-Path $backupDirectory 'config.local.json'
    if (Test-Path -LiteralPath $configBackup) {
        Copy-Item -LiteralPath $configBackup -Destination $configPath -Force
    }
    Write-UpdateStatus -Status 'failed' -Message $failure -CurrentVersion $currentVersion
    if (-not $TestMode) {
        $workerTask = Get-ScheduledTask -TaskName $WorkerTaskName -ErrorAction SilentlyContinue
        if ($null -ne $workerTask) {
            Start-ScheduledTask -TaskName $WorkerTaskName -ErrorAction SilentlyContinue
        }
    }
    exit 1
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
