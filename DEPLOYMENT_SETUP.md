# Staging Deployment Setup Guide

This guide walks you through setting up automated deployment from GitHub to AWS EC2 Windows machines.

## Overview

When code is pushed to the `staging` branch:
1. GitHub Actions runs the Ruff linter
2. If linting passes, it connects to each EC2 server via SSH
3. Stops the running application
4. Pulls the latest code
5. Restarts the application

---

## Prerequisites

- AWS EC2 Windows instances running
- Administrator access to the EC2 instances
- GitHub repository admin access (to add secrets)
- Git installed on all EC2 instances
- Poetry installed on all EC2 instances

---

## Part 1: Generate SSH Key Pair (Do This Once)

You need an SSH key pair to authenticate GitHub Actions with your EC2 servers.

### Step 1.1: Generate SSH Key on Your Local Machine

Open terminal (Mac/Linux) or Git Bash (Windows) and run:

```bash
ssh-keygen -t rsa -b 4096 -C "github-actions-deploy" -f ~/.ssh/github_actions_key
```

When prompted for a passphrase, press Enter (leave empty).

This creates two files:
- `~/.ssh/github_actions_key` - **Private key** (for GitHub Secrets)
- `~/.ssh/github_actions_key.pub` - **Public key** (for EC2 servers)

### Step 1.2: View Your Keys

```bash
# View private key (you'll need this for GitHub)
cat ~/.ssh/github_actions_key

# View public key (you'll need this for EC2)
cat ~/.ssh/github_actions_key.pub
```

**Important:** Keep the private key secure. Never share it publicly.

---

## Part 2: Configure Each EC2 Windows Server

Repeat these steps for **each EC2 server** you want to deploy to.

### Step 2.1: Connect to Your EC2 Instance

Use RDP (Remote Desktop) to connect to your EC2 Windows instance.

### Step 2.2: Install OpenSSH Server

Open **PowerShell as Administrator** and run:

```powershell
# Install OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Start the SSH service
Start-Service sshd

# Set SSH to start automatically on boot
Set-Service -Name sshd -StartupType 'Automatic'

# Verify SSH is running
Get-Service sshd
```

You should see:
```
Status   Name               DisplayName
------   ----               -----------
Running  sshd               OpenSSH SSH Server
```

### Step 2.3: Configure Windows Firewall

```powershell
# Check if firewall rule exists
Get-NetFirewallRule -Name *ssh*

# If no rule exists, create one
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

### Step 2.4: Add Public Key to EC2 Server

```powershell
# Create .ssh directory (if it doesn't exist)
New-Item -ItemType Directory -Force -Path C:\Users\Administrator\.ssh

# Create/edit authorized_keys file
notepad C:\Users\Administrator\.ssh\authorized_keys
```

In Notepad:
1. Paste the **public key** content (from `github_actions_key.pub`)
2. Save and close

### Step 2.5: Configure SSH for Administrator Account

```powershell
# Open SSH config file
notepad C:\ProgramData\ssh\sshd_config
```

Find these lines at the **bottom** of the file:
```
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

Comment them out by adding `#` at the start:
```
#Match Group administrators
#       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

Save and close.

### Step 2.6: Set File Permissions

```powershell
# Set correct permissions on authorized_keys
icacls C:\Users\Administrator\.ssh\authorized_keys /inheritance:r /grant "Administrator:F" /grant "SYSTEM:F"
```

### Step 2.7: Restart SSH Service

```powershell
Restart-Service sshd
```

### Step 2.8: Configure AWS Security Group

1. Go to **AWS Console** → **EC2** → **Security Groups**
2. Find the security group attached to your EC2 instance
3. Click **Edit inbound rules**
4. Add a new rule:
   - **Type:** SSH
   - **Protocol:** TCP
   - **Port:** 22
   - **Source:** `0.0.0.0/0` (or restrict to [GitHub Actions IPs](https://api.github.com/meta) for better security)
5. Click **Save rules**

### Step 2.9: Test SSH Connection

From your local machine, test the connection:

```bash
ssh -i ~/.ssh/github_actions_key Administrator@<EC2-PUBLIC-IP>
```

If successful, you'll see a Windows command prompt. Type `exit` to disconnect.

---

## Part 3: Setup Git on EC2 Servers

On each EC2 server, ensure Git is configured:

### Step 3.1: Install Git (if not installed)

Download and install from: https://git-scm.com/download/win

### Step 3.2: Clone the Repository

```powershell
# Navigate to the application directory
cd C:\Users\Administrator\Documents\Applications

# Clone the repository (first time only)
git clone https://github.com/YOUR_ORG/browser-automation-launcher.git

# Or if using SSH
git clone git@github.com:YOUR_ORG/browser-automation-launcher.git
```

### Step 3.3: Configure Git Credentials

For HTTPS (recommended for automated pulls):

```powershell
# Store credentials
git config --global credential.helper store

# Do a manual pull once to save credentials
cd browser-automation-launcher
git pull
# Enter your GitHub username and Personal Access Token when prompted
```

**Note:** Use a GitHub Personal Access Token (PAT) instead of password. Create one at: GitHub → Settings → Developer settings → Personal access tokens

---

## Part 4: Install Poetry on EC2 Servers

On each EC2 server:

### Step 4.1: Install Poetry

Open PowerShell and run:

```powershell
(Invoke-WebRequest -Uri https://install.python-poetry.org -UseBasicParsing).Content | python -
```

### Step 4.2: Add Poetry to PATH

```powershell
# Add to PATH for current session
$env:Path += ";C:\Users\Administrator\AppData\Roaming\Python\Scripts"

# Add to PATH permanently
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Users\Administrator\AppData\Roaming\Python\Scripts", "User")
```

### Step 4.3: Verify Installation

```powershell
poetry --version
```

### Step 4.4: Install Project Dependencies

```powershell
cd C:\Users\Administrator\Documents\Applications\browser-automation-launcher
poetry install
```

---

## Part 5: Configure GitHub Secrets

### Step 5.1: Navigate to Repository Settings

1. Go to your GitHub repository
2. Click **Settings** tab
3. Click **Secrets and variables** → **Actions**
4. Click **New repository secret**

### Step 5.2: Add Secrets for Each Server

For **Server 1**, add these secrets:

| Secret Name | Value |
|-------------|-------|
| `EC2_HOST_1` | Public IP or hostname of EC2 Server 1 (e.g., `52.123.45.67`) |
| `EC2_USERNAME_1` | `Administrator` |
| `EC2_SSH_PRIVATE_KEY_1` | Entire content of `~/.ssh/github_actions_key` (private key) |
| `APP_DIRECTORY_1` | `C:\Users\Administrator\Documents\Applications\browser-automation-launcher` |

For **Server 2**, add:

| Secret Name | Value |
|-------------|-------|
| `EC2_HOST_2` | Public IP of EC2 Server 2 |
| `EC2_USERNAME_2` | `Administrator` |
| `EC2_SSH_PRIVATE_KEY_2` | Private key (same or different key) |
| `APP_DIRECTORY_2` | Application path on Server 2 |

For **Server 3**, add:

| Secret Name | Value |
|-------------|-------|
| `EC2_HOST_3` | Public IP of EC2 Server 3 |
| `EC2_USERNAME_3` | `Administrator` |
| `EC2_SSH_PRIVATE_KEY_3` | Private key (same or different key) |
| `APP_DIRECTORY_3` | Application path on Server 3 |

**Tip:** If all servers use the same SSH key, you can use the same private key content for all `EC2_SSH_PRIVATE_KEY_*` secrets.

### Step 5.3: How to Copy Private Key

```bash
# On Mac/Linux
cat ~/.ssh/github_actions_key | pbcopy  # Copies to clipboard (Mac)

# On Windows (Git Bash)
cat ~/.ssh/github_actions_key | clip

# Or just display and manually copy
cat ~/.ssh/github_actions_key
```

Copy **everything** including:
```
-----BEGIN OPENSSH PRIVATE KEY-----
...
-----END OPENSSH PRIVATE KEY-----
```

---

## Part 6: Update Workflow for Your Servers

Edit `.github/workflows/deploy-staging.yml` to match your server count.

### If you have 2 servers:

Remove the Server 3 entry from the matrix:

```yaml
matrix:
  server:
    - name: EC2-Server-1
      host: EC2_HOST_1
      username: EC2_USERNAME_1
      key: EC2_SSH_PRIVATE_KEY_1
      app_dir: APP_DIRECTORY_1
    - name: EC2-Server-2
      host: EC2_HOST_2
      username: EC2_USERNAME_2
      key: EC2_SSH_PRIVATE_KEY_2
      app_dir: APP_DIRECTORY_2
```

### If you have 5 servers:

Add more entries following the same pattern.

---

## Part 7: Test the Deployment

### Step 7.1: Make a Test Commit

```bash
# Make sure you're on staging branch
git checkout staging

# Make a small change (e.g., add a comment)
echo "# Test deployment" >> README.md

# Commit and push
git add .
git commit -m "Test staging deployment"
git push origin staging
```

### Step 7.2: Monitor the Workflow

1. Go to your GitHub repository
2. Click **Actions** tab
3. Click on the running workflow
4. Watch the logs for each job

### Step 7.3: Verify Deployment

SSH into each server and verify:

```powershell
cd C:\Users\Administrator\Documents\Applications\browser-automation-launcher
git log -1  # Should show your test commit
```

---

## Troubleshooting

### SSH Connection Refused

1. Verify SSH service is running: `Get-Service sshd`
2. Check Windows Firewall allows port 22
3. Check AWS Security Group allows port 22
4. Verify the public key is in `authorized_keys`

### Permission Denied (publickey)

1. Ensure `authorized_keys` file has correct permissions
2. Verify the private key in GitHub Secrets is complete (including headers)
3. Check `sshd_config` administrator lines are commented out
4. Restart SSH service after changes

### Git Pull Fails

1. Verify Git credentials are stored on the server
2. Check the repository URL is correct
3. Ensure the `staging` branch exists remotely

### Poetry Not Found

1. Verify Poetry is in PATH
2. Run deployment commands in a new PowerShell session
3. Use full path: `C:\Users\Administrator\AppData\Roaming\Python\Scripts\poetry.exe`

### Scheduled Task Issues

1. Verify task exists: `schtasks /query /tn "BrowserAutomationStartup"`
2. Check task is configured correctly
3. Run task manually to test: `schtasks /run /tn "BrowserAutomationStartup"`

---

## Security Best Practices

1. **Rotate SSH keys** periodically
2. **Restrict Security Group** to GitHub Actions IP ranges only
3. **Use separate keys** for each environment (staging/production)
4. **Never commit secrets** to the repository
5. **Use GitHub Environments** for additional protection (require approvals)

---

## Quick Reference

### GitHub Secrets Checklist

For each server (N = 1, 2, 3, ...):
- [ ] `EC2_HOST_N`
- [ ] `EC2_USERNAME_N`
- [ ] `EC2_SSH_PRIVATE_KEY_N`
- [ ] `APP_DIRECTORY_N`

### EC2 Server Checklist

For each server:
- [ ] OpenSSH Server installed and running
- [ ] SSH set to start automatically
- [ ] Windows Firewall allows port 22
- [ ] AWS Security Group allows port 22
- [ ] Public key added to `authorized_keys`
- [ ] `sshd_config` modified for Administrator
- [ ] Git installed and configured
- [ ] Repository cloned
- [ ] Poetry installed
- [ ] Dependencies installed
- [ ] Scheduled task configured

---

## Support

If you encounter issues:
1. Check the GitHub Actions logs for error messages
2. SSH manually to the server to test commands
3. Review the troubleshooting section above
