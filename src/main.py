import asyncio
import json
import os
import signal
import sys
from typing import Any

from src.core.config import settings
from src.queue.models import (
    BrowserSessionRequest,
    BrowserSessionResponse,
    RequestStatus,
)
from src.utils.logger import get_logger, setup_root_logger
from src.utils.sqs_utils import (
    poll_sqs_messages,
    delete_sqs_message,
    change_message_visibility,
)
from src.workers.browser_launcher import BrowserLauncher

setup_root_logger(level=settings.log_level, log_file=settings.log_file)
logger = get_logger(__name__)


class BrowserAutomationLauncher:
    def __init__(self):
        self.browser_launcher: BrowserLauncher | None = None
        self._shutdown = False
        self._cleanup_task: asyncio.Task | None = None
        self._profile_cleanup_task: asyncio.Task | None = None

        # Cached IP addresses (detected once at application startup)
        self.cached_machine_ip: str | None = None
        self.cached_public_ip: str | None = None
        self.is_aws_vm: bool = False

    async def task_handler(self, task_data: dict[str, Any]) -> BrowserSessionResponse:
        """Handle browser session requests from SQS queue"""
        try:
            # Parse Pydantic model in thread to avoid blocking validation
            request = await asyncio.to_thread(BrowserSessionRequest, **task_data)
            logger.info(f"Processing browser session request: {request.id}")
            response = await self.browser_launcher.launch_browser_session(request)
            logger.info(
                f"Browser launch completed with status: {response.status.value}"
            )
            # SQS response sending disabled - using callback instead
            # response_queue_url = (
            #     task_data.get("response_queue_url") or settings.response_queue_url
            # )
            # if response_queue_url:
            #     if response.status == RequestStatus.FAILED:
            #         logger.error(f"Browser launch failed: {response.error_message}")
            #     elif response.status == RequestStatus.REJECTED:
            #         logger.warning(
            #             f"Browser request rejected: {response.error_message}"
            #         )
            #     response_dict = await asyncio.to_thread(
            #         response.model_dump, mode="json"
            #     )
            #     try:
            #         response_region = response_queue_url.split(".")[1]
            #     except IndexError:
            #         response_region = settings.aws_region
            #     await send_sqs_message(
            #         response_queue_url, response_dict, response_region
            #     )

            # Log status instead
            if response.status == RequestStatus.FAILED:
                logger.error(f"Browser launch failed: {response.error_message}")
            elif response.status == RequestStatus.REJECTED:
                logger.warning(f"Browser request rejected: {response.error_message}")
            elif response.status == RequestStatus.SLOT_FULL:
                logger.warning(
                    f"Browser request rejected - slots full: {response.error_message}"
                )
            return response
        except Exception as e:
            logger.error(f"Error handling browser session request: {e}", exc_info=True)
            raise

    async def _detect_and_cache_ips(self):
        """Detect and cache IP addresses at startup"""
        logger.info("Detecting and caching IP addresses...")

        try:
            # Create temporary browser launcher instance just to use its IP detection methods
            temp_launcher = BrowserLauncher()

            # Detect machine IP
            self.cached_machine_ip = await temp_launcher._get_machine_ip()
            logger.info(f"Machine IP cached: {self.cached_machine_ip}")

            # Check if running on AWS
            self.is_aws_vm = await temp_launcher._is_aws_vm()
            logger.info(f"Running on AWS: {self.is_aws_vm}")

            # Get public IP if on AWS
            if self.is_aws_vm:
                try:
                    self.cached_public_ip = await asyncio.wait_for(
                        temp_launcher._get_public_ip_async(), timeout=5.0
                    )
                    logger.info(f"Public IP cached: {self.cached_public_ip}")
                except asyncio.TimeoutError:
                    logger.warning("Public IP detection timeout, using machine IP")
                    self.cached_public_ip = self.cached_machine_ip
                except Exception as e:
                    logger.warning(f"Error detecting public IP: {e}, using machine IP")
                    self.cached_public_ip = self.cached_machine_ip
            else:
                self.cached_public_ip = self.cached_machine_ip

            logger.info("IP detection completed successfully")

        except Exception as e:
            logger.error(f"Error detecting IPs: {e}", exc_info=True)
            # Fallback to localhost
            self.cached_machine_ip = "127.0.0.1"
            self.cached_public_ip = "127.0.0.1"
            self.is_aws_vm = False

    async def start(self):
        """Start the browser automation launcher"""
        # Detect and cache IPs first
        await self._detect_and_cache_ips()

        self.browser_launcher = BrowserLauncher()

        # Pass cached IPs to browser launcher
        self.browser_launcher._cached_machine_ip = self.cached_machine_ip
        self.browser_launcher._cached_public_ip = self.cached_public_ip
        self.browser_launcher._is_aws_vm_cached = self.is_aws_vm

        if settings.queue_url.lower() == "local":
            logger.info(
                f"Launcher started | Environment: {settings.environment.upper()} | "
                f"Max instances: {settings.max_browser_instances} | Mode: Local Test"
            )
            await self._run_local_test_mode()
        else:
            logger.info(
                f"Launcher started | Environment: {settings.environment.upper()} | "
                f"Max instances: {settings.max_browser_instances} | Mode: SQS"
            )
            await self._run_sqs_mode()

    async def _run_sqs_mode(self):
        """Run with SQS queue monitoring"""
        self._cleanup_task = asyncio.create_task(self._cleanup_loop())
        self._profile_cleanup_task = asyncio.create_task(self._profile_cleanup_loop())

        if not settings.queue_url:
            logger.error("SQS_QUEUE_URL not configured")
            return

        if not settings.queue_url.startswith("https://sqs."):
            logger.error(f"Invalid SQS queue URL: {settings.queue_url}")
            return

        try:
            region = settings.queue_url.split(".")[1]
        except IndexError:
            region = settings.aws_region

        # Main status and SQS polling loop
        while not self._shutdown:
            try:
                # Get current capacity
                active_sessions = self.browser_launcher.get_active_sessions()
                active_count = len(active_sessions)
                max_count = settings.max_browser_instances
                available_slots = max_count - active_count

                # Log status
                if available_slots <= 0:
                    logger.warning(
                        f"[WARN] Launcher running (NO SLOTS) | Active browsers: {active_count}/{max_count} | Mode: SQS"
                    )
                else:
                    logger.info(
                        f"[OK] Launcher running | Active browsers: {active_count}/{max_count} | Mode: SQS"
                    )

                # Fetch SQS messages if slots AND ports are available (prevents race conditions)
                if available_slots > 0 and self.browser_launcher._has_free_port():
                    messages_to_fetch = min(
                        available_slots, settings.sqs_max_batch_size
                    )
                    messages = await poll_sqs_messages(
                        queue_url=settings.queue_url,
                        region_name=region,
                        max_messages=messages_to_fetch,
                        wait_time=20,
                        visibility_timeout=120,
                    )

                    # Process messages concurrently
                    if messages:
                        tasks = []
                        for message in messages:
                            task = asyncio.create_task(
                                self._process_sqs_message(message, region)
                            )
                            tasks.append(task)

                        if tasks:
                            await asyncio.gather(*tasks, return_exceptions=True)
                elif available_slots <= 0:
                    logger.debug("No available slots - skipping SQS fetch")
                    await asyncio.sleep(2)
                    continue
                else:
                    # No free ports available
                    logger.debug("No free ports - skipping SQS fetch")
                    await asyncio.sleep(2)
                    continue

            except Exception as e:
                logger.error(f"Error in SQS polling loop: {e}", exc_info=True)

            await asyncio.sleep(settings.status_log_interval)

    async def _process_sqs_message(self, message: dict, region: str):
        """Process a single SQS message"""
        message_id = message.get("MessageId", "unknown")
        receipt_handle = message["ReceiptHandle"]

        try:
            # Parse JSON in thread to avoid blocking
            task_data = await asyncio.to_thread(json.loads, message["Body"])

            if not isinstance(task_data, dict):
                logger.error(
                    f"Invalid message format: expected dict, got {type(task_data)}"
                )
                await delete_sqs_message(settings.queue_url, receipt_handle, region)
                return

            task_id = (
                task_data.get("id")
                or task_data.get("request_id")
                or task_data.get("requester_id")
                or f"msg-{message_id[:8]}"
            )
            logger.info(f"Processing message {message_id} for task {task_id}")

            # Check if this is a delete action
            # Delete actions are processed even when slots are full (to free up slots)
            action = task_data.get("action")
            if action == "delete":
                session_id = task_data.get("session_id")
                if session_id:
                    # Find session by session_id with proper locking
                    found_session = None
                    async with self.browser_launcher._session_lock:
                        for (
                            worker_id,
                            session,
                        ) in self.browser_launcher.sessions.items():
                            if session.session_id == session_id:
                                found_session = (worker_id, session)
                                break

                    if found_session:
                        worker_id, session = found_session
                        active_count = len(self.browser_launcher.sessions)
                        max_count = settings.max_browser_instances
                        logger.info(
                            f"Delete action received for session {session_id[:8]} (worker {worker_id[:8]}) | "
                            f"Slots before: {active_count}/{max_count}"
                        )
                        try:
                            await self.browser_launcher.terminate_session(
                                worker_id, "delete_action"
                            )
                            active_count_after = len(self.browser_launcher.sessions)
                            logger.info(
                                f"Successfully terminated session {session_id[:8]} | "
                                f"Slots after: {active_count_after}/{max_count} | "
                                f"Freed 1 slot"
                            )
                            await delete_sqs_message(
                                settings.queue_url, receipt_handle, region
                            )
                        except Exception as e:
                            logger.error(
                                f"Failed to terminate session {session_id[:8]}: {e}"
                            )
                            # Add delay before retry
                            await change_message_visibility(
                                settings.queue_url, receipt_handle, 10, region
                            )
                        return
                    else:
                        logger.warning(
                            f"Delete action for session {session_id[:8]} - session not found on this machine, returning to queue"
                        )
                        await change_message_visibility(
                            settings.queue_url, receipt_handle, 0, region
                        )
                        return
                else:
                    logger.warning(
                        f"Delete action received but no session_id provided in message {message_id}"
                    )
                    await delete_sqs_message(settings.queue_url, receipt_handle, region)
                    return

            # Process the task (browser launch happens here)
            result = await self.task_handler(task_data)

            # Check if request was rejected due to no slots
            if hasattr(result, "status") and result.status == RequestStatus.SLOT_FULL:
                # Use visibility timeout to prevent immediate retry thrashing
                # Wait 30 seconds before making message available again
                visibility_timeout = 30
                logger.warning(
                    f"Task {task_id} rejected due to no available slots. "
                    f"Returning message to queue with {visibility_timeout}s delay."
                )
                await change_message_visibility(
                    settings.queue_url, receipt_handle, visibility_timeout, region
                )
                return

            # Check if request failed
            if hasattr(result, "status") and result.status == RequestStatus.FAILED:
                # Use small delay to prevent immediate retry thrashing
                visibility_timeout = 10
                logger.error(
                    f"Task {task_id} failed: {getattr(result, 'error_message', 'Unknown error')}. "
                    f"Returning message to queue with {visibility_timeout}s delay."
                )
                await change_message_visibility(
                    settings.queue_url, receipt_handle, visibility_timeout, region
                )
                return

            # Delete message only after successful processing
            logger.info(f"Task {task_id} completed successfully. Deleting message.")
            await delete_sqs_message(settings.queue_url, receipt_handle, region)

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in message {message_id}: {e}")
            await delete_sqs_message(settings.queue_url, receipt_handle, region)
        except Exception as e:
            logger.error(f"Failed to process message {message_id}: {e}", exc_info=True)
            # Return message to queue for retry on unexpected errors with delay
            try:
                await change_message_visibility(
                    settings.queue_url, receipt_handle, 15, region
                )
            except Exception:
                pass

    async def _run_local_test_mode(self):
        """Run in local test mode without SQS"""
        logger.info(
            f"Local test mode active | Check interval: {settings.local_check_interval}s | Create 'local_test/test_request.json' to launch browser"
        )

        self._cleanup_task = asyncio.create_task(self._cleanup_loop())

        local_test_dir = "local_test"
        os.makedirs(local_test_dir, exist_ok=True)

        try:
            while not self._shutdown:
                try:
                    active_sessions = self.browser_launcher.get_active_sessions()
                    active_count = len(active_sessions)
                    max_count = settings.max_browser_instances

                    if active_count >= max_count:
                        logger.warning(
                            f"[WARN] Launcher running (NO SLOTS) | Active browsers: {active_count}/{max_count} | Mode: Local Test"
                        )
                    else:
                        logger.info(
                            f"[OK] Launcher running | Active browsers: {active_count}/{max_count} | Mode: Local Test"
                        )

                    request_file = os.path.join(local_test_dir, "test_request.json")
                    if await asyncio.to_thread(os.path.exists, request_file):
                        try:
                            # Read and parse JSON in thread to avoid blocking
                            def read_json_file(path):
                                with open(path) as f:
                                    return json.load(f)

                            request_data = await asyncio.to_thread(
                                read_json_file, request_file
                            )

                            response = await self.task_handler(request_data)

                            if response.status != RequestStatus.COMPLETED:
                                logger.error(
                                    f"Browser launch {response.status.value}: {response.error_message}"
                                )

                            await asyncio.to_thread(os.remove, request_file)

                        except FileNotFoundError:
                            pass
                        except json.JSONDecodeError as e:
                            logger.error(f"Invalid JSON in {request_file}: {e}")
                        except Exception as e:
                            logger.error(f"Error processing test request: {e}")

                    status_request_file = os.path.join(
                        local_test_dir, "test_status_request.json"
                    )
                    if await asyncio.to_thread(os.path.exists, status_request_file):
                        try:
                            status_req = await asyncio.to_thread(
                                read_json_file, status_request_file
                            )

                            worker_id = status_req.get("worker_id")
                            if worker_id:
                                status = self.browser_launcher.get_session_status(
                                    worker_id
                                )
                            else:
                                terminated = (
                                    self.browser_launcher.get_terminated_sessions()
                                )
                                status = {
                                    "active_sessions": len(
                                        self.browser_launcher.sessions
                                    ),
                                    "terminated_sessions": [
                                        {
                                            "worker_id": t.worker_id,
                                            "termination_reason": t.termination_reason,
                                            "termination_time": t.termination_time.isoformat(),
                                            "exit_code": t.exit_code,
                                            "duration_seconds": t.session_duration_seconds,
                                        }
                                        for t in terminated[-10:]
                                    ],
                                }

                            status_response_file = os.path.join(
                                local_test_dir, "test_status_response.json"
                            )

                            # Write JSON in thread to avoid blocking
                            def write_json_file(path, data):
                                with open(path, "w") as f:
                                    json.dump(data, f, indent=2)

                            await asyncio.to_thread(
                                write_json_file, status_response_file, status
                            )

                            await asyncio.to_thread(os.remove, status_request_file)
                            logger.info(
                                f"Status response written to {status_response_file}"
                            )
                        except Exception as e:
                            logger.error(f"Error processing status request: {e}")

                    await asyncio.sleep(settings.local_check_interval)

                except asyncio.CancelledError:
                    break

        except (KeyboardInterrupt, asyncio.CancelledError):
            logger.info("Local test mode cancelled")

    async def _cleanup_loop(self):
        """Periodically clean up expired browser sessions"""
        try:
            while not self._shutdown:
                try:
                    await self.browser_launcher.cleanup_expired_sessions()
                    await asyncio.sleep(
                        20
                    )  # Check browser health and cleanup every 20 seconds
                except asyncio.CancelledError:
                    logger.info("Cleanup loop cancelled")
                    break
                except Exception as e:
                    logger.error(f"Error in cleanup loop: {e}")
                    await asyncio.sleep(30)
        except asyncio.CancelledError:
            logger.info("Cleanup task cancelled")

    async def _profile_cleanup_loop(self):
        """Periodically clean up old profile folders (background BAT script on Windows)"""
        try:
            # Wait a bit before first cleanup
            await asyncio.sleep(60)

            while not self._shutdown:
                try:
                    # Call BAT script to cleanup old profiles (fire-and-forget)
                    self.browser_launcher.cleanup_old_profiles_bat()

                    # Wait for configured interval before next cleanup
                    await asyncio.sleep(settings.profile_cleanup_interval_seconds)
                except asyncio.CancelledError:
                    logger.info("Profile cleanup loop cancelled")
                    break
                except Exception as e:
                    logger.error(f"Error in profile cleanup loop: {e}")
                    await asyncio.sleep(settings.profile_cleanup_interval_seconds)
        except asyncio.CancelledError:
            logger.info("Profile cleanup task cancelled")

    async def shutdown(self):
        """Gracefully shutdown the launcher"""
        if self._shutdown:
            return

        self._shutdown = True
        logger.info("Shutting down Browser Automation Launcher")

        if self._cleanup_task and not self._cleanup_task.done():
            self._cleanup_task.cancel()
            try:
                await asyncio.wait_for(self._cleanup_task, timeout=1.0)
            except (asyncio.CancelledError, asyncio.TimeoutError):
                pass

        if self._profile_cleanup_task and not self._profile_cleanup_task.done():
            self._profile_cleanup_task.cancel()
            try:
                await asyncio.wait_for(self._profile_cleanup_task, timeout=1.0)
            except (asyncio.CancelledError, asyncio.TimeoutError):
                pass

        if self.browser_launcher:
            active_sessions = self.browser_launcher.get_active_sessions()
            if active_sessions:
                logger.info(
                    f"Terminating {len(active_sessions)} active browser sessions"
                )
                semaphore = asyncio.Semaphore(3)

                async def terminate_with_semaphore(worker_id):
                    async with semaphore:
                        await self.browser_launcher.terminate_session(worker_id)

                tasks = [
                    terminate_with_semaphore(session["worker_id"])
                    for session in active_sessions
                ]
                await asyncio.gather(*tasks, return_exceptions=True)

            await self.browser_launcher.shutdown()

        logger.info("Shutdown complete")

    def request_shutdown(self):
        """Request graceful shutdown"""
        if not self._shutdown:
            self._shutdown = True
            logger.info("Shutdown requested")


async def main():
    """Main entry point"""
    launcher = BrowserAutomationLauncher()

    def signal_handler(sig, _frame):
        logger.info(f"Received signal {sig}")
        launcher.request_shutdown()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    try:
        await launcher.start()
    except asyncio.CancelledError:
        logger.info("Main task cancelled")
    except Exception as e:
        logger.error(f"Error in launcher: {e}")
    finally:
        await launcher.shutdown()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Application interrupted")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Application error: {e}")
        sys.exit(1)
