@echo off
chcp 65001 >nul
title Hoehwa Yeonseup - Update
cd /d "%~dp0"
rem Everything runs from this single line, so the update may safely replace this .bat file while it runs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" %* & echo. & pause & exit /b
