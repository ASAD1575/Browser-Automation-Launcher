# ==========================================================
# EC2 Clone Module — Launch from Custom AMI
# ==========================================================

resource "aws_instance" "cloned_instance" {
  count                       = var.cloned_instance_count
  ami                         = var.ami_id # custom AMI: ami-0d418d3b14bf1782f
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  iam_instance_profile        = var.iam_instance_profile # Attach IAM instance profile
  associate_public_ip_address = true
  tags = {
    Name = "${var.cloned_instance_name}-${count.index + 1}-${var.env}"
  }

# user_data = <<-EOF
# <powershell>
# $ErrorActionPreference = "Stop"
# Start-Transcript -Path "C:\\ProgramData\\cloudwatch-bootstrap.log" -Append

# # ----------------------------
# # 0) Helpers
# # ----------------------------
# function Get-IMDSToken {
#   try {
#     $res = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 5
#     return $res
#   } catch { return $null }
# }

# function Get-IMDS($path, $token) {
#   $headers = @{}
#   if ($token) { $headers["X-aws-ec2-metadata-token"] = $token }
#   return Invoke-RestMethod -Uri "http://169.254.169.254/latest/$path" -Headers $headers -TimeoutSec 5
# }

# # ----------------------------
# # 1) Ensure SSM Agent present & running
# # ----------------------------
# if (-not (Get-Service AmazonSSMAgent -ErrorAction SilentlyContinue)) {
#   Write-Host "Installing SSM Agent..."
#   $region = (Get-IMDS "meta-data/placement/region" (Get-IMDSToken))
#   if (-not $region) { $region = "${var.region}" } # fallback to TF var
#   $ssmUrl = "https://s3.amazonaws.com/amazon-ssm-$region/latest/windows_amd64/AmazonSSMAgentSetup.exe"
#   $ssmExe = "C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe"
#   Invoke-WebRequest -Uri $ssmUrl -OutFile $ssmExe -UseBasicParsing
#   Start-Process -FilePath $ssmExe -ArgumentList "/S" -Wait
# }
# try {
#   Start-Service AmazonSSMAgent
#   Set-Service -Name AmazonSSMAgent -StartupType Automatic
# } catch { Write-Host "SSM start failed: $_" }

# # ----------------------------
# # 2) Install CloudWatch Agent via MSI (with retries)
# # ----------------------------
# $msiUrl  = "https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi"
# $msiPath = "C:\\Windows\\Temp\\amazon-cloudwatch-agent.msi"
# $retries = 5
# for ($i=0; $i -lt $retries; $i++) {
#   try {
#     Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
#     Start-Process msiexec.exe -ArgumentList @("/i",$msiPath,"/qn","/norestart") -Wait
#     break
#   } catch {
#     Start-Sleep -Seconds 10
#     if ($i -eq ($retries-1)) { throw }
#   }
# }

# # ----------------------------
# # 3) Build CW Agent config with {InstanceID}/{InstanceName}
# # ----------------------------
# $token = Get-IMDSToken
# $InstanceId = Get-IMDS "meta-data/instance-id" $token
# $InstanceName = $null
# try { $InstanceName = Get-IMDS "meta-data/tags/instance/Name" $token } catch { $InstanceName = $null }
# if (-not $InstanceName) { $InstanceName = "UnknownName" }
# $StreamPrefix = "$InstanceId/$InstanceName"

# $CwConfig = @{
#   logs = @{
#     logs_collected = @{
#       files = @{
#         collect_list = @(
#           @{
#             file_path       = "C:\\Users\\Administrator\\Documents\\applications\\browser-automation-launcher\\logs\\monitor.log"
#             log_group_name  = "${var.cw_log_group_name}"
#             log_stream_name = "$StreamPrefix/monitor.log"
#             timestamp_format= "%Y-%m-%d %H:%M:%S"
#           },
#           @{
#             file_path       = "C:\\Users\\Administrator\\Documents\\applications\\browser-automation-launcher\\logs\\app.log"
#             log_group_name  = "${var.cw_log_group_name}"
#             log_stream_name = "$StreamPrefix/app.log"
#             timestamp_format= "%Y-%m-%d %H:%M:%S"
#           }
#         )
#       }
#       windows_events = @{
#         collect_list = @(
#           @{
#             event_levels    = @("ERROR","WARNING")
#             event_format    = "xml"
#             log_group_name  = "${var.cw_log_group_name}"
#             log_stream_name = "$StreamPrefix/EventLog/System"
#             event_name      = "System"
#           },
#           @{
#             event_levels    = @("ERROR","WARNING")
#             event_format    = "xml"
#             log_group_name  = "${var.cw_log_group_name}"
#             log_stream_name = "$StreamPrefix/EventLog/Application"
#             event_name      = "Application"
#           }
#         )
#       }
#     }
#   }
#   agent = @{
#     metrics_collection_interval = 60
#     run_as_user = "NT AUTHORITY\\SYSTEM"
#     debug = $false
#   }
# }

# $CfgDir = "C:\\ProgramData\\Amazon\\AmazonCloudWatchAgent"
# $CfgPath = Join-Path $CfgDir "config.json"
# New-Item -ItemType Directory -Force -Path $CfgDir | Out-Null
# # Use ASCII/UTF8 without BOM to be safe
# $CwConfig | ConvertTo-Json -Depth 10 | Out-File -FilePath $CfgPath -Encoding ascii -Force

# # ----------------------------
# # 4) Start CloudWatch Agent with local config
# # ----------------------------
# & "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1" -a stop | Out-Null
# & "C:\\Program Files\\Amazon\\AmazonCloudWatchAgent\\amazon-cloudwatch-agent-ctl.ps1" -a start -m ec2 -c "file:$CfgPath"

# # ----------------------------
# # 5) Ensure your app service is Auto + Started
# # ----------------------------
# $svcName = "${var.app_service_name}"   # e.g., BrowserAutomationLauncher
# try {
#   if (Get-Service -Name $svcName -ErrorAction Stop) {
#     Set-Service -Name $svcName -StartupType Automatic
#     Start-Service -Name $svcName -ErrorAction SilentlyContinue
#   }
# } catch {
#   Write-Host "Service '$svcName' not found: $_"
# }

# # ----------------------------
# # 6) Any bootstrap dirs
# # ----------------------------
# New-Item -ItemType Directory -Force -Path "C:\\app" | Out-Null

# Stop-Transcript
# </powershell>
# EOF

  # ==============================
  # Metadata & Security Hardening
  # ==============================

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2
    http_put_response_hop_limit = 1
    instance_metadata_tags = "enabled"
  }

  # ==============================
  # Root Block Device
  # ==============================

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 30 # Adjust as needed
    delete_on_termination = true

    # optional: define KMS key if using customer-managed encryption
    # kms_key_id = aws_kms_key.ec2_encryption.arn
  }

  # ==============================
  # Lifecycle Management
  # ==============================
  lifecycle {
    create_before_destroy = true
  }
}
