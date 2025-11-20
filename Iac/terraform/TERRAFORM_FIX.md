# Terraform Error Fix: "collecting instance settings: couldn't find resource"

## Problem
The error `Error: collecting instance settings: couldn't find resource` occurs when Terraform tries to create an EC2 instance but cannot find the IAM instance profile.

## Root Cause
The IAM instance profile data source in `modules/IAM_role/main.tf` is trying to look up an instance profile that either:
1. Doesn't exist in AWS
2. Has a different name than the IAM role
3. Is in a different AWS account/region

## Solution

### Option 1: Verify Instance Profile Exists (Recommended)

1. **Check if the instance profile exists:**
   ```bash
   aws iam get-instance-profile --instance-profile-name ec2-browser-role
   ```

2. **If it doesn't exist, create it:**
   ```bash
   aws iam create-instance-profile --instance-profile-name ec2-browser-role
   aws iam add-role-to-instance-profile \
     --instance-profile-name ec2-browser-role \
     --role-name ec2-browser-role
   ```

3. **Verify the instance profile is attached to the role:**
   ```bash
   aws iam get-instance-profile --instance-profile-name ec2-browser-role
   ```

### Option 2: Update Variable to Use Correct Instance Profile Name

If your instance profile has a different name, update the variable in your Terraform configuration:

```hcl
# In terraform.tfvars or environment variables
existing_iam_role_name = "your-actual-instance-profile-name"
```

### Option 3: Make Instance Profile Optional (If Not Required)

If SSM access is not required, you can make the instance profile optional by updating `main.tf`:

```hcl
module "cloned_instance" {
  # ... other variables ...
  iam_instance_profile = var.existing_iam_role_name != "" ? module.IAM_role.instance_profile_name : null
}
```

## Verification Steps

1. **List all instance profiles:**
   ```bash
   aws iam list-instance-profiles --query 'InstanceProfiles[*].InstanceProfileName'
   ```

2. **Check if role exists:**
   ```bash
   aws iam get-role --role-name ec2-browser-role
   ```

3. **Verify instance profile is attached to role:**
   ```bash
   aws iam get-instance-profile --instance-profile-name ec2-browser-role \
     --query 'InstanceProfile.Roles[*].RoleName'
   ```

## Common Issues

### Issue 1: Instance Profile Name Doesn't Match Role Name
- **Symptom**: Data source lookup fails
- **Fix**: Ensure instance profile name matches the role name, or update the variable

### Issue 2: Instance Profile Not Attached to Role
- **Symptom**: Instance profile exists but role is not attached
- **Fix**: Run `aws iam add-role-to-instance-profile`

### Issue 3: Wrong AWS Region
- **Symptom**: Resources not found
- **Fix**: Ensure Terraform is using the correct AWS region

### Issue 4: Insufficient Permissions
- **Symptom**: Access denied errors
- **Fix**: Ensure the IAM user/role running Terraform has `iam:GetInstanceProfile` permission

## Testing the Fix

After applying the fix, run:

```bash
cd Iac/terraform
terraform init
terraform plan
```

If the instance profile is found, you should see it in the plan output. If not, you'll get a clear error message indicating what's missing.

