@echo off
rem Sets up the laptop node environment and runs a 40 second Bluetooth self test.
cd /d "%~dp0"
set PY=
py -3 -c "import sys; sys.exit(0 if sys.version_info>=(3,11) else 1)" >nul 2>&1 && set PY=py -3
if not defined PY python -c "import sys; sys.exit(0 if sys.version_info>=(3,11) else 1)" >nul 2>&1 && set PY=python
if not defined PY ( echo Python 3.11+ not found & pause & exit /b 1 )
set VENV=%LOCALAPPDATA%\NearbyChatNode\venv
if not exist "%VENV%\Scripts\python.exe" %PY% -m venv "%VENV%"
"%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q --no-index --find-links wheels -r laptop_node\requirements.txt > node_pip.log 2>&1
if errorlevel 1 "%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q -r laptop_node\requirements.txt >> node_pip.log 2>&1
"%VENV%\Scripts\python.exe" -m laptop_node.selftest
echo.
echo Self test finished. You can close this window.
pause
