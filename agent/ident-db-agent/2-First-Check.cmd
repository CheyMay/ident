@echo off
setlocal
set "AGENT_DIR=%LOCALAPPDATA%\Code9\IdentAgent"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AGENT_DIR%\IdentAgent.ps1" -ConfigPath "%AGENT_DIR%\config.local.json" -DiscoverInstances
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AGENT_DIR%\IdentAgent.ps1" -ConfigPath "%AGENT_DIR%\config.local.json" -TestConnection
echo.
pause
