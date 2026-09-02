# For v2.5

Work deliberately deferred out of v2.4 (PR #124). Each item says what the defect
is, why it was not fixed at the time, and what the change actually involves.

Ordered by value, not by effort.

| # | Item | Why it waited |
| --- | --- | --- |
| 1 | Atomic deletion outbox | Schema change; the bug it fixes is a narrow crash window |
| 2 | Reserve the CloudKit asset cache during a sync | Needs a reservation primitive the sync coordinator does not have |
| 3 | Retry audio a restore could not copy | Needs verification before it is worth building |
| 4 | Staging budget cannot help a recording bigger than the disk | Rare, and the current behaviour is safe |
| 5 | `iCloudStorageManager` size | Pure refactor; no defect |
| 6 | Textual fork rebase | Separate repository |

---

## 1. Atomic deletion outbox

**Status:** planned, not started. Raised by Codex on PR #124 against
`RecordingWorkflowManager.swift:339`; declined there and left open on the thread.

### The defect

A local deletion commits to Core Data, and the tombstone that tells iCloud about
it is written afterwards, to a separate UserDefaults-backed queue. The two writes
are not atomic. If the process dies between them, the row is durably gone locally
and no removal intent exists, so nothing will ever tell the cloud.

Two places do this, and they are not equally serious:

- **`RecordingWorkflowManager.createSummary`** (`Models/RecordingWorkflowManager.swift`,
  around the `context.save()` that removes superseded summaries) — the reported
  case. **Self-correcting.** The lost tombstone is always for a summary that a
  newer one supersedes, and cloud dedupe is derived from record timestamps rather
  than tombstones: `resolveLatestRecordsPerRecording` picks the newest summary per
  recording, and the next backup deletes the losers and drops them from the
  manifest. The stale cloud row is pruned on the next pass regardless. Worst case
  is a transient duplicate.

- **`CoreDataManager.deleteRecording` → `save(committing:)`**
  (`Models/CoreDataManager.swift:1286`) — same pattern, **not self-correcting.**
  The recording is gone locally, the cloud copy survives with no tombstone, and
  the restore leg discovers it as a cloud-only record and pulls it back. A deleted
  recording reappears. This is the resurrection class the project has already
  fixed twice by other means (`b2f81c0c`, `09f16823`) and is the actual reason to
  do this work.

The window is microseconds wide and needs a crash landing inside it. That is why
it did not block the v2.4 release, not because it is imaginary.

### Why the obvious fix is wrong

Codex proposed enqueueing the intents before the save and withdrawing them on
rollback. Do not do this. The current ordering is deliberate (`ac232863`), and the
comment above the loop says why: a tombstone and an attachment-folder delete are
both one-way, so raising them before a save that then fails deletes the user's
cloud copy — and their notes — for a summary still on the device. "Withdraw on
rollback" has the same hole: a crash between enqueue and withdraw produces the
unrecoverable outcome rather than the recoverable one.

The ordering is not the problem. The lack of atomicity is.

### The design

Move the pending-mutation queues from UserDefaults into Core Data, and write the
intent in the **same `context.save()`** as the deletion that motivates it. One
transaction commits both or neither, and the ordering question disappears.

Today there are five queues, all `Codable` arrays behind computed properties in
`iCloudStorageManager.swift`:

| Key | Type |
| --- | --- |
| `iCloudPendingDeletionMarkersV1` | `PendingCloudDeletionMarker` |
| `iCloudPendingLocalOnlyRemovalsV1` | `PendingLocalOnlyCloudRemoval` |
| `iCloudPendingSummaryRemovalsV1` | `PendingSummaryCloudRemoval` |
| `iCloudPendingTranscriptRemovalsV1` | `PendingTranscriptCloudRemoval` |
| `iCloudPendingImportedAudioRemovalsV1` | `PendingImportedAudioRemoval` |

Proposed shape:

1. **One `PendingCloudMutation` entity** rather than five, with `kind` (a string
   discriminator matching the five cases), `targetId`, `recordingId`,
   `requestedAt`, and a small `payload` for the fields only one kind needs.
   `requestedAt` must keep its current meaning exactly — it is when the *user*
   deleted, not when the row was written, and the earliest claim wins. That rule
   is load-bearing for multi-device arbitration and is covered by
   `ICloudBackupRegressionTests`.

2. **Keep the five accessors' signatures.** `enqueueSummaryRemovalFromiCloud`,
   `enqueueTranscriptRemovalFromiCloud`, and friends stay as they are to callers.
   There are 19 enqueue call sites; none of them should need to change except the
   ones that must now pass a context (see 3).

3. **Route the atomic paths through `save(committing:)`.**
   `DeferredDeletionEffects` is already the choke point for recording deletion:
   it stages intents and commits them after the save. Change `commit()` to insert
   the outbox rows into the same context *before* `context.save()` runs, so the
   existing staging API keeps working and gains atomicity for free. This is the
   single highest-value part of the change and could ship on its own.

4. **`RecordingWorkflowManager.createSummary` is the one caller that does not use
   `save(committing:)`** — it runs its own `context.save()` and then an enqueue
   loop. Convert it to stage effects and save through the same helper.

5. **Migration.** Read the five UserDefaults keys once on first launch after
   upgrade, insert them as outbox rows, then clear the keys. A tombstone that
   fails to migrate must be left in UserDefaults, not dropped — losing one is the
   exact bug this is meant to prevent. Note that `flushPendingiCloudMutations`
   (`iCloudStorageManager.swift:5871`) and the "Erase All iCloud Data" path both
   clear these keys and will need to clear the entity instead.

### Scope

- New Core Data entity + a model version + migration.
- ~45 references to the queue properties inside `iCloudStorageManager`.
- 19 enqueue call sites, most of which should be untouched by design.
- `DeferredDeletionEffects.commit()` / `commitLocalOnly()` and `save(committing:)`.

Not a small change, but smaller than the reference count suggests, because most
callers funnel through two places.

### Tests

- A recording deletion whose tombstone write is interrupted still has its intent
  after relaunch (simulate by rolling back the context after `commit()` stages,
  and asserting the outbox row and the row deletion share a transaction).
- `requestedAt` still replays the original user-deletion time, and the earliest
  claim still wins — extend `ICloudBackupRegressionTests` rather than writing new
  arbitration tests.
- Migration: five populated UserDefaults queues become the equivalent outbox rows,
  and the keys are cleared only after the insert commits.
- "Erase All iCloud Data" clears the entity and leaves local data alone.

### Explicitly out of scope

Changing when tombstones are published relative to the save. The existing
ordering is correct and must survive this refactor.

---

## 2. Reserve the CloudKit asset cache for the duration of a sync

**Status:** partially fixed in v2.4 (`6f71e6ae`); a residual window remains.

`CacheMaintenanceSweep.pruneCloudKitAssetCache` now takes `isCloudSyncActive` and
re-reads it immediately before every asset deletion, so a sync that starts
mid-sweep protects the assets it has not copied out yet. That is the same shape
as the `isDownloadInFlight` gate on the blob sweep.

It is still a check, not a reservation. A sync that starts in the window between
the check and `removeItem` is not seen. The blob sweep does not have this problem
because `MLXSwiftDownloadManager.beginCacheMaintenance()` *reserves* the cache
before the sweep leaves the main actor, so the download side can refuse to start.

**The fix:** give `CloudSyncOperationCoordinator` the same pair —
`beginCacheMaintenance()` / `endCacheMaintenance()`, refusing to hand out a
maintenance reservation while an operation is running and refusing to start an
operation while one is held. Then the sweep reserves once instead of polling.

**Priority: low.** The residual window is microseconds, and the v2.4 restore-side
fix (below) already means the consequence is one skipped audio file rather than a
failed run. Worth doing when the coordinator is next touched, not on its own.

---

## 3. Retry audio that a restore could not copy

**Status:** open question, verify before building.

`performRestore` now counts `audioFilesFailedToRestore` and continues rather than
throwing out of the whole run (`6f71e6ae`). Nothing explicitly schedules another
attempt at those files.

It may not need to. The restore leg overwrites a local row when the cloud
timestamp is **at least** the local one, so a subsequent pass should decide
`applyCloudRecording` again for the same record and retry the copy. That needs
confirming against the record-selection path before anyone builds a retry
mechanism — `recordingRecordsWithAudioAssets` only refetches assets for records
it is about to write, so the question is really whether an unchanged record still
enters that set.

**Do this first:** write a test that fails one asset copy and asserts the audio
arrives on the next restore. If it passes, close this item and keep the test. If
it fails, the counter needs to feed something that forces the next pass, in the
same spirit as `audioFilesPendingRetry` clearing the backup signature.

---

## 4. A recording larger than half the free disk still cannot stage

**Status:** known limitation of the v2.4 staging budget (`876bd1f3`). Raised by
Cursor's review of PR #124.

`CloudAudioAssetPolicy.stagingByteBudget` caps a run's staging at half of
available capacity. The "first file of a run always stages, however large" rule
stops a recording bigger than the *budget* from being stranded forever — but it
only bypasses the budget, not the physical space. A recording larger than the
free disk itself will attempt its copy, fail on `ENOSPC`, count as
`audioFilesPendingRetry`, and be attempted again on every later run.

The behaviour is safe: metadata syncs, the signature is not stamped, and the
partial copy is now reclaimed immediately (`0927dd98`). It is just futile, and it
repeats.

**Possible fix:** when a single file cannot fit in available capacity at all,
skip it without attempting the copy and surface it once in the maintenance
message, so the user learns the device is too full for that recording rather than
watching every sync quietly retry it.

Related: on a nearly-full device, audio now needs several passes to finish, since
each run stages at most half of what is free. That is intended, but it means
`audioFilesPendingRetry > 0` keeps clearing the backup-state signature, so every
one of those runs does a full metadata pass. If that proves noisy in practice,
the fix is to let the signature record metadata completeness separately from
audio completeness.

---

## 5. `iCloudStorageManager` size

~8,000 lines in one type. No defect, and it was not going to be split during a
release wrap-up, but it is now the main obstacle to reasoning about the sync legs
independently. The `Services/` extraction done in v2.4
(`CloudKitTransport`, `CloudKitBatchExecutor`, `CloudContentIndexCoordinator`,
`CloudSyncOperationCoordinator`, `CloudSyncMetrics`, `CloudAudioAssetStaging`)
is the pattern to continue: the backup leg, the restore leg, and the deletion
preflight are each plausible next extractions.

Do this incrementally and behind the existing test suites, never as one commit.

---

## 6. Textual fork rebase

`CLAUDE.md` notes that the historical Catalyst guards in the `bisonbet/textual`
fork are no longer required by this app and can be dropped when that separate
repository is next rebased. Catalyst was removed in Phase 4.3; nothing in
BisonNotes depends on those guards any more.
