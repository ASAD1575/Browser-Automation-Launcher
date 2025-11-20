# Data source for existing IAM role
data "aws_iam_role" "existing_role" {
  name = var.existing_role_name
}

# Try to find existing instance profile that uses this role
data "aws_iam_instance_profile" "existing_profile" {
  count = var.create_instance_profile_if_missing ? 0 : 1
  name  = var.instance_profile_name != null ? var.instance_profile_name : var.existing_role_name
}

# Create instance profile if it doesn't exist
resource "aws_iam_instance_profile" "instance_profile" {
  count = var.create_instance_profile_if_missing ? 1 : 0
  name  = var.instance_profile_name != null ? var.instance_profile_name : var.existing_role_name
  role  = data.aws_iam_role.existing_role.name

  lifecycle {
    create_before_destroy = true
  }
}