@echo off
REM Clean up a single expired browser session
REM Usage: cleanup_expired_session.bat <PID> <PORT> [PROFILE_DIR]
REM Args:
REM   PID - Process ID to kill
REM   PORT - Debug port to clean up port forwarding
REM   PROFILE_DIR - Optional profile directory to delete

setlocal enabledelayedexpansion

set PID=%1
set PORT=%2
set PROFILE_DIR=%3

if "%PID%"=="" (
    exit /b 1
)

if "%PORT%"=="" (
    exit /b 1
)

REM Kill the browser process (force kill with tree)
taskkill /F /PID %PID% /T >nul 2>&1

REM Remove port forwarding
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=%PORT% >nul 2>&1

REM Clean up profile directory if provided (with brief wait for file locks)
if not "%PROFILE_DIR%"=="" (
    if exist "%PROFILE_DIR%" (
        timeout /t 1 /nobreak >nul 2>&1
        rd /s /q "%PROFILE_DIR%" >nul 2>&1
    )
)

exit /b 0
