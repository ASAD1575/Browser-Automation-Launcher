#!/bin/bash
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
pip install "ansible>=9" boto3 botocore pywinrm requests-ntlm

# Install AWS CLI
pip install awscli --upgrade

# AWS Session Manager Plugin download URL (direct link)
echo "Downloading AWS Session Manager plugin..."

curl -o session-manager-plugin-linux-x64.tar.gz https://d1vvhvl2y92vvt.cloudfront.net/aws-session-manager-plugin/1.2.10/session-manager-plugin-linux-x64.tar.gz

# Verify the download
if [ ! -f session-manager-plugin-linux-x64.tar.gz ]; then
  echo "Error: Failed to download the AWS Session Manager plugin"
  exit 1
fi

# Extract the tarball
echo "Extracting AWS Session Manager plugin..."
tar -xvzf session-manager-plugin-linux-x64.tar.gz

# Create directory for installation (no sudo required)
mkdir -p $HOME/session-manager-plugin

# Move the extracted files to the user directory
mv session-manager-plugin $HOME/session-manager-plugin/

# Add the installation directory to the PATH
echo "export PATH=\$PATH:$HOME/session-manager-plugin" >> $HOME/.bashrc
source $HOME/.bashrc

# Verify if the session-manager plugin is available
if ! command -v session-manager-plugin &> /dev/null; then
  echo "Error: AWS Session Manager plugin installation failed"
  exit 1
fi

echo "AWS Session Manager plugin installed successfully"

ansible-galaxy collection install amazon.aws community.aws ansible.windows community.windows

# Load Ansible env (optional user run)
if [ -f .env.ansible ]; then
    set -a
    source .env.ansible
    set +a
fi

#########################################################
# Wait for all new instances to be fully initialized and ready for SSM
#########################################################
echo "Waiting for EC2 instances to be fully initialized and ready for SSM..."

# Set max retries and timeout (in seconds)
MAX_RETRIES=60
WAIT_TIME=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  # Read expected count from the copied outputs file
  EXPECTED=$(jq -r '.cloned_instance_ids.value | length' < ../terraform/outputs.json 2>/dev/null || echo 0)

  if [ "$EXPECTED" -eq 0 ]; then
    echo "No instances expected, skipping wait."
    break
  fi

  # Check EC2 instance states, public IPs, and health status
  INSTANCE_IDS=$(jq -r '.cloned_instance_ids.value | join(" ")' < ../terraform/outputs.json 2>/dev/null || echo "")
  if [ -z "$INSTANCE_IDS" ]; then
    INSTANCE_STATUS_COUNT=0
    PUBLIC_IP_COUNT=0
    SYSTEM_STATUS_COUNT=0
    SYSTEM_OK_COUNT=0
  else
    INSTANCE_STATUS_COUNT=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --query 'Reservations[*].Instances[*].State.Name' --output text 2>/dev/null | grep -c "running" 2>/dev/null || echo 0)
    PUBLIC_IP_COUNT=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --query 'Reservations[*].Instances[*].PublicIpAddress' --output text 2>/dev/null | grep -c -v None 2>/dev/null || echo 0)
    SYSTEM_STATUS_COUNT=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].SystemStatus.Status' --output text 2>/dev/null | grep -c "ok\|initializing" 2>/dev/null || echo 0)
    SYSTEM_OK_COUNT=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].SystemStatus.Status' --output text 2>/dev/null | grep -c "ok" 2>/dev/null || echo 0)
  fi

  if [ "$INSTANCE_STATUS_COUNT" -eq "$EXPECTED" ] && [ "$PUBLIC_IP_COUNT" -eq "$EXPECTED" ] && [ "$SYSTEM_OK_COUNT" -eq "$EXPECTED" ]; then
    echo "All checks passed: $INSTANCE_STATUS_COUNT/$EXPECTED running, $PUBLIC_IP_COUNT/$EXPECTED have public IPs, $SYSTEM_OK_COUNT/$EXPECTED system status ok."
    break
  fi

  echo "Waiting: $INSTANCE_STATUS_COUNT/$EXPECTED running, $PUBLIC_IP_COUNT/$EXPECTED have public IPs, $SYSTEM_STATUS_COUNT/$EXPECTED system status initializing — retrying in $WAIT_TIME seconds..."
  sleep $WAIT_TIME
  ((RETRY_COUNT++))
done

# Check if we broke out of the loop due to timeout
if [ "$RETRY_COUNT" -eq "$MAX_RETRIES" ]; then
    echo "Timeout: Not all instances are fully initialized after $((MAX_RETRIES * WAIT_TIME)) seconds."
    echo "Final status: $INSTANCE_STATUS_COUNT/$EXPECTED running, $PUBLIC_IP_COUNT/$EXPECTED have public IPs, $SYSTEM_OK_COUNT/$EXPECTED system status ok."
    exit 1
fi

#########################################################
# Additional wait for instance setup
#########################################################
echo "Waiting additional 2 minutes for instance setup to complete..."
sleep 120  # 2 minutes additional wait

#########################################################
# Run Ansible Playbook (SSM)
#########################################################
chmod +x inventory/ec2.py
echo "Running Ansible playbook..."
ansible-inventory -i inventory/ec2.py --graph
ansible-playbook -i inventory/ec2.py playbook.yml -vv

# Capture the exit code of ansible-playbook
ANSIBLE_EXIT_CODE=$?

if [ $ANSIBLE_EXIT_CODE -ne 0 ]; then
    echo "Ansible playbook failed with exit code $ANSIBLE_EXIT_CODE"
    exit $ANSIBLE_EXIT_CODE
fi

echo "Ansible playbook execution completed successfully."
