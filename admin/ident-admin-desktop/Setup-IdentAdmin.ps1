[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Code9\IdentAdmin'),
    [string]$BackendUrl = '',
    [Security.SecureString]$ServiceApiKey = $null,
    [switch]$NoShortcut,
    [switch]$NoLaunch
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
Write-Host 'Установка Code9 IDENT Admin' -ForegroundColor Cyan
Write-Host ''

if ([string]::IsNullOrWhiteSpace($BackendUrl)) {
    $BackendUrl = Read-WithDefault -Prompt 'Адрес сервера Code9' -Default 'https://ident.code9dev.ru'
}
$parsedBackendUri = $null
if (
    -not [Uri]::TryCreate($BackendUrl, [UriKind]::Absolute, [ref]$parsedBackendUri) -or
    $parsedBackendUri.Scheme -notin @('http', 'https')
) {
    throw 'Укажите полный адрес сервера, например https://ident.code9dev.ru.'
}
if ($null -eq $ServiceApiKey) {
    Write-Host 'Нужен SERVICE_API_KEY сервера. Ключ агента сюда не подходит.' -ForegroundColor Yellow
    $ServiceApiKey = Read-Host 'Ключ администратора Code9' -AsSecureString
}
if ($ServiceApiKey.Length -eq 0) { throw 'Ключ администратора не может быть пустым.' }

New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'IdentAdminDesktop.ps1') -Destination (Join-Path $InstallDirectory 'IdentAdminDesktop.ps1') -Force

$config = [ordered]@{
    version = 1
    appVersion = '1.0.1'
    backend = [ordered]@{
        baseUrl = $BackendUrl.TrimEnd('/')
        timeoutSeconds = 60
        refreshSeconds = 30
    }
    paths = [ordered]@{
        secrets = 'secrets.local.json'
    }
}
$secrets = [ordered]@{
    version = 1
    serviceApiKeyDpapi = ConvertFrom-SecureString -SecureString $ServiceApiKey
}
$config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $InstallDirectory 'config.local.json') -Encoding UTF8
$secrets | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $InstallDirectory 'secrets.local.json') -Encoding UTF8

$shortcutPath = ''
if (-not $NoShortcut) {
    $desktopDirectory = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopDirectory)) {
        throw 'Не удалось найти рабочий стол Windows.'
    }
    $shortcutPath = Join-Path $desktopDirectory 'Code9 IDENT Admin.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDirectory 'IdentAdminDesktop.ps1')`""
    $shortcut.WorkingDirectory = $InstallDirectory
    $shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,14"
    $shortcut.Save()
}

Write-Host ''
Write-Host "Админское приложение установлено: $InstallDirectory" -ForegroundColor Green
if (-not [string]::IsNullOrWhiteSpace($shortcutPath)) {
    Write-Host "Ярлык создан: $shortcutPath" -ForegroundColor Green
}
if (-not $NoLaunch) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $InstallDirectory 'IdentAdminDesktop.ps1')`""
}

