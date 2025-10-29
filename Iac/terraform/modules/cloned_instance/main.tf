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

  user_data = <<-EOF
<powershell>
# ----------------------------
# 1) Ensure SSM Agent is Installed & Running
# ----------------------------
if (-not (Get-Service AmazonSSMAgent -ErrorAction SilentlyContinue)) {
  Write-Host "Installing SSM Agent..."
  
  # Get region from IMDSv2
  $token = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"} -TimeoutSec 5
  $region = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" -Headers @{ "X-aws-ec2-metadata-token" = $token } -TimeoutSec 5
  
  # If no region is fetched from IMDS, fallback to a Terraform variable or default region
  if (-not $region) { $region = "us-east-1" } # Replace with your fallback region if needed

  # Download and install SSM agent
  $ssmUrl = "https://s3.amazonaws.com/amazon-ssm-$region/latest/windows_amd64/AmazonSSMAgentSetup.exe"
  $ssmExe = "C:\\Windows\\Temp\\AmazonSSMAgentSetup.exe"
  Invoke-WebRequest -Uri $ssmUrl -OutFile $ssmExe -UseBasicParsing
  Start-Process -FilePath $ssmExe -ArgumentList "/S" -Wait
}

# Start the AmazonSSMAgent service and ensure it starts automatically on boot
try {
  Start-Service AmazonSSMAgent
  Set-Service -Name AmazonSSMAgent -StartupType Automatic
  Write-Host "SSM Agent is installed and running."
} catch {
  Write-Host "Failed to start SSM Agent: $_"
}

# ----------------------------
# 2) Enable WinRM for Ansible connectivity
# ----------------------------
Write-Host "Enabling WinRM for remote management..."

# Enable PowerShell remoting
Enable-PSRemoting -Force

# Configure WinRM to allow unencrypted traffic (for basic auth)
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true

# Configure WinRM to allow basic authentication
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $true

# Set WinRM service to start automatically
Set-Service WinRM -StartupType Automatic

# Start WinRM service
Start-Service WinRM

# Configure firewall to allow WinRM
netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow

# Allow WinRM through Windows Firewall
Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -Enabled True

# Test WinRM connectivity
try {
  $winrmStatus = Get-Service WinRM
  if ($winrmStatus.Status -eq "Running") {
    Write-Host "WinRM is enabled and running."
  } else {
    Write-Host "WinRM service is not running."
  }
} catch {
  Write-Host "Failed to check WinRM status: $_"
}

</powershell>
EOF

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
