import asyncio
import json
from typing import Any
import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, EndpointConnectionError

from ..core.config import settings
from ..utils.logger import get_logger

logger = get_logger(__name__)


class SQSClientManager:
    """Manages SQS client with connection pooling and auto-recovery (async-safe)"""

    def __init__(self):
        self._clients = {}
        self._failure_counts = {}
        self._lock = asyncio.Lock()  # Async-safe lock for concurrent access

    def _get_client_key(self, region_name: str) -> str:
        """Generate cache key for client"""
        return f"{region_name}_{settings.aws_access_key_id or 'default'}"

    def _create_client(self, region_name: str):
        """Create a new SQS client with optimized configuration"""
        client_config = {
            "region_name": region_name,
            "config": Config(
                connect_timeout=10,
                read_timeout=60,
                retries={"max_attempts": 4, "mode": "adaptive"},
            ),
        }

        if settings.aws_access_key_id and settings.aws_secret_access_key:
            client_config["aws_access_key_id"] = settings.aws_access_key_id
            client_config["aws_secret_access_key"] = settings.aws_secret_access_key

        return boto3.client("sqs", **client_config)

    async def get_client(self, region_name: str):
        """Get or create SQS client with auto-recovery (async-safe)"""
        key = self._get_client_key(region_name)

        async with self._lock:
            # Check if client needs reset due to consecutive failures
            if key in self._failure_counts and self._failure_counts[key] >= 3:
                logger.warning(
                    f"SQS client for {region_name} has {self._failure_counts[key]} failures - reinitializing"
                )
                if key in self._clients:
                    del self._clients[key]
                self._failure_counts[key] = 0

            # Create new client if needed
            if key not in self._clients:
                logger.info(f"Creating new SQS client for region {region_name}")
                self._clients[key] = self._create_client(region_name)
                self._failure_counts[key] = 0

            return self._clients[key]

    async def record_failure(self, region_name: str):
        """Record a failure for circuit breaker logic (async-safe)"""
        key = self._get_client_key(region_name)
        async with self._lock:
            self._failure_counts[key] = self._failure_counts.get(key, 0) + 1
            logger.debug(
                f"SQS failure count for {region_name}: {self._failure_counts[key]}"
            )

    async def record_success(self, region_name: str):
        """Reset failure count on success (async-safe)"""
        key = self._get_client_key(region_name)
        async with self._lock:
            if key in self._failure_counts and self._failure_counts[key] > 0:
                logger.debug(f"SQS connection recovered for {region_name}")
                self._failure_counts[key] = 0


# Global SQS client manager
_sqs_manager = SQSClientManager()


async def poll_sqs_messages(
    queue_url: str,
    region_name: str = "us-east-1",
    max_messages: int = 1,
    wait_time: int = 5,
    visibility_timeout: int = 300,
) -> list[dict[str, Any]]:
    """
    Poll SQS queue for messages using asyncio.to_thread for non-blocking operation.
    Uses client manager for connection pooling and auto-recovery.

    Args:
        queue_url: SQS queue URL
        region_name: AWS region
        max_messages: Maximum number of messages to retrieve (1-10)
        wait_time: Long polling wait time in seconds (0-20)
        visibility_timeout: Message visibility timeout in seconds

    Returns:
        List of message dictionaries with 'MessageId', 'Body', 'ReceiptHandle'
    """
    try:
        # Get SQS client from manager (handles pooling and recovery)
        sqs_client = await _sqs_manager.get_client(region_name)

        # Poll SQS with timeout protection
        response = await asyncio.wait_for(
            asyncio.to_thread(
                sqs_client.receive_message,
                QueueUrl=queue_url,
                MaxNumberOfMessages=max_messages,
                VisibilityTimeout=visibility_timeout,
                WaitTimeSeconds=wait_time,
            ),
            timeout=wait_time + 5,  # wait_time + buffer
        )

        messages = response.get("Messages", [])
        if messages:
            logger.info(f"Received {len(messages)} message(s) from SQS")

        # Always record success on successful API call (even if no messages)
        await _sqs_manager.record_success(region_name)
        return messages

    except asyncio.TimeoutError:
        logger.debug("SQS poll timeout (no messages available)")
        return []
    except (ClientError, EndpointConnectionError) as e:
        await _sqs_manager.record_failure(region_name)
        if isinstance(e, ClientError):
            error_code = e.response.get("Error", {}).get("Code", "")
            logger.error(f"SQS ClientError: {error_code} - {e}")
        else:
            logger.error(f"SQS EndpointConnectionError: {e}")
        return []
    except Exception as e:
        await _sqs_manager.record_failure(region_name)
        logger.error(f"Error polling SQS: {e}", exc_info=True)
        return []


async def delete_sqs_message(
    queue_url: str,
    receipt_handle: str,
    region_name: str = "us-east-1",
) -> bool:
    """
    Delete a message from SQS queue.
    Uses client manager for connection pooling and auto-recovery.

    Args:
        queue_url: SQS queue URL
        receipt_handle: Receipt handle of the message to delete
        region_name: AWS region

    Returns:
        True if successful, False otherwise
    """
    try:
        # Get SQS client from manager (handles pooling and recovery)
        sqs_client = await _sqs_manager.get_client(region_name)

        await asyncio.wait_for(
            asyncio.to_thread(
                sqs_client.delete_message,
                QueueUrl=queue_url,
                ReceiptHandle=receipt_handle,
            ),
            timeout=10,
        )

        logger.info("Message deleted successfully from queue")
        await _sqs_manager.record_success(region_name)
        return True

    except ClientError as e:
        error_code = e.response.get("Error", {}).get("Code", "")
        if error_code == "ReceiptHandleIsInvalid":
            # Invalid receipt handle is an expected error, not a connection failure
            logger.warning("Receipt handle invalid or expired")
        else:
            await _sqs_manager.record_failure(region_name)
            logger.error(f"Failed to delete message: {error_code}")
        return False
    except Exception as e:
        await _sqs_manager.record_failure(region_name)
        logger.error(f"Error deleting message: {e}")
        return False


async def change_message_visibility(
    queue_url: str,
    receipt_handle: str,
    visibility_timeout: int,
    region_name: str = "us-east-1",
) -> bool:
    """
    Change the visibility timeout of a message.
    Uses client manager for connection pooling and auto-recovery.

    Args:
        queue_url: SQS queue URL
        receipt_handle: Receipt handle of the message
        visibility_timeout: New visibility timeout in seconds (0 to return to queue)
        region_name: AWS region

    Returns:
        True if successful, False otherwise
    """
    try:
        # Get SQS client from manager (handles pooling and recovery)
        sqs_client = await _sqs_manager.get_client(region_name)

        await asyncio.wait_for(
            asyncio.to_thread(
                sqs_client.change_message_visibility,
                QueueUrl=queue_url,
                ReceiptHandle=receipt_handle,
                VisibilityTimeout=visibility_timeout,
            ),
            timeout=10,
        )

        await _sqs_manager.record_success(region_name)
        return True

    except Exception as e:
        await _sqs_manager.record_failure(region_name)
        logger.error(f"Error changing message visibility: {e}")
        return False


async def send_sqs_message(
    queue_url: str,
    message_body: dict[str, Any],
    region_name: str = "us-east-1",
) -> str | None:
    """
    Send a message to SQS queue.
    Uses client manager for connection pooling and auto-recovery.

    Args:
        queue_url: SQS queue URL
        message_body: Message body as dictionary
        region_name: AWS region

    Returns:
        MessageId if successful, None otherwise
    """
    try:
        # Get SQS client from manager (handles pooling and recovery)
        sqs_client = await _sqs_manager.get_client(region_name)

        # Serialize JSON in thread to avoid blocking
        message_body_str = await asyncio.to_thread(json.dumps, message_body)

        result = await asyncio.wait_for(
            asyncio.to_thread(
                sqs_client.send_message,
                QueueUrl=queue_url,
                MessageBody=message_body_str,
            ),
            timeout=10,
        )

        message_id = result.get("MessageId")
        if message_id:
            logger.info(f"Message sent successfully, MessageId: {message_id}")
            await _sqs_manager.record_success(region_name)
        return message_id

    except Exception as e:
        await _sqs_manager.record_failure(region_name)
        logger.error(f"Error sending message: {e}")
        return None
