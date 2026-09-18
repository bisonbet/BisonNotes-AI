"""AWS Lambda handlers for the review-only diagnostics receiver.

The ingest handler is intended for API Gateway HTTP API payload format 2.0.
The cleanup handler is intended for an hourly EventBridge schedule. Both are
deliberately dependency-light; boto3 is supplied by the AWS Lambda runtime.
"""

from __future__ import annotations

import base64
import json
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Mapping

try:  # boto3 is supplied by Lambda, but is unnecessary for local unit tests.
    import boto3
except ImportError:  # pragma: no cover - exercised only outside Lambda.
    boto3 = None

from receiver import MAX_BODY_BYTES, ValidationError, parse_request_body, validate_envelope


INGEST_PATH = "/v1/diagnostics"
CLEANUP_AGE = timedelta(days=13)
CLEANUP_METRIC_NAMESPACE = "BisonNotes/Diagnostics"
MAX_DELETE_ATTEMPTS = 3
RETRYABLE_DELETE_ERROR_CODES = frozenset({
    "500",
    "503",
    "InternalError",
    "RequestTimeout",
    "ServiceUnavailable",
    "SlowDown",
    "Throttling",
    "ThrottlingException",
    "UnconfirmedDelete",
})


class CleanupFailure(RuntimeError):
    """Raised so Lambda Errors and the CloudWatch alarm record a failed run."""


def _json_response(status_code: int, value: Any) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
        },
        "isBase64Encoded": False,
        "body": json.dumps(value, separators=(",", ":")),
    }


def _header(headers: Mapping[str, Any], name: str) -> str | None:
    for key, value in headers.items():
        if key.lower() == name.lower() and isinstance(value, str):
            return value
    return None


def _event_path(event: Mapping[str, Any]) -> str:
    if isinstance(event.get("rawPath"), str):
        return event["rawPath"]
    request_context = event.get("requestContext")
    if isinstance(request_context, Mapping):
        http = request_context.get("http")
        if isinstance(http, Mapping) and isinstance(http.get("path"), str):
            return http["path"]
    return event.get("path", "") if isinstance(event.get("path"), str) else ""


def _event_method(event: Mapping[str, Any]) -> str:
    request_context = event.get("requestContext")
    if isinstance(request_context, Mapping):
        http = request_context.get("http")
        if isinstance(http, Mapping) and isinstance(http.get("method"), str):
            return http["method"].upper()
    return event.get("httpMethod", "").upper() if isinstance(event.get("httpMethod"), str) else ""


def _event_body(event: Mapping[str, Any]) -> bytes:
    body = event.get("body")
    if not isinstance(body, str):
        return b""
    if event.get("isBase64Encoded") is True:
        return base64.b64decode(body, validate=True)
    return body.encode("utf-8")


def _s3_client(client: Any | None) -> Any:
    if client is not None:
        return client
    if boto3 is None:
        raise RuntimeError("boto3 is required in the Lambda runtime")
    return boto3.client("s3")


def _cloudwatch_client(client: Any | None) -> Any:
    if client is not None:
        return client
    if boto3 is None:
        raise RuntimeError("boto3 is required in the Lambda runtime")
    return boto3.client("cloudwatch")


def _is_precondition_failure(error: Exception) -> bool:
    response = getattr(error, "response", None)
    if not isinstance(response, Mapping):
        return False
    error_details = response.get("Error")
    if not isinstance(error_details, Mapping):
        return False
    return str(error_details.get("Code", "")) in {"PreconditionFailed", "412"}


def _error_code(error: Any) -> str:
    response = getattr(error, "response", None)
    if isinstance(response, Mapping):
        details = response.get("Error")
        if isinstance(details, Mapping):
            return str(details.get("Code", "Unknown"))
    if isinstance(error, Mapping):
        return str(error.get("Code", "Unknown"))
    return str(error)


def _is_retryable_delete_code(code: str) -> bool:
    return code in RETRYABLE_DELETE_ERROR_CODES or code.startswith("5")


def _delete_batch(
    client: Any,
    bucket: str,
    keys: list[str],
    sleep_fn: Any,
) -> int:
    pending = list(dict.fromkeys(keys))
    deleted: set[str] = set()

    for attempt in range(1, MAX_DELETE_ATTEMPTS + 1):
        if not pending:
            return len(deleted)

        try:
            response = client.delete_objects(
                Bucket=bucket,
                Delete={
                    "Objects": [{"Key": key} for key in pending],
                    # Keep the per-object Deleted entries so a successful
                    # request cannot be mistaken for a successful deletion
                    # when S3 reports individual errors.
                    "Quiet": False,
                },
            )
        except Exception as error:
            code = _error_code(error)
            if _is_retryable_delete_code(code) and attempt < MAX_DELETE_ATTEMPTS:
                sleep_fn(min(2 ** (attempt - 1), 4))
                continue
            raise CleanupFailure(
                f"diagnostic cleanup delete request failed after {attempt} attempts"
            ) from None

        if not isinstance(response, Mapping):
            raise CleanupFailure("diagnostic cleanup received an invalid delete response")

        submitted = set(pending)
        deleted_items = response.get("Deleted") or []
        if not isinstance(deleted_items, list):
            raise CleanupFailure("diagnostic cleanup received an invalid deleted list")
        for item in deleted_items:
            if isinstance(item, Mapping) and isinstance(item.get("Key"), str):
                key = item["Key"]
                if key in submitted:
                    deleted.add(key)

        errors = response.get("Errors") or []
        if not isinstance(errors, list):
            raise CleanupFailure("diagnostic cleanup received an invalid error list")
        error_by_key: dict[str, str] = {}
        for item in errors:
            if not isinstance(item, Mapping) or not isinstance(item.get("Key"), str):
                raise CleanupFailure("diagnostic cleanup received an unkeyed delete error")
            error_by_key[item["Key"]] = str(item.get("Code", "Unknown"))

        # S3 reports one Deleted or Errors entry for every requested object.
        # Treat an unreported key as unconfirmed rather than counting it as
        # successfully deleted.
        unresolved = submitted - deleted - set(error_by_key)
        for key in unresolved:
            error_by_key[key] = "UnconfirmedDelete"

        next_pending: list[str] = []
        terminal_failures = 0
        for key, code in error_by_key.items():
            if key in deleted:
                continue
            if _is_retryable_delete_code(code) and attempt < MAX_DELETE_ATTEMPTS:
                next_pending.append(key)
            else:
                terminal_failures += 1

        if terminal_failures:
            raise CleanupFailure(
                f"diagnostic cleanup could not delete {terminal_failures} objects"
            )
        pending = next_pending
        if pending and attempt < MAX_DELETE_ATTEMPTS:
            sleep_fn(min(2 ** (attempt - 1), 4))

    if pending:
        raise CleanupFailure("diagnostic cleanup exhausted delete retries")
    return len(deleted)


def _publish_cleanup_heartbeat(
    client: Any,
    environment: str,
    timestamp: datetime,
) -> None:
    client.put_metric_data(
        Namespace=CLEANUP_METRIC_NAMESPACE,
        MetricData=[
            {
                "MetricName": "CleanupHeartbeat",
                "Dimensions": [{"Name": "Environment", "Value": environment}],
                "Timestamp": timestamp,
                "Value": 1,
                "Unit": "Count",
            }
        ],
    )


def lambda_handler(
    event: Mapping[str, Any],
    _context: Any,
    s3_client: Any | None = None,
) -> dict[str, Any]:
    """Validate and conditionally store one API Gateway diagnostic envelope."""

    path = _event_path(event)
    method = _event_method(event)
    if path != os.environ.get("DIAGNOSTIC_PATH", INGEST_PATH):
        return _json_response(404, {"error": "not_found"})
    if method != "POST":
        return {
            "statusCode": 405,
            "headers": {"Allow": "POST", "Cache-Control": "no-store"},
            "isBase64Encoded": False,
            "body": "",
        }

    headers = event.get("headers")
    headers = headers if isinstance(headers, Mapping) else {}
    content_type = _header(headers, "Content-Type") or ""
    if not content_type.lower().startswith("application/json"):
        return _json_response(415, {"error": "invalid_request"})

    try:
        body = _event_body(event)
        if not body or len(body) > MAX_BODY_BYTES:
            raise ValidationError("request body is outside the allowed size")
        envelope = parse_request_body(body)
        event_id = validate_envelope(envelope, _header(headers, "Idempotency-Key"))
    except (ValidationError, UnicodeDecodeError, ValueError, base64.binascii.Error):
        return _json_response(400, {"error": "invalid_request"})

    bucket = os.environ.get("DIAGNOSTIC_BUCKET")
    if not bucket or os.environ.get("RECEIVER_READY", "false").lower() != "true":
        return _json_response(503, {"error": "receiver_unavailable"})

    try:
        _s3_client(s3_client).put_object(
            Bucket=bucket,
            Key=f"diagnostics/{event_id}.json",
            Body=body,
            ContentType="application/json",
            CacheControl="no-store",
            IfNoneMatch="*",
        )
    except Exception as error:  # Do not log or echo request data.
        if not _is_precondition_failure(error):
            return _json_response(503, {"error": "receiver_unavailable"})

    return _json_response(200, {"accepted": True, "eventID": event_id})


def cleanup_handler(
    _event: Mapping[str, Any],
    _context: Any,
    s3_client: Any | None = None,
    now: datetime | None = None,
    cloudwatch_client: Any | None = None,
    sleep_fn: Any = time.sleep,
) -> dict[str, int]:
    """Delete old reports and publish a heartbeat only after a complete run."""

    bucket = os.environ.get("DIAGNOSTIC_BUCKET")
    if not bucket:
        raise RuntimeError("DIAGNOSTIC_BUCKET is required")
    current = now or datetime.now(timezone.utc)
    if current.tzinfo is None:
        current = current.replace(tzinfo=timezone.utc)
    cutoff = current.astimezone(timezone.utc) - CLEANUP_AGE

    client = _s3_client(s3_client)
    deleted_count = 0
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix="diagnostics/"):
        objects = page.get("Contents", [])
        if not isinstance(objects, list):
            raise CleanupFailure("diagnostic cleanup received an invalid object list")
        expired_keys: list[str] = []
        for item in objects:
            if not isinstance(item, Mapping):
                continue
            key = item.get("Key")
            last_modified = item.get("LastModified")
            if not isinstance(key, str) or not isinstance(last_modified, datetime):
                continue
            if last_modified.tzinfo is None:
                last_modified = last_modified.replace(tzinfo=timezone.utc)
            if last_modified.astimezone(timezone.utc) <= cutoff:
                expired_keys.append(key)
        for start in range(0, len(expired_keys), 1000):
            deleted_count += _delete_batch(
                client,
                bucket,
                expired_keys[start:start + 1000],
                sleep_fn,
            )

    _publish_cleanup_heartbeat(
        _cloudwatch_client(cloudwatch_client),
        os.environ.get("ENVIRONMENT_NAME", "unknown"),
        current.astimezone(timezone.utc),
    )
    return {"deletedCount": deleted_count, "heartbeatPublished": 1}
