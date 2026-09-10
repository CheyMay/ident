param([string]$InstallDirectory,[string]$WorkerTaskName)
Set-Content -LiteralPath (Join-Path $InstallDirectory 'fixture-registration.txt') -Value $WorkerTaskName -Encoding ASCII
