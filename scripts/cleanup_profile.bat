@echo off
REM Script to cleanup Chrome profile directory
REM Usage: cleanup_profile.bat <profile_directory_path>
REM This script runs in the background and deletes the profile directory

REM Get profile directory path from first argument
set PROFILE_DIR=%1

REM Exit if no profile directory provided
if "%PROFILE_DIR%"=="" (
    exit /b 1
)

REM Check if directory exists
if not exist "%PROFILE_DIR%" (
    exit /b 0
)

REM Wait 2 seconds to ensure Chrome has fully released file locks
timeout /t 2 /nobreak >NUL 2>&1

REM Remove the profile directory recursively and quietly
rmdir /s /q "%PROFILE_DIR%" >NUL 2>&1

REM Always exit with success (don't care if deletion failed)
exit /b 0
