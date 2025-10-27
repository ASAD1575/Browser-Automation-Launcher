import os
from pathlib import Path

from dotenv import load_dotenv

# Load .env from project root (parent of src directory)
env_path = Path(__file__).parent.parent.parent / ".env"
load_dotenv(dotenv_path=env_path, override=True)


class Settings:
    environment: str = os.getenv("ENV", "local")  # local, staging, production
    queue_url: str = os.getenv("SQS_REQUEST_QUEUE_URL", "")
    response_queue_url: str = os.getenv("SQS_RESPONSE_QUEUE_URL", "")
    aws_region: str = os.getenv("AWS_REGION", "us-east-1")
    aws_access_key_id: str | None = os.getenv("AWS_ACCESS_KEY_ID")
    aws_secret_access_key: str | None = os.getenv("AWS_SECRET_ACCESS_KEY")

    max_browser_instances: int = int(os.getenv("MAX_BROWSER_INSTANCES", "5"))
    default_ttl_minutes: int = int(os.getenv("DEFAULT_TTL_MINUTES", "30"))
    hard_ttl_minutes: int = int(os.getenv("HARD_TTL_MINUTES", "120"))
    idle_timeout_seconds: int = int(os.getenv("IDLE_TIMEOUT_SECONDS", "60"))
    browser_timeout: int = int(os.getenv("BROWSER_TIMEOUT", "60000"))

    log_level: str = os.getenv("LOG_LEVEL", "INFO")
    log_file: str | None = os.getenv("LOG_FILE", "logs/browser_launcher.log")

    local_check_interval: int = int(os.getenv("LOCAL_CHECK_INTERVAL", "900"))
    status_log_interval: int = int(os.getenv("STATUS_LOG_INTERVAL", "10"))
    sqs_wait_time_seconds: int = int(os.getenv("SQS_WAIT_TIME_SECONDS", "10"))
    sqs_max_batch_size: int = int(os.getenv("SQS_MAX_BATCH_SIZE", "4"))

    browser_api_callback_enabled: bool = (
        os.getenv("BROWSER_API_CALLBACK_ENABLED", "false").lower() == "true"
    )
    browser_api_callback_url: str = os.getenv("BROWSER_API_CALLBACK_URL", "")
    browser_api_callback_timeout: int = int(
        os.getenv("BROWSER_API_CALLBACK_TIMEOUT", "30")
    )

    # Chrome Launcher Configuration
    use_custom_chrome_launcher: bool = (
        os.getenv("USE_CUSTOM_CHROME_LAUNCHER", "false").lower() == "true"
    )
    chrome_launcher_cmd: str = os.getenv(
        "CHROME_LAUNCHER_CMD", "C:\\Chrome-RDP\\launch_chrome_port.cmd"
    )
    chrome_port_start: int = int(os.getenv("CHROME_PORT_START", "9222"))
    chrome_port_end: int = int(os.getenv("CHROME_PORT_END", "9322"))

    profile_reuse_enabled: bool = (
        os.getenv("PROFILE_REUSE_ENABLED", "true").lower() == "true"
    )
    profile_max_age_hours: int = int(os.getenv("PROFILE_MAX_AGE_HOURS", "24"))
    profile_cleanup_interval_seconds: int = int(
        os.getenv("PROFILE_CLEANUP_INTERVAL_SECONDS", "3600")
    )

    # Port forwarding configuration (DEPRECATED - No longer used)
    # Port forwarding is now handled by the custom Chrome launcher script
    # The script (launch_chrome_port.cmd) creates port forwarding automatically
    # This setting is kept for backwards compatibility but has no effect
    enable_portproxy: bool = os.getenv("ENABLE_PORTPROXY", "false").lower() == "true"


settings = Settings()
