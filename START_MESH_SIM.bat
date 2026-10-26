@echo off
setlocal
title NearbyChat mesh simulation
cd /d "%~dp0"

rem ---- find Python 3.10 or newer ----
set PY=
py -3 -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)" >nul 2>&1 && set PY=py -3
if not defined PY python -c "import sys; sys.exit(0 if sys.version_info>=(3,10) else 1)" >nul 2>&1 && set PY=python
if not defined PY (
  echo Python 3.10 or newer is not installed.
  pause
  exit /b 1
)

set VENV=%LOCALAPPDATA%\NearbyChatSim\venv
if not exist "%VENV%\Scripts\python.exe" (
  echo Creating Python environment in %VENV% ...
  %PY% -m venv "%VENV%"
)
rem needs internet the first time only
"%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q -r mesh_simulation\requirements.txt
if errorlevel 1 (
  echo Could not install pynacl, flask, matplotlib. Connect to the internet once and run this again.
  pause
  exit /b 1
)

set MODE=%1
if "%MODE%"=="" set MODE=trust

if /i "%MODE%"=="tests" (
  "%VENV%\Scripts\python.exe" -m pytest mesh_simulation\tests -q
  pause
  exit /b 0
)
if /i "%MODE%"=="experiments" (
  "%VENV%\Scripts\python.exe" -m mesh_simulation.experiments.run_experiments
  start "" "mesh_simulation\results\SUMMARY.md"
  pause
  exit /b 0
)

echo.
echo Mesh simulation dashboard, routing mode %MODE%
echo Open http://127.0.0.1:5000 . Keep this window open, close it to stop.
echo.
start "" http://127.0.0.1:5000
"%VENV%\Scripts\python.exe" -m mesh_simulation.dashboard.app --routing %MODE%
pause
