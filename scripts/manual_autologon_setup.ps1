# Safe AutoLogon Setup (for GUI Chrome)
# Run as Administrator on your EC2 instance once.
#
# IMPORTANT: This script does NOT change existing user passwords.
# IMPORTANT: This script does NOT create scheduled tasks - it only triggers existing ones.
# - If user exists: Preserves existing password, only configures autologon
# - If user doesn't exist: Creates user with provided password
# - To update autologon password: Use -UpdateAutologonPassword flag after manually changing password
# - To trigger existing task: Use -RunTaskNow flag (default: true)

param(
  [string]$Username = "Administrator",
  [string]$TaskName = "BrowserAutomationStartup",
  [string]$Password = "",               # Optional: Only used if creating new user or UpdateAutologonPassword is true
  [switch]$UpdateAutologonPassword = $false,  # Set to $true to update autologon registry password
  [switch]$MakeUserAdmin = $true,
  [switch]$RunTaskNow = $true,          # Trigger existing scheduled task immediately
  [switch]$RebootWhenDone = $false
)

$ErrorActionPreference = "Stop"

# --- Track if we created a new user (affects autologon password setting) ---
$UserWasCreated = $false

# --- Ensure User Exists (DO NOT change existing password) ---
if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  if ([string]::IsNullOrEmpty($Password)) {
    Write-Error "Password is required when creating a new user. Provide -Password parameter."
    exit 1
  }
  Write-Host "Creating local user $Username with provided password..."
  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  New-LocalUser -Name $Username -Password $sec -FullName "AutoLogin User" -Description "Used for AutoLogin GUI tasks"
  if ($MakeUserAdmin) { 
    try { Add-LocalGroupMember -Group "Administrators" -Member $Username } catch { Write-Host "Note: User might already be admin" }
  }
  $UserWasCreated = $true
  Write-Host "[OK] User created successfully"
} else {
  Write-Host "User $Username already exists. Preserving existing password (no changes made)."
  Write-Host "  Note: To change password for existing user, do it manually via SSM:"
  Write-Host "    net user $Username 'YourNewPassword'"
  Write-Host "  Then run this script with -UpdateAutologonPassword to update autologon registry."
}

# Configure password expiration (safe operation, doesn't change password)
try {
  Set-LocalUser -Name $Username -PasswordNeverExpires $true -ErrorAction Stop
  cmd /c "net user $Username /expires:never" | Out-Null
  Write-Host "[OK] Password expiration disabled"
} catch {
  Write-Host "Warning: Could not configure password expiration: $_"
}

# --- Enable AutoLogin Safely ---
Write-Host "Configuring AutoAdminLogon for $Username..."
$reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }

# Determine what password to use for autologon registry
$autologonPassword = $null
if ($UserWasCreated) {
  # We created the user, so use the password we set
  $autologonPassword = $Password
  Write-Host "  Using password from user creation for autologon..."
} elseif ($UpdateAutologonPassword -and -not [string]::IsNullOrEmpty($Password)) {
  # User explicitly wants to update autologon password
  $autologonPassword = $Password
  Write-Host "  Updating autologon registry password (UpdateAutologonPassword flag set)..."
} else {
  # Preserve existing autologon password or use empty (will prompt user)
  $existingPassword = (Get-ItemProperty -Path $reg -Name 'DefaultPassword' -ErrorAction SilentlyContinue).DefaultPassword
  if ($existingPassword) {
    $autologonPassword = $existingPassword
    Write-Host "  Preserving existing autologon registry password..."
  } else {
    Write-Host "  Warning: No password in autologon registry and no password provided."
    Write-Host "  Autologon may not work. Set password manually or use -UpdateAutologonPassword"
    $autologonPassword = ""
  }
}

Set-ItemProperty -Path $reg -Name 'AutoAdminLogon' -Type String -Value '1'
Set-ItemProperty -Path $reg -Name 'ForceAutoLogon' -Type String -Value '1'
Set-ItemProperty -Path $reg -Name 'DisableCAD' -Type DWord -Value 1
Set-ItemProperty -Path $reg -Name 'DefaultUserName' -Type String -Value $Username
Set-ItemProperty -Path $reg -Name 'DefaultPassword' -Type String -Value $autologonPassword
Set-ItemProperty -Path $reg -Name 'DefaultDomainName' -Type String -Value $env:COMPUTERNAME

# Prevent console session timeout and screen lock (keeps autologon session active for Chrome GUI)
try {
  # Disable screen saver via system-wide policy (applies to all users)
  $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop'
  if (-not (Test-Path $policyPath)) {
    New-Item -Path $policyPath -Force | Out-Null
  }
  Set-ItemProperty -Path $policyPath -Name 'ScreenSaveActive' -Type String -Value '0' -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty -Path $policyPath -Name 'ScreenSaverIsSecure' -Type String -Value '0' -ErrorAction SilentlyContinue | Out-Null
  
  # Disable session timeout (prevents RDP session disconnection)
  $rdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
  if (-not (Test-Path $rdpTcpPath)) {
    New-Item -Path $rdpTcpPath -Force | Out-Null
  }
  Set-ItemProperty -Path $rdpTcpPath -Name 'MaxDisconnectionTime' -Type DWord -Value 0 -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty -Path $rdpTcpPath -Name 'MaxIdleTime' -Type DWord -Value 0 -ErrorAction SilentlyContinue | Out-Null
  
  Write-Host "[OK] Configured session to stay active (no screen lock/timeout)"
} catch {
  # Non-critical, ignore errors
  Write-Host "Note: Some session timeout settings could not be configured: $_"
}

Write-Host "[OK] AutoLogin configured for user '$Username'"
if ([string]::IsNullOrEmpty($autologonPassword)) {
  Write-Host "  [WARNING] Autologon password is empty. Autologon may not work on reboot."
}

# --- Enable and Configure RDP for Remote Access ---
Write-Host "Checking RDP configuration..."
try {
  # Check if RDP is already enabled
  $rdpEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
  
  if ($rdpEnabled -eq 0) {
    Write-Host "RDP is already enabled. Skipping RDP configuration."
  } else {
    Write-Host "RDP is disabled. Enabling RDP..."
    
    # Enable RDP service
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Type DWord -Value 0 -Force | Out-Null
    
    # Enable RDP through Windows Firewall
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Out-Null
    
    # Set RDP authentication level (0 = Allow connections from computers running any version of Remote Desktop)
    $rdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    if (-not (Test-Path $rdpTcpPath)) {
      New-Item -Path $rdpTcpPath -Force | Out-Null
    }
    Set-ItemProperty -Path $rdpTcpPath -Name 'UserAuthentication' -Type DWord -Value 0 -Force | Out-Null
    
    # Ensure Remote Desktop Service is running
    $rdpService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if ($rdpService) {
      Set-Service -Name 'TermService' -StartupType Automatic -ErrorAction SilentlyContinue
      if ($rdpService.Status -ne 'Running') {
        Start-Service -Name 'TermService' -ErrorAction SilentlyContinue
        Write-Host "[OK] RDP service started."
      } else {
        Write-Host "[OK] RDP service already running."
      }
    }
    
    Write-Host "[OK] RDP configured and enabled. You can now connect via RDP on port 3389."
  }
} catch {
  Write-Host "Warning: Could not fully configure RDP: $_"
  Write-Host "You may need to manually enable RDP via: sysdm.cpl -> Remote tab -> Enable Remote Desktop"
}

# --- Verify Scheduled Task Exists ---
Write-Host "Checking for existing scheduled task '$TaskName'..."
$taskExists = $false
try {
  $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existingTask) {
    $taskExists = $true
    Write-Host "[OK] Scheduled task '$TaskName' already exists."
    Write-Host "  Task path: $($existingTask.TaskPath)"
    Write-Host "  Task state: $($existingTask.State)"
  }
} catch {
  # Task doesn't exist
}

if (-not $taskExists) {
  Write-Host "[WARNING] Scheduled task '$TaskName' not found."
  Write-Host "  The task should already exist (created during AMI setup or manually)."
  Write-Host "  If missing, create it manually or use a different script to set it up."
}

# --- Optionally Run Existing Task Now ---
if ($RunTaskNow) {
  if ($taskExists) {
    Write-Host ""
    Write-Host "Triggering existing scheduled task '$TaskName'..."
    try {
      $result = schtasks /run /tn "$TaskName" 2>&1
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Task '$TaskName' triggered successfully."
      } else {
        Write-Host "[WARNING] Task trigger may have failed. Output: $result"
      }
    } catch { 
      Write-Host "[ERROR] Could not trigger task: $_"
    }
  } else {
    Write-Host "[SKIP] Task '$TaskName' not found. Cannot trigger."
  }
}

Write-Host ""
Write-Host "Setup complete: AutoLogin configured."
if ($taskExists) {
  Write-Host "  Scheduled task '$TaskName' exists and can be triggered manually or via autologon."
} else {
  Write-Host "  [NOTE] Scheduled task '$TaskName' was not found. Ensure it exists for autologon to start the app."
}

# --- Final RDP Verification ---
Write-Host ""
Write-Host "=========================================="
Write-Host "RDP Connection Checklist:"
Write-Host "=========================================="
Write-Host "1. Security Group: Ensure port 3389 (RDP) is open in AWS Security Group"
if ($UserWasCreated) {
  Write-Host "2. Password: Use the password you provided when creating user"
} else {
  Write-Host "2. Password: Use the EXISTING password for $Username (script did not change it)"
  Write-Host "   To verify current password, check via SSM or reset it manually"
}
Write-Host "3. Username: $Username"
Write-Host "4. Public IP: Use instance's public IP address"
Write-Host ""
Write-Host "To verify RDP is enabled, run via SSM:"
Write-Host "  (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server').fDenyTSConnections"
Write-Host "  (Should return: 0)"
Write-Host ""
Write-Host "If RDP still doesn't work after reboot:"
Write-Host "  1. Check security group allows port 3389"
Write-Host "  2. Verify password matches: Run 'net user $Username' via SSM"
Write-Host "  3. Try: Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
Write-Host ""

if ($RebootWhenDone) {
  Write-Host "Rebooting to apply AutoLogin and RDP configuration..."
  Restart-Computer -Force
}
