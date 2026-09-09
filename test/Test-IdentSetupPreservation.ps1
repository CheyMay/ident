[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('ident-setup-preservation-' + [guid]::NewGuid().ToString('N'))))
if (-not $root.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path.' }
$process = $null
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $files = @('config.local.json', 'secrets.local.json', 'IdentWorker.ps1')
    $hashes = @{}
    foreach ($file in $files) {
        Set-Content -LiteralPath (Join-Path $root $file) -Value '{}' -Encoding UTF8
        $hashes[$file] = (Get-FileHash -LiteralPath (Join-Path $root $file)).Hash
    }
    $setup = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\agent\ident-db-agent\Setup-IdentAgent.ps1'))
    $process = Start-Process powershell.exe -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $root 'setup-output.log') -RedirectStandardError (Join-Path $root 'setup-error.log') `
        -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$setup`" -InstallDirectory `"$root`" -SkipAutostart -NoShortcut -NoLaunch"
    $null = $process.Handle
    if (-not $process.WaitForExit(10000)) { throw 'Repeated setup did not stop promptly.' }
    if ($process.ExitCode -eq 0) { throw 'Repeated initial setup unexpectedly succeeded.' }
    foreach ($file in $files) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $file)).Hash -ne $hashes[$file]) { throw "REPEATED_SETUP_CHANGED_EXISTING_FILE: $file" }
    }
    if ((Get-Content -LiteralPath (Join-Path $root 'setup-error.log') -Raw) -notmatch 'IDENT_ALREADY_INSTALLED') { throw 'Setup did not explain the protected installation.' }
    Write-Host 'IDENT SETUP PRESERVATION OK: repeated initial setup fails before changing files or credentials.'
} finally {
    if ($null -ne $process) {
        if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1500) }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
