##############################
# ⚙️ SECURITY GROUP (WINDOWS)
##############################

data "aws_security_group" "selected_sg" {
  filter {
    name   = "group-name"
    values = [var.security_group_name]
  }
}

output "windows_security_group_id" {
  description = "The ID of the Security Group"
  value       = data.aws_security_group.selected_sg.id
}
