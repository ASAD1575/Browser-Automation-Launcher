# Install Browser Automation Launcher as Windows Service using NSSM
# Run as Administrator
# 
# This script installs the application as a Windows Service for maximum resilience
# against Windows updates, AMI updates, and system reboots.

param(
    [string]$ProjectPath = (Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher"),
    [switch]$Uninstall = $false
)

$ErrorActionPreference = "Stop"

# Configuration
$ServiceName = "BrowserAutomationLauncher"
$ServiceDisplayName = "Browser Automation Launcher"
$ServiceDescription = "Runs Browser Automation Launcher application with automatic restart on failure. Provides Chrome browser automation services."
$StartupScript = Join-Path $ProjectPath "scripts\simple_startup.ps1"
$NSSMPath = "C:\Program Files\nssm\nssm.exe"
$NSSMDir = "C:\Program Files\nssm"

function Write-Log {
    param($Message, [ConsoleColor]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage -ForegroundColor $Color
}

function Install-NSSM {
    Write-Log "NSSM not found. Downloading and installing..." "Yellow"
    
    # Create directory
    if (-not (Test-Path $NSSMDir)) {
        New-Item -ItemType Directory -Path $NSSMDir -Force | Out-Null
        Write-Log "Created NSSM directory: $NSSMDir"
    }
    
    # Download NSSM
    $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $nssmZip = "$env:TEMP\nssm.zip"
    $nssmExtract = "$env:TEMP\nssm-extract"
    
    Write-Log "Downloading NSSM from $nssmUrl..." "Yellow"
    try {
        Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing -ErrorAction Stop
        Write-Log "Download completed" "Green"
    } catch {
        Write-Log "ERROR: Failed to download NSSM: $_" "Red"
        throw
    }
    
    # Extract
    Write-Log "Extracting NSSM..." "Yellow"
    try {
        Expand-Archive -Path $nssmZip -DestinationPath $nssmExtract -Force -ErrorAction Stop
    } catch {
        Write-Log "ERROR: Failed to extract NSSM: $_" "Red"
        Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
        throw
    }
    
    # Copy appropriate architecture (64-bit)
    $nssmExe = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" | Where-Object { $_.Directory.Name -eq "win64" } | Select-Object -First 1
    
    if (-not $nssmExe) {
        # Try 32-bit if 64-bit not found
        $nssmExe = Get-ChildItem -Path $nssmExtract -Recurse -Filter "nssm.exe" | Where-Object { $_.Directory.Name -eq "win32" } | Select-Object -First 1
    }
    
    if ($nssmExe) {
        Copy-Item $nssmExe.FullName -Destination $NSSMPath -Force
        Write-Log "NSSM installed to: $NSSMPath" "Green"
    } else {
        Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
        Remove-Item $nssmExtract -Recurse -Force -ErrorAction SilentlyContinue
        throw "NSSM executable not found in archive"
    }
    
    # Cleanup
    Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
    Remove-Item $nssmExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log "NSSM installation cleanup completed" "Green"
}

function Remove-Service {
    Write-Log "Uninstalling service: $ServiceName" "Yellow"
    
    $existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existingService) {
        if ($existingService.Status -eq "Running") {
            Write-Log "Stopping service..." "Yellow"
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        
        Write-Log "Removing service..." "Yellow"
        if (Test-Path $NSSMPath) {
            $result = & $NSSMPath remove $ServiceName confirm 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Service removed successfully" "Green"
            } else {
                Write-Log "WARNING: Service removal may have failed. Output: $result" "Yellow"
            }
        } else {
            # Fallback: Use sc.exe
            $result = sc.exe delete $ServiceName 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Service removed via sc.exe" "Green"
            } else {
                Write-Log "ERROR: Failed to remove service. Output: $result" "Red"
            }
        }
    } else {
        Write-Log "Service not found. Nothing to remove." "Yellow"
    }
    
    Write-Log "Uninstallation complete!" "Green"
    exit 0
}

# Check for Administrator privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "ERROR: This script must be run as Administrator!" "Red"
    Write-Log "Right-click the script and select 'Run as Administrator'" "Yellow"
    exit 1
}

# Handle uninstall
if ($Uninstall) {
    Remove-Service
}

# Verify project path exists
if (-not (Test-Path $ProjectPath)) {
    Write-Log "ERROR: Project path not found: $ProjectPath" "Red"
    Write-Log "Please ensure the application is installed at the correct location." "Yellow"
    exit 1
}

# Verify startup script exists
if (-not (Test-Path $StartupScript)) {
    Write-Log "ERROR: Startup script not found: $StartupScript" "Red"
    exit 1
}

Write-Log "========================================" "Cyan"
Write-Log "Browser Automation Launcher Service Installer" "Cyan"
Write-Log "========================================" "Cyan"
Write-Log ""
Write-Log "Service Name: $ServiceName" "White"
Write-Log "Project Path: $ProjectPath" "White"
Write-Log "Startup Script: $StartupScript" "White"
Write-Log ""

# Step 1: Install/Verify NSSM
if (-not (Test-Path $NSSMPath)) {
    Install-NSSM
} else {
    Write-Log "NSSM found at: $NSSMPath" "Green"
}

# Step 2: Remove existing service if it exists
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Log "Existing service found. Removing..." "Yellow"
    if ($existingService.Status -eq "Running") {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    
    $result = & $NSSMPath remove $ServiceName confirm 2>&1
    Start-Sleep -Seconds 2
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Existing service removed" "Green"
    } else {
        Write-Log "WARNING: May have failed to remove existing service" "Yellow"
    }
}

# Step 3: Create the service
Write-Log "Creating Windows Service..." "Yellow"

$powershellPath = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
$serviceArguments = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$StartupScript`""

Write-Log "Service command: $powershellPath $serviceArguments" "Gray"

$result = & $NSSMPath install $ServiceName $powershellPath $serviceArguments 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: Failed to install service. Exit code: $LASTEXITCODE" "Red"
    Write-Log "NSSM output: $result" "Red"
    exit 1
}

Write-Log "Service installation command executed successfully" "Green"
Start-Sleep -Seconds 2

# Step 4: Configure service properties
Write-Log "Configuring service properties..." "Yellow"

# Set display name and description
& $NSSMPath set $ServiceName DisplayName $ServiceDisplayName | Out-Null
& $NSSMPath set $ServiceName Description $ServiceDescription | Out-Null

# Set startup type to Automatic (with delay for system stability)
& $NSSMPath set $ServiceName Start SERVICE_AUTO_START | Out-Null
& $NSSMPath set $ServiceName AppStartDelay 60 | Out-Null  # 60 second delay

# Configure automatic restart on failure
& $NSSMPath set $ServiceName AppExit Default Restart | Out-Null
& $NSSMPath set $ServiceName AppRestartDelay 10000 | Out-Null  # 10 seconds
& $NSSMPath set $ServiceName AppThrottle 600000 | Out-Null     # Throttle after 10 minutes of failures

# Set working directory
& $NSSMPath set $ServiceName AppDirectory $ProjectPath | Out-Null

# Configure output redirection for logging
$LogPath = Join-Path $ProjectPath "logs"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    Write-Log "Created log directory: $LogPath" "Green"
}

$stdoutLog = Join-Path $LogPath "service-stdout.log"
$stderrLog = Join-Path $LogPath "service-stderr.log"

& $NSSMPath set $ServiceName AppStdout $stdoutLog | Out-Null
& $NSSMPath set $ServiceName AppStderr $stderrLog | Out-Null
& $NSSMPath set $ServiceName AppRotateFiles 1 | Out-Null
& $NSSMPath set $ServiceName AppRotateBytes 10485760 | Out-Null  # 10MB per file

# Configure service to run as SYSTEM account (has GUI access on Windows Server)
& $NSSMPath set $ServiceName ObjectName LocalSystem | Out-Null

# Enable service to interact with desktop (for Chrome GUI on Windows Server)
& $NSSMPath set $ServiceName AppStdoutCreationDisposition CREATE_ALWAYS | Out-Null
& $NSSMPath set $ServiceName AppStderrCreationDisposition CREATE_ALWAYS | Out-Null

Write-Log "Service properties configured" "Green"

# Step 5: Start the service
Write-Log "Starting service..." "Yellow"
try {
    Start-Service -Name $ServiceName -ErrorAction Stop
    Start-Sleep -Seconds 5
    
    $serviceStatus = Get-Service -Name $ServiceName
    if ($serviceStatus.Status -eq "Running") {
        Write-Log "[SUCCESS] Service installed and started successfully!" "Green"
        Write-Log "" "White"
        Write-Log "========================================" "Cyan"
        Write-Log "Installation Summary" "Cyan"
        Write-Log "========================================" "Cyan"
        Write-Log "Service Name:     $ServiceName" "White"
        Write-Log "Display Name:     $ServiceDisplayName" "White"
        Write-Log "Status:           $($serviceStatus.Status)" "Green"
        Write-Log "Start Type:       Automatic (with 60s delay)" "White"
        Write-Log "Account:          LocalSystem" "White"
        Write-Log "Auto-Restart:     Enabled (on failure)" "White"
        Write-Log "" "White"
        Write-Log "Useful Commands:" "Cyan"
        Write-Log "  Start:    Start-Service -Name $ServiceName" "White"
        Write-Log "  Stop:     Stop-Service -Name $ServiceName" "White"
        Write-Log "  Restart:  Restart-Service -Name $ServiceName" "White"
        Write-Log "  Status:   Get-Service -Name $ServiceName" "White"
        Write-Log "  Config:   & '$NSSMPath' get $ServiceName all" "White"
        Write-Log "" "White"
        Write-Log "Log Files:" "Cyan"
        Write-Log "  Stdout:   $stdoutLog" "White"
        Write-Log "  Stderr:   $stderrLog" "White"
        Write-Log "  Monitor:  $(Join-Path $LogPath 'monitor.log')" "White"
        Write-Log "" "White"
        Write-Log "The service will:" "Cyan"
        Write-Log "  ✓ Start automatically at system boot" "Green"
        Write-Log "  ✓ Restart automatically on failure" "Green"
        Write-Log "  ✓ Survive Windows updates and reboots" "Green"
        Write-Log "  ✓ Run even if no user is logged in" "Green"
        Write-Log "" "White"
        Write-Log "Installation complete!" "Green"
    } else {
        Write-Log "[WARNING] Service installed but not running. Status: $($serviceStatus.Status)" "Yellow"
        Write-Log "Attempting to start..." "Yellow"
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $serviceStatus = Get-Service -Name $ServiceName
        Write-Log "Current Status: $($serviceStatus.Status)" "Yellow"
        
        if ($serviceStatus.Status -ne "Running") {
            Write-Log "" "White"
            Write-Log "Troubleshooting:" "Cyan"
            Write-Log "  1. Check service logs: Get-Content '$stdoutLog' -Tail 50" "White"
            Write-Log "  2. Check event logs: Get-EventLog -LogName Application -Source NSSM -Newest 10" "White"
            Write-Log "  3. Check NSSM config: & '$NSSMPath' get $ServiceName all" "White"
            Write-Log "  4. Verify startup script exists: Test-Path '$StartupScript'" "White"
        }
    }
} catch {
    Write-Log "[ERROR] Failed to start service: $_" "Red"
    Write-Log "Check logs and configuration manually." "Yellow"
    Write-Log "" "White"
    Write-Log "Troubleshooting:" "Cyan"
    Write-Log "  View NSSM config: & '$NSSMPath' get $ServiceName all" "White"
    Write-Log "  View service logs: Get-Content '$stdoutLog' -Tail 50" "White"
    exit 1
}

