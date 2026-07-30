@echo off
setlocal
set "AGENT_DIR=%LOCALAPPDATA%\Code9\IdentAgent"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%AGENT_DIR%\Uninstall-IdentAgentTask.ps1"
echo.
pause
