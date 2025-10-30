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
$msiUrl  = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
$msiPath = "C:\\Windows\\Temp\\amazon-cloudwatch-agent.msi"
$retries = 5
for ($i=0; $i -lt $retries; $i++) {
  try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList @("/i",$msiPath,"/qn","/norestart") -Wait
    break
  } catch {
    Start-Sleep -Seconds 10
    if ($i -eq ($retries-1)) { throw }
  }
}

# ----------------------------
# 5) Build CW Agent config with {InstanceID}/{InstanceName}
# ----------------------------
$token = Get-IMDSToken
$InstanceId = Get-IMDS "meta-data/instance-id" $token
$InstanceName = $null
try { $InstanceName = Get-IMDS "meta-data/tags/instance/Name" $token } catch { $InstanceName = $null }
if (-not $InstanceName) { $InstanceName = "UnknownName" }
$StreamPrefix = "$InstanceId/$InstanceName"

$CwConfig = @{
  logs = @{
    logs_collected = @{
      files = @{
        collect_list = @(
          @{
            file_path       = "C:\\Users\\Administrator\\Documents\\applications\\browser-automation-launcher\\logs\\monitor.log"
            log_group_name  = "${var.cw_log_group_name}"
            log_stream_name = "$StreamPrefix/monitor.log"
            timestamp_format= "%Y-%m-%d %H:%M:%S"
          },
          @{
            file_path       = "C:\\Users\\Administrator\\Documents\\applications\\browser-automation-launcher\\logs\\app.log"
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

$CfgDir = "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent"
$CfgPath = Join-Path $CfgDir "config.json"
New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null
$CwConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $CfgPath -Encoding ascii -Force

# ----------------------------
# 6) Start CloudWatch Agent with local config
# ----------------------------
Write-Host "Starting CloudWatch Agent..."
& "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1" -a stop | Out-Null
& "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1" -a start -m ec2 -c "file:$CfgPath"

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

  if (-not (Test-Path $StartupScript)) {
    Write-Host "Startup script not found for user $UserNameForTask: $StartupScript"
  }

  # Remove any existing task
  try { Unregister-ScheduledTask -TaskName $LogonTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

  $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$StartupScript`""
  $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $UserNameForTask
  # Match manual test script: use Interactive desktop logon type
  $principal = New-ScheduledTaskPrincipal -UserId $UserNameForTask -LogonType Interactive -RunLevel Highest

  Register-ScheduledTask -TaskName $LogonTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
  Write-Host "Logon scheduled task '$LogonTaskName' created for user $UserNameForTask"
} catch {
  Write-Host "Failed to create logon scheduled task: $_"
}

# ----------------------------
# 8) Optional: Force reboot to apply auto-login
# ----------------------------
Write-Host "Rebooting to apply auto-login..."
Restart-Computer -Force

Write-Host "Setup complete: Auto-login, login trigger, CloudWatch, SSM, and App service configured."
Stop-Transcript
</powershell>