Complete AMI Creation Steps:
# 1. On your first VM, configure everything:
# - Install Python, Chrome, Git
# - Clone your repo to C:\Apps\browser-automation-launcher
# - Set up scheduled task
# - Test it works

# 2. Before creating AMI, clean up:
Stop-Process -Name python -Force -ErrorAction SilentlyContinue
Remove-Item C:\Apps\browser-automation-launcher\logs\* -Force

# 3. Go to AWS Console:
EC2 → Your Instance → Actions → Image and templates → Create image

# 4. Wait for AMI to be ready (10-15 min)

# 5. Launch new VMs:
EC2 → Launch Instance → My AMIs → Select your AMI → Launch
