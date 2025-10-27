@echo off
REM Script to cleanup Windows port forwarding for a specific port
REM Usage: cleanup_port.bat <port_number>
REM This script runs netsh command to remove port proxy mapping

REM Get port number from first argument
set PORT=%1

REM Exit if no port provided
if "%PORT%"=="" (
    exit /b 1
)

REM Remove port forwarding rule (redirect output to NUL to suppress output)
netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=%PORT% >NUL 2>&1

REM Always exit with success (don't care if rule didn't exist)
exit /b 0
