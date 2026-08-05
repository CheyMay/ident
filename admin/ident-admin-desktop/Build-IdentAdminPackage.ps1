[CmdletBinding()]
param([string]$OutputDirectory = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$stagingDirectory = Join-Path $OutputDirectory 'ident-admin-desktop'
$archivePath = Join-Path $OutputDirectory 'ident-admin-desktop-1.0.0.zip'
$outputPrefix = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not ([IO.Path]::GetFullPath($stagingDirectory)).StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Staging directory must stay inside the output directory.'
}

if (Test-Path -LiteralPath $stagingDirectory) { Remove-Item -LiteralPath $stagingDirectory -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stagingDirectory | Out-Null
foreach ($file in @('1-Setup.cmd', '2-Open.cmd', 'Setup-IdentAdmin.ps1', 'IdentAdminDesktop.ps1', 'config.example.json', 'README.txt')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $stagingDirectory $file)
}
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal
Write-Host "Admin package built: $archivePath" -ForegroundColor Green
