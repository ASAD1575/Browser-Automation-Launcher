#!/bin/bash

set -e

####################################################################################################
# Check if Docker is running
####################################################################################################
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Please start Docker and try again."
  exit 1
fi

####################################################################################################
# Determine Flags
####################################################################################################
while getopts "d" opt; do
  case ${opt} in
  d)
    export FLAG_DESTROY=true
    ;;
  \?)
    echo "Invalid option: -$OPTARG" 1>&2
    exit 1
    ;;
  esac
done
shift $((OPTIND - 1))

####################################################################################################
# Determine Environment
####################################################################################################
# If the provided environment is not one of the allowed values, exit the script
if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "staging" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Invalid environment: ${ENVIRONMENT}. Allowed values are 'dev', 'staging', or 'prod'."
  exit 1
fi

echo "ENVIRONMENT: ${ENVIRONMENT}"
echo "FLAG_DESTROY: ${FLAG_DESTROY}"

#########################################################
# Configure Environment
#########################################################

echo $BITBUCKET_STEP_OIDC_TOKEN > $(pwd)/web-identity-token

source .env.global
source ".env.${ENVIRONMENT}.terraform"

export APP_IDENT="${APP_IDENT_WITHOUT_ENV}-${ENVIRONMENT}"
# Terraform state identifier (must be unique) | allowed characters: a-zA-Z0-9-_
# NOTE: This can often be the same as the APP_IDENT
export TERRAFORM_STATE_IDENT=$APP_IDENT

# Set Terraform variables from environment
export TF_VAR_aws_region=${AWS_DEFAULT_REGION}
export TF_VAR_key_pair_name=${key_pair_name}
export TF_VAR_terraform_state_bucket=${TERRAFORM_STATE_BUCKET}
export TF_VAR_clone_instance_name=${clone_instance_name}
export TF_VAR_cloned_instance_type=${cloned_instance_type}
export TF_VAR_cloned_instance_count=${cloned_instance_count}
export TF_VAR_env=${env}
export TF_VAR_existing_security_group_name=${existing_security_group_name}
export TF_VAR_existing_iam_role_name=${existing_iam_role_name}

####################################################################################################
# Run Terraform
####################################################################################################
if [ "$FLAG_DESTROY" = true ] ; then
    bash ./_run_terraform_destroy.sh
else
    bash ./_run_terraform_create.sh
fi

####################################################################################################
# Run Ansible
####################################################################################################
if [ "$FLAG_DESTROY" = false ] ; then
    bash ./_run_ansible.sh
fi
