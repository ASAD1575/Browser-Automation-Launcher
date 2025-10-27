# PowerShell script to create multiple test requests for Windows

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

for ($i = 1; $i -le 3; $i++) {
    Write-Host "Creating test request $i..."

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $json = @{
        id = "test-$i-$timestamp"
        requester_id = "local-test"
        ttl_minutes = 2
        chrome_args = @("--window-size=1920,1080")
    } | ConvertTo-Json -Depth 10

    $filePath = Join-Path $scriptDir "test_request.json"
    $json | Out-File -FilePath $filePath -Encoding UTF8

    Start-Sleep -Seconds 6
}
