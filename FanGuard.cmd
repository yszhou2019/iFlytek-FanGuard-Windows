@echo off
rem FanGuard launcher - lets you double-click this file.
rem Usage: FanGuard.cmd install | status | uninstall | test
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0FanGuard.ps1" %*
echo.
pause
