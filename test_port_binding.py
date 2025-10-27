"""Test script to diagnose port binding issues on Windows"""

import socket
import subprocess

print("=" * 60)
print("PORT BINDING DIAGNOSTIC TEST")
print("=" * 60)

# Test binding to port 9220
port = 9220

print(f"\n1. Testing port {port} with 0.0.0.0...")
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    print(f"   ✓ SUCCESS: Port {port} is available on 0.0.0.0")
    sock.close()
except Exception as e:
    print(f"   ✗ FAILED: {type(e).__name__}: {e}")

print(f"\n2. Testing port {port} with 127.0.0.1...")
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    print(f"   ✓ SUCCESS: Port {port} is available on 127.0.0.1")
    sock.close()
except Exception as e:
    print(f"   ✗ FAILED: {type(e).__name__}: {e}")

print(f"\n3. Testing port {port} with empty string ''...")
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("", port))
    print(f"   ✓ SUCCESS: Port {port} is available on ''")
    sock.close()
except Exception as e:
    print(f"   ✗ FAILED: {type(e).__name__}: {e}")

print("\n4. Checking which ports in range 9220-9240 are in use...")
try:
    result = subprocess.run(
        ["netstat", "-ano"], capture_output=True, text=True, timeout=5
    )
    lines = [
        line
        for line in result.stdout.split("\n")
        if ":922" in line or ":923" in line or ":924" in line
    ]
    if lines:
        print(f"   Found {len(lines)} connections in port range:")
        for line in lines[:15]:
            print(f"   {line.strip()}")
    else:
        print("   ✓ No ports in 9220-9240 range are in use")
except subprocess.TimeoutExpired:
    print("   ✗ netstat command timed out")
except Exception as e:
    print(f"   ✗ Error running netstat: {e}")

print("\n5. Testing the actual _check_port_free_async logic...")


def check_port_free(port):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", port))
            sock.close()
            return True
        except OSError as e:
            sock.close()
            print(f"   Port {port}: BUSY - {e}")
            return False
    except Exception as e:
        print(f"   Port {port}: ERROR - {e}")
        return False


free_ports = []
for test_port in range(9220, 9225):  # Test first 5 ports
    if check_port_free(test_port):
        free_ports.append(test_port)
        print(f"   Port {test_port}: FREE")

if free_ports:
    print(f"\n   ✓ Found {len(free_ports)} free ports: {free_ports}")
else:
    print("\n   ✗ No free ports found in range 9220-9224")

print("\n" + "=" * 60)
print("DIAGNOSTIC TEST COMPLETE")
print("=" * 60)
