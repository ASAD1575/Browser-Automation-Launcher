# ==========================================================
# EC2 Clone Module — Launch from Custom AMI
# ==========================================================

resource "aws_instance" "cloned_instance" {
  count                       = var.cloned_instance_count
  ami                         = var.ami_id # custom AMI: ami-0d418d3b14bf1782f
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  key_name                    = var.key_name
  iam_instance_profile        = var.iam_instance_profile # Attach IAM instance profile
  associate_public_ip_address = true
  tags = {
    Name = "${var.cloned_instance_name}-${count.index + 1}-${var.env}"
  }

  user_data = <<-EOF
<powershell>
${file("../scripts/setup_login.ps1")}
</powershell>
EOF

  # ==============================
  # Metadata & Security Hardening
  # ==============================

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2
    http_put_response_hop_limit = 1
    instance_metadata_tags = "enabled"
  }

  # ==============================
  # Root Block Device
  # ==============================

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 30 # Adjust as needed
    delete_on_termination = true

    # optional: define KMS key if using customer-managed encryption
    # kms_key_id = aws_kms_key.ec2_encryption.arn
  }

  # ==============================
  # Lifecycle Management
  # ==============================
  lifecycle {
    create_before_destroy = true
  }
}
