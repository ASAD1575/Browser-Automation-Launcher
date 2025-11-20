# Chrome GUI Visibility Fix - Complete Guide

## Problem

After running `auto_login.ps1`, Chrome processes are running but not visible when you RDP into the Windows Server. Chrome windows are launching in Session 0 (background/service session) instead of Session 1 (interactive/RDP session).

## Root Cause

When the Python application launches Chrome via `subprocess.Popen`:
1. Python inherits the session context from the scheduled task/service
2. Scheduled tasks/services typically run in Session 0 (non-interactive)
3. Chrome inherits this session and launches in the background
4. RDP users connect to Session 1 (interactive), so Chrome windows are not visible

## Solution

Use a PowerShell launcher that ensures Chrome launches in the interactive desktop session (Session 1).

---

## Quick Fix Steps

### Step 1: Copy Interactive Launcher Scripts

Copy these files to `C:\Chrome-RDP\` on your EC2 instance:

1. **`launch_chrome_port_interactive.ps1`** (already created in scripts folder)
2. **`launch_chrome_port_interactive.cmd`** (wrapper for PowerShell script)

Or create them directly on the server:

```powershell
# Create directory if it doesn't exist
if (-not (Test-Path "C:\Chrome-RDP")) {
    New-Item -ItemType Directory -Path "C:\Chrome-RDP" -Force
}

# Copy the PowerShell launcher
Copy-Item "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\scripts\launch_chrome_port_interactive.ps1" `
    -Destination "C:\Chrome-RDP\launch_chrome_port_interactive.ps1" -Force

# Copy the CMD wrapper
Copy-Item "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\scripts\launch_chrome_port_interactive.cmd" `
    -Destination "C:\Chrome-RDP\launch_chrome_port_interactive.cmd" -Force
```

### Step 2: Update Application Configuration

Update your `.env` file or environment variable:

```bash
CHROME_LAUNCHER_CMD=C:\Chrome-RDP\launch_chrome_port_interactive.cmd
```

Or if you want to use PowerShell directly:

```bash
CHROME_LAUNCHER_CMD=powershell.exe
```

**Note**: If using PowerShell directly, you'll need to modify the Python code to pass arguments correctly (see Step 3).

### Step 3: Update Python Code (Optional - Only if using PowerShell directly)

If you prefer to use PowerShell directly instead of the CMD wrapper, you need to modify `src/workers/browser_launcher.py`:

**Current code (line ~1085-1091)**:
```python
full_cmd = [
    "cmd.exe",
    "/c",
    settings.chrome_launcher_cmd,
    str(debug_port),
    machine_ip,
]
```

**Updated code for PowerShell**:
```python
if settings.chrome_launcher_cmd.endswith('.ps1'):
    # PowerShell script - use PowerShell to execute
    full_cmd = [
        "powershell.exe",
        "-ExecutionPolicy", "Bypass",
        "-File",
        settings.chrome_launcher_cmd,
        "-Port", str(debug_port),
        "-ListenIP", machine_ip,
    ]
else:
    # CMD script - use existing method
    full_cmd = [
        "cmd.exe",
        "/c",
        settings.chrome_launcher_cmd,
        str(debug_port),
        machine_ip,
    ]
```

**Recommended**: Use the CMD wrapper (`launch_chrome_port_interactive.cmd`) - no Python code changes needed!

### Step 4: Restart Application

Stop and restart your application to pick up the new launcher:

```powershell
# Find Python process
$pythonProc = Get-Process python | Where-Object {
    (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like "*src.main*"
}

# Stop it
Stop-Process -Id $pythonProc.Id -Force

# Restart via scheduled task
schtasks /run /tn "BrowserAutomationStartup"
```

Or restart the service:
```powershell
Restart-Service -Name "BrowserAutomationLauncher"
```

### Step 5: Verify Chrome is Visible

After restart:
1. **RDP into the server**
2. **Check if Chrome windows appear**: You should see Chrome windows on the desktop
3. **Check session**: Run `query session` - Chrome processes should be in Session 1 (your RDP session)

---

## Verification Commands

### Check Current Sessions
```powershell
query session
```

**Expected Output**:
```
SESSIONNAME       USERNAME                 ID  STATE   TYPE        DEVICE
console           Administrator            1  Active
rdp-tcp#0         Administrator            2  Active
```

Chrome should be running in Session 1 (console) or Session 2 (your RDP session).

### Check Chrome Process Session
```powershell
# Get Chrome processes and their session IDs
Get-Process chrome | ForEach-Object {
    $sessionId = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").SessionId
    Write-Host "Chrome PID $($_.Id) - Session: $sessionId"
}
```

**Expected**: Chrome processes should be in Session 1 (console) or Session 2 (RDP).

### Check If Chrome is Visible
```powershell
# List visible windows
Get-Process chrome | ForEach-Object {
    $windows = Get-Process -Id $_.Id | Select-Object -ExpandProperty MainWindowTitle
    Write-Host "PID $($_.Id): $windows"
}
```

If Chrome windows have titles (not empty), they're visible in the GUI.

---

## Alternative Solutions

### Solution 1: Ensure Scheduled Task Runs in Interactive Mode

Modify the scheduled task to ensure it runs in the interactive session:

```powershell
$task = Get-ScheduledTask -TaskName "BrowserAutomationStartup"
$task.Principal.LogonType = "Interactive"  # Ensure interactive logon
$task.Principal.RunLevel = "Highest"
Set-ScheduledTask -TaskName "BrowserAutomationStartup" -Principal $task.Principal
```

### Solution 2: Use Windows Service with Desktop Interaction

If using Windows Service, ensure it's configured to allow desktop interaction:

```powershell
# Using NSSM
& "C:\Program Files\nssm\nssm.exe" set BrowserAutomationLauncher AppStdoutCreationDisposition CREATE_ALWAYS
& "C:\Program Files\nssm\nssm.exe" set BrowserAutomationLauncher AppStderrCreationDisposition CREATE_ALWAYS
& "C:\Program Files\nssm\nssm.exe" set BrowserAutomationLauncher ObjectName LocalSystem
```

However, services still run in Session 0, so this may not fully solve the issue. The PowerShell launcher approach is more reliable.

### Solution 3: Launch Chrome Directly in Session 1

Create a script that uses `psexec` or similar to launch Chrome in Session 1:

```powershell
# Requires PsExec from Sysinternals
psexec.exe -i 1 -s "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 ...
```

This is more complex and requires additional tools.

---

## Troubleshooting

### Chrome Still Not Visible

1. **Check if launcher script exists**:
   ```powershell
   Test-Path "C:\Chrome-RDP\launch_chrome_port_interactive.ps1"
   Test-Path "C:\Chrome-RDP\launch_chrome_port_interactive.cmd"
   ```

2. **Test launcher manually**:
   ```powershell
   cd C:\Chrome-RDP
   .\launch_chrome_port_interactive.ps1 -Port 9222 -ListenIP 127.0.0.1
   ```
   Chrome should appear on your desktop.

3. **Check application logs**:
   ```powershell
   Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\monitor.log" -Tail 50
   ```

4. **Check Chrome launcher output**:
   ```powershell
   Get-Content "C:\Users\Administrator\Documents\Applications\browser-automation-launcher\logs\service-stdout.log" -Tail 50
   ```

### Chrome Launches But Immediately Closes

1. **Check Chrome error logs**:
   ```powershell
   Get-Content "C:\Chrome-RDP\p9222\chrome_debug.log" -ErrorAction SilentlyContinue
   ```

2. **Check Windows Event Log**:
   ```powershell
   Get-EventLog -LogName Application -Source "Chrome" -Newest 10
   ```

### Permission Issues

Ensure the launcher scripts are executable:
```powershell
icacls "C:\Chrome-RDP\launch_chrome_port_interactive.ps1" /grant Administrators:F
icacls "C:\Chrome-RDP\launch_chrome_port_interactive.cmd" /grant Administrators:F
```

---

## How It Works

### PowerShell Launcher (`launch_chrome_port_interactive.ps1`)

1. **Inherits Session Context**: When called from an interactive session (RDP or console), PowerShell inherits that session
2. **Start-Process with -WindowStyle Normal**: Ensures Chrome launches in the current interactive session
3. **Session Inheritance**: Chrome process inherits the PowerShell session, so it appears in the GUI

### CMD Wrapper (`launch_chrome_port_interactive.cmd`)

1. **Calls PowerShell**: Wraps the PowerShell launcher for compatibility with existing Python code
2. **Maintains Argument Format**: Uses same argument format as original CMD script
3. **No Code Changes**: Python code doesn't need modification

---

## Summary

**Quick Fix**:
1. Copy `launch_chrome_port_interactive.ps1` and `launch_chrome_port_interactive.cmd` to `C:\Chrome-RDP\`
2. Update `.env`: `CHROME_LAUNCHER_CMD=C:\Chrome-RDP\launch_chrome_port_interactive.cmd`
3. Restart application

**Result**: Chrome will now launch in the interactive desktop session and be visible when you RDP into the server.

---

**Last Updated**: 2025-01-31

