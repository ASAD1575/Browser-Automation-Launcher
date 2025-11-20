output "instance_profile_name" {
  description = "The name of the IAM instance profile"
  value = var.create_instance_profile_if_missing ? (
    aws_iam_instance_profile.instance_profile[0].name
  ) : (
    data.aws_iam_instance_profile.existing_profile[0].name
  )
}
