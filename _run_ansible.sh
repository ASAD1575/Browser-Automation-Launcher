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

# --- START: NON-SUDO AWS SESSION MANAGER PLUGIN INSTALLATION ---
INSTALL_DIR="$HOME/.local/bin"
PLUGIN_NAME="session-manager-plugin"
TEMP_DIR="/tmp/smm_install_temp_$$" # Unique temp directory

echo "Starting non-sudo installation of AWS Session Manager Plugin..."
mkdir -p "$TEMP_DIR"
mkdir -p "$INSTALL_DIR"

# Download the latest Linux 64-bit ZIP file
DOWNLOAD_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.zip"

echo "Downloading plugin from AWS S3..."
if ! curl -s -o "$TEMP_DIR/$PLUGIN_NAME.zip" "$DOWNLOAD_URL"; then
    echo "Error: Failed to download plugin. Check network connectivity."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Unzip the executable
echo "Extracting executable..."
if ! unzip -q "$TEMP_DIR/$PLUGIN_NAME.zip" -d "$TEMP_DIR"; then
    echo "Error: Failed to unzip plugin file."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Move the executable to the local bin directory
echo "Moving $PLUGIN_NAME to $INSTALL_DIR..."
mv "$TEMP_DIR/$PLUGIN_NAME" "$INSTALL_DIR/"

# Make sure it's executable
chmod +x "$INSTALL_DIR/$PLUGIN_NAME"

# Clean up temporary files
rm -rf "$TEMP_DIR"

# Add the installation directory to the PATH for the current shell session
# This ensures the command is available immediately after installation
export PATH="$INSTALL_DIR:$PATH"
echo "NOTICE: Added $INSTALL_DIR to PATH for this script's session."

# Verify if the session-manager plugin is available
if ! command -v $PLUGIN_NAME &> /dev/null; then
  echo "Error: AWS Session Manager plugin installation failed"
  exit 1
fi

echo "AWS Session Manager plugin installed successfully"
# --- END: NON-SUDO AWS SESSION MANAGER PLUGIN INSTALLATION ---

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
