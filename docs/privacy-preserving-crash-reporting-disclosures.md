# Privacy-preserving crash reporting disclosure drafts

These are drafts for product, privacy, and App Store Connect review. They are
not published policy text. The proposed recipient below is a review placeholder
based on the un-deployed AWS API Gateway + Lambda + S3 design; replace it if existing
approved infrastructure is selected and publish nothing until privacy/legal
review is complete.

## Proposed recipient wording for review

**Proposed recipient:** a dedicated BisonNotes diagnostic receiver hosted on
Amazon API Gateway, AWS Lambda, and a private Amazon S3 bucket. The receiver
would accept only the allowlisted technical envelope over HTTPS. Authorized
BisonNotes maintainers, rather than the public app endpoint, would access
individual reports for debugging using restricted IAM credentials. The
proposed S3 lifecycle and scheduled cleanup controls are designed and will be
tested to delete automatic reports before 14 days. The service uses a 13-day
cutoff, scheduled cleanup, retry/failure handling, and alarms for failed or
missed cleanup runs. Because provider deletion can be asynchronous, this is an
ongoing operational target subject to monitoring and incident response, not an
unconditional guarantee; provider operational metadata and access records are
reviewed separately.

The review configuration targets AWS `us-east-1` with environment hostnames
under `bisonnetworking.com`; the final legal entity, exact hostname, and any
provider operational metadata must be confirmed before publication.

The final disclosure must identify the actual legal entity, hostname, AWS
Region/jurisdiction, operational metadata, and verified retention wording. If
Tim has a different approved AWS account, UMBC service, or data-residency
requirement, use that reviewed recipient instead.

## Settings opt-in draft

**Automatically send technical crash reports**

If you turn this on, BisonNotes AI may send small technical reports to help diagnose crashes, hangs, and resource failures. Reports include the app version and build, operating-system version, platform, device model identifier, broad app state such as foreground/background and recording/syncing status, bucketed technical measurements, bounded numeric failure codes, and selected symbolication fields from the app or reviewed system frameworks.

Reports do not include audio, transcripts, summaries, recording titles or names, prompts, file paths, URLs, CloudKit or recording identifiers, credentials, settings, diagnostic log text, or raw Apple diagnostic payloads. Reports use fresh pseudonymous technical tokens; they are not your account, recording, or existing application session identifiers.

The recipient, purpose, storage jurisdiction, retention period, and any
server-side identifiers must be named here before release. The current client
keeps automatic local events for up to 48 hours and queued reports for up to 7
days. The proposed server deletion mechanism is tested with an S3 lifecycle
rule and scheduled cleanup using a 13-day cutoff, with alarms for failed and
missed cleanup runs. This supports an ongoing target of deleting reports
before 14 days, but it is not an unconditional guarantee because provider
deletion can be asynchronous. Turning
this setting off deletes automatic local events, queued reports, and local
technical tokens; it cannot recall a report already received by the server.
Hosting-provider operational metadata and access records are subject to their
own reviewed retention terms and must be described before publication.

## Manual detailed export draft

**Share diagnostic report**

This is a separate, user-initiated export. It may contain recording identifiers, file information, technical logs, recovery information, and raw Apple diagnostic details. Review the file and choose whether to share it. Canceling stops the share; no detailed report is sent automatically from this action.

This disclosure must appear before the detailed export is generated or shared from Settings, the unexpected-session alert, native macOS diagnostics, and any other existing manual export entry point.

## App Store Connect review checklist

- [ ] Classify actual ongoing collection using Apple's Crash Data, Performance Data, and Other Diagnostic Data categories.
- [ ] Review whether the fresh pseudonymous tokens, server access logs, or any linkage make an Identifiers disclosure necessary.
- [ ] State the actual recipient and purpose; opt-in does not remove the need for ongoing collection disclosure.
- [ ] Do not claim "not linked to you" until the server, proxies, access logs, support workflow, and retention configuration have been reviewed.
- [ ] Review privacy-manifest requirements independently of App Store privacy answers and this user-facing explanation.
- [ ] Obtain privacy/legal approval and publish the final policy before enabling a production endpoint.
