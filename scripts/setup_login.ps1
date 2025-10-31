<powershell>
$ErrorActionPreference = "Stop"
Start-Transcript -Path "C:\\ProgramData\\cloudwatch-bootstrap.log" -Append

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

$Username = "${var.windows_username}"
$PasswordPlain = "${var.windows_password}"
$Password = $PasswordPlain | ConvertTo-SecureString -AsPlainText -Force
$RegPath  = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"

if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  New-LocalUser -Name $Username -Password $Password -FullName "AutoLogin User" -Description "AutoLogin"
  Add-LocalGroupMember -Group "Administrators" -Member $Username
} else {
  Set-LocalUser -Name $Username -Password $Password
}

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
} catch {}

try {
  if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa')) {
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'Lsa' -Force | Out-Null
  }
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -PropertyType DWord -Value 0 -Force | Out-Null
  if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies')) {
      New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -Name 'Policies' -Force | Out-Null
    }
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' -Name 'System' -Force | Out-Null
  }
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DisableCAD' -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'legalnoticecaption' -PropertyType String -Value '' -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'legalnoticetext' -PropertyType String -Value '' -Force | Out-Null
} catch {}

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
  Register-ScheduledTask -Action $Action -Trigger $Trigger -TaskName $TaskName -Description "Forces auto-login" -RunLevel Highest -User "SYSTEM" -Force
} catch {}

$msiUrl  = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
$msiPath = "C:\\Windows\\Temp\\amazon-cloudwatch-agent.msi"
$retries = 5
$installSuccess = $false

for ($i=0; $i -lt $retries; $i++) {
  try {
    Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop
    $installProcess = Start-Process msiexec.exe -ArgumentList @("/i",$msiPath,"/qn","/norestart") -Wait -PassThru -NoNewWindow
    if ($installProcess.ExitCode -eq 0) {
      $installSuccess = $true
      break
    }
    if ($i -eq ($retries-1)) { throw "Install failed: $($installProcess.ExitCode)" }
  } catch {
    if ($i -eq ($retries-1)) { throw }
    Start-Sleep -Seconds 10
  }
}


$CfgDir = "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent"
$CfgPath = Join-Path $CfgDir "config.json"
try {
  $token = Get-IMDSToken
  $InstanceId = Get-IMDS "meta-data/instance-id" $token
  $InstanceName = $null
  try { $InstanceName = Get-IMDS "meta-data/tags/instance/Name" $token } catch { $InstanceName = $null }
  if (-not $InstanceName) { $InstanceName = "UnknownName" }
  $StreamPrefix = "$InstanceId/$InstanceName"
  $UserProfilePath = Join-Path "C:\Users" $Username
  $LogBasePath = Join-Path $UserProfilePath "Documents\Applications\browser-automation-launcher\logs"
  $MonitorLogPath = Join-Path $LogBasePath "monitor.log"
  $AppLogPath = Join-Path $LogBasePath "app.log"
  if (-not (Test-Path $LogBasePath)) { New-Item -ItemType Directory -Force -Path $LogBasePath | Out-Null }

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
} catch {}

if (Test-Path $CfgPath) {
  $cwCtlPath = "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1"
  if (Test-Path $cwCtlPath) {
    & $cwCtlPath -a stop | Out-Null
    & $cwCtlPath -a start -m ec2 -c "file:$CfgPath" 2>&1 | Out-Null
  }
}

$svcName = "${var.app_service_name}"
try {
  if (Get-Service -Name $svcName -ErrorAction Stop) {
    Set-Service -Name $svcName -StartupType Automatic
    Start-Service -Name $svcName -ErrorAction SilentlyContinue
  }
} catch {}

try {
  $LogonTaskName = "BrowserAutomationStartup"
  $UserNameForTask = "$Username"
  $UserProfilePath = Join-Path "C:\Users" $UserNameForTask
  $StartupScript = Join-Path $UserProfilePath "Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1"
  try { Unregister-ScheduledTask -TaskName $LogonTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$StartupScript`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserNameForTask
  $principal = New-ScheduledTaskPrincipal -UserId $UserNameForTask -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $LogonTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
} catch {}

try {
  $rdpEnabled = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -ErrorAction SilentlyContinue).fDenyTSConnections
  if ($rdpEnabled -ne 0) {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Type DWord -Value 0 -Force | Out-Null
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | Out-Null
    $rdpTcpPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    if (-not (Test-Path $rdpTcpPath)) { New-Item -Path $rdpTcpPath -Force | Out-Null }
    Set-ItemProperty -Path $rdpTcpPath -Name 'UserAuthentication' -Type DWord -Value 0 -Force | Out-Null
    $rdpService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
    if ($rdpService) {
      Set-Service -Name 'TermService' -StartupType Automatic -ErrorAction SilentlyContinue
      if ($rdpService.Status -ne 'Running') { Start-Service -Name 'TermService' -ErrorAction SilentlyContinue }
    }
  }
} catch {}


Stop-Transcript
Restart-Computer -Force
</powershell>