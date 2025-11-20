# Data source for existing IAM role
data "aws_iam_role" "existing_role" {
  name = var.existing_role_name
}

# Data source for existing IAM instance profile
# Note: Instance profile name typically matches the role name, but can differ
data "aws_iam_instance_profile" "existing_profile" {
  name = var.existing_role_name
}


