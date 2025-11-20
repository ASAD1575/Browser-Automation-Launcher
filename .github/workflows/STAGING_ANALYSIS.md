# Staging.yml Workflow Analysis

## 🔴 Critical Issues

### 1. **Workflow Dispatch Won't Work**
**Line 27**: The job condition only allows `push` events:
```yaml
if: github.event_name == 'push' && github.ref == 'refs/heads/staging'
```

**Problem**: `workflow_dispatch` is defined in triggers (line 10), but the job will never run for manual dispatch because of this condition.

**Impact**: Manual workflow runs will be skipped.

**Fix**: Update condition to allow both push and workflow_dispatch:
```yaml
if: |
  (github.event_name == 'push' && github.ref == 'refs/heads/staging') ||
  github.event_name == 'workflow_dispatch'
```

### 2. **Command Script Empty on Push Events**
**Line 77**: 
```yaml
COMMAND_SCRIPT="${{ github.event.inputs.command_to_run }}"
```

**Problem**: On push events, `github.event.inputs.command_to_run` will be empty/null, causing the SSM command to fail or do nothing.

**Impact**: Push-triggered runs will execute an empty command.

**Fix**: Provide a default command for push events:
```yaml
COMMAND_SCRIPT="${{ github.event.inputs.command_to_run || 'cd C:\Users\ticketboat\Documents\Applications\browser-automation-launcher; New-Item -ItemType File -Path \"C:\Users\ticketboat\Documents\Applications\browser-automation-launcher\logs\STOP\" -Force; Stop-Process -Name python -Force -ErrorAction SilentlyContinue; git pull origin staging; schtasks /run /tn \"BrowserAutomationStartup\"' }}"
```

### 3. **Multi-line PowerShell Script Format Issue**
**Line 87**: 
```yaml
--parameters commands="$COMMAND_SCRIPT"
```

**Problem**: SSM `AWS-RunPowerShellScript` expects commands as a JSON array of strings. Multi-line scripts need proper formatting.

**Impact**: Multi-line PowerShell scripts may not execute correctly.

**Fix**: Convert to JSON array format:
```yaml
# Convert multi-line script to JSON array
COMMAND_JSON=$(echo "$COMMAND_SCRIPT" | jq -R -s 'split("\n") | map(select(length > 0))')
--parameters "{\"commands\":$COMMAND_JSON}"
```

### 4. **Only Checks First Instance**
**Line 95**: 
```yaml
aws ssm wait command-executed --command-id $COMMAND_ID --instance-id $(echo ${{ steps.instance_lookup.outputs.instance_ids }} | jq -r '.[0]')
```

**Problem**: Only waits for the first instance. Other instances may still be running or may have failed.

**Impact**: Workflow may complete before all instances finish, or failures on other instances go unnoticed.

**Fix**: Wait for all instances and check status of each:
```yaml
# Wait for all instances
for INSTANCE_ID in $(echo ${{ steps.instance_lookup.outputs.instance_ids }} | jq -r '.[]'); do
  echo "Waiting for instance $INSTANCE_ID..."
  aws ssm wait command-executed --command-id $COMMAND_ID --instance-id $INSTANCE_ID || true
done

# Check status of all instances
for INSTANCE_ID in $(echo ${{ steps.instance_lookup.outputs.instance_ids }} | jq -r '.[]'); do
  STATUS=$(aws ssm get-command-invocation --command-id $COMMAND_ID --instance-id $INSTANCE_ID --query 'Status' --output text)
  if [ "$STATUS" != "Success" ]; then
    echo "::error::Command failed on instance $INSTANCE_ID with status $STATUS"
    aws ssm get-command-invocation --command-id $COMMAND_ID --instance-id $INSTANCE_ID
    exit 1
  fi
done
```

## ⚠️ Medium Priority Issues

### 5. **Unused Input Parameter**
**Line 12-14**: `environment` input is defined but never used.

**Fix**: Either remove it or use it to filter instances by environment tag.

### 6. **Hardcoded Instance Names**
**Line 34**: 
```yaml
INSTANCE_NAMES: "Browser Automation Launcher,Browser Automation Launcher-1,Browser Automation Launcher-2"
```

**Problem**: Instance names are hardcoded. If instances are added/removed, the workflow needs manual updates.

**Fix**: Use GitHub variables or Terraform outputs:
```yaml
env:
  INSTANCE_NAMES: "${{ vars.STAGING_INSTANCE_NAMES || 'Browser Automation Launcher' }}"
```

Or better, query instances by tag:
```yaml
--filters "Name=tag:Environment,Values=staging" "Name=instance-state-name,Values=running"
```

### 7. **Pull Request Trigger Not Handled**
**Line 7-9**: Pull requests are defined in triggers, but the job condition (line 27) doesn't allow PR events.

**Fix**: Either remove PR trigger or add PR handling (e.g., for validation only).

### 8. **No Error Handling for SSM Command**
**Line 84-88**: If `send-command` fails, the workflow continues and may fail later.

**Fix**: Add error checking:
```yaml
COMMAND_ID=$(aws ssm send-command ...)
if [ -z "$COMMAND_ID" ]; then
  echo "::error::Failed to send SSM command"
  exit 1
fi
```

### 9. **Missing Output for All Instances**
**Line 97-102**: Only shows output for the first instance.

**Fix**: Loop through all instances to show output:
```yaml
for INSTANCE_ID in $(echo ${{ steps.instance_lookup.outputs.instance_ids }} | jq -r '.[]'); do
  echo "--- Output for instance $INSTANCE_ID ---"
  aws ssm get-command-invocation --command-id $COMMAND_ID --instance-id $INSTANCE_ID --query 'StandardOutputContent' --output text
  echo "----------------------------------------"
done
```

## 💡 Recommendations

### 10. **Add Timeout**
SSM commands can hang. Add a timeout:
```yaml
timeout-minutes: 10
```

### 11. **Add Environment Tag Filter**
Instead of hardcoded names, filter by environment tag:
```yaml
--filters "Name=tag:Environment,Values=staging" "Name=tag:Name,Values=${NAMES_ARRAY}" "Name=instance-state-name,Values=running"
```

### 12. **Separate Jobs for Push vs Manual**
Consider having separate jobs:
- One for push events (with default deployment command)
- One for workflow_dispatch (with custom command)

### 13. **Add Validation Step**
Before executing commands, validate that instances are SSM-ready:
```yaml
- name: Verify SSM Connectivity
  run: |
    for INSTANCE_ID in $(echo ${{ steps.instance_lookup.outputs.instance_ids }} | jq -r '.[]'); do
      STATUS=$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE_ID" --query 'InstanceInformationList[0].PingStatus' --output text)
      if [ "$STATUS" != "Online" ]; then
        echo "::error::Instance $INSTANCE_ID is not SSM-ready (status: $STATUS)"
        exit 1
      fi
    done
```

## ✅ What's Good

1. ✅ Proper AWS credentials configuration with OIDC
2. ✅ Good use of jq for JSON parsing
3. ✅ Instance lookup by name tag
4. ✅ Proper permissions setup
5. ✅ Error handling for no instances found

## 📝 Suggested Fixed Version

See the corrected workflow file with all fixes applied.

