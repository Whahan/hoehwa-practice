@echo off
chcp 65001 >nul
title Hoehwa Yeonseup - Uninstall
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set RC=%ERRORLEVEL%
echo.
pause
exit /b %RC%
