# iCloud Sync Performance Implementation Plan

## Status

Implementation plan for the `v2.4` release branch. This document is intended as a handoff to Luna or another implementation agent.

Planning baseline:

- Branch point: `v2.3` commit `db37d0360791accb5a65ef6c41e21709331a0a9c`
- Device log: `/Users/champ/Downloads/BisonNotes-Logs-2026-08-24T01-25-54.txt`
- Dataset observed: 63 recordings, 36 transcripts, and 62 summaries
- Audio backup defaults to off and must be measured separately from metadata sync

## Goal

Reduce routine metadata synchronization from minutes to seconds while preserving existing production CloudKit data and all multi-device conflict, deletion-tombstone, local-only, deduplication, relationship-repair, and recovery behavior.

## Evidence and root causes

The device log shows a full metadata backup taking about 3 minutes 14 seconds, followed by another 28-second restore enumeration. CloudKit also returned HTTP 503 throttling, `content_index` oplock conflicts, and a missing `CKAsset` source-file error.

The application currently amplifies CloudKit latency by:

- forcing full reconciliation on cold launch;
- running backup and then restore during ordinary reconciliation;
- repeatedly flushing and applying deletion state inside nested operations;
- fetching indexed records one at a time;
- saving changed records one at a time;
- rereading all records after backup only to calculate logging counts;
- processing summary batches serially with fixed per-item and inter-batch sleeps;
- allowing several CloudKit entry points to bypass the existing concurrency flags;
- rewriting one shared `content_index` record from competing operations; and
- refreshing sync metadata in a way that can make otherwise unchanged records dirty after a full backup begins.

## Safety constraints

The first implementation must not:

- change the CloudKit container, production schema, record types, deterministic record names, or default zone;
- migrate to `CKSyncEngine`, a custom zone, or persisted zone-change tokens;
- remove legacy summary records or compatibility recovery paths;
- infer user deletion merely because a local Core Data row is absent;
- change newest-content timestamp arbitration or the 60-second delete-versus-edit revival grace;
- clear a durable pending deletion before every corresponding cloud mutation succeeds;
- advance the backup signature, last-successful-sync date, or manifest after a partial failure;
- automatically invoke full repair after an incremental failure; or
- use `Task.detached`, broad `@unchecked Sendable`, `nonisolated(unsafe)`, or another Swift 6 isolation workaround.

Durable deletion intent remains the only authority for deleting cloud content. Missing local rows may result from restore, migration, repair, or partial persistence and must not be treated as implicit deletion.

## Phase 1: Testable transport, metrics, and one operation coordinator

Add focused production components under `BisonNotes AI/BisonNotes AI/Services/`:

- `CloudKitTransport.swift`
- `CloudKitBatchExecutor.swift`
- `CloudSyncOperationCoordinator.swift`
- `CloudSyncMetrics.swift`

`CloudKitTransport` should wrap account status, batched record fetches, record modification, queries/cursors, and the zone-change operations retained for explicit recovery. Production defaults should use `CKDatabase`; tests should inject a scripted transport, monotonic clock, sleeper, metrics sink, preferences store, and asset-staging helper.

Introduce explicit intents:

```swift
enum CloudSyncIntent {
    case routineSnapshot
    case deletionFlush
    case seedFromThisDevice
    case restoreToThisDevice
    case fullRepair
    case reviewScan
    case erase
}
```

Serialize all CloudKit operations through one coordinator. Requests arriving while work is running should join or coalesce and request at most one follow-up. A busy request must not return an empty result that appears successful.

Intent priority:

1. Erase, full repair, or manual restore
2. Durable deletion flush
3. Routine snapshot
4. Review scan

Every content-changing operation must preserve this phase barrier:

1. Flush durable outbound tombstones.
2. Fetch and apply inbound tombstones.
3. Fetch one cloud snapshot.
4. Resolve local and cloud winners.
5. Batch content saves and deletes.
6. Apply cloud winners locally.
7. Commit a conflict-safe manifest delta.
8. Prune deterministic duplicates where appropriate.

Record monotonic phase timing and request counts. Logs may include a run identifier, reason, intent, queue delay, item counts, batch sizes, successes, failures, retries, retry wait, deferred state, and audio byte counts. Never log names, filenames, transcript or summary text, Apple account identifiers, or other user content.

## Phase 2: Generalize batched CloudKit I/O

Generalize the existing batched-delete implementation and use it for fetches, saves, and deletes.

Initial limits:

- metadata fetch/save/delete batch size: 100;
- asset-bearing save batch size: 4;
- `atomically: false`; and
- `.ifServerRecordUnchanged` save policy.

If CloudKit returns `.limitExceeded`, recursively halve only the rejected batch. Preserve a result for every record:

- succeeded;
- missing;
- retryable or deferred; or
- permanently failed.

Retry only failed record IDs. Never resend successful records because another item failed. Treat `.unknownItem` during deletion as success.

Centralize retry behavior:

- honor `CKErrorRetryAfterKey`;
- use bounded exponential backoff with jitter only when CloudKit supplies no delay;
- retry no more than three times;
- inject the sleeper so tests do not wait; and
- when the requested delay exceeds 30 seconds, persist a next-eligible time and complete as deferred instead of leaving a foreground task asleep.

No query or fallback scan may begin during a server-requested backoff. Triggers received during backoff should coalesce without issuing more requests.

Replace normal serial collection paths in `iCloudStorageManager.swift`, including:

- `performBatchSync`
- `performIndividualSync` and `handleConflictResolution`
- `syncAllSummaries`
- the placeholder `syncSummariesInBatches`
- `fetchBackupRecordsByRecordNames`
- `saveBackupRecord`
- `deleteBackupRecords`
- `deleteExistingCloudRecords`

A single-record helper may remain for exceptional conflict fallback, but ordinary collection processing must be batched.

## Phase 3: One shared backup and reconcile snapshot

Refactor `backupAllDataToiCloud` to:

1. Load the trusted manifest once.
2. Batch-fetch all known record IDs once into a `BackupCloudSnapshot`.
3. Build recording, transcript, and summary records in memory.
4. Queue only genuinely changed records.
5. Batch-save confirmed local winners.
6. Batch-delete confirmed obsolete records.
7. Commit the manifest after data operations succeed.
8. Calculate logging counts from the snapshot and operation results.

Remove the repeated `fetchBackupRecordsByUUID` behavior that reloads every indexed collection for each requested record type. Remove the final full reread used only for logging.

`cloudHasAnyContentBackupRecord` should inspect manifest arrays and at most one known record ID rather than downloading every indexed record.

`markBackupRecordActive` must update lifecycle timestamps and device metadata only when content or lifecycle state actually changes. Merely touching a record during sync must not make it dirty.

Full reconcile should perform deletion preflight once. Private backup and restore cores should accept the preflight/snapshot rather than repeating pending-mutation flushes, marker application, manifest fetches, and record discovery.

For this release, routine sync may batch-fetch all 161 known metadata records from a trusted manifest. Two batched requests are acceptable and materially safer than introducing a new change-token or zone migration. Full query and zone fallback scans are reserved for:

- first install;
- missing or untrusted manifest;
- explicit recovery or repair; or
- schema diagnostics.

## Phase 4: Conflict-safe `content_index`

Replace whole-record read/overwrite behavior with a delta:

```swift
struct ManifestDelta {
    var addRecordings: Set<String>
    var removeRecordings: Set<String>
    var addTranscripts: Set<String>
    var removeTranscripts: Set<String>
    var addSummaries: Set<String>
    var removeSummaries: Set<String>
}
```

Data saves and deletes happen before manifest mutation. On `.serverRecordChanged`, use the returned server record, reapply the original delta, and retry. A tombstone or removal for an ID must win over adding that same ID. Unrelated changes made by another device must survive.

Never use the generic copy-every-field conflict merge for `content_index` or deletion markers. Full manifest replacement is permitted only during explicit repair or migration.

Pending deletion entries may be cleared only after:

1. the tombstone save succeeds;
2. associated content deletion succeeds or is already absent;
3. stale relationship cleanup succeeds; and
4. manifest removal succeeds.

Preserve these existing arbitration rules:

- `shouldUploadLocalVersion`
- `shouldApplyCloudVersion`
- `shouldReviveLocallyModifiedItem`
- `resolvedDeletionTimestamp`
- `latestPerRecording`
- `isBackupRecordNewer`
- `shouldRelinkRestoredRow`
- local-only recording exclusion

For content `.serverRecordChanged`, compare the original local content timestamp against the returned server record. A newer server item is a successful local skip. A newer or equal local item should copy only locally owned fields into the current server record before retry.

Deletion-marker conflicts merge using the earliest deletion timestamp.

## Phase 5: Routine lifecycle triggers

Switch automatic triggers only after the shared snapshot, batching, and manifest tests are green.

| Trigger | New behavior |
|---|---|
| Cold launch | One routine snapshot, coalesced with the immediate active event |
| App becomes active | Routine snapshot only when work is pending or the last successful check is stale |
| Local create or edit | Mark affected IDs dirty and debounce for 2-5 seconds |
| User deletion | Urgent deletion flush that bypasses normal throttling |
| Network restoration | Resume pending or deferred work |
| Periodic timer | Routine health check; never automatic full repair |
| Backup Now | Forced local-to-cloud snapshot |
| Restore From iCloud | Explicit restore followed by routine convergence |
| Database repair | Explicit full repair only |
| Review restore | Restore only the selected item |
| Legacy migration | One persisted successful compatibility scan |

The existing 15-minute no-change maintenance throttle may remain, but it must never delay queued edits or deletions. Record throttle timestamps only after successful completion.

The review flow must not perform a selected restore followed by a full restore, full backup, and another full review scan. `SummariesView` legacy discovery must be gated by a persisted successful one-time migration marker.

Keep explicit full repair available from Database Tools and retain a feature-flag fallback to the current reconcile behavior until signed two-device validation passes. Do not fall back automatically after errors or throttling.

## Phase 6: Separate audio assets

Metadata synchronization must succeed independently of audio upload.

- Exclude the audio asset field from `desiredKeys` unless audio is being restored.
- Stage each changed source file to an immutable per-run temporary URL.
- Keep staging files alive until CloudKit reports every associated result.
- Clean staging files in `defer`.
- On `.assetFileNotFound` or `.assetFileModified`, restage once if the source still exists.
- A missing source skips the asset while preserving metadata.
- An unchanged audio signature produces no upload.
- Report audio bytes, duration, and throughput separately from metadata timing.

## Automated test plan

Preserve every existing `ICloudBackupRegressionTests` test, including the imported-transcript tests added at the `v2.4` branch point.

Add:

### `CloudKitTestDoubles.swift`

- Scriptable fake transport
- Operation ledger
- Manual clock and sleeper
- Fake preferences store
- Asset-staging fake
- Metrics sink

### `CloudKitBatchExecutorTests.swift`

- 161 IDs split into 100 and 61
- Batch fetch, save, and delete
- Input deduplication
- `.limitExceeded` splitting
- Partial success
- Retry only failed IDs
- `.unknownItem` delete success

### `CloudKitRetryPolicyTests.swift`

- `retryAfter` honored
- Long delay deferred
- No calls before eligibility
- Attempt exhaustion
- Triggers coalesce during backoff

### `CloudContentIndexCoordinatorTests.swift`

- Concurrent add and remove
- Conflict rebase
- Delete wins for the same ID
- Unrelated entries retained
- At most one index write in flight

### `ICloudSyncOrchestrationTests.swift`

- Exact phase order
- Launch plus active produces one run
- Burst triggers produce at most one follow-up
- Deletion bypasses maintenance throttling
- Signature and last-success values update only after complete success
- No redundant post-write fetch
- Missing or untrusted manifest enters bootstrap/repair
- Full repair executes deletion phases exactly once

### `CloudAudioAssetPolicyTests.swift`

- Audio disabled
- Audio unchanged
- Audio changed
- Missing source
- Source removed after staging
- Asset partial failure without metadata loss

### `CloudSyncMetricsTests.swift`

- Success, failure, and deferred metrics
- Accurate phase and operation counts
- No user-content leakage

Extend `ICloudBackupRegressionTests.swift` with:

- pending tombstones surviving partial batch failure;
- queue removal only after the complete tombstone sequence succeeds;
- newest-wins and revival-grace parity through batched execution;
- local-only exclusion;
- deterministic deduplication; and
- relationship repair after restore.

The application and test groups are filesystem-synchronized. New files should not require manual `project.pbxproj` edits, but target membership must be verified by Xcode builds.

## Validation commands

Focused iOS tests:

```bash
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-icloud-perf-derived \
  -only-testing:"BisonNotes AITests/ICloudBackupRegressionTests" \
  -only-testing:"BisonNotes AITests/CloudKitBatchExecutorTests" \
  -only-testing:"BisonNotes AITests/CloudKitRetryPolicyTests" \
  -only-testing:"BisonNotes AITests/CloudContentIndexCoordinatorTests" \
  -only-testing:"BisonNotes AITests/ICloudSyncOrchestrationTests" \
  -only-testing:"BisonNotes AITests/CloudAudioAssetPolicyTests" \
  -only-testing:"BisonNotes AITests/CloudSyncMetricsTests"
```

Full iOS scheme:

```bash
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-full-test-derived
```

Native macOS build:

```bash
xcodebuild \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI macOS" \
  -destination 'platform=macOS' \
  -configuration Debug \
  -derivedDataPath /private/tmp/bisonnotes-native-mac-derived \
  build
```

Also run:

- `git diff --check`
- baseline-aware SwiftLint
- static searches confirming there are no fixed metadata sleeps or per-record CloudKit calls inside normal collection loops
- final branch, HEAD, status, and scoped diff review

## Performance acceptance gates

With audio disabled and 63 recordings, 36 transcripts, and 62 summaries:

- Full metadata seed: at most two content modify batches plus manifest/settings; median at most 30 seconds and ordinary maximum at most 60 seconds.
- Clean-device known-ID restore: at most two content fetch batches; median at most 30 seconds and ordinary maximum at most 60 seconds.
- No-change activation: zero content writes or deletes, at most two content fetch batches, median at most 5 seconds, and p95 at most 10 seconds.
- One changed recording/transcript/summary set: source upload completes within 15 seconds including debounce, with no unrelated records written.
- Cold launch: exactly one routine run despite launch and active notifications.
- Production test matrix: zero `content_index` oplock failures.
- CloudKit-requested throttling: clean deferred result and no requests before `retryAfter`; throttled runs are reported separately from ordinary latency.
- Audio: separately reported duration, byte count, and throughput.

## Physical two-device production matrix

Use matching TestFlight builds, the same Apple ID, and a dedicated QA dataset rather than the user's live data.

Test:

1. Device A seeds the 161-record dataset; clean Device B restores exact counts.
2. Repeated no-change foregrounding on both devices.
3. A creates or edits recording metadata, a transcript, and a summary; B converges.
4. An older edit synchronized last cannot overwrite a newer edit.
5. Offline recording, transcript, and summary deletions propagate without resurrection.
6. An edit more than 60 seconds after deletion revives consistently.
7. Keep on This Device content never appears on B; re-enabling sync uploads it.
8. Concurrent unrelated add/delete operations preserve both outcomes and manifest entries.
9. Rapid launch, background, and foreground transitions produce no overlap.
10. Audio off, unchanged audio, changed audio, and missing-source audio.
11. Relaunch both devices and repeat no-change sync to prove stable convergence.

Mocks and simulator tests cannot prove production schema deployment, signing and entitlements, Apple-account behavior, real throttling, `CKAsset` lifetime, background suspension, or cross-device propagation. A signed development build still uses the development CloudKit environment. Production validation requires matching TestFlight or App Store builds.

## Implementation handoff requirements

At completion, report:

- exact starting and final branch/HEAD;
- files changed;
- operation-count and timing changes;
- focused and full test results;
- iOS and macOS build results;
- SwiftLint baseline status;
- manual production QA still pending; and
- final dirty status.

Do not commit, push, or open a pull request without separate authorization.
