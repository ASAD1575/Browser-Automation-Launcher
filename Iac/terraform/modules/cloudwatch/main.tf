resource "aws_cloudwatch_log_group" "app" {
  name              = var.log_group_name
  retention_in_days = var.retention_in_days
  kms_key_id        = var.cw_kms_key_arn
  tags              = { Environment = "prod" }
}

resource "aws_ssm_parameter" "cwagent_windows" {
  name  = var.cwagent_param_name
  type  = "String"
  tier  = "Standard"
  value = var.cwagent_config_json
  tags  = { Environment = "prod" }
}


    
