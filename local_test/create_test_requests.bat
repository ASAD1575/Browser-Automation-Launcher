@echo off
REM Create multiple test requests to launch multiple browsers on Windows

REM Get the directory where this script is located
set SCRIPT_DIR=%~dp0

for /L %%i in (1,1,3) do (
    echo Creating test request %%i...
    (
        echo {
        echo   "id": "test-%%i-%RANDOM%",
        echo   "requester_id": "local-test",
        echo   "ttl_minutes": 2,
        echo   "chrome_args": ["--window-size=1920,1080"]
        echo }
    ) > "%SCRIPT_DIR%test_request.json"

    timeout /t 6 /nobreak > nul
)
