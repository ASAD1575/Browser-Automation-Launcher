#!/bin/bash

set -e

# --- Configuration for Artifact Locations ---
# The tf_output.json file is downloaded into Iac/terraform/ 
# from the previous job's artifact upload.
TERRAFORM_OUTPUT_FILE="Iac/terraform/tf_output.json"
ANSIBLE_INVENTORY_FILE="Iac/ansible/inventory/instances.json"

#########################################################
# Validate Terraform Output File
#########################################################

echo "Capturing Terraform outputs for Ansible inventory from downloaded artifact..."

# The artifact is tf_output.json
if [ ! -f $TERRAFORM_OUTPUT_FILE ]; then
  echo "Error: Terraform output file ($TERRAFORM_OUTPUT_FILE) not found."
  echo "This means the previous deployment job failed to create/upload the artifact, or the download failed."
  exit 1
fi

# Copy the outputs to where the original script expected them, and to the Ansible inventory location
cp $TERRAFORM_OUTPUT_FILE Iac/terraform/outputs.json
cp $TERRAFORM_OUTPUT_FILE $ANSIBLE_INVENTORY_FILE

echo "Terraform outputs (from artifact):"
cat $TERRAFORM_OUTPUT_FILE

# Check if outputs are empty
# We check the content of the copied file
if [ "$(jq -r '.' $TERRAFORM_OUTPUT_FILE 2>/dev/null)" = "{}" ]; then
  echo "No Terraform outputs found. Skipping Ansible configuration as no instances were deployed."
  exit 0
fi

#########################################################
# Run Ansible Playbook Preparation
#########################################################

cd Iac/ansible

# Install Ansible + deps
echo "Installing Ansible and dependencies..."
python -m pip install --upgrade pip
pip install "ansible>=9" boto3 botocore
ansible-galaxy collection install amazon.aws community.aws ansible.windows community.windows

# Load Ansible env (optional user run)
if [ -f .env.ansible ]; then
    set -a
    source .env.ansible
    set +a
fi

#########################################################
# Wait for all new instances to be Online in SSM (up to ~10 min)
#########################################################
echo "Waiting for SSM availability..."
for i in {1..40}; do
  READY=$(aws ssm describe-instance-information --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' --output text | wc -w)
  # Read expected count from the copied outputs file
  EXPECTED=$(jq -r '.cloned_instance_ids.value | length' < ../terraform/outputs.json 2>/dev/null || echo 0)
  
  if [ "$EXPECTED" -gt 0 ] && [ "$READY" -ge "$EXPECTED" ]; then
    echo "SSM shows $READY/$EXPECTED Online"
    break
  fi
  echo "$READY/$EXPECTED Online — retrying in 15s..."
  sleep 15
done


# Check if we broke out of the loop due to timeout
if [ "$READY" -lt "$EXPECTED" ]; then
    echo "Timeout: Not any instance came online in SSM after 10 minutes."
    echo "Error: Unable to detect any instance online in SSM."
    exit 1
fi

#########################################################
# Wait 5 minutes before running the Ansible Playbook
#########################################################
echo "Waiting for 5 minutes before running the Ansible playbook..."
sleep 300

#########################################################
# Run Ansible Playbook (SSM)
#########################################################
chmod +x inventory/ec2.py
echo "Running Ansible playbook..."
ansible-inventory -i inventory/ec2.py --graph
ansible-playbook -i inventory/ec2.py playbook.yml -vv

echo "Ansible playbook execution completed."
