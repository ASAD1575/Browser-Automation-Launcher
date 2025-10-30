#!/bin/bash

# --- Configuration for Artifact Locations ---
TERRAFORM_OUTPUT_FILE="Iac/terraform/tf_output.json"
ANSIBLE_INVENTORY_FILE="Iac/ansible/inventory/instances.json"

#########################################################
# Validate Terraform Output File
#########################################################

echo "Capturing Terraform outputs for EC2 instance readiness check..."

# The artifact is tf_output.json
if [ ! -f $TERRAFORM_OUTPUT_FILE ]; then
  echo "Error: Terraform output file ($TERRAFORM_OUTPUT_FILE) not found."
  echo "This means the previous deployment job failed to create/upload the artifact, or the download failed."
  exit 1
fi

# Copy to expected paths for consistency
cp $TERRAFORM_OUTPUT_FILE Iac/terraform/outputs.json
cp $TERRAFORM_OUTPUT_FILE $ANSIBLE_INVENTORY_FILE

echo "Terraform outputs (from artifact):"
cat $TERRAFORM_OUTPUT_FILE

# Check if outputs are empty
if [ "$(jq -r '.' $TERRAFORM_OUTPUT_FILE 2>/dev/null)" = "{}" ]; then
  echo "No Terraform outputs found. Skipping Ansible configuration as no instances were deployed."
  exit 0
fi

# Additional wait to allow instance setup scripts to complete
echo "Waiting additional 3 minutes for instance setup to complete..."
sleep 180

#########################################################
# Wait for all instances to become SSM-ready
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

  # --- Collect Instance IDs ---
  INSTANCE_IDS=$(jq -r '.cloned_instance_ids.value | join(" ")' < ../terraform/outputs.json 2>/dev/null || echo "")
  if [ -z "$INSTANCE_IDS" ]; then
    # Reset counts if no instances found, though EXPECTED should be 0 in this case
    RUNNING_COUNT=0
    PUBLIC_IP_COUNT=0
    SYSTEM_OK_COUNT=0
    INSTANCE_OK_COUNT=0
    SSM_PING_OK_COUNT=0
  else
    # --- Check EC2 Instance States, Public IPs, and Health Statuses ---

    # 1. Running State Count
    RUNNING_COUNT=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --query 'Reservations[*].Instances[*].State.Name' --output text 2>/dev/null | grep -c "running" || echo 0)

    # 2. Public IP Count
    PUBLIC_IP_COUNT=$(aws ec2 describe-instances --instance-ids $INSTANCE_IDS --query 'Reservations[*].Instances[*].PublicIpAddress' --output text 2>/dev/null | grep -c -v None || echo 0)

    # 3. System Status OK Count and 4. Instance Status OK Count
    INSTANCE_STATUSES=$(aws ec2 describe-instance-status --instance-ids $INSTANCE_IDS --query 'InstanceStatuses[*].[SystemStatus.Status, InstanceStatus.Status]' --output text 2>/dev/null)
    
    SYSTEM_OK_COUNT=$(echo "$INSTANCE_STATUSES" | awk '/ok/{system_ok++} END {print system_ok}' || echo 0)
    INSTANCE_OK_COUNT=$(echo "$INSTANCE_STATUSES" | awk '/ok/{instance_ok++} END {print instance_ok}' || echo 0)

    # 5. SSM Agent Ping Status OK Count (Real-time SSM readiness check)
    SSM_PING_OK_COUNT=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${INSTANCE_IDS// /\,}" --query 'InstanceInformationList[*].PingStatus' --output text 2>/dev/null | grep -c "Online" || echo 0)
  fi

  # --- Final Success Check ---
  if [ "$RUNNING_COUNT" -eq "$EXPECTED" ] && \
     [ "$PUBLIC_IP_COUNT" -eq "$EXPECTED" ] && \
     [ "$SYSTEM_OK_COUNT" -eq "$EXPECTED" ] && \
     [ "$INSTANCE_OK_COUNT" -eq "$EXPECTED" ] && \
     [ "$SSM_PING_OK_COUNT" -eq "$EXPECTED" ]; then
    
    echo "All checks passed:"
    echo "  - $RUNNING_COUNT/$EXPECTED running"
    echo "  - $PUBLIC_IP_COUNT/$EXPECTED public IPs"
    echo "  - $SYSTEM_OK_COUNT/$EXPECTED system status ok"
    echo "  - $INSTANCE_OK_COUNT/$EXPECTED instance status ok"
    echo "  - $SSM_PING_OK_COUNT/$EXPECTED SSM agent online"
    break
  fi

  # --- Waiting Message ---
  echo "Waiting:"
  echo "  - $RUNNING_COUNT/$EXPECTED running"
  echo "  - $PUBLIC_IP_COUNT/$EXPECTED public IPs"
  echo "  - $SYSTEM_OK_COUNT/$EXPECTED system status ok (or initializing)"
  echo "  - $INSTANCE_OK_COUNT/$EXPECTED instance status ok (or initializing)"
  echo "  - $SSM_PING_OK_COUNT/$EXPECTED SSM agent online"
  echo "Retrying in $WAIT_TIME seconds (Attempt $((RETRY_COUNT + 1)) of $MAX_RETRIES)..."
  
  sleep $WAIT_TIME
  ((RETRY_COUNT++))
done

# --- Timeout Check ---
if [ "$RETRY_COUNT" -eq "$MAX_RETRIES" ]; then
    echo "Timeout: Not all instances are fully initialized after $((MAX_RETRIES * WAIT_TIME)) seconds."
    echo "Final status:"
    echo "  - $RUNNING_COUNT/$EXPECTED running"
    echo "  - $PUBLIC_IP_COUNT/$EXPECTED public IPs"
    echo "  - $SYSTEM_OK_COUNT/$EXPECTED system status ok"
    echo "  - $INSTANCE_OK_COUNT/$EXPECTED instance status ok"
    echo "  - $SSM_PING_OK_COUNT/$EXPECTED SSM agent online"
    exit 1
fi

echo "All EC2 instances are fully initialized and ready for SSM."
exit 1