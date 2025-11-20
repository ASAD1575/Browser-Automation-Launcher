param(
  [string]$Username = "ticketboat",
  [string]$Password = 'RetroG@m3s',  # Password for autologon registry (required if registry is empty, or leave empty to preserve existing registry password)
  [switch]$UpdateUserPassword = $false,  # WARNING: Do NOT enable unless you want to change user password (may cause RDP disconnection!)
  [switch]$UpdateAutologonPassword = $false,  # Set to $true to update autologon registry password (requires -Password)
  [switch]$VerifySSMAgent = $true,  # Check and verify SSM Agent is running (default: true)
  [switch]$SkipRDPConfig = $false,  # Skip RDP configuration to preserve existing settings (use if Chrome visibility is working)
  [string]$TaskName = "BrowserAutomationStartup"  # Scheduled task name to verify (read-only, no modifications)
)

$ErrorActionPreference = "Stop"

# Function for section headers
function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

# Function for status messages
function Write-Status {
    param(
        [string]$Message,
        [string]$Status = "OK"  # OK, WARNING, ERROR, INFO
    )
    $color = switch ($Status) {
        "OK" { "Green" }
        "WARNING" { "Yellow" }
        "ERROR" { "Red" }
        "INFO" { "Cyan" }
        default { "White" }
    }
    $prefix = switch ($Status) {
        "OK" { "[OK]" }
        "WARNING" { "[WARNING]" }
        "ERROR" { "[ERROR]" }
        "INFO" { "[INFO]" }
        default { "" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

# --- Verify User Exists ---
Write-SectionHeader "User Verification"
Write-Host "Checking user: $Username" -ForegroundColor White
$existingUser = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
if (-not $existingUser) {
  Write-Status "User '$Username' does not exist. This script only works with existing users." "ERROR"
  Write-Status "Please create the user first or use a different username." "ERROR"
  exit 1
}
Write-Status "User '$Username' found" "OK"

# --- User Account Configuration ---
Write-SectionHeader "User Account Configuration"

# Update User Password (optional - DISABLED by default to prevent RDP disconnection)
if ($UpdateUserPassword) {
  Write-Host ""
  Write-Host "  [WARNING] UpdateUserPassword is enabled - this will change the user account password!" -ForegroundColor Yellow
  Write-Host "  This may cause RDP disconnection if you're currently connected via RDP." -ForegroundColor Yellow
  Write-Host "  Press Ctrl+C within 5 seconds to cancel, or wait to continue..." -ForegroundColor Yellow
  Start-Sleep -Seconds 5
  
  if ([string]::IsNullOrEmpty($Password)) {
    Write-Status "Password is required when using -UpdateUserPassword. Provide -Password parameter." "ERROR"
    exit 1
  }
  Write-Host "  Updating user password..." -ForegroundColor White
  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  try {
    Set-LocalUser -Name $Username -Password $sec -ErrorAction Stop
    Write-Status "User password updated successfully" "OK"
    Write-Host "  [WARNING] If connected via RDP, you may need to reconnect with the new password!" -ForegroundColor Yellow
  } catch {
    Write-Status "Failed to update user password: $_" "ERROR"
    exit 1
  }
} else {
  Write-Status "Preserving existing user password (no changes made)" "OK"
  Write-Host "  Note: User password is NOT modified to prevent RDP disconnection issues" -ForegroundColor Gray
  Write-Host "  Only autologon registry password is configured (if needed)" -ForegroundColor Gray
}

# --- Enable AutoLogin Safely ---
Write-SectionHeader "Autologon Configuration"
Write-Host "Configuring AutoAdminLogon for user: $Username" -ForegroundColor White

$reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }

# Determine autologon password:
# 1. Always use Password parameter (default value from script or provided)
# 2. Only update registry if UpdateAutologonPassword is true OR registry doesn't exist
# 3. This ensures autologon uses the password from script parameters
$autologonPassword = $Password

if ([string]::IsNullOrEmpty($autologonPassword)) {
    # Try to read from registry as fallback
    $registryPassword = (Get-ItemProperty -Path $reg -Name 'DefaultPassword' -ErrorAction SilentlyContinue).DefaultPassword
    if (-not [string]::IsNullOrEmpty($registryPassword)) {
        $autologonPassword = $registryPassword
        Write-Host "  Using existing registry password for autologon (Password parameter not provided)" -ForegroundColor Gray
    } else {
        Write-Status "No password available for autologon!" "ERROR"
        Write-Host "  The Password parameter in the script must have a value, or provide it via -Password parameter" -ForegroundColor Yellow
        exit 1
    }
} else {
    if ($UpdateAutologonPassword) {
        Write-Host "  Using provided password for autologon (UpdateAutologonPassword=true)" -ForegroundColor Gray
    } else {
        Write-Host "  Using password from script parameters for autologon" -ForegroundColor Gray
        Write-Host "  (Registry will be updated to match script password)" -ForegroundColor Gray
    }
}

Set-ItemProperty -Path $reg -Name 'AutoAdminLogon' -Type String -Value '1' -Force
Set-ItemProperty -Path $reg -Name 'ForceAutoLogon' -Type String -Value '1' -Force
Set-ItemProperty -Path $reg -Name 'DisableCAD' -Type DWord -Value 1 -Force
Set-ItemProperty -Path $reg -Name 'DefaultUsername' -Type String -Value $Username -Force
Set-ItemProperty -Path $reg -Name 'DefaultPassword' -Type String -Value $autologonPassword -Force

# Ensure autologon session is interactive (critical for Chrome visibility)
# These settings help ensure the session is fully interactive
Set-ItemProperty -Path $reg -Name 'AutoLogonCount' -Type DWord -Value 0 -ErrorAction SilentlyContinue
# Remove AutoLogonCount if it exists (0 = unlimited, but removing it is cleaner)
if ((Get-ItemProperty -Path $reg -Name 'AutoLogonCount' -ErrorAction SilentlyContinue).AutoLogonCount -eq 0) {
    Remove-ItemProperty -Path $reg -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
}

# Ensure the session is not locked after autologon
# This registry key helps prevent the session from being locked
$regWinlogon = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
if (-not (Test-Path $regWinlogon)) { 
    New-Item -Path $regWinlogon -Force | Out-Null 
}
Set-ItemProperty -Path $regWinlogon -Name 'LastLoggedOnUser' -Type String -Value $Username -ErrorAction SilentlyContinue

# Set AutoLogonCount to allow multiple autologons (0 = unlimited, or remove it to allow unlimited)
# This ensures autologon works on every restart
$existingAutoLogonCount = (Get-ItemProperty -Path $reg -Name 'AutoLogonCount' -ErrorAction SilentlyContinue).AutoLogonCount
if ($null -eq $existingAutoLogonCount) {
    # AutoLogonCount not set - autologon will work indefinitely
    Write-Host "  AutoLogonCount: Not set (unlimited autologons)" -ForegroundColor Gray
} else {
    # If AutoLogonCount exists and is > 0, it will stop after that many logons
    if ($existingAutoLogonCount -gt 0) {
        Write-Host "  [WARNING] AutoLogonCount is set to $existingAutoLogonCount - autologon will stop after $existingAutoLogonCount restarts" -ForegroundColor Yellow
        Write-Host "  Removing AutoLogonCount to allow unlimited autologons..." -ForegroundColor Gray
        Remove-ItemProperty -Path $reg -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    }
}

Write-Status "Autologon registry configured successfully" "OK"
Write-Host ""
Write-Host "  Critical Issue: Chrome not appearing after autologon (even when task manually triggered)" -ForegroundColor Red
Write-Host ""
Write-Host "  Problem Analysis:" -ForegroundColor Cyan
Write-Host "    - Task triggers correctly after autologon" -ForegroundColor Gray
Write-Host "    - But Chrome doesn't appear even when task is manually run" -ForegroundColor Gray
Write-Host "    - This suggests autologon session is not fully interactive" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Possible Causes:" -ForegroundColor Cyan
Write-Host "    1. Session is locked or not interactive after autologon" -ForegroundColor Yellow
Write-Host "    2. Chrome is launching in Session 0 (background) instead of Session 1" -ForegroundColor Yellow
Write-Host "    3. Task is running but child processes (Chrome) inherit wrong session" -ForegroundColor Yellow
Write-Host "    4. Session is not fully initialized when task runs" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Diagnostic Steps (run after autologon restart):" -ForegroundColor Cyan
Write-Host "    1. Check if session is locked:" -ForegroundColor White
Write-Host "       rundll32.exe user32.dll,LockWorkStation  # Will fail if already locked" -ForegroundColor Gray
Write-Host "       query session  # Check session state" -ForegroundColor Gray
Write-Host ""
Write-Host "    2. Check current session and interactive desktop:" -ForegroundColor White
Write-Host "       [System.Environment]::UserInteractive" -ForegroundColor Gray
Write-Host "       (Get-CimInstance Win32_ComputerSystem).UserName" -ForegroundColor Gray
Write-Host ""
Write-Host "    3. Check Python/Chrome session IDs:" -ForegroundColor White
Write-Host "       Get-Process python* | Where-Object { (Get-CimInstance Win32_Process -Filter `"ProcessId=`$(`$_.Id)`").CommandLine -match 'src.main' } | Select-Object Id,SessionId" -ForegroundColor Gray
Write-Host "       Get-Process chrome | Select-Object Id,SessionId" -ForegroundColor Gray
Write-Host ""
Write-Host "    4. Check task execution context:" -ForegroundColor White
Write-Host "       Get-ScheduledTaskInfo -TaskName '$TaskName' | Format-List" -ForegroundColor Gray
Write-Host "       Get-ScheduledTask -TaskName '$TaskName' | Select-Object State,Principal" -ForegroundColor Gray
Write-Host ""
Write-Host "  Analysis from your diagnostics:" -ForegroundColor Cyan
Write-Host "    ✓ Session is interactive (UserInteractive = True)" -ForegroundColor Green
Write-Host "    ✓ Chrome processes are in Session 2 (RDP session) - correct location!" -ForegroundColor Green
Write-Host "    ⚠ BUT Chrome windows are not visible on desktop" -ForegroundColor Red
Write-Host ""
Write-Host "  This indicates Chrome IS launching in the correct session, but windows are not visible." -ForegroundColor Yellow
Write-Host "  Possible causes:" -ForegroundColor Cyan
Write-Host "    1. Chrome windows are minimized or hidden" -ForegroundColor Gray
Write-Host "    2. Chrome launched with --headless or --disable-gpu flags" -ForegroundColor Gray
Write-Host "    3. Window creation is failing silently" -ForegroundColor Gray
Write-Host "    4. Chrome is launching but immediately hiding windows" -ForegroundColor Gray
Write-Host ""
Write-Host "  Diagnostic: Check Chrome window visibility" -ForegroundColor Cyan
Write-Host "    # Check if Chrome has visible windows:" -ForegroundColor White
Write-Host "    Get-Process chrome | Where-Object { `$_.MainWindowTitle -ne '' } | Select-Object Id,MainWindowTitle" -ForegroundColor Gray
Write-Host "    # If empty, Chrome has no visible windows (all hidden/minimized)" -ForegroundColor Yellow
Write-Host ""
Write-Host "    # Check Chrome command line arguments:" -ForegroundColor White
Write-Host "    Get-CimInstance Win32_Process -Filter \"name='chrome.exe'\" | Select-Object ProcessId,CommandLine" -ForegroundColor Gray
Write-Host "    # Look for --headless, --disable-gpu, or other flags that hide windows" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Root Cause (Most Likely):" -ForegroundColor Cyan
Write-Host "    After autologon, the Chrome launcher script may be using flags that hide windows," -ForegroundColor White
Write-Host "    or Chrome is launching but the window creation is failing in the autologon context." -ForegroundColor White
Write-Host ""
Write-Host "  CONFIRMED ISSUE: Chrome is in Session 1 (console), but you're viewing Session 2 (RDP)" -ForegroundColor Red
Write-Host ""
Write-Host "  Required Solution: Chrome must launch in BOTH sessions" -ForegroundColor Cyan
Write-Host "    - Session 1 (autologon/SSM): Chrome should be visible" -ForegroundColor White
Write-Host "    - Session 2 (RDP): Chrome should also be visible when RDP connects" -ForegroundColor White
Write-Host ""
Write-Host "  How to achieve this:" -ForegroundColor Cyan
Write-Host "    1. The scheduled task 'At Log On' trigger should work for both console and RDP" -ForegroundColor White
Write-Host "    2. When autologon happens → Task runs in Session 1 → Chrome in Session 1" -ForegroundColor Gray
Write-Host "    3. When RDP connects → Task runs again in Session 2 → Chrome in Session 2" -ForegroundColor Gray
Write-Host ""
Write-Host "  Verification:" -ForegroundColor Cyan
Write-Host "    The task '$TaskName' should have 'At Log On' trigger configured for:" -ForegroundColor White
Write-Host "    - Any user logon (works for both console and RDP)" -ForegroundColor Gray
Write-Host "    - User: $Username" -ForegroundColor Gray
Write-Host "    - LogonType: Interactive" -ForegroundColor Gray
Write-Host ""
Write-Host "  If Chrome only appears in Session 1 but not Session 2:" -ForegroundColor Yellow
Write-Host "    - Task may not be triggering on RDP logon" -ForegroundColor Gray
Write-Host "    - Check task trigger settings in Task Scheduler" -ForegroundColor Gray
Write-Host "    - Verify 'At Log On' is set for 'Any user' not just console" -ForegroundColor Gray
Write-Host ""
Write-Host "  Note: Each session will have its own Chrome instance running" -ForegroundColor Cyan
Write-Host "    This is normal - Chrome in Session 1 for SSM, Chrome in Session 2 for RDP" -ForegroundColor Gray
Write-Host ""

# --- Skip RDP Configuration (if specified) ---
if (-not $SkipRDPConfig) {
    Write-SectionHeader "RDP Configuration"
    Write-Host "Checking RDP status..." -ForegroundColor White
    $rdpEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($rdpEnabled -eq 0) {
        Write-Status "RDP is already enabled" "OK"
    } else {
        Write-Host "Enabling RDP..." -ForegroundColor White
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -Force
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        Write-Status "RDP enabled" "OK"
    }
} else {
    Write-Status "Skipping RDP configuration" "INFO"
}

# --- Verify Scheduled Task Configuration (Read-Only) ---
Write-SectionHeader "Scheduled Task Verification"
Write-Host "Verifying scheduled task: $TaskName" -ForegroundColor White
Write-Host "  Note: This is read-only verification - no changes will be made" -ForegroundColor Gray
Write-Host ""

try {
  $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existingTask) {
    Write-Status "Task '$TaskName' exists" "OK"
    Write-Host "    Path: $($existingTask.TaskPath)" -ForegroundColor Gray
    Write-Host "    State: $($existingTask.State)" -ForegroundColor Gray
    
    # Check task settings for restart/recovery behavior
    $taskSettings = $existingTask.Settings
    if ($taskSettings) {
      Write-Host ""
      Write-Host "  Task Restart/Recovery Settings (Read-Only):" -ForegroundColor White
      
      # Check if task is configured to restart on failure
      # NOTE: simple_startup.ps1 already handles restarts internally (up to 5 attempts with delays)
      # The scheduled task should NOT restart on failure - let the PowerShell script handle it
      if ($taskSettings.RestartCount -gt 0) {
        Write-Host "    [WARNING] Task is configured to restart on failure" -ForegroundColor Yellow
        Write-Host "    Restart Count: $($taskSettings.RestartCount)" -ForegroundColor Gray
        Write-Host "    Restart Interval: $($taskSettings.RestartInterval)" -ForegroundColor Gray
        Write-Host "    This may cause 'refused the request' errors when task tries to restart" -ForegroundColor Yellow
        Write-Host "    IMPORTANT: simple_startup.ps1 already handles application restarts internally" -ForegroundColor Cyan
        Write-Host "    The scheduled task should NOT restart - let the PowerShell script handle crashes" -ForegroundColor Cyan
        Write-Host "    Recommendation: Disable task restart on failure (Settings → Restart: OFF)" -ForegroundColor Gray
        Write-Host "    The PowerShell script will still restart the application up to 5 times" -ForegroundColor Gray
      } else {
        Write-Host "    [OK] Task is not configured to automatically restart on failure" -ForegroundColor Green
        Write-Host "    [OK] Application restarts will be handled by simple_startup.ps1 (up to 5 attempts)" -ForegroundColor Green
      }
      
      # Check multiple instances policy
      $multipleInstances = $taskSettings.MultipleInstances
      Write-Host "    Multiple Instances Policy: $multipleInstances" -ForegroundColor Gray
      if ($multipleInstances -eq "Parallel" -or $multipleInstances -eq "Queue") {
        Write-Host "    [INFO] Task allows multiple instances - may cause conflicts" -ForegroundColor Yellow
      }
      
      # Check if task stops on idle
      if ($taskSettings.StopIfGoingOnBatteries -eq $true) {
        Write-Host "    [INFO] Task will stop if going on batteries" -ForegroundColor Gray
      }
    }
    
    # Check last run result and current running processes
    Write-Host ""
    Write-Host "  Task Execution History (Read-Only):" -ForegroundColor White
    try {
      $taskInfo = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
      $taskState = $existingTask.State
      
      if ($taskInfo) {
        Write-Host "    Task State: $taskState" -ForegroundColor $(if ($taskState -eq "Running" -and ($taskInfo.LastTaskResult -eq 267014 -or $taskInfo.LastTaskResult -eq 267009)) { "Red" } elseif ($taskState -eq "Running") { "Yellow" } else { "Gray" })
        Write-Host "    Last Run Time: $(if ($taskInfo.LastRunTime) { $taskInfo.LastRunTime } else { 'Never' })" -ForegroundColor Gray
        $hexResult = "0x{0:X8}" -f $taskInfo.LastTaskResult
        Write-Host "    Last Result: $($taskInfo.LastTaskResult) ($hexResult)" -ForegroundColor $(if ($taskInfo.LastTaskResult -eq 0) { "Green" } elseif ($taskInfo.LastTaskResult -eq 267014 -or $taskInfo.LastTaskResult -eq 267009) { "Red" } else { "Yellow" })
        
        # 267009 = 0x41301, 267014 = 0x41306 - both are "refused the request" variants
        if ($taskInfo.LastTaskResult -eq 267014 -or $taskInfo.LastTaskResult -eq 267009) {
          Write-Host ""
          $errorCodeName = if ($taskInfo.LastTaskResult -eq 267009) { "0x41301" } else { "0x41306" }
          Write-Host "    [ERROR] Last result: $errorCodeName = 'The operator or administrator refused the request'" -ForegroundColor Red
          
          if ($taskState -eq "Running") {
            Write-Host "    [CRITICAL] Task shows as 'Running' but has refused error - task is stuck!" -ForegroundColor Red
            Write-Host "    This means the task started but was immediately refused by Windows" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    Immediate Actions:" -ForegroundColor Cyan
            Write-Host "    1. Stop the stuck task:" -ForegroundColor White
            Write-Host "       Stop-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
            Write-Host "    2. Wait 10 seconds, then verify it stopped:" -ForegroundColor White
            Write-Host "       (Get-ScheduledTask -TaskName '$TaskName').State" -ForegroundColor Gray
            Write-Host "    3. Check if application is already running (causing conflict):" -ForegroundColor White
            Write-Host "       Get-Process python* | Where-Object { (Get-CimInstance Win32_Process -Filter `"ProcessId=`$(`$_.Id)`").CommandLine -match 'src.main' }" -ForegroundColor Gray
            Write-Host "    4. If Python is running, the task may be trying to start a duplicate instance" -ForegroundColor White
            Write-Host ""
          }
          
          Write-Host "    Common causes for 0x41301 error:" -ForegroundColor Yellow
          Write-Host "    1. Task trigger delay too short (< 30 seconds) - session not ready yet" -ForegroundColor Gray
          Write-Host "    2. User session is locked or not fully initialized" -ForegroundColor Gray
          Write-Host "    3. Task lacks 'Log on as a batch job' right (check Local Security Policy)" -ForegroundColor Gray
          Write-Host "    4. Application already running - task trying to start duplicate instance" -ForegroundColor Gray
          Write-Host "    5. Task restart on failure enabled (should be disabled)" -ForegroundColor Gray
          Write-Host ""
          Write-Host "    Recommended fixes:" -ForegroundColor Cyan
          Write-Host "    - Ensure trigger delay is 30-60 seconds (already configured)" -ForegroundColor White
          Write-Host "    - Verify task restart on failure is DISABLED (Settings tab)" -ForegroundColor White
          Write-Host "    - Grant user 'Log on as a batch job' right if not already done" -ForegroundColor White
          Write-Host "    - Check if application is already running and stop it if needed" -ForegroundColor White
          
        } elseif ($taskInfo.LastTaskResult -eq 2147946720) {
          Write-Host "    [ERROR] Last result: 0x80070020 = 'The process cannot access the file because it is being used by another process'" -ForegroundColor Red
          Write-Host "    This usually means:" -ForegroundColor Yellow
          Write-Host "    1. Application is already running (multiple instances conflict)" -ForegroundColor Gray
          Write-Host "    2. Port is already in use" -ForegroundColor Gray
          Write-Host "    3. Lock file or resource conflict" -ForegroundColor Gray
        } elseif ($taskInfo.LastTaskResult -ne 0) {
          $hexResult = "0x{0:X8}" -f $taskInfo.LastTaskResult
          Write-Host "    [WARNING] Last result code: $($taskInfo.LastTaskResult) ($hexResult = error or warning)" -ForegroundColor Yellow
          Write-Host "    Check Windows event logs or application logs for details" -ForegroundColor Gray
        }
        
        Write-Host "    Next Run Time: $(if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime } else { 'Not scheduled' })" -ForegroundColor Gray
      }
    } catch {
      Write-Host "    Could not read task execution history: $_" -ForegroundColor Gray
    }
    
    # Check current running processes (if task is running)
    Write-Host ""
    Write-Host "  Current Process Status (Read-Only):" -ForegroundColor White
    try {
      $pythonProcesses = Get-Process python* -ErrorAction SilentlyContinue | Where-Object {
        try {
          $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
          $cmdLine -match "src\.main"
        } catch {
          $false
        }
      }
      
      if ($pythonProcesses) {
        Write-Host "    [INFO] Python application process found:" -ForegroundColor Cyan
        foreach ($proc in $pythonProcesses) {
          $procSession = $proc.SessionId
          $procOwner = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" | Invoke-CimMethod -MethodName GetOwner).User
          Write-Host "      PID: $($proc.Id) | SessionId: $procSession | Owner: $procOwner" -ForegroundColor $(if ($procSession -eq 0 -or $procOwner -like "*SYSTEM*") { "Red" } else { "Green" })
          
          if ($procSession -eq 0 -or $procOwner -like "*SYSTEM*") {
            Write-Host "      [ERROR] Python is running in Session 0 or as SYSTEM - Chrome will run in background!" -ForegroundColor Red
            Write-Host "      This means the task is NOT running as logged-in user despite configuration" -ForegroundColor Red
          } else {
            Write-Host "      [OK] Python is running in Session $procSession as $procOwner" -ForegroundColor Green
          }
        }
        
        $chromeProcesses = Get-Process chrome -ErrorAction SilentlyContinue
        if ($chromeProcesses) {
          Write-Host ""
          Write-Host "    [INFO] Chrome processes found:" -ForegroundColor Cyan
          $chromeSessions = $chromeProcesses | Select-Object -ExpandProperty SessionId -Unique
          foreach ($session in $chromeSessions) {
            $count = ($chromeProcesses | Where-Object { $_.SessionId -eq $session }).Count
            Write-Host "      Session $session : $count process(es)" -ForegroundColor $(if ($session -eq 0) { "Red" } else { "Green" })
            
            if ($session -eq 0) {
              Write-Host "      [ERROR] Chrome is running in Session 0 (background) - NOT visible!" -ForegroundColor Red
            } else {
              Write-Host "      [OK] Chrome is running in Session $session (foreground) - should be visible" -ForegroundColor Green
            }
          }
        } else {
          Write-Host "    [INFO] No Chrome processes found (application may not have started Chrome yet)" -ForegroundColor Gray
        }
      } else {
        Write-Host "    [INFO] Python application process not found (task may not be running currently)" -ForegroundColor Gray
      }
    } catch {
      Write-Host "    Could not check running processes: $_" -ForegroundColor Gray
    }
    
    # Check principal settings
    Write-Host ""
    Write-Host "  Task Principal Settings (Read-Only):" -ForegroundColor White
    $principal = $existingTask.Principal
    $currentUserId = $principal.UserId
    $expectedUserId = "$env:USERDOMAIN\$Username"
    $systemUsers = @("SYSTEM", "NT AUTHORITY\SYSTEM", "S-1-5-18")
    
    # Normalize user IDs for comparison
    $currentUserIdNormalized = $currentUserId -replace '^.*\\', ''
    $expectedUserIdNormalized = $expectedUserId -replace '^.*\\', ''
    
    Write-Host "    UserId: $currentUserId" -ForegroundColor $(if ($systemUsers -contains $currentUserId -or $currentUserId -like "*SYSTEM*") { "Red" } elseif ($currentUserIdNormalized -ne $expectedUserIdNormalized) { "Yellow" } else { "Green" })
    Write-Host "    LogonType: $($principal.LogonType)" -ForegroundColor $(if ($principal.LogonType -eq "Interactive") { "Green" } else { "Red" })
    Write-Host "    RunLevel: $($principal.RunLevel)" -ForegroundColor Gray
    
    if ($systemUsers -contains $currentUserId -or $currentUserId -like "*SYSTEM*") {
      Write-Host "    [ERROR] Task runs as SYSTEM - Chrome will run in background (Session 0)" -ForegroundColor Red
      Write-Host "    Required: Task must run as '$expectedUserId' or '$Username'" -ForegroundColor Yellow
    } elseif ($currentUserIdNormalized -ne $expectedUserIdNormalized) {
      Write-Host "    [WARNING] Task runs as different user: $currentUserId" -ForegroundColor Yellow
      Write-Host "    Expected: $expectedUserId or $Username" -ForegroundColor Gray
    } else {
      Write-Host "    [OK] Task runs as logged-in user (Session 1)" -ForegroundColor Green
    }
    
    if ($principal.LogonType -ne "Interactive") {
      Write-Host "    [ERROR] LogonType is not Interactive - Chrome will run in background" -ForegroundColor Red
      Write-Host "    Required: LogonType must be 'Interactive' for Chrome visibility" -ForegroundColor Yellow
    } else {
      Write-Host "    [OK] LogonType is Interactive (runs in Session 1)" -ForegroundColor Green
    }
    
    # Check triggers
  Write-Host ""
    Write-Host "  Task Triggers (Read-Only):" -ForegroundColor White
    $hasLogonTrigger = $false
    foreach ($trigger in $existingTask.Triggers) {
      $triggerType = $trigger.CimClass.CimClassName
      Write-Host "    Trigger Type: $triggerType" -ForegroundColor Gray
      
      if ($triggerType -eq "MSFT_TaskLogonTrigger") {
        $hasLogonTrigger = $true
        
        # Check if trigger is configured for specific user or any user
        $userId = $trigger.UserId
        if ([string]::IsNullOrEmpty($userId)) {
          Write-Host "      [OK] Trigger configured for 'Any user' (works for both console and RDP logon)" -ForegroundColor Green
        } else {
          Write-Host "      UserId: $userId" -ForegroundColor Gray
          if ($userId -eq $Username -or $userId -eq "$env:USERDOMAIN\$Username") {
            Write-Host "      [OK] Trigger configured for user '$Username' (should work for both console and RDP)" -ForegroundColor Green
          } else {
            Write-Host "      [WARNING] Trigger configured for different user: $userId" -ForegroundColor Yellow
          }
        }
        
        Write-Host "      Delay: $($trigger.Delay)" -ForegroundColor Gray
        if ($trigger.Delay) {
          $delaySeconds = [math]::Round($trigger.Delay.TotalSeconds)
          if ($delaySeconds -lt 30) {
            Write-Host "      [WARNING] Trigger delay is less than 30 seconds ($delaySeconds seconds)" -ForegroundColor Yellow
            Write-Host "      Recommendation: Increase delay to 30-60 seconds for autologon compatibility" -ForegroundColor Gray
          } else {
            Write-Host "      [OK] Trigger delay is sufficient ($delaySeconds seconds)" -ForegroundColor Green
          }
        } else {
          Write-Host "      [WARNING] No delay configured - may cause issues with autologon" -ForegroundColor Yellow
        }
        
        Write-Host ""
        Write-Host "      Expected Behavior:" -ForegroundColor Cyan
        Write-Host "        - Autologon (Session 1): Task triggers → Chrome launches in Session 1 → Visible in SSM" -ForegroundColor Gray
        Write-Host "        - RDP Logon (Session 2): Task triggers again → Chrome launches in Session 2 → Visible in RDP" -ForegroundColor Gray
        Write-Host "        - Each session will have its own Chrome instance (this is normal)" -ForegroundColor Gray
      }
    }
    
    if (-not $hasLogonTrigger) {
      Write-Host "    [WARNING] No 'At Log On' trigger found!" -ForegroundColor Red
      Write-Host "    Task will not automatically start on logon (console or RDP)" -ForegroundColor Yellow
      Write-Host "    Recommendation: Add 'At Log On' trigger for user '$Username'" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "  Application Restart Behavior:" -ForegroundColor Cyan
    Write-Host "    ✓ simple_startup.ps1 handles application restarts internally (up to 5 attempts)" -ForegroundColor Green
    Write-Host "    ✓ Restart delays: 30s → 1m → 2m → 5m (progressive backoff)" -ForegroundColor Green
    Write-Host "    ✓ Scheduled task should NOT restart on failure (causes 'refused the request' error)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Recommendations for 'refused the request' error after application runs:" -ForegroundColor Cyan
    Write-Host "    1. DISABLE task restart on failure (Settings → If task fails, restart every: OFF)" -ForegroundColor Yellow
    Write-Host "       → The PowerShell script will still restart the application automatically" -ForegroundColor Gray
    Write-Host "       → Task restart conflicts with autologon and causes the error" -ForegroundColor Gray
    Write-Host "    2. Ensure trigger delay is 30-60 seconds (already configured)" -ForegroundColor White
    Write-Host "    3. Check application logs for crashes:" -ForegroundColor White
    Write-Host "       C:\Users\$Username\Documents\Applications\browser-automation-launcher\logs\crash.log" -ForegroundColor Gray
    Write-Host "    4. Grant user 'Log on as a batch job' right if not already done" -ForegroundColor White
    Write-Host ""
    
    # Additional verification after task is stopped
    if ($taskState -eq "Ready" -or $taskState -eq "Disabled") {
      Write-Host "  Task Status Check:" -ForegroundColor Cyan
      Write-Host "    Task is now in '$taskState' state - ready to run" -ForegroundColor Green
      Write-Host ""
      Write-Host "    Next Steps:" -ForegroundColor Cyan
      Write-Host "    1. Test the task manually (optional):" -ForegroundColor White
      Write-Host "       Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Gray
      Write-Host "    2. Wait 10-15 seconds, then check if Python started:" -ForegroundColor White
      Write-Host "       Get-Process python* | Where-Object { (Get-CimInstance Win32_Process -Filter `"ProcessId=`$(`$_.Id)`").CommandLine -match 'src.main' }" -ForegroundColor Gray
      Write-Host "    3. Check Chrome processes and session:" -ForegroundColor White
      Write-Host "       Get-Process chrome | Select-Object Id,ProcessName,SessionId" -ForegroundColor Gray
      Write-Host "    4. On next restart, the task will trigger automatically after 30s delay" -ForegroundColor White
      Write-Host ""
    }
    
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  VERIFICATION: Chrome in Both Sessions" -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Run these commands after autologon restart to verify Chrome in both sessions:" -ForegroundColor White
Write-Host ""
Write-Host "  STEP 1: Check active sessions" -ForegroundColor Yellow
Write-Host '    query session' -ForegroundColor White
Write-Host "    Expected: Session 1 (console) and Session 2 (RDP) should both be Active" -ForegroundColor Gray
Write-Host ""
Write-Host "  STEP 2: Check Chrome processes by session" -ForegroundColor Yellow
Write-Host '    Get-Process chrome -ErrorAction SilentlyContinue | Group-Object SessionId | Select-Object @{Name="Session";Expression={$_.Name}}, @{Name="ChromeCount";Expression={$_.Count}} | Format-Table' -ForegroundColor White
Write-Host "    Expected: Chrome processes in Session 1 AND Session 2" -ForegroundColor Gray
Write-Host ""
Write-Host "  STEP 3: Detailed Chrome session breakdown" -ForegroundColor Yellow
Write-Host '    Get-Process chrome -ErrorAction SilentlyContinue | Select-Object Id,ProcessName,SessionId | Group-Object SessionId | ForEach-Object { Write-Host "Session $($_.Name): $($_.Count) Chrome processes" -ForegroundColor $(if ($_.Name -eq 0) { "Red" } else { "Green" }); $_.Group | Select-Object -First 3 Id,SessionId }' -ForegroundColor White
Write-Host ""
Write-Host "  STEP 4: Check Python processes by session" -ForegroundColor Yellow
Write-Host '    $pythonProcs = Get-Process python* -ErrorAction SilentlyContinue | Where-Object { try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine; $cmd -match "src\.main" } catch { $false } }; $pythonProcs | Group-Object SessionId | Select-Object @{Name="Session";Expression={$_.Name}}, @{Name="PythonCount";Expression={$_.Count}} | Format-Table' -ForegroundColor White
Write-Host "    Expected: Python processes in Session 1 AND Session 2" -ForegroundColor Gray
Write-Host ""
Write-Host "  STEP 5: Check Chrome window visibility in each session" -ForegroundColor Yellow
Write-Host '    Get-Process chrome -ErrorAction SilentlyContinue | Group-Object SessionId | ForEach-Object { $session = $_.Name; $visible = ($_.Group | Where-Object { $_.MainWindowTitle -ne "" }).Count; $total = $_.Count; Write-Host "Session $session : $visible/$total Chrome processes have visible windows" -ForegroundColor $(if ($visible -gt 0) { "Green" } else { "Yellow" }) }' -ForegroundColor White
Write-Host "    Expected: At least some Chrome processes have visible windows in each session" -ForegroundColor Gray
Write-Host ""
Write-Host "  STEP 6: Complete session summary (All-in-one)" -ForegroundColor Yellow
Write-Host '    Write-Host "=== SESSION SUMMARY ===" -ForegroundColor Cyan; Write-Host ""; Write-Host "Active Sessions:" -ForegroundColor White; query session | Select-Object -Skip 1; Write-Host ""; Write-Host "Chrome by Session:" -ForegroundColor White; Get-Process chrome -ErrorAction SilentlyContinue | Group-Object SessionId | ForEach-Object { Write-Host "  Session $($_.Name): $($_.Count) Chrome processes" -ForegroundColor $(if ($_.Name -eq 0) { "Red" } elseif ($_.Name -eq 1) { "Green" } else { "Green" }) }; Write-Host ""; Write-Host "Python by Session:" -ForegroundColor White; $pythons = Get-Process python* -ErrorAction SilentlyContinue | Where-Object { try { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -match "src\.main" } catch { $false } }; $pythons | Group-Object SessionId | ForEach-Object { Write-Host "  Session $($_.Name): $($_.Count) Python processes" -ForegroundColor Green }' -ForegroundColor White
Write-Host ""
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  INTERPRETATION:" -ForegroundColor Cyan
Write-Host "  ========================================" -ForegroundColor Cyan
Write-Host "  ✓ SUCCESS: Chrome in Session 1 AND Session 2 = Working in both sessions" -ForegroundColor Green
Write-Host "  ⚠ ISSUE: Chrome only in Session 1 = Task not triggering on RDP logon" -ForegroundColor Yellow
Write-Host "  ⚠ ISSUE: Chrome only in Session 2 = Task not triggering on autologon" -ForegroundColor Yellow
Write-Host "  ✗ ERROR: Chrome in Session 0 = Task running as SYSTEM (background)" -ForegroundColor Red
Write-Host ""
    
  } else {
    Write-Status "Task '$TaskName' not found" "WARNING"
    Write-Host "    Task should already exist (created manually or via setup script)" -ForegroundColor Gray
  }
} catch {
  Write-Status "Could not verify scheduled task: $_" "WARNING"
}

Write-Host ""
Write-Status "Setup Complete" "OK"
