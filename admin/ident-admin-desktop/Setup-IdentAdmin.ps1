[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Code9\IdentAdmin')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Read-WithDefault {
    param([string]$Prompt, [string]$Default)
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value.Trim()
}

Write-Host ''
Write-Host 'Code9 IDENT Admin setup' -ForegroundColor Cyan
Write-Host ''

$backendUrl = Read-WithDefault -Prompt 'Code9 backend URL' -Default 'https://ident.code9dev.ru'
$serviceKey = Read-Host 'Code9 service API key' -AsSecureString
if ($serviceKey.Length -eq 0) { throw 'Service API key cannot be empty.' }

New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'IdentAdminDesktop.ps1') -Destination (Join-Path $InstallDirectory 'IdentAdminDesktop.ps1') -Force

$config = [ordered]@{
    version = 1
    appVersion = '1.0.0'
    backend = [ordered]@{
        baseUrl = $backendUrl.TrimEnd('/')
        timeoutSeconds = 60
        refreshSeconds = 30
    }
    paths = [ordered]@{
        secrets = 'secrets.local.json'
    }
}
$secrets = [ordered]@{
    version = 1
    serviceApiKeyDpapi = ConvertFrom-SecureString -SecureString $serviceKey
}
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $InstallDirectory 'config.local.json') -Encoding UTF8
$secrets | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $InstallDirectory 'secrets.local.json') -Encoding UTF8

$desktopDirectory = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktopDirectory 'Code9 IDENT Admin.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = 'powershell.exe'
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDirectory 'IdentAdminDesktop.ps1')`""
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,14"
$shortcut.Save()

Write-Host ''
Write-Host "Admin application installed: $InstallDirectory" -ForegroundColor Green
Write-Host "Desktop shortcut created: $shortcutPath" -ForegroundColor Green
Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDirectory 'IdentAdminDesktop.ps1')`""

