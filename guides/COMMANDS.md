# Quick Command Reference

## Initial Setup

```cmd
REM Run as Administrator - Creates scheduled task
cd C:\Users\%USERNAME%\Documents\Applications\browser-automation-launcher\scripts
setup_startup_task.bat
```

## Start Application

### Option 1: Run Scheduled Task
```cmd
schtasks /run /tn "BrowserAutomationStartup"
```

### Option 2: Manual Run
```powershell
cd C:\Users\%USERNAME%\Documents\Applications\browser-automation-launcher\scripts
powershell -ExecutionPolicy Bypass -File ".\simple_startup.ps1"
```

### Option 3: Direct Python Run
```powershell
cd C:\Users\%USERNAME%\Documents\Applications\browser-automation-launcher
poetry run python -m src.main
```

## Stop Application

### Method 1: Graceful Shutdown (Recommended)
```powershell
REM Creates STOP file - app shuts down within 30 seconds without restart
New-Item -ItemType File -Path "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\STOP"
```

### Method 2: Kill Python Process
```powershell
REM Find the process ID
Get-Content C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log -Tail 5

REM Kill the process (replace <PID> with actual number from log)
Stop-Process -Id <PID> -Force
```

### Method 3: Kill All Python Processes (Nuclear Option)
```powershell
REM Stops ALL Python processes - use with caution
Get-Process python | Stop-Process -Force
```

## Update to Latest Code

### Step 1: Stop Running Application
```powershell
REM Create STOP file
New-Item -ItemType File -Path "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\STOP"

REM Wait 30 seconds for graceful shutdown
Start-Sleep -Seconds 30

REM Verify process stopped
Get-Process python -ErrorAction SilentlyContinue
```

### Step 2: Pull Latest Code
```powershell
cd C:\Users\%USERNAME%\Documents\Applications\browser-automation-launcher

REM Stash any local changes
git stash

REM Pull latest code
git pull origin main

REM Update dependencies
poetry install
```

### Step 3: Restart Application
```cmd
REM Run the scheduled task
schtasks /run /tn "BrowserAutomationStartup"
```

## Check Status

### Check if Application is Running
```powershell
REM Check for Python processes
Get-Process python -ErrorAction SilentlyContinue

REM View recent log activity
Get-Content C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log -Tail 10
```

### View Real-Time Logs
```powershell
REM Monitor application activity
Get-Content C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log -Wait -Tail 50

REM Watch application output
Get-Content C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\app-stdout.log -Wait -Tail 50

REM Check for errors
Get-Content C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\app-stderr.log -Wait -Tail 50
```

### Check Scheduled Task Status
```cmd
REM View task details
schtasks /query /tn "BrowserAutomationStartup" /v

REM Check last run time
schtasks /query /tn "BrowserAutomationStartup" /fo LIST | findstr /C:"Last Run Time" /C:"Status"
```

## Manage Scheduled Task

### Disable Auto-Start
```cmd
REM Temporarily disable scheduled task
schtasks /change /tn "BrowserAutomationStartup" /disable
```

### Enable Auto-Start
```cmd
REM Re-enable scheduled task
schtasks /change /tn "BrowserAutomationStartup" /enable
```

### Remove Scheduled Task
```cmd
REM Completely delete the task
schtasks /delete /tn "BrowserAutomationStartup" /f
```

## Troubleshooting

### Clear STOP File (If Exists)
```powershell
REM Remove STOP file if it's preventing startup
Remove-Item C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\STOP -Force -ErrorAction SilentlyContinue
```

### Reset After Max Crashes
```powershell
REM If app stopped after 10 crashes, clear logs and restart
cd C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs

REM Backup crash log
Copy-Item crash.log crash.log.backup -ErrorAction SilentlyContinue

REM Clear crash log
Clear-Content crash.log -ErrorAction SilentlyContinue

REM Restart application
schtasks /run /tn "BrowserAutomationStartup"
```

### Force Clean Restart
```powershell
REM Stop all Python processes
Get-Process python | Stop-Process -Force

REM Wait for cleanup
Start-Sleep -Seconds 5

REM Remove STOP file if exists
Remove-Item C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\STOP -Force -ErrorAction SilentlyContinue

REM Restart
schtasks /run /tn "BrowserAutomationStartup"
```
