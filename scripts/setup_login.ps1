<powershell>
# ----------------------------
# 1) Ensure SSM Agent is Installed & Running
# ----------------------------
Write-Host "Checking SSM Agent..."
if (-not (Get-Service AmazonSSMAgent -ErrorAction SilentlyContinue)) {
  Write-Host "Installing SSM Agent..."

  # Get region from IMDSv2
  $token = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 5
  $region = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" -Headers @{ "X-aws-ec2-metadata-token" = $token } -TimeoutSec 5

  if (-not $region) { $region = "us-east-1" } # fallback region

  $ssmUrl = "https://s3.amazonaws.com/amazon-ssm-$region/latest/windows_amd64/AmazonSSMAgentSetup.exe"
  $ssmExe = "C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe"
  Invoke-WebRequest -Uri $ssmUrl -OutFile $ssmExe -UseBasicParsing
  Start-Process -FilePath $ssmExe -ArgumentList "/S" -Wait
}

try {
  Start-Service AmazonSSMAgent
  Set-Service -Name AmazonSSMAgent -StartupType Automatic
  Write-Host "SSM Agent is installed and running."
} catch {
  Write-Host "Failed to start SSM Agent: $_"
}

# ----------------------------
# 2) Create User and Enable Auto-Login
# ----------------------------
$Username = "${var.windows_username}"
$Password = "${var.windows_password}" | ConvertTo-SecureString -AsPlainText -Force
$RegPath  = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"

Write-Host "Ensuring local user '$Username' exists..."
if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  New-LocalUser -Name $Username -Password $Password -FullName "Ticket Boat User" -Description "Auto-login user"
  Add-LocalGroupMember -Group "Administrators" -Member $Username
} else {
  Write-Host "User already exists. Updating password..."
  Set-LocalUser -Name $Username -Password $Password
}

Write-Host "Configuring Windows Auto-Login..."
Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon" -Value "1" -Type String
Set-ItemProperty -Path $RegPath -Name "DefaultUsername" -Value $Username -Type String
Set-ItemProperty -Path $RegPath -Name "DefaultPassword" -Value "${var.windows_password}" -Type String
Set-ItemProperty -Path $RegPath -Name "DefaultDomainName" -Value $env:COMPUTERNAME -Type String

# ----------------------------
# 3) Install CloudWatch Agent
# ----------------------------
Write-Host "Installing CloudWatch Agent..."
$CwMsi = "C:\\Windows\\Temp\\amazon-cloudwatch-agent.msi"
Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi" -OutFile $CwMsi -UseBasicParsing
Start-Process msiexec.exe -ArgumentList "/i $CwMsi /qn /norestart" -Wait

# ----------------------------
# 4) Build CloudWatch Config
# ----------------------------
$cwLogGroup = "/prod/Browser-Automation-Launcher/app"

Write-Host "Creating CloudWatch Agent configuration..."
$CWConfig = @"
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "C:\\\\Users\\\\Administrator\\\\Documents\\\\applications\\\\browser-automation-launcher\\\\logs\\\\monitor.log",
            "log_group_name": "$cwLogGroup",
            "log_stream_name": "monitor.log",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          },
          {
            "file_path": "C:\\\\Users\\\\Administrator\\\\Documents\\\\applications\\\\browser-automation-launcher\\\\logs\\\\app.log",
            "log_group_name": "$cwLogGroup",
            "log_stream_name": "app.log",
            "timestamp_format": "%Y-%m-%d %H:%M:%S"
          }
        ]
      },
      "windows_events": {
        "collect_list": [
          {
            "event_levels": ["ERROR","WARNING"],
            "event_format": "xml",
            "log_group_name": "$cwLogGroup",
            "log_stream_name": "EventLog/System",
            "event_name": "System"
          },
          {
            "event_levels": ["ERROR","WARNING"],
            "event_format": "xml",
            "log_group_name": "$cwLogGroup",
            "log_stream_name": "EventLog/Application",
            "event_name": "Application"
          }
        ]
      }
    }
  },
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "NT AUTHORITY\\\\SYSTEM",
    "debug": false
  }
}
"@

$CWPath = "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent"
New-Item -ItemType Directory -Force -Path $CWPath | Out-Null
$ConfigFile = "$CWPath\\config.json"
$CWConfig | Out-File -Encoding ASCII -FilePath $ConfigFile -Force

# ----------------------------
# 5) Start CloudWatch Agent
# ----------------------------
Write-Host "Starting CloudWatch Agent..."
& "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1" -a stop
& "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1" -a start -m ec2 -c file:$ConfigFile

Write-Host "CloudWatch Agent installed and running."
Write-Host "Auto-login configured for user '$Username'."
Write-Host "SSM Agent active and connected."
</powershell>
