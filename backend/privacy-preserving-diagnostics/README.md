# Privacy-preserving diagnostic receiver draft

This directory contains a review-only AWS backend candidate and local receiver
tests. Nothing here is deployed, no account-specific ARN, credential, or bucket
name is embedded, and the app's production endpoint remains deliberately
unset. The template's hostname is only a review default and remains a
deployment parameter.

## Candidate production shape

- Amazon API Gateway HTTP API exposes only `POST /v1/diagnostics` over HTTPS.
- AWS Lambda validates the closed envelope contract and writes one object to a
  private S3 bucket at `diagnostics/<idempotency-key>.json`.
- The S3 write uses `If-None-Match: *`, so duplicate submissions receive the
  same acknowledgement without overwriting the first occurrence.
- An hourly EventBridge-triggered cleanup Lambda is enabled in the template,
  with retries, a failure alarm, and a two-hour missing-heartbeat alarm. S3
  lifecycle expiration is configured at 13 days as a second cleanup path; the
  deployment gate requires versioning, Object Lock, replication, and public
  access to remain disabled.
- The template defaults `ReceiverReady` to `false`. Real reports must remain
  rejected until the staging deletion exercise and cleanup monitoring checks
  are complete; changing readiness is a separate reviewed deployment input.
- API Gateway defines a best-effort 2 requests/second rate and 10-request
  burst by default. These values are abuse/cost guardrails, not a guaranteed
  billing cap.
- Lambda roles are separated: ingest can only write diagnostic objects and
  cleanup can list/delete the diagnostic prefix. Report access belongs to a
  separately managed, MFA-protected operator role and is never public.

The implementation is in `lambda_handler.py` and the review-only SAM template
is `template.yaml`. The existing `receiver.py` is a dependency-free local
contract validator and loopback mock, not a production service.

## Local tests

Run the local receiver and Lambda tests without contacting AWS:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s backend/privacy-preserving-diagnostics -p 'test_*.py'
```

The tests cover strict field rejection, idempotent S3-style conditional writes,
mismatched headers, body-size enforcement, readiness gating, successful and
partial S3 deletion responses (including retry and failure paths), cleanup
heartbeats, retention cleanup, and a real loopback HTTP request. They never use
the production endpoint.
