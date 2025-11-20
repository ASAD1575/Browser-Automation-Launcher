# Quick SSM Diagnostic Commands

Copy and paste these commands into SSM Session Manager:

## 1. Check if user is logged in:
```powershell
query user
```
**Expected:** Should show Administrator session  
**If empty:** User is NOT logged in = autologon failed

---

## 2. Check autologon registry:
```powershell
$reg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Get-ItemProperty -Path $reg | Select AutoAdminLogon, ForceAutoLogon, DefaultUsername, DefaultPassword, AutoLogonCount
```
**Expected:**
- AutoAdminLogon: `1`
- ForceAutoLogon: `1`
- DefaultUsername: `Administrator`
- DefaultPassword: `<your password>` (not empty!)
- AutoLogonCount: `999999`

---

## 3. Check task status:
```powershell
schtasks /query /tn "ForceAutoLogin" /fo LIST
schtasks /query /tn "BrowserAutomationStartup" /fo LIST
```
**Expected:** Status: `Running` (after user logs in)  
**If Ready:** Tasks haven't triggered yet

---

## 4. Check task execution history:
```powershell
Get-ScheduledTaskInfo -TaskName "ForceAutoLogin" | Format-List
Get-ScheduledTaskInfo -TaskName "BrowserAutomationStartup" | Format-List
```
Shows when tasks last ran and results

---

## 5. Check Event Viewer for errors:
```powershell
Get-WinEvent -FilterHashtable @{LogName="System"; Level=2,3} -MaxEvents 20 | Where-Object {$_.Message -like "*logon*"} | Select-Object -First 5 TimeCreated, LevelDisplayName, Message
```

---

## 6. Test manual task trigger:
```powershell
# Test ForceAutoLogin
schtasks /run /tn "ForceAutoLogin"

# Test BrowserAutomationStartup (if user is logged in)
schtasks /run /tn "BrowserAutomationStartup"
```

---

## 7. Quick Fix - Re-run autologon setup:
```powershell
.\manual_autologon_setup.ps1 -UpdateAutologonPassword
```

---

## 8. Comprehensive Fix:
```powershell
.\fix_autologon.ps1
```

---

## Most Common Issue:
**Password mismatch** - The password in autologon registry doesn't match the actual user password.

**Solution:**
```powershell
# Update user password to match autologon registry
net user Administrator "bDwQrUQLDA*uEOvZqCB6ldG@\$ea(JLC3"

# OR update autologon registry to match user password
.\manual_autologon_setup.ps1 -UpdateAutologonPassword
```

