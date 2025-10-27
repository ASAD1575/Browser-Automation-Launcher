"""HTTP client utilities for making async HTTP requests"""

import asyncio
from typing import Any

import aiohttp

from ..utils.logger import get_logger

logger = get_logger(__name__)


async def send_post_request(
    url: str,
    data: dict[str, Any],
    timeout: int = 30,
    headers: dict[str, str] | None = None,
) -> tuple[bool, int | None, str]:
    """
    Send async POST request to URL

    Args:
        url: Target URL
        data: JSON data to send
        timeout: Request timeout in seconds (default: 30)
        headers: Optional HTTP headers

    Returns:
        Tuple of (success: bool, status_code: int | None, response_text: str)
    """
    if not url:
        logger.warning("Empty URL provided to send_post_request")
        return False, None, "Empty URL"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                url,
                json=data,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=timeout),
            ) as response:
                response_text = await response.text()
                success = 200 <= response.status < 300

                if success:
                    logger.debug(
                        f"POST request successful | URL: {url} | Status: {response.status}"
                    )
                else:
                    logger.warning(
                        f"POST request failed | URL: {url} | Status: {response.status} | Response: {response_text[:200]}"
                    )

                return success, response.status, response_text

    except asyncio.TimeoutError:
        logger.error(f"POST request timeout after {timeout}s | URL: {url}")
        return False, None, f"Timeout after {timeout}s"

    except aiohttp.ClientError as e:
        logger.error(f"POST request client error | URL: {url} | Error: {e}")
        return False, None, f"Client error: {str(e)}"

    except Exception as e:
        logger.error(f"POST request unexpected error | URL: {url} | Error: {e}")
        return False, None, f"Unexpected error: {str(e)}"


async def send_get_request(
    url: str,
    timeout: int = 30,
    headers: dict[str, str] | None = None,
) -> tuple[bool, int | None, str]:
    """
    Send async GET request to URL

    Args:
        url: Target URL
        timeout: Request timeout in seconds (default: 30)
        headers: Optional HTTP headers

    Returns:
        Tuple of (success: bool, status_code: int | None, response_text: str)
    """
    if not url:
        logger.warning("Empty URL provided to send_get_request")
        return False, None, "Empty URL"

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                url,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=timeout),
            ) as response:
                response_text = await response.text()
                success = 200 <= response.status < 300

                if success:
                    logger.debug(
                        f"GET request successful | URL: {url} | Status: {response.status}"
                    )
                else:
                    logger.warning(
                        f"GET request failed | URL: {url} | Status: {response.status} | Response: {response_text[:200]}"
                    )

                return success, response.status, response_text

    except asyncio.TimeoutError:
        logger.error(f"GET request timeout after {timeout}s | URL: {url}")
        return False, None, f"Timeout after {timeout}s"

    except aiohttp.ClientError as e:
        logger.error(f"GET request client error | URL: {url} | Error: {e}")
        return False, None, f"Client error: {str(e)}"

    except Exception as e:
        logger.error(f"GET request unexpected error | URL: {url} | Error: {e}")
        return False, None, f"Unexpected error: {str(e)}"
