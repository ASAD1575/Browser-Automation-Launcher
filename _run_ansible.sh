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
# Wait for all new instances to be Online in SSM and EC2 Health status to be ready
#########################################################
echo "Waiting for SSM availability and EC2 instance health..."

# Set max retries and timeout (in seconds)
MAX_RETRIES=40
WAIT_TIME=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Read expected count from the copied outputs file
  EXPECTED=$(jq -r '.cloned_instance_ids.value | length' < ../terraform/outputs.json 2>/dev/null || echo 0)

  if [ "$EXPECTED" -eq 0 ]; then
    echo "No instances expected, skipping wait."
    break
  fi

  # Check SSM availability
  READY=$(aws ssm describe-instance-information --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' --output text | wc -w)

  # Check EC2 instance states and health (handle multiple instances by counting)
  INSTANCE_IDS=$(jq -r '.cloned_instance_ids.value | join(" ")' < ../terraform/outputs.json)
  INSTANCE_STATUS_COUNT=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].InstanceState.Name' --output text 2>/dev/null | grep -c "running" || echo 0)
  HEALTH_CHECKS_COUNT=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].SystemStatus.Status' --output text 2>/dev/null | grep -c "ok\|initializing" || echo 0)
  HEALTH_OK_COUNT=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].SystemStatus.Status' --output text 2>/dev/null | grep -c "ok" || echo 0)

  if [ "$READY" -ge "$EXPECTED" ] && [ "$INSTANCE_STATUS_COUNT" -eq "$EXPECTED" ] && [ "$HEALTH_OK_COUNT" -eq "$EXPECTED" ]; then
    echo "All checks passed: SSM $READY/$EXPECTED Online, $INSTANCE_STATUS_COUNT/$EXPECTED running, $HEALTH_OK_COUNT/$EXPECTED healthy."
    break
  fi

  echo "Waiting: SSM $READY/$EXPECTED Online, $INSTANCE_STATUS_COUNT/$EXPECTED running, $HEALTH_CHECKS_COUNT/$EXPECTED initializing or healthy — retrying in $WAIT_TIME seconds..."
  sleep $WAIT_TIME
  ((RETRY_COUNT++))
done

# Check if we broke out of the loop due to timeout
if [ "$RETRY_COUNT" -eq "$MAX_RETRIES" ]; then
    echo "Timeout: Not all instances are online or healthy after $((MAX_RETRIES * WAIT_TIME)) seconds."
    echo "Final status: SSM $READY/$EXPECTED Online, $INSTANCE_STATUS_COUNT/$EXPECTED running, $HEALTH_OK_COUNT/$EXPECTED healthy."
    exit 1
fi

#########################################################
# Run Ansible Playbook (SSM)
#########################################################
chmod +x inventory/ec2.py
echo "Running Ansible playbook..."
ansible-inventory -i inventory/ec2.py --graph
ansible-playbook -i inventory/ec2.py playbook.yml -vv

echo "Ansible playbook execution completed."
