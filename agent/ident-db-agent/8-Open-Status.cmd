@echo off
setlocal
set "AGENT_DIR=%LOCALAPPDATA%\Code9\IdentAgent"
start "" /min powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%AGENT_DIR%\IdentDesktop.ps1" -ConfigPath "%AGENT_DIR%\config.local.json"
