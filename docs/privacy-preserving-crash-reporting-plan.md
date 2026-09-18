# Agent implementation brief: privacy-preserving crash reporting

## Objective and scope

Implement optional automatic technical crash reporting for BisonNotes AI, with a small, typed local event buffer and an independent upload path. Preserve detailed diagnostic export as an explicit user action with a clear disclosure and confirmation. Never automatically upload the existing diagnostic export, OSLog output, error buffer, recovery inventory, or raw Apple payload.

This document is a plan, not authorization to provision infrastructure, publish privacy disclosures, deploy, commit, or push. Implement and validate the client and a reviewable ingestion contract first. Production activation requires an identified backend, verified retention/security configuration, and published disclosures. If the backend remains undecided, deliver a working client against a local test receiver with production upload disabled; clearly report that end-to-end production reporting is incomplete.

## Verified starting point

Inspected September 18, 2026: branch `v3.0`, HEAD `c44d1585f9b8e0241bd62c7e8b9be7f45e15ac42`, initially clean worktree. Recheck branch, HEAD, status, repository instructions, and ownership before editing; do not reset or absorb unrelated work.

Paths below are relative to the repository root:

- `BisonNotes AI/BisonNotes AI/AppDelegate.swift`: `AppDelegateCore` subscribes to MetricKit and stores the last five raw diagnostic payloads in `metrickit_diagnostics.json`. The inspected callback has no upload path.
- `BisonNotes AI/BisonNotes AI/LogExporter.swift`: combines current OSLog, persistent breadcrumbs/errors, raw MetricKit diagnostics, and recording recovery inventory into a user-shared file. Its header says “Previous session crashed.”
- `BisonNotes AI/BisonNotes AI/EnhancedLoggingSystem.swift`: owns `previousSessionCrashed` and launch/clean markers. Existing breadcrumbs contain free-form text and session IDs; they are not suitable as the automatic buffer.
- `BisonNotes AI/BisonNotes AI/BisonNotesAIApp.swift`: updates markers during lifecycle transitions. Background/inactive transitions can be recorded as clean; this cannot establish whether a later termination was a crash.
- `BisonNotes AI/BisonNotes AI/ContentView.swift`: presents an unexpected-shutdown alert and a manual report action.
- `BisonNotes AI/BisonNotes AI/Views/SettingsView.swift` and `Views/MacSettingsAdvancedView.swift`: contain manual export entry points.
- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift`: consumes the existing marker for job recovery. Preserve recovery behavior while correcting diagnostic terminology.

The installed Xcode 27.0 SDK declares `DiagnosticReport` available on iOS/macOS/Mac Catalyst 27.0+, with watchOS unavailable. The legacy `MXDiagnosticPayload` header recommends `DiagnosticReport` using `API_TO_BE_DEPRECATED`; do not infer that legacy support can be removed. Verify the implementation toolchain and every supported deployment target before choosing availability guards.

## 1. Establish the data contract before instrumentation

Create a versioned, strongly typed `CrashEnvelope` and typed `DiagnosticEvent`. Use explicit field projection, enum values, finite numeric ranges, and strict size limits. Do not accept arbitrary dictionaries, interpolated strings, `Error.localizedDescription`, or generic metadata bags. Unknown Apple fields must be discarded. The backend must independently validate the same schema.

Allowed fields:

| Area | Allowed representation |
| --- | --- |
| Version | Schema version; affected app version/build; OS version; platform; hardware model identifier, never device name |
| Identity | Fresh telemetry-only random event/session tokens; optionally a rotating installation token if there is a demonstrated need |
| Operation | Fixed enum such as `icloud_sync`, `recording_finalize`, `live_transcription`, `idle`, `unknown`; phase/result enums |
| State | Separate foreground/background/inactive state and recording/syncing flags, since these can overlap |
| Measurements | Bucketed operation counts, duration and memory-pressure categories, thermal-state enum; explicit unavailable/unknown values |
| Failure | Report kind; bounded numeric exception/signal codes; reviewed termination categories; projected technical stack frames |
| Provenance | Apple-reported incident time/range versus receipt time; context association status; affected build separate from receiving build |

Prohibited: audio, transcripts, summaries, titles/recording names, prompts, CloudKit IDs, existing recording/job/session UUIDs, file paths, URLs, API responses, credentials, user settings, arbitrary exception text, raw process environment, or the existing diagnostic log. Do not hash content identifiers as a workaround. Coarse counts should concern operations, not inventory of the user's recordings or documents.

Resolve the UUID distinction explicitly: build binary UUIDs and image-relative frame offsets may be retained for symbolication because they identify shipped executable builds, not user content. Permit only reviewed app/framework image identities, never arbitrary image paths. Fresh telemetry tokens must not reuse `AppLog.sessionId`, IDFV, account IDs, CloudKit IDs, or content IDs. Avoid an installation token unless session/event tokens are insufficient. If used, rotate at least every seven days and on consent revocation; never maintain a mapping between generations. Describe these as pseudonymous, not guaranteed anonymous.

## 2. Separate the automatic pipeline from detailed logging

Suggested components under `Services/Diagnostics/`, adapted to repository conventions:

1. `DiagnosticConsentStore`: local, versioned consent and effective collection state.
2. `DiagnosticEventStore`: bounded, serialized event storage with atomic persistence.
3. `MetricKitDiagnosticAdapter`: legacy and modern adapters producing the same normalized model.
4. `CrashEnvelopeBuilder`: strict allowlist projection and context association.
5. `DiagnosticUploadQueue` / `DiagnosticUploader`: bounded persistence, retry and transport.

Neither envelope construction nor upload may call `LogExporter`, read the existing diagnostic log files, or enumerate recordings. Keep raw local Apple diagnostics available only to the manual support path, with explicit age and byte limits; their existing five-payload limit is insufficient by itself. Raw payload retention must not depend on upload success.

Suggested initial limits, implemented as policy constants with tests: 64 structured events / 32 KiB total, 48-hour event retention, 128 KiB maximum envelope, 20 queued envelopes / 2 MiB total, seven-day queue expiry, and 14-day server retention. Cap raw manual-only Apple diagnostics at five payloads / 1 MiB / seven days. Expire by age as well as size; discard oldest entries first. Make any revised limits explicit in the handoff.

Persist off the main actor and away from audio callbacks. Record operation transitions at coordinator boundaries, never each audio buffer or transcript update. Use a serialized store, atomic writes, platform-appropriate file protection, and backup exclusion. Handle corrupt, missing, inaccessible, and partially written storage by dropping telemetry safely. Never upload or perform unsafe work from a signal handler. Some final events may be lost on termination; accept and document that limit.

## 3. Integrate Apple reports without inventing context

Use an availability-gated modern adapter where supported and the existing subscriber path for older supported OS versions. Ensure exactly one active collection path per runtime, or deduplicate if both are unavoidable. Handle callback concurrency and Swift 6 isolation explicitly; convert framework objects into safe immutable values before crossing actors.

Do not promise immediate or next-launch delivery. Reports may be delayed, duplicated, absent, or describe an older app version. Never attach the current operation, current build, or latest previous-session buffer merely because it exists when a payload arrives. Associate context only when time/build/session evidence is sufficient. If matching is ambiguous or context has expired, send a technical report with `contextAssociation = unknown` and omit unrelated breadcrumbs. Do not upload old pre-consent reports, including reports whose entire relevant collection interval cannot be shown to fall after consent.

Maintain an event ID across retries and enforce server idempotency. Deduplicate repeated Apple deliveries using a bounded local fingerprint over approved technical fields, without merging distinct occurrences that share a stack signature. Grouping a crash signature and identifying a report occurrence are separate concerns.

Preserve stack usefulness: retain only symbolication-required fields from the reviewed call-stack structure, cap frames/threads, and record truncation. Retain matching release dSYMs and build UUIDs in restricted developer infrastructure. Validate with a known fixture that the projected report can still be symbolicated; an envelope of only version/state metadata is not sufficient crash reporting.

## 4. Correct lifecycle semantics without changing recovery policy

Use “previous session ended unexpectedly” for the heuristic and “Apple-reported crash” only when backed by a crash diagnostic. Distinguish crash, hang, resource diagnostic, and unconfirmed unexpected termination in the model and backend.

Rename the marker and its call sites, or provide a temporary compatibility accessor where necessary, with call-site verification across background processing and tests. Preserve persisted-key compatibility and first-launch behavior. Do not change background-job recovery policy as an incidental consequence of a rename.

Document that normal background termination, force-quit, jetsam, and missing lifecycle callbacks make this heuristic incomplete. A background transition is not proof of a clean process exit. Do not count marker-only reports as confirmed crashes or calculate a crash-free-session rate from crash-only submissions. If the heuristic is uploaded, use a separate event kind and bounded frequency.

## 5. Consent and manual sharing

Choose explicit opt-in as the initial product policy: “Automatically send technical crash reports,” disabled on new installs and upgrades until accepted. Explain the fields collected, recipient, purpose, retention, and how to disable collection. Automatic upload needs no per-report confirmation after consent. Store this preference locally rather than in CloudKit.

Gate creation of the automatic event buffer and queue as well as transmission. On disable, stop collection, cancel scheduled/in-flight work where possible, and delete local automatic events, queued envelopes and tokens. Synchronize revocation with enqueue/send operations. Explain that already-received reports cannot be recalled by cancelling a request and expire under server policy. Re-enabling starts a new consent epoch and identity; never backfill pre-consent history.

Keep “Share diagnostic report” separate on iOS and macOS. Before generating/sharing the detailed export, disclose that it can contain recording identifiers, file information and technical logs; allow cancellation and preview where practical. Require an explicit share/send action each time. Audit every existing export entry point, including the unexpected-shutdown alert, so none bypasses this explanation. Avoid reassuring users that a detailed report contains no sensitive data. Preserve existing recovery tools and sharing behavior.

## 6. Delivery and backend contract

Define a minimal HTTPS ingestion endpoint with strict schema/body limits, rate limiting, idempotency, encrypted storage, restricted operator access, and a tested deletion mechanism using a conservative cutoff before the 14-day target. Monitor failed and missed cleanup runs; a deletion exercise demonstrates the configured mechanism but is not an unconditional ongoing guarantee because provider deletion can be asynchronous. Disable request-body logging, unnecessary IP/access-log retention, payload forwarding and third-party analytics. Audit proxies, error trackers, backups and dead-letter queues too; database TTL alone does not establish retention across the system. Do not embed a privileged ingestion secret in the app or reuse the user's AI-provider credentials.

Use bounded timeouts, exponential backoff with jitter, `Retry-After` handling and an expiry limit. Retry transient network/429/5xx failures; discard or quarantine within the same limits permanently invalid reports. Treat only the documented successful acknowledgement as accepted. Use an ephemeral session without cookies or credential reuse; reject redirects outside the approved endpoint. Never fall back to insecure transport or log request bodies on failures.

Send on eligible launches/foreground opportunities and available execution time, without inventing a background mode or delaying launch, recording or recovery. Offline reports remain bounded and eventually expire. Lack of consent, absent endpoint configuration, or validation failure must result in no upload. Ensure debug/tests never contact production.

Prepare privacy-policy and App Store Connect disclosure changes for the actual implementation. Apple's categories include Crash Data, Performance Data and Other Diagnostic Data; review whether token use also requires an Identifiers disclosure. Opt-in alone does not exempt ongoing collection from disclosure. Do not claim “not linked to you” without examining server identifiers and linkage. Audit privacy-manifest requirements separately; a manifest does not replace the privacy policy or App Store privacy answers.

## 7. Verification and delivery gates

- Privacy: sentinel-filled fixtures containing titles, UUIDs, paths, URLs, transcripts, secrets, nested unknown fields and free-form Apple text must not survive projection into serialized envelopes or captured requests. Verify the approved build UUID exception and frame offsets survive.
- Consent: fresh install, upgrade, enable, disable, revoke during enqueue/retry/send, re-enable and pre-consent delayed payloads. Assert zero requests while disabled and no stale queue revival.
- Storage: event/byte caps, expiry, corruption, interrupted writes, unavailable protection keys, concurrent access and relaunch. Telemetry failure must not interrupt recording or startup.
- Reports: both API adapters, duplicate deliveries, same signature across separate incidents, old build reports, missing context, ambiguous time ranges and multiple sessions. Assert no current-session misattribution.
- Transport: offline/relaunch, timeouts, 429/5xx, permanent 4xx, redirect rejection, size rejection and duplicate acknowledgements, using a controlled receiver.
- Lifecycle/recovery: first launch, foreground/background transitions, force-quit and marker migration. Run relevant background recovery tests and preserve existing behavior.
- UI: opt-in and manual-share cancellation/disclosure on native macOS and iOS; verify no automatic detailed-log export.
- Build/test: follow `docs/testing-regimen.md`; run focused unit tests and native macOS/iOS builds, relevant lint, and `git diff --check`. Report actual lint counts and baseline limitations. Inspect modified code for unused declarations, duplicate helpers, placeholders and secrets.
- Signed-device proof: use a controlled test build with synthetic data to exercise a known failure and eventual report delivery. Verify the received payload, matching dSYM symbolication, consent enforcement and the tested deletion mechanism, including cleanup monitoring. Treat the 14-day wording as an ongoing operational target subject to provider behavior, not as proven by one deletion exercise. Simulator fixtures and Xcode diagnostic injection do not prove real-world delivery timing or coverage. Retain hardware gates if delivery has not occurred.

Deliver code, schema and sanitized example envelopes, tests, retention policy, disclosure drafts, backend deployment/configuration checklist, and a concise handoff listing exact source/build/test/hardware evidence. Do not present production reporting as complete until a real configured receiver, privacy disclosures, symbolication and retention have been verified. Commit/push/deploy only when separately requested.

## Reference sources

- [Apple: MXDiagnosticPayload](https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload)
- [Apple: DiagnosticReport](https://developer.apple.com/documentation/metrickit/diagnosticreport)
- [Apple: App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/) — diagnostic categories and ongoing collection disclosure.
- Availability/deprecation details above were verified against the installed Xcode 27.0 iPhoneOS SDK headers and Swift interface; recheck on the implementing agent's toolchain.
