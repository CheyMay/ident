[CmdletBinding()]
param([string]$OutputDirectory = '')

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $PSScriptRoot 'dist'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$version = '1.0.1'
$payloadDirectory = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-admin-payload'))
$installerDirectory = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-admin-installer'))
$payloadArchivePath = [IO.Path]::GetFullPath((Join-Path $OutputDirectory 'ident-admin-payload.zip'))
$archivePath = [IO.Path]::GetFullPath((Join-Path $OutputDirectory "ident-admin-desktop-$version.zip"))
$outputPrefix = $OutputDirectory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
foreach ($path in @($payloadDirectory, $installerDirectory, $payloadArchivePath, $archivePath)) {
    if (-not $path.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Build paths must stay inside the output directory.'
    }
}

foreach ($directory in @($payloadDirectory, $installerDirectory)) {
    if (Test-Path -LiteralPath $directory) {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
foreach ($file in @('Setup-IdentAdmin.ps1', 'IdentAdminDesktop.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $payloadDirectory $file)
}
foreach ($archive in @($payloadArchivePath, $archivePath)) {
    if (Test-Path -LiteralPath $archive) {
        Remove-Item -LiteralPath $archive -Force
    }
}
Compress-Archive -Path (Join-Path $payloadDirectory '*') -DestinationPath $payloadArchivePath -CompressionLevel Optimal

$payloadBase64 = [Convert]::ToBase64String(
    [IO.File]::ReadAllBytes($payloadArchivePath),
    [Base64FormattingOptions]::InsertLineBreaks
)
$installerHeader = @'
@echo off
chcp 65001 >nul
setlocal
title Code9 IDENT Admin Setup
set "CODE9_INSTALLER=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $source=$env:CODE9_INSTALLER; $marker='__CODE9_PAYLOAD__'; $raw=[IO.File]::ReadAllText($source,[Text.Encoding]::ASCII); $index=$raw.LastIndexOf($marker,[StringComparison]::Ordinal); if($index -lt 0){throw 'Installation payload was not found.'}; $temporary=Join-Path $env:TEMP ('Code9IdentAdminInstall-'+[Guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $temporary|Out-Null; try{$archive=Join-Path $temporary 'admin.zip'; $base64=$raw.Substring($index+$marker.Length); [IO.File]::WriteAllBytes($archive,[Convert]::FromBase64String($base64)); $files=Join-Path $temporary 'files'; Expand-Archive -LiteralPath $archive -DestinationPath $files -Force; & (Join-Path $files 'Setup-IdentAdmin.ps1'); if(-not $?){throw 'Code9 IDENT Admin setup did not finish.'}}finally{Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}"
set "CODE9_RESULT=%ERRORLEVEL%"
if not "%CODE9_RESULT%"=="0" (
  echo.
  echo Installation did not finish. Send this window to the Code9 specialist.
) else (
  echo.
  echo Code9 IDENT Admin installation completed.
)
pause
exit /b %CODE9_RESULT%
__CODE9_PAYLOAD__
'@
$installerPath = Join-Path $installerDirectory '1-INSTALL-ADMIN.cmd'
[IO.File]::WriteAllText($installerPath, ($installerHeader + $payloadBase64 + [Environment]::NewLine), [Text.Encoding]::ASCII)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'README.txt') -Destination (Join-Path $installerDirectory '2-INSTRUCTION.txt')
Compress-Archive -Path (Join-Path $installerDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal

Remove-Item -LiteralPath $payloadArchivePath -Force
Write-Host "Admin package built: $archivePath" -ForegroundColor Green
