@echo off
REM Script to cleanup Chrome profiles older than 24 hours
REM Usage: cleanup_old_profiles.bat <profile_base_directory> <max_age_hours>
REM Example: cleanup_old_profiles.bat "C:\Chrome-RDP" 24

setlocal enabledelayedexpansion

REM Get parameters
set "PROFILE_DIR=%~1"
set "MAX_AGE_HOURS=%~2"

REM Default values if not provided
if "%PROFILE_DIR%"=="" set "PROFILE_DIR=C:\Chrome-RDP"
if "%MAX_AGE_HOURS%"=="" set "MAX_AGE_HOURS=24"

REM Check if profile directory exists
if not exist "%PROFILE_DIR%" (
    echo Profile directory does not exist: %PROFILE_DIR%
    exit /b 0
)

echo Cleaning up profiles in: %PROFILE_DIR%
echo Max age: %MAX_AGE_HOURS% hours
echo.

REM Calculate cutoff time (current time - max age hours)
REM Get current time in minutes since epoch (approximate)
for /f "tokens=1-3 delims=:." %%a in ("%time%") do (
    set /a "current_hour=%%a"
    set /a "current_min=%%b"
)

for /f "tokens=1-3 delims=/-" %%a in ("%date%") do (
    set "current_day=%%b"
    set "current_month=%%a"
    set "current_year=%%c"
)

set /a "cutoff_hours=%MAX_AGE_HOURS%"

REM Counter for deleted profiles
set /a deleted_count=0

REM Loop through all subdirectories (profile folders only, not files)
for /d %%D in ("%PROFILE_DIR%\*") do (
    REM Get the directory name
    set "profile_path=%%D"
    set "profile_name=%%~nxD"

    REM Only process directories (folders), skip files
    if exist "%%D\*" (
        REM Check if directory starts with 'p' followed by digits (custom launcher pattern)
        REM OR starts with 'chrome_profile_' (default pattern)
        echo !profile_name! | findstr /r "^p[0-9][0-9]*$" >nul
        if !errorlevel! equ 0 (
            set "is_profile=1"
        ) else (
            echo !profile_name! | findstr /b "chrome_profile_" >nul
            if !errorlevel! equ 0 (
                set "is_profile=1"
            ) else (
                set "is_profile=0"
            )
        )

        if !is_profile! equ 1 (
            REM Use forfiles to check if directory is older than specified hours
            forfiles /P "%%D" /C "cmd /c exit 0" /D -%MAX_AGE_HOURS% >nul 2>&1

            REM If forfiles succeeds, directory is older than cutoff
            if !errorlevel! equ 0 (
                echo Deleting old profile folder: !profile_name!

                REM Wait a moment to ensure no locks
                timeout /t 1 /nobreak >nul 2>&1

                REM Delete the directory recursively (folder only)
                rmdir /s /q "%%D" >nul 2>&1

                if !errorlevel! equ 0 (
                    echo   SUCCESS: Deleted !profile_name!
                    set /a deleted_count+=1
                ) else (
                    echo   WARNING: Could not delete !profile_name! (may be in use)
                )
            )
        )
    )
)

echo.
echo Cleanup completed: %deleted_count% profile(s) deleted
exit /b 0
