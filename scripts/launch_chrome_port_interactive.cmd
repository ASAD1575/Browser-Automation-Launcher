@echo off
REM Chrome Launcher Wrapper - Launches Chrome in Interactive Desktop Session (Session 1)
REM This ensures Chrome windows are visible in RDP
REM Usage: launch_chrome_port_interactive.cmd <PORT> <LISTEN_IP>

setlocal ENABLEEXTENSIONS

REM Get parameters
set "PORT=%~1"
set "LISTEN_IP=%~2"

if "%PORT%"=="" (
    echo ERROR: Port parameter required
    exit /b 1
)

if "%LISTEN_IP%"=="" (
    echo ERROR: Listen IP parameter required
    exit /b 1
)

REM Call PowerShell launcher script which ensures Chrome launches in interactive session
REM PowerShell automatically inherits the session context, and if called from interactive session,
REM Chrome will launch in that same session and be visible in RDP

powershell.exe -ExecutionPolicy Bypass -File "C:\Chrome-RDP\launch_chrome_port_interactive.ps1" -Port %PORT% -ListenIP %LISTEN_IP%

REM Exit with PowerShell's exit code
exit /b %ERRORLEVEL%

