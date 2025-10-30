# Manual Autologon + Interactive Logon Task Setup (for GUI Chrome)
# Run as Administrator in PowerShell on the instance to test end-to-end.

param(
  [string]$Username = "ticketboat",
  [string]$TaskName = "BrowserAutomationStartup",
  [string]$TaskScript = "$env:USERPROFILE\Documents\Applications\browser-automation-launcher\scripts\simple_startup.ps1",
  [switch]$AllowBlankPassword = $true,
  [string]$Password = "",             # optional; if provided, overrides blank password
  [switch]$MakeUserAdmin = $true,
  [switch]$RunTaskNow = $true,
  [switch]$RebootWhenDone = $false
)

$ErrorActionPreference = "Stop"

function Ensure-User {
  if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
    if ($AllowBlankPassword -and [string]::IsNullOrEmpty($Password)) {
      Write-Host "Creating local user $Username with BLANK password..."
      New-LocalUser -Name $Username -NoPassword
    } else {
      if ([string]::IsNullOrEmpty($Password)) {
        throw "Password not provided and AllowBlankPassword is false. Provide -Password or enable -AllowBlankPassword."
      }
      Write-Host "Creating local user $Username with provided password..."
      $sec = ConvertTo-SecureString $Password -AsPlainText -Force
      New-LocalUser -Name $Username -Password $sec
    }
  } else {
    if ($AllowBlankPassword -and [string]::IsNullOrEmpty($Password)) {
      Write-Host "Ensuring user $Username has BLANK password..."
      cmd /c "net user $Username """ | Out-Null
    } elseif (-not [string]::IsNullOrEmpty($Password)) {
      Write-Host "Updating password for $Username..."
      cmd /c "net user $Username $Password" | Out-Null
    }
  }

  try { Set-LocalUser -Name $Username -PasswordNeverExpires $true } catch {}
  cmd /c "net user $Username /expires:never" | Out-Null
  if ($MakeUserAdmin) { try { Add-LocalGroupMember -Group "Administrators" -Member $Username } catch {} }
}

function Relax-LocalPasswordPolicyIfBlank {
  if (-not $AllowBlankPassword -or -not [string]::IsNullOrEmpty($Password)) { return }
  Write-Host "Relaxing local password policy for blank password..."
  $temp = Join-Path $env:TEMP "secpol.inf"
  secedit /export /cfg $temp | Out-Null
  $content = Get-Content $temp -Encoding ASCII
  if ($content -notmatch '^\s*\[System Access\]\s*$') { $content = @('[System Access]') + $content }
  $content = $content `
    -replace 'PasswordComplexity\s*=\s*\d', 'PasswordComplexity = 0' `
    -replace 'MinimumPasswordLength\s*=\s*\d+', 'MinimumPasswordLength = 0'
  $content | Set-Content $temp -Encoding ASCII
  secedit /configure /db C:\Windows\Security\Local.sdb /cfg $temp /areas SECURITYPOLICY | Out-Null
  gpupdate /force | Out-Null
}

function Allow-BlankPasswordLoginIfBlank {
  if (-not $AllowBlankPassword -or -not [string]::IsNullOrEmpty($Password)) { return }
  Write-Host "Allowing blank-password logon and removing blockers..."
  if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa')) {
    New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'Lsa' -Force | Out-Null
  }
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -PropertyType DWord -Value 0 -Force | Out-Null

  if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')) {
    if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies')) {
      New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion' -Name 'Policies' -Force | Out-Null
    }
    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies' -Name 'System' -Force | Out-Null
  }
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DisableCAD' -PropertyType DWord -Value 1 -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'legalnoticecaption' -PropertyType String -Value '' -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'legalnoticetext' -PropertyType String -Value '' -Force | Out-Null
}

function Enable-AutoLogon {
  Write-Host "Configuring AutoAdminLogon for $Username..."
  $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

  if (-not (Test-Path $reg)) {
      New-Item -Path $reg -Force | Out-Null
  }

  Set-ItemProperty -Path $reg -Name 'AutoAdminLogon' -Type String -Value '1'
  Set-ItemProperty -Path $reg -Name 'ForceAutoLogon' -Type String -Value '1'
  Set-ItemProperty -Path $reg -Name 'DisableCAD' -Type DWord -Value 1
  Set-ItemProperty -Path $reg -Name 'DefaultUserName' -Type String -Value $Username
  $pwdToStore = if ([string]::IsNullOrEmpty($Password)) { '' } else { $Password }
  Set-ItemProperty -Path $reg -Name 'DefaultPassword' -Type String -Value $pwdToStore
  Set-ItemProperty -Path $reg -Name 'DefaultDomainName' -Type String -Value $env:COMPUTERNAME
}

function Ensure-TaskScript {
  if (-not (Test-Path $TaskScript)) {
    throw "Task script not found: $TaskScript"
  }
}

function Create-InteractiveLogonTask {
  Write-Host "Creating logon task '$TaskName' for $Username (interactive)..."
  try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
  $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -File `"$TaskScript`""
  $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $Username
  # FIX: Use 'Interactive' instead of 'InteractiveToken'
  $principal = New-ScheduledTaskPrincipal -UserId $Username -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Run-Task-Now {
  try {
    schtasks /run /tn "$TaskName" | Out-Null
    Write-Host "Triggered task '$TaskName' to run now."
  } catch {
    Write-Host "Could not trigger task now: $_"
  }
}

# --- Execution ---
Ensure-User
Relax-LocalPasswordPolicyIfBlank
Allow-BlankPasswordLoginIfBlank
Enable-AutoLogon
Ensure-TaskScript
Create-InteractiveLogonTask
if ($RunTaskNow) { Run-Task-Now }

Write-Host "Done. Autologon configured and interactive logon task created."
if ($RebootWhenDone) {
  Write-Host "Rebooting to apply autologon..."
  Restart-Computer -Force
}
