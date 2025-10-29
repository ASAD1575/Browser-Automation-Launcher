#!/usr/bin/env python3
"""
Dynamic inventory script for Ansible.
- Reads instance IDs from Terraform `instances.json`.
- Mimics behavior of aws_ec2 inventory plugin for "Browser*" instances.
- Groups all Windows hosts under [windows] and filters Name tags for Browser instances.
"""

import json
import sys
import os
import boto3

def get_instances():
    # File is now expected to be at the same level as ec2.py's parent directory
    instances_file = os.path.join(os.path.dirname(__file__), 'instances.json')
    
    # Check for the file (it is now copied by _run_ansible.sh from the artifact)
    if not os.path.exists(instances_file):
        # Fallback path to check the expected location of the artifact file
        parent_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
        tf_dir = os.path.join(parent_dir, 'terraform')
        tf_outputs = os.path.join(tf_dir, 'tf_output.json') # The artifact name
        
        # If the expected copy doesn't exist, check the artifact location
        if os.path.exists(tf_outputs):
             instances_file = tf_outputs
        else:
            print(f"Error: Required outputs file not found in expected locations: {instances_file} or {tf_outputs}.", file=sys.stderr)
            sys.exit(1)

    with open(instances_file, 'r') as f:
        outputs = json.load(f)

    # Extract instance IDs from Terraform output
    # Note: Terraform output structures often have a 'value' key if it's not a primitive type.
    instance_ids = outputs.get('cloned_instance_ids', {}).get('value', [])

    # Ensure there are instance IDs to process
    if not instance_ids:
        # This will now return an empty inventory structure, which is acceptable
        return {
            '_meta': { 'hostvars': {} },
            'all': { 'hosts': [] },
            'windows': { 'hosts': [] }
        }

    # Determine region (default to us-east-1 if not set)
    # The AWS_REGION/AWS_DEFAULT_REGION is set by the GitHub Actions step
    region = os.environ.get('AWS_REGION', os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
    
    # Initialize EC2 client
    ec2 = boto3.client('ec2', region_name=region)

    # Describe instances to get tags (e.g., Name)
    response = ec2.describe_instances(InstanceIds=instance_ids)
    reservations = response.get('Reservations', [])

    inventory = {
        '_meta': {
            'hostvars': {}
        },
        'all': {
            'hosts': []
        },
        'windows': {
            'hosts': []
        }
    }

    for reservation in reservations:
        for instance in reservation.get('Instances', []):
            iid = instance['InstanceId']
            name_tag = next((t['Value'] for t in instance.get('Tags', []) if t['Key'] == 'Name'), None)

            # Match "Browser*" like aws_ec2.yml filter
            if name_tag and name_tag.lower().startswith("browser"):
                inventory['all']['hosts'].append(iid)
                inventory['windows']['hosts'].append(iid)

                # Configure hostvars for WinRM/Windows connectivity
                inventory['_meta']['hostvars'][iid] = {
                    'ansible_host': instance['PublicIpAddress'],  # Use public IP for WinRM
                    'ansible_connection': 'winrm',  # Set connection to use WinRM
                    'ansible_winrm_transport': 'basic',  # Use basic auth
                    'ansible_winrm_scheme': 'http',  # Use HTTP instead of HTTPS
                    'ansible_winrm_server_cert_validation': 'ignore',  # Ignore SSL cert validation
                    'ansible_winrm_port': 5985,  # HTTP port for WinRM
                    'ansible_user': 'Administrator',  # Windows admin user
                    'ansible_password': os.environ.get('TF_VAR_WINDOWS_PASSWORD', ''),  # Password from env
                    'instance_name': name_tag,
                    # --- CRUCIAL ADDITIONS FOR WINDOWS/WINRM ---
                    'ansible_shell_type': 'powershell',
                    'ansible_shell_executable': 'powershell.exe'
                }

    return inventory

if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == '--list':
        print(json.dumps(get_instances(), indent=2))
    elif len(sys.argv) == 3 and sys.argv[1] == '--host':
        # We already store everything in _meta
        print(json.dumps({}))
    else:
        print(f"Usage: {sys.argv[0]} --list or --host <hostname>")
        sys.exit(1)
