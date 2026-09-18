# AWS deployment and operations draft

Status: review-only. Do not run deployment commands, set `ReceiverReady=true`,
or configure the client production endpoint until the account, region,
retention, privacy, and disclosure gates are approved. The intended Region is
`us-east-1` and the proposed hostnames are
`staging.diagnostics.bisonnetworking.com` and
`diagnostics.bisonnetworking.com` under `bisonnetworking.com`.

## Account and region requirements

Confirm:

- AWS account/organization owner and billing contact;
- target AWS Region and any data-residency requirement (the current target is
  `us-east-1`);
- ACM certificate in `us-east-1` covering the approved environment hostnames;
- Route 53 or external DNS ownership for the API Gateway regional custom
  domain;
- SNS topic ARN and subscribers for cleanup alarms;
- whether existing AWS CloudTrail, security, tagging, backup, or incident
  response standards apply;
- who may read reports and who may deploy infrastructure.

Keep AWS credentials, account IDs, API IDs, bucket names, and final hostnames
outside the repository. Use separate least-privilege deployment and report-
reader roles with MFA. The app must not contain an AWS credential, API key, or
user token.

### Read-only account discovery

Existing IAM and CloudTrail configuration is not required for the local
implementation. Before a real deployment, an AWS administrator can run these
read-only checks with the intended profile and `us-east-1` region; do not save
the output in the repository:

```sh
aws sts get-caller-identity --region us-east-1
aws iam get-account-summary --region us-east-1
aws cloudtrail describe-trails --region us-east-1 --include-shadow-trails
aws sns list-topics --region us-east-1
aws acm list-certificates --region us-east-1
```

The first command confirms the account. The CloudTrail result shows whether a
trail exists; it is not required for ingestion, but S3 data events are the
recommended way to audit report-object access if the account's policy permits
them. The SNS result identifies a topic that can notify the cleanup alarms. The
SAM template creates separate Lambda execution roles with only their required
S3/CloudWatch actions; the deployment identity still needs the organization's
approved CloudFormation/SAM permissions.

## Review-only deployment sequence

1. Select the account and Region, then inspect the SAM template with
   `sam validate` and `sam build` locally. Supply the staging certificate ARN,
   alarm topic ARN, and `EnvironmentName=staging`; the template creates an
   environment-specific bucket.
2. Deploy only to a staging stack using
   `staging.diagnostics.bisonnetworking.com`. Keep `ReceiverReady=false`.
   Confirm the API Gateway 2 requests/second steady-state and 10-request burst
   defaults (or an explicitly reviewed override) and the Lambda reserved
   concurrency before sending any app request.

Use these environment-specific values when preparing the stack parameters:

| Environment | `EnvironmentName` | `DiagnosticDomainName` | `ReceiverReady` |
| --- | --- | --- | --- |
| staging | `staging` | `staging.diagnostics.bisonnetworking.com` | `false` |
| production | `production` | `diagnostics.bisonnetworking.com` | `false` |

The certificate ARN, alarm topic ARN, and account/region remain deployment
inputs. The two environment values produce distinct bucket names in the same
AWS account and Region.

3. Confirm the S3 bucket has Block Public Access enabled, Bucket Owner Enforced
   ownership, default SSE-S3 encryption, no versioning, no Object Lock, no
   replication, and no unrelated backup/export path.
4. Confirm the bucket lifecycle rule and the enabled hourly cleanup schedule.
   EventBridge retries a failed invocation up to the configured limit; the
   cleanup Lambda's `Errors` alarm covers failed runs, and the
   `CleanupHeartbeat` alarm treats two hours without a successful heartbeat as
   a missed run. Run the cleanup against synthetic objects, including a
   partial S3 delete failure, before changing readiness.
5. Keep API Gateway access logging, Lambda logs, tracing, request sampling, and
   analytics free of request bodies. The template retains Lambda logs for 7
   days; log only status/count metadata if additional operational logging is
   approved.
6. Test opt-in, duplicate upload, malformed schema, revoked consent, transient
   retry, report access, and deletion. Do not use real recordings or
   transcripts for staging.
7. Confirm the successful cleanup heartbeat and both alarm paths, then change
   `ReceiverReady` only for the reviewed staging stack. Do not use this step to
   enable production uploads.
8. Complete privacy/legal and App Store Connect review. Only after approval
   would a separate client change replace the production `nil` endpoint and a
   separately approved production stack use `EnvironmentName=production`.

API Gateway route/stage throttling and the Lambda reserved-concurrency limit
provide a small global abuse/budget guard without retaining a client identity.
If stronger per-source abuse controls are required, AWS WAF or a separate
front-door design should be reviewed as an additional cost and scope item.

## Report-access workflow

The public API never returns a report body and has no read route. An authorized
maintainer would:

1. Use an MFA-protected report-reader role limited to `s3:ListBucket` for the
   `diagnostics/` prefix and `s3:GetObject` for that prefix.
2. Locate one object by its idempotency key and record operator, purpose,
   object key, and timestamp in the approved access record. Do not put the
   envelope in an access log.
3. Copy the object to an encrypted, access-controlled developer workspace,
   symbolicate it against the restricted release dSYM/build-UUID store, and
   delete the local copy after review.
4. Optionally enable CloudTrail S3 data events for this bucket to audit object
   access. CloudTrail records must not contain report bodies and need their own
   reviewed metadata-retention policy.

The ingest Lambda has no `GetObject`, `ListBucket`, or `DeleteObject`
permission. The cleanup Lambda has no `GetObject` permission. Release dSYMs
never enter the client, Lambda response, or S3 report bucket.

## Privacy and retention controls

- The client remains explicit opt-in and sends only the closed schema.
- Lambda rejects unknown fields, malformed values, unsafe numbers, oversized
  bodies, invalid stack bounds, and mismatched idempotency headers.
- S3 keys contain only the validated occurrence ID. No account ID, recording
  ID, CloudKit ID, path, URL, credential, transcript, audio, log text, or raw
  Apple payload is accepted by the automatic receiver.
- S3 is private, encrypted, non-versioned, and non-replicated. Object Lock and
  backups/exports are prohibited for this bucket unless separately reviewed.
- The hourly cleanup Lambda deletes objects older than 13 days. It treats
  per-object S3 delete errors as failures, retries transient errors, and emits
  a CloudWatch heartbeat only after the full run succeeds. S3 lifecycle
  expiration is also set to 13 days. Noncurrent-version cleanup is included as
  a guard, but versioning must remain off; an accidental versioned bucket is a
  release blocker.
- Lambda logs are capped at 7 days and must not include request bodies. Any
  CloudTrail or access metadata is reviewed separately and is not described as
  part of the report payload retention.
- Local client events remain bounded to 48 hours and queued reports to 7 days.
  Revocation clears local material but cannot recall a report already received.

The tested deletion mechanism is the 13-day cutoff, scheduled cleanup, retry
and failure handling, successful-run heartbeat, and S3 lifecycle rule. This
test demonstrates the configured mechanism on synthetic objects; it does not
create an unconditional ongoing guarantee that every provider deletion will
complete before 14 days. AWS documents that lifecycle expiration can be
delayed, so the ongoing 14-day target requires the alarms, incident response,
and review of all copies and metadata stores. No production disclosure should
claim an unconditional 14-day maximum before those checks pass.
