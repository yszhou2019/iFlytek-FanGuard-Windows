@echo off
rem ---------------------------------------------------------------------------
rem  FanGuard - UNINSTALL
rem  Removes the scheduled task, stops the guard and releases the target
rem  process back to full speed. Use this before deleting or moving this folder.
rem
rem  To start guarding again, run install.cmd.
rem  Administrator rights are acquired automatically.
rem ---------------------------------------------------------------------------
setlocal
pushd "%~dp0"

echo.
echo   FanGuard - uninstall
echo   --------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FanGuard.ps1" uninstall
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" (
    echo   FAILED ^(exit code %RC%^). Right-click this file and choose
    echo   "Run as administrator".
) else (
    echo   Done. The task is removed and the process is back at full speed.
)
echo.
pause
popd
endlocal
