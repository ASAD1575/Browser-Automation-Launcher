# Windows VM Testing Guide

Quick guide to test that your Windows VM is properly configured before creating an AMI.

---

## Prerequisites

Before testing, ensure you have:
- ✅ Windows Server VM running
- ✅ Python 3.12 installed
- ✅ Chrome installed
- ✅ Git installed
- ✅ Repository cloned to `C:\Apps\browser-automation-launcher`
- ✅ Scheduled task created

---

## Step 1: Test Simple Startup Script

### 1.1 Run the Startup Script Manually

```powershell
# Open PowerShell as Administrator
# Navigate to project directory
cd C:\Apps\browser-automation-launcher\scripts

# Run the startup script
powershell -ExecutionPolicy Bypass -File .\simple_startup.ps1
```

**What to watch for:**
```
Expected output:
- "Starting Browser Automation Launcher startup script"
- "Python found at: C:\Program Files\Python312\python.exe"
- "Poetry found at: C:\Program Files\Python312\Scripts\poetry.exe"
- "Changed to project directory"
- "Application started with PID: XXXX"
- "Starting process monitoring..."
- "Application is running (PID: XXXX)" (every 30 seconds)
```

**Common issues:**
- ❌ "Python not found" → Install Python 3.12
- ❌ "Poetry not found" → Script will auto-install it (wait 2-3 minutes)
- ❌ "Project not found" → Check repository is at correct path
- ❌ "Application exited" → Check logs in `C:\Apps\browser-automation-launcher\logs\`

### 1.2 Let It Run for 2-3 Minutes

```powershell
# Keep PowerShell open
# Watch for monitoring messages every 30 seconds:
# "Application is running (PID: XXXX)"

# Check if Python process is running (in another PowerShell window)
Get-Process python

# Should show:
# Handles  NPM(K)    PM(K)      WS(K) CPU(s)     Id  SI ProcessName
# -------  ------    -----      ----- ------     --  -- -----------
#     ...      ...   ....       ....   ...    XXXX   X python
```

---

## Step 2: Test Application Functionality

### 2.1 Check Application Logs

```powershell
# Open a new PowerShell window
cd C:\Apps\browser-automation-launcher\logs

# View startup log
Get-Content .\startup.log -Tail 20

# View application output
Get-Content .\app-stdout.log -Tail 50 -Wait

# Check for errors
Get-Content .\app-stderr.log -Tail 20
```

**Expected in app-stdout.log:**
```
INFO - Starting Browser Automation Launcher
INFO - Environment: staging
INFO - SQS Queue: https://sqs.us-east-1.amazonaws.com/...
INFO - Polling SQS queue...
INFO - Waiting for messages...
```

**If you see errors:**
```
# Check AWS credentials
aws sts get-caller-identity

# Check SQS queue access
aws sqs get-queue-attributes --queue-url YOUR_QUEUE_URL --attribute-names All
```

### 2.2 Test Chrome Launcher (Optional)

```powershell
# If you have custom Chrome launcher script
cd C:\Chrome-RDP

# Get VM's private IP
$ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias "Ethernet*" | Where-Object {$_.IPAddress -like "172.*" -or $_.IPAddress -like "10.*"})[0].IPAddress
Write-Host "VM IP: $ip"

# Test launching Chrome on port 9222
.\launch_chrome_port.cmd 9222 $ip

# Check Chrome is running
Get-Process chrome

# Test CDP endpoint (from another machine or local)
# curl http://$ip:9222/json/version
```

---

## Step 3: Test Graceful Shutdown

### 3.1 Stop Using STOP File Method

```powershell
# Create STOP file
New-Item -ItemType File -Path "C:\Apps\browser-automation-launcher\logs\STOP"

# Watch the monitoring PowerShell window
# Within 30 seconds you should see:
# "STOP file detected. Shutting down gracefully..."
# "Stopping application process (PID: XXXX)..."

# Verify process stopped
Get-Process python -ErrorAction SilentlyContinue
# Should return nothing

# Verify PowerShell script also stopped
Get-Process powershell
# Should NOT show the startup script process anymore
```

### 3.2 Remove STOP File

```powershell
# Remove STOP file so app can restart
Remove-Item "C:\Apps\browser-automation-launcher\logs\STOP" -Force
```

---

## Step 4: Test Scheduled Task

### 4.1 Verify Task Exists

```powershell
# Check scheduled task
schtasks /query /tn "BrowserAutomationStartup" /fo LIST

# Expected output:
# TaskName:    \BrowserAutomationStartup
# Status:      Ready (or Running)
# Next Run Time: At logon
```

### 4.2 Run Task Manually

```powershell
# Trigger scheduled task
schtasks /run /tn "BrowserAutomationStartup"

# Should see:
# SUCCESS: Attempted to run the scheduled task "BrowserAutomationStartup".

# Wait 60 seconds (startup script has 60 second delay)
Start-Sleep -Seconds 65

# Check if application started
Get-Process python

# Check logs
Get-Content C:\Apps\browser-automation-launcher\logs\monitor.log -Tail 20
```

### 4.3 Test Auto-Restart on Crash

```powershell
# Force kill Python to simulate crash
Stop-Process -Name python -Force

# Watch monitor log (should see restart attempt)
Get-Content C:\Apps\browser-automation-launcher\logs\monitor.log -Wait -Tail 10

# Expected:
# "Application exited with code: 1"
# "Application crashed! Consecutive failures: 1"
# "Waiting 30 seconds before restart..."
# "Restarting application..."
# "Application restarted with PID: XXXX"

# Check crash log
Get-Content C:\Apps\browser-automation-launcher\logs\crash.log
```

---

## Step 5: Test AMI Preparation Script

### 5.1 Run Preparation Script

```powershell
# Make sure application is running first
Get-Process python

# Run prepare script
cd C:\Apps\browser-automation-launcher\scripts
.\prepare_for_ami.ps1
```

**Expected output:**
```
================================================
Preparing VM for AMI Creation
================================================

[1/6] Creating STOP file for graceful shutdown...
      STOP file created at: C:\Apps\browser-automation-launcher\logs\STOP

[2/6] Waiting for application to shutdown gracefully (35 seconds)...

[3/6] Ensuring all processes are stopped...
      Stopping 1 Python process(es)...
      Stopping 2 Chrome process(es)...

[4/6] Removing STOP file...
      STOP file removed

[5/6] Cleaning up logs and temporary files...
      Removing 5 log file(s)...
      Removing 3 Chrome profile directory(ies)...
        - Removed: p9222
        - Removed: p9223
        - Removed: p9224
      Cleaning temp files...

[6/6] Verifying scheduled task configuration...
      Scheduled task is ready (will auto-start on new VMs)

================================================
Verification
================================================

✓ Python processes: Stopped
✓ Chrome processes: Stopped
✓ STOP file: Removed
✓ Scheduled task: Enabled and ready

================================================
Next Steps
================================================

If all checks passed, you can now create the AMI:
...
```

### 5.2 Verify Clean State

```powershell
# Verify nothing running
Get-Process python -ErrorAction SilentlyContinue  # Should be empty
Get-Process chrome -ErrorAction SilentlyContinue  # Should be empty

# Verify STOP file removed
Test-Path "C:\Apps\browser-automation-launcher\logs\STOP"  # Should be False

# Verify logs cleaned
Get-ChildItem "C:\Apps\browser-automation-launcher\logs\" -Filter *.log
# Should show no or minimal log files

# Verify scheduled task enabled
schtasks /query /tn "BrowserAutomationStartup" /fo LIST | Select-String "Status"
# Should show: Ready or Running (not Disabled)
```

---

## Step 6: Test Full Restart After AMI Prep

### 6.1 Restart Application

```powershell
# Start scheduled task again
schtasks /run /tn "BrowserAutomationStartup"

# Wait for startup delay (60 seconds)
Start-Sleep -Seconds 65

# Verify application started
Get-Process python

# Check logs
Get-Content C:\Apps\browser-automation-launcher\logs\startup.log -Tail 20
Get-Content C:\Apps\browser-automation-launcher\logs\monitor.log -Tail 10
```

### 6.2 Verify Full Functionality

```powershell
# Application should be working exactly as before
Get-Content C:\Apps\browser-automation-launcher\logs\app-stdout.log -Wait -Tail 20

# Should see:
# - SQS polling active
# - No errors
# - Normal operation
```

---

## Complete Test Checklist

Run through this checklist before creating AMI:

```
□ Step 1: Startup script runs without errors
□ Step 2: Application starts and logs show normal operation
□ Step 3: STOP file graceful shutdown works
□ Step 4: Scheduled task runs and auto-restarts on crash
□ Step 5: AMI preparation script completes all checks
□ Step 6: Application restarts successfully after cleanup

If all checked, you're ready to create AMI! ✅
```

---

## Common Issues and Solutions

### Issue: "Poetry not found" in startup script
```powershell
# Manual install
python -m pip install poetry

# Verify
poetry --version
```

### Issue: Application starts but immediately exits
```powershell
# Check stderr for errors
Get-Content C:\Apps\browser-automation-launcher\logs\app-stderr.log

# Common causes:
# - Missing .env file
# - Invalid AWS credentials
# - Wrong SQS queue URL
```

### Issue: Scheduled task won't run
```powershell
# Check task status
schtasks /query /tn "BrowserAutomationStartup" /v

# Delete and recreate
cd C:\Apps\browser-automation-launcher\scripts
.\setup_startup_task.bat
```

### Issue: Can't stop application
```powershell
# Force stop everything
Stop-Process -Name python -Force
Stop-Process -Name chrome -Force

# Kill startup script
Get-Process powershell | Where-Object {$_.CommandLine -like "*simple_startup*"} | Stop-Process -Force
```

### Issue: AWS credentials not working
```powershell
# Check IAM role attached to instance
# AWS Console → EC2 → Instance → Security → IAM Role

# Should have policies:
# - AmazonSQSFullAccess (or custom SQS policy)
# - SecretsManagerReadWrite (if using)

# Test credentials
aws sts get-caller-identity
```

---

## Quick Commands Reference

```powershell
# Start application
schtasks /run /tn "BrowserAutomationStartup"

# Stop application (graceful)
New-Item -ItemType File -Path "C:\Apps\browser-automation-launcher\logs\STOP"

# Stop application (force)
Stop-Process -Name python -Force

# View logs (real-time)
Get-Content C:\Apps\browser-automation-launcher\logs\app-stdout.log -Wait -Tail 50

# Check if running
Get-Process python, chrome

# Prepare for AMI
cd C:\Apps\browser-automation-launcher\scripts
.\prepare_for_ami.ps1

# Check scheduled task
schtasks /query /tn "BrowserAutomationStartup" /fo LIST
```

---

## After Testing Successfully

Once all tests pass:

1. ✅ Run `prepare_for_ami.ps1`
2. ✅ Verify all checks pass
3. ✅ Go to AWS Console
4. ✅ Create AMI from instance
5. ✅ Test launching new VM from AMI
6. ✅ Verify new VM auto-starts application

---

## Next: Create AMI

If all tests pass, proceed to create your AMI:

**See:** [aws-ami-setup-guide.md](./aws-ami-setup-guide.md) → "Step 4: Create AMI from Configured VM"

```
AWS Console:
EC2 → Instances → Select instance →
Actions → Image and templates → Create image

Name: browser-automation-launcher-v1
Description: Windows + Python + Chrome + tested and working

☑ No reboot
Create image
```

Wait 10-15 minutes, then test launching a new VM from the AMI!
