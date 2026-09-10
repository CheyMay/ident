Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path ([IO.Path]::GetTempPath()) ('ident-calendar-launcher-test-'+[guid]::NewGuid().ToString('N'))
try {
    $robot=Join-Path $root 'robot'; $null=New-Item -ItemType Directory -Path $robot
    foreach($file in @('Start-IdentCalendarCheck.ps1','RobotCapture.ps1','IdentFillCheck.ps1','IdentCalendar.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repo ('robot/ident-rpa/'+$file)) -Destination (Join-Path $robot $file)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/calendar-check-child.ps1') -Destination (Join-Path $robot 'Start-IdentRobot.ps1')
    $agentConfig=Join-Path $root 'config.local.json'
    @{ features=@{ robotEnabled=$false } } | ConvertTo-Json | Set-Content -LiteralPath $agentConfig -Encoding UTF8
    '{}' | Set-Content -LiteralPath (Join-Path $robot 'config.local.json') -Encoding UTF8
    $pending=Join-Path $robot 'fill-check-pending.json'
    '{"runId":"private-previous-run","stage":"write_intent"}' | Set-Content -LiteralPath $pending -Encoding UTF8
    $before=(Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash
    $launcher=Join-Path $robot 'Start-IdentCalendarCheck.ps1'
    $parameters=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher,'-ConfigPath',(Join-Path $robot 'config.local.json'),
        '-Start','2099-09-20T09:00:00+05:00','-TimeoutSeconds','15')
    $result=@(& powershell.exe @parameters -DoctorCaption 'Doctor B')
    if ($LASTEXITCODE -ne 0 -or ($result -join ' ') -notmatch 'IDENT_CALENDAR_CHECK planned_read_only') { throw 'Calendar launcher failed synthetic planning.' }
    $count=@(Get-ChildItem -LiteralPath (Join-Path $robot 'calendar-checks') -Directory).Count
    $result=@(& powershell.exe @parameters -DoctorCaption 'Doctor B' -DurationMinutes 16)
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'CALENDAR_INVALID_REQUEST' -or
        @(Get-ChildItem -LiteralPath (Join-Path $robot 'calendar-checks') -Directory).Count -ne $count) { throw 'Invalid duration started a child.' }
    @{ features=@{ robotEnabled=$true } } | ConvertTo-Json | Set-Content -LiteralPath $agentConfig -Encoding UTF8
    $result=@(& powershell.exe @parameters -DoctorCaption 'Doctor B')
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'FILL_ROBOT_ENABLED') { throw 'Enabled robot bypassed exclusive checking.' }
    @{ features=@{ robotEnabled=$false } } | ConvertTo-Json | Set-Content -LiteralPath $agentConfig -Encoding UTF8
    $execution=Join-Path $robot 'execution-pending.json'
    '{}' | Set-Content -LiteralPath $execution -Encoding UTF8
    $result=@(& powershell.exe @parameters -DoctorCaption 'Doctor B')
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'FILL_REVIEW_PENDING') { throw 'Pending real booking was ignored.' }
    Remove-Item -LiteralPath $execution
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $result=@(& powershell.exe @parameters -DoctorCaption 'Hang Fixture')
    $watch.Stop()
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'CALENDAR_TIMEOUT' -or $watch.Elapsed.TotalSeconds -gt 30) { throw 'Stuck child was not bounded.' }
    if ((Get-FileHash -LiteralPath $pending -Algorithm SHA256).Hash -cne $before) { throw 'Checking changed pending fill evidence.' }
    foreach($pidFile in @(Get-ChildItem -LiteralPath (Join-Path $robot 'calendar-checks') -Filter 'fixture-pid.txt' -Recurse)) {
        if (Get-Process -Id ([int](Get-Content -LiteralPath $pidFile.FullName -Raw)) -ErrorAction SilentlyContinue) { throw 'Calendar child survived launcher exit.' }
    }
    # The real mode rejects attempts to turn the check into an input run before opening IDENT.
    $result=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'robot/ident-rpa/Start-IdentRobot.ps1') -Mode CalendarCheck -Execute)
    if ($LASTEXITCODE -eq 0 -or ($result -join ' ') -notmatch 'CALENDAR_INVALID_MODE') { throw 'Calendar check allowed Execute.' }
} finally {
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'ident-calendar-launcher-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Host 'IDENT CALENDAR LAUNCHER TESTS OK (isolated fixture processes; no IDENT)'
