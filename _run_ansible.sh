#!/bin/bash

set -e

#########################################################
# Install Terraform if not installed
#########################################################

# Check if Terraform is installed
if ! command -v terraform &> /dev/null
then
    echo "Terraform not found, installing..."
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
    sudo apt-add-repository "deb https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    sudo apt-get update && sudo apt-get install terraform
else
    echo "Terraform is already installed."
fi

#########################################################
# Run Ansible Playbook
#########################################################

cd Iac/ansible

# Install Ansible + deps
echo "Installing Ansible and dependencies..."
python -m pip install --upgrade pip
pip install "ansible>=9" boto3 botocore
ansible-galaxy collection install amazon.aws community.aws ansible.windows community.windows

# Capture Terraform Outputs (instances.json)
cd ../terraform

echo "Capturing Terraform outputs for Ansible inventory..."
terraform output -json > ../ansible/inventory/instances.json
# Also save outputs to use for SSM readiness check
terraform output -json > outputs.json
cd ../ansible

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
  EXPECTED=$(jq '.cloned_instance_ids.value | length' < ../terraform/outputs.json 2>/dev/null || echo 0)
  if [ "$EXPECTED" -gt 0 ] && [ "$READY" -ge "$EXPECTED" ]; then
    echo "SSM shows $READY/$EXPECTED Online"
    break
  fi
  echo "$READY/$EXPECTED Online — retrying in 15s..."
  sleep 15
done

#########################################################
# Run Ansible Playbook (SSM)
#########################################################
chmod +x inventory/ec2.py
echo "Running Ansible playbook..."
ansible-inventory -i inventory/ec2.py --graph
ansible-playbook -i inventory/ec2.py playbook.yml -vv

# Verify Deployment
echo "Verifying deployment by fetching Terraform outputs..."
cd ../terraform
terraform output
