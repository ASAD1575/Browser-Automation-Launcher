import asyncio
import logging
import json
from collections.abc import Callable
from contextlib import suppress
from datetime import datetime
from typing import Any
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.exceptions import ClientError
from botocore.config import Config

from ..core.config import settings
from ..queue.models import RequestStatus
from ..utils.logger import get_logger

logger = get_logger(__name__)

# Suppress repetitive boto credential logs
logging.getLogger("botocore.credentials").setLevel(logging.WARNING)


class QueueMonitor:
    """SQS Queue Monitor for browser session requests"""

    def __init__(self, queue_url: str, region_name: str = "us-east-1"):
        self.queue_url = queue_url
        self.region_name = region_name
        self._running = False
        self._task_handler: Callable | None = None
        self._status_callback: Callable | None = None
        self._has_slots_callback: Callable | None = None
        self._get_slots_callback: Callable | None = None
        self._monitor_task: asyncio.Task | None = None
        self._status_task: asyncio.Task | None = None

        self._thread_pool = ThreadPoolExecutor(
            max_workers=5, thread_name_prefix="sqs-worker"
        )

        client_config = {
            "region_name": region_name,
            "config": Config(
                connect_timeout=10,
                read_timeout=60,
                retries={"max_attempts": 2, "mode": "standard"},
            ),
        }

        if settings.aws_access_key_id and settings.aws_secret_access_key:
            client_config["aws_access_key_id"] = settings.aws_access_key_id
            client_config["aws_secret_access_key"] = settings.aws_secret_access_key

        self.sqs_client = boto3.client("sqs", **client_config)
        logger.info(
            f"QueueMonitor initialized with boto3 (with dedicated thread pool) for queue: {queue_url[:50]}..."
        )

    def set_task_handler(self, handler: Callable):
        """Set the handler function for processing tasks"""
        self._task_handler = handler

    def set_status_callback(self, callback: Callable):
        """Set the callback function for status updates"""
        self._status_callback = callback

    def set_has_slots_callback(self, callback: Callable):
        """Set the callback function to check for available slots"""
        self._has_slots_callback = callback

    def set_get_slots_callback(self, callback: Callable):
        """Set the callback function to get number of available slots"""
        self._get_slots_callback = callback

    async def start_monitoring(self):
        """Start monitoring the SQS queue"""
        if not self._task_handler:
            raise ValueError("Task handler not set")

        if self._running:
            logger.warning("Monitor is already running")
            return

        self._running = True

        self._monitor_task = asyncio.create_task(self._monitor_loop())
        self._status_task = asyncio.create_task(self._status_loop())

        try:
            await asyncio.gather(self._monitor_task, self._status_task)
        except asyncio.CancelledError:
            logger.info("Monitor task cancelled")

    async def _status_loop(self):
        """Separate status logging loop"""
        while self._running:
            try:
                if self._status_callback:
                    await self._status_callback()
                await asyncio.sleep(settings.status_log_interval)
            except asyncio.CancelledError:
                logger.info("Status loop cancelled")
                break
            except Exception as e:
                logger.error(f"Error in status loop: {e}")
                await asyncio.sleep(60)

    async def _process_message(self, message: dict):
        """Process a single SQS message"""
        message_id = message.get("MessageId", "unknown")
        receipt_handle = message["ReceiptHandle"]

        try:
            task_data = await asyncio.to_thread(json.loads, message["Body"])

            if not isinstance(task_data, dict):
                logger.error(
                    f"Invalid message format: expected dict, got {type(task_data)}"
                )
                await self._delete_message(receipt_handle)
                return

            task_id = (
                task_data.get("id")
                or task_data.get("request_id")
                or task_data.get("requester_id")
                or f"msg-{message_id[:8]}"
            )
            logger.info(f"Processing message {message_id} for task {task_id}")

            result = await asyncio.wait_for(self._task_handler(task_data), timeout=300)

            if hasattr(result, "status") and result.status == RequestStatus.REJECTED:
                logger.warning(
                    f"Task {task_id} rejected due to no available slots. "
                    f"Message will be returned to queue for another launcher to process."
                )
                await self._change_message_visibility(receipt_handle, 0)
                return

            logger.debug(f"Deleting message for task {task_id}")
            await self._delete_message(receipt_handle)

        except TimeoutError:
            logger.error(f"Task handler timeout for message {message_id}")
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in message {message_id}: {e}")
            await self._delete_message(receipt_handle)
        except Exception as e:
            logger.error(f"Failed to process message: {e}", exc_info=True)

    async def _monitor_loop(self):
        """Main monitoring loop"""
        credential_error_count = 0
        while self._running:
            try:
                available_slots = 0
                if hasattr(self, "_get_slots_callback") and self._get_slots_callback:
                    available_slots = await self._get_slots_callback()
                elif self._has_slots_callback:
                    has_slots = await self._has_slots_callback()
                    available_slots = 1 if has_slots else 0

                if available_slots == 0:
                    logger.debug("No available slots - skipping SQS poll")
                    await asyncio.sleep(2)
                    continue

                messages_to_poll = min(available_slots, settings.sqs_max_batch_size)

                try:
                    visibility_timeout = 300
                    loop = asyncio.get_event_loop()
                    response = await asyncio.wait_for(
                        loop.run_in_executor(
                            self._thread_pool,
                            lambda: self.sqs_client.receive_message(
                                QueueUrl=self.queue_url,
                                MaxNumberOfMessages=messages_to_poll,
                                VisibilityTimeout=visibility_timeout,
                                WaitTimeSeconds=2,
                            ),
                        ),
                        timeout=5,
                    )

                    messages = response.get("Messages", [])

                except asyncio.TimeoutError:
                    logger.warning("SQS poll timeout (5s) - forcing next poll")
                    messages = []
                except Exception as e:
                    logger.error(f"Error polling SQS: {e}", exc_info=True)
                    messages = []

                if messages:
                    tasks = []
                    for message in messages:
                        task = asyncio.create_task(self._process_message(message))
                        tasks.append(task)

                    if tasks:
                        await asyncio.gather(*tasks, return_exceptions=True)
                else:
                    await asyncio.sleep(0.1)

                credential_error_count = 0

            except Exception as e:
                error_msg = str(e)
                if (
                    "credentials" in error_msg.lower()
                    or "unauthorized" in error_msg.lower()
                ):
                    credential_error_count += 1
                    logger.warning(
                        f"AWS credentials error (attempt {credential_error_count}): {error_msg}"
                    )
                    backoff_time = min(5 * credential_error_count, 30)
                    logger.info(
                        f"Waiting {backoff_time}s for credentials to refresh..."
                    )
                    await asyncio.sleep(backoff_time)
                else:
                    logger.error(f"Error in monitoring loop: {e}", exc_info=True)
                    await asyncio.sleep(60)

    async def stop_monitoring(self):
        """Stop monitoring the queue gracefully"""
        if not self._running:
            logger.warning("Monitor is not running")
            return

        logger.info("Stopping SQS monitor...")
        self._running = False

        if self._monitor_task and not self._monitor_task.done():
            self._monitor_task.cancel()
            with suppress(asyncio.CancelledError):
                await self._monitor_task

        if self._status_task and not self._status_task.done():
            self._status_task.cancel()
            with suppress(asyncio.CancelledError):
                await self._status_task

        # Shutdown thread pool
        self._thread_pool.shutdown(wait=False)

        logger.info("SQS monitor stopped")

    async def _delete_message(self, receipt_handle: str):
        """Delete message from SQS queue"""
        try:
            logger.info(
                f"Deleting message with receipt handle: {receipt_handle[:50]}..."
            )

            loop = asyncio.get_event_loop()
            await asyncio.wait_for(
                loop.run_in_executor(
                    self._thread_pool,
                    lambda: self.sqs_client.delete_message(
                        QueueUrl=self.queue_url, ReceiptHandle=receipt_handle
                    ),
                ),
                timeout=10,
            )

            logger.info("Message deleted successfully from queue")

        except ClientError as e:
            error_code = e.response.get("Error", {}).get("Code", "")
            error_msg = e.response.get("Error", {}).get("Message", "")

            if error_code == "ReceiptHandleIsInvalid":
                logger.warning(
                    f"Receipt handle is invalid or expired. Message may have already been deleted: {error_msg}"
                )
            else:
                logger.error(f"Failed to delete message: {error_code} - {error_msg}")

        except Exception as e:
            logger.error(f"Unexpected error deleting message: {type(e).__name__}: {e}")

    async def _change_message_visibility(
        self, receipt_handle: str, visibility_timeout: int
    ):
        """Change message visibility timeout"""
        try:
            loop = asyncio.get_event_loop()
            await asyncio.wait_for(
                loop.run_in_executor(
                    self._thread_pool,
                    lambda: self.sqs_client.change_message_visibility(
                        QueueUrl=self.queue_url,
                        ReceiptHandle=receipt_handle,
                        VisibilityTimeout=visibility_timeout,
                    ),
                ),
                timeout=10,
            )
        except ClientError as e:
            logger.error(f"Failed to change message visibility: {e}")
        except Exception as e:
            logger.error(f"Unexpected error changing visibility: {e}")

    async def send_response(
        self, response_data: dict[str, Any], response_queue_url: str | None = None
    ):
        """Send response to a response queue"""
        if not response_queue_url:
            logger.debug("No response queue URL provided, skipping response")
            return

        try:

            def convert_datetime(obj):
                if isinstance(obj, datetime):
                    return obj.isoformat()
                elif isinstance(obj, dict):
                    return {k: convert_datetime(v) for k, v in obj.items()}
                elif isinstance(obj, list):
                    return [convert_datetime(item) for item in obj]
                return obj

            serializable_data = convert_datetime(response_data)
            message_body = await asyncio.to_thread(json.dumps, serializable_data)

            logger.debug(f"Sending response to queue: {response_queue_url}")

            loop = asyncio.get_event_loop()
            result = await asyncio.wait_for(
                loop.run_in_executor(
                    self._thread_pool,
                    lambda: self.sqs_client.send_message(
                        QueueUrl=response_queue_url, MessageBody=message_body
                    ),
                ),
                timeout=10,
            )

            if result and "MessageId" in result:
                logger.info(
                    f"Successfully sent response to queue, MessageId: {result['MessageId']}"
                )
            else:
                logger.warning(
                    f"Sent message but no MessageId returned. Result: {result}"
                )

        except ClientError as e:
            logger.error(f"Failed to send response: {e}")
            raise
        except Exception as e:
            logger.error(f"Unexpected error sending response: {type(e).__name__}: {e}")
            raise
