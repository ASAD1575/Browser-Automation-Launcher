<powershell>
$ErrorActionPreference = "Stop"
Start-Transcript -Path "C:\\ProgramData\\cloudwatch-bootstrap.log" -Append

# ----------------------------
# 0) Helpers
# ----------------------------
function Get-IMDSToken {
  try {
    $res = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 5
    return $res
  } catch { return $null }
}

function Get-IMDS($path, $token) {
  $headers = @{}
  if ($token) { $headers["X-aws-ec2-metadata-token"] = $token }
  return Invoke-RestMethod -Uri "http://169.254.169.254/latest/$path" -Headers $headers -TimeoutSec 5
}

# ----------------------------
# 1) Ensure SSM Agent present & running
# ----------------------------
if (-not (Get-Service AmazonSSMAgent -ErrorAction SilentlyContinue)) {
  Write-Host "Installing SSM Agent..."
  $region = (Get-IMDS "meta-data/placement/region" (Get-IMDSToken))
  if (-not $region) { $region = "${var.region}" } # fallback to TF var
  $ssmUrl = "https://s3.amazonaws.com/amazon-ssm-$region/latest/windows_amd64/AmazonSSMAgentSetup.exe"
  $ssmExe = "C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe"
  Invoke-WebRequest -Uri $ssmUrl -OutFile $ssmExe -UseBasicParsing
  Start-Process -FilePath $ssmExe -ArgumentList "/S" -Wait
}
try {
  Start-Service AmazonSSMAgent
  Set-Service -Name AmazonSSMAgent -StartupType Automatic
} catch { Write-Host "SSM start failed: $_" }

# ----------------------------
# 2) Configure Auto-Login
# ----------------------------
Write-Host "Configuring Windows Auto-Login..."
$Username = "${var.windows_username}"
$PasswordPlain = "${var.windows_password}"
$Password = $PasswordPlain | ConvertTo-SecureString -AsPlainText -Force
$RegPath  = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"

# Ensure user exists
if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  Write-Host "Creating local user $Username..."
  New-LocalUser -Name $Username -Password $Password -FullName "AutoLogin User" -Description "Automatically logged in on startup"
  Add-LocalGroupMember -Group "Administrators" -Member $Username
} else {
  Write-Host "User $Username exists. Updating password..."
  Set-LocalUser -Name $Username -Password $Password
}

# Enable auto-login via registry (align with manual script)
if (-not (Test-Path $RegPath)) {
  $parent = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
  if (-not (Test-Path $parent)) {
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT' -Name 'CurrentVersion' -Force | Out-Null
  }
  New-Item -Path $parent -Name 'Winlogon' -Force | Out-Null
}
Set-ItemProperty -Path $RegPath -Name 'AutoAdminLogon' -Type String -Value '1'
Set-ItemProperty -Path $RegPath -Name 'ForceAutoLogon' -Type String -Value '1'
Set-ItemProperty -Path $RegPath -Name 'DisableCAD' -Type DWord -Value 1
Set-ItemProperty -Path $RegPath -Name 'DefaultUsername' -Type String -Value $Username
Set-ItemProperty -Path $RegPath -Name 'DefaultPassword' -Type String -Value $PasswordPlain
Set-ItemProperty -Path $RegPath -Name 'DefaultDomainName' -Type String -Value $env:COMPUTERNAME
Write-Host "Auto-login enabled for user '$Username'."

# Prevent console session timeout and screen lock (keeps autologon session active for Chrome GUI)
try {
  $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop'
  if (-not (Test-Path $policyPath)) {
    New-Item -Path $policyPath -Force | Out-Null
  }
  Set-ItemProperty -Path $policyPath -Name 'ScreenSaveActive' -Type String -Value '0' -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty -Path $policyPath -Name 'ScreenSaverIsSecure' -Type String -Value '0' -ErrorAction SilentlyContinue | Out-Null
  
  $rdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
  if (-not (Test-Path $rdpTcpPath)) {
    New-Item -Path $rdpTcpPath -Force | Out-Null
  }
  Set-ItemProperty -Path $rdpTcpPath -Name 'MaxDisconnectionTime' -Type DWord -Value 0 -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty -Path $rdpTcpPath -Name 'MaxIdleTime' -Type DWord -Value 0 -ErrorAction SilentlyContinue | Out-Null
} catch {
  # Non-critical
}

# ----------------------------
# 2.1) Allow blank-password autologon and remove blockers
# ----------------------------
try {
  # Ensure Lsa key exists, then set value
  if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa')) {
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'Lsa' -Force | Out-Null
  }
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -PropertyType DWord -Value 0 -Force | Out-Null

  # Ensure Policies\System key exists, then set values
  if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies')) {
      New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -Name 'Policies' -Force | Out-Null
    }
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' -Name 'System' -Force | Out-Null
  }
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DisableCAD' -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'legalnoticecaption' -PropertyType String -Value '' -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'legalnoticetext' -PropertyType String -Value '' -Force | Out-Null

  Write-Host "Policies updated for blank-password autologon and no prompts"
} catch {
  Write-Host "Failed to update blank-password/autologon policies: $_"
}

# ----------------------------
# 3) Schedule Task to Trigger Auto Login After Reboot (Fixed)
# ----------------------------
Write-Host "Creating persistent auto-login trigger task..."

$TaskName = "ForceAutoLogin"
$TaskScript = "C:\\ProgramData\\trigger_autologin.ps1"

$ScriptContent = @"
Start-Sleep -Seconds 10
Write-Host 'Triggering auto-login session...'
rundll32.exe user32.dll, LockWorkStation
rundll32.exe user32.dll, LockWorkStation
"@
$ScriptContent | Out-File -FilePath $TaskScript -Encoding ASCII -Force

$Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$TaskScript`""
$Trigger = New-ScheduledTaskTrigger -AtStartup

try {
  Register-ScheduledTask -Action $Action -Trigger $Trigger -TaskName $TaskName -Description "Forces auto-login session at startup" -RunLevel Highest -User "SYSTEM" -Force
  Write-Host "Scheduled Task '$TaskName' successfully created under SYSTEM context."
} catch {
  Write-Host "Failed to create scheduled task: $_"
}

# ----------------------------
# 4) Install CloudWatch Agent via MSI (with retries)
# ----------------------------
Write-Host "Installing CloudWatch Agent..."
$msiUrl  = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
$msiPath = "C:\\Windows\\Temp\\amazon-cloudwatch-agent.msi"
$retries = 5
$installSuccess = $false

for ($i=0; $i -lt $retries; $i++) {
  try {
    Write-Host "  Attempt $($i+1)/$retries: Downloading CloudWatch Agent MSI..."
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
    Write-Host "  Installing CloudWatch Agent..."
    $installProcess = Start-Process msiexec.exe -ArgumentList @("/i",$msiPath,"/qn","/norestart") -Wait -PassThru -NoNewWindow
    if ($installProcess.ExitCode -eq 0) {
      $installSuccess = $true
      Write-Host "  [OK] CloudWatch Agent installed successfully."
      break
    } else {
      Write-Host "  [WARNING] Install exit code: $($installProcess.ExitCode)"
      if ($i -eq ($retries-1)) {
        throw "CloudWatch Agent installation failed with exit code: $($installProcess.ExitCode)"
      }
    }
  } catch {
    Write-Host "  [ERROR] Attempt $($i+1) failed: $_"
    if ($i -eq ($retries-1)) {
      Write-Host "  [CRITICAL] CloudWatch Agent installation failed after $retries attempts."
      throw
    }
    Start-Sleep -Seconds 10
  }
}

# Verify CloudWatch Agent is installed
if ($installSuccess) {
  $cwAgentPath = "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent.exe"
  if (Test-Path $cwAgentPath) {
    Write-Host "  [VERIFIED] CloudWatch Agent executable found."
  } else {
    Write-Host "  [WARNING] CloudWatch Agent executable not found at expected path."
  }
}

# ----------------------------
# 5) Build CW Agent config with {InstanceID}/{InstanceName}
# ----------------------------
Write-Host "Configuring CloudWatch Agent..."
$CfgDir = "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent"
$CfgPath = Join-Path $CfgDir "config.json"
try {
  $token = Get-IMDSToken
  $InstanceId = Get-IMDS "meta-data/instance-id" $token
  $InstanceName = $null
  try { $InstanceName = Get-IMDS "meta-data/tags/instance/Name" $token } catch { $InstanceName = $null }
  if (-not $InstanceName) { $InstanceName = "UnknownName" }
  $StreamPrefix = "$InstanceId/$InstanceName"
  Write-Host "  Instance ID: $InstanceId"
  Write-Host "  Instance Name: $InstanceName"
  Write-Host "  Stream Prefix: $StreamPrefix"

  # Use dynamic username instead of hardcoded "Administrator"
  $UserProfilePath = Join-Path "C:\Users" $Username
  $LogBasePath = Join-Path $UserProfilePath "Documents\Applications\browser-automation-launcher\logs"
  $MonitorLogPath = Join-Path $LogBasePath "monitor.log"
  $AppLogPath = Join-Path $LogBasePath "app.log"
  
  Write-Host "  Application log directory: $LogBasePath"
  Write-Host "    Monitor log: $MonitorLogPath"
  Write-Host "    App log: $AppLogPath"

  # Create log directory if it doesn't exist
  if (-not (Test-Path $LogBasePath)) {
    Write-Host "  Creating log directory: $LogBasePath"
    New-Item -ItemType Directory -Force -Path $LogBasePath | Out-Null
  }

  $CwConfig = @{
    logs = @{
      logs_collected = @{
        files = @{
          collect_list = @(
            @{
              file_path       = $MonitorLogPath
              log_group_name  = "${var.cw_log_group_name}"
              log_stream_name = "$StreamPrefix/monitor.log"
              timestamp_format= "%Y-%m-%d %H:%M:%S"
            },
            @{
              file_path       = $AppLogPath
              log_group_name  = "${var.cw_log_group_name}"
              log_stream_name = "$StreamPrefix/app.log"
              timestamp_format= "%Y-%m-%d %H:%M:%S"
            }
          )
        }
        windows_events = @{
          collect_list = @(
            @{
              event_levels    = @("ERROR","WARNING")
              event_format    = "xml"
              log_group_name  = "${var.cw_log_group_name}"
              log_stream_name = "$StreamPrefix/EventLog/System"
              event_name      = "System"
            },
            @{
              event_levels    = @("ERROR","WARNING")
              event_format    = "xml"
              log_group_name  = "${var.cw_log_group_name}"
              log_stream_name = "$StreamPrefix/EventLog/Application"
              event_name      = "Application"
            }
          )
        }
      }
    }
    agent = @{
      metrics_collection_interval = 60
      run_as_user = "NT AUTHORITY\\SYSTEM"
      debug = $false
    }
  }

  New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null
  $CwConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $CfgPath -Encoding ascii -Force
  Write-Host "  [OK] CloudWatch Agent configuration saved to: $CfgPath"
} catch {
  Write-Host "  [ERROR] Failed to configure CloudWatch Agent: $_"
  Write-Host "  Stack trace: $($_.ScriptStackTrace)"
}

# ----------------------------
# 6) Start CloudWatch Agent with local config
# ----------------------------
Write-Host "Starting CloudWatch Agent..."
try {
  # Verify config file was created
  if (-not (Test-Path $CfgPath)) {
    Write-Host "  [ERROR] CloudWatch Agent configuration file not found: $CfgPath"
    Write-Host "  Cannot start CloudWatch Agent without configuration."
    throw "CloudWatch Agent configuration file missing"
  }
  
  $cwCtlPath = "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1"
  
  if (-not (Test-Path $cwCtlPath)) {
    Write-Host "  [ERROR] CloudWatch Agent control script not found: $cwCtlPath"
    Write-Host "  CloudWatch Agent may not have installed correctly."
  } else {
    Write-Host "  Stopping existing CloudWatch Agent (if running)..."
    & $cwCtlPath -a stop | Out-Null
    
    Write-Host "  Starting CloudWatch Agent with configuration file: $CfgPath"
    $startResult = & $cwCtlPath -a start -m ec2 -c "file:$CfgPath" 2>&1
    
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  [OK] CloudWatch Agent started successfully."
    } else {
      Write-Host "  [WARNING] CloudWatch Agent start returned exit code: $LASTEXITCODE"
      Write-Host "  Output: $startResult"
    }
    
    # Verify agent is running
    Start-Sleep -Seconds 2
    $cwService = Get-Service -Name "AmazonCloudWatchAgent" -ErrorAction SilentlyContinue
    if ($cwService) {
      if ($cwService.Status -eq 'Running') {
        Write-Host "  [VERIFIED] CloudWatch Agent service is running."
      } else {
        Write-Host "  [WARNING] CloudWatch Agent service status: $($cwService.Status)"
        Write-Host "  Attempting to start service..."
        Start-Service -Name "AmazonCloudWatchAgent" -ErrorAction SilentlyContinue
      }
    } else {
      Write-Host "  [WARNING] CloudWatch Agent service not found."
    }
  }
} catch {
  Write-Host "  [ERROR] Failed to start CloudWatch Agent: $_"
  Write-Host "  Stack trace: $($_.ScriptStackTrace)"
}

# ----------------------------
# 7) Ensure your app service is Auto + Started
# ----------------------------
$svcName = "${var.app_service_name}"   # e.g., BrowserAutomationLauncher
try {
  if (Get-Service -Name $svcName -ErrorAction Stop) {
    Set-Service -Name $svcName -StartupType Automatic
    Start-Service -Name $svcName -ErrorAction SilentlyContinue
  }
} catch {
  Write-Host "Service '$svcName' not found: $_"
}

# ----------------------------
# 7.1) Create Logon Scheduled Task to start GUI app (interactive desktop)
# ----------------------------
try {
  $LogonTaskName = "BrowserAutomationStartup"
  $UserNameForTask = "$Username"

  # Path to startup script under the autologon user's profile
  $UserProfilePath = Join-Path "C:\Users" $UserNameForTask
  $StartupScript = Join-Path $UserProfilePath "Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1"

  Write-Host "Configuring scheduled task '$LogonTaskName' for user $UserNameForTask..."
  Write-Host "  Expected script path: $StartupScript"

  # Check if user profile exists
  if (-not (Test-Path $UserProfilePath)) {
    Write-Host "  [WARNING] User profile path does not exist yet: $UserProfilePath"
    Write-Host "  The profile will be created when the user first logs on via autologon."
  }

  # Check if startup script exists
  if (-not (Test-Path $StartupScript)) {
    Write-Host "  [WARNING] Startup script not found: $StartupScript"
    Write-Host "  The script should exist before autologon triggers the task."
    Write-Host "  Ensure the application is installed in the user's profile."
  } else {
    Write-Host "  [OK] Startup script found."
  }

  # Remove any existing task
  try { 
    Unregister-ScheduledTask -TaskName $LogonTaskName -Confirm:$false -ErrorAction SilentlyContinue 
    Write-Host "  Removed any existing task with same name."
  } catch {}

  # Create the scheduled task
  $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$StartupScript`""
  $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $UserNameForTask
  # Match manual test script: use Interactive desktop logon type
  $principal = New-ScheduledTaskPrincipal -UserId $UserNameForTask -LogonType Interactive -RunLevel Highest

  Register-ScheduledTask -TaskName $LogonTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
  Write-Host "  [OK] Scheduled task '$LogonTaskName' registered successfully."

  # Verify task was created
  try {
    $createdTask = Get-ScheduledTask -TaskName $LogonTaskName -ErrorAction Stop
    Write-Host "  [VERIFIED] Task exists with state: $($createdTask.State)"
    Write-Host "  Task will trigger automatically when user '$UserNameForTask' logs on via autologon (after reboot)."
    
    # Show task details
    $taskInfo = Get-ScheduledTaskInfo -TaskName $LogonTaskName -ErrorAction SilentlyContinue
    if ($taskInfo) {
      Write-Host "  Last run: $($taskInfo.LastRunTime)"
      Write-Host "  Last result: $($taskInfo.LastTaskResult)"
    }
  } catch {
    Write-Host "  [ERROR] Could not verify task creation: $_"
  }
} catch {
  Write-Host "[ERROR] Failed to create logon scheduled task: $_"
  Write-Host "  Stack trace: $($_.ScriptStackTrace)"
}

# ----------------------------
# 7.2) Enable and Configure RDP for Remote Access
# ----------------------------
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
        Write-Host "RDP service started."
      } else {
        Write-Host "RDP service already running."
      }
    }
    
    Write-Host "RDP configured and enabled. Port 3389 should be accessible via Security Group."
  }
} catch {
  Write-Host "Warning: Could not fully configure RDP: $_"
}

# # ----------------------------
# # 8) Verify Autologon Configuration Before Reboot
# # ----------------------------
# Write-Host ""
# Write-Host "=========================================="
# Write-Host "Pre-Reboot Verification"
# Write-Host "=========================================="

# # Verify autologon is configured
# $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
# try {
#   $autoAdminLogon = (Get-ItemProperty -Path $winlogonPath -Name 'AutoAdminLogon' -ErrorAction SilentlyContinue).AutoAdminLogon
#   $defaultUser = (Get-ItemProperty -Path $winlogonPath -Name 'DefaultUserName' -ErrorAction SilentlyContinue).DefaultUserName
  
#   if ($autoAdminLogon -eq '1' -and $defaultUser -eq "$Username") {
#     Write-Host "[OK] Autologon is configured for user: $defaultUser"
#   } else {
#     Write-Host "[WARNING] Autologon may not be properly configured:"
#     Write-Host "  AutoAdminLogon: $autoAdminLogon"
#     Write-Host "  DefaultUserName: $defaultUser"
#   }
# } catch {
#   Write-Host "[WARNING] Could not verify autologon configuration: $_"
# }

# # Verify scheduled task exists
# try {
#   $task = Get-ScheduledTask -TaskName "BrowserAutomationStartup" -ErrorAction Stop
#   Write-Host "[OK] Scheduled task 'BrowserAutomationStartup' exists with state: $($task.State)"
#   Write-Host "  Note: Task will remain in 'Ready' state until user logs on via autologon."
#   Write-Host "  After reboot and autologon, the task should automatically trigger and change to 'Running'."
# } catch {
#   Write-Host "[ERROR] Scheduled task 'BrowserAutomationStartup' not found!"
# }

# # Verify CloudWatch Agent is installed and configured
# try {
#   $cwService = Get-Service -Name "AmazonCloudWatchAgent" -ErrorAction SilentlyContinue
#   if ($cwService) {
#     Write-Host "[OK] CloudWatch Agent service found with status: $($cwService.Status)"
#   } else {
#     Write-Host "[WARNING] CloudWatch Agent service not found."
#   }
  
#   if (Test-Path $CfgPath) {
#     Write-Host "[OK] CloudWatch Agent configuration file exists: $CfgPath"
#   } else {
#     Write-Host "[ERROR] CloudWatch Agent configuration file not found: $CfgPath"
#   }
# } catch {
#   Write-Host "[WARNING] Could not verify CloudWatch Agent: $_"
# }

# Write-Host ""
# Write-Host "=========================================="
# Write-Host "Post-Reboot Expected Behavior"
# Write-Host "=========================================="
# Write-Host "1. System will reboot"
# Write-Host "2. Autologon will log in user '$Username' automatically"
# Write-Host "3. Scheduled task 'BrowserAutomationStartup' will trigger automatically"
# Write-Host "4. Application will start via simple_startup.ps1"
# Write-Host ""
# Write-Host "To verify after reboot (via SSM):"
# Write-Host "  schtasks /query /tn BrowserAutomationStartup /fo LIST"
# Write-Host "  # Should show Status: Running (after autologon completes)"
# Write-Host ""
# Write-Host "If task remains in 'Ready' state after reboot:"
# Write-Host "  1. Check autologon worked: verify user is logged in"
# Write-Host "  2. Check task history: Event Viewer -> Task Scheduler"
# Write-Host "  3. Manually trigger: schtasks /run /tn BrowserAutomationStartup"
# Write-Host ""

# ----------------------------
# 9) Force reboot to apply auto-login
# ----------------------------
Write-Host "Rebooting to apply auto-login and RDP configuration..."
Write-Host "Setup complete: Auto-login, login trigger, CloudWatch, SSM, and App service configured."
Stop-Transcript
Restart-Computer -Force
</powershell>