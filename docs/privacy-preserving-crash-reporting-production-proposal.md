# Privacy-preserving diagnostic receiver: AWS production proposal

Status: implementation draft for review. The receiver is not deployed, no
production URL is configured in the app, and no disclosure text has been
published. The intended AWS Region is `us-east-1`; the proposed hostnames are
`staging.diagnostics.bisonnetworking.com` and
`diagnostics.bisonnetworking.com` under `bisonnetworking.com`.

## Recommended smallest backend

Use one Amazon API Gateway HTTP API, one AWS Lambda ingest function, one
private Amazon S3 Standard bucket, and one small scheduled cleanup Lambda:

```text
BisonNotes client --HTTPS POST--> API Gateway --> ingest Lambda --conditional PUT--> S3
                                                        ^                         |
                                                        |                         +-- lifecycle expiry
                                      hourly cleanup Lambda --list/delete----------+
```

The API accepts only `POST /v1/diagnostics`. Lambda validates the closed
envelope schema and writes one object at
`diagnostics/<idempotency-key>.json`. There is no report `GET`, listing,
search, admin, or public-bucket route. The review implementation is in
`backend/privacy-preserving-diagnostics/lambda_handler.py`; the SAM template
is `backend/privacy-preserving-diagnostics/template.yaml`.

The conditional S3 write uses `If-None-Match: *`, so a duplicate occurrence is
acknowledged without overwriting the first object. The ingest role cannot read
or delete reports. The cleanup role cannot read report bodies.

The SAM template creates distinct bucket names for `staging` and `production`,
defines a best-effort API Gateway throttle of 2 requests per second with a
10-request burst by default, enables hourly cleanup with EventBridge retries,
and creates alarms for cleanup errors and a missing two-hour cleanup heartbeat.
The throttle is an abuse/cost guardrail, not a spending cap. The template also
defaults `ReceiverReady` to `false`; the ingest Lambda will not accept reports
until readiness is deliberately enabled after staging checks.

## Estimated monthly cost

For a small app with an existing AWS account, the service components have no
fixed monthly minimum. A realistic budget is **approximately $0–$2/month at
low volume**, excluding any existing AWS support plan, CloudTrail organization
charges, optional WAF, customer-managed KMS keys, or domain costs:

- API Gateway HTTP API is priced from about $1 per million requests in the
  first tier. [API Gateway pricing](https://aws.amazon.com/api-gateway/pricing/)
- Lambda charges $0.20 per million requests after the one-million-request free
  tier, plus execution duration; this function should be tiny. [Lambda pricing](https://aws.amazon.com/lambda/pricing/)
- S3 Standard storage is approximately $0.023/GB-month, PUT requests are
  approximately $0.005 per 1,000, and DELETE requests are free. A 14-day
  diagnostic store should be far below one cent of storage at normal volume.
  [S3 pricing](https://aws.amazon.com/s3/pricing/)
- CloudWatch log volume is the main variable for a quiet service; the template
  caps Lambda log retention at 7 days and the code never logs request bodies.

The exact estimate depends on the AWS Region, account-wide free-tier usage,
CloudTrail configuration, and report volume.

## Deployment requirements

Before enabling an endpoint, an operator must:

1. Confirm the AWS account owner, target Region, data-residency requirement,
   approved hostname, billing tags, and existing CloudTrail/security standards.
2. Deploy the SAM template only to a staging stack first. Keep account IDs,
   API IDs, bucket names, credentials, and final hostnames outside the repo.
3. Verify S3 Block Public Access, Bucket Owner Enforced ownership, default
   SSE-S3 encryption, no versioning, no Object Lock, no replication, and no
   unrelated backup/export path.
4. Pass the ACM certificate ARN from `us-east-1`, an SNS topic ARN for the
   alarms, and the environment-specific hostname. Create DNS records for the
   API Gateway regional custom domain. Keep the stack's `ReceiverReady=false`.
5. Confirm the template's API Gateway best-effort throttle (2 requests/second,
   10 burst by default) and Lambda reserved concurrency limit. The app cannot
   safely carry a shared secret, so abuse protection must be at the service
   boundary; stronger controls such as AWS WAF are optional follow-on scope.
6. The hourly cleanup schedule is enabled by the template and has EventBridge
   retries. Keep the 13-day S3 lifecycle rule as a second cleanup path. AWS
   documents that lifecycle expiration can be delayed, so a synthetic-object
   deletion exercise and the failure/missed-heartbeat alarms are required
   before readiness is changed to true.
7. Disable request-body logging, tracing attachments, analytics payload
   sampling, and third-party error forwarding. Keep Lambda logs at the
   template's 7-day retention unless a shorter approved setting is selected.
8. Test staging with synthetic reports: opt-in, duplicate upload, malformed
   schema, revocation, retries, report access, and deletion.
9. Complete privacy/legal and App Store Connect review. Only then would a
   separate client change replace the production `nil` endpoint.

## Report-access workflow

The public API returns only a small acknowledgement. An authorized maintainer
would:

1. Assume an MFA-protected report-reader IAM role limited to listing the
   `diagnostics/` prefix and reading individual objects there.
2. Locate one report by idempotency key and record operator, purpose, object
   key, and timestamp in an approved access record. Never put the envelope in
   the access log.
3. Copy the object to an encrypted, access-controlled developer workspace,
   symbolicate it using the restricted release dSYM/build-UUID store, and
   delete the local copy after review.
4. Optionally enable CloudTrail S3 data events for auditability. CloudTrail
   events contain access metadata, not report bodies, and require their own
   reviewed retention policy.

There is intentionally no unauthenticated report browser or report identifier
lookup endpoint. A future web viewer would be a separate SSO/MFA, audit, and
retention project.

## Privacy and retention enforcement

Enforcement is layered:

- The client requires explicit opt-in, rotates consent/session tokens, clears
  local events and queue entries on revocation, and sends only the closed
  schema documented in `docs/privacy-preserving-crash-reporting-schema.md`.
- Lambda rejects unknown fields, unknown enum values, malformed dates and
  UUIDs, unsafe numbers, oversized bodies, invalid stack bounds, missing
  `Idempotency-Key`, and header/body ID mismatches. It never echoes or logs the
  request body.
- S3 keys contain only a validated occurrence key. No account ID, recording
  ID, CloudKit ID, path, URL, credential, transcript, audio, log text, or raw
  Apple payload is accepted by the automatic receiver.
- The S3 bucket is private, encrypted, non-versioned, and non-replicated.
  Object Lock and backups/exports are prohibited for this bucket unless
  separately reviewed.
- The cleanup Lambda deletes objects older than 13 days, and S3 lifecycle
  expiration is also set to 13 days. Noncurrent-version cleanup is included as
  a guard, but an accidentally versioned bucket remains a release blocker.
  Partial S3 deletion errors fail the cleanup invocation rather than being
  counted as successful; transient delete errors are retried. A CloudWatch
  heartbeat is emitted only after a complete cleanup run, while Lambda failure
  and missing-heartbeat alarms notify the configured SNS topic.
- Lambda logs are capped at 7 days and must not include payloads. Access and
  provider metadata are reviewed separately from report retention.
- The client retains automatic local events for at most 48 hours and queued
  reports for at most 7 days. Revocation cannot recall a report already
  received by the server.

The tested deletion mechanism is the 13-day cutoff plus scheduled cleanup,
retry/failure handling, a successful-run heartbeat, and the S3 lifecycle rule.
That exercise demonstrates that the configured mechanism deletes synthetic
objects; it is not an unconditional ongoing guarantee that every provider
operation will complete before 14 days. S3 lifecycle deletion is asynchronous,
so the ongoing 14-day target depends on monitoring, incident response, and
review of versioning, Object Lock, replication, backups, exports, logs, and
access records.

## Decision needed before production work

The requested Region and domain are now recorded as `us-east-1` and
`bisonnetworking.com`. Before deployment, the remaining account-side inputs are
an ACM certificate ARN for the two diagnostic hostnames, the DNS owner/action,
an SNS alarm topic (or approval to create and subscribe one), and any existing
IAM, CloudTrail, backup, or tagging standards. Existing policies are not
required for the local implementation: the SAM template generates separate
least-privilege Lambda roles, while CloudTrail/S3 data-event auditing remains
an explicit account decision. Until those inputs and the privacy gates are
approved, the app remains production-disabled.
