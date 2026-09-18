from __future__ import annotations

import copy
import json
import unittest
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from receiver import MAX_BODY_BYTES, MockReceiver, start_mock_server


class MockReceiverTests(unittest.TestCase):
    incident_time = datetime(2026, 9, 18, 14, 15, tzinfo=timezone.utc)

    def test_accepts_valid_envelope_and_deduplicates_by_idempotency_key(self) -> None:
        receiver = MockReceiver(clock=lambda: self.incident_time)
        body = json.dumps(self.valid_envelope(), separators=(",", ":")).encode("utf-8")
        headers = "11111111-2222-6222-0222-555555555555"

        first = receiver.receive(body, idempotency_header=headers)
        second = receiver.receive(body, idempotency_header=headers)

        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertEqual(first.json(), {"accepted": True, "eventID": headers.lower()})
        self.assertEqual(second.json(), first.json())
        self.assertEqual(len(receiver.objects), 1)

    def test_rejects_unknown_fields_and_mismatched_header_without_storage(self) -> None:
        receiver = MockReceiver(clock=lambda: self.incident_time)
        envelope = self.valid_envelope()
        envelope["unexpected"] = "must not be retained"
        body = json.dumps(envelope).encode("utf-8")

        unknown_field = receiver.receive(
            body,
            idempotency_header=envelope["idempotencyKey"],
        )
        mismatched_header = receiver.receive(
            json.dumps(self.valid_envelope()).encode("utf-8"),
            idempotency_header="22222222-3333-4333-8333-666666666666",
        )

        self.assertEqual(unknown_field.status_code, 400)
        self.assertEqual(mismatched_header.status_code, 400)
        self.assertEqual(receiver.objects, {})

    def test_rejects_oversized_body_and_nonfinite_json(self) -> None:
        receiver = MockReceiver(clock=lambda: self.incident_time)
        oversized = receiver.receive(
            b"{" + b"x" * MAX_BODY_BYTES + b"}",
            idempotency_header="11111111-2222-6222-0222-555555555555",
        )
        nonfinite = receiver.receive(
            b'{"schemaVersion": NaN}',
            idempotency_header="11111111-2222-6222-0222-555555555555",
        )

        self.assertEqual(oversized.status_code, 400)
        self.assertEqual(nonfinite.status_code, 400)
        self.assertEqual(receiver.objects, {})

    def test_retention_removes_objects_at_fourteen_days(self) -> None:
        receiver = MockReceiver(clock=lambda: self.incident_time)
        body = json.dumps(self.valid_envelope()).encode("utf-8")
        accepted = receiver.receive(
            body,
            idempotency_header="11111111-2222-6222-0222-555555555555",
            now=self.incident_time,
        )
        self.assertEqual(accepted.status_code, 200)

        receiver.purge_expired(self.incident_time + timedelta(days=13, hours=23))
        self.assertEqual(len(receiver.objects), 1)
        receiver.purge_expired(self.incident_time + timedelta(days=14))
        self.assertEqual(receiver.objects, {})

    def test_loopback_http_server_exposes_ingest_only(self) -> None:
        receiver = MockReceiver(clock=lambda: self.incident_time)
        server, thread = start_mock_server(receiver)
        try:
            body = json.dumps(self.valid_envelope(), separators=(",", ":")).encode("utf-8")
            request = Request(
                f"http://{server.server_address[0]}:{server.server_address[1]}{receiver.endpoint_path}",
                data=body,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Cache-Control": "no-store",
                    "Idempotency-Key": "11111111-2222-6222-0222-555555555555",
                },
            )
            with urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 200)
                self.assertEqual(
                    json.loads(response.read()),
                    {"accepted": True, "eventID": "11111111-2222-6222-0222-555555555555"},
                )

            with self.assertRaises(HTTPError) as error:
                urlopen(
                    f"http://{server.server_address[0]}:{server.server_address[1]}{receiver.endpoint_path}/report",
                    timeout=2,
                )
            self.assertEqual(error.exception.code, 404)
            error.exception.close()
            self.assertEqual(len(receiver.objects), 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    @classmethod
    def valid_envelope(cls) -> dict[str, object]:
        runtime = {
            "appVersion": "3.0",
            "appBuild": "42",
            "osVersion": "27.0.0",
            "platform": "ios",
            "hardwareModel": "iPhone17,1",
        }
        return {
            "schemaVersion": 1,
            "idempotencyKey": "11111111-2222-6222-0222-555555555555",
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
                "resourceKind": None,
                "failure": {
                    "exceptionType": 1,
                    "exceptionCode": 10,
                    "signal": 11,
                    "terminationCategory": "bad_access",
                },
                "stack": {
                    "threads": [
                        {
                            "frames": [
                                {
                                    "imageUUID": "11111111-2222-4333-8444-555555555555",
                                    "offsetIntoBinaryTextSegment": 4096,
                                    "imageKind": "application",
                                }
                            ]
                        }
                    ],
                    "truncated": False,
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
