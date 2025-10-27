@echo off
REM Setup scheduled task for Browser Automation Launcher with Admin Rights

REM Check if running as Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ERROR: This script must be run as Administrator!
    echo.
    echo Please right-click on this file and select "Run as Administrator"
    echo.
    pause
    exit /b 1
)

echo Setting up Browser Automation Launcher startup task with Administrator privileges...

REM Get current username for task
set TASK_USER=%USERDOMAIN%\%USERNAME%

REM Delete existing task if it exists
schtasks /delete /tn "BrowserAutomationStartup" /f 2>nul

REM Create new task with admin privileges
echo.

schtasks /create ^
    /tn "BrowserAutomationStartup" ^
    /tr "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%USERPROFILE%\Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1\"" ^
    /sc onlogon ^
    /ru "%TASK_USER%" ^
    /rl highest ^
    /f

if %errorlevel% == 0 (
    echo.
    echo Success! Browser Automation Launcher will start with ADMIN RIGHTS when you log in.
    echo.
    echo The task will:
    echo - Run as: %TASK_USER% with Administrator privileges
    echo - Trigger: When you log in to Windows
    echo - Run continuously without time limit
    echo - Interactive desktop enabled (allows Chrome to launch GUI)
    echo - No UAC prompt will appear when it runs
    echo.
    echo To stop the application without auto-restart:
    echo - Create a STOP file: New-Item -ItemType File -Path "%USERPROFILE%\Documents\Applications\browser-automation-launcher\logs\STOP"
    echo - Or kill the Python process with Stop-Process
    echo.
    echo You can test it now by running:
    echo schtasks /run /tn "BrowserAutomationStartup"
) else (
    echo.
    echo Failed to create scheduled task.
    echo Make sure you entered your password correctly.
)

echo.
pause
