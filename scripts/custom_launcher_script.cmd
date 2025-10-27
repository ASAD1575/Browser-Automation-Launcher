@echo off
setlocal ENABLEEXTENSIONS

REM ===== Usage =====
if "%~2"=="" (
  echo Usage: %~nx0 ^<port^> ^<listen_ip^>
  echo Example: %~nx0 9220 172.31.28.23
  exit /b 1
)

set "PORT=%~1"
set "LISTEN_IP=%~2"

REM ===== Validate port =====
set /a PORTNUM=%PORT% >nul 2>&1 || (echo [ERROR] Port must be numeric.& exit /b 1)
if %PORTNUM% LSS 1  (echo [ERROR] Port out of range.& exit /b 1)
if %PORTNUM% GTR 65535 (echo [ERROR] Port out of range.& exit /b 1)

REM ===== Locate Chrome =====
set "CHROME=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME%" set "CHROME=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
if not exist "%CHROME%" (echo [ERROR] Chrome not found at default paths.& exit /b 1)

REM ===== Prep dirs =====
set "BASEDIR=C:\Chrome-RDP"
set "PROFILE=%BASEDIR%\p%PORTNUM%"
if not exist "%BASEDIR%" mkdir "%BASEDIR%" >nul 2>&1
if not exist "%PROFILE%" mkdir "%PROFILE%" >nul 2>&1

REM ===== Ensure IP Helper for portproxy =====
sc query iphlpsvc | find "RUNNING" >nul || net start iphlpsvc >nul

REM ===== Clean any old mappings that could conflict/loop =====
for %%A in (0.0.0.0 127.0.0.1 %LISTEN_IP%) do (
  netsh interface portproxy delete v4tov4 listenaddress=%%A listenport=%PORTNUM% >nul 2>&1
)

REM ===== Launch Chrome bound to loopback only =====
REM echo [Chrome %PORTNUM%] Launching headed Chrome on 127.0.0.1:%PORTNUM% (profile "%PROFILE%") 1>&2
start "" "%CHROME%" ^
  --remote-debugging-port=%PORTNUM% ^
  --user-data-dir="%PROFILE%" ^
  --no-first-run --no-default-browser-check ^
  --proxy-server="http=brd.superproxy.io:33335;https=brd.superproxy.io:33335" ^
  --proxy-bypass-list="localhost;127.0.0.1;<-loopback>;*.local"

REM ===== Wait briefly for Chrome to start and find its PID =====
timeout /t 1 /nobreak >nul 2>&1
for /f "tokens=2" %%p in ('netstat -ano ^| findstr ":%PORTNUM% " ^| findstr "LISTENING"') do (
  set CHROME_PID=%%p
  goto :pid_found
)
:pid_found

REM ===== Output Chrome PID to stdout for Python to capture =====
if defined CHROME_PID (
  echo %CHROME_PID%
) else (
  echo 0
)

REM ===== Expose externally on your LAN IP (avoids self-loop) =====
netsh interface portproxy add v4tov4 listenaddress=%LISTEN_IP% listenport=%PORTNUM% connectaddress=127.0.0.1 connectport=%PORTNUM% || (
  echo [ERROR] netsh portproxy add failed. Check LISTEN_IP "%LISTEN_IP%" and that IP exists on this host.
  exit /b 1
)

REM ===== Open Windows Firewall for this port =====
netsh advfirewall firewall delete rule name="Chrome DevTools %PORTNUM%" >nul 2>&1
netsh advfirewall firewall add    rule name="Chrome DevTools %PORTNUM%" dir=in action=allow protocol=TCP localport=%PORTNUM% >nul

REM Output info to stderr (Python reads PID from stdout)
REM echo. 1>&2
REM echo Ready. From a remote host: 1>&2
REM echo   http://%LISTEN_IP%:%PORTNUM%/json/version 1>&2
REM echo Connect using the exact "webSocketDebuggerUrl" returned. 1>&2
REM echo. 1>&2

endlocal
