Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('ident-fill-launcher-test-'+[guid]::NewGuid().ToString('N'))
try {
    $robot=Join-Path $root 'robot'; $null=New-Item -ItemType Directory -Path $robot
    foreach($file in @('Start-IdentFillCheck.ps1','RobotCapture.ps1','IdentFillCheck.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo ('robot/ident-rpa/'+$file)) -Destination (Join-Path $robot $file)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/fill-check-child.ps1') -Destination (Join-Path $robot 'Start-IdentRobot.ps1')
    @{ features=@{ robotEnabled=$false } } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.local.json') -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $robot 'config.local.json') -Encoding UTF8
    $request=Join-Path $root 'request.txt'
    'preview' | Set-Content -LiteralPath $request -Encoding ASCII
    $result=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $robot 'Start-IdentFillCheck.ps1') `
        -ConfigPath (Join-Path $robot 'config.local.json') -TaskFile $request -TimeoutSeconds 15)
    if ($LASTEXITCODE -ne 0 -or ($result -join ' ') -notmatch 'IDENT_FILL_CHECK preview') { throw 'Launcher failed a synthetic preview.' }
    $pending=Join-Path $robot 'fill-check-pending.json'
    '{"runId":"previous-private-run","stage":"write_intent"}' | Set-Content -LiteralPath $pending -Encoding UTF8
    $before=(Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash
    $result=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $robot 'Start-IdentFillCheck.ps1') `
        -ConfigPath (Join-Path $robot 'config.local.json') -TaskFile $request -TimeoutSeconds 15 -ObserveChanges)
    if ($LASTEXITCODE -ne 0 -or ($result -join ' ') -notmatch 'IDENT_FILL_CHECK no_change' -or
        (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash -cne $before) { throw 'Observation was blocked or changed pending evidence.' }
    $count=@(Get-ChildItem -LiteralPath (Join-Path $robot 'fill-checks') -Directory).Count
    $result=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $robot 'Start-IdentFillCheck.ps1') `
        -ConfigPath (Join-Path $robot 'config.local.json') -TaskFile $request -Execute -ObserveChanges)
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'FILL_INVALID_MODE' -or
        @(Get-ChildItem -LiteralPath (Join-Path $robot 'fill-checks') -Directory).Count -ne $count) { throw 'Conflicting modes spawned a child.' }
    $result=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $robot 'Start-IdentFillCheck.ps1') `
        -ConfigPath (Join-Path $robot 'config.local.json') -TaskFile $request -Execute)
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'FILL_REVIEW_PENDING' -or
        (Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash -cne $before) { throw 'Execute bypassed the pending receipt.' }
    'hang' | Set-Content -LiteralPath $request -Encoding ASCII
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $robot 'Start-IdentFillCheck.ps1') `
        -ConfigPath (Join-Path $robot 'config.local.json') -TaskFile $request -TimeoutSeconds 15)
    $watch.Stop()
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'FILL_TIMEOUT' -or $watch.Elapsed.TotalSeconds -gt 30) { throw 'Launcher failed to bound a stuck child.' }
    if (-not (Test-Path -LiteralPath (Join-Path $robot 'fill-check-pending.json'))) { throw 'Timeout removed manual-review evidence.' }
    foreach($pidFile in @(Get-ChildItem -LiteralPath (Join-Path $robot 'fill-checks') -Filter 'fixture-pid.txt' -Recurse)) {
        $childId=[int](Get-Content -LiteralPath $pidFile.FullName -Raw)
        if (Get-Process -Id $childId -ErrorAction SilentlyContinue) { throw 'Fill child survived launcher exit.' }
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'ident-fill-launcher-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'IDENT FILL LAUNCHER TESTS OK (isolated fixture processes; no IDENT)'
