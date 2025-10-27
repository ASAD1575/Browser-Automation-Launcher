import uuid
from datetime import UTC, datetime
from enum import Enum

from pydantic import BaseModel, Field

from ..core.config import settings


class RequestStatus(str, Enum):
    PENDING = "pending"
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"
    SLOT_FULL = "slot_full"


class BrowserSessionRequest(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    session_id: str | None = None
    requester_id: str
    action: str | None = None
    user_data_dir: str | None = None
    profile_name: str | None = None
    proxy_config: dict[str, str] | None = None
    extensions: list[str] | None = None
    chrome_args: list[str] | None = None
    ttl_minutes: int = Field(default_factory=lambda: settings.default_ttl_minutes)
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    class Config:
        json_encoders = {datetime: lambda v: v.isoformat()}


class BrowserSessionResponse(BaseModel):
    status: RequestStatus
    worker_id: str
    machine_ip: str
    debug_port: int
    session_id: str | None = None
    requester_id: str | None = None
    websocket_url: str | None = None
    debug_url: str | None = None
    proxy_config: dict[str, str] | None = None
    ttl_minutes: int | None = None
    expires_at: datetime | None = None
    error_message: str | None = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    class Config:
        json_encoders = {datetime: lambda v: v.isoformat()}


class BrowserSession(BaseModel):
    session_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    worker_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    request_id: str
    machine_ip: str
    debug_port: int
    process_id: int | None = None
    process_create_time: float | None = None  # For PID-reuse validation
    user_data_dir: str
    status: str = "active"
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
    expires_at: datetime
    websocket_url: str
    debug_url: str
    process_object: object | None = Field(
        default=None, exclude=True
    )  # ChromeProcessWrapper or subprocess.Popen
    has_navigated_away: bool = False
    last_activity_at: datetime = Field(default_factory=lambda: datetime.now(UTC))

    class Config:
        json_encoders = {datetime: lambda v: v.isoformat()}
        arbitrary_types_allowed = True


class TerminatedSession(BaseModel):
    """Information about terminated browser sessions"""

    worker_id: str
    request_id: str
    machine_ip: str
    debug_port: int
    process_id: int
    termination_time: datetime = Field(default_factory=lambda: datetime.now(UTC))
    termination_reason: str
    exit_code: int | None = None
    session_duration_seconds: float

    class Config:
        json_encoders = {datetime: lambda v: v.isoformat()}
