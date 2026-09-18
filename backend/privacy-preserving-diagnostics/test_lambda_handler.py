from __future__ import annotations

import copy
import json
import os
import unittest
from datetime import datetime, timedelta, timezone

from lambda_handler import CleanupFailure, cleanup_handler, lambda_handler


class PreconditionFailed(Exception):
    def __init__(self) -> None:
        self.response = {"Error": {"Code": "PreconditionFailed"}}


class FakePaginator:
    def __init__(self, objects: list[dict[str, object]]) -> None:
        self.objects = objects

    def paginate(self, **_kwargs: object) -> list[dict[str, object]]:
        return [{"Contents": self.objects}]


class FakeS3:
    def __init__(
        self,
        objects: list[dict[str, object]] | None = None,
        delete_responses: list[dict[str, object]] | None = None,
    ) -> None:
        self.stored: dict[str, bytes] = {}
        self.objects = objects or []
        self.put_count = 0
        self.deleted: list[str] = []
        self.delete_calls = 0
        self.delete_responses = list(delete_responses or [])

    def put_object(self, **kwargs: object) -> None:
        self.put_count += 1
        key = str(kwargs["Key"])
        if key in self.stored:
            raise PreconditionFailed()
        self.stored[key] = bytes(kwargs["Body"])

    def get_paginator(self, _name: str) -> FakePaginator:
        return FakePaginator(self.objects)

    def delete_objects(self, **kwargs: object) -> dict[str, object]:
        self.delete_calls += 1
        delete = kwargs["Delete"]
        keys = [str(item["Key"]) for item in delete["Objects"]]
        response = (
            self.delete_responses.pop(0)
            if self.delete_responses
            else {"Deleted": [{"Key": key} for key in keys]}
        )
        for item in response.get("Deleted", []):
            if isinstance(item, dict) and isinstance(item.get("Key"), str):
                self.deleted.append(item["Key"])
        return response


class FakeCloudWatch:
    def __init__(self) -> None:
        self.calls: list[dict[str, object]] = []

    def put_metric_data(self, **kwargs: object) -> None:
        self.calls.append(kwargs)


class LambdaHandlerTests(unittest.TestCase):
    now = datetime(2026, 9, 18, 14, 15, tzinfo=timezone.utc)
    event_id = "11111111-2222-6222-0222-555555555555"

    def setUp(self) -> None:
        os.environ["DIAGNOSTIC_BUCKET"] = "review-only-bisonnotes-diagnostics"
        os.environ["DIAGNOSTIC_PATH"] = "/v1/diagnostics"
        os.environ["RECEIVER_READY"] = "true"
        os.environ["ENVIRONMENT_NAME"] = "staging"

    def tearDown(self) -> None:
        os.environ.pop("DIAGNOSTIC_BUCKET", None)
        os.environ.pop("DIAGNOSTIC_PATH", None)
        os.environ.pop("RECEIVER_READY", None)
        os.environ.pop("ENVIRONMENT_NAME", None)

    def test_ingest_stores_and_acknowledges_duplicate_without_overwrite(self) -> None:
        s3 = FakeS3()
        body = json.dumps(self.envelope(), separators=(",", ":"))
        first = lambda_handler(self.event(body), None, s3)
        duplicate = lambda_handler(self.event(body), None, s3)

        self.assertEqual(first["statusCode"], 200)
        self.assertEqual(duplicate["statusCode"], 200)
        self.assertEqual(json.loads(first["body"]), {"accepted": True, "eventID": self.event_id})
        self.assertEqual(len(s3.stored), 1)
        self.assertEqual(s3.put_count, 2)

    def test_rejects_unknown_fields_and_mismatched_headers(self) -> None:
        s3 = FakeS3()
        unknown = self.envelope()
        unknown["unexpected"] = "must not be stored"

        unknown_response = lambda_handler(self.event(json.dumps(unknown)), None, s3)
        mismatch_response = lambda_handler(
            self.event(json.dumps(self.envelope()), idempotency_key="22222222-3333-6333-0333-666666666666"),
            None,
            s3,
        )

        self.assertEqual(unknown_response["statusCode"], 400)
        self.assertEqual(mismatch_response["statusCode"], 400)
        self.assertEqual(s3.stored, {})

    def test_ingest_stays_disabled_until_receiver_is_ready(self) -> None:
        os.environ["RECEIVER_READY"] = "false"
        s3 = FakeS3()
        response = lambda_handler(
            self.event(json.dumps(self.envelope())),
            None,
            s3,
        )

        self.assertEqual(response["statusCode"], 503)
        self.assertEqual(s3.stored, {})

    def test_cleanup_removes_only_objects_older_than_conservative_cutoff(self) -> None:
        old = self.now - timedelta(days=13)
        recent = self.now - timedelta(days=12)
        s3 = FakeS3([
            {"Key": "diagnostics/old.json", "LastModified": old},
            {"Key": "diagnostics/recent.json", "LastModified": recent},
        ])

        cloudwatch = FakeCloudWatch()
        result = cleanup_handler(
            {},
            None,
            s3,
            self.now,
            cloudwatch_client=cloudwatch,
            sleep_fn=lambda _seconds: None,
        )

        self.assertEqual(result, {"deletedCount": 1, "heartbeatPublished": 1})
        self.assertEqual(s3.deleted, ["diagnostics/old.json"])
        self.assertEqual(len(cloudwatch.calls), 1)

    def test_cleanup_retries_transient_partial_delete_errors(self) -> None:
        old = self.now - timedelta(days=13)
        s3 = FakeS3(
            [{"Key": "diagnostics/old.json", "LastModified": old}],
            delete_responses=[
                {
                    "Errors": [
                        {"Key": "diagnostics/old.json", "Code": "SlowDown"}
                    ]
                }
            ],
        )
        cloudwatch = FakeCloudWatch()
        sleeps: list[float] = []

        result = cleanup_handler(
            {},
            None,
            s3,
            self.now,
            cloudwatch_client=cloudwatch,
            sleep_fn=sleeps.append,
        )

        self.assertEqual(result["deletedCount"], 1)
        self.assertEqual(s3.delete_calls, 2)
        self.assertEqual(s3.deleted, ["diagnostics/old.json"])
        self.assertEqual(sleeps, [1])
        self.assertEqual(len(cloudwatch.calls), 1)

    def test_cleanup_fails_when_s3_reports_permanent_partial_delete_error(self) -> None:
        old = self.now - timedelta(days=13)
        s3 = FakeS3(
            [{"Key": "diagnostics/old.json", "LastModified": old}],
            delete_responses=[
                {
                    "Errors": [
                        {
                            "Key": "diagnostics/old.json",
                            "Code": "AccessDenied",
                        }
                    ]
                }
            ],
        )
        cloudwatch = FakeCloudWatch()

        with self.assertRaises(CleanupFailure):
            cleanup_handler(
                {},
                None,
                s3,
                self.now,
                cloudwatch_client=cloudwatch,
                sleep_fn=lambda _seconds: None,
            )

        self.assertEqual(s3.deleted, [])
        self.assertEqual(cloudwatch.calls, [])

    def event(self, body: str, idempotency_key: str | None = None) -> dict[str, object]:
        return {
            "version": "2.0",
            "rawPath": "/v1/diagnostics",
            "requestContext": {"http": {"method": "POST", "path": "/v1/diagnostics"}},
            "headers": {
                "content-type": "application/json",
                "idempotency-key": idempotency_key or self.event_id,
            },
            "body": body,
            "isBase64Encoded": False,
        }

    def envelope(self) -> dict[str, object]:
        runtime = {
            "appVersion": "3.0",
            "appBuild": "42",
            "osVersion": "27.0.0",
            "platform": "ios",
            "hardwareModel": "iPhone17,1",
        }
        return {
            "schemaVersion": 1,
            "idempotencyKey": self.event_id,
            "consentEpoch": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            "sessionToken": "99999999-8888-4777-8666-555555555555",
            "receivedAt": "2026-09-18T14:15:00Z",
            "affectedRuntime": runtime,
            "receivingRuntime": copy.deepcopy(runtime),
            "operation": "recording_finalize",
            "phase": "end",
            "result": "failure",
            "state": {
                "foregroundState": "foreground",
                "isRecording": False,
                "isSyncing": False,
            },
            "measurements": {
                "operationCount": "one",
                "duration": "one_to_ten_seconds",
                "memoryPressure": "unknown",
                "thermalState": "nominal",
            },
            "report": {
                "kind": "apple_crash",
                "failure": {
                    "exceptionType": 1,
                    "exceptionCode": 10,
                    "signal": 11,
                    "terminationCategory": "bad_access",
                },
                "provenance": {
                    "source": "modern_metrickit",
                    "incidentStart": "2026-09-18T14:14:59Z",
                    "incidentEnd": "2026-09-18T14:15:00Z",
                    "affectedRuntime": copy.deepcopy(runtime),
                    "receiptAt": "2026-09-18T14:15:00Z",
                    "contextAssociation": "matched",
                },
            },
        }


if __name__ == "__main__":
    unittest.main()
