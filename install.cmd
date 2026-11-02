@echo off
rem ---------------------------------------------------------------------------
rem  FanGuard - INSTALL
rem  Registers the logon-triggered scheduled task and starts limiting the CPU
rem  of the target process right away.
rem
rem  Edit FanGuard.config.json first if you want a different limit
rem  ("targetCpuPercent" is the number shown in Task Manager).
rem  Administrator rights are acquired automatically.
rem ---------------------------------------------------------------------------
setlocal
pushd "%~dp0"

echo.
echo   FanGuard - install
echo   ------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FanGuard.ps1" install
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
    echo   FAILED ^(exit code %RC%^). Right-click this file and choose
    echo   "Run as administrator".
) else (
    echo   Done. FanGuard is now active and starts again at every logon.
)
echo.
pause
popd
endlocal
