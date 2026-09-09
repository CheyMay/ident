param([string]$PidFile)
$PID | Set-Content -LiteralPath $PidFile -Encoding ASCII
Start-Sleep -Seconds 120
