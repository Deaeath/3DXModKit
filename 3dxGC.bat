@echo off
setlocal EnableExtensions
cd /d "%~dp0"

:: ===========================================================================
::  3dxGC - double-click launcher
::
::  Requests elevation once, because four of the five RAMMap-equivalent
::  operations (standby list, modified page list, system working set, and the
::  system-wide working set purge) fail without it. If you decline the UAC
::  prompt it still runs - per-process trimming needs no privileges at all -
::  so declining costs you the system-wide operations, not the tool.
:: ===========================================================================

title 3dxGC

if not exist "gui\Start-Gui.ps1" (
    echo.
    echo   ERROR: gui\Start-Gui.ps1 not found.
    echo.
    echo   Extract the whole folder and run this file from inside it.
    echo   Current folder: %CD%
    echo.
    pause
    exit /b 1
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo   ERROR: Windows PowerShell not found on PATH.
    echo.
    pause
    exit /b 1
)

:: Already elevated? Go.
net session >nul 2>&1
if not errorlevel 1 goto run

:: Not elevated. Relaunch this script through UAC.
if /i "%~1"=="-elevated" goto run_unelevated

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Start-Process -FilePath '%~f0' -ArgumentList '-elevated' -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"

if not errorlevel 1 exit /b 0

:run_unelevated
echo.
echo   Running without administrator.
echo   Per-process trimming works; system-wide purges will report as skipped.
echo.

:run
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0gui\Start-Gui.ps1"
exit /b 0
