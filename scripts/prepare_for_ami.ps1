# Prepare VM for AMI Creation
# This script safely stops the application and cleans up before creating an AMI

Write-Host "================================================"
Write-Host "Preparing VM for AMI Creation"
Write-Host "================================================"
Write-Host ""

$projectPath = "C:\Apps\browser-automation-launcher"
$logsDir = "$projectPath\logs"
$stopFile = "$logsDir\STOP"

# Step 1: Create STOP file for graceful shutdown
Write-Host "[1/6] Creating STOP file for graceful shutdown..."
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}
New-Item -ItemType File -Path $stopFile -Force | Out-Null
Write-Host "      STOP file created at: $stopFile"
Write-Host ""

# Step 2: Wait for application to detect STOP file and shutdown
Write-Host "[2/6] Waiting for application to shutdown gracefully (35 seconds)..."
Start-Sleep -Seconds 35
Write-Host ""

# Step 3: Force stop any remaining processes
Write-Host "[3/6] Ensuring all processes are stopped..."
$pythonProcesses = Get-Process python -ErrorAction SilentlyContinue
if ($pythonProcesses) {
    $count = @($pythonProcesses).Count
    Write-Host "      Stopping $count Python processes..."
    Stop-Process -Name python -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-Host "      No Python processes running"
}

$chromeProcesses = Get-Process chrome -ErrorAction SilentlyContinue
if ($chromeProcesses) {
    $count = @($chromeProcesses).Count
    Write-Host "      Stopping $count Chrome processes..."
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
} else {
    Write-Host "      No Chrome processes running"
}
Write-Host ""

# Step 4: Remove STOP file (so new VMs don't have it)
Write-Host "[4/6] Removing STOP file..."
if (Test-Path $stopFile) {
    Remove-Item $stopFile -Force
    Write-Host "      STOP file removed"
} else {
    Write-Host "      STOP file already removed"
}
Write-Host ""

# Step 5: Clean up logs and temporary files
Write-Host "[5/6] Cleaning up logs and temporary files..."
if (Test-Path $logsDir) {
    $logFiles = Get-ChildItem $logsDir -Filter *.log -ErrorAction SilentlyContinue
    if ($logFiles) {
        $count = @($logFiles).Count
        Write-Host "      Removing $count log files..."
        Remove-Item "$logsDir\*.log" -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "      No log files to remove"
    }
}

# Clean Chrome profiles only (keep other files in Chrome-RDP folder)
$chromeRdpPath = "C:\Chrome-RDP"
if (Test-Path $chromeRdpPath) {
    # Only remove directories that match profile pattern (p9220, p9221, etc.)
    $profiles = Get-ChildItem $chromeRdpPath -Directory -Filter "p*" -ErrorAction SilentlyContinue
    if ($profiles) {
        $count = @($profiles).Count
        Write-Host "      Removing $count Chrome profile directories..."
        foreach ($profile in $profiles) {
            Remove-Item $profile.FullName -Recurse -Force -ErrorAction SilentlyContinue
            $profileName = $profile.Name
            Write-Host "        - Removed: $profileName"
        }
    } else {
        Write-Host "      No Chrome profile directories to remove"
    }
} else {
    Write-Host "      Chrome-RDP folder not found"
}

# Clean temp files
Write-Host "      Cleaning temp files..."
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""

# Step 6: Verify scheduled task is enabled (so new VMs will auto-start)
Write-Host "[6/6] Verifying scheduled task configuration..."
$taskInfo = schtasks /query /tn "BrowserAutomationStartup" /fo LIST 2>&1 | Select-String "Status:"
if ($taskInfo -match "Disabled") {
    Write-Host "      WARNING: Scheduled task is disabled. Enabling it..."
    schtasks /change /tn "BrowserAutomationStartup" /enable
    Write-Host "      Scheduled task enabled"
} else {
    Write-Host "      Scheduled task is ready (will auto-start on new VMs)"
}
Write-Host ""

# Final verification
Write-Host "================================================"
Write-Host "Verification"
Write-Host "================================================"
Write-Host ""

$pythonRunning = Get-Process python -ErrorAction SilentlyContinue
$chromeRunning = Get-Process chrome -ErrorAction SilentlyContinue

if ($pythonRunning) {
    $pid = $pythonRunning.Id
    Write-Host "WARNING: Python is still running! PID: $pid"
    Write-Host "         Manually stop it: Stop-Process -Id $pid -Force"
} else {
    Write-Host "[OK] Python processes: Stopped"
}

if ($chromeRunning) {
    $count = @($chromeRunning).Count
    Write-Host "WARNING: Chrome is still running! $count processes"
    Write-Host "         Manually stop: Stop-Process -Name chrome -Force"
} else {
    Write-Host "[OK] Chrome processes: Stopped"
}

if (Test-Path $stopFile) {
    Write-Host "WARNING: STOP file still exists at: $stopFile"
    Write-Host "         Manually remove it: Remove-Item '$stopFile' -Force"
} else {
    Write-Host "[OK] STOP file: Removed"
}

$taskEnabled = schtasks /query /tn "BrowserAutomationStartup" /fo LIST 2>&1 | Select-String "Status:"
if ($taskEnabled -match "Ready" -or $taskEnabled -match "Running") {
    Write-Host "[OK] Scheduled task: Enabled and ready"
} else {
    Write-Host "WARNING: Scheduled task status unclear"
    Write-Host "         Check manually: schtasks /query /tn 'BrowserAutomationStartup'"
}

Write-Host ""
Write-Host "================================================"
Write-Host "Next Steps"
Write-Host "================================================"
Write-Host ""
Write-Host "If all checks passed, you can now create the AMI:"
Write-Host ""
Write-Host "1. Go to AWS Console"
Write-Host "2. EC2 -> Instances -> Select this instance"
Write-Host "3. Actions -> Image and templates -> Create image"
Write-Host "4. Name: browser-automation-launcher-v1"
Write-Host "5. Description: Windows + Python + Chrome + configured"
Write-Host "6. ☑ No reboot (recommended)"
Write-Host "7. Click 'Create image'"
Write-Host ""
Write-Host "Wait 10-15 minutes for AMI creation to complete."
Write-Host ""
Write-Host "================================================"
