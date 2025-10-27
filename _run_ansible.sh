#!/bin/bash

set -e

#########################################################
# Run Ansible Playbook
#########################################################

cd Iac/ansible

# Install Ansible + deps
python -m pip install --upgrade pip
pip install "ansible>=9" boto3 botocore
ansible-galaxy collection install amazon.aws community.aws ansible.windows community.windows

# Capture Terraform Outputs (instances.json)
cd ../terraform
terraform output -json > ../ansible/inventory/instances.json
cd ../ansible

# Load Ansible env (optional user run)
if [ -f .env.ansible ]; then
    set -a
    source .env.ansible
    set +a
fi

# Run Ansible Playbook (SSM)
chmod +x inventory/ec2.py
ansible-inventory -i inventory/ec2.py --graph
ansible-playbook -i inventory/ec2.py playbook.yml -vv

# Verify Deployment
cd ../terraform
terraform output
