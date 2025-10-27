# Browser Automation Launcher Infrastructure

This repository contains Terraform configurations and GitHub Actions workflows for deploying browser automation infrastructure on AWS using Windows Server instances.

## Architecture

- **VPC**: Uses existing default VPC
- **Security Groups**: Uses existing security group named "axs-test-sg"
- **IAM Role**: Uses existing IAM role named "ec2-browser-role"
- **EC2 Instances**: Windows Server 2022 instances with browser automation software
- **CloudWatch**: Centralized logging and monitoring

## Prerequisites

### AWS Resources
Ensure the following AWS resources exist in your account:
- VPC: Default VPC
- Security Group: `axs-test-sg`
- IAM Role: `ec2-browser-role` with required policies
- Key Pair: `test-server-key`

### Secrets Required (GitHub Repository Secrets)
- `AWS_ACCESS_KEY_ID`: AWS access key
- `AWS_SECRET_ACCESS_KEY`: AWS secret key
- `WINDOWS_ADMIN_PASSWORD`: Windows administrator password for Ansible

## Quick Start

### Local Development

1. **Configure Environment**:
   ```bash
   cd terraform
   cp .env.terraform.example .env.terraform
   # Edit .env.terraform with your values
   source .env.terraform
   ```

2. **Initialize Terraform**:
   ```bash
   terraform init
   ```

3. **Plan Deployment**:
   ```bash
   terraform plan -var-file=terraform.tfvars
   ```

4. **Apply Configuration**:
   ```bash
   terraform apply -var-file=terraform.tfvars
   ```

5. **Login to Instances**:
   ```bash
   ./login_instances.sh
   ```

### CI/CD Deployment

The repository includes GitHub Actions workflows for automated deployment:

#### Deploy Workflow
- **Trigger**: Push to main/master branch or manual dispatch
- **Jobs**:
  1. **Terraform Plan**: Validates and plans infrastructure changes
  2. **Terraform Apply**: Applies changes (only on main/master)
  3. **Ansible Configure**: Configures instances post-deployment

#### Destroy Workflow
- **Trigger**: Manual dispatch only
- **Requires**: Confirmation input "destroy"
- **Cleans**: All infrastructure and local state files

## Directory Structure

```
.
├── terraform/
│   ├── main.tf                 # Main Terraform configuration
│   ├── variables.tf            # Variable definitions
│   ├── terraform.tfvars        # Variable values
│   ├── outputs.tf              # Output definitions
│   ├── backend.tf              # State backend configuration
│   ├── .env.terraform          # Environment variables
│   ├── modules/
│   │   ├── vpc/                # VPC module (uses existing)
│   │   ├── security_group/     # Security group module (uses existing)
│   │   ├── IAM_role/           # IAM role module (uses existing)
│   │   ├── cloned_instance/    # EC2 instance module
│   │   └── cloudwatch/         # CloudWatch module
│   ├── login_instances.sh      # SSM login script
│   ├── ansible_inventory.ini   # Ansible inventory template
│   ├── ansible_login.yml       # Ansible login playbook
│   ├── ansible_deploy.yml      # Ansible deployment playbook
│   └── generate_inventory.py   # Dynamic inventory generator
├── .github/
│   └── workflows/
│       ├── deploy.yml          # CI/CD deployment pipeline
│       └── destroy.yml         # Infrastructure destruction pipeline
└── README.md
```

## Configuration Files

### Environment Variables (.env.terraform)
```bash
# AWS Region
export TF_VAR_aws_region="us-east-1"

# Existing Security Group Name
export TF_VAR_existing_security_group_name="axs-test-sg"

# Existing IAM Role Name
export TF_VAR_existing_iam_role_name="ec2-browser-role"

# Key Pair Name
export TF_VAR_key_pair_name="test-server-key"

# Other variables...
```

### Terraform Variables (terraform.tfvars)
```hcl
aws_region                    = "us-east-1"
windows_server_2022_ami_id   = "ami-028dc1123403bd543"
cloned_instance_count         = 1
cloned_instance_type          = "t3.micro"
clone_instance_name           = "Cloned-Instance"
env                           = "Dev"
key_pair_name                 = "test-server-key"
existing_security_group_name  = "axs-test-sg"
existing_iam_role_name        = "ec2-browser-role"
```

## Instance Access

### AWS Systems Manager Session Manager (Recommended)
```bash
cd terraform
./login_instances.sh
```

### Ansible
```bash
cd terraform
python3 generate_inventory.py > inventory.json
ansible-playbook -i inventory.json ansible_deploy.yml --ask-pass
```

## Monitoring

- **CloudWatch Logs**: Centralized logging at `/prod/app`
- **CloudWatch Metrics**: Instance and application metrics
- **SSM**: Instance management and monitoring

## Troubleshooting

### Common Issues

1. **No public subnets in default VPC**:
   - Use a custom VPC with public subnets
   - Or modify Terraform to use private subnets with NAT Gateway

2. **IAM role/instance profile not found**:
   - Ensure "ec2-browser-role" exists with required policies
   - Instance profile must have the same name as the role

3. **Security group not found**:
   - Ensure "axs-test-sg" security group exists
   - Check the group name matches exactly

4. **Ansible connection failures**:
   - Verify Windows Firewall allows WinRM (TCP 5986)
   - Ensure administrator password is correct
   - Check network connectivity

### Logs and Debugging

- **Terraform logs**: Check GitHub Actions output
- **Instance logs**: Use SSM Session Manager or CloudWatch
- **Ansible logs**: Review playbook output in CI/CD

## Security Considerations

- Instances use IMDSv2 for metadata access
- Encrypted root volumes
- Least-privilege IAM policies
- WinRM over HTTPS with NTLM authentication
- No public RDP access (use SSM instead)

## Contributing

1. Create a feature branch
2. Make changes
3. Test locally
4. Create a pull request
5. CI/CD will validate changes
6. Merge after approval

## License

[Add your license information here]
