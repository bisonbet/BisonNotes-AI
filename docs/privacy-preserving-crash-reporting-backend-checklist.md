# Privacy-preserving crash reporting backend checklist

This checklist is a deployment gate, not evidence that a production receiver exists. The app currently has no production endpoint configured.

The current implementation candidate is documented in
`docs/privacy-preserving-crash-reporting-production-proposal.md`,
`docs/privacy-preserving-crash-reporting-aws-deployment.md`, and
`backend/privacy-preserving-diagnostics/`. It uses API Gateway HTTP API,
Lambda, and private S3 storage for review only. The client remains production-
disabled.

## Receiver and schema

- [ ] Use a dedicated HTTPS endpoint with a documented hostname and certificate lifecycle.
- [ ] Validate schemaVersion, exact field names, enum values, UUID/date formats, finite numeric ranges, stack bounds, and the 128 KiB body limit.
- [ ] Reject unknown fields and reject malformed or pre-consent data rather than attempting recovery from free-form text.
- [ ] Require the Idempotency-Key header to equal the JSON idempotencyKey.
- [ ] Return only the documented acknowledgement shape: accepted true and the same eventID.
- [ ] Make accepted duplicate submissions idempotent without merging distinct incident occurrences.
- [ ] Do not embed an ingestion secret in the app and do not accept AI-provider credentials or user authentication tokens.

## Transport and abuse controls

- [ ] Enforce request size, connection, parsing, and response timeouts at every proxy and service layer.
- [ ] Define the API Gateway route/stage rate and burst limits in deployment configuration; confirm they are best-effort guardrails, not a billing cap.
- [ ] Keep the receiver readiness gate disabled until cleanup and privacy checks pass.
- [ ] Rate-limit by an abuse-resistant policy that does not require retaining unnecessary client identifiers.
- [ ] Disable request-body logging, payload sampling, analytics, tracing attachments, and automatic forwarding to third-party error trackers.
- [ ] Reject redirects or ensure every proxy hop remains within the approved service boundary.
- [ ] Restrict operator access, encrypt in transit and at rest, and record access without copying payload content.
- [ ] Define behavior for 4xx validation failures, 408, 429, 5xx, timeouts, malformed acknowledgements, and duplicate acknowledgements.

## Retention and deletion

- [ ] Configure the 13-day scheduled cleanup cutoff and the S3 lifecycle rule in every environment.
- [ ] Monitor both cleanup failures and missing successful-run heartbeats; do not treat an alarm-free deployment as proof of an unconditional 14-day guarantee.
- [ ] Verify the same deletion policy for databases, object storage, caches, queues, backups, replicas, indexes, exports, dead-letter stores, and observability systems.
- [ ] Prohibit indefinite quarantine or manual exports unless separately approved, access-controlled, and covered by a documented retention exception.
- [ ] Exercise deletion with a synthetic envelope and retain evidence that all copies and indexes expire.
- [ ] Test partial S3 delete responses: retry transient per-object errors, fail persistent errors, and publish a heartbeat only after a complete run.
- [ ] Keep release dSYMs and build UUID mappings in restricted developer infrastructure separate from diagnostic payload storage; do not place them in the client or receiver response.

## Privacy and product gates

- [ ] Review the actual server identifiers and linkage before claiming that diagnostics are not linked to a person.
- [ ] Publish the opt-in explanation, recipient, purpose, collected fields, retention, and revocation behavior.
- [ ] Review App Store Connect categories for Crash Data, Performance Data, Other Diagnostic Data, and any Identifiers disclosure.
- [ ] Review privacy-manifest obligations separately; a manifest does not replace policy or App Store answers.
- [ ] Confirm that revocation removes local events, queues, and telemetry tokens and that the server policy explains already-received reports.
- [ ] Confirm detailed manual export disclosure appears on iOS, native macOS, the unexpected-shutdown alert, and every existing export entry point.

## Controlled rollout

- [ ] Inject a local test receiver in debug/tests only; verify it cannot contact production.
- [ ] Verify an opt-in synthetic report, request body, acknowledgement, retry, duplicate submission, and expiry.
- [ ] Verify disabled, pre-consent, revoked, corrupt-storage, oversized, old-build, and ambiguous-context cases.
- [ ] Verify a known fixture can be symbolicated using the restricted dSYM mapping.
- [ ] Run signed iOS and native macOS builds on controlled hardware and retain evidence for delivery timing, consent enforcement, symbolication, and deletion.
- [ ] Configure the production endpoint only after all preceding checks and disclosure approvals are recorded. No production completion claim is valid before that point.
