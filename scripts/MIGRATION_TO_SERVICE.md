# Migration Guide: Scheduled Task → Windows Service

## Quick Migration Steps

### Step 1: Install the Windows Service

Run as Administrator on your EC2 instance:

```powershell
cd C:\Users\Administrator\Documents\Applications\browser-automation-launcher\scripts
.\install_service.ps1
```

### Step 2: Verify Service is Running

```powershell
Get-Service -Name "BrowserAutomationLauncher"

# Should show:
# Status   Name               DisplayName
# ------   ----               -----------
# Running  BrowserAutomation... Browser Automation Launcher
```

### Step 3: Monitor for 24 Hours

Check service logs:

```powershell
# View service output
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stdout.log" -Tail 50

# View application monitor log
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 50
```

### Step 4: Disable Old Scheduled Task (Optional)

Once you've verified the service is working correctly:

```powershell
# Disable the old scheduled task
schtasks /change /tn "BrowserAutomationStartup" /disable

# Or delete it completely (after confirming service works)
schtasks /delete /tn "BrowserAutomationStartup" /f
```

### Step 5: Update AMI User Data (For New Instances)

Update `scripts/setup_login.ps1` to include service installation:

Add this section after CloudWatch agent setup:

```powershell
# Install Browser Automation Launcher as Windows Service
$ServiceScript = Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher\scripts\install_service.ps1"
if (Test-Path $ServiceScript) {
    Write-Host "Installing Browser Automation Launcher as Windows Service..."
    try {
        & powershell.exe -ExecutionPolicy Bypass -File $ServiceScript
        Write-Host "Service installation completed"
    } catch {
        Write-Host "WARNING: Service installation failed: $_"
    }
} else {
    Write-Host "Service installation script not found"
}
```

---

## Service Management Commands

### Start Service
```powershell
Start-Service -Name "BrowserAutomationLauncher"
```

### Stop Service
```powershell
Stop-Service -Name "BrowserAutomationLauncher"
```

### Restart Service
```powershell
Restart-Service -Name "BrowserAutomationLauncher"
```

### Check Status
```powershell
Get-Service -Name "BrowserAutomationLauncher"
```

### View Service Configuration
```powershell
& "C:\Program Files\nssm\nssm.exe" get "BrowserAutomationLauncher" all
```

### View Service Logs
```powershell
# Service stdout
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stdout.log" -Tail 50

# Service stderr
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stderr.log" -Tail 50

# Application monitor log
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 50
```

---

## Uninstall Service

If you need to remove the service:

```powershell
.\install_service.ps1 -Uninstall
```

Or manually:

```powershell
Stop-Service -Name "BrowserAutomationLauncher" -Force
& "C:\Program Files\nssm\nssm.exe" remove "BrowserAutomationLauncher" confirm
```

---

## Testing Service Resilience

### Test 1: Reboot Test
```powershell
# Reboot the system
Restart-Computer -Force

# After reboot, wait 5 minutes, then check:
Get-Service -Name "BrowserAutomationLauncher"
Get-Process python | Where-Object { $_.CommandLine -like "*src.main*" }
```

**Expected**: Service should be `Running` and Python process should exist.

### Test 2: Service Recovery Test
```powershell
# Stop the service
Stop-Service -Name "BrowserAutomationLauncher"

# Kill any Python processes manually
Stop-Process -Name python -Force -ErrorAction SilentlyContinue

# Wait 30 seconds
Start-Sleep -Seconds 30

# Check if service restarted and app is running
Get-Service -Name "BrowserAutomationLauncher"
Get-Process python -ErrorAction SilentlyContinue
```

**Expected**: Service should restart automatically (via NSSM configuration).

### Test 3: Application Crash Test
```powershell
# Find and kill the Python process running the app
$pythonProc = Get-Process python | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like "*src.main*"
}
Stop-Process -Id $pythonProc.Id -Force

# Wait 30-60 seconds
Start-Sleep -Seconds 60

# Check if application restarted (simple_startup.ps1 should restart it)
Get-Process python | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like "*src.main*"
}
```

**Expected**: Application should restart automatically (via `simple_startup.ps1` monitoring).

---

## Troubleshooting

### Service Won't Start

1. **Check NSSM logs**:
   ```powershell
   Get-EventLog -LogName Application -Source NSSM -Newest 10
   ```

2. **Check service stdout/stderr**:
   ```powershell
   Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stdout.log" -Tail 50
   Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stderr.log" -Tail 50
   ```

3. **Verify startup script path**:
   ```powershell
   Test-Path "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1"
   ```

4. **Check NSSM configuration**:
   ```powershell
   & "C:\Program Files\nssm\nssm.exe" get "BrowserAutomationLauncher" all
   ```

### Service Starts but Application Doesn't Run

1. **Check application logs**:
   ```powershell
   Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\startup.log" -Tail 50
   Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 50
   ```

2. **Check if Python is installed**:
   ```powershell
   Test-Path "C:\Program Files\Python312\python.exe"
   ```

3. **Check project directory**:
   ```powershell
   Test-Path "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\pyproject.toml"
   ```

---

## Benefits of Service Approach

✅ **Automatic Startup**: Starts at boot, before user logon  
✅ **Update Resilience**: Survives Windows updates and AMI updates  
✅ **Crash Recovery**: Automatic restart on failure  
✅ **No User Dependency**: Runs without user logged in  
✅ **Monitoring Integration**: Shows in Services MMC and can be monitored via CloudWatch  
✅ **Production Ready**: Standard approach for enterprise Windows applications  

---

## Rollback Plan

If you need to rollback to scheduled task:

1. **Stop and uninstall service**:
   ```powershell
   .\install_service.ps1 -Uninstall
   ```

2. **Re-enable scheduled task**:
   ```powershell
   schtasks /change /tn "BrowserAutomationStartup" /enable
   ```

3. **Trigger task**:
   ```powershell
   schtasks /run /tn "BrowserAutomationStartup"
   ```

---

**Note**: Keep both service and scheduled task enabled for a few days during migration to ensure service reliability before removing the scheduled task.

