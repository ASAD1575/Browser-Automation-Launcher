# NOTE: Do not call this directly - it is called from ./deploy.sh

#########################################################
# Generate the backend.tf file for the main terraform configuration
#########################################################

cd Iac/terraform/
rm -fR .terraform
rm -fR .terraform.lock.hcl
echo "Generating backend.tf for Terraform..."
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

# Plan terraform changes
echo "Planning resources..."
terraform plan -out=tfplan -input=false

# terraform plan push to artifact for review (optional)
echo "Exporting terraform plan to tfplan.json..."
terraform show -json tfplan > tfplan.json

# Apply terraform changes
echo "Getting plan from tfplan..."
terraform apply -input=false tfplan -auto-approve
if [ $? -ne 0 ]; then
    echo "Terraform apply failed."
    exit 1
fi
echo "Terraform apply completed successfully."

# Clean up plan files
echo "Cleaning up plan files..."
rm -f tfplan
rm -f tfplan.json
