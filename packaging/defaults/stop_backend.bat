@echo off
rem Stops the backend started from this package (only processes running from runtime\python).
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*server.py*' -and $_.CommandLine -like '*python*' -and $_.ExecutablePath -like '*\runtime\python\*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; 'stopped ' + $_.ProcessId }"
