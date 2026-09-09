[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repository=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-child-lifetime-'+[guid]::NewGuid().ToString('N'))))
if (-not $temp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test path.' }
$owner=$null; $child=$null
try {
    New-Item -ItemType Directory -Path $temp | Out-Null
    $fixture=Join-Path $PSScriptRoot 'fixtures\worker-child-owner.ps1'
    $owner=Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList (
        "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$fixture`" -Repository `"$repository`" -TestDirectory `"$temp`"")
    $null=$owner.Handle
    $pidFile=Join-Path $temp 'child.pid'
    $until=[DateTimeOffset]::Now.AddSeconds(10)
    while (-not (Test-Path $pidFile) -and [DateTimeOffset]::Now -lt $until) { Start-Sleep -Milliseconds 100 }
    $child=Get-Process -Id ([int](Get-Content $pidFile -Raw))
    $null=$child.Handle
    $owner.Kill()
    if (-not $owner.WaitForExit(1500)) { throw 'Test owner did not stop.' }
    if (-not $child.WaitForExit(2500)) { throw 'CHILD_SURVIVED_OWNER_CRASH: a worker child can keep running after its owner exits.' }
    Write-Host 'IDENT CHILD LIFETIME OK: owner crash stops its child.'
}
finally {
    foreach ($process in @($owner,$child)) {
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
            $process.Dispose()
        }
    }
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
