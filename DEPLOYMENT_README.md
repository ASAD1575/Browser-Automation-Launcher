# Browser Automation Launcher - Complete Deployment Guide

This comprehensive guide covers all prerequisites, setup steps, and execution instructions for deploying the Browser Automation Launcher application using Terraform and GitHub Actions workflows.

---

## 📋 Table of Contents

1. [Application Prerequisites](#application-prerequisites)
2. [Terraform Prerequisites & Setup](#terraform-prerequisites--setup)
3. [GitHub Workflow Prerequisites & Setup](#github-workflow-prerequisites--setup)
4. [Running Terraform Locally](#running-terraform-locally)
5. [Running GitHub Workflows](#running-github-workflows)
6. [Application Configuration](#application-configuration)
7. [Troubleshooting](#troubleshooting)
8. [Security Considerations](#security-considerations)

---

## Application Prerequisites

### Required Software (Windows EC2 Instance)

The application runs on Windows Server 2022 EC2 instances. The following software must be installed:

#### 1. **Python 3.12**
- **Download**: [Python 3.12.x](https://www.python.org/downloads/)
- **Installation**: Use the Windows installer with "Add Python to PATH" enabled
- **Verification**:
  ```powershell
  python --version
  # Should output: Python 3.12.x
  ```

#### 2. **Poetry** (Python Package Manager)
- **Installation**: Will be auto-installed by `simple_startup.ps1` if missing
- **Manual Installation**:
  ```powershell
  (Invoke-WebRequest -Uri https://install.python-poetry.org -UseBasicParsing).Content | python -
  ```
- **Verification**:
  ```powershell
  poetry --version
  ```

#### 3. **Google Chrome**
- **Download**: [Chrome Enterprise](https://www.google.com/chrome/business/)
- **Installation**: Standard Windows installer
- **Default Path**: `C:\Program Files\Google\Chrome\Application\chrome.exe`
- **Verification**:
  ```powershell
  Test-Path "C:\Program Files\Google\Chrome\Application\chrome.exe"
  ```

#### 4. **Git** (for cloning repository)
- **Download**: [Git for Windows](https://git-scm.com/download/win)
- **Verification**:
  ```powershell
  git --version
  ```

#### 5. **AWS SSM Agent** (Pre-installed on most AMIs, verified by user data)
- **Purpose**: Enables remote management via AWS Systems Manager
- **Auto-installation**: Handled by `setup_login.ps1` user data script

### Python Dependencies

The application uses Poetry for dependency management. Required packages are defined in `pyproject.toml`:

```toml
- Python >= 3.12
- boto3 >= 1.35.0
- aioboto3 >= 13.0.0
- aiohttp >= 3.9.0
- pydantic >= 2.9.0
- psutil >= 6.0.0
- python-dotenv >= 1.1.1
- requests >= 2.32.0
```

**Installation**: Automatically handled by `simple_startup.ps1` via `poetry install`

---

## Terraform Prerequisites & Setup

### Required Software (Local Machine)

#### 1. **Terraform >= 1.9.8**
- **Download**: [Terraform Downloads](https://www.terraform.io/downloads)
- **Installation**:
  ```bash
  # Linux/Mac
  wget https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
  unzip terraform_1.9.8_linux_amd64.zip
  sudo mv terraform /usr/local/bin/
  
  # Verify
  terraform --version
  ```

#### 2. **AWS CLI >= 2.0**
- **Download**: [AWS CLI](https://aws.amazon.com/cli/)
- **Installation**:
  ```bash
  # Linux
  curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip awscliv2.zip
  sudo ./aws/install
  
  # Verify
  aws --version
  ```

#### 3. **Docker** (Required by deploy script)
- **Download**: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- **Verification**:
  ```bash
  docker info
  ```

#### 4. **jq** (JSON processor, for scripts)
- **Linux**:
  ```bash
  sudo apt-get install jq  # Debian/Ubuntu
  sudo yum install jq       # RHEL/CentOS
  ```

### AWS Prerequisites

Before running Terraform, ensure the following AWS resources exist:

#### 1. **VPC**
- **Requirement**: Default VPC or existing VPC
- **Verification**:
  ```bash
  aws ec2 describe-vpcs --query 'Vpcs[?IsDefault==`true`].[VpcId,CidrBlock]' --output table
  ```

#### 2. **Security Group**
- **Requirement**: Existing security group (name specified in variables)
- **Permissions Required**:
  - **Inbound**:
    - Port 3389 (RDP) - Optional, for remote access
    - Port 9222-9322 (Chrome DevTools) - Optional, for browser debugging
    - All traffic from Security Group itself (for inter-instance communication)
  - **Outbound**: All traffic (for SQS, CloudWatch, SSM)
- **Verification**:
  ```bash
  aws ec2 describe-security-groups --group-names "your-security-group-name"
  ```

#### 3. **IAM Role**
- **Requirement**: Existing IAM role with instance profile
- **Required Policies**:
  - `AmazonSSMManagedInstanceCore` (for SSM agent)
  - `CloudWatchAgentServerPolicy` (for CloudWatch agent)
  - SQS permissions (if using SQS mode):
    ```json
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:SendMessage"
      ],
      "Resource": "arn:aws:sqs:*:*:*"
    }
    ```
- **Verification**:
  ```bash
  aws iam get-role --role-name "your-iam-role-name"
  aws iam list-attached-role-policies --role-name "your-iam-role-name"
  ```

#### 4. **EC2 Key Pair**
- **Requirement**: Existing key pair for EC2 instances (optional, for RDP access)
- **Creation**:
  ```bash
  aws ec2 create-key-pair --key-name "your-key-pair-name" --query 'KeyMaterial' --output text > key.pem
  chmod 400 key.pem
  ```
- **Verification**:
  ```bash
  aws ec2 describe-key-pairs --key-names "your-key-pair-name"
  ```

#### 5. **S3 Bucket for Terraform State** (Optional but Recommended)
- **Requirement**: S3 bucket for storing Terraform state
- **Creation**:
  ```bash
  aws s3 mb s3://your-terraform-state-bucket
  aws s3api put-bucket-versioning --bucket your-terraform-state-bucket --versioning-configuration Status=Enabled
  ```
- **Note**: Currently commented out in `main.tf` - state is stored locally

#### 6. **DynamoDB Table for State Locking** (Optional but Recommended)
- **Requirement**: DynamoDB table for Terraform state locking
- **Creation**:
  ```bash
  aws dynamodb create-table \
    --table-name terraform-state-lock-table \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  ```

### AWS Credentials Configuration

Configure AWS credentials using one of these methods:

#### Method 1: AWS CLI Configuration
```bash
aws configure
# Enter:
# - AWS Access Key ID
# - AWS Secret Access Key
# - Default region (e.g., us-east-1)
# - Default output format (json)
```

#### Method 2: Environment Variables
```bash
export AWS_ACCESS_KEY_ID="your-access-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-access-key"
export AWS_DEFAULT_REGION="us-east-1"
```

#### Method 3: AWS Profile
```bash
aws configure --profile your-profile-name
export AWS_PROFILE=your-profile-name
```

### Terraform Environment Files

Create environment-specific configuration files in the project root:

#### 1. **`.env.global`** (Global/Shared Variables)
```bash
# AWS Region
export AWS_DEFAULT_REGION="us-east-1"

# Terraform State Bucket
export TERRAFORM_STATE_BUCKET="your-terraform-state-bucket"

# Application Identifier (without environment suffix)
export APP_IDENT_WITHOUT_ENV="Browser-Automation-Launcher"

# CodeArtifact Token (if using private package registry)
export CODEARTIFACT_TOKEN=""
```

#### 2. **`.env.dev.terraform`** (Development Environment)
```bash
# Instance Configuration
export CLONED_INSTANCE_COUNT=1
export CLONED_INSTANCE_TYPE="t3.micro"
export CLONE_INSTANCE_NAME="Browser-Automation-Launcher"
export ENVIRONMENT="dev"

# AMI Configuration
export CUSTOM_AMI_ID="ami-028dc1123403bd543"  # Windows Server 2022 AMI for your region

# AWS Resources
export EC2_KEY_PAIR="your-key-pair-name"
export EC2_SECURITY_GROUP="your-security-group-name"
export EXISTING_IAM_ROLE_NAME="your-iam-role-name"
```

#### 3. **`.env.staging.terraform`** (Staging Environment)
```bash
# Same structure as dev, with staging-specific values
export CLONED_INSTANCE_COUNT=2
export CLONED_INSTANCE_TYPE="t3.small"
export CLONE_INSTANCE_NAME="Browser-Automation-Launcher"
export ENVIRONMENT="staging"
export CUSTOM_AMI_ID="ami-028dc1123403bd543"
export EC2_KEY_PAIR="your-key-pair-name"
export EC2_SECURITY_GROUP="your-security-group-name"
export EXISTING_IAM_ROLE_NAME="your-iam-role-name"
```

#### 4. **`.env.prod.terraform`** (Production Environment)
```bash
# Same structure, with production-specific values
export CLONED_INSTANCE_COUNT=5
export CLONED_INSTANCE_TYPE="t3.medium"
export CLONE_INSTANCE_NAME="Browser-Automation-Launcher"
export ENVIRONMENT="prod"
export CUSTOM_AMI_ID="ami-028dc1123403bd543"
export EC2_KEY_PAIR="your-key-pair-name"
export EC2_SECURITY_GROUP="your-security-group-name"
export EXISTING_IAM_ROLE_NAME="your-iam-role-name"
```

**Note**: These files should NOT be committed to Git. Add them to `.gitignore`.

---

## GitHub Workflow Prerequisites & Setup

### Repository Configuration

#### 1. **GitHub Repository Variables**

Navigate to: **Settings → Secrets and variables → Actions → Variables**

Add the following **Variables** (not secrets):

| Variable Name | Description | Example |
|--------------|-------------|---------|
| `CLONE_INSTANCE_NAME` | Base name for EC2 instances | `Browser-Automation-Launcher` |
| `CLONED_INSTANCE_TYPE` | EC2 instance type | `t3.micro` |
| `CUSTOM_AMI_ID` | Windows Server 2022 AMI ID | `ami-028dc1123403bd543` |
| `CLONED_INSTANCE_COUNT` | Number of instances to create | `1` |
| `ENVIRONMENT` | Environment tag | `dev` |
| `EC2_KEY_PAIR` | EC2 key pair name | `your-key-pair-name` |
| `EC2_SECURITY_GROUP` | Security group name | `your-security-group-name` |
| `EC2_IAM_ROLE` | IAM role name | `your-iam-role-name` |
| `CODEARTIFACT_TOKEN` | CodeArtifact token (if using) | (leave empty if not using) |
| `TF_STATE_BUCKET` | S3 bucket for Terraform state | `your-terraform-state-bucket` |
| `AWS_DEFAULT_REGION` | AWS region | `us-east-1` |
| `APP_IDENT_WITHOUT_ENV` | Application identifier | `Browser-Automation-Launcher` |

**How to Add**:
1. Go to your GitHub repository
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **Variables** tab
4. Click **New repository variable**
5. Enter name and value
6. Click **Add variable**

#### 2. **GitHub Repository Secrets**

Navigate to: **Settings → Secrets and variables → Actions → Secrets**

Add the following **Secrets**:

| Secret Name | Description | Example |
|------------|-------------|---------|
| `WINDOWS_USERNAME` | Windows user for autologon | `Administrator` |
| `WINDOWS_PASSWORD` | Windows user password | `YourSecurePassword123!` |

**How to Add**:
1. Go to your GitHub repository
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **Secrets** tab
4. Click **New repository secret**
5. Enter name and value (value is masked after creation)
6. Click **Add secret**

#### 3. **AWS IAM Role for GitHub Actions**

The workflow uses OIDC (OpenID Connect) for AWS authentication. Create an IAM role that GitHub Actions can assume:

**Step 1: Create IAM Identity Provider**
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

**Step 2: Create IAM Role with Trust Policy**

Create a file `github-actions-trust-policy.json`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:*"
        }
      }
    }
  ]
}
```

**Step 3: Create IAM Role**
```bash
aws iam create-role \
  --role-name GitHubActionsTerraformRole \
  --assume-role-policy-document file://github-actions-trust-policy.json
```

**Step 4: Attach Required Policies**

Attach policies that allow the role to:
- Manage EC2 instances
- Manage IAM roles (read-only)
- Manage Security Groups (read-only)
- Manage VPC (read-only)
- Manage S3 buckets (for Terraform state)
- Manage DynamoDB (for state locking)
- Manage CloudWatch
- Manage SSM
- Manage SQS (if using)

Example:
```bash
aws iam attach-role-policy \
  --role-name GitHubActionsTerraformRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

aws iam attach-role-policy \
  --role-name GitHubActionsTerraformRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```

**Update the workflow file** (`.github/workflows/github_flow.yml`) with your account ID and role ARN:
```yaml
role-to-assume: arn:aws:iam::YOUR_ACCOUNT_ID:role/GitHubActionsTerraformRole
```

---

## Running Terraform Locally

### Step 1: Navigate to Project Directory
```bash
cd /path/to/Browser-Automation-Launcher
```

### Step 2: Source Environment Variables
```bash
# Source global variables
source .env.global

# Source environment-specific variables
source .env.dev.terraform  # or .env.staging.terraform or .env.prod.terraform
```

### Step 3: Verify AWS Credentials
```bash
aws sts get-caller-identity
# Should output your AWS account and user information
```

### Step 4: Run Deployment Script

#### Create Infrastructure
```bash
ENVIRONMENT=dev ./deploy.sh
```

#### Destroy Infrastructure
```bash
ENVIRONMENT=dev ./deploy.sh -d
```

### Step 5: Manual Terraform Commands (Alternative)

If you prefer to run Terraform commands directly:

```bash
cd Iac/terraform

# Initialize Terraform
terraform init

# Generate backend.tf (if using S3 backend)
# Edit backend.tf with your S3 bucket details

# Plan changes
terraform plan -out=tfplan

# Review plan
terraform show tfplan

# Apply changes
terraform apply tfplan

# Destroy resources
terraform destroy
```

### Step 6: Check Deployment Status

After deployment, check Terraform outputs:
```bash
cd Iac/terraform
terraform output
```

Example output:
```
cloned_instance_ids = [
  "i-0123456789abcdef0",
]
cloned_instance_public_ips = [
  "54.123.45.67",
]
```

### Step 7: Connect to Instances

#### Via AWS SSM Session Manager (Recommended)
```bash
# Get instance ID from Terraform output
INSTANCE_ID=$(terraform output -json | jq -r '.cloned_instance_ids.value[0]')

# Start SSM session
aws ssm start-session --target $INSTANCE_ID
```

#### Via RDP (if configured)
```bash
# Get public IP
PUBLIC_IP=$(terraform output -json | jq -r '.cloned_instance_public_ips.value[0]')

# Connect via RDP (requires key pair and password)
# Use your RDP client: rdp://$PUBLIC_IP
```

---

## Running GitHub Workflows

### Workflow Triggers

The GitHub workflow (`.github/workflows/github_flow.yml`) supports multiple triggers:

#### 1. **Automatic Deployment**
- **Dev**: Push to `main` branch
- **Staging**: Push to `staging` branch OR merge PR to `staging`
- **Production**: Create tag starting with `v*` (e.g., `v1.0.0`)

#### 2. **Manual Deployment** (Workflow Dispatch)

1. Go to your GitHub repository
2. Click **Actions** tab
3. Select **GitHub Flow Deployment** workflow
4. Click **Run workflow**
5. Select:
   - **Environment**: `dev`, `staging`, or `prod`
   - **Action**: `apply` or `destroy`
   - **Confirm**: Type `DESTROY` if destroying (only for destroy action)
6. Click **Run workflow**

### Workflow Jobs

#### Job 1: Deploy Infrastructure
- **Purpose**: Create/update EC2 instances using Terraform
- **Steps**:
  1. Checkout code
  2. Configure AWS credentials (OIDC)
  3. Install Terraform
  4. Run `deploy.sh` with environment variables
  5. Capture Terraform outputs
  6. Upload outputs as artifact

#### Job 2: Check Instance Readiness
- **Purpose**: Wait for instances to be fully initialized and SSM-ready
- **Steps**:
  1. Download Terraform outputs artifact
  2. Configure AWS credentials
  3. Install AWS Session Manager Plugin
  4. Run `instance_readiness_checker.sh`
  5. Wait for:
     - EC2 state: `running`
     - Public IP assigned
     - System status: `ok`
     - Instance status: `ok`
     - SSM ping status: `Online`

### Monitoring Workflow Execution

1. Go to **Actions** tab in GitHub repository
2. Click on the workflow run
3. View logs for each job and step
4. Check for errors or warnings

### Common Workflow Issues

#### Issue: "AWS credentials not configured"
- **Solution**: Verify IAM role exists and trust policy allows your repository

#### Issue: "Terraform state locked"
- **Solution**: Check if another workflow is running, or manually unlock:
  ```bash
  terraform force-unlock LOCK_ID
  ```

#### Issue: "Instance readiness timeout"
- **Solution**: Check SSM Agent installation and IAM role permissions

---

## Application Configuration

### Environment Variables

The application reads configuration from environment variables. Create a `.env` file in the project root:

```bash
# Application Mode
ENV=dev  # local, dev, staging, production

# SQS Configuration
SQS_REQUEST_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/123456789012/your-queue-name
SQS_RESPONSE_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/123456789012/your-response-queue-name

# AWS Configuration
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=your-access-key  # Optional if using IAM role
AWS_SECRET_ACCESS_KEY=your-secret-key  # Optional if using IAM role

# Capacity Management
MAX_BROWSER_INSTANCES=5
CHROME_PORT_START=9222
CHROME_PORT_END=9322

# Session TTL
DEFAULT_TTL_MINUTES=30
HARD_TTL_MINUTES=120
IDLE_TIMEOUT_SECONDS=60
BROWSER_TIMEOUT=60000

# Chrome Launcher
USE_CUSTOM_CHROME_LAUNCHER=true
CHROME_LAUNCHER_CMD=C:\Chrome-RDP\launch_chrome_port.cmd

# Profile Management
PROFILE_REUSE_ENABLED=true
PROFILE_MAX_AGE_HOURS=24
PROFILE_CLEANUP_INTERVAL_SECONDS=3600

# Logging
LOG_LEVEL=INFO
LOG_FILE=logs/browser_launcher.log
```

**Note**: On EC2 instances, these are set via user data or scheduled task environment variables.

### Application Startup

The application starts automatically via Windows Scheduled Task:

1. **Autologon**: User logs in automatically on boot
2. **Scheduled Task**: `BrowserAutomationStartup` triggers on logon
3. **Startup Script**: `simple_startup.ps1` runs:
   - Checks Python/Poetry installation
   - Installs dependencies via Poetry
   - Starts application via `poetry run python -m src.main`
   - Monitors process for crashes (auto-restart)

### Manual Application Start

To start the application manually (via SSM):

```powershell
# Navigate to project directory
cd C:\Users\Administrator\Documents\Applications\browser-automation-launcher

# Run startup script
powershell -ExecutionPolicy Bypass -File .\scripts\simple_startup.ps1
```

### Application Logs

Logs are located in:
```
C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\
```

- `monitor.log` - Application status and monitoring
- `app.log` - Application logs
- `app-stdout.log` - Standard output (rotated daily)
- `app-stderr.log` - Error output (rotated daily)
- `crash.log` - Crash information

View logs via SSM:
```powershell
Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 50
```

---

## Troubleshooting

### Terraform Issues

#### Issue: "Security group not found"
```bash
# Verify security group exists
aws ec2 describe-security-groups --group-names "your-security-group-name"

# Check if name matches exactly (case-sensitive)
```

#### Issue: "IAM role not found"
```bash
# Verify IAM role exists
aws iam get-role --role-name "your-iam-role-name"

# Check instance profile is attached
aws iam get-instance-profile --instance-profile-name "your-instance-profile-name"
```

#### Issue: "AMI not found in region"
```bash
# Find AMI ID for your region
aws ec2 describe-images \
  --owners amazon \
  --filters "Name=name,Values=Windows_Server-2022-English-Full-Base-*" \
  --query 'Images[*].[ImageId,Name]' \
  --output table
```

### GitHub Workflow Issues

#### Issue: "Permission denied for GitHub Actions"
- **Solution**: Check IAM role trust policy allows your repository
- **Verify**:
  ```bash
  aws iam get-role --role-name GitHubActionsTerraformRole --query 'AssumeRolePolicyDocument'
  ```

#### Issue: "Terraform state file not found"
- **Solution**: Check S3 bucket exists and is accessible
- **Verify**:
  ```bash
  aws s3 ls s3://your-terraform-state-bucket/
  ```

### Application Issues

#### Issue: "SSM Agent not available"
- **Solution**: Install SSM Agent manually:
  ```powershell
  # Download and install SSM Agent
  Invoke-WebRequest -Uri "https://s3.amazonaws.com/amazon-ssm-us-east-1/latest/windows_amd64/AmazonSSMAgentSetup.exe" -OutFile "$env:TEMP\AmazonSSMAgentSetup.exe"
  Start-Process -FilePath "$env:TEMP\AmazonSSMAgentSetup.exe" -ArgumentList "/S" -Wait
  Start-Service AmazonSSMAgent
  ```

#### Issue: "Chrome not launching in GUI mode"
- **Solution**: Verify autologon is configured:
  ```powershell
  # Check autologon registry
  Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" | Select AutoAdminLogon, DefaultUsername, DefaultPassword

  # Verify user is logged in
  query user
  ```

#### Issue: "Application not starting after reboot"
- **Solution**: Check scheduled task:
  ```powershell
  # Verify task exists
  schtasks /query /tn "BrowserAutomationStartup"

  # Check task status
  Get-ScheduledTaskInfo -TaskName "BrowserAutomationStartup"

  # Manually trigger task
  schtasks /run /tn "BrowserAutomationStartup"
  ```

---

## Security Considerations

### IAM Roles and Policies

- **Principle of Least Privilege**: Grant only necessary permissions
- **Instance Profile**: Use IAM roles, not access keys
- **SSM Access**: Use SSM Session Manager instead of SSH/RDP when possible

### Network Security

- **Security Groups**: Restrict inbound traffic to necessary ports only
- **RDP Access**: Use Security Group restrictions (source IP whitelist)
- **Chrome DevTools Ports**: Restrict access to known IPs or Security Groups

### Secrets Management

- **Windows Passwords**: Store in GitHub Secrets, not in code or Terraform variables
- **AWS Credentials**: Use IAM roles for GitHub Actions (OIDC), not access keys
- **Environment Files**: Do not commit `.env*` files to Git

### Encryption

- **EBS Volumes**: Enable encryption at rest
- **Data in Transit**: Use HTTPS/TLS for all API calls
- **CloudWatch Logs**: Enable log encryption (KMS)

### Monitoring and Auditing

- **CloudWatch Logs**: Monitor application and system logs
- **CloudTrail**: Enable AWS API call logging
- **SSM Session Logs**: Review SSM session history

---

## Additional Resources

- [Terraform AWS Provider Documentation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [AWS Systems Manager Documentation](https://docs.aws.amazon.com/systems-manager/)
- [Windows Autologon Configuration](https://docs.microsoft.com/en-us/troubleshoot/windows-server/user-profiles-and-logon/turn-on-automatic-logon)

---

## Support

For issues or questions:
1. Check the [Troubleshooting](#troubleshooting) section
2. Review application logs
3. Check GitHub Actions workflow logs
4. Contact the development team

---

**Last Updated**: 2025-01-31

