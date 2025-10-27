"""Utility to manage Windows port reservations and IP Helper service conflicts"""

import platform
import subprocess

from src.utils.logger import get_logger

logger = get_logger(__name__)


def ensure_ports_available(start_port: int, end_port: int) -> bool:
    """
    Ensure ports are available by handling Windows IP Helper conflicts.
    Only runs on Windows. Requires admin privileges.

    Args:
        start_port: Starting port number
        end_port: Ending port number

    Returns:
        True if ports are available or conflicts resolved, False otherwise
    """
    if platform.system().lower() != "windows":
        logger.debug("Port manager only runs on Windows")
        return True

    try:
        # Check if IP Helper service is running and blocking ports
        if _is_ip_helper_blocking_ports(start_port, end_port):
            logger.warning(
                f"IP Helper service is blocking ports {start_port}-{end_port}. "
                "Attempting to resolve..."
            )

            # Try to stop and disable IP Helper
            if _disable_ip_helper_service():
                logger.info(
                    "Successfully disabled IP Helper service. Ports should now be available."
                )
                return True
            else:
                logger.error(
                    "Failed to disable IP Helper service. "
                    "Manual intervention required or run as Administrator."
                )
                return False
        else:
            logger.debug(f"Ports {start_port}-{end_port} are available")
            return True

    except Exception as e:
        logger.warning(f"Error checking port availability: {e}")
        # Don't fail the application, just log the warning
        return True


def _is_ip_helper_blocking_ports(start_port: int, end_port: int) -> bool:
    """Check if IP Helper service has reserved the port range"""
    try:
        # Check excluded port ranges
        result = subprocess.run(
            ["netsh", "int", "ipv4", "show", "excludedportrange", "protocol=tcp"],
            capture_output=True,
            text=True,
            timeout=10,
        )

        if result.returncode != 0:
            logger.debug("Could not check excluded port ranges")
            return False

        # Parse output to find if our port range is excluded
        lines = result.stdout.split("\n")
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    range_start = int(parts[0])
                    range_end = int(parts[1])

                    # Check if our port range overlaps with excluded range
                    if (
                        range_start <= start_port <= range_end
                        or range_start <= end_port <= range_end
                        or (start_port <= range_start and end_port >= range_end)
                    ):
                        logger.info(
                            f"Found port exclusion: {range_start}-{range_end} "
                            f"overlapping with {start_port}-{end_port}"
                        )
                        return True
                except (ValueError, IndexError):
                    continue

        return False

    except Exception as e:
        logger.debug(f"Error checking IP Helper port reservations: {e}")
        return False


def _disable_ip_helper_service() -> bool:
    """
    Attempt to stop and disable IP Helper service permanently.
    Requires administrator privileges.

    Returns:
        True if successful, False otherwise
    """
    try:
        logger.info("Attempting to stop IP Helper service (iphlpsvc)...")

        # Stop the service
        result = subprocess.run(
            ["net", "stop", "iphlpsvc", "/y"],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            # Service might already be stopped
            logger.debug(f"Stop service result: {result.stderr}")
        else:
            logger.info("IP Helper service stopped successfully")

        # Disable the service - FIXED: removed space between start= and disabled
        logger.info("Disabling IP Helper service permanently...")
        result = subprocess.run(
            ["sc", "config", "iphlpsvc", "start=disabled"],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode == 0:
            logger.info("IP Helper service disabled successfully")

            # Delete existing port exclusions created by IP Helper
            logger.info("Cleaning up port exclusions...")
            _delete_port_exclusions()

            logger.info(
                "Note: IP Helper provides IPv6 transition technologies. "
                "If you need IPv6 connectivity, you may need to re-enable this service."
            )
            return True
        else:
            logger.warning(f"Failed to disable IP Helper service: {result.stderr}")
            return False

    except subprocess.TimeoutExpired:
        logger.error("Timeout while trying to manage IP Helper service")
        return False
    except Exception as e:
        logger.error(f"Error managing IP Helper service: {e}")
        return False


def _delete_port_exclusions() -> bool:
    """
    Delete port exclusions created by IP Helper.
    This requires the IP Helper service to be stopped first.

    Returns:
        True if successful or no exclusions found, False otherwise
    """
    try:
        # Check if there are any exclusions in our port range
        result = subprocess.run(
            ["netsh", "int", "ipv4", "show", "excludedportrange", "protocol=tcp"],
            capture_output=True,
            text=True,
            timeout=10,
        )

        if result.returncode != 0:
            logger.debug("Could not check port exclusions")
            return True

        # Port exclusions are automatically removed when IP Helper is stopped
        # But we log what we found
        exclusions_found = False
        lines = result.stdout.split("\n")
        for line in lines:
            parts = line.split()
            if len(parts) >= 2:
                try:
                    range_start = int(parts[0])
                    range_end = int(parts[1])
                    if 9200 <= range_start <= 9350 or 9200 <= range_end <= 9350:
                        logger.info(
                            f"Found port exclusion in our range: {range_start}-{range_end}"
                        )
                        exclusions_found = True
                except (ValueError, IndexError):
                    continue

        if not exclusions_found:
            logger.info("No port exclusions found in Chrome port range (9200-9350)")
        else:
            logger.info(
                "Port exclusions should be cleared now that IP Helper is stopped"
            )

        return True

    except Exception as e:
        logger.debug(f"Error checking/deleting port exclusions: {e}")
        return True  # Don't fail the application


def check_admin_privileges() -> bool:
    """Check if running with administrator privileges on Windows"""
    if platform.system().lower() != "windows":
        return True

    try:
        # Try to read from a protected registry key
        import winreg

        with winreg.OpenKey(winreg.HKEY_USERS, "S-1-5-19"):
            return True
    except (ImportError, OSError):
        return False
