# NOTE: Do not call this directly - it is called from ./deploy.sh

#########################################################
# Generate the backend.tf file for the main terraform configuration
#########################################################

cd Iac/terraform/
rm -fR .terraform
rm -fR .terraform.lock.hcl
cat > backend.tf << EOF
terraform {
  backend "s3" {
    bucket = "${TERRAFORM_STATE_BUCKET}"
    key    = "terraform-${TERRAFORM_STATE_IDENT}.tfstate"
    region = "${AWS_DEFAULT_REGION}"
  }
}
EOF

#########################################################
# Run Terraform
#########################################################

# Initialize terraform
terraform init

echo "Destroying resources..."
terraform destroy -auto-approve
