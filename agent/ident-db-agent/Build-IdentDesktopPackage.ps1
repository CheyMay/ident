[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stagingDirectory = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-desktop'))
$archivePath = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-desktop-2.2.0.zip'))
$outputPrefix = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $stagingDirectory.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Staging directory must stay inside the output directory.'
}

if (Test-Path -LiteralPath $stagingDirectory) {
    Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stagingDirectory 'robot-source') | Out-Null

$files = @(
    '1-Setup.cmd',
    '2-First-Check.cmd',
    '3-Export-Schema.cmd',
    '4-Preview.cmd',
    '5-Install-Autostart.cmd',
    '6-Run-Now.cmd',
    '7-Remove-Autostart.cmd',
    '8-Open-Status.cmd',
    'IdentAgent.ps1',
    'IdentWorker.ps1',
    'IdentDesktop.ps1',
    'Setup-IdentAgent.ps1',
    'Install-IdentAgentTask.ps1',
    'Uninstall-IdentAgentTask.ps1',
    'config.example.json',
    'mapping.example.json',
    'README.txt'
)
foreach ($file in $files) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $stagingDirectory $file)
}

$robotSource = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\robot\ident-rpa'))
Copy-Item -LiteralPath (Join-Path $robotSource 'Start-IdentRobot.ps1') -Destination (Join-Path $stagingDirectory 'robot-source\Start-IdentRobot.ps1')
Copy-Item -LiteralPath (Join-Path $robotSource 'config.example.json') -Destination (Join-Path $stagingDirectory 'robot-source\config.example.json')

if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
}
Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal

Write-Host "Package built: $archivePath" -ForegroundColor Green
