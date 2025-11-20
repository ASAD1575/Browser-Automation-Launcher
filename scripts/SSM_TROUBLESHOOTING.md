# SSM Agent Troubleshooting Guide

If SSM Agent is installed but not showing in AWS Console, check these common issues:

## Quick Checks (Run via RDP)

### 1. Check SSM Service Status
```powershell
Get-Service AmazonSSMAgent
```

**Expected:** Status = Running, StartType = Automatic

**If not running:**
```powershell
Start-Service AmazonSSMAgent
Set-Service -Name AmazonSSMAgent -StartupType Automatic
```

---

### 2. Check IAM Role Permissions
```powershell
# Get IAM role name
Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/iam/security-credentials/" -Headers @{"X-aws-ec2-metadata-token"=(Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"})}
```

**Then in AWS Console:**
1. Go to **IAM → Roles → [Your Role Name]**
2. Ensure it has **`AmazonSSMManagedInstanceCore`** policy attached
3. If missing, attach it

---

### 3. Check SSM Agent Logs
```powershell
Get-Content C:\ProgramData\Amazon\SSM\Logs\amazon-ssm-agent.log -Tail 50
```

Look for errors like:
- `AccessDenied` - IAM permission issue
- `Connection timeout` - Network/firewall issue
- `Registration failed` - Instance registration issue

---

### 4. Check Network Connectivity
```powershell
# Get region
$region = (Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" -Headers @{"X-aws-ec2-metadata-token"=(Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"})})

# Test SSM endpoints
Test-NetConnection -ComputerName "ssm.$region.amazonaws.com" -Port 443
Test-NetConnection -ComputerName "ec2messages.$region.amazonaws.com" -Port 443
Test-NetConnection -ComputerName "ssmmessages.$region.amazonaws.com" -Port 443
```

**All should return `TcpTestSucceeded : True`**

If not, check Security Group allows outbound HTTPS (443) to AWS endpoints.

---

### 5. Wait for Registration
After installing/restarting SSM Agent, it can take **5-10 minutes** for the instance to appear in Systems Manager.

**Check registration:**
```powershell
# Check if configuration files exist
Get-ChildItem "C:\ProgramData\Amazon\SSM\InstanceData\registration" -ErrorAction SilentlyContinue
```

If files exist, registration is in progress or complete.

---

## Common Issues and Fixes

### Issue 1: Service Not Running
**Symptoms:** SSM Agent installed but service is stopped

**Fix:**
```powershell
Start-Service AmazonSSMAgent
Set-Service -Name AmazonSSMAgent -StartupType Automatic
```

---

### Issue 2: Missing IAM Permissions
**Symptoms:** Logs show "AccessDenied" errors

**Fix:**
1. Go to **IAM Console → Roles**
2. Find the role attached to your EC2 instance
3. Click **Add permissions → Attach policies**
4. Search for and attach: **`AmazonSSMManagedInstanceCore`**
5. Restart SSM Agent: `Restart-Service AmazonSSMAgent`

---

### Issue 3: Network/Firewall Blocking
**Symptoms:** Logs show connection timeouts

**Fix:**
1. Check Security Group allows outbound HTTPS (443) to:
   - `ssm.<region>.amazonaws.com`
   - `ec2messages.<region>.amazonaws.com`
   - `ssmmessages.<region>.amazonaws.com`
2. If using NACLs, ensure they allow outbound HTTPS

---

### Issue 4: Instance Not Registering
**Symptoms:** Service running, logs look OK, but instance not in console

**Fixes:**
1. **Wait 5-10 minutes** - Registration can take time
2. **Restart SSM Agent:**
   ```powershell
   Restart-Service AmazonSSMAgent
   ```
3. **Check if instance has IAM role attached:**
   - EC2 Console → Instance → Security → IAM role name (should be set)
4. **Reinstall SSM Agent** (last resort):
   ```powershell
   # Uninstall
   C:\Program Files\Amazon\SSM\uninstall.exe
   # Then reinstall using install_SSM_Agent.ps1
   ```

---

## Automated Diagnostic Script

Run the comprehensive diagnostic script:

```powershell
.\diagnose_and_fix_ssm.ps1
```

This script will:
- Check service status and fix if needed
- Review SSM Agent logs for errors
- Verify IAM role and permissions
- Test network connectivity
- Restart SSM Agent service
- Provide detailed recommendations

---

## Verification Commands

After fixing issues, verify SSM is working:

```powershell
# 1. Service status
Get-Service AmazonSSMAgent | Select Name, Status, StartType

# 2. Check logs for registration success
Get-Content C:\ProgramData\Amazon\SSM\Logs\amazon-ssm-agent.log -Tail 20 | Select-String "registration\|successfully\|registered"

# 3. Check instance registration files
Get-ChildItem "C:\ProgramData\Amazon\SSM\InstanceData\registration"

# 4. In AWS Console (after 5-10 minutes):
# Systems Manager → Fleet Manager → Managed Instances
# Your instance should appear with "Online" status
```

---

## Still Not Working?

1. **Check CloudWatch Logs** (if available) for additional errors
2. **Verify instance region** matches your Systems Manager setup
3. **Check if VPC endpoints** are required (for private subnets)
4. **Review SSM Agent version** - ensure it's up to date
5. **Contact AWS Support** with instance ID and SSM Agent logs

---

## Prevention

To avoid SSM issues in the future:

1. **Always attach IAM role** with `AmazonSSMManagedInstanceCore` policy when creating instances
2. **Use setup_login.ps1** in user data to automatically install and configure SSM Agent
3. **Verify security groups** allow outbound HTTPS (443) to AWS endpoints
4. **Wait 5-10 minutes** after instance creation before expecting SSM access

