variable "aws_region" {
  type = string
}

# Windows Server 2022 AMI ID (update with actual AMI ID for your region)
variable "windows_server_2022_ami_id" {
  description = "AMI ID for Windows Server 2022"
  type        = string
  default     = "ami-028dc1123403bd543" # Example for us-east-1, update as needed
}

variable "cloned_instance_count" {
  description = "Number of cloned instances to create"
  type        = string
  default     = "1"
}

variable "cloned_instance_type" {
  description = "Instance type for the cloned instances"
  type        = string
  default     = "t3.micro"
}

variable "clone_instance_name" {
  description = "The name tag for the cloned instances"
  type        = string
  default     = "Cloned-Instance"
  
}

variable "env" {
  description = "Environment (e.g., dev, prod)"
  type        = string
  default     = "dev"

}

variable "key_pair_name" {
  description = "Name of the existing key pair for EC2 instances"
  type        = string
}

variable "existing_security_group_name" {
  description = "Name of the existing security group"
  type        = string
  default     = "axs-test-sg"
}

variable "existing_iam_role_name" {
  description = "Name of the existing IAM role"
  type        = string
  default     = "ec2-browser-role"
}

variable "terraform_state_bucket" {
  description = "S3 bucket name for Terraform remote state"
  type        = string
}
