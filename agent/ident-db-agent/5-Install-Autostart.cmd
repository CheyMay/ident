@echo off
setlocal
set "AGENT_DIR=%LOCALAPPDATA%\Code9\IdentAgent"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AGENT_DIR%\Install-IdentAgentTask.ps1" -InstallDirectory "%AGENT_DIR%"
echo.
pause
