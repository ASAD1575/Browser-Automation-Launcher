# SSM Diagnostic Commands for Autologon Troubleshooting
# Copy and paste these commands one by one into SSM Session Manager

Write-Host "=========================================="
Write-Host "SSM Diagnostic Commands"
Write-Host "=========================================="
Write-Host ""
Write-Host "Run these commands via SSM Session Manager to diagnose autologon issues:"
Write-Host ""
Write-Host "=========================================="
Write-Host "1. Check if user is logged in:"
Write-Host "=========================================="
Write-Host 'query user'
Write-Host ""
Write-Host "Expected: Should show Administrator user logged in"
Write-Host "If empty: User is NOT logged in = autologon failed"
Write-Host ""

Write-Host "=========================================="
Write-Host "2. Check autologon registry settings:"
Write-Host "=========================================="
Write-Host '$reg = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"'
Write-Host 'Get-ItemProperty -Path $reg | Select AutoAdminLogon, ForceAutoLogon, DefaultUsername, DefaultPassword, AutoLogonCount'
Write-Host ""
Write-Host "Expected:"
Write-Host "  AutoAdminLogon: 1"
Write-Host "  ForceAutoLogon: 1"
Write-Host "  DefaultUsername: Administrator"
Write-Host "  DefaultPassword: (should show your password)"
Write-Host "  AutoLogonCount: 999999"
Write-Host ""

Write-Host "=========================================="
Write-Host "3. Check scheduled task status:"
Write-Host "=========================================="
Write-Host 'schtasks /query /tn "ForceAutoLogin" /fo LIST'
Write-Host 'schtasks /query /tn "BrowserAutomationStartup" /fo LIST'
Write-Host ""
Write-Host "Expected: Should show Status: Running (after user logs in)"
Write-Host "If Ready: Tasks haven't triggered yet"
Write-Host ""

Write-Host "=========================================="
Write-Host "4. Check task execution history:"
Write-Host "=========================================="
Write-Host '$taskInfo = Get-ScheduledTaskInfo -TaskName "ForceAutoLogin"'
Write-Host '$taskInfo | Format-List'
Write-Host '$taskInfo = Get-ScheduledTaskInfo -TaskName "BrowserAutomationStartup"'
Write-Host '$taskInfo | Format-List'
Write-Host ""
Write-Host "Shows when tasks last ran and their results"
Write-Host ""

Write-Host "=========================================="
Write-Host "5. Check Event Viewer for autologon errors:"
Write-Host "=========================================="
Write-Host 'Get-WinEvent -FilterHashtable @{LogName="System"; Level=2,3} -MaxEvents 20 | Where-Object {$_.Message -like "*logon*" -or $_.Message -like "*autologon*" -or $_.Message -like "*credential*"} | Format-List TimeCreated, LevelDisplayName, Message'
Write-Host ""
Write-Host "Look for errors related to logon/autologon"
Write-Host ""

Write-Host "=========================================="
Write-Host "6. Verify user password:"
Write-Host "=========================================="
Write-Host 'net user Administrator'
Write-Host ""
Write-Host "Shows user account info (but not the password itself)"
Write-Host ""

Write-Host "=========================================="
Write-Host "7. Test if password works (by trying to change it):"
Write-Host "=========================================="
Write-Host '# This will fail if password is wrong (but won''t change password)'
Write-Host '# net user Administrator "CurrentPassword" /domain'
Write-Host ""
Write-Host "Note: You can test password by trying RDP login"
Write-Host ""

Write-Host "=========================================="
Write-Host "8. Manually trigger ForceAutoLogin task:"
Write-Host "=========================================="
Write-Host 'schtasks /run /tn "ForceAutoLogin"'
Write-Host ""
Write-Host "This should trigger autologon (if configured correctly)"
Write-Host ""

Write-Host "=========================================="
Write-Host "9. Manually trigger BrowserAutomationStartup:"
Write-Host "=========================================="
Write-Host 'schtasks /run /tn "BrowserAutomationStartup"'
Write-Host ""
Write-Host "This tests if the task works (even without autologon)"
Write-Host ""

Write-Host "=========================================="
Write-Host "10. Check if RDP is enabled:"
Write-Host "=========================================="
Write-Host '(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections'
Write-Host ""
Write-Host "Expected: 0 (enabled)"
Write-Host ""

Write-Host "=========================================="
Write-Host "11. Check current logged in user context:"
Write-Host "=========================================="
Write-Host '$env:USERNAME'
Write-Host 'whoami'
Write-Host ""
Write-Host "Shows who you're logged in as in SSM session"
Write-Host ""

Write-Host "=========================================="
Write-Host "12. Check ForceAutoLogin trigger script exists:"
Write-Host "=========================================="
Write-Host 'Test-Path "C:\ProgramData\trigger_autologin.ps1"'
Write-Host 'Get-Content "C:\ProgramData\trigger_autologin.ps1"'
Write-Host ""
Write-Host "Verify the trigger script exists and has correct content"
Write-Host ""

Write-Host "=========================================="
Write-Host "13. Quick Fix Commands:"
Write-Host "=========================================="
Write-Host "# Re-run autologon setup:"
Write-Host '.\manual_autologon_setup.ps1 -UpdateAutologonPassword'
Write-Host ""
Write-Host "# Run comprehensive fix:"
Write-Host '.\fix_autologon.ps1'
Write-Host ""
Write-Host "# Create ForceAutoLogin task if missing:"
Write-Host '.\create_force_autologin_task.ps1'
Write-Host ""

