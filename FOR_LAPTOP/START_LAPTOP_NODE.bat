@echo off
setlocal
title NearbyChat laptop node
cd /d "%~dp0"

rem ---- find Python 3.11 or newer ----
set PY=
py -3 -c "import sys; sys.exit(0 if sys.version_info>=(3,11) else 1)" >nul 2>&1 && set PY=py -3
if not defined PY python -c "import sys; sys.exit(0 if sys.version_info>=(3,11) else 1)" >nul 2>&1 && set PY=python
if not defined PY (
  echo Python 3.11 or newer, 64 bit, is not installed on this laptop.
  echo Install it once with the python.org installer and tick "Add python.exe to PATH", then run this again.
  echo If this laptop has internet you can also run:  winget install -e --id Python.Python.3.12
  pause
  exit /b 1
)

rem ---- private virtual environment outside OneDrive ----
set VENV=%LOCALAPPDATA%\NearbyChatNode\venv
if not exist "%VENV%\Scripts\python.exe" (
  echo Creating Python environment in %VENV% ...
  %PY% -m venv "%VENV%"
)
rem install from the bundled wheels folder: no internet needed
"%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q --no-index --find-links wheels -r laptop_node\requirements.txt
if errorlevel 1 (
  echo Offline install failed for this Python version, trying the internet once...
  "%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q -r laptop_node\requirements.txt
  if errorlevel 1 (
    echo Could not install the packages. Use Python 3.11 to 3.14 64 bit.
    pause
    exit /b 1
  )
)

rem ---- name of this laptop ----
set NAME=%1
if "%NAME%"=="" if exist "%LOCALAPPDATA%\NearbyChatNode\name.txt" set /p NAME=<"%LOCALAPPDATA%\NearbyChatNode\name.txt"
if "%NAME%"=="" set /p NAME=Name for this laptop (for example LaptopA):
if "%NAME%"=="" set NAME=Laptop
echo %NAME%>"%LOCALAPPDATA%\NearbyChatNode\name.txt"

echo.
echo Starting NearbyChat node "%NAME%". Bluetooth must be ON.
echo Everything runs over Bluetooth LE: no internet, no WiFi, no pairing.
echo.
"%VENV%\Scripts\python.exe" -m laptop_node --name "%NAME%" %2 %3 %4 %5 %6
pause
