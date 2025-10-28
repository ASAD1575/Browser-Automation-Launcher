# NOTE: Do not call this directly - it is called from ./deploy.sh

#########################################################
# Generate the backend.tf file for the main terraform configuration
#########################################################

cd Iac/terraform/
rm -fR .terraform
rm -fR .terraform.lock.hcl
echo "Generating backend.tf for Terraform destroy..."
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
echo "Initializing Terraform..."
terraform init

# Destroy terraform-managed infrastructure
echo "Destroying resources..."
terraform destroy -auto-approve
if [ $? -ne 0 ]; then
    echo "Terraform destroy failed."
    exit 1
fi
echo "Terraform destroy completed successfully."
