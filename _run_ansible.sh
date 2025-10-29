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
  # Check SSM availability
  READY=$(aws ssm describe-instance-information --query 'InstanceInformationList[?PingStatus==`Online`].InstanceId' --output text | wc -w)
  
  # Check EC2 health status
  INSTANCE_IDS=$(jq -r '.cloned_instance_ids.value | join(" ")' < ../terraform/outputs.json)
  INSTANCE_STATUS=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].InstanceState.Name' --output text)
  HEALTH_CHECKS=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].SystemStatus.Status' --output text)

  # Read expected count from the copied outputs file
  EXPECTED=$(jq -r '.cloned_instance_ids.value | length' < ../terraform/outputs.json 2>/dev/null || echo 0)

  # If all conditions are met (SSM is online, EC2 running, health checks are ok)
  if [ "$EXPECTED" -gt 0 ] && [ "$READY" -ge "$EXPECTED" ] && [ "$INSTANCE_STATUS" == "running" ] && [ "$HEALTH_CHECKS" == "ok" ]; then
    echo "SSM shows $READY/$EXPECTED Online, EC2 instances are running, and health checks passed."
    break
  fi

  # If health check is still "initializing", continue retrying
  if [[ "$HEALTH_CHECKS" == "initializing" ]]; then
    echo "Health check is 'initializing' — retrying in $WAIT_TIME seconds..."
  else
    echo "SSM: $READY/$EXPECTED Online, EC2 Status: $INSTANCE_STATUS, Health Checks: $HEALTH_CHECKS — retrying in $WAIT_TIME seconds..."
  fi

  sleep $WAIT_TIME
  ((RETRY_COUNT++))
done

# Check if we broke out of the loop due to timeout
if [ "$READY" -lt "$EXPECTED" ] || [ "$INSTANCE_STATUS" != "running" ] || [ "$HEALTH_CHECKS" != "ok" ]; then
    echo "Timeout: Not all instances are online or healthy after $((MAX_RETRIES * WAIT_TIME)) seconds."
    echo "Error: Unable to detect all instances online or healthy."
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
