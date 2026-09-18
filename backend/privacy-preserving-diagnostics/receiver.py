"""Dependency-free local receiver for the privacy-preserving diagnostics contract.

This module is test infrastructure only. It intentionally stores accepted
objects in memory and binds its HTTP server to loopback. It does not know the
production hostname and cannot publish an envelope anywhere.
"""

from __future__ import annotations

import json
import re
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Mapping


MAX_BODY_BYTES = 128 * 1024
MAX_STACK_THREADS = 32
MAX_FRAMES_PER_THREAD = 64
MAX_STACK_FRAMES = 256
MAX_FRAME_OFFSET = 2**48
SERVER_RETENTION = timedelta(days=14)

UUID_PATTERN = re.compile(
    # The client derives occurrence IDs from SHA-256 bytes and intentionally
    # does not rewrite UUID version/variant bits. Validate canonical UUID shape.
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
DATE_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$"
)
VERSION_PATTERN = re.compile(r"^[A-Za-z0-9._+\-]{1,64}$")
HARDWARE_PATTERN = re.compile(r"^(?:[A-Za-z]+[0-9]+,[0-9]+|unknown)$")

PLATFORM_VALUES = {"ios", "macos", "unknown"}
FOREGROUND_VALUES = {"foreground", "background", "inactive", "unknown"}
OPERATION_VALUES = {
    "icloud_sync",
    "recording_finalize",
    "live_transcription",
    "background_processing",
    "idle",
    "unknown",
}
PHASE_VALUES = {"begin", "progress", "end", "unknown"}
RESULT_VALUES = {"success", "failure", "cancelled", "unknown"}
REPORT_KIND_VALUES = {
    "apple_crash",
    "apple_hang",
    "resource_diagnostic",
    "unexpected_termination",
}
RESOURCE_KIND_VALUES = {
    "cpu_exception",
    "disk_write_exception",
    "memory_exception",
    "app_launch",
}
SOURCE_VALUES = {"legacy_metrickit", "modern_metrickit", "lifecycle_heuristic"}
ASSOCIATION_VALUES = {"matched", "unknown", "not_applicable"}
TERMINATION_VALUES = {
    "bad_access",
    "abnormal",
    "illegal_instruction",
    "watchdog",
    "task_timeout",
    "file_lock",
    "memory",
    "unknown",
}
COUNT_VALUES = {"none", "one", "two_to_five", "six_to_ten", "more_than_ten", "unknown"}
DURATION_VALUES = {
    "less_than_one_second",
    "one_to_ten_seconds",
    "ten_to_sixty_seconds",
    "one_to_five_minutes",
    "more_than_five_minutes",
    "unknown",
}
MEMORY_VALUES = {"normal", "warning", "critical", "unknown"}
THERMAL_VALUES = {"nominal", "fair", "serious", "critical", "unknown"}
IMAGE_VALUES = {"application", "reviewed_framework"}


class ValidationError(ValueError):
    """Raised for a request that is outside the closed diagnostics schema."""


def _is_object(value: Any) -> bool:
    return isinstance(value, dict)


def _require_object(value: Any, name: str) -> None:
    if not _is_object(value):
        raise ValidationError(f"{name} must be an object")


def _require_keys(
    value: Any,
    name: str,
    required: set[str],
    optional: set[str] | None = None,
) -> None:
    _require_object(value, name)
    allowed = required | (optional or set())
    if set(value) - allowed:
        raise ValidationError(f"{name} contains an unknown field")
    if required - set(value):
        raise ValidationError(f"{name} is missing a required field")


def _require_string(value: Any, name: str, pattern: re.Pattern[str] | None = None) -> None:
    if not isinstance(value, str) or not value or pattern is not None and not pattern.fullmatch(value):
        raise ValidationError(f"{name} is invalid")


def _require_enum(value: Any, name: str, values: set[str]) -> None:
    if not isinstance(value, str) or value not in values:
        raise ValidationError(f"{name} is invalid")


def _require_uuid(value: Any, name: str) -> None:
    _require_string(value, name, UUID_PATTERN)
    try:
        uuid.UUID(value)
    except (ValueError, AttributeError):
        raise ValidationError(f"{name} is invalid") from None


def _require_date(value: Any, name: str) -> datetime:
    _require_string(value, name, DATE_PATTERN)
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise ValidationError(f"{name} is invalid") from None
    if parsed.tzinfo is None:
        raise ValidationError(f"{name} is invalid")
    return parsed.astimezone(timezone.utc)


def _require_bool(value: Any, name: str) -> None:
    if type(value) is not bool:
        raise ValidationError(f"{name} is invalid")


def _require_int(value: Any, name: str, minimum: int, maximum: int) -> None:
    if type(value) is not int or value < minimum or value > maximum:
        raise ValidationError(f"{name} is invalid")


def _validate_runtime(value: Any, name: str) -> None:
    _require_keys(value, name, {"appVersion", "appBuild", "osVersion", "platform", "hardwareModel"})
    _require_string(value["appVersion"], f"{name}.appVersion", VERSION_PATTERN)
    _require_string(value["appBuild"], f"{name}.appBuild", VERSION_PATTERN)
    _require_string(value["osVersion"], f"{name}.osVersion", VERSION_PATTERN)
    _require_enum(value["platform"], f"{name}.platform", PLATFORM_VALUES)
    _require_string(value["hardwareModel"], f"{name}.hardwareModel", HARDWARE_PATTERN)


def _validate_state(value: Any, name: str) -> None:
    _require_keys(value, name, {"foregroundState", "isRecording", "isSyncing"})
    _require_enum(value["foregroundState"], f"{name}.foregroundState", FOREGROUND_VALUES)
    _require_bool(value["isRecording"], f"{name}.isRecording")
    _require_bool(value["isSyncing"], f"{name}.isSyncing")


def _validate_measurements(value: Any, name: str) -> None:
    _require_keys(value, name, {"operationCount", "duration", "memoryPressure", "thermalState"})
    _require_enum(value["operationCount"], f"{name}.operationCount", COUNT_VALUES)
    _require_enum(value["duration"], f"{name}.duration", DURATION_VALUES)
    _require_enum(value["memoryPressure"], f"{name}.memoryPressure", MEMORY_VALUES)
    _require_enum(value["thermalState"], f"{name}.thermalState", THERMAL_VALUES)


def _validate_failure(value: Any, name: str) -> None:
    _require_keys(
        value,
        name,
        {"terminationCategory"},
        {"exceptionType", "exceptionCode", "signal"},
    )
    if "exceptionType" in value:
        _require_int(value["exceptionType"], f"{name}.exceptionType", -(2**31), 2**31 - 1)
    if "exceptionCode" in value:
        _require_int(value["exceptionCode"], f"{name}.exceptionCode", 0, 2**53 - 1)
    if "signal" in value:
        _require_int(value["signal"], f"{name}.signal", -(2**31), 2**31 - 1)
    _require_enum(value["terminationCategory"], f"{name}.terminationCategory", TERMINATION_VALUES)


def _validate_stack(value: Any, name: str) -> None:
    _require_keys(value, name, {"threads", "truncated"})
    threads = value["threads"]
    if not isinstance(threads, list) or len(threads) > MAX_STACK_THREADS:
        raise ValidationError(f"{name}.threads is invalid")
    _require_bool(value["truncated"], f"{name}.truncated")

    frame_count = 0
    for thread_index, thread in enumerate(threads):
        thread_name = f"{name}.threads[{thread_index}]"
        _require_keys(thread, thread_name, {"frames"})
        frames = thread["frames"]
        if not isinstance(frames, list) or len(frames) > MAX_FRAMES_PER_THREAD:
            raise ValidationError(f"{thread_name}.frames is invalid")
        frame_count += len(frames)
        if frame_count > MAX_STACK_FRAMES:
            raise ValidationError(f"{name} contains too many frames")
        for frame_index, frame in enumerate(frames):
            frame_name = f"{thread_name}.frames[{frame_index}]"
            _require_keys(
                frame,
                frame_name,
                {"imageUUID", "offsetIntoBinaryTextSegment", "imageKind"},
            )
            _require_uuid(frame["imageUUID"], f"{frame_name}.imageUUID")
            _require_int(
                frame["offsetIntoBinaryTextSegment"],
                f"{frame_name}.offsetIntoBinaryTextSegment",
                0,
                MAX_FRAME_OFFSET,
            )
            _require_enum(frame["imageKind"], f"{frame_name}.imageKind", IMAGE_VALUES)


def _validate_provenance(value: Any, name: str) -> None:
    _require_keys(
        value,
        name,
        {
            "source",
            "incidentStart",
            "incidentEnd",
            "affectedRuntime",
            "receiptAt",
            "contextAssociation",
        },
    )
    _require_enum(value["source"], f"{name}.source", SOURCE_VALUES)
    incident_start = _require_date(value["incidentStart"], f"{name}.incidentStart")
    incident_end = _require_date(value["incidentEnd"], f"{name}.incidentEnd")
    if incident_end < incident_start:
        raise ValidationError(f"{name} has an invalid interval")
    _validate_runtime(value["affectedRuntime"], f"{name}.affectedRuntime")
    _require_date(value["receiptAt"], f"{name}.receiptAt")
    _require_enum(value["contextAssociation"], f"{name}.contextAssociation", ASSOCIATION_VALUES)


def _validate_report(value: Any, name: str) -> None:
    _require_keys(
        value,
        name,
        {"kind", "provenance"},
        {"resourceKind", "failure", "stack"},
    )
    _require_enum(value["kind"], f"{name}.kind", REPORT_KIND_VALUES)
    if value.get("resourceKind") is not None:
        _require_enum(value["resourceKind"], f"{name}.resourceKind", RESOURCE_KIND_VALUES)
    if value.get("failure") is not None:
        _validate_failure(value["failure"], f"{name}.failure")
    if value.get("stack") is not None:
        _validate_stack(value["stack"], f"{name}.stack")
    _validate_provenance(value["provenance"], f"{name}.provenance")


def validate_envelope(value: Any, idempotency_header: str | None) -> str:
    """Validate an envelope and return its canonical lower-case object key ID."""

    _require_keys(
        value,
        "envelope",
        {
            "schemaVersion",
            "idempotencyKey",
            "consentEpoch",
            "sessionToken",
            "receivedAt",
            "affectedRuntime",
            "receivingRuntime",
            "operation",
            "phase",
            "result",
            "state",
            "measurements",
            "report",
        },
    )
    _require_int(value["schemaVersion"], "envelope.schemaVersion", 1, 1)
    _require_uuid(value["idempotencyKey"], "envelope.idempotencyKey")
    _require_uuid(value["consentEpoch"], "envelope.consentEpoch")
    _require_uuid(value["sessionToken"], "envelope.sessionToken")
    _require_date(value["receivedAt"], "envelope.receivedAt")
    _require_uuid(idempotency_header, "Idempotency-Key")
    if idempotency_header.lower() != value["idempotencyKey"].lower():
        raise ValidationError("Idempotency-Key does not match the body")
    _validate_runtime(value["affectedRuntime"], "envelope.affectedRuntime")
    _validate_runtime(value["receivingRuntime"], "envelope.receivingRuntime")
    _require_enum(value["operation"], "envelope.operation", OPERATION_VALUES)
    _require_enum(value["phase"], "envelope.phase", PHASE_VALUES)
    _require_enum(value["result"], "envelope.result", RESULT_VALUES)
    _validate_state(value["state"], "envelope.state")
    _validate_measurements(value["measurements"], "envelope.measurements")
    _validate_report(value["report"], "envelope.report")
    return value["idempotencyKey"].lower()


def _reject_json_constant(value: str) -> None:
    raise ValidationError(f"non-finite JSON value {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError("duplicate JSON field")
        result[key] = value
    return result


def parse_request_body(body: bytes) -> Any:
    if not body or len(body) > MAX_BODY_BYTES:
        raise ValidationError("request body is outside the allowed size")
    try:
        text = body.decode("utf-8")
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValidationError("request body is not valid JSON") from error


@dataclass(frozen=True)
class ReceiverResponse:
    status_code: int
    headers: Mapping[str, str]
    body: bytes

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))


class MockReceiver:
    """In-memory receiver with the production contract's storage behavior."""

    endpoint_path = "/v1/diagnostics"

    def __init__(self, clock: Callable[[], datetime] | None = None) -> None:
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self._objects: dict[str, tuple[datetime, bytes]] = {}

    @property
    def objects(self) -> Mapping[str, tuple[datetime, bytes]]:
        return dict(self._objects)

    def receive(
        self,
        body: bytes,
        *,
        idempotency_header: str | None,
        content_type: str = "application/json",
        now: datetime | None = None,
    ) -> ReceiverResponse:
        if not content_type.lower().startswith("application/json"):
            return _json_response({"error": "invalid_request"}, 415)
        try:
            envelope = parse_request_body(body)
            event_id = validate_envelope(envelope, idempotency_header)
        except ValidationError:
            return _json_response({"error": "invalid_request"}, 400)

        received_at = now or self._clock()
        if received_at.tzinfo is None:
            received_at = received_at.replace(tzinfo=timezone.utc)
        self.purge_expired(received_at)
        key = f"diagnostics/{event_id}.json"
        self._objects.setdefault(key, (received_at, body))
        return _json_response({"accepted": True, "eventID": event_id}, 200)

    def purge_expired(self, now: datetime | None = None) -> None:
        current = now or self._clock()
        if current.tzinfo is None:
            current = current.replace(tzinfo=timezone.utc)
        cutoff = current - SERVER_RETENTION
        for key, (stored_at, _) in list(self._objects.items()):
            if stored_at <= cutoff:
                del self._objects[key]


def _json_response(value: Any, status_code: int) -> ReceiverResponse:
    return ReceiverResponse(
        status_code=status_code,
        headers={
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        body=json.dumps(value, separators=(",", ":")).encode("utf-8"),
    )


class _MockReceiverHandler(BaseHTTPRequestHandler):
    server: "MockReceiverHTTPServer"

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path != self.server.receiver.endpoint_path:
            self._send(ReceiverResponse(404, {"Cache-Control": "no-store"}, b""))
            return
        try:
            content_length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            content_length = -1
        if content_length < 0 or content_length > MAX_BODY_BYTES:
            self._send(_json_response({"error": "invalid_request"}, 400))
            return
        body = self.rfile.read(content_length)
        response = self.server.receiver.receive(
            body,
            idempotency_header=self.headers.get("Idempotency-Key"),
            content_type=self.headers.get("Content-Type", ""),
        )
        self._send(response)

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        self._send(ReceiverResponse(404, {"Cache-Control": "no-store"}, b""))

    def do_PUT(self) -> None:  # noqa: N802 - stdlib handler API
        self._send(ReceiverResponse(405, {"Allow": "POST", "Cache-Control": "no-store"}, b""))

    def _send(self, response: ReceiverResponse) -> None:
        self.send_response(response.status_code)
        for key, value in response.headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(response.body)))
        self.end_headers()
        if response.body:
            self.wfile.write(response.body)

    def log_message(self, _format: str, *_args: Any) -> None:
        # Request paths and headers may contain sensitive metadata. Tests are
        # intentionally silent just like the proposed production receiver.
        return


class MockReceiverHTTPServer(ThreadingHTTPServer):
    def __init__(self, receiver: MockReceiver) -> None:
        super().__init__(("127.0.0.1", 0), _MockReceiverHandler)
        self.receiver = receiver


def start_mock_server(
    receiver: MockReceiver | None = None,
) -> tuple[MockReceiverHTTPServer, threading.Thread]:
    server = MockReceiverHTTPServer(receiver or MockReceiver())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread
