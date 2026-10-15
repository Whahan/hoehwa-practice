@echo off
rem Starts the backend. Usage:  run_backend.bat            (console window, Ctrl+C to stop)
rem                            run_backend.bat hidden      (no window, via pythonw; stop with stop_backend.bat or Task Manager)
setlocal
cd /d "%~dp0"
if not exist logs mkdir logs
set HF_HOME=%~dp0models\hf
set HF_HUB_CACHE=%~dp0models\hf
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
if /I "%~1"=="hidden" (
  start "" /B "%~dp0.venv\Scripts\pythonw.exe" "%~dp0server.py"
  exit /b 0
)
"%~dp0.venv\Scripts\python.exe" "%~dp0server.py"
