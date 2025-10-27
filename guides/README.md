# Browser Automation Launcher Scripts

This directory contains scripts for automatically starting and monitoring the Browser Automation Launcher on Windows.

## Recent Updates (2025-10-08)

- ✅ Added `/it` flag to scheduled task for interactive desktop support (allows Chrome to launch)
- ✅ Added graceful shutdown mechanism via STOP file
- ✅ Improved exit code detection to distinguish manual termination from crashes
- ✅ Manual termination (Stop-Process) no longer triggers auto-restart
- ✅ Changed trigger from `onlogon` to `onstart` for system-wide startup
- ✅ Limited restart attempts to 5 (prevents infinite restart loops)
- ✅ Added dedicated `crash.log` with detailed crash information
- ✅ Progressive restart delays: 30s → 1m → 2m → 5m → STOP (~8.5 min total)

## Quick Start

### 1. Setup (Run as Administrator)

```cmd
cd C:\Users\%USERNAME%\Documents\Applications\browser-automation-launcher\scripts
setup_startup_task.bat
```

This creates a scheduled task that runs the application at system startup with administrator privileges.

### 2. Test the Setup

```powershell
# Run the scheduled task
schtasks /run /tn "BrowserAutomationStartup"

# Or run the script directly
powershell -ExecutionPolicy Bypass -File ".\simple_startup.ps1"
```

## Monitoring

### Log Files

All logs are in the `logs` folder:

- `startup.log` - Installation and setup progress
- `monitor.log` - Application status and restart events
- `crash.log` - Detailed crash information with stack traces
- `app-stdout.log` - Application output (rotated daily, kept 2 days)
- `app-stderr.log` - Application errors (rotated daily, kept 2 days)

### View Logs

```powershell
# Watch real-time activity
Get-Content "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Wait -Tail 50

# Check recent application output
Get-Content "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\app-stdout.log" -Tail 50

# View crash details
Get-Content "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\crash.log" -Tail 50

# Check for errors
Get-Content "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\app-stderr.log" -Tail 50
```

## How It Works

The `simple_startup.ps1` script automatically:

1. Waits 1 minute for Windows to fully start
2. Installs Python 3.12 and Poetry if not present
3. Creates .env file with staging configuration
4. Installs project dependencies
5. Starts the application
6. Monitors every 30 seconds and restarts on crash (max 5 attempts):
   - 1st crash: wait 30s → restart
   - 2nd crash: wait 1m → restart
   - 3rd crash: wait 2m → restart
   - 4th crash: wait 5m → restart
   - 5th crash: **STOP** (no more restarts)
7. Resets failure counter after 5 minutes of stable operation
8. Logs crash details to `crash.log`

## Stopping the Application

### Method 1: Create STOP file (Recommended)

```powershell
New-Item -ItemType File -Path "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\STOP"
```

The application detects this file and shuts down within 30 seconds without restarting.

### Method 2: Kill Python process

```powershell
# Get PID from monitor log
Get-Content C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log -Tail 5

# Stop the process (replace <PID> with actual number)
Stop-Process -Id <PID> -Force
```

The script detects manual termination and will NOT restart.

## Troubleshooting

### Application won't start
1. Check `startup.log` for installation errors
2. Verify Python and Poetry installed: `python --version` and `poetry --version`
3. Check `app-stderr.log` for application errors

### Task doesn't run at startup
1. Verify task exists: `schtasks /query /tn "BrowserAutomationStartup"`
2. Check Windows Event Viewer > Task Scheduler for errors
3. Ensure you ran `setup_startup_task.bat` as Administrator

### Application keeps crashing
1. Check `crash.log` for detailed crash information
2. Review `app-stderr.log` for error messages
3. After 5 crashes (~8.5 minutes), application stops automatically
4. To restart: `schtasks /run /tn "BrowserAutomationStartup"`

## Diagnostics

### Check if application is running

```powershell
# Check Python processes
Get-Process python -ErrorAction SilentlyContinue

# View monitor log
Get-Content "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 20
```

### Check task status

```powershell
# Verify scheduled task
schtasks /query /tn "BrowserAutomationStartup" /v

# Check last run time
schtasks /query /tn "BrowserAutomationStartup" /fo LIST | Select-String -Pattern "Last Run Time","Status"
```

### Find process details

```powershell
# Get PID from monitor log
Get-Content "C:\Users\$env:USERNAME\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 5

# Check if process is running (replace <PID> with actual number)
Get-Process -Id <PID> -ErrorAction SilentlyContinue
```

## Advanced

### Manage scheduled task

```cmd
# Disable task temporarily
schtasks /change /tn "BrowserAutomationStartup" /disable

# Enable task
schtasks /change /tn "BrowserAutomationStartup" /enable

# Delete task completely
schtasks /delete /tn "BrowserAutomationStartup" /f
```

### Run application manually

```powershell
cd C:\Users\%USERNAME%\Documents\Applications\browser-automation-launcher
poetry run python -m src.main
```

## Notes

- Chrome must be installed
- Uses staging environment configuration
- Repository location: `Documents\Applications\browser-automation-launcher`
- Log timestamps are in local time
- App logs (stdout/stderr) rotated daily, kept 2 days
