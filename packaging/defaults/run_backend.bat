@echo off
rem Starts the backend alone (package layout). Usage:  run_backend.bat          (console, Ctrl+C to stop)
rem                                               run_backend.bat hidden   (no window; stop with stop_backend.bat)
setlocal
cd /d "%~dp0"
if not exist logs mkdir logs
set "PY=%~dp0..\runtime\python\python.exe"
set "PYW=%~dp0..\runtime\python\pythonw.exe"
if not exist "%PY%" (
  echo runtime\python not found - run the installer first.
  exit /b 1
)
if /I "%~1"=="hidden" (
  start "" /B "%PYW%" "%~dp0server.py"
  exit /b 0
)
"%PY%" -X utf8 "%~dp0server.py"
