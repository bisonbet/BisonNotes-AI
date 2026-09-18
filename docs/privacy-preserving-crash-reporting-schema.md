# Privacy-preserving diagnostic ingestion schema

Status: client contract and review artifact. Production ingestion is intentionally disabled until the backend checklist and disclosure gates are complete.

## Contract

The client sends one JSON CrashEnvelope per normalized Apple diagnostic or bounded lifecycle heuristic. The schema is versioned by schemaVersion; the initial value is 1. The server must reject an unknown schema version, unknown enum value, missing required field, non-finite or out-of-range number, oversized body, or an envelope containing fields outside the allowlist.

The client uses an ephemeral HTTPS request with:

- Content-Type: application/json
- Cache-Control: no-store
- Idempotency-Key: the envelope idempotencyKey
- no cookies, credentials, provider tokens, or redirect following

The successful response must be a small JSON acknowledgement:

    {
      "accepted": true,
      "eventID": "4a6b1a4f-88f0-4c6d-a0a3-0ab2f19e2df3"
    }

eventID must equal the request's idempotencyKey. A successful HTTP status without this acknowledgement is not accepted. The server must make repeated requests with the same idempotency key safe and must not merge separate occurrence IDs merely because their stack frames match.

## Allowlisted fields

CrashEnvelope contains only:

- schema version, fresh consent epoch, session token, idempotency key, and receipt time;
- affected and receiving app version/build, OS version, platform, and hardware model identifier;
- fixed operation, phase, result, foreground state, recording/syncing flags, and bucketed measurements;
- report kind, optional reviewed resource kind, bounded numeric failure codes, and context association;
- incident start/end and receipt times;
- projected stack frames containing a shipped-image UUID, image-relative text-segment offset, reviewed image kind, and truncation state.

The fresh tokens are pseudonymous telemetry identities. They are not AppLog.sessionId, IDFV, account IDs, CloudKit IDs, recording IDs, job IDs, or any content identifier.

The following never enters the automatic envelope: audio, transcripts, summaries, titles, prompts, recording names, paths, URLs, API responses, credentials, user settings, environment variables, arbitrary exception text, OSLog/breadcrumb text, recovery inventories, raw MetricKit payloads, or arbitrary dictionaries. Build UUIDs and image-relative offsets are the sole intentionally retained identifier-like symbolication fields.

## Bounds and retention

| Item | Limit |
| --- | ---: |
| Structured local events | 64 / 32 KiB |
| Structured event age | 48 hours |
| Encoded envelope | 128 KiB |
| Queued envelopes | 20 / 2 MiB |
| Queue age | 7 days |
| Server retention | 14 days |
| Stack threads / frames per thread / total frames | 32 / 64 / 256 |
| Manual-only raw Apple payloads | 5 / 1 MiB / 7 days |

Oldest entries are discarded first. Corrupt, missing, inaccessible, or partially written telemetry storage is dropped safely. The automatic pipeline never reads the detailed diagnostic export and never enumerates recordings.

## Sanitized example

This example is representative only. UUIDs and offsets are synthetic, and no user data is present:

    {
      "schemaVersion": 1,
      "idempotencyKey": "4a6b1a4f-88f0-4c6d-a0a3-0ab2f19e2df3",
      "consentEpoch": "7a2b1f20-5db0-4b8e-9f37-2c5ea0d0e9ab",
      "sessionToken": "9e6cf64e-fd6d-4a0e-86d6-3d03f6f2b8aa",
      "receivedAt": "2026-09-18T14:15:00Z",
      "affectedRuntime": {
        "appVersion": "3.0",
        "appBuild": "42",
        "osVersion": "27.0.0",
        "platform": "ios",
        "hardwareModel": "iPhone17,1"
      },
      "receivingRuntime": {
        "appVersion": "3.0",
        "appBuild": "42",
        "osVersion": "27.0.0",
        "platform": "ios",
        "hardwareModel": "iPhone17,1"
      },
      "operation": "recording_finalize",
      "phase": "end",
      "result": "failure",
      "state": {
        "foregroundState": "foreground",
        "isRecording": false,
        "isSyncing": false
      },
      "measurements": {
        "operationCount": "one",
        "duration": "one_to_ten_seconds",
        "memoryPressure": "unknown",
        "thermalState": "nominal"
      },
      "report": {
        "kind": "apple_crash",
        "resourceKind": null,
        "failure": {
          "exceptionType": 1,
          "exceptionCode": 10,
          "signal": 11,
          "terminationCategory": "bad_access"
        },
        "stack": {
          "threads": [
            {
              "frames": [
                {
                  "imageUUID": "11111111-2222-3333-4444-555555555555",
                  "offsetIntoBinaryTextSegment": 4096,
                  "imageKind": "application"
                }
              ]
            }
          ],
          "truncated": false
        },
        "provenance": {
          "source": "modern_metrickit",
          "incidentStart": "2026-09-18T14:14:59Z",
          "incidentEnd": "2026-09-18T14:14:59Z",
          "affectedRuntime": {
            "appVersion": "3.0",
            "appBuild": "42",
            "osVersion": "27.0.0",
            "platform": "ios",
            "hardwareModel": "iPhone17,1"
          },
          "receiptAt": "2026-09-18T14:15:00Z",
          "contextAssociation": "matched"
        }
      }
    }

The raw Apple report remains in the manual-only bounded store for an explicit detailed export. It is not a fallback body, a retry payload, or a source for arbitrary automatic fields.
