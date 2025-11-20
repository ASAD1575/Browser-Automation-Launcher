# Verify Chrome GUI Visibility
# Run this script to diagnose Chrome session issues

Write-Host "========================================"
Write-Host "Chrome GUI Visibility Diagnostic"
Write-Host "========================================"
Write-Host ""

# Check current session
Write-Host "1. Current Session Information:" -ForegroundColor Cyan
$currentSession = query session
$currentSession | Write-Host

Write-Host ""
Write-Host "2. Your RDP Session:" -ForegroundColor Cyan
$rdpSession = $currentSession | Select-String "rdp" | Select-Object -First 1
if ($rdpSession) {
    Write-Host $rdpSession -ForegroundColor Green
    $rdpSessionId = ($rdpSession -split '\s+')[2]
    Write-Host "Your session ID: $rdpSessionId" -ForegroundColor Yellow
} else {
    Write-Host "No RDP session found (you may be on console)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "3. Chrome Processes and Sessions:" -ForegroundColor Cyan
$chromeProcesses = Get-Process chrome -ErrorAction SilentlyContinue
if ($chromeProcesses) {
    Write-Host "Found $($chromeProcesses.Count) Chrome process(es)" -ForegroundColor Green
    Write-Host ""
    foreach ($proc in $chromeProcesses) {
        try {
            $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)"
            $sessionId = $procInfo.SessionId
            $cmdLine = $procInfo.CommandLine
            
            # Get port from command line if available
            $port = "N/A"
            if ($cmdLine -match '--remote-debugging-port=(\d+)') {
                $port = $matches[1]
            }
            
            Write-Host "  PID: $($proc.Id)" -ForegroundColor White
            Write-Host "    Session: $sessionId" -ForegroundColor $(if ($sessionId -eq 1 -or $sessionId -eq 2) { "Green" } else { "Red" })
            Write-Host "    Port: $port" -ForegroundColor White
            Write-Host "    Window Title: $($proc.MainWindowTitle)" -ForegroundColor $(if ($proc.MainWindowTitle) { "Green" } else { "Red" })
            
            if ($sessionId -eq 0) {
                Write-Host "    [ISSUE] Running in Session 0 (service session) - NOT visible in RDP!" -ForegroundColor Red
            } elseif ($sessionId -eq 1) {
                Write-Host "    [OK] Running in Session 1 (console) - Visible if you're on console" -ForegroundColor Green
            } else {
                Write-Host "    [OK] Running in Session $sessionId (likely RDP) - Should be visible" -ForegroundColor Green
            }
            
            if (-not $proc.MainWindowTitle -and $sessionId -ne 0) {
                Write-Host "    [WARNING] Process has no window title - may be running headless" -ForegroundColor Yellow
            }
            
            Write-Host ""
        } catch {
            Write-Host "  PID: $($proc.Id) - Error getting info: $_" -ForegroundColor Red
        }
    }
} else {
    Write-Host "No Chrome processes found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "4. Python Application Process:" -ForegroundColor Cyan
$pythonProcesses = Get-Process python* -ErrorAction SilentlyContinue | Where-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        $cmdLine -match "src\.main"
    } catch {
        $false
    }
}

if ($pythonProcesses) {
    foreach ($proc in $pythonProcesses) {
        try {
            $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)"
            $sessionId = $procInfo.SessionId
            $cmdLine = $procInfo.CommandLine
            
            Write-Host "  PID: $($proc.Id)" -ForegroundColor White
            Write-Host "    Session: $sessionId" -ForegroundColor $(if ($sessionId -eq 1 -or $sessionId -eq 2) { "Green" } else { "Red" })
            Write-Host "    Command: $($cmdLine.Substring(0, [Math]::Min(80, $cmdLine.Length)))..." -ForegroundColor Gray
            
            if ($sessionId -eq 0) {
                Write-Host "    [ISSUE] Python running in Session 0 - Chrome will launch in Session 0 too!" -ForegroundColor Red
                Write-Host "    [FIX] Ensure scheduled task runs with Interactive logon type" -ForegroundColor Yellow
            }
            Write-Host ""
        } catch {
            Write-Host "  PID: $($proc.Id) - Error getting info: $_" -ForegroundColor Red
        }
    }
} else {
    Write-Host "No Python processes running src.main found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "5. Scheduled Task Configuration:" -ForegroundColor Cyan
$task = Get-ScheduledTask -TaskName "BrowserAutomationStartup" -ErrorAction SilentlyContinue
if ($task) {
    $principal = $task.Principal
    Write-Host "  Task Name: $($task.TaskName)" -ForegroundColor White
    Write-Host "  State: $($task.State)" -ForegroundColor White
    Write-Host "  User: $($principal.UserId)" -ForegroundColor White
    Write-Host "  Logon Type: $($principal.LogonType)" -ForegroundColor $(if ($principal.LogonType -eq "Interactive") { "Green" } else { "Yellow" })
    Write-Host "  Run Level: $($principal.RunLevel)" -ForegroundColor White
    
    if ($principal.LogonType -ne "Interactive") {
        Write-Host "  [ISSUE] Task not configured for Interactive logon - Chrome will launch in background!" -ForegroundColor Red
        Write-Host "  [FIX] Run the following command:" -ForegroundColor Yellow
        Write-Host "    `$task = Get-ScheduledTask -TaskName 'BrowserAutomationStartup'" -ForegroundColor Cyan
        Write-Host "    `$task.Principal.LogonType = 'Interactive'" -ForegroundColor Cyan
        Write-Host "    Set-ScheduledTask -TaskName 'BrowserAutomationStartup' -Principal `$task.Principal" -ForegroundColor Cyan
    }
} else {
    Write-Host "Scheduled task 'BrowserAutomationStartup' not found" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "6. Chrome Launcher Configuration:" -ForegroundColor Cyan
$launcherPath = $env:CHROME_LAUNCHER_CMD
if (-not $launcherPath) {
    $launcherPath = "C:\Chrome-RDP\launch_chrome_port.cmd"
}

Write-Host "  Expected launcher: $launcherPath" -ForegroundColor White
if (Test-Path $launcherPath) {
    Write-Host "  [OK] Launcher script exists" -ForegroundColor Green
    
    # Check if it's the interactive version
    if ($launcherPath -like "*interactive*") {
        Write-Host "  [OK] Using interactive launcher" -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] Using standard launcher - may launch in background" -ForegroundColor Yellow
        Write-Host "  [FIX] Update CHROME_LAUNCHER_CMD to use launch_chrome_port_interactive.cmd" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [ERROR] Launcher script not found!" -ForegroundColor Red
}

Write-Host ""
Write-Host "========================================"
Write-Host "Summary & Recommendations"
Write-Host "========================================"
Write-Host ""

$issues = @()
$fixes = @()

if ($pythonProcesses) {
    foreach ($proc in $pythonProcesses) {
        $sessionId = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").SessionId
        if ($sessionId -eq 0) {
            $issues += "Python application running in Session 0 (service session)"
            $fixes += "Configure scheduled task to use Interactive logon type"
        }
    }
}

if ($chromeProcesses) {
    foreach ($proc in $chromeProcesses) {
        $sessionId = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").SessionId
        if ($sessionId -eq 0) {
            $issues += "Chrome running in Session 0 (not visible in RDP)"
            $fixes += "Use interactive Chrome launcher: launch_chrome_port_interactive.cmd"
        }
        if (-not $proc.MainWindowTitle -and $sessionId -ne 0) {
            $issues += "Chrome has no visible windows (may be running headless)"
        }
    }
}

if ($issues.Count -eq 0) {
    Write-Host "[SUCCESS] No issues detected! Chrome should be visible in RDP." -ForegroundColor Green
} else {
    Write-Host "[ISSUES FOUND]:" -ForegroundColor Red
    foreach ($issue in $issues) {
        Write-Host "  - $issue" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "[RECOMMENDED FIXES]:" -ForegroundColor Yellow
    foreach ($fix in $fixes) {
        Write-Host "  - $fix" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "See CHROME_GUI_FIX_GUIDE.md for detailed instructions." -ForegroundColor Cyan
}

Write-Host ""

