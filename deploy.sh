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
if [[ "${ENVIRONMENT}" != "dev" && "${ENVIRONMENT}" != "staging" && "${ENVIRONMENT}" != "prod" ]]; then
  echo "Invalid environment: ${ENVIRONMENT}. Allowed values are 'dev', 'staging', or 'prod'."
  exit 1
fi

echo "ENVIRONMENT: ${ENVIRONMENT}"
echo "FLAG_DESTROY: ${FLAG_DESTROY}"

#########################################################
# Configure Environment
#########################################################

# Source the global variables first
echo "Sourcing .env.global for global variables..."
source .env.global

# Dynamically source the environment-specific `.env` file
if [ "${ENVIRONMENT}" == "prod" ]; then
    echo "Sourcing .env.prod.terraform for production..."
    source .env.prod.terraform
elif [ "${ENVIRONMENT}" == "staging" ]; then
    echo "Sourcing .env.staging.terraform for staging..."
    source .env.staging.terraform
else
    echo "Sourcing .env.dev.terraform for development..."
    source .env.dev.terraform
fi

# Export environment variables (if needed)
export APP_IDENT="${APP_IDENT_WITHOUT_ENV}-${ENVIRONMENT}"
export TERRAFORM_STATE_IDENT=$APP_IDENT

echo "Terraform state identifier: ${TERRAFORM_STATE_IDENT}"

####################################################################################################
# Run Terraform
####################################################################################################
if [ "$FLAG_DESTROY" = true ] ; then
    echo "Destroying resources..."
    bash ./_run_terraform_destroy.sh
else
    echo "Creating resources..."
    bash ./_run_terraform_create.sh
fi

# Ensure the `terraform apply` has completed successfully
if [ $? -ne 0 ]; then
    echo "Terraform apply failed, skipping Ansible."
    exit 1
fi

####################################################################################################
# Run Ansible (only if resources were successfully created)
####################################################################################################
if [ "$FLAG_DESTROY" = false ] ; then
    echo "Running Ansible playbook..."
    bash ./_run_ansible.sh
else
    echo "Skipping Ansible playbook as destroy flag is set."
fi
