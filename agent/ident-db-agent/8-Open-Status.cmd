@echo off
setlocal
set "AGENT_DIR=%LOCALAPPDATA%\Code9\IdentAgent"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AGENT_DIR%\IdentDesktop.ps1" -ConfigPath "%AGENT_DIR%\config.local.json"
