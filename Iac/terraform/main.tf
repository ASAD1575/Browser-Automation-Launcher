terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.17.0"
    }
  }
  backend "s3" {
    bucket         = var.terraform_state_bucket     # Replace with your S3 bucket name
    key            = "terraform-${var.env}.tfstate" # Replace with your desired state file path
    region         = "us-east-1"                    # Replace with your AWS region
    dynamodb_table = "terraform-state-lock-table"   # Replace with your DynamoDB table name
    encrypt        = true
  }
}


# data "terraform_remote_state" "core" {
#   backend = "s3"
#   config = {
#     bucket = var.terraform_state_bucket
#     key    = "terraform-core-aws-infrastructure-${var.env}.tfstate"
#     region = var.aws_region
#   }
# }

# VPC Module
module "vpc" {
  source = "./modules/vpc"
}

# Security Group Module
module "security_group" {
  source              = "./modules/security_group"
  security_group_name = var.existing_security_group_name
}

# IAM Role Module (for EC2 instances)
module "IAM_role" {
  source             = "./modules/IAM_role"
  existing_role_name = var.existing_iam_role_name
}

# CloudWatch Module
module "cloudwatch" {
  source = "./modules/cloudwatch"

  log_group_name     = "/prod/Browser-Automation-Launcher/app"
  retention_in_days  = 30
  cw_kms_key_arn     = null
  cwagent_param_name = "/prod/cwagent/windows"

  cwagent_config_json = jsonencode({
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path        = "C:\\Users\\Administrator\\Documents\\applications\\browser-automation-launcher\\logs\\monitor.log"
              log_group_name   = "/prod/Browser-Automation-Launcher/app"
              log_stream_name  = "{instance_id}/monitor.log"
              timestamp_format = "%Y-%m-%d %H:%M:%S"
            },
            {
              file_path        = "C:\\Users\\Administrator\\Documents\\applications\\browser-automation-launcher\\logs\\app.log"
              log_group_name   = "/prod/Browser-Automation-Launcher/app"
              log_stream_name  = "{instance_id}/app.log"
              timestamp_format = "%Y-%m-%d %H:%M:%S"
            }
          ]
        }
        windows_events = {
          collect_list = [
            {
              event_levels    = ["ERROR", "WARNING"]
              event_format    = "xml"
              log_group_name  = "/prod/Browser-Automation-Launcher/app"
              log_stream_name = "{instance_id}/EventLog/System"
              event_name      = "System"
            },
            {
              event_levels    = ["ERROR", "WARNING"]
              event_format    = "xml"
              log_group_name  = "/prod/Browser-Automation-Launcher/app"
              log_stream_name = "{instance_id}/EventLog/Application"
              event_name      = "Application"
            }
          ]
        }
      }
    }
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "NT AUTHORITY\\SYSTEM"
      debug                       = false
    }
  })
}

# Cloned Instances
module "cloned_instance" {
  source                = "./modules/cloned_instance"
  cloned_instance_count = var.cloned_instance_count
  ami_id                = var.windows_server_2022_ami_id
  instance_type         = var.cloned_instance_type
  subnet_id             = element(module.vpc.public_subnet_ids, 0)
  security_group_id     = module.security_group.windows_security_group_id
  key_name              = var.key_pair_name
  iam_instance_profile  = module.IAM_role.instance_profile_name # Attach IAM instance profile
  cloned_instance_name  = var.clone_instance_name
  env                   = var.env
  cwagent_param_name    = module.cloudwatch.cwagent_param_name
  region                = var.aws_region
  cw_log_group_name     = module.cloudwatch.log_group_name
  app_service_name      = "BrowserAutomationLauncher"
}
