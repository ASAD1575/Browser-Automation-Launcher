"""Browser health monitoring and cleanup utilities"""

import asyncio
import platform
import socket

import aiohttp

from .logger import get_logger

logger = get_logger(__name__)


def _is_aws_vm_sync() -> bool:
    """Synchronous AWS check - only call from thread"""
    try:
        import socket

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            result = s.connect_ex(("169.254.169.254", 80))
            return result == 0
    except Exception:
        return False


async def _is_aws_vm() -> bool:
    """Check if running on AWS VM (async version)"""
    return await asyncio.to_thread(_is_aws_vm_sync)


async def is_browser_alive(
    debug_port: int, timeout: int = 10, retries: int = 1
) -> bool:
    """
    Check if browser is alive and responsive on the given debug port.
    Works regardless of how the browser was launched.

    Args:
        debug_port: The Chrome DevTools Protocol debug port
        timeout: Connection timeout in seconds (default: 10)
        retries: Number of retry attempts (default: 1)

    Returns:
        True if browser is responsive, False otherwise
    """
    # Validate port
    if not (1 <= debug_port <= 65535):
        logger.error(f"Invalid debug port: {debug_port}")
        return False

    for attempt in range(retries + 1):
        try:
            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=timeout)
            ) as session:
                async with session.get(
                    f"http://127.0.0.1:{debug_port}/json/version"
                ) as response:
                    if response.status == 200:
                        logger.debug(
                            f"Browser on port {debug_port} is alive and responsive"
                        )
                        return True
                    else:
                        logger.debug(
                            f"Browser on port {debug_port} returned status {response.status}"
                        )
                        return False

        except (
            aiohttp.ClientError,
            asyncio.TimeoutError,
            ConnectionRefusedError,
            OSError,
        ) as e:
            if attempt < retries:
                logger.debug(
                    f"Browser check retry {attempt + 1}/{retries} for port {debug_port}"
                )
                await asyncio.sleep(0.5)
                continue
            logger.debug(
                f"Browser on port {debug_port} is not responsive: {type(e).__name__}"
            )
            return False
        except Exception as e:
            logger.warning(
                f"Unexpected error checking browser on port {debug_port}: {e}"
            )
            return False

    return False


def _is_port_in_use_sync(
    port: int, host: str = "127.0.0.1", timeout: float = 0.5
) -> bool:
    """Synchronous port check - only call from thread"""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            result = sock.connect_ex((host, port))
            sock.close()

            if result == 0:
                logger.debug(f"Port {port} is in use on {host}")
                return True
            else:
                logger.debug(f"Port {port} is free on {host}")
                return False
        except Exception:
            sock.close()
            return False

    except Exception as e:
        logger.debug(f"Error checking if port {port} is in use: {e}")
        return False


async def is_port_in_use(
    port: int, host: str = "127.0.0.1", timeout: float = 0.5
) -> bool:
    """
    Check if a port is currently in use.

    Args:
        port: Port number to check
        host: Host address to check (default: 127.0.0.1)
        timeout: Connection timeout in seconds (default: 0.5)

    Returns:
        True if port is in use, False if free
    """
    return await asyncio.to_thread(_is_port_in_use_sync, port, host, timeout)


async def cleanup_windows_port_forwarding(port: int) -> bool:
    """
    Remove Windows port forwarding/proxy mappings for a given port.
    Uses BAT script with START /B for fire-and-forget execution to avoid blocking.

    Args:
        port: Port number to clean up

    Returns:
        True if cleanup initiated successfully, False otherwise
    """
    if platform.system().lower() != "windows":
        logger.debug("Windows port forwarding cleanup skipped (not Windows)")
        return True

    try:
        import os
        import subprocess

        logger.debug(f"Cleaning up Windows port forwarding for port {port}")

        # Validate port number
        if not (1 <= port <= 65535):
            logger.error(f"Invalid port number: {port}")
            return False

        # Get path to BAT script (assuming it's in scripts/ directory relative to project root)
        # Navigate up from src/utils/ to project root
        current_file = os.path.abspath(__file__)
        project_root = os.path.dirname(os.path.dirname(os.path.dirname(current_file)))
        bat_script = os.path.join(project_root, "scripts", "cleanup_port.bat")

        if not os.path.exists(bat_script):
            logger.warning(f"cleanup_port.bat not found at {bat_script}")
            return False

        # Use START /B to run in background without waiting
        # This is truly fire-and-forget - returns immediately
        await asyncio.to_thread(
            lambda: subprocess.Popen(
                ["cmd", "/c", "start", "/B", bat_script, str(port)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW
                if hasattr(subprocess, "CREATE_NO_WINDOW")
                else 0,
            )
        )

        logger.debug(f"Started background port cleanup for {port}")
        return True

    except Exception as e:
        logger.error(f"Error cleaning up Windows port forwarding for port {port}: {e}")
        return False


async def cleanup_linux_port_forwarding(port: int) -> bool:
    """
    Remove Linux iptables port forwarding rules for a given port.

    Args:
        port: Port number to clean up

    Returns:
        True if cleanup successful, False otherwise
    """
    if platform.system().lower() != "linux":
        logger.debug("Linux port forwarding cleanup skipped (not Linux)")
        return True

    try:
        logger.debug(f"Cleaning up Linux iptables rules for port {port}")

        # Remove PREROUTING rule
        prerouting_cmd = [
            "sudo",
            "iptables",
            "-t",
            "nat",
            "-D",
            "PREROUTING",
            "-p",
            "tcp",
            "--dport",
            str(port),
            "-j",
            "DNAT",
            "--to-destination",
            f"127.0.0.1:{port}",
        ]

        await asyncio.create_subprocess_exec(
            *prerouting_cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )

        # Remove OUTPUT rule
        output_cmd = [
            "sudo",
            "iptables",
            "-t",
            "nat",
            "-D",
            "OUTPUT",
            "-p",
            "tcp",
            "--dport",
            str(port),
            "-o",
            "lo",
            "-j",
            "DNAT",
            "--to-destination",
            f"127.0.0.1:{port}",
        ]

        await asyncio.create_subprocess_exec(
            *output_cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )

        # Remove FORWARD rule
        forward_cmd = [
            "sudo",
            "iptables",
            "-D",
            "FORWARD",
            "-p",
            "tcp",
            "-d",
            "127.0.0.1",
            "--dport",
            str(port),
            "-j",
            "ACCEPT",
        ]

        await asyncio.create_subprocess_exec(
            *forward_cmd,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )

        logger.debug(f"Cleaned up Linux iptables rules for port {port}")
        return True

    except Exception as e:
        logger.error(f"Error cleaning up Linux port forwarding for port {port}: {e}")
        return False


async def cleanup_macos_port_forwarding(port: int) -> bool:
    """
    Remove macOS pfctl port forwarding rules for a given port.

    Args:
        port: Port number to clean up

    Returns:
        True if cleanup successful, False otherwise
    """
    if platform.system().lower() != "darwin":
        logger.debug("macOS port forwarding cleanup skipped (not macOS)")
        return True

    try:
        logger.debug(f"Cleaning up macOS pfctl rules for port {port}")

        cmd = ["sudo", "pfctl", "-a", f"browser_port_{port}", "-F", "all"]
        result = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        stdout, stderr = await asyncio.wait_for(result.communicate(), timeout=5.0)

        if result.returncode == 0:
            logger.debug(f"Cleaned up macOS pfctl rules for port {port}")
            return True
        else:
            logger.warning(
                f"Failed to clean up macOS pfctl rules for port {port}: {stderr.decode()}"
            )
            return False

    except Exception as e:
        logger.error(f"Error cleaning up macOS port forwarding for port {port}: {e}")
        return False


async def force_cleanup_port_and_proxy(port: int) -> tuple[bool, bool, bool]:
    """
    Force cleanup of port forwarding/proxy mappings for a given port.
    This ensures cleanup even if browser was not launched by this application.

    Args:
        port: Port number to clean up

    Returns:
        Tuple of (proxy_cleaned: bool, port_freed: bool, browser_closed: bool)
    """
    try:
        logger.debug(f"Starting force cleanup for port {port}")

        # Check if browser is still alive
        browser_alive = await is_browser_alive(port, timeout=1)

        # Clean up proxy/port forwarding based on OS
        # Only cleanup if on AWS VM (where port forwarding is needed)
        system = platform.system().lower()
        proxy_cleaned = False

        if await _is_aws_vm():
            logger.debug(
                f"AWS VM detected - cleaning up port forwarding for port {port}"
            )
            if system == "windows":
                proxy_cleaned = await cleanup_windows_port_forwarding(port)
            elif system == "linux":
                proxy_cleaned = await cleanup_linux_port_forwarding(port)
            elif system == "darwin":
                proxy_cleaned = await cleanup_macos_port_forwarding(port)
            else:
                logger.warning(f"Unsupported OS for port forwarding cleanup: {system}")
                proxy_cleaned = True  # Skip on unsupported OS
        else:
            logger.debug("Not on AWS VM - skipping port forwarding cleanup")
            proxy_cleaned = True  # Not needed on non-AWS

        # Wait a moment for cleanup to take effect
        await asyncio.sleep(0.5)

        # Verify port is actually released
        port_in_use = await is_port_in_use(port)
        port_freed = not port_in_use

        if proxy_cleaned and port_freed:
            logger.debug(f"Port {port} successfully cleaned up and verified as free")
        elif not port_freed:
            logger.warning(f"Port {port} cleanup completed but port is still in use")
        else:
            logger.warning(
                f"Port {port} proxy cleanup had issues but port appears free"
            )

        return proxy_cleaned, port_freed, not browser_alive

    except Exception as e:
        logger.error(f"Error during force cleanup of port {port}: {e}")
        return False, False, False


async def verify_session_health(
    debug_port: int, check_browser: bool = True, check_port: bool = True
) -> dict[str, bool]:
    """
    Comprehensive health check for a browser session.

    Args:
        debug_port: The Chrome DevTools Protocol debug port
        check_browser: Whether to check if browser is responsive (default: True)
        check_port: Whether to check if port is in use (default: True)

    Returns:
        Dictionary with health check results:
        {
            'browser_alive': bool,
            'port_in_use': bool,
            'healthy': bool  # Overall health status
        }
    """
    results = {
        "browser_alive": False,
        "port_in_use": False,
        "healthy": False,
    }

    try:
        if check_browser:
            results["browser_alive"] = await is_browser_alive(debug_port)

        if check_port:
            results["port_in_use"] = await is_port_in_use(debug_port)

        # Session is healthy if browser is alive and port is in use
        results["healthy"] = results["browser_alive"] and results["port_in_use"]

        if not results["healthy"]:
            if not results["browser_alive"] and results["port_in_use"]:
                logger.warning(
                    f"Port {debug_port} is occupied but browser is not responsive"
                )
            elif results["browser_alive"] and not results["port_in_use"]:
                logger.warning(
                    f"Browser on port {debug_port} appears alive but port shows as free (unusual)"
                )
            else:
                logger.info(f"Browser session on port {debug_port} is not healthy")

        return results

    except Exception as e:
        logger.error(f"Error during health check for port {debug_port}: {e}")
        return results


async def find_orphaned_port_mappings(port_range: tuple[int, int]) -> list[int]:
    """
    Find port proxy mappings that don't have active browsers.
    These are "orphaned" mappings left behind after improper cleanup.

    Args:
        port_range: Tuple of (start_port, end_port) to scan

    Returns:
        List of port numbers with orphaned mappings
    """
    orphaned_ports = []

    try:
        system = platform.system().lower()

        if system == "windows":
            orphaned_ports = await _find_orphaned_windows_ports(port_range)
        elif system == "linux":
            orphaned_ports = await _find_orphaned_linux_ports(port_range)
        elif system == "darwin":
            orphaned_ports = await _find_orphaned_macos_ports(port_range)
        else:
            logger.debug(f"Orphaned port detection not supported on {system}")

        if orphaned_ports:
            logger.debug(
                f"Found {len(orphaned_ports)} orphaned port mappings: {orphaned_ports}"
            )
        else:
            logger.debug(f"No orphaned port mappings found in range {port_range}")

        return orphaned_ports

    except Exception as e:
        logger.error(f"Error finding orphaned port mappings: {e}")
        return []


async def _find_orphaned_windows_ports(port_range: tuple[int, int]) -> list[int]:
    """Find orphaned Windows netsh port proxy mappings"""
    orphaned = []

    try:
        # Get all port proxy mappings
        check_cmd = ["netsh", "interface", "portproxy", "show", "v4tov4"]

        proc = await asyncio.create_subprocess_exec(
            *check_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10.0)

        if proc.returncode != 0:
            logger.debug("Could not check Windows port proxy mappings")
            return []

        if stdout:
            output = stdout.decode()
            start_port, end_port = port_range

            # Parse output for ports in our range
            for line in output.split("\n"):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        port = int(parts[1].strip())
                        if start_port <= port <= end_port:
                            # Check if browser is actually running on this port
                            browser_alive = await is_browser_alive(
                                port, timeout=1, retries=0
                            )
                            if not browser_alive:
                                orphaned.append(port)
                                logger.debug(
                                    f"Port {port} has mapping but no active browser"
                                )
                    except (ValueError, IndexError):
                        continue

        return orphaned

    except Exception as e:
        logger.error(f"Error finding orphaned Windows ports: {e}")
        return []


async def _find_orphaned_linux_ports(port_range: tuple[int, int]) -> list[int]:
    """Find orphaned Linux iptables port forwarding rules"""
    orphaned = []

    try:
        # Check iptables NAT rules
        check_cmd = ["sudo", "iptables", "-t", "nat", "-L", "PREROUTING", "-n"]

        proc = await asyncio.create_subprocess_exec(
            *check_cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10.0)

        if proc.returncode != 0:
            logger.debug("Could not check Linux iptables rules")
            return []

        if stdout:
            output = stdout.decode()
            start_port, end_port = port_range

            # Parse iptables output for DNAT rules with our port range
            for line in output.split("\n"):
                if "DNAT" in line and "tcp dpt:" in line:
                    try:
                        # Extract port from line like: "tcp dpt:9222 to:127.0.0.1:9222"
                        for part in line.split():
                            if part.startswith("dpt:"):
                                port = int(part.split(":")[1])
                                if start_port <= port <= end_port:
                                    # Check if browser is running
                                    browser_alive = await is_browser_alive(
                                        port, timeout=1, retries=0
                                    )
                                    if not browser_alive:
                                        orphaned.append(port)
                                        logger.debug(
                                            f"Port {port} has iptables rule but no active browser"
                                        )
                    except (ValueError, IndexError):
                        continue

        return orphaned

    except Exception as e:
        logger.error(f"Error finding orphaned Linux ports: {e}")
        return []


async def _find_orphaned_macos_ports(port_range: tuple[int, int]) -> list[int]:
    """Find orphaned macOS pfctl port forwarding rules"""
    orphaned = []

    try:
        start_port, end_port = port_range

        # Check each port in range for pfctl anchor
        for port in range(start_port, end_port + 1):
            check_cmd = ["sudo", "pfctl", "-a", f"browser_port_{port}", "-s", "nat"]

            proc = await asyncio.create_subprocess_exec(
                *check_cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=5.0)

            # If there's a rule for this port
            if proc.returncode == 0 and stdout and stdout.decode().strip():
                # Check if browser is running
                browser_alive = await is_browser_alive(port, timeout=1, retries=0)
                if not browser_alive:
                    orphaned.append(port)
                    logger.debug(f"Port {port} has pfctl rule but no active browser")

        return orphaned

    except Exception as e:
        logger.error(f"Error finding orphaned macOS ports: {e}")
        return []


async def cleanup_orphaned_port_mappings(port_range: tuple[int, int]) -> dict[str, int]:
    """
    Find and clean up all orphaned port proxy mappings in the given range.
    Orphaned mappings are those with proxy rules but no active browser.

    Args:
        port_range: Tuple of (start_port, end_port) to scan and clean

    Returns:
        Dictionary with cleanup results:
        {
            'found': int,      # Number of orphaned mappings found
            'cleaned': int,    # Number successfully cleaned
            'failed': int      # Number that failed to clean
        }
    """
    results = {"found": 0, "cleaned": 0, "failed": 0}

    try:
        logger.debug(
            f"Scanning for orphaned port mappings in range {port_range[0]}-{port_range[1]}"
        )

        # Find orphaned ports
        orphaned_ports = await find_orphaned_port_mappings(port_range)
        results["found"] = len(orphaned_ports)

        if not orphaned_ports:
            logger.debug("No orphaned port mappings found")
            return results

        # Clean up each orphaned port
        for port in orphaned_ports:
            try:
                logger.debug(f"Cleaning up orphaned mapping for port {port}")
                proxy_cleaned, port_freed, _ = await force_cleanup_port_and_proxy(port)

                if proxy_cleaned and port_freed:
                    results["cleaned"] += 1
                    logger.debug(
                        f"Successfully cleaned orphaned mapping for port {port}"
                    )
                else:
                    results["failed"] += 1
                    logger.warning(
                        f"Failed to fully clean orphaned mapping for port {port}"
                    )

            except Exception as e:
                results["failed"] += 1
                logger.error(f"Error cleaning orphaned port {port}: {e}")

        # Only log summary at INFO level
        logger.info(
            f"Orphaned port cleanup: "
            f"Found={results['found']}, Cleaned={results['cleaned']}, Failed={results['failed']}"
        )

        return results

    except Exception as e:
        logger.error(f"Error during orphaned port cleanup: {e}")
        return results
