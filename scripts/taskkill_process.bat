@echo off
REM Script to forcefully kill a process by PID
REM Usage: taskkill_process.bat <pid>
REM This script runs taskkill command in the background

REM Get PID from first argument
set PID=%1

REM Exit if no PID provided
if "%PID%"=="" (
    exit /b 1
)

REM Kill the process tree forcefully (redirect output to NUL to suppress output)
taskkill /T /F /PID %PID% >NUL 2>&1

REM Always exit with success (don't care if process didn't exist)
exit /b 0
