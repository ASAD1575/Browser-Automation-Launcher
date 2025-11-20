# Requires PowerShell 3.0 or higher
# -----------------------------------------------------------------------------
# AWS Systems Manager (SSM) Agent Installation Script for Windows
# Uses the user-specified URL format for download.
# -----------------------------------------------------------------------------

# =============================================================================
# Configuration
# =============================================================================

# NOTE: CRITICAL! REPLACE 'us-east-1' with the AWS Region where your EC2 instance is
# deployed (e.g., 'eu-west-1', 'ap-southeast-2').
$Region = "us-east-1"

# The path where the installer will be downloaded and run from
$DownloadPath = "C:\Temp\SSM"

# **UPDATED URL:** Using the structure requested by the user.
# This URL is constructed using the specified region.
$InstallerUrl = "https://s3.amazonaws.com/amazon-ssm-$Region/latest/windows_amd64/AmazonSSMAgentSetup.exe"

# =============================================================================
# Pre-checks and Setup
# =============================================================================
Write-Host "Starting SSM Agent Installation for region: $Region"
Write-Host "Download URL: $InstallerUrl"

# Check if the directory exists, and create it if not
if (-not (Test-Path -Path $DownloadPath)) {
    Write-Host "Creating download directory: $DownloadPath"
    try {
        New-Item -Path $DownloadPath -Type Directory -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Failed to create directory $DownloadPath. $($_.Exception.Message)"
        exit 1
    }
}

$InstallerDestination = Join-Path $DownloadPath "AmazonSSMAgentSetup.exe"

# =============================================================================
# Download Installer
# =============================================================================
Write-Host "Downloading SSM Agent installer..."

try {
    # Use Invoke-WebRequest to download the file
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $InstallerDestination -ErrorAction Stop
    Write-Host "Download successful. File saved to $InstallerDestination"
}
catch {
    Write-Error "Failed to download SSM Agent installer."
    Write-Error "Error: $($_.Exception.Message)"
    Write-Error "Please verify the \$Region setting and network connectivity to $InstallerUrl."
    exit 1
}

# =============================================================================
# Install SSM Agent
# =============================================================================
Write-Host "Starting installation..."

# Arguments: /S for silent install, /REGION to specify the AWS region
$InstallArgs = "/S /REGION=$Region"

try {
    # Start the installer process and wait for completion
    $Process = Start-Process -FilePath $InstallerDestination -ArgumentList $InstallArgs -Wait -PassThru -ErrorAction Stop

    # Check the exit code of the installation process
    if ($Process.ExitCode -eq 0) {
        Write-Host "SSM Agent installation completed successfully."
        
        # Verify and start the service
        $ServiceName = "AmazonSSMAgent"
        if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
            Write-Host "$ServiceName service is present. Ensuring it is started..."
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-Host "$ServiceName service successfully started."
        }
    }
    else {
        Write-Error "SSM Agent installation failed with exit code $($Process.ExitCode). Consult SSM Agent logs for details."
        exit 1
    }
}
catch {
    Write-Error "An unhandled error occurred during the installation process. $($_.Exception.Message)"
    exit 1
}

Write-Host "SSM Agent Script Finished."
