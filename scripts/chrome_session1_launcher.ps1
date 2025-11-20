# Chrome Session 1 Launcher
# Forces Chrome to launch in Session 1 (interactive desktop) regardless of caller's session
# Usage: .\chrome_session1_launcher.ps1 -Port <PORT> -ListenIP <IP> [-ChromeArgs <args>]

param(
    [Parameter(Mandatory=$true)]
    [int]$Port,
    
    [Parameter(Mandatory=$true)]
    [string]$ListenIP,
    
    [string]$ChromeArgs = ""
)

# Find Chrome
$chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
if (-not (Test-Path $chromePath)) {
    $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
}
if (-not (Test-Path $chromePath)) {
    Write-Error "Chrome not found"
    exit 1
}

# Prepare profile directory
$profileDir = "C:\Chrome-RDP\p$Port"
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}

# Build Chrome arguments
$chromeArguments = @(
    "--remote-debugging-port=$Port",
    "--user-data-dir=`"$profileDir`"",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--disable-sync",
    "--disable-background-networking",
    "--disable-component-update",
    "--disable-default-apps",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--disable-popup-blocking",
    "--disable-hang-monitor",
    "--disable-background-mode",
    "--disable-backgrounding-occluded-windows",
    "--disable-renderer-backgrounding",
    "--disable-breakpad",
    "--disable-domain-reliability",
    "--disable-features=OptimizationHints,MediaRouter,TranslateUI",
    "--disable-ipc-flooding-protection",
    "--metrics-recording-only",
    "--mute-audio",
    "--process-per-site",
    "--renderer-process-limit=2",
    "--aggressive-cache-discard",
    "--disk-cache-size=104857600",
    "--media-cache-size=20971520",
    "--proxy-server=`"http=brd.superproxy.io:33335;https=brd.superproxy.io:33335`"",
    "--proxy-bypass-list=`"localhost;127.0.0.1;<-loopback>;*.local`"",
    "about:blank"
)

# Use scheduled task with Interactive logon to force Session 1
$taskName = "ChromeLaunch_Session1_$Port"
$chromeArgString = $chromeArguments -join " "

try {
    # Create temporary scheduled task with Interactive logon (forces Session 1)
    $action = New-ScheduledTaskAction -Execute $chromePath -Argument $chromeArgString
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(1)
    
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger -Force -ErrorAction Stop | Out-Null
    Start-Sleep -Milliseconds 500
    
    # Trigger the task
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
    
    # Wait for Chrome to start
    Start-Sleep -Seconds 3
    
    # Find Chrome PID
    $chromePid = 0
    $tcpConnections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($tcpConnections) {
        $chromePid = $tcpConnections[0].OwningProcess
    }
    
    # Clean up temporary task
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    
    # Setup portproxy and firewall
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$Port | Out-Null
    netsh interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$Port | Out-Null
    netsh interface portproxy delete v4tov4 listenaddress=$ListenIP listenport=$Port | Out-Null
    
    netsh interface portproxy add v4tov4 listenaddress=$ListenIP listenport=$Port connectaddress=127.0.0.1 connectport=$Port | Out-Null
    
    netsh advfirewall firewall delete rule name="Chrome DevTools $Port" | Out-Null
    netsh advfirewall firewall add rule name="Chrome DevTools $Port" dir=in action=allow protocol=TCP localport=$Port | Out-Null
    
    # Output PID (for Python to capture)
    Write-Output $chromePid
    exit 0
    
} catch {
    Write-Error "Failed to launch Chrome in Session 1: $_"
    exit 1
}



