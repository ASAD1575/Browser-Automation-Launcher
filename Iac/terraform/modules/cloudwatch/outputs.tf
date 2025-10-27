output "log_group_name" {
  value = aws_cloudwatch_log_group.app.name
}

output "cwagent_param_name" {
  value = aws_ssm_parameter.cwagent_windows.name
}

output "cwagent_param_arn" {
  value = aws_ssm_parameter.cwagent_windows.arn
}
