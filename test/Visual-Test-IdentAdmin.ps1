[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $env:TEMP 'ident-admin-visual.png'),
    [int]$Port = 4892,
    [ValidateRange(0, 3)][int]$TabSteps = 0
)

$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = Join-Path $env:TEMP ('ident-admin-visual-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
$server = $null
$app = $null

try {
    $env:PORT = [string]$Port
    $env:DATA_DIR = Join-Path $root 'data'
    $env:STORAGE_DRIVER = 'json'
    $env:SERVICE_API_KEY = 'test-service-key'
    $env:AGENT_API_KEY = 'test-agent-key'
    $env:IDENT_INTEGRATION_KEY = 'test-ident-key'
    $env:JOB_WORKER_ENABLED = 'false'
    $server = Start-Process `
        -FilePath 'node.exe' `
        -ArgumentList 'src/index.js' `
        -WorkingDirectory $repository `
        -WindowStyle Hidden `
        -PassThru `
        -RedirectStandardOutput (Join-Path $root 'server.out') `
        -RedirectStandardError (Join-Path $root 'server.err')

    $ready = $false
    for ($attempt = 0; $attempt -lt 30; $attempt += 1) {
        try {
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 1)
            $ready = $true
            break
        }
        catch { Start-Sleep -Milliseconds 200 }
    }
    if (-not $ready) { throw 'Test server did not start.' }

    $agentHeaders = @{ 'X-Agent-Key' = 'test-agent-key'; 'Content-Type' = 'application/json' }
    $heartbeat = @{
        agentId = 'clinic-demo'
        deviceName = 'IDENT-RECEPTION'
        version = '2.4.0'
        status = 'online'
        schedule = @{ enabled = $true; state = 'ok'; doctors = 3; intervals = 24; freeIntervals = 18; lastSuccessAt = (Get-Date).ToString('o'); lastError = '' }
        schema = @{ state = 'ok'; tables = 42; columns = 318; lastError = '' }
        robot = @{ enabled = $false; configured = $false; state = 'disabled'; lastError = '' }
    } | ConvertTo-Json -Depth 6
    [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/agent/heartbeat" -Method Post -Headers $agentHeaders -Body $heartbeat)
    $timetable = @{
        Doctors = @(@{ Id = 1; Name = 'Иванов Иван Иванович' }, @{ Id = 2; Name = 'Петрова Анна Сергеевна' })
        Branches = @(@{ Id = 1; Name = 'Основная клиника' })
        Intervals = @(
            @{ DoctorId = 1; BranchId = 1; StartDateTime = (Get-Date).Date.AddHours(10).ToString('o'); LengthInMinutes = 30; IsBusy = $false },
            @{ DoctorId = 2; BranchId = 1; StartDateTime = (Get-Date).Date.AddHours(11).ToString('o'); LengthInMinutes = 60; IsBusy = $true }
        )
    } | ConvertTo-Json -Depth 6
    [void](Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/agent/timetable" -Method Post -Headers $agentHeaders -Body $timetable)

    $config = [ordered]@{
        version = 1
        appVersion = '1.0.0'
        backend = [ordered]@{ baseUrl = "http://127.0.0.1:$Port"; timeoutSeconds = 10; refreshSeconds = 30 }
        paths = [ordered]@{ secrets = 'secrets.local.json' }
    }
    $config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'config.local.json') -Encoding UTF8
    $secure = ConvertTo-SecureString 'test-service-key' -AsPlainText -Force
    [ordered]@{
        version = 1
        serviceApiKeyDpapi = ConvertFrom-SecureString $secure
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'secrets.local.json') -Encoding UTF8

    $appScript = Join-Path $repository 'admin\ident-admin-desktop\IdentAdminDesktop.ps1'
    $appConfig = Join-Path $root 'config.local.json'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$appScript`" -ConfigPath `"$appConfig`""
    $app = Start-Process `
        -FilePath 'powershell.exe' `
        -ArgumentList $arguments `
        -PassThru `
        -RedirectStandardOutput (Join-Path $root 'app.out') `
        -RedirectStandardError (Join-Path $root 'app.err')
    Start-Sleep -Seconds 5
    if ($app.HasExited) {
        throw ('Admin app exited: ' + (Get-Content -LiteralPath (Join-Path $root 'app.err') -Raw -ErrorAction SilentlyContinue))
    }
    if ($TabSteps -gt 0) {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.AppActivate($app.Id)
        Start-Sleep -Milliseconds 300
        for ($index = 0; $index -lt $TabSteps; $index += 1) {
            $shell.SendKeys('^{TAB}')
            Start-Sleep -Milliseconds 250
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object Drawing.Bitmap($bounds.Width, $bounds.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($OutputPath, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    Write-Output $OutputPath
}
finally {
    if ($null -ne $app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
    if ($null -ne $server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

