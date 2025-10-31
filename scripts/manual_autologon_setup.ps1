# Safe AutoLogon + Interactive Logon Task Setup (for GUI Chrome)
# Run as Administrator on your EC2 instance once.

param(
  [string]$Username = "Administrator",
  [string]$TaskName = "BrowserAutomationStartup",
  [string]$TaskScript = "$env:USERPROFILE\Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1",
  [string]$Password = "bDwQrUQLDA*uEOvZqCB6ldG@$ea(JLC3",               # REQUIRED for AutoLogin safety
  [switch]$MakeUserAdmin = $true,
  [switch]$RunTaskNow = $true,
  [switch]$RebootWhenDone = $false
)

$ErrorActionPreference = "Stop"

# --- Validate ---
if ([string]::IsNullOrEmpty($Password)) {
  Write-Error "A password is required for safe AutoLogin. Blank passwords can cause login loops."
  exit 1
}

# --- Ensure User Exists ---
if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
  Write-Host "Creating local user $Username..."
  $sec = ConvertTo-SecureString $Password -AsPlainText -Force
  New-LocalUser -Name $Username -Password $sec -FullName "AutoLogin User" -Description "Used for AutoLogin GUI tasks"
  if ($MakeUserAdmin) { Add-LocalGroupMember -Group "Administrators" -Member $Username }
} else {
  Write-Host "User $Username exists. Updating password..."
  cmd /c "net user $Username $Password" | Out-Null
}
cmd /c "net user $Username /expires:never" | Out-Null
Set-LocalUser -Name $Username -PasswordNeverExpires $true

# --- Enable AutoLogin Safely ---
Write-Host "Configuring AutoAdminLogon for $Username..."
$reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
if (-not (Test-Path $reg)) { New-Item -Path $reg -Force | Out-Null }

Set-ItemProperty -Path $reg -Name 'AutoAdminLogon' -Type String -Value '1'
Set-ItemProperty -Path $reg -Name 'ForceAutoLogon' -Type String -Value '1'
Set-ItemProperty -Path $reg -Name 'DisableCAD' -Type DWord -Value 1
Set-ItemProperty -Path $reg -Name 'DefaultUserName' -Type String -Value $Username
Set-ItemProperty -Path $reg -Name 'DefaultPassword' -Type String -Value $Password
Set-ItemProperty -Path $reg -Name 'DefaultDomainName' -Type String -Value $env:COMPUTERNAME
Write-Host "AutoLogin enabled with password protection."

# --- Verify Task Script Exists ---
if (-not (Test-Path $TaskScript)) {
  throw "Task script not found: $TaskScript"
}

# --- Create Scheduled Task for GUI Chrome ---
Write-Host "Creating interactive logon task '$TaskName' for $Username..."
try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$TaskScript`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn -User $Username
$principal = New-ScheduledTaskPrincipal -UserId $Username -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
Write-Host "Interactive logon task created successfully."

# --- Optionally Run Task Now ---
if ($RunTaskNow) {
  try {
    schtasks /run /tn "$TaskName" | Out-Null
    Write-Host "Task '$TaskName' triggered manually."
  } catch { Write-Host "Could not trigger task now: $_" }
}

Write-Host "Setup complete: AutoLogin + Chrome interactive startup ready."

if ($RebootWhenDone) {
  Write-Host "Rebooting to apply AutoLogin..."
  Restart-Computer -Force
}
