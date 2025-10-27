# Infrastructure as Code (IaC) for Browser Automation Launcher

## Overview

This Infrastructure as Code (IaC) setup automates the provisioning and configuration of AWS resources for running browser automation workloads on Windows Server 2025 EC2 instances. It leverages Terraform for infrastructure provisioning and Ansible for configuration management and remote execution via AWS Systems Manager (SSM).

The setup creates Windows EC2 instances from a custom AMI (which already contains the browser automation code), enables SSM for secure access, and provides Ansible automation to "login" (execute commands) on all instances dynamically after Terraform deployment.

## Features

- **Terraform Modules**: Modular infrastructure components including VPC, Security Groups, IAM Roles, EC2 instances, and CloudWatch monitoring.
- **Windows EC2 Instances**: Launches instances from a custom Windows Server 2022 AMI with pre-installed browser automation code.
- **SSM Integration**: Automatic installation and configuration of SSM agent for secure, agent-based access without SSH.
- **Ansible Inventory from Terraform Outputs**: Reads instance IDs directly from Terraform outputs to target exactly the instances created by Terraform.
- **Ansible SSM Playbook**: Executes tasks on all discovered instances using the `aws_ssm` connection plugin, including user impersonation.
- **GitHub Actions CI/CD**: Automated deployment and destruction pipelines with Terraform workspace management for multiple environments (dev/prod).
- **Environment Variable Support**: Secure handling of sensitive configuration via `.env` files.
- **CloudWatch Monitoring**: Pre-configured logging and metrics collection for application and system events.

## Prerequisites

Before deploying this infrastructure, ensure you have the following:

- **AWS Account**: With permissions to create VPCs, EC2 instances, IAM roles, Security Groups, and CloudWatch resources.
- **Terraform**: Version 1.5.0 or later installed locally or in CI/CD environment.
- **Ansible**: Installed for configuration management (version 2.9+ recommended).
- **Python**: Version 3.9+ with `boto3` library for dynamic inventory.
- **GitHub Repository**: With the following secrets configured:
  - `AWS_ACCESS_KEY_ID`: AWS access key for Terraform and Ansible.
  - `AWS_SECRET_ACCESS_KEY`: AWS secret key for Terraform and Ansible.
  - `WINDOWS_USERNAME`: Username for Ansible to become on Windows instances (e.g., `ticketboat`).
  - `WINDOWS_PASSWORD`: Password for the Windows user.
- **Custom AMI**: A Windows Server 2022 AMI with browser automation code pre-installed (AMI ID specified in `.env.terraform`).

## Architecture

The infrastructure consists of the following components:

- **VPC Module**: Creates a VPC with public subnets for instance placement.
- **Security Group Module**: Defines inbound/outbound rules for Windows instances.
- **IAM Role Module**: Creates an IAM role with SSM permissions, attached to instances via instance profile.
- **Cloned Instance Module**: Launches EC2 instances from the custom AMI, installs SSM agent, and configures CloudWatch.
- **CloudWatch Module**: Sets up CloudWatch agent for logging application and system events.
- **Ansible Automation**: Uses dynamic inventory to target instances and execute commands via SSM.

All instances are tagged with names like `Browser-Automation-Launcher-1-Dev` (configurable via `clone_instance_name` and `env` variables).

## Usage

### Local Deployment

1. **Clone the Repository**:
   ```bash
   git clone <repository-url>
   cd browser-automation-launcher/Iac
   ```

2. **Configure Environment Variables**:
   - Copy and edit `.env.terraform` and `.env.ansible` files with your values.
   - Ensure AWS credentials are set (e.g., via `aws configure` or environment variables).

3. **Deploy Infrastructure with Terraform**:
   ```bash
   cd terraform
   terraform init
   terraform plan -var-file=terraform.tfvars
   terraform apply -var-file=terraform.tfvars
   ```

4. **Run Ansible Configuration**:
   ```bash
   cd terraform
   terraform output -json > ../ansible/instances.json
   cd ../ansible
   ansible-playbook -i inventory/ec2.py playbook.yml
   ```

5. **Verify Deployment**:
   - Check Terraform outputs for instance IDs and public IPs.
   - Ansible will output login confirmations for each instance.

### CI/CD Deployment

The GitHub Actions workflows automate the deployment process:

- **Deploy Workflow** (`deploy.yml`):
  - Triggered on push to `main`/`master` or manual dispatch.
  - Runs Terraform plan, apply, then Ansible playbook.
  - Supports environment selection (dev/prod) with Terraform workspaces.

- **Destroy Workflow** (`destroy.yml`):
  - Manual trigger with environment selection and confirmation.
  - Destroys all resources and cleans up state.

To trigger:
1. Go to GitHub repository Actions tab.
2. Select "Deploy Infrastructure" or "Destroy Infrastructure".
3. Choose environment and run.

## Configuration

### Terraform Configuration

- **`variables.tf`**: Variable definitions with defaults.
- **`.env.terraform`**: Main configuration file with instance count, AMI ID, region, etc., loaded as environment variables during deployment.
- **`terraform.tfvars`**: Example/testing configuration file (not used in production deployments).

Key variables (set in `.env.terraform`):
- `cloned_instance_count`: Number of instances to create (e.g., 10).
- `clone_instance_name`: Base name for instances (e.g., "Browser-Automation-Launcher").
- `windows_server_2022_ami_id`: Custom AMI ID.
- `env`: Environment tag (e.g., "Dev").

### Ansible Configuration

- **`ansible.cfg`**: Ansible configuration with SSM plugin settings.
- **`inventory/ec2.py`**: Python script that reads instance IDs from `instances.json` (generated from Terraform outputs).
- **`playbook.yml`**: Playbook to run commands on instances via SSM.
- **`.env.ansible`**: Environment variables for Windows credentials.

The playbook:
- Targets the `windows` group from dynamic inventory.
- Uses `aws_ssm` connection.
- Becomes the specified user (`WINDOWS_USERNAME`) with password.
- Runs `echo` and `whoami` commands to verify login.

## Modules

### Terraform Modules

Located in `terraform/modules/`:

- **`vpc`**: Creates VPC, internet gateway, route tables, and public subnets.
- **`security_group`**: Data source for existing security group by name.
- **`IAM_role`**: Data source for existing IAM role and instance profile.
- **`cloned_instance`**: Launches EC2 instances with user data for SSM and CloudWatch setup.
- **`cloudwatch`**: Configures CloudWatch agent with custom log groups and streams.

### Ansible Components

Located in `ansible/`:

- **`ansible.cfg`**: Global Ansible settings.
- **`inventory/ec2.py`**: Dynamic inventory script querying EC2 API.
- **`playbook.yml`**: YAML playbook for SSM tasks.

## Security Considerations

- **IMDSv2**: Enforced on all instances for secure metadata access.
- **Encrypted Volumes**: Root block devices use encrypted GP3 volumes.
- **SSM Access**: All remote access via SSM, no direct SSH or RDP.
- **IAM Least Privilege**: Roles limited to SSM and CloudWatch permissions.
- **Environment Variables**: Sensitive data stored in GitHub secrets and `.env` files (not committed).

## Troubleshooting

- **SSM Agent Issues**: Ensure the agent is running on instances (checked in user data).
- **IAM Permissions**: Verify the instance profile has `AmazonSSMManagedInstanceCore` policy.
- **Inventory Problems**: Check AWS credentials and region in `inventory/ec2.py`.
- **Ansible Failures**: Confirm `WINDOWS_USERNAME` and `WINDOWS_PASSWORD` are set correctly.
- **Terraform Errors**: Ensure existing resources (SG, IAM role) exist before applying.
- **CI/CD Logs**: Review GitHub Actions logs for detailed error messages.

## Contributing

1. Make changes to Terraform or Ansible files.
2. Test locally with `terraform plan` and `ansible-playbook --check`.
3. Commit and push to trigger CI/CD.
4. Monitor workflows and verify outputs.

## License

[Specify license if applicable]
