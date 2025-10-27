# Simple Windows Startup Script for Browser Automation Launcher
# This script runs at Windows startup to ensure the application is running

# Wait for Windows to fully start
Start-Sleep -Seconds 60

# Set project location
$projectPath = Join-Path $env:USERPROFILE "Documents\Applications\browser-automation-launcher"
$logsDir = "$projectPath\logs"

# Create logs directory if it doesn't exist
if (-not (Test-Path $logsDir)) {
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
}

$logFile = "$logsDir\startup.log"
$monitorLog = "$logsDir\monitor.log"
$crashLog = "$logsDir\crash.log"

# Create log function
function Write-Log {
    param($Message, $LogPath = $logFile)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $LogPath -Append
}

# Helper function to run Poetry commands
function Invoke-Poetry {
    param([string[]]$Arguments)

    if (Test-Path $script:poetryPath) {
        & $script:poetryPath @Arguments
    } else {
        & $pythonPath -m poetry @Arguments
    }
}

Write-Log "Starting Browser Automation Launcher startup script"

# Check if Python is installed
$pythonPath = "C:\Program Files\Python312\python.exe"
if (-not (Test-Path $pythonPath)) {
    Write-Log "Python not found. Installing Python 3.12..."

    try {
        $pythonInstaller = "$env:TEMP\python-3.12.0-amd64.exe"
        Write-Log "Downloading Python installer..."
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.12.0/python-3.12.0-amd64.exe" -OutFile $pythonInstaller

        Write-Log "Installing Python..."
        $process = Start-Process -FilePath $pythonInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1" -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-Log "ERROR: Python installation failed with exit code: $($process.ExitCode)"
            exit 1
        }

        Remove-Item $pythonInstaller
        Write-Log "Python installed successfully"

        # Wait a moment for Python to be fully available
        Start-Sleep -Seconds 5
    } catch {
        Write-Log "ERROR: Failed to install Python: $_"
        exit 1
    }
}

# Check if Poetry is installed
$script:poetryPath = "C:\Program Files\Python312\Scripts\poetry.exe"
if (-not (Test-Path $poetryPath)) {
    Write-Log "Poetry not found at $poetryPath. Installing Poetry..."

    try {
        Write-Log "Upgrading pip..."
        $pipOutput = & $pythonPath -m pip install --upgrade pip 2>&1
        Write-Log "Pip output: $pipOutput"

        Write-Log "Installing Poetry (this may take a few minutes)..."
        $poetryOutput = & $pythonPath -m pip install --no-cache-dir poetry 2>&1
        Write-Log "Poetry installation output: $poetryOutput"

        if ($LASTEXITCODE -ne 0) {
            Write-Log "ERROR: Poetry installation failed with exit code: $LASTEXITCODE"
            exit 1
        }

        # Wait for Poetry to be available
        Start-Sleep -Seconds 3

        # Check if Poetry was installed
        if (-not (Test-Path $poetryPath)) {
            # Try alternative Poetry location
            $altPoetryPath = "$env:APPDATA\Python\Python312\Scripts\poetry.exe"
            if (Test-Path $altPoetryPath) {
                $script:poetryPath = $altPoetryPath
                Write-Log "Poetry found at alternative location: $poetryPath"
            } else {
                # Try to find Poetry in PATH
                $poetryInPath = Get-Command poetry -ErrorAction SilentlyContinue
                if ($poetryInPath) {
                    $script:poetryPath = $poetryInPath.Path
                    Write-Log "Poetry found in PATH: $poetryPath"
                } else {
                    Write-Log "ERROR: Poetry installation completed but executable not found!"
                    Write-Log "Checked locations:"
                    Write-Log "  - C:\Program Files\Python312\Scripts\poetry.exe"
                    Write-Log "  - $env:APPDATA\Python\Python312\Scripts\poetry.exe"
                    exit 1
                }
            }
        }

        Write-Log "Poetry installed successfully at: $poetryPath"
    } catch {
        Write-Log "ERROR: Failed to install Poetry: $_"
        exit 1
    }
} else {
    Write-Log "Poetry found at: $poetryPath"
}

# Navigate to project directory
if (-not (Test-Path $projectPath)) {
    Write-Log "ERROR: Project not found at $projectPath"
    exit 1
}

Set-Location $projectPath
Write-Log "Changed to project directory"

# Verify pyproject.toml exists
if (-not (Test-Path "$projectPath\pyproject.toml")) {
    Write-Log "ERROR: pyproject.toml not found in $projectPath"
    Write-Log "Please ensure the browser-automation-launcher project is properly cloned"
    exit 1
}

# Configure Poetry to create virtual environment in project directory
Write-Log "Configuring Poetry to use in-project virtual environments..."
Invoke-Poetry @("config", "virtualenvs.in-project", "true")

# Also set the path explicitly to ensure it's in the project
Invoke-Poetry @("config", "virtualenvs.path", "$projectPath")

# Show current Poetry configuration for debugging
$poetryConfig = Invoke-Poetry @("config", "--list") 2>&1
Write-Log "Current Poetry configuration: $poetryConfig"

Write-Log "Poetry configured"

# Create .env file if it doesn't exist
$envFile = "$projectPath\.env"
if (-not (Test-Path $envFile)) {
    Write-Log "Creating .env file..."

    @"
ENV=staging

# AWS SQS Configuration
SQS_REQUEST_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/317822790556/browser-automation-worker-api-staging-request-queue
SQS_RESPONSE_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/317822790556/browser-automation-worker-api-staging-response-queue

# Browser Management
MAX_BROWSER_INSTANCES=12
DEFAULT_TTL_MINUTES=8
HARD_TTL_MINUTES=20
IDLE_TIMEOUT_SECONDS=50
BROWSER_TIMEOUT=60000

# Chrome Launcher Configuration
USE_CUSTOM_CHROME_LAUNCHER=true
CHROME_LAUNCHER_CMD=C:\Chrome-RDP\launch_chrome_port.cmd
CHROME_PORT_START=9220
CHROME_PORT_END=9240

# Logging
LOG_LEVEL=INFO
LOG_FILE=logs/browser_launcher.log

# Monitoring Intervals
LOCAL_CHECK_INTERVAL=900
STATUS_LOG_INTERVAL=2

# FastAPI Callback Configuration
BROWSER_API_CALLBACK_ENABLED=true
BROWSER_API_CALLBACK_URL=https://nmq3jr4y06.execute-api.us-east-1.amazonaws.com/staging/browser/callback
BROWSER_API_CALLBACK_TIMEOUT=30

# Profile Management
PROFILE_REUSE_ENABLED=true
PROFILE_MAX_AGE_HOURS=24
PROFILE_CLEANUP_INTERVAL_SECONDS=10800

# AWS Credentials (optional)
# AWS_ACCESS_KEY_ID=your_access_key_id
# AWS_SECRET_ACCESS_KEY=your_secret_access_key
# AWS_REGION=us-east-1
"@ | Out-File -FilePath $envFile -Encoding UTF8

    Write-Log ".env file created"
}

# Logs directory already created at the beginning of script

# Install dependencies
if (-not (Test-Path "$projectPath\.venv")) {
    Write-Log "Virtual environment not found."

    # Check if Poetry has any existing environments for this project
    Write-Log "Checking for existing Poetry environments..."
    $envList = Invoke-Poetry @("env", "list") 2>&1
    Write-Log "Environment list: $envList"

    if ($envList -and $envList -notlike "*No*") {
        Write-Log "Found existing Poetry environments, removing them..."
        Invoke-Poetry @("env", "remove", "--all") 2>&1 | Out-Null
        Write-Log "Removed existing environments"
    }

    Write-Log "Installing dependencies with Poetry..."
    $installOutput = Invoke-Poetry @("install", "-vv") 2>&1
    Write-Log "Poetry install output: $installOutput"

    # Wait a bit for virtual environment to be created
    Start-Sleep -Seconds 3

    # Verify .venv was created in project directory
    if (Test-Path "$projectPath\.venv") {
        Write-Log "Virtual environment created successfully in project directory"
    } else {
        Write-Log "WARNING: Virtual environment not found in project directory!"
        # Check where Poetry created it
        $envInfo = Invoke-Poetry @("env", "info", "--path") 2>&1
        Write-Log "Poetry environment location: $envInfo"

        # Try to use the existing environment
        if ($envInfo -and (Test-Path $envInfo)) {
            Write-Log "Using Poetry environment at: $envInfo"
        } else {
            Write-Log "ERROR: Could not find Poetry virtual environment!"
            exit 1
        }
    }
} else {
    Write-Log "Virtual environment exists. Updating dependencies..."
    Write-Log "Running poetry lock..."
    Invoke-Poetry @("lock")
    Write-Log "Running poetry install..."
    Invoke-Poetry @("install")
    Write-Log "Dependencies updated"
}

# Check if application is already running
Write-Log "Checking for existing Python processes running src.main..."
$existingProcesses = Get-Process python* -ErrorAction SilentlyContinue | Where-Object {
    try {
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)" -ErrorAction SilentlyContinue).CommandLine
        $cmdLine -match "src\.main"
    } catch {
        $false
    }
}

if ($existingProcesses) {
    $pids = ($existingProcesses | ForEach-Object { $_.Id }) -join ", "
    Write-Log "Application is already running (PID: $pids)"
    Write-Log "Exiting to prevent duplicate instances"
    Write-Log "To restart, first kill the existing process(es) using: Stop-Process -Id $pids -Force"
    exit 0
}

Write-Log "No existing instances found. Proceeding with startup..."

# Start the application
Write-Log "Starting Browser Automation Launcher..."

# Create output files for capturing application output
$stdoutFile = "$logsDir\app-stdout.log"
$stderrFile = "$logsDir\app-stderr.log"

# Implement log rotation - keep only last 2 days
$currentDate = Get-Date
$rotationDate = $currentDate.ToString("yyyy-MM-dd")

# Archive old logs if they exist
if (Test-Path $stdoutFile) {
    $stdoutBackup = "$logsDir\app-stdout-$rotationDate.log"
    Copy-Item $stdoutFile $stdoutBackup -Force
    Clear-Content $stdoutFile
    Write-Log "Archived stdout log to: $stdoutBackup"
}

if (Test-Path $stderrFile) {
    $stderrBackup = "$logsDir\app-stderr-$rotationDate.log"
    Copy-Item $stderrFile $stderrBackup -Force
    Clear-Content $stderrFile
    Write-Log "Archived stderr log to: $stderrBackup"
}

# Clean up logs older than 2 days
Write-Log "Cleaning up logs older than 2 days..."
$cutoffDate = $currentDate.AddDays(-2)
Get-ChildItem "$logsDir\app-stdout-*.log", "$logsDir\app-stderr-*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoffDate } |
    ForEach-Object {
        Write-Log "Removing old log file: $($_.Name)"
        Remove-Item $_.FullName -Force
    }

try {
    # Start the process using appropriate method
    if (Test-Path $poetryPath) {
        Write-Log "Starting application using Poetry at: $poetryPath"
        $process = Start-Process -FilePath $poetryPath `
            -ArgumentList "run", "python", "-B", "-m", "src.main" `
            -WorkingDirectory $projectPath `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -PassThru `
            -NoNewWindow
    } else {
        Write-Log "Starting application using Python module syntax"
        $process = Start-Process -FilePath $pythonPath `
            -ArgumentList "-m", "poetry", "run", "python", "-B", "-m", "src.main" `
            -WorkingDirectory $projectPath `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile `
            -PassThru `
            -NoNewWindow
    }
} catch {
    Write-Log "ERROR: Failed to start process: $_"
    $process = $null
}

if ($process) {
    Write-Log "Application started with PID: $($process.Id)"
    Write-Log "Application output being written to: $stdoutFile" $monitorLog
    Write-Log "Application errors being written to: $stderrFile" $monitorLog

    # Monitor the process
    Write-Log "Starting process monitoring..." $monitorLog
    $consecutiveFailures = 0
    $lastRotationDate = (Get-Date).ToString("yyyy-MM-dd")
    $stopFile = "$logsDir\STOP"

    while ($true) {
        Start-Sleep -Seconds 30

        # Check for stop file (manual shutdown request)
        if (Test-Path $stopFile) {
            Write-Log "STOP file detected. Shutting down gracefully..." $monitorLog
            Write-Log "To restart, delete the STOP file and run the scheduled task again." $monitorLog
            Remove-Item $stopFile -Force

            # Try to stop the application gracefully
            if (-not $process.HasExited) {
                Write-Log "Stopping application process (PID: $($process.Id))..." $monitorLog
                $process.Kill()
            }
            break
        }

        # Check if we need to rotate logs (daily rotation)
        $currentDateString = (Get-Date).ToString("yyyy-MM-dd")
        if ($currentDateString -ne $lastRotationDate) {
            Write-Log "Daily log rotation triggered" $monitorLog

            # Rotate logs
            $stdoutBackup = "$logsDir\app-stdout-$lastRotationDate.log"
            $stderrBackup = "$logsDir\app-stderr-$lastRotationDate.log"

            if (Test-Path $stdoutFile) {
                Copy-Item $stdoutFile $stdoutBackup -Force
                Clear-Content $stdoutFile
                Write-Log "Rotated stdout log to: $stdoutBackup" $monitorLog
            }

            if (Test-Path $stderrFile) {
                Copy-Item $stderrFile $stderrBackup -Force
                Clear-Content $stderrFile
                Write-Log "Rotated stderr log to: $stderrBackup" $monitorLog
            }

            # Clean up old logs
            $cutoffDate = (Get-Date).AddDays(-2)
            Get-ChildItem "$logsDir\app-stdout-*.log", "$logsDir\app-stderr-*.log" -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '\d{4}-\d{2}-\d{2}' -and $_.LastWriteTime -lt $cutoffDate } |
                ForEach-Object {
                    Write-Log "Removing old log: $($_.Name)" $monitorLog
                    Remove-Item $_.FullName -Force
                }

            $lastRotationDate = $currentDateString
        }

        if ($process.HasExited) {
            $exitCode = $process.ExitCode
            Write-Log "Application exited with code: $exitCode" $monitorLog

            # Exit code 0 = clean exit (normal shutdown)
            # Exit code 1 = manual termination (Stop-Process or killed)
            # Exit code -1073741510 (0xC000013A) = Process terminated (Ctrl+C, Stop-Process)
            # Other codes = application crash

            if ($exitCode -eq 0) {
                Write-Log "Application exited cleanly" $monitorLog
                break
            } elseif ($exitCode -eq 1 -or $exitCode -eq -1073741510) {
                Write-Log "Application was manually terminated (exit code: $exitCode). Not restarting." $monitorLog
                Write-Log "To restart the application, run the scheduled task or delete the STOP file if it exists." $monitorLog
                break
            } else {
                $consecutiveFailures++
                $crashTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

                Write-Log "Application crashed! Consecutive failures: $consecutiveFailures" $monitorLog
                Write-Log "=== CRASH #$consecutiveFailures at $crashTimestamp ===" $crashLog
                Write-Log "Exit Code: $exitCode" $crashLog

                # Log last few lines of output to both monitor and crash log
                if (Test-Path $stdoutFile) {
                    $lastOutput = Get-Content $stdoutFile -Tail 10
                    $stdoutText = $lastOutput -join "`n"
                    Write-Log "Last stdout: $($lastOutput -join ' | ')" $monitorLog
                    Write-Log "STDOUT:`n$stdoutText" $crashLog
                }
                if (Test-Path $stderrFile) {
                    $lastError = Get-Content $stderrFile -Tail 10
                    $stderrText = $lastError -join "`n"
                    Write-Log "Last stderr: $($lastError -join ' | ')" $monitorLog
                    Write-Log "STDERR:`n$stderrText" $crashLog
                }

                Write-Log "----------------------------------------" $crashLog

                # Check if max retry limit reached (5 attempts)
                if ($consecutiveFailures -ge 5) {
                    Write-Log "CRITICAL: Maximum restart attempts (5) reached. Stopping application." $monitorLog
                    Write-Log "CRITICAL: Maximum restart attempts (5) reached. Application will NOT restart automatically." $crashLog
                    Write-Log "Total crashes: $consecutiveFailures" $crashLog
                    Write-Log "To restart manually, run: schtasks /run /tn `"BrowserAutomationStartup`"" $crashLog
                    Write-Log "Or delete the STOP file if it exists and rerun the scheduled task." $crashLog
                    break
                }

                # Wait before restart with progressive delays (5 levels)
                switch ($consecutiveFailures) {
                    1 { $waitTime = 30 }   # 30 seconds
                    2 { $waitTime = 60 }   # 1 minute
                    3 { $waitTime = 120 }  # 2 minutes
                    4 { $waitTime = 300 }  # 5 minutes
                    default { $waitTime = 300 }  # 5 minutes
                }

                Write-Log "Waiting $waitTime seconds before restart (attempt $consecutiveFailures of 5)..." $monitorLog
                Write-Log "Next restart attempt in $waitTime seconds (attempt $consecutiveFailures of 5)" $crashLog
                Start-Sleep -Seconds $waitTime

                # Restart the application
                Write-Log "Restarting application..." $monitorLog
                Write-Log "Attempting restart..." $crashLog
                if (Test-Path $poetryPath) {
                    $process = Start-Process -FilePath $poetryPath `
                        -ArgumentList "run", "python", "-B", "-m", "src.main" `
                        -WorkingDirectory $projectPath `
                        -RedirectStandardOutput $stdoutFile `
                        -RedirectStandardError $stderrFile `
                        -PassThru `
                        -NoNewWindow
                } else {
                    $process = Start-Process -FilePath $pythonPath `
                        -ArgumentList "-m", "poetry", "run", "python", "-B", "-m", "src.main" `
                        -WorkingDirectory $projectPath `
                        -RedirectStandardOutput $stdoutFile `
                        -RedirectStandardError $stderrFile `
                        -PassThru `
                        -NoNewWindow
                }

                if ($process) {
                    Write-Log "Application restarted with PID: $($process.Id)" $monitorLog
                } else {
                    Write-Log "Failed to restart application" $monitorLog
                    break
                }
            }
        } else {
            # Process is still running
            Write-Log "Application is running (PID: $($process.Id))" $monitorLog

            # Reset failure counter if app has been running successfully for 5 minutes
            if ($consecutiveFailures -gt 0) {
                $runningTime = (Get-Date) - $process.StartTime
                if ($runningTime.TotalMinutes -gt 5) {
                    Write-Log "Application stable for 5+ minutes. Resetting failure counter." $monitorLog
                    $consecutiveFailures = 0
                }
            }
        }
    }
} else {
    Write-Log "ERROR: Failed to start application"
}

Write-Log "Startup script completed"
