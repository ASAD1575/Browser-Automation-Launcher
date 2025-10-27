import asyncio
import json
import os
import platform
import random
import re
import shutil
import socket
import subprocess
import tempfile
import time
import uuid
from datetime import UTC, datetime, timedelta
from typing import Optional, Union

import aiohttp
import psutil

from ..core.config import settings
from ..queue.models import (
    BrowserSession,
    BrowserSessionRequest,
    BrowserSessionResponse,
    RequestStatus,
    TerminatedSession,
)
from ..utils.http_client import send_post_request
from ..utils.logger import get_logger

logger = get_logger(__name__)


class ChromeProcessWrapper:
    def __init__(
        self, chrome_process: psutil.Process, launcher_process: subprocess.Popen
    ):
        self.chrome_process = chrome_process
        self.launcher_process = launcher_process
        self.pid = chrome_process.pid
        self.returncode = None

    def _poll_sync(self):
        try:
            is_running = self.chrome_process.is_running()
            if not is_running:
                if self.returncode is None:
                    self.returncode = 0
                return self.returncode
            return None
        except psutil.NoSuchProcess:
            if self.returncode is None:
                self.returncode = 0
            return self.returncode

    async def poll(self):
        return await asyncio.to_thread(self._poll_sync)

    def terminate(self):
        try:
            self.chrome_process.terminate()
        except psutil.NoSuchProcess:
            pass
        except Exception as e:
            logger.error(f"Error terminating Chrome process {self.pid}: {e}")

        try:
            if self.launcher_process and self.launcher_process.poll() is None:
                self.launcher_process.terminate()
        except Exception:
            pass

    def kill(self):
        try:
            self.chrome_process.kill()
        except psutil.NoSuchProcess:
            pass
        except Exception as e:
            logger.error(f"Error killing Chrome process {self.pid}: {e}")

        try:
            if self.launcher_process and self.launcher_process.poll() is None:
                self.launcher_process.kill()
        except Exception:
            pass

    def communicate(self):
        return (b"", b"")


class BrowserLauncher:
    """Launches browser sessions as separate processes with slot management"""

    def __init__(self):
        self.sessions: dict[str, BrowserSession] = {}
        self.terminated_sessions: list[TerminatedSession] = []

        self._session_lock = asyncio.Lock()
        self._port_lock = asyncio.Lock()
        self._used_ports: set = set()
        self._max_terminated_history = 50
        self._last_orphan_cleanup = None

        self._cached_machine_ip: str | None = None
        self._cached_public_ip: str | None = None
        self._is_aws_vm_cached: bool | None = None

        self._background_tasks: set[asyncio.Task] = set()
        self._cleanup_running = False
        self._http: Optional[aiohttp.ClientSession] = None
        self._worker_to_port: dict[str, int] = {}

        # Port state machine: {port: (state, worker_id, timestamp)}
        # States: "FREE" | "RESERVED" | "ACTIVE"
        self._port_state: dict[int, tuple[str, str, float]] = {}
        self._reservation_timeout = 90.0  # Seconds before RESERVED state expires

    async def _get_machine_ip(self) -> str:
        """Get machine's local IP address"""
        try:
            loop = asyncio.get_event_loop()
            hostname = await asyncio.to_thread(socket.gethostname)

            try:
                ip_address = await asyncio.wait_for(
                    loop.run_in_executor(None, socket.gethostbyname, hostname),
                    timeout=2.0,
                )
            except asyncio.TimeoutError:
                ip_address = "127.0.0.1"

            if ip_address.startswith("127."):
                try:
                    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    sock.setblocking(False)
                    await asyncio.wait_for(
                        loop.sock_connect(sock, ("8.8.8.8", 80)), timeout=2.0
                    )
                    ip_address = sock.getsockname()[0]
                    sock.close()
                except (asyncio.TimeoutError, OSError):
                    ip_address = "127.0.0.1"

            return ip_address
        except Exception as e:
            logger.error(f"Failed to get machine IP: {e}")
            return "127.0.0.1"

    async def _get_public_ip_async(self) -> str:
        """Get public IP for AWS VMs"""
        try:
            async with aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=3)
            ) as session:
                async with session.put(
                    "http://169.254.169.254/latest/api/token",
                    headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
                ) as token_response:  # type: aiohttp.ClientResponse
                    if token_response.status == 200:
                        token = await token_response.text()
                        async with session.get(
                            "http://169.254.169.254/latest/meta-data/public-ipv4",
                            headers={"X-aws-ec2-metadata-token": token},
                        ) as ip_response:  # type: aiohttp.ClientResponse
                            if ip_response.status == 200:
                                public_ip = (await ip_response.text()).strip()
                                if public_ip:
                                    return public_ip
            return await self._get_machine_ip()
        except Exception:
            return await self._get_machine_ip()

    def _is_aws_vm_sync(self) -> bool:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(1)
                result = s.connect_ex(("169.254.169.254", 80))
                return result == 0
        except Exception:
            return False

    async def _is_aws_vm(self) -> bool:
        return await asyncio.to_thread(self._is_aws_vm_sync)

    async def _get_http(self) -> aiohttp.ClientSession:
        """Return a shared aiohttp session. Lazily create if needed."""
        if self._http is None or self._http.closed:
            self._http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=1.0))
        return self._http

    async def _setup_port_forwarding_with_timeout(self, port: int):
        """
        DEPRECATED: Port forwarding is now handled by custom Chrome launcher script.

        This function is kept for backwards compatibility but is no longer called.
        The custom script (launch_chrome_port.cmd) already creates port forwarding.
        """
        logger.warning(
            f"_setup_port_forwarding_with_timeout called for port {port} - "
            f"This is deprecated. Port forwarding should be handled by custom launcher script."
        )
        try:
            await asyncio.wait_for(
                self._setup_windows_port_forwarding(port), timeout=15.0
            )
        except asyncio.TimeoutError:
            logger.warning(
                f"Port forwarding timeout for {port}, browser may not be accessible remotely"
            )
        except Exception as e:
            logger.error(
                f"Port forwarding failed for {port}: {e}, browser only accessible on localhost"
            )

    async def _setup_windows_port_forwarding(self, port: int):
        """
        DEPRECATED: Port forwarding is now handled by custom Chrome launcher script.

        This function is kept for backwards compatibility but should not be called.
        The custom script creates:
          1. netsh portproxy: LISTEN_IP:PORT -> 127.0.0.1:PORT
          2. Windows Firewall rule for the port
        """
        try:
            remove_cmd = [
                "netsh",
                "interface",
                "portproxy",
                "delete",
                "v4tov4",
                "listenaddress=0.0.0.0",
                f"listenport={port}",
            ]

            remove_proc = await asyncio.create_subprocess_exec(
                *remove_cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                await asyncio.wait_for(remove_proc.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                logger.warning(f"Initial netsh delete timeout for port {port}, killing")
                try:
                    remove_proc.kill()
                except Exception:
                    pass

            cmd = [
                "netsh",
                "interface",
                "portproxy",
                "add",
                "v4tov4",
                "listenaddress=0.0.0.0",
                f"listenport={port}",
                "connectaddress=127.0.0.1",
                f"connectport={port}",
            ]

            result = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )

            try:
                stdout, stderr = await asyncio.wait_for(
                    result.communicate(), timeout=5.0
                )
            except asyncio.TimeoutError:
                logger.warning(
                    f"netsh add command timeout for port {port}, killing process"
                )
                try:
                    result.kill()
                    await result.wait()
                except Exception:
                    pass
                raise

            if result.returncode != 0:
                error_msg = (
                    stderr.decode().strip()
                    if stderr
                    else stdout.decode().strip()
                    if stdout
                    else "No error details"
                )
                logger.error(f"Failed to set up port forwarding: {error_msg}")

                if "elevation" in error_msg.lower() or "admin" in error_msg.lower():
                    logger.error(
                        "WARNING: Port forwarding requires administrator privileges! "
                        "Please run this service as Administrator or grant necessary permissions."
                    )
            else:
                show_cmd = ["netsh", "interface", "portproxy", "show", "v4tov4"]
                result = await asyncio.create_subprocess_exec(
                    *show_cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                try:
                    stdout, _ = await asyncio.wait_for(
                        result.communicate(), timeout=5.0
                    )
                    if stdout and f"0.0.0.0:{port}" in stdout.decode():
                        logger.info(
                            f"Verified port forwarding is active for port {port}"
                        )
                except asyncio.TimeoutError:
                    logger.warning(f"netsh show command timeout for port {port}")
                    try:
                        result.kill()
                    except Exception:
                        pass

        except Exception as e:
            logger.error(f"Error setting up port forwarding: {e}")

    def _remove_windows_port_forwarding_bat(self, port: int):
        try:
            script_dir = os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
            bat_script = os.path.join(script_dir, "scripts", "cleanup_port.bat")

            if not os.path.exists(bat_script):
                logger.warning(f"cleanup_port.bat not found at {bat_script}")
                return

            subprocess.Popen(
                [bat_script, str(port)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW
                if hasattr(subprocess, "CREATE_NO_WINDOW")
                else 0,
            )
            logger.debug(f"Started background port cleanup for {port}")

        except Exception as e:
            logger.warning(f"Failed to start port cleanup script for port {port}: {e}")

    def _cleanup_profile_directory_bat(self, profile_dir: str):
        try:
            script_dir = os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
            bat_script = os.path.join(script_dir, "scripts", "cleanup_profile.bat")

            if not os.path.exists(bat_script):
                logger.warning(f"cleanup_profile.bat not found at {bat_script}")
                return

            subprocess.Popen(
                [bat_script, profile_dir],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW
                if hasattr(subprocess, "CREATE_NO_WINDOW")
                else 0,
            )
            logger.debug(
                f"Started background profile cleanup for {os.path.basename(profile_dir)}"
            )

        except Exception as e:
            logger.warning(
                f"Failed to start profile cleanup script for {os.path.basename(profile_dir)}: {e}"
            )

    def _cleanup_expired_session_bat(
        self, pid: int, port: int, profile_dir: str = None
    ):
        """
        Fire-and-forget session cleanup using BAT script (Windows only).
        Kills process, removes port forwarding, and optionally deletes profile.
        """
        try:
            system = platform.system().lower()
            if system != "windows":
                return False

            script_dir = os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
            bat_script = os.path.join(
                script_dir, "scripts", "cleanup_expired_session.bat"
            )

            if not os.path.exists(bat_script):
                logger.warning(f"cleanup_expired_session.bat not found at {bat_script}")
                return False

            args = [bat_script, str(pid), str(port)]
            if profile_dir:
                args.append(profile_dir)

            subprocess.Popen(
                args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW
                if hasattr(subprocess, "CREATE_NO_WINDOW")
                else 0,
            )
            logger.debug(
                f"Started background session cleanup | PID: {pid} | Port: {port}"
            )
            return True

        except Exception as e:
            logger.warning(f"Failed to start session cleanup script: {e}")
            return False

    async def _remove_windows_port_forwarding(self, port: int):
        proc = None
        try:
            cmd = [
                "netsh",
                "interface",
                "portproxy",
                "delete",
                "v4tov4",
                "listenaddress=0.0.0.0",
                f"listenport={port}",
            ]

            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )

            try:
                await asyncio.wait_for(proc.communicate(), timeout=1.5)
                logger.debug(f"Removed portproxy mapping for port {port}")
            except asyncio.TimeoutError:
                try:
                    proc.kill()
                    await asyncio.wait_for(proc.wait(), timeout=1.0)
                except asyncio.TimeoutError:
                    logger.warning(
                        f"netsh process for port {port} won't die - abandoning"
                    )
                except Exception:
                    pass

        except asyncio.TimeoutError:
            logger.warning(f"netsh timeout for port {port}")
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
        except Exception as e:
            logger.warning(f"Error removing port forwarding for {port}: {e}")
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass

    async def _release_port(self, port: int):
        """
        Safely release a port and clear all tracking structures.
        Idempotent - safe to call multiple times.
        """
        if not port:
            logger.warning("Attempted to release invalid port (None or 0)")
            return

        async with self._port_lock:
            # Clear legacy used_ports set (for backward compatibility)
            self._used_ports.discard(port)

            # Clear port state machine
            self._port_state.pop(port, None)

            # Clear any worker mappings pointing to this port
            for wid, p in list(self._worker_to_port.items()):
                if p == port:
                    self._worker_to_port.pop(wid, None)

            logger.debug(
                f"Port {port} released from all tracking | "
                f"Active ports: {len([s for s, (st, _, _) in self._port_state.items() if st == 'ACTIVE'])}"
            )

    async def _reserve_port_for_worker(self, worker_id: str) -> int:
        """
        Atomically reserve a port for a worker under lock.
        Returns port number or raises RuntimeError if no ports available.

        Port moves from FREE → RESERVED state.
        """
        async with self._port_lock:
            now = time.time()

            # Expire stale RESERVED states (>90s old)
            stale_ports = []
            for p, (st, wid, ts) in list(self._port_state.items()):
                if st == "RESERVED" and now - ts > self._reservation_timeout:
                    logger.warning(
                        f"Port {p} RESERVED by {wid[:8]} expired after {now - ts:.1f}s"
                    )
                    stale_ports.append(p)

            for p in stale_ports:
                self._port_state.pop(p, None)

            # Find a free port
            all_ports = list(
                range(settings.chrome_port_start, settings.chrome_port_end + 1)
            )
            random.shuffle(all_ports)

            for port in all_ports:
                st = self._port_state.get(port)
                # Port is candidate if not tracked or explicitly FREE
                if st is None or st[0] == "FREE":
                    # Verify port is actually free (socket probe)
                    if self._check_port_free(port):
                        # Atomically reserve it
                        self._port_state[port] = ("RESERVED", worker_id, now)
                        self._worker_to_port[worker_id] = port
                        logger.debug(
                            f"Port {port} RESERVED for worker {worker_id[:8]} | "
                            f"Reserved: {len([s for s, (st, _, _) in self._port_state.items() if st == 'RESERVED'])}, "
                            f"Active: {len([s for s, (st, _, _) in self._port_state.items() if st == 'ACTIVE'])}"
                        )
                        return port

            # No free ports found
            raise RuntimeError(
                f"No free ports found between {settings.chrome_port_start} and {settings.chrome_port_end}. "
                f"All ports in use or reserved."
            )

    async def _activate_reserved_port(self, worker_id: str, port: int):
        """
        Promote a RESERVED port to ACTIVE after successful launch.
        Idempotent - safe to call multiple times if already ACTIVE by same worker.

        Port moves from RESERVED → ACTIVE state.
        """
        async with self._port_lock:
            st = self._port_state.get(port)
            if st and st[0] == "RESERVED" and st[1] == worker_id:
                self._port_state[port] = ("ACTIVE", worker_id, time.time())
                logger.debug(
                    f"Port {port} ACTIVATED for worker {worker_id[:8]} | "
                    f"Active: {len([s for s, (st, _, _) in self._port_state.items() if st == 'ACTIVE'])}"
                )
            elif st and st[0] == "ACTIVE" and st[1] == worker_id:
                # Idempotent - already active by same worker
                return
            else:
                logger.warning(
                    f"Cannot activate port {port} for worker {worker_id[:8]} - "
                    f"current state: {st}"
                )

    async def _rollback_reserved_port(self, worker_id: str, port: int):
        """
        Release a RESERVED port after launch failure.
        Only succeeds if port is RESERVED by this worker.

        Port moves from RESERVED → FREE (removed from tracking).
        """
        async with self._port_lock:
            st = self._port_state.get(port)
            if st and st[0] == "RESERVED" and st[1] == worker_id:
                self._port_state.pop(port, None)
                self._worker_to_port.pop(worker_id, None)
                logger.debug(
                    f"Port {port} reservation ROLLED BACK for worker {worker_id[:8]}"
                )
            else:
                # Already cleaned up or wrong worker - that's okay
                self._worker_to_port.pop(worker_id, None)

    def _check_port_free(self, port: int) -> bool:
        """
        Port is free if we can bind the same address Chrome will bind.

        Windows-accurate: No SO_REUSEADDR (can mask conflicts), bind actual address.
        Custom launcher: Chrome binds to 127.0.0.1, test with connect_ex.
        Non-custom: Chrome binds to 0.0.0.0, test with bind.

        Uses 100ms timeout for fast localhost checks (reduced from 250ms for better performance).

        Returns True if port is free, False if in use or on any exception.
        Treats all errors as "port in use" to err on the safe side.
        """
        s = None
        try:
            if settings.use_custom_chrome_launcher:
                addr = "127.0.0.1"
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(0.1)  # 100ms timeout for localhost
                return s.connect_ex((addr, port)) != 0
            else:
                addr = "0.0.0.0"
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(0.1)  # 100ms timeout for localhost
                s.bind((addr, port))
                return True
        except Exception:
            # Treat all exceptions as "port in use" (safe default)
            return False
        finally:
            if s:
                try:
                    s.close()
                except Exception:
                    pass

    async def _find_free_port(
        self, start_port: int = None, max_port: int = None
    ) -> int:
        """
        DEPRECATED: Use _reserve_port_for_worker() instead.

        Find a random free port for Chrome debugging.
        This method uses legacy _used_ports tracking and is no longer used.
        """
        if start_port is None:
            start_port = settings.chrome_port_start
        if max_port is None:
            max_port = settings.chrome_port_end + 1

        logger.info(f"Searching for free port between {start_port} and {max_port}")

        all_ports = list(range(start_port, max_port))
        random.shuffle(all_ports)

        async with self._port_lock:
            used_ports_snapshot = self._used_ports.copy()
            logger.info(
                f"Total ports to check: {len(all_ports)}, Used ports: {sorted(used_ports_snapshot)}"
            )

        candidate_ports = [p for p in all_ports if p not in used_ports_snapshot]

        checked_count = 0
        for port in candidate_ports:
            checked_count += 1
            try:
                is_free = await asyncio.to_thread(self._check_port_free, port)

                if is_free:
                    async with self._port_lock:
                        if port not in self._used_ports:
                            self._used_ports.add(port)
                            logger.info(
                                f"Found free port: {port} (checked {checked_count} ports)"
                            )
                            return port
                        else:
                            logger.debug(
                                f"Port {port} was taken by another request, continuing"
                            )
                            continue

            except Exception as e:
                logger.warning(f"Error checking port {port}: {e}")
                continue

        logger.error(
            f"No free ports found between {start_port} and {max_port}. "
            f"Checked {checked_count} ports. "
            f"Currently used ports: {sorted(used_ports_snapshot)}"
        )
        raise RuntimeError(
            f"No free ports found between {start_port} and {max_port}. "
            f"Used: {len(used_ports_snapshot)} ports"
        )

    async def _send_callback_to_api(self, response: BrowserSessionResponse) -> bool:
        """Send browser launch response to API"""
        if (
            not settings.browser_api_callback_enabled
            or not settings.browser_api_callback_url
        ):
            return False

        try:
            response_dict = response.model_dump(mode="json")
            success, status_code, response_text = await send_post_request(
                url=settings.browser_api_callback_url, data=response_dict, timeout=30
            )

            if success:
                logger.info("Response sent successfully")
                return True
            else:
                logger.warning(f"API callback failed: {status_code}")
                return False

        except Exception as e:
            logger.error(f"API callback error: {e}")
            return False

    def has_available_slots(self) -> bool:
        """Check if there are available slots for new browser sessions"""
        return len(self.sessions) < settings.max_browser_instances

    def get_available_slots(self) -> int:
        """Get the number of available slots for new browser sessions"""
        return max(0, settings.max_browser_instances - len(self.sessions))

    def _has_free_port(self) -> bool:
        """
        Fast check if ports are available without OS scan.
        Prevents race conditions where SQS tasks claim ports simultaneously.

        Returns:
            True if at least one port is available in the range
        """
        total_ports = (settings.chrome_port_end - settings.chrome_port_start) + 1
        # Count ports in RESERVED or ACTIVE state (new state machine tracking)
        occupied_ports = len(
            [
                p
                for p, (st, _, _) in self._port_state.items()
                if st in ("RESERVED", "ACTIVE")
            ]
        )
        return occupied_ports < total_ports

    async def launch_browser_session(
        self, request: BrowserSessionRequest
    ) -> BrowserSessionResponse:
        worker_id = str(uuid.uuid4())

        machine_ip = self._cached_machine_ip or "127.0.0.1"
        public_ip = self._cached_public_ip or "127.0.0.1"

        if not self._cached_machine_ip or not self._cached_public_ip:
            logger.error("IP cache not initialized! This should never happen.")

        total_ports = (settings.chrome_port_end - settings.chrome_port_start) + 1
        async with self._port_lock:
            # Count ports in RESERVED or ACTIVE state (new state machine tracking)
            occupied_ports = len(
                [
                    p
                    for p, (st, _, _) in self._port_state.items()
                    if st in ("RESERVED", "ACTIVE")
                ]
            )
            if occupied_ports >= total_ports:
                reserved_count = len(
                    [
                        p
                        for p, (st, _, _) in self._port_state.items()
                        if st == "RESERVED"
                    ]
                )
                active_count = len(
                    [p for p, (st, _, _) in self._port_state.items() if st == "ACTIVE"]
                )
                msg = (
                    f"No free debug ports in range "
                    f"{settings.chrome_port_start}-{settings.chrome_port_end}. "
                    f"All {total_ports} ports exhausted "
                    f"(Reserved: {reserved_count}, Active: {active_count})."
                )
                logger.warning(msg)
                resp = BrowserSessionResponse(
                    status=RequestStatus.SLOT_FULL,
                    worker_id=worker_id,
                    machine_ip=public_ip,
                    debug_port=0,
                    requester_id=request.requester_id,
                    session_id=request.session_id,
                    error_message=msg,
                )
                if settings.browser_api_callback_enabled:
                    await self._send_callback_to_api(resp)
                return resp

        async with self._session_lock:
            if not self.has_available_slots():
                logger.warning(
                    f"[WARN] NO SLOTS AVAILABLE | Request rejected: {request.id} | "
                    f"Active browsers: {len(self.sessions)}/{settings.max_browser_instances} | "
                    f"Ports in use: {[s.debug_port for s in self.sessions.values()]}"
                )
                slot_full_response = BrowserSessionResponse(
                    status=RequestStatus.SLOT_FULL,
                    worker_id=worker_id,
                    machine_ip=public_ip,
                    debug_port=0,
                    requester_id=request.requester_id,
                    session_id=request.session_id,
                    error_message=f"No available slots on this launcher. Currently {len(self.sessions)}/{settings.max_browser_instances} slots are occupied. Please retry in a few minutes when a session becomes available. The request has been returned to the queue for processing by another available launcher.",
                )

                if settings.browser_api_callback_enabled:
                    await self._send_callback_to_api(slot_full_response)

                return slot_full_response

        debug_port = None
        process = None
        reserved_port = None
        user_data_dir = None

        try:
            # Atomically reserve a port (FREE → RESERVED)
            reserved_port = await self._reserve_port_for_worker(worker_id)
            debug_port = reserved_port

            user_data_dir = request.user_data_dir
            if not user_data_dir:
                system = platform.system().lower()
                if system == "windows" and settings.use_custom_chrome_launcher:
                    launcher_path = settings.chrome_launcher_cmd
                    basedir = os.path.dirname(launcher_path)
                    if not basedir or basedir == ".":
                        basedir = r"C:\Chrome-RDP"
                    user_data_dir = os.path.join(basedir, f"p{debug_port}")
                    await asyncio.to_thread(os.makedirs, basedir, exist_ok=True)
                else:
                    user_data_dir = os.path.join(
                        tempfile.gettempdir(), f"chrome_profile_p{debug_port}"
                    )
                await asyncio.to_thread(os.makedirs, user_data_dir, exist_ok=True)
            else:
                try:
                    user_data_dir = await asyncio.to_thread(
                        lambda p: os.path.abspath(os.path.realpath(p)), user_data_dir
                    )

                    allowed_bases = [
                        tempfile.gettempdir(),
                        "/tmp",
                        "/var/tmp",
                        os.path.expanduser("~/chrome_profiles"),
                    ]

                    if settings.use_custom_chrome_launcher:
                        launcher_path = settings.chrome_launcher_cmd
                        custom_basedir = os.path.dirname(launcher_path)
                        if custom_basedir and custom_basedir != ".":
                            allowed_bases.append(custom_basedir)

                    is_allowed = False
                    for base in allowed_bases:
                        try:
                            base_real = await asyncio.to_thread(
                                lambda b: os.path.abspath(os.path.realpath(b)), base
                            )
                            if (
                                user_data_dir.startswith(base_real + os.sep)
                                or user_data_dir == base_real
                            ):
                                is_allowed = True
                                break
                        except Exception:
                            continue

                    if not is_allowed:
                        raise ValueError(
                            f"User data directory must be within allowed paths: {allowed_bases}"
                        )

                    dir_name = os.path.basename(user_data_dir)
                    if not all(c.isalnum() or c in "-_" for c in dir_name):
                        raise ValueError(f"Invalid directory name: {dir_name}")

                except Exception as e:
                    raise ValueError(f"Invalid user_data_dir path: {e}")

            if (
                settings.use_custom_chrome_launcher
                and platform.system().lower() == "windows"
            ):
                process = await self._launch_chrome_custom(
                    debug_port, machine_ip, user_data_dir
                )
            else:
                chrome_cmd = await self._build_chrome_command(
                    debug_port=debug_port,
                    user_data_dir=user_data_dir,
                    proxy_config=request.proxy_config,
                    extensions=request.extensions,
                    chrome_args=request.chrome_args,
                )

                process = subprocess.Popen(
                    chrome_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                )

            host_for_probe = "127.0.0.1"
            devtools_deadline = min(90.0, settings.browser_timeout / 1000)

            poll_result = None
            if isinstance(process, ChromeProcessWrapper):
                poll_result = await process.poll()
            else:
                poll_result = process.poll()

            if poll_result is not None:
                raise RuntimeError(
                    f"Chrome process exited immediately with code: {poll_result}"
                )

            if not await self._wait_devtools(
                host_for_probe, debug_port, devtools_deadline
            ):
                if isinstance(process, ChromeProcessWrapper):
                    poll_result = await process.poll()
                else:
                    poll_result = process.poll()

                if poll_result is not None:
                    raise RuntimeError(
                        f"Chrome process exited during startup with code: {poll_result}"
                    )
                else:
                    raise RuntimeError(
                        f"Chrome DevTools not ready on {host_for_probe}:{debug_port} within {devtools_deadline}s"
                    )

            ttl_minutes = request.ttl_minutes

            if ttl_minutes > settings.hard_ttl_minutes:
                logger.warning(
                    f"Requested TTL {ttl_minutes} minutes exceeds hard limit {settings.hard_ttl_minutes} minutes. "
                    f"Using hard limit instead."
                )
                ttl_minutes = settings.hard_ttl_minutes

            # Capture process create_time for PID-reuse validation
            try:
                proc_for_create_time = psutil.Process(process.pid)
                process_create_time = proc_for_create_time.create_time()
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                process_create_time = None
                logger.warning(f"Could not capture create_time for PID {process.pid}")

            session_kwargs = {
                "worker_id": worker_id,
                "request_id": request.id,
                "machine_ip": machine_ip,
                "debug_port": debug_port,
                "process_id": process.pid,
                "process_create_time": process_create_time,
                "user_data_dir": user_data_dir,
                "expires_at": datetime.now(UTC) + timedelta(minutes=ttl_minutes),
                "websocket_url": f"ws://{public_ip}:{debug_port}/devtools/browser",
                "debug_url": f"http://{public_ip}:{debug_port}",
            }

            if request.session_id:
                session_kwargs["session_id"] = request.session_id

            session = BrowserSession(**session_kwargs)
            session.process_object = process

            async with self._session_lock:
                if len(self.sessions) >= settings.max_browser_instances:
                    logger.error(
                        f"Race condition detected: max instances reached during launch. "
                        f"Terminating newly launched browser. Worker: {worker_id}"
                    )
                    raise RuntimeError(
                        "Maximum browser instances reached during concurrent launch"
                    )
                self.sessions[worker_id] = session

            # Promote port from RESERVED → ACTIVE after successful launch
            await self._activate_reserved_port(worker_id, debug_port)
            reserved_port = None  # Prevent accidental rollback after activation

            logger.info(
                f"Browser launched | Worker: {worker_id[:8]} | Port: {debug_port}"
            )

            response = BrowserSessionResponse(
                status=RequestStatus.COMPLETED,
                worker_id=worker_id,
                machine_ip=public_ip,
                debug_port=debug_port,
                session_id=request.session_id
                if request.session_id
                else session.session_id,
                requester_id=request.requester_id,
                websocket_url=session.websocket_url,
                debug_url=session.debug_url,
                proxy_config=request.proxy_config,
                ttl_minutes=ttl_minutes,
                expires_at=session.expires_at,
            )

            if settings.browser_api_callback_enabled:
                await self._send_callback_to_api(response)

            return response

        except Exception as e:
            logger.error(f"Failed to launch browser session: {e}")

            # Rollback RESERVED port on any failure
            if reserved_port:
                await self._rollback_reserved_port(worker_id, reserved_port)

            async with self._session_lock:
                if worker_id in self.sessions:
                    del self.sessions[worker_id]
                    logger.debug(
                        f"Removed failed session {worker_id[:8]} from tracking"
                    )

            if process:
                try:
                    poll_result = None
                    if isinstance(process, ChromeProcessWrapper):
                        poll_result = await process.poll()
                    else:
                        poll_result = process.poll()

                    if poll_result is None:
                        process.terminate()
                        if isinstance(process, ChromeProcessWrapper):
                            poll_result = await process.poll()
                        else:
                            poll_result = process.poll()

                        if poll_result is None:
                            process.kill()
                except Exception as proc_error:
                    logger.warning(f"Failed to terminate Chrome process: {proc_error}")

            is_temp_profile = user_data_dir and (
                "chrome_profile_" in user_data_dir or "Chrome-RDP" in user_data_dir
            )

            if is_temp_profile:
                try:
                    if await asyncio.to_thread(os.path.exists, user_data_dir):
                        await asyncio.to_thread(
                            shutil.rmtree, user_data_dir, ignore_errors=True
                        )
                        logger.debug(
                            f"Cleaned up failed launch profile: {os.path.basename(user_data_dir)}"
                        )
                except Exception as cleanup_error:
                    logger.warning(f"Failed to clean up directory: {cleanup_error}")

            return BrowserSessionResponse(
                status=RequestStatus.FAILED,
                worker_id=worker_id,
                machine_ip=public_ip,
                debug_port=0,
                requester_id=request.requester_id,
                session_id=request.session_id,
                error_message=str(e),
            )

    async def _launch_chrome_custom(
        self, debug_port: int, machine_ip: str, user_data_dir: str
    ) -> Union[subprocess.Popen, ChromeProcessWrapper]:
        """
        Launch Chrome using custom launcher script with PID capture optimization.

        The launcher script outputs Chrome PID to stdout, eliminating slow port scanning.
        Falls back to fast psutil lookup if PID not captured.
        """
        if not await asyncio.to_thread(os.path.exists, settings.chrome_launcher_cmd):
            logger.warning(
                f"Custom Chrome launcher not found: {settings.chrome_launcher_cmd}"
            )
            raise FileNotFoundError(
                f"Chrome launcher not found: {settings.chrome_launcher_cmd}"
            )

        startupinfo = None
        if platform.system() == "Windows":
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW

        full_cmd = [
            "cmd.exe",
            "/c",
            settings.chrome_launcher_cmd,
            str(debug_port),
            machine_ip,
        ]
        process = subprocess.Popen(
            full_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            startupinfo=startupinfo,
        )

        chrome_pid = None
        try:
            loop = asyncio.get_event_loop()

            def _read_chunk():
                try:
                    return os.read(process.stdout.fileno(), 128)
                except Exception:
                    return b""

            buf = b""
            for _ in range(8):
                chunk = await asyncio.wait_for(
                    loop.run_in_executor(None, _read_chunk), timeout=0.25
                )
                if not chunk:
                    await asyncio.sleep(0.05)
                    continue
                buf += chunk
                for token in buf.decode(errors="ignore").split():
                    if token.isdigit():
                        chrome_pid = int(token)
                        break
                if chrome_pid:
                    logger.info(
                        f"Captured Chrome PID {chrome_pid} from launcher stdout | Port: {debug_port}"
                    )
                    break
        except asyncio.TimeoutError:
            logger.debug("Launcher stdout read timed out; using psutil fallback")
        except Exception as e:
            logger.debug(f"PID parse from launcher stdout failed: {e}")
        finally:
            try:
                if process.stdout and not process.stdout.closed:
                    process.stdout.close()
            except Exception:
                pass

        if chrome_pid is None:
            logger.debug(
                f"Using psutil fallback to find Chrome PID on port {debug_port}"
            )
            deadline = 8.0
            step = 0.25
            waited = 0.0

            while waited < deadline and chrome_pid is None:
                chrome_pid = await self._find_chrome_process_by_port(debug_port)
                if chrome_pid:
                    logger.info(
                        f"Found Chrome PID {chrome_pid} via psutil fallback | "
                        f"Port: {debug_port} | Took: {waited:.2f}s"
                    )
                    break
                await asyncio.sleep(step)
                waited += step

        if chrome_pid is None:
            try:
                if process.poll() is None:
                    process.terminate()
            except Exception:
                pass
            raise RuntimeError(
                f"Could not find Chrome process on port {debug_port} after 8s"
            )

        try:
            chrome_process = await asyncio.to_thread(psutil.Process, chrome_pid)
            process_name = chrome_process.name().lower()

            if "chrome" not in process_name:
                raise RuntimeError(
                    f"Found non-Chrome process '{process_name}' on port {debug_port}"
                )

            wrapper = ChromeProcessWrapper(chrome_process, process)
            logger.info(f"Created ChromeProcessWrapper for PID {chrome_pid}")

            host_for_probe = "127.0.0.1"
            if not await self._wait_devtools(host_for_probe, debug_port, 90.0):
                try:
                    wrapper.kill()
                except Exception:
                    pass
                raise RuntimeError(
                    f"DevTools not reachable on {host_for_probe}:{debug_port} within 90s"
                )

            return wrapper

        except psutil.NoSuchProcess:
            raise RuntimeError(
                f"Chrome process {chrome_pid} terminated immediately after launch"
            )
        except Exception as e:
            logger.error(f"Error creating Chrome wrapper: {e}")
            raise

    async def _wait_devtools(
        self, host: str, port: int, deadline: float = 90.0
    ) -> bool:
        """
        Wait for Chrome DevTools to become available with exponential backoff.
        Probes /json/version endpoint to verify Chrome is actually ready.

        Args:
            host: Host to connect to (usually 127.0.0.1)
            port: Debug port
            deadline: Maximum seconds to wait (default 90s)

        Returns:
            True if DevTools became available, False if timeout
        """
        url = f"http://{host}:{port}/json/version"
        delay = 0.25
        elapsed = 0.0
        attempt = 0
        burst = 3

        logger.info(
            f"Waiting for Chrome DevTools on {host}:{port} (deadline: {deadline}s)"
        )

        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=1.5)
        ) as session:
            while elapsed < deadline:
                attempt += 1
                try:
                    async with session.get(url) as response:  # type: aiohttp.ClientResponse
                        if response.status == 200:
                            browser_info = "unknown"
                            try:
                                data = await response.json()
                                browser_info = data.get("Browser", "unknown")
                            except Exception:
                                pass

                            logger.info(
                                f"DevTools ready on port {port} | "
                                f"Attempts: {attempt} | Elapsed: {elapsed:.2f}s | "
                                f"Browser: {browser_info}"
                            )
                            return True
                except Exception:
                    pass

                sleep_time = 0.1 if attempt <= burst else delay
                await asyncio.sleep(sleep_time)
                elapsed += sleep_time

                if attempt > burst:
                    delay = min(delay * 1.7, 2.0)

                if attempt % 10 == 0:
                    logger.debug(
                        f"Still waiting for DevTools on port {port} | "
                        f"Elapsed: {elapsed:.1f}s / {deadline}s"
                    )

        logger.error(
            f"DevTools not ready on {host}:{port} after {elapsed:.1f}s | "
            f"Attempts: {attempt}"
        )
        return False

    async def _find_chrome_process_by_port(self, port: int) -> int | None:
        """Fast PID lookup via kernel TCP table (no netstat shellout)"""
        lookup_start = asyncio.get_event_loop().time()

        def _find_pid_by_port():
            """Lookup PID using psutil TCP connections - much faster than netstat"""
            try:
                conns = psutil.net_connections(kind="tcp4")
                for c in conns:
                    if not c.laddr or c.status != psutil.CONN_LISTEN or not c.pid:
                        continue
                    if c.laddr.port == port and c.laddr.ip in ("127.0.0.1", "0.0.0.0"):
                        return c.pid
            except (psutil.AccessDenied, PermissionError):
                logger.debug("Access denied reading TCP table; trying broader scan")
                try:
                    for c in psutil.net_connections(kind="inet"):
                        if (
                            c.laddr
                            and c.laddr.port == port
                            and c.status == psutil.CONN_LISTEN
                            and c.pid
                        ):
                            return c.pid
                except Exception:
                    pass
            except Exception as e:
                logger.debug(f"psutil net_connections failed: {e}")
            return None

        try:
            pid = await asyncio.to_thread(_find_pid_by_port)
            dur = asyncio.get_event_loop().time() - lookup_start
            if pid:
                logger.info(f"Found PID {pid} on port {port} | {dur:.3f}s")
            else:
                logger.debug(f"No PID found on port {port} | {dur:.3f}s")
            return pid
        except Exception as e:
            logger.error(f"PID lookup error on port {port}: {e}")
            return None

    async def _find_chrome_executable(self) -> str:
        """Find Chrome executable based on the operating system"""
        system = platform.system().lower()
        logger.debug(f"Finding Chrome executable on {system}")

        if system == "windows":
            chrome_paths = [
                "C:\\\\Program Files\\\\Google\\\\Chrome\\\\Application\\\\chrome.exe",
                "C:\\\\Program Files (x86)\\\\Google\\\\Chrome\\\\Application\\\\chrome.exe",
                os.path.expandvars(
                    "%LOCALAPPDATA%\\\\Google\\\\Chrome\\\\Application\\\\chrome.exe"
                ),
                os.path.expandvars(
                    "%PROGRAMFILES%\\\\Google\\\\Chrome\\\\Application\\\\chrome.exe"
                ),
                os.path.expandvars(
                    "%PROGRAMFILES(X86)%\\\\Google\\\\Chrome\\\\Application\\\\chrome.exe"
                ),
            ]
        elif system == "darwin":
            chrome_paths = [
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                "/Applications/Chromium.app/Contents/MacOS/Chromium",
                os.path.expanduser(
                    "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                ),
            ]
        elif system == "linux":
            chrome_paths = [
                "/usr/bin/google-chrome",
                "/usr/bin/google-chrome-stable",
                "/usr/bin/chromium",
                "/usr/bin/chromium-browser",
                "/usr/local/bin/chrome",
                "/snap/bin/chromium",
                "/opt/google/chrome/google-chrome",
            ]
        else:
            raise RuntimeError(f"Unsupported operating system: {system}")

        for path in chrome_paths:
            if await asyncio.to_thread(os.path.exists, path):
                if await asyncio.to_thread(os.access, path, os.X_OK):
                    logger.info(f"Found Chrome at: {path}")
                    return path
                else:
                    logger.warning(f"Chrome found at {path} but is not executable")

        for cmd in ["google-chrome", "chrome", "chromium", "chromium-browser"]:
            chrome_path = await asyncio.to_thread(shutil.which, cmd)
            if chrome_path:
                logger.info(f"Found Chrome in PATH: {chrome_path}")
                return chrome_path

        raise RuntimeError(f"Chrome executable not found on {system} system")

    async def _build_chrome_command(
        self,
        debug_port: int,
        user_data_dir: str,
        proxy_config: dict[str, str] | None = None,
        extensions: list | None = None,
        chrome_args: list | None = None,
    ) -> list:
        """Build Chrome launch command with arguments"""
        chrome_exe = await self._find_chrome_executable()

        cmd = [
            chrome_exe,
            f"--remote-debugging-port={debug_port}",
            "--remote-debugging-address=0.0.0.0",
            f"--user-data-dir={user_data_dir}",
            "--no-first-run",
            "--no-default-browser-check",
            "--enable-automation",
            "--disable-background-timer-throttling",
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--disable-features=TranslateUI",
            "--disable-ipc-flooding-protection",
            "--disable-default-apps",
            "--disable-hang-monitor",
            "--disable-prompt-on-repost",
            "--disable-sync",
            "--metrics-recording-only",
            "--no-service-autorun",
            "--password-store=basic",
            "--disable-extensions",
            "--disable-component-extensions-with-background-pages",
            "--disable-background-networking",
            "--disable-breakpad",
            "--disable-component-update",
            "--disable-domain-reliability",
            "--disable-features=OptimizationHints,MediaRouter",
            "--disable-client-side-phishing-detection",
        ]

        if proxy_config:
            proxy_server = proxy_config.get("server")
            if proxy_server:
                if not isinstance(proxy_server, str) or len(proxy_server) > 500:
                    logger.warning(
                        f"Invalid proxy server format, skipping: {proxy_server}"
                    )
                else:
                    safe_proxy = (
                        proxy_server.replace('"', "")
                        .replace("'", "")
                        .replace(";", "")
                        .replace("&", "")
                    )
                    if safe_proxy != proxy_server:
                        logger.warning(
                            "Proxy server contained unsafe characters that were removed"
                        )
                    cmd.append(f"--proxy-server={safe_proxy}")

            bypass_list = proxy_config.get("bypass_list", "<-loopback>;*.local")
            if isinstance(bypass_list, str) and len(bypass_list) < 1000:
                cmd.append(f"--proxy-bypass-list={bypass_list}")

        if extensions:
            for ext_path in extensions:
                if await asyncio.to_thread(os.path.exists, ext_path):
                    cmd.append(f"--load-extension={ext_path}")

        if chrome_args:
            dangerous_args = {
                "--disable-web-security",
                "--allow-file-access-from-files",
                "--allow-file-access",
                "--allow-running-insecure-content",
                "--disable-site-isolation-trials",
                "--no-sandbox",
                "--disable-setuid-sandbox",
                "--disable-namespace-sandbox",
                "--disable-seccomp-filter-sandbox",
                "--allow-sandbox-debugging",
                "--enable-logging",
                "--log-file",
                "--enable-dbus",
                "--remote-debugging-address",
                "--remote-debugging-port",
                "--user-data-dir",
                "--crash-dumps-dir",
                "--homedir",
                "--disk-cache-dir",
                "--enable-local-file-accesses",
                "--unlimited-storage",
                "--allow-cross-origin-auth-prompt",
                "--password-store",
                "--enable-automation",
            }

            safe_arg_pattern = r"^--[a-z0-9\-]+(=[a-z0-9\-_\.,:/]+)?$"

            safe_args = []
            for arg in chrome_args:
                if not isinstance(arg, str):
                    logger.warning(f"Skipping non-string chrome arg: {arg}")
                    continue

                if not arg.startswith("--"):
                    logger.warning(f"Skipping chrome arg not starting with --: {arg}")
                    continue

                arg_name = arg.split("=")[0].lower()
                if arg_name in dangerous_args:
                    logger.warning(f"Blocking dangerous chrome arg: {arg}")
                    continue

                if not re.match(safe_arg_pattern, arg, re.IGNORECASE):
                    logger.warning(f"Skipping chrome arg with invalid format: {arg}")
                    continue

                if "=" in arg:
                    arg_key, arg_value = arg.split("=", 1)

                    if any(
                        path_word in arg_key for path_word in ["dir", "path", "file"]
                    ):
                        logger.warning(
                            f"Blocking chrome arg with path reference: {arg}"
                        )
                        continue

                    if any(
                        proto in arg_value
                        for proto in ["http://", "https://", "file://", "ftp://"]
                    ):
                        logger.warning(f"Blocking chrome arg with URL: {arg}")
                        continue

                safe_args.append(arg)

            if len(safe_args) < len(chrome_args):
                logger.warning(
                    f"Filtered {len(chrome_args) - len(safe_args)} unsafe chrome arguments"
                )

            cmd.extend(safe_args)

        return cmd

    async def terminate_session(
        self, worker_id: str, termination_reason: str = "killed"
    ) -> bool:
        """Terminate a browser session with timeout protection"""
        session_data = None

        async with self._session_lock:
            session = self.sessions.get(worker_id)
            if not session:
                logger.info(f"Session {worker_id} not found or already cleaned up")
                return False

            session_data = {
                "process_id": session.process_id,
                "process_create_time": getattr(session, "process_create_time", None),
                "debug_port": session.debug_port,
                "user_data_dir": session.user_data_dir,
                "created_at": session.created_at,
                "worker_id": session.worker_id,
                "request_id": session.request_id,
                "machine_ip": session.machine_ip,
                "session_id": session.session_id
                if hasattr(session, "session_id")
                else None,
            }

            del self.sessions[worker_id]
            # Note: _worker_to_port cleanup handled by _release_port() later

        killed = True
        pid = None  # Initialize to prevent "referenced before assignment" error
        try:
            pid = session_data["process_id"]

            if pid:
                system = platform.system().lower()

                if system == "windows":
                    # Use taskkill /T to kill entire process tree
                    # This is the most reliable way on Windows to kill Chrome and all children
                    try:
                        proc = await asyncio.create_subprocess_exec(
                            "taskkill",
                            "/F",
                            "/T",
                            "/PID",
                            str(pid),
                            stdout=asyncio.subprocess.DEVNULL,
                            stderr=asyncio.subprocess.DEVNULL,
                        )
                        # Wait up to 10 seconds for taskkill to complete
                        # (handles cases with 20+ Chrome child processes)
                        try:
                            await asyncio.wait_for(proc.wait(), timeout=10.0)
                        except asyncio.TimeoutError:
                            logger.warning(f"taskkill timeout for PID {pid} after 10s")
                            killed = False

                        # Verify process is actually dead
                        await asyncio.sleep(0.2)
                        if await asyncio.to_thread(psutil.pid_exists, pid):
                            logger.warning(f"Process {pid} still alive after taskkill")
                            killed = False
                        else:
                            logger.debug(
                                f"Successfully killed process tree for PID {pid}"
                            )
                    except Exception as e:
                        logger.error(f"Failed to kill process {pid}: {e}")
                        killed = False
                else:
                    # Linux/Mac: Kill children first, then parent
                    try:
                        parent = psutil.Process(pid)
                        children = parent.children(recursive=True)

                        # Kill all children first (bottom-up)
                        for child in children:
                            try:
                                child.kill()
                            except (psutil.NoSuchProcess, psutil.AccessDenied):
                                pass

                        # Kill parent
                        await asyncio.to_thread(os.kill, pid, 9)  # SIGKILL

                        # Wait longer for all Chrome processes to die (up to 10s total)
                        # Check multiple times with exponential backoff
                        max_wait = 10.0
                        elapsed = 0.0
                        wait_interval = 0.2

                        while elapsed < max_wait:
                            await asyncio.sleep(wait_interval)
                            elapsed += wait_interval

                            if not await asyncio.to_thread(psutil.pid_exists, pid):
                                logger.debug(
                                    f"Successfully killed process tree for PID {pid} in {elapsed:.1f}s"
                                )
                                break

                            # Exponential backoff: increase wait time
                            wait_interval = min(wait_interval * 1.5, 1.0)
                        else:
                            # Timeout reached, process still alive
                            logger.warning(
                                f"Process {pid} still alive after {max_wait}s"
                            )
                            killed = False
                    except (psutil.NoSuchProcess, ProcessLookupError):
                        pass  # Already dead
                    except Exception as e:
                        logger.error(f"Failed to kill process {pid}: {e}")
                        killed = False

            duration = (datetime.now(UTC) - session_data["created_at"]).total_seconds()
            logger.info(
                f"Browser terminated | Worker: {worker_id[:8]} | "
                f"Reason: {termination_reason} | "
                f"Duration: {duration:.1f}s"
            )
            terminated = TerminatedSession(
                worker_id=session_data["worker_id"],
                request_id=session_data["request_id"],
                machine_ip=session_data["machine_ip"],
                debug_port=session_data["debug_port"],
                process_id=session_data["process_id"],
                termination_reason=termination_reason,
                exit_code=None,
                session_duration_seconds=duration,
            )
            self.terminated_sessions.append(terminated)
            if len(self.terminated_sessions) > self._max_terminated_history:
                self.terminated_sessions = self.terminated_sessions[
                    -self._max_terminated_history :
                ]

            user_data_dir = session_data.get("user_data_dir")
            is_temp_profile = user_data_dir and (
                "chrome_profile_" in user_data_dir or "Chrome-RDP" in user_data_dir
            )

            if is_temp_profile and not settings.profile_reuse_enabled:
                system = platform.system().lower()
                if system == "windows":
                    self._cleanup_profile_directory_bat(user_data_dir)
                else:
                    task = asyncio.create_task(
                        self._cleanup_profile_directory_async(user_data_dir)
                    )
                    self._background_tasks.add(task)
                    task.add_done_callback(self._background_tasks.discard)

        except Exception as e:
            logger.error(f"Failed to terminate session {worker_id}: {e}")
            killed = False
        finally:
            # Final PID check BEFORE releasing resources
            try:
                pid = session_data.get("process_id") if session_data else None
                if pid and killed:
                    if await asyncio.to_thread(psutil.pid_exists, pid):
                        killed = False
                        logger.warning(
                            f"Process {pid} still alive after termination attempt - "
                            f"attempting aggressive force kill"
                        )
                        # Aggressive force kill attempt with PID-reuse validation
                        try:
                            proc = psutil.Process(pid)
                            # Validate PID hasn't been reused (compare create_time)
                            process_create_time = session_data.get(
                                "process_create_time"
                            )

                            # Conservative fallback: only kill if we can verify it's the same process
                            if process_create_time is None:
                                # Fallback: verify process name and cmdline match our Chrome instance
                                try:
                                    name_ok = (
                                        proc.name()
                                        .lower()
                                        .startswith(("chrome", "msedge"))
                                    )
                                    cmd = (
                                        " ".join(proc.cmdline())
                                        if proc.cmdline()
                                        else ""
                                    )
                                    port_str = f"--remote-debugging-port={session_data.get('debug_port')}"
                                    if not (name_ok and port_str in cmd):
                                        logger.warning(
                                            f"PID {pid} has no stored create_time and fallback guards failed - "
                                            f"skipping aggressive kill to avoid potential PID-reuse race"
                                        )
                                        proc = None
                                    else:
                                        logger.info(
                                            f"PID {pid} has no create_time but name/cmdline match - "
                                            f"proceeding with aggressive kill"
                                        )
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    logger.warning(
                                        f"PID {pid} - cannot verify process identity, skipping kill"
                                    )
                                    proc = None
                            else:
                                # We have create_time, validate it matches
                                current_create_time = proc.create_time()
                                time_diff = abs(
                                    current_create_time - process_create_time
                                )
                                if time_diff > 1.0:
                                    logger.warning(
                                        f"PID {pid} create_time changed (diff: {time_diff:.2f}s) - "
                                        f"skipping aggressive kill to avoid PID-reuse race"
                                    )
                                    proc = None

                            if proc:
                                # Kill all children first
                                for child in proc.children(recursive=True):
                                    try:
                                        child.kill()
                                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                                        pass
                                # Force kill parent
                                proc.kill()
                                # Wait briefly and check again
                                await asyncio.sleep(0.5)
                                if not await asyncio.to_thread(psutil.pid_exists, pid):
                                    killed = True
                                    logger.info(
                                        f"Aggressive kill succeeded for PID {pid}"
                                    )
                        except (
                            psutil.NoSuchProcess,
                            psutil.AccessDenied,
                            Exception,
                        ) as e:
                            logger.warning(f"Aggressive kill failed for PID {pid}: {e}")
            except Exception:
                pass

            if session_data:
                try:
                    # Always release port to prevent leaks
                    # Even if process is alive, port will be reused when process dies
                    await self._release_port(session_data["debug_port"])
                    if not killed and pid:
                        logger.warning(
                            f"Port {session_data['debug_port']} released despite process {pid} still running - "
                            f"port may be in use until process dies"
                        )
                except Exception as e:
                    logger.error(
                        f"Failed to release port {session_data['debug_port']}: {e}"
                    )

            try:
                idle_tracking = getattr(self, "_idle_tracking", None)
                if idle_tracking is not None and worker_id in idle_tracking:
                    del idle_tracking[worker_id]
                    logger.debug(
                        f"Cleaned up idle tracking for session {worker_id[:8]}"
                    )
                idle_checks = getattr(self, "_idle_check_count", None)
                if idle_checks is not None and worker_id in idle_checks:
                    del idle_checks[worker_id]
            except Exception as e:
                logger.debug(f"Idle-tracking cleanup skipped: {e}")

            if session_data:
                try:
                    system = platform.system().lower()
                    # Always cleanup port-proxy on Windows (unconditional)
                    if system == "windows":
                        self._remove_windows_port_forwarding_bat(
                            session_data["debug_port"]
                        )
                except Exception as e:
                    logger.error(
                        f"Failed to cleanup port forwarding for {session_data['debug_port']}: {e}"
                    )

        return killed

    async def _cleanup_profile_directory_async(self, user_data_dir: str):
        """Async profile cleanup for Linux/Mac (fire-and-forget)"""
        try:
            if await asyncio.to_thread(os.path.exists, user_data_dir):
                await asyncio.to_thread(
                    shutil.rmtree, user_data_dir, ignore_errors=True
                )
        except Exception:
            pass

    def cleanup_old_profiles_bat(self):
        """
        Fire-and-forget old profile cleanup using BAT script.
        Runs in background to delete profile FOLDERS (not files) older than configured hours.
        Only deletes directories matching profile patterns (p*, chrome_profile_*).
        """
        try:
            system = platform.system().lower()
            if system != "windows":
                logger.debug("BAT script cleanup only available on Windows")
                return

            if not settings.profile_reuse_enabled:
                logger.debug("Profile reuse disabled - skipping old profile cleanup")
                return

            if settings.use_custom_chrome_launcher:
                launcher_path = settings.chrome_launcher_cmd
                basedir = os.path.dirname(launcher_path)
                if not basedir or basedir == ".":
                    basedir = r"C:\Chrome-RDP"
            else:
                basedir = tempfile.gettempdir()

            script_dir = os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            )
            bat_script = os.path.join(script_dir, "scripts", "cleanup_old_profiles.bat")

            if not os.path.exists(bat_script):
                logger.warning(f"cleanup_old_profiles.bat not found at {bat_script}")
                return

            subprocess.Popen(
                [
                    bat_script,
                    basedir,
                    str(settings.profile_max_age_hours),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=subprocess.CREATE_NO_WINDOW
                if hasattr(subprocess, "CREATE_NO_WINDOW")
                else 0,
            )
            logger.info(
                f"Started background cleanup for profile folders older than {settings.profile_max_age_hours}h in {basedir}"
            )

        except Exception as e:
            logger.warning(f"Failed to start old profile cleanup script: {e}")

    async def _check_chrome_activity(self, debug_port: int) -> tuple[bool, bool, bool]:
        """Fast CDP activity monitoring with TCP pre-probe and shared HTTP session.

        Returns:
            tuple[bool, bool, bool]: (has_pages, has_real_content, has_websocket)
            - has_pages: True if browser has any pages open
            - has_real_content: True if browser has any non-blank page
            - has_websocket: True if any page has an active WebSocket connection
        """
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.1)
            try:
                if s.connect_ex(("127.0.0.1", debug_port)) != 0:
                    return (False, False, False)
            finally:
                try:
                    s.close()
                except Exception:
                    pass
        except Exception:
            return (False, False, False)

        try:
            http = await self._get_http()
            url = f"http://127.0.0.1:{debug_port}/json/list"
            async with http.get(url) as response:
                if response.status != 200:
                    logger.debug(
                        f"Chrome debug API returned {response.status} on port {debug_port}"
                    )
                    return (False, False, False)

                content = await response.text()
                if not content or content.strip() == "":
                    logger.debug(
                        f"Chrome debug API returned empty response on port {debug_port}"
                    )
                    return (False, False, False)

            try:
                targets = json.loads(content)
            except json.JSONDecodeError:
                logger.debug(
                    f"Chrome debug API returned invalid JSON on port {debug_port}"
                )
                return (False, False, False)

            if not isinstance(targets, list):
                logger.debug(
                    f"Chrome debug API returned unexpected format on port {debug_port}"
                )
                return (False, False, False)

            page_count = 0
            has_real_content = False
            has_websocket = False

            for t in targets:
                if not isinstance(t, dict):
                    continue
                if t.get("type") == "page":
                    page_count += 1
                    url_str = t.get("url", "")

                    if url_str not in [
                        "about:blank",
                        "chrome://newtab/",
                        "chrome://new-tab-page/",
                        "",
                        "data:",
                    ]:
                        has_real_content = True

                    if "webSocketDebuggerUrl" in t:
                        has_websocket = True

            has_pages = page_count > 0

            if has_pages:
                logger.debug(
                    f"Port {debug_port} has {page_count} page(s), real_content={has_real_content}, websocket={has_websocket}"
                )
            else:
                logger.debug(f"Port {debug_port} has no pages - browser disconnected")

            return (has_pages, has_real_content, has_websocket)

        except aiohttp.ClientError as e:
            logger.debug(
                f"Chrome debug API connection failed on port {debug_port}: {e}"
            )
            return (False, False, False)
        except asyncio.TimeoutError:
            logger.debug(f"Chrome debug API timeout on port {debug_port}")
            return (False, False, False)
        except Exception as e:
            logger.debug(f"Error checking Chrome activity on port {debug_port}: {e}")
            return (False, False, False)

    async def cleanup_expired_sessions(self):
        """Clean up expired browser sessions and detect externally terminated browsers"""
        if self._cleanup_running:
            logger.warning(
                "Cleanup already running - skipping this cycle to prevent overlap"
            )
            return

        self._cleanup_running = True
        try:
            cleanup_start = asyncio.get_event_loop().time()
            now = datetime.now(UTC)
            sessions_to_check = list(self.sessions.items())
            terminated_count = 0
            timeout_count = 0
            skipped_count = 0

            GLOBAL_CLEANUP_TIMEOUT = 120.0
            PER_SESSION_TIMEOUT = 10.0

            for worker_id, session in sessions_to_check:
                elapsed = asyncio.get_event_loop().time() - cleanup_start
                if elapsed > GLOBAL_CLEANUP_TIMEOUT:
                    remaining_sessions = len(sessions_to_check) - (
                        terminated_count + timeout_count + skipped_count
                    )
                    logger.warning(
                        f"Cleanup global timeout ({GLOBAL_CLEANUP_TIMEOUT}s) exceeded - "
                        f"skipping {remaining_sessions} remaining sessions"
                    )
                    break

                try:
                    remaining_time = max(1.0, GLOBAL_CLEANUP_TIMEOUT - elapsed)
                    session_timeout = min(PER_SESSION_TIMEOUT, remaining_time)

                    await asyncio.wait_for(
                        self._check_and_cleanup_session(worker_id, session, now),
                        timeout=session_timeout,
                    )
                    if worker_id not in self.sessions:
                        terminated_count += 1
                except asyncio.TimeoutError:
                    timeout_count += 1
                    logger.warning(
                        f"Session check timeout for {worker_id[:8]} | Port: {session.debug_port} - skipping"
                    )
                except Exception as e:
                    logger.error(f"Error checking session {worker_id[:8]}: {e}")
                    skipped_count += 1

            cleanup_duration = asyncio.get_event_loop().time() - cleanup_start

            if terminated_count > 0 or timeout_count > 0 or skipped_count > 0:
                logger.info(
                    f"Cleanup complete | Terminated: {terminated_count} | Timeouts: {timeout_count} | Skipped: {skipped_count} | "
                    f"Active: {len(self.sessions)}/{settings.max_browser_instances} | "
                    f"Duration: {cleanup_duration:.2f}s"
                )
            else:
                logger.debug(
                    f"Cleanup cycle complete | Active: {len(self.sessions)}/{settings.max_browser_instances} | "
                    f"Duration: {cleanup_duration:.2f}s"
                )
        finally:
            self._cleanup_running = False

    async def _check_and_cleanup_session(
        self, worker_id: str, session: BrowserSession, now: datetime
    ):
        """Check a single session and clean up if needed - with timeout protection"""
        check_start_time = asyncio.get_event_loop().time()

        session_age = (now - session.created_at).total_seconds() / 60

        if session_age > settings.hard_ttl_minutes:
            logger.warning(
                f"Session {worker_id} exceeded hard TTL limit ({session_age:.1f} > {settings.hard_ttl_minutes} min) - "
                f"forcing termination regardless of connections | Port: {session.debug_port}"
            )
            await self.terminate_session(worker_id, "hard_ttl_exceeded")
            return

        if session.expires_at < now:
            logger.info(
                f"Session {worker_id} has expired (TTL reached) - terminating | "
                f"Port: {session.debug_port}"
            )
            await self.terminate_session(worker_id, "expired")
            return

        process_is_running = True
        exit_code = None

        if not session.process_id:
            logger.warning(
                f"Session {worker_id} has no process_id - cannot check if running"
            )
            return

        process_check_start = asyncio.get_event_loop().time()
        try:
            if hasattr(session, "process_object") and session.process_object:
                if isinstance(session.process_object, ChromeProcessWrapper):
                    poll_result = await asyncio.wait_for(
                        session.process_object.poll(), timeout=3.0
                    )
                    if poll_result is not None:
                        process_is_running = False
                        exit_code = poll_result
                else:
                    poll_result = session.process_object.poll()
                    if poll_result is not None:
                        process_is_running = False
                        exit_code = poll_result
            else:

                def check_process_running(pid):
                    try:
                        proc = psutil.Process(pid)
                        is_running = proc.is_running()
                        returncode = (
                            proc.returncode if hasattr(proc, "returncode") else 0
                        )
                        return is_running, returncode
                    except psutil.NoSuchProcess:
                        return False, 0

                process_is_running, exit_code = await asyncio.wait_for(
                    asyncio.to_thread(check_process_running, session.process_id),
                    timeout=5.0,
                )

            process_check_duration = (
                asyncio.get_event_loop().time() - process_check_start
            )
            logger.debug(
                f"Process check completed | Worker: {worker_id[:8]} | Port: {session.debug_port} | "
                f"Duration: {process_check_duration:.2f}s | Status: {'running' if process_is_running else 'stopped'}"
            )

        except asyncio.TimeoutError:
            process_check_duration = (
                asyncio.get_event_loop().time() - process_check_start
            )
            logger.warning(
                f"Process check timeout | Worker: {worker_id[:8]} | Port: {session.debug_port} | "
                f"Duration: {process_check_duration:.2f}s (exceeded limit)"
            )
            return
        except psutil.NoSuchProcess:
            process_is_running = False
            exit_code = 0

        if process_is_running:
            session_age_seconds = (now - session.created_at).total_seconds()

            (
                has_pages,
                has_real_content,
                has_websocket,
            ) = await self._check_chrome_activity(session.debug_port)

            # Mark session as navigated if it has real content
            if has_real_content and not session.has_navigated_away:
                session.has_navigated_away = True
                logger.info(
                    f"Session {worker_id[:8]} navigated to real content - marking as active"
                )

            # Terminate sessions that never left about:blank after grace period
            # This handles browsers launched but never used by automation tools
            if not session.has_navigated_away and session_age_seconds > 90:
                logger.warning(
                    f"Session {worker_id[:8]} never used (only about:blank) for {session_age_seconds:.0f}s - terminating"
                )
                await self.terminate_session(worker_id, "never_used")
                return

        if not process_is_running and exit_code is not None:
            if exit_code != 0:
                termination_reason = "crashed"
                logger.warning(
                    f"Browser crashed | Worker: {worker_id[:8]} | Exit: {exit_code}"
                )
            else:
                termination_reason = "closed"
                logger.info(f"Browser closed | Worker: {worker_id[:8]}")

            system = platform.system().lower()
            if system == "windows":
                profile_dir = (
                    session.user_data_dir if hasattr(session, "user_data_dir") else None
                )
                is_temp_profile = profile_dir and (
                    "chrome_profile_" in profile_dir or "Chrome-RDP" in profile_dir
                )

                cleanup_profile = (
                    profile_dir
                    if (is_temp_profile and not settings.profile_reuse_enabled)
                    else None
                )

                if self._cleanup_expired_session_bat(
                    session.process_id, session.debug_port, cleanup_profile
                ):
                    await self._cleanup_terminated_session_tracking_only(
                        worker_id, termination_reason, exit_code
                    )
                else:
                    await self._cleanup_terminated_session(
                        worker_id, termination_reason, exit_code
                    )
            else:
                await self._cleanup_terminated_session(
                    worker_id, termination_reason, exit_code
                )

        total_check_duration = asyncio.get_event_loop().time() - check_start_time
        if total_check_duration > 5.0:
            logger.info(
                f"Session check slow | Worker: {worker_id[:8]} | Port: {session.debug_port} | "
                f"Total duration: {total_check_duration:.2f}s"
            )
        else:
            logger.debug(
                f"Session check complete | Worker: {worker_id[:8]} | "
                f"Total duration: {total_check_duration:.2f}s"
            )

    async def _cleanup_terminated_session_tracking_only(
        self,
        worker_id: str,
        termination_reason: str = "unknown",
        exit_code: int | None = None,
    ):
        """
        Update session tracking only (for when BAT script handles actual cleanup).
        This is instant and non-blocking - just updates internal state.
        """
        session = None
        debug_port = None

        async with self._session_lock:
            session = self.sessions.get(worker_id)
            if not session:
                logger.warning(f"Session {worker_id} not found for cleanup")
                stale_port = self._worker_to_port.get(worker_id)
                self.terminated_sessions.append(
                    TerminatedSession(
                        worker_id=worker_id,
                        request_id=None,
                        machine_ip=None,
                        debug_port=stale_port,
                        process_id=None,
                        termination_reason=termination_reason,
                        exit_code=exit_code,
                        session_duration_seconds=0.0,
                    )
                )
                if stale_port:
                    await self._release_port(stale_port)
                return

            debug_port = session.debug_port
            duration = (datetime.now(UTC) - session.created_at).total_seconds()

            terminated = TerminatedSession(
                worker_id=session.worker_id,
                request_id=session.request_id,
                machine_ip=session.machine_ip,
                debug_port=session.debug_port,
                process_id=session.process_id,
                termination_reason=termination_reason,
                exit_code=exit_code,
                session_duration_seconds=duration,
            )

            self.terminated_sessions.append(terminated)

            if len(self.terminated_sessions) > self._max_terminated_history:
                self.terminated_sessions = self.terminated_sessions[
                    -self._max_terminated_history :
                ]

            logger.info(
                f"Session cleanup delegated to BAT | {worker_id[:8]} | "
                f"Port: {debug_port} | Duration: {duration:.1f}s"
            )

            if worker_id in self.sessions:
                del self.sessions[worker_id]
            # Note: _worker_to_port cleanup handled by _release_port() below

        if debug_port:
            await self._release_port(debug_port)  # Clears _worker_to_port

    async def _cleanup_terminated_session(
        self,
        worker_id: str,
        termination_reason: str = "unknown",
        exit_code: int | None = None,
    ):
        """Clean up a session that was terminated externally"""
        session = None
        debug_port = None

        async with self._session_lock:
            session = self.sessions.get(worker_id)
            if not session:
                logger.warning(f"Session {worker_id} not found for cleanup")
                stale_port = self._worker_to_port.get(worker_id)
                self.terminated_sessions.append(
                    TerminatedSession(
                        worker_id=worker_id,
                        request_id=None,
                        machine_ip=None,
                        debug_port=stale_port,
                        process_id=None,
                        termination_reason=termination_reason,
                        exit_code=exit_code,
                        session_duration_seconds=0.0,
                    )
                )
                if stale_port:
                    await self._release_port(stale_port)
                return

            debug_port = session.debug_port
            duration = (datetime.now(UTC) - session.created_at).total_seconds()

            terminated = TerminatedSession(
                worker_id=session.worker_id,
                request_id=session.request_id,
                machine_ip=session.machine_ip,
                debug_port=session.debug_port,
                process_id=session.process_id,
                termination_reason=termination_reason,
                exit_code=exit_code,
                session_duration_seconds=duration,
            )

            self.terminated_sessions.append(terminated)

            if len(self.terminated_sessions) > self._max_terminated_history:
                self.terminated_sessions = self.terminated_sessions[
                    -self._max_terminated_history :
                ]

            logger.info(
                f"Cleaning up browser session: {worker_id} | "
                f"Port: {debug_port} | Duration: {duration:.1f}s"
            )

            if worker_id in self.sessions:
                del self.sessions[worker_id]
            # Note: _worker_to_port cleanup handled by _release_port() below

        if debug_port:
            system = platform.system().lower()
            # Always cleanup port-proxy on Windows (unconditional)
            if system == "windows":
                self._remove_windows_port_forwarding_bat(debug_port)

            await self._release_port(debug_port)  # Clears _worker_to_port

    def get_active_sessions(self) -> list:
        """Get list of active sessions"""
        sessions_snapshot = list(self.sessions.values())
        return [
            {
                "worker_id": session.worker_id,
                "request_id": session.request_id,
                "debug_port": session.debug_port,
                "machine_ip": session.machine_ip,
                "created_at": session.created_at.isoformat(),
                "expires_at": session.expires_at.isoformat(),
            }
            for session in sessions_snapshot
        ]

    def get_terminated_sessions(
        self, worker_id: str | None = None
    ) -> list[TerminatedSession]:
        """Get terminated session information"""
        if worker_id:
            return [s for s in self.terminated_sessions if s.worker_id == worker_id]
        return self.terminated_sessions.copy()

    def get_session_status(self, worker_id: str) -> dict:
        """Get status of a session (active or terminated)"""
        session = self.sessions.get(worker_id)
        if session:
            return {
                "status": "active",
                "worker_id": session.worker_id,
                "request_id": session.request_id,
                "machine_ip": session.machine_ip,
                "debug_port": session.debug_port,
                "process_id": session.process_id,
                "created_at": session.created_at.isoformat(),
                "expires_at": session.expires_at.isoformat(),
            }

        terminated = [s for s in self.terminated_sessions if s.worker_id == worker_id]
        if terminated:
            term_session = terminated[-1]
            return {
                "status": "terminated",
                "worker_id": term_session.worker_id,
                "request_id": term_session.request_id,
                "machine_ip": term_session.machine_ip,
                "debug_port": term_session.debug_port,
                "process_id": term_session.process_id,
                "termination_time": term_session.termination_time.isoformat(),
                "termination_reason": term_session.termination_reason,
                "exit_code": term_session.exit_code,
                "session_duration_seconds": term_session.session_duration_seconds,
            }

        return {"status": "not_found", "worker_id": worker_id}

    async def shutdown(self):
        """Gracefully shutdown and wait for background tasks to complete"""
        if self._background_tasks:
            logger.info(
                f"Waiting for {len(self._background_tasks)} background tasks to complete..."
            )
            await asyncio.gather(*self._background_tasks, return_exceptions=True)

        try:
            http = getattr(self, "_http", None)
            if http and not http.closed:
                await http.close()
        except Exception:
            pass

        logger.info("All background tasks completed")
