[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$robotPath = Join-Path $repositoryRoot 'robot\ident-rpa\Start-IdentRobot.ps1'
$tempRoot = Join-Path $PSScriptRoot '.tmp-robot-safety'

try {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $robotPath -Mode SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw 'Robot built-in self-test failed.'
    }

    $config = @{
        backend = @{ baseUrl = ''; serviceApiKey = ''; ticketStatus = 'queued' }
        ident = @{ processName = 'Code9IdentProcessThatDoesNotExist'; windowTitleRegex = '^$' }
        inspect = @{ maxDepth = 1; outputPath = (Join-Path $tempRoot 'ui-tree.json') }
        logDir = (Join-Path $tempRoot 'logs')
        selectors = @{}
        workflow = @{
            allowUnsafeExecution = $true
            confirmBeforeEachStep = $false
            successCondition = @{ type = 'elementMissing'; selector = 'saveButton'; timeoutSeconds = 1 }
            steps = @()
        }
    }
    $task = @{
        id = 'robot-safety-test'
        status = 'robot_processing'
        ticket = @{
            Id = 'robot-safety-test'
            PlanStart = '2026-09-01T10:00:00+03:00'
            DoctorName = 'Doctor Test'
        }
    }
    $configPath = Join-Path $tempRoot 'config.json'
    $taskPath = Join-Path $tempRoot 'task.json'
    $config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $task | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskPath -Encoding UTF8

    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $robotPath `
            -Mode RunOnce `
            -ConfigPath $configPath `
            -TaskFile $taskPath `
            -MaxTasks 1 `
            -Execute 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    if ($exitCode -eq 0) {
        throw 'Robot unexpectedly succeeded without an IDENT window.'
    }
    if ($output -notmatch 'ROBOT_DEFER_IDENT_UNAVAILABLE') {
        throw "Robot did not return the safe IDENT-unavailable marker. Output: $output"
    }

    Write-Host 'IDENT ROBOT SAFETY TEST OK' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
