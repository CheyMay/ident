[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$releaseVersion = '2.9.2'
$releaseStagingDirectory = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-agent-release'))
$installerStagingDirectory = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-client-installer'))
$releaseArchivePath = [IO.Path]::GetFullPath((Join-Path $OutputDirectory "ident-agent-release-$releaseVersion.zip"))
$installerArchivePath = [IO.Path]::GetFullPath((Join-Path $OutputDirectory "ident-desktop-$releaseVersion.zip"))
$outputPrefix = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
foreach ($path in @($releaseStagingDirectory, $installerStagingDirectory, $releaseArchivePath, $installerArchivePath)) {
    if (-not $path.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build paths must stay inside the output directory.'
    }
}

foreach ($directory in @($releaseStagingDirectory, $installerStagingDirectory)) {
    if (Test-Path -LiteralPath $directory) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
New-Item -ItemType Directory -Force -Path (Join-Path $releaseStagingDirectory 'robot-source') | Out-Null

$payloadFiles = @(
    'IdentAgent.ps1',
    'IdentWorker.ps1',
    'IdentSupervisor.ps1',
    'IdentDesktop.ps1',
    'Apply-IdentAgentUpdate.ps1',
    'Setup-IdentAgent.ps1',
    'Install-IdentAgentTask.ps1',
    'Uninstall-IdentAgentTask.ps1',
    'config.example.json',
    'mapping.example.json',
    'README.txt'
)
foreach ($file in $payloadFiles) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $releaseStagingDirectory $file)
}

$robotSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\robot\ident-rpa'))
Copy-Item -LiteralPath (Join-Path $robotSource 'Start-IdentRobot.ps1') -Destination (Join-Path $releaseStagingDirectory 'robot-source\Start-IdentRobot.ps1')
Copy-Item -LiteralPath (Join-Path $robotSource 'config.example.json') -Destination (Join-Path $releaseStagingDirectory 'robot-source\config.example.json')

$releaseManifest = [ordered]@{
    product = 'code9-ident-agent'
    version = $releaseVersion
    notes = 'Code9 IDENT Desktop 2.9.2: unattended recovery for interrupted agent updates'
    files = @(
        @{ source = 'IdentAgent.ps1'; destination = 'IdentAgent.ps1' },
        @{ source = 'IdentWorker.ps1'; destination = 'IdentWorker.ps1' },
        @{ source = 'IdentSupervisor.ps1'; destination = 'IdentSupervisor.ps1' },
        @{ source = 'IdentDesktop.ps1'; destination = 'IdentDesktop.ps1' },
        @{ source = 'Apply-IdentAgentUpdate.ps1'; destination = 'Apply-IdentAgentUpdate.ps1' },
        @{ source = 'Setup-IdentAgent.ps1'; destination = 'Setup-IdentAgent.ps1' },
        @{ source = 'Install-IdentAgentTask.ps1'; destination = 'Install-IdentAgentTask.ps1' },
        @{ source = 'Uninstall-IdentAgentTask.ps1'; destination = 'Uninstall-IdentAgentTask.ps1' },
        @{ source = 'robot-source/Start-IdentRobot.ps1'; destination = 'robot/Start-IdentRobot.ps1' }
    )
}
$releaseManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $releaseStagingDirectory 'release.json') -Encoding UTF8

foreach ($archive in @($releaseArchivePath, $installerArchivePath)) {
    if (Test-Path -LiteralPath $archive) {
        Remove-Item -LiteralPath $archive -Force
    }
}
Compress-Archive -Path (Join-Path $releaseStagingDirectory '*') -DestinationPath $releaseArchivePath -CompressionLevel Optimal

$payloadBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($releaseArchivePath), [Base64FormattingOptions]::InsertLineBreaks)
$installerHeader = @'
@echo off
chcp 65001 >nul
setlocal
title Code9 IDENT Setup
set "CODE9_INSTALLER=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $source=$env:CODE9_INSTALLER; $marker='__CODE9_PAYLOAD__'; $raw=[IO.File]::ReadAllText($source,[Text.Encoding]::ASCII); $index=$raw.LastIndexOf($marker,[StringComparison]::Ordinal); if($index -lt 0){throw 'Installation payload was not found.'}; $temporary=Join-Path $env:TEMP ('Code9IdentInstall-'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $temporary|Out-Null; try{$archive=Join-Path $temporary 'agent.zip'; $base64=$raw.Substring($index+$marker.Length); [IO.File]::WriteAllBytes($archive,[Convert]::FromBase64String($base64)); $files=Join-Path $temporary 'files'; Expand-Archive -LiteralPath $archive -DestinationPath $files -Force; & (Join-Path $files 'Setup-IdentAgent.ps1'); if(-not $?){throw 'Code9 IDENT setup did not finish.'}}finally{Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}"
set "CODE9_RESULT=%ERRORLEVEL%"
if not "%CODE9_RESULT%"=="0" (
  echo.
  echo Setup did not finish. Send the error text to the Code9 specialist.
) else (
  echo.
  echo Code9 IDENT setup completed.
)
pause
exit /b %CODE9_RESULT%
__CODE9_PAYLOAD__
'@
$installerPath = Join-Path $installerStagingDirectory '1-УСТАНОВИТЬ.cmd'
[IO.File]::WriteAllText($installerPath, ($installerHeader + $payloadBase64 + [Environment]::NewLine), [Text.Encoding]::ASCII)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'INSTALLATION.txt') -Destination (Join-Path $installerStagingDirectory '2-ИНСТРУКЦИЯ.txt')
Compress-Archive -Path (Join-Path $installerStagingDirectory '*') -DestinationPath $installerArchivePath -CompressionLevel Optimal

Write-Host "Client package built: $installerArchivePath" -ForegroundColor Green
Write-Host "Remote update release built: $releaseArchivePath" -ForegroundColor Green
