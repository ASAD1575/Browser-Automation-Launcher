#!/bin/bash
# Create multiple test requests to launch multiple browsers

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

for i in {1..10}; do
  echo "Creating test request $i..."
  cat > "$SCRIPT_DIR/test_request.json" << EOF
{
  "id": "test-$i-$(date +%s)",
  "requester_id": "local-test",
  "ttl_minutes": 2,
  "chrome_args": ["--window-size=1920,1080"]
}
EOF
  sleep 6  # Wait for the app to process each request
done
