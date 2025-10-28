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
    instances_file = os.path.join(os.path.dirname(__file__), 'instances.json')

    if not os.path.exists(instances_file):
        print(f"Error: {instances_file} not found. Run 'terraform output -json > instances.json' first.", file=sys.stderr)
        sys.exit(1)

    with open(instances_file, 'r') as f:
        outputs = json.load(f)

    # Extract instance IDs from Terraform output
    instance_ids = outputs.get('cloned_instance_ids', {}).get('value', [])

    # Ensure there are instance IDs to process
    if not instance_ids:
        print("No instance IDs found. Exiting.", file=sys.stderr)
        sys.exit(1)

    # Determine region (default to us-east-1 if not set)
    region = os.environ.get('AWS_REGION', os.environ.get('AWS_DEFAULT_REGION', 'us-east-1'))
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

                # Ensure that the instance has a valid Name and SSM access
                inventory['_meta']['hostvars'][iid] = {
                    'ansible_host': iid,  # with SSM we use instance ID directly
                    'ansible_aws_ssm_region': region,  # Ensure region is correct
                    'instance_name': name_tag
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
