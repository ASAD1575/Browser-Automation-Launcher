#!/usr/bin/env python3
"""
Test browser active/inactive detection
Usage: python test_browser_activity.py <debug_port>
"""

import time
import sys
from datetime import datetime
from selenium import webdriver
from selenium.webdriver.chrome.options import Options


def test_browser_activity(debug_port=9222, machine_ip=None):
    # Use localhost if testing on same machine, otherwise use provided IP
    browser_ip = machine_ip or "127.0.0.1"

    print("\n=== Testing Browser Activity Detection ===")
    print(f"    IP: {browser_ip}, Port: {debug_port}")
    print("    Test Duration: 5 minutes with active pages")
    print(f"    Started at: {datetime.now().strftime('%H:%M:%S')}\n")

    # Connect to browser
    print("1. Connecting to browser...")
    chrome_options = Options()
    chrome_options.add_experimental_option(
        "debuggerAddress", f"{browser_ip}:{debug_port}"
    )

    try:
        driver = webdriver.Chrome(options=chrome_options)
        print("   ✓ Connected successfully\n")

        # Open multiple pages
        print("2. Opening multiple pages...")
        pages = [
            ("https://example.com", "Example"),
            ("https://www.wikipedia.org", "Wikipedia"),
            ("https://www.github.com", "GitHub"),
        ]

        # Open first page
        driver.get(pages[0][0])
        print(f"   ✓ Opened {pages[0][1]}")

        # Open additional pages in new tabs
        for url, name in pages[1:]:
            driver.execute_script(f"window.open('{url}', '_blank');")
            print(f"   ✓ Opened {name} in new tab")
            time.sleep(2)

        print(f"\n3. Keeping {len(pages)} pages active for 7 minutes...")
        print("   - Browser should remain active during this period")
        print("   - Even if TTL expires, browser should stay alive")

        # Show progress every minute
        for minute in range(1, 5):
            print(f"\n   Minute {minute}/7 - {datetime.now().strftime('%H:%M:%S')}")

            # Switch between tabs to simulate activity
            handles = driver.window_handles
            driver.switch_to.window(handles[minute % len(handles)])

            # Perform minor activity
            driver.execute_script("window.scrollTo(0, 100);")
            print(f"   - Switched to tab {(minute % len(handles)) + 1}")
            print(f"   - Browser has {len(handles)} active tabs")

            # Wait 1 minute
            time.sleep(60)

        print(f"\n4. Test completed at: {datetime.now().strftime('%H:%M:%S')}")
        print("   ✓ Disconnecting from browser (leaving it running)")

        # Disconnect without closing browser
        driver.quit()

        print("\n5. Browser is now disconnected but still running")
        print("   - If browser has active pages, it should stay alive until TTL")
        print("   - If browser returns to blank pages, it should terminate")
        print("\n   Monitor your launcher logs to verify behavior!")

    except Exception as e:
        print(f"\n   ✗ Error: {e}")
        import traceback

        traceback.print_exc()
        return False

    return True


if __name__ == "__main__":
    # Usage: python test_browser_activity.py [port] [ip]
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9222
    ip = sys.argv[2] if len(sys.argv) > 2 else None

    print("Usage: python test_browser_activity.py [port] [ip]")
    print("  - For local testing: python test_browser_activity.py 9222")
    print("  - For remote testing: python test_browser_activity.py 9222 10.0.0.5")

    test_browser_activity(port, ip)
