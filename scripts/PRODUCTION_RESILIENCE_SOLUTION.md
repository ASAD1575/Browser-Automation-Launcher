# Production Resilience Solution - Application Auto-Restart After Windows/AMI Updates

## Problem Statement

When Windows Server 2025 receives updates or AWS updates the AMI, the scheduled task (`BrowserAutomationStartup`) may fail to start the application automatically because:

1. **Scheduled Task Dependency**: Task depends on user logon (`/sc onlogon`), which may not occur immediately after updates
2. **Task State Corruption**: Windows updates can disable or corrupt scheduled tasks
3. **Service Restart Delays**: System services restart in a specific order, and the task may run before all dependencies are ready
4. **AMI Updates**: New AMI instances may have different configurations or missing task definitions

---

## Solution Options (Ranked by Production Readiness)

### ✅ **Solution 1: Windows Service (RECOMMENDED for Production)**

Windows Services are the most resilient mechanism for production applications. They:
- Start automatically at system boot (before logon)
- Survive Windows updates and reboots
- Run under SYSTEM account with proper permissions
- Can be configured for automatic recovery on failure
- Survive AMI updates if properly configured in user data

#### Implementation Steps

##### Step 1: Create NSSM-Based Service Wrapper

**Create**: `scripts/install_service.ps1`

```powershell
# Install Browser Automation Launcher as Windows Service using NSSM
# Run as Administrator

$ErrorActionPreference = "Stop"

# Configuration
$ServiceName = "BrowserAutomationLauncher"
$ServiceDisplayName = "Browser Automation Launcher"
$ServiceDescription = "Runs Browser Automation Launcher application with automatic restart on failure"
$ProjectPath = Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher"
$StartupScript = Join-Path $ProjectPath "scripts\simple_startup.ps1"

Write-Host "Installing $ServiceDisplayName as Windows Service..."

# Step 1: Download and install NSSM (Non-Sucking Service Manager)
$NSSMPath = "C:\Program Files\nssm\nssm.exe"
$NSSMDir = "C:\Program Files\nssm"

if (-not (Test-Path $NSSMPath)) {
    Write-Host "NSSM not found. Downloading and installing..."
    
    # Create directory
    if (-not (Test-Path $NSSMDir)) {
        New-Item -ItemType Directory -Path $NSSMDir -Force | Out-Null
    }
    
    # Download NSSM
    $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $nssmZip = "$env:TEMP\nssm.zip"
    $nssmExtract = "$env:TEMP\nssm-extract"
    
    Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing
    
    # Extract
    Expand-Archive -Path $nssmZip -DestinationPath $nssmExtract -Force
    
    # Copy appropriate architecture (assume 64-bit)
    $nssmExe = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" | Where-Object { $_.Directory.Name -eq "win64" } | Select-Object -First 1
    if ($nssmExe) {
        Copy-Item $nssmExe.FullName -Destination $NSSMPath -Force
    } else {
        throw "NSSM executable not found in archive"
    }
    
    # Cleanup
    Remove-Item $nssmZip -Force
    Remove-Item $nssmExtract -Recurse -Force
    
    Write-Host "NSSM installed successfully"
}

# Step 2: Remove existing service if it exists
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Removing existing service..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath $NSSMPath -ArgumentList "remove", $ServiceName, "confirm" -Wait -NoNewWindow
    Start-Sleep -Seconds 2
}

# Step 3: Create the service
Write-Host "Creating Windows Service..."

# Install service using PowerShell (wrapped for better error handling)
$powershellPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$serviceCmd = "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`""

& $NSSMPath install $ServiceName $powershellPath "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`""

if ($LASTEXITCODE -ne 0) {
    throw "Failed to install service. Exit code: $LASTEXITCODE"
}

# Step 4: Configure service properties
Write-Host "Configuring service properties..."

# Set display name and description
& $NSSMPath set $ServiceName DisplayName $ServiceDisplayName
& $NSSMPath set $ServiceName Description $ServiceDescription

# Set startup type to Automatic (with delay)
& $NSSMPath set $ServiceName Start SERVICE_AUTO_START
& $NSSMPath set $ServiceName AppStartDelay 60

# Configure automatic restart on failure
& $NSSMPath set $ServiceName AppExit Default Restart
& $NSSMPath set $ServiceName AppRestartDelay 10000  # 10 seconds
& $NSSMPath set $ServiceName AppThrottle 600000     # Throttle restart after 10 minutes

# Set working directory
& $NSSMPath set $ServiceName AppDirectory $ProjectPath

# Configure environment variables (if needed)
& $NSSMPath set $ServiceName AppEnvironmentExtra "ENV=staging"

# Set output redirection for logging
$LogPath = Join-Path $ProjectPath "logs"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

& $NSSMPath set $ServiceName AppStdout (Join-Path $LogPath "service-stdout.log")
& $NSSMPath set $ServiceName AppStderr (Join-Path $LogPath "service-stderr.log")
& $NSSMPath set $ServiceName AppRotateFiles 1
& $NSSMPath set $ServiceName AppRotateBytes 10485760  # 10MB per file

# Configure service to run as SYSTEM account (has GUI access on Windows Server)
& $NSSMPath set $ServiceName ObjectName LocalSystem

# Enable service to interact with desktop (for Chrome GUI)
& $NSSMPath set $ServiceName AppStdoutCreationDisposition CREATE_ALWAYS
& $NSSMPath set $ServiceName AppStderrCreationDisposition CREATE_ALWAYS

Write-Host "Service configured successfully"

# Step 5: Start the service
Write-Host "Starting service..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 3

$serviceStatus = Get-Service -Name $ServiceName
if ($serviceStatus.Status -eq "Running") {
    Write-Host "[SUCCESS] Service installed and started successfully!"
    Write-Host "Service Name: $ServiceName"
    Write-Host "Status: $($serviceStatus.Status)"
    Write-Host ""
    Write-Host "Useful commands:"
    Write-Host "  Start Service:   Start-Service -Name $ServiceName"
    Write-Host "  Stop Service:    Stop-Service -Name $ServiceName"
    Write-Host "  Restart Service: Restart-Service -Name $ServiceName"
    Write-Host "  Check Status:    Get-Service -Name $ServiceName"
    Write-Host "  View Logs:      Get-Content `"$LogPath\service-stdout.log`" -Tail 50"
} else {
    Write-Host "[WARNING] Service installed but not running. Status: $($serviceStatus.Status)"
    Write-Host "Check event logs: Get-EventLog -LogName Application -Source NSSM -Newest 10"
}

Write-Host ""
Write-Host "Installation complete!"
```

##### Step 2: Update User Data Script

**Modify**: `scripts/setup_login.ps1` to install the service instead of/alongside scheduled task

Add this to the user data script (after SSM and CloudWatch setup):

```powershell
# Install Browser Automation Launcher as Windows Service
$ServiceScript = Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher\scripts\install_service.ps1"
if (Test-Path $ServiceScript) {
    Write-Host "Installing Browser Automation Launcher as Windows Service..."
    & powershell.exe -ExecutionPolicy Bypass -File $ServiceScript
} else {
    Write-Host "Service installation script not found at: $ServiceScript"
}
```

##### Step 3: Service Management Commands

```powershell
# Start service
Start-Service -Name "BrowserAutomationLauncher"

# Stop service
Stop-Service -Name "BrowserAutomationLauncher"

# Restart service
Restart-Service -Name "BrowserAutomationLauncher"

# Check status
Get-Service -Name "BrowserAutomationLauncher"

# View service configuration (NSSM)
& "C:\Program Files\nssm\nssm.exe" get "BrowserAutomationLauncher" all

# View service logs
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stdout.log" -Tail 50
```

#### Advantages

✅ **Resilience**: Automatically starts at boot, even if no user logs in  
✅ **Windows Update Survival**: Services are preserved across Windows updates  
✅ **AMI Update Ready**: Can be configured in user data for new AMI instances  
✅ **Automatic Recovery**: Built-in restart on failure  
✅ **System Integration**: Shows in Services MMC, can be monitored by CloudWatch  

#### Disadvantages

⚠️ **Complexity**: Requires NSSM or custom service wrapper  
⚠️ **GUI Access**: May need special configuration for Chrome GUI (though Windows Server supports this)  

---

### Solution 2: Enhanced Scheduled Task with Multiple Triggers

If you prefer to stick with scheduled tasks, enhance them with multiple triggers and recovery mechanisms.

#### Implementation: `scripts/setup_resilient_startup_task.ps1`

```powershell
# Enhanced Scheduled Task Setup with Multiple Triggers
# Run as Administrator

$ErrorActionPreference = "Stop"

$TaskName = "BrowserAutomationStartup"
$TaskPath = "$env:USERPROFILE\Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1"

Write-Host "Setting up resilient scheduled task: $TaskName"

# Remove existing task
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Removing existing task..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Create action
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TaskPath`""

# Create multiple triggers
$triggers = @()

# Trigger 1: At system startup (with delay)
$trigger1 = New-ScheduledTaskTrigger -AtStartup
$trigger1.Delay = "PT2M"  # 2 minute delay
$triggers += $trigger1

# Trigger 2: At user logon
$trigger2 = New-ScheduledTaskTrigger -AtLogOn
$triggers += $trigger2

# Trigger 3: Weekly at Monday 12:00 AM (as a backup)
$trigger3 = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At "12:00AM"
$triggers += $trigger3

# Create principal (run as SYSTEM for maximum resilience)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

# Create settings with enhanced recovery
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -RestartCount 5 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0) `
    -MultipleInstances IgnoreNew `
    -RunOnlyIfNetworkAvailable:$false

# Register the task
Write-Host "Creating scheduled task with multiple triggers..."
Register-ScheduledTask -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Principal $principal `
    -Settings $settings `
    -Description "Browser Automation Launcher - Starts automatically at boot, logon, and weekly backup trigger"

Write-Host "[SUCCESS] Resilient scheduled task created!"
Write-Host "Triggers:"
Write-Host "  1. System startup (2 min delay)"
Write-Host "  2. User logon"
Write-Host "  3. Weekly backup (Monday 12:00 AM)"

# Verify
$task = Get-ScheduledTask -TaskName $TaskName
Write-Host ""
Write-Host "Task Status: $($task.State)"
Write-Host "Triggers: $($task.Triggers.Count)"
```

#### Advantages

✅ **Familiar**: Uses existing scheduled task infrastructure  
✅ **Multiple Triggers**: Starts on boot AND logon  
✅ **Recovery**: Built-in restart on failure  
✅ **Simple**: No additional dependencies  

#### Disadvantages

⚠️ **Still Task-Based**: May still fail in edge cases during major updates  
⚠️ **GUI Dependency**: Requires user session for Chrome GUI (unless using SYSTEM account)  

---

### Solution 3: Watchdog Script (Hybrid Approach)

Create a separate monitoring script that runs continuously and ensures the application is always running.

#### Implementation: `scripts/watchdog_monitor.ps1`

```powershell
# Watchdog Monitor - Ensures application is always running
# This script runs as a Windows Service or scheduled task
# It checks every 60 seconds if the application is running and starts it if not

$ErrorActionPreference = "Continue"
$LogPath = Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher\logs\watchdog.log"

function Write-WatchdogLog {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogPath -Append
}

function Is-ApplicationRunning {
    $processes = Get-Process python* -ErrorAction SilentlyContinue | Where-Object {
        try {
            $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
            $cmdLine -match "src\.main"
        } catch {
            $false
        }
    }
    return ($processes.Count -gt 0)
}

function Start-Application {
    $projectPath = Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher"
    $startupScript = Join-Path $projectPath "scripts\simple_startup.ps1"
    
    if (Test-Path $startupScript) {
        Write-WatchdogLog "Starting application via startup script..."
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$startupScript`"" `
            -WindowStyle Hidden
        return $true
    } else {
        Write-WatchdogLog "ERROR: Startup script not found at: $startupScript"
        return $false
    }
}

Write-WatchdogLog "Watchdog monitor started"

while ($true) {
    try {
        $isRunning = Is-ApplicationRunning
        
        if (-not $isRunning) {
            Write-WatchdogLog "Application not running. Attempting to start..."
            $started = Start-Application
            
            if ($started) {
                Write-WatchdogLog "Application start command issued. Waiting 30 seconds..."
                Start-Sleep -Seconds 30
                
                # Verify it started
                $isRunning = Is-ApplicationRunning
                if ($isRunning) {
                    Write-WatchdogLog "Application started successfully"
                } else {
                    Write-WatchdogLog "WARNING: Application start command issued but process not detected"
                }
            }
        } else {
            # Log status every 5 minutes
            $lastCheck = Get-Date
            if (-not $script:lastStatusLog -or ((Get-Date) - $script:lastStatusLog).TotalMinutes -ge 5) {
                Write-WatchdogLog "Application is running (status check)"
                $script:lastStatusLog = Get-Date
            }
        }
    } catch {
        Write-WatchdogLog "ERROR: Watchdog loop exception: $_"
    }
    
    # Check every 60 seconds
    Start-Sleep -Seconds 60
}
```

Install watchdog as a service or scheduled task that runs continuously.

#### Advantages

✅ **Redundancy**: Separate monitoring ensures app stays running  
✅ **Flexible**: Can work alongside existing scheduled task  
✅ **Simple**: Just monitors and starts if needed  

#### Disadvantages

⚠️ **Resource Overhead**: Extra process running continuously  
⚠️ **Still Task-Based**: If watchdog itself fails, still have issues  

---

### Solution 4: Windows Update Management

Configure Windows Update to minimize disruption.

#### Implementation: `scripts/configure_windows_updates.ps1`

```powershell
# Configure Windows Update for Production Servers
# Run as Administrator

# Set Windows Update to notify only (don't auto-install)
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" `
    -Name "AUOptions" -Value 3 -Type DWord  # 3 = Notify before download

# Disable automatic reboots
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update" `
    -Name "NoAutoRebootWithLoggedOnUsers" -Value 1 -Type DWord

# Or use Group Policy for more control
# gpedit.msc > Computer Configuration > Administrative Templates > Windows Components > Windows Update

Write-Host "Windows Update configured for manual control"
```

#### Advantages

✅ **Control**: You decide when updates happen  
✅ **Predictable**: Schedule updates during maintenance windows  

#### Disadvantages

⚠️ **Security Risk**: Delayed updates may leave systems vulnerable  
⚠️ **Maintenance Overhead**: Requires manual update management  

---

## Recommended Production Architecture

### **Combination Approach** (Best Practice)

For maximum production resilience, combine multiple solutions:

1. **Primary**: Windows Service (Solution 1) - Handles normal operation
2. **Secondary**: Enhanced Scheduled Task (Solution 2) - Backup trigger on boot/logon
3. **Tertiary**: Watchdog Monitor (Solution 3) - Continuous health check
4. **Management**: Windows Update Control (Solution 4) - Schedule updates during maintenance windows

### Deployment Steps

1. **Update AMI User Data**: Include service installation in `setup_login.ps1`
2. **Deploy Service**: Run `install_service.ps1` on all instances
3. **Configure Scheduled Task Backup**: Deploy enhanced task as secondary trigger
4. **Deploy Watchdog** (Optional): For critical production environments
5. **Configure Updates**: Use AWS Systems Manager Patch Manager for controlled updates

---

## Monitoring and Verification

### Check Service Status

```powershell
# Check service status
Get-Service -Name "BrowserAutomationLauncher"

# Check service details
Get-WmiObject win32_service | Where-Object { $_.Name -eq "BrowserAutomationLauncher" } | Select-Object Name, State, StartMode, Status
```

### Verify Auto-Start After Reboot

```powershell
# Simulate reboot scenario
Restart-Computer -Force

# After reboot (wait 5 minutes), check:
Get-Service -Name "BrowserAutomationLauncher"
Get-Process python | Where-Object { $_.CommandLine -like "*src.main*" }
```

### CloudWatch Integration

Create CloudWatch alarms for:
- Service stopped
- Application process not running
- High error rates in logs

---

## Migration Guide

### From Scheduled Task to Service

1. **Stop current scheduled task**: `schtasks /change /tn "BrowserAutomationStartup" /disable`
2. **Install service**: Run `install_service.ps1`
3. **Verify service running**: `Get-Service -Name "BrowserAutomationLauncher"`
4. **Monitor for 24 hours**: Check logs and CloudWatch metrics
5. **Remove old scheduled task** (optional): `schtasks /delete /tn "BrowserAutomationStartup" /f`

---

## Conclusion

**For Production Environments**: Use **Solution 1 (Windows Service)** as it provides the highest level of resilience against Windows updates, AMI updates, and system reboots.

The service approach ensures:
- ✅ Automatic startup at boot (before user logon)
- ✅ Survival across Windows updates
- ✅ Automatic recovery on failure
- ✅ Integration with Windows monitoring tools
- ✅ Production-grade reliability

Combine with Windows Update management (Solution 4) for complete production readiness.

