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
  if (-not $region) { $region = "${var.region}" }
  $ssmUrl = "https://s3.amazonaws.com/amazon-ssm-$region/latest/windows_amd64/AmazonSSMAgentSetup.exe"
  $ssmExe = "C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe"
  Invoke-WebRequest -Uri $ssmUrl -OutFile $ssmExe -UseBasicParsing
  Start-Process -FilePath $ssmExe -ArgumentList "/S" -Wait
}
try {
  Start-Service AmazonSSMAgent
  Set-Service -Name AmazonSSMAgent -StartupType Automatic
} catch { Write-Host "SSM start failed: $_" }

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
  $Username = "${var.windows_username}"
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

Stop-Transcript
</powershell>
