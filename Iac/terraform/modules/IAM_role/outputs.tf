output "instance_profile_name" {
  description = "The name of the IAM instance profile"
  value       = data.aws_iam_instance_profile.existing_profile.name
}
