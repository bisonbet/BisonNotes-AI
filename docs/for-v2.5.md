# For v2.5

Work deliberately deferred out of v2.4 (PR #124). Each item says what the defect
is, why it was not fixed at the time, and what the change actually involves.

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

## 2. Textual fork rebase

`CLAUDE.md` notes that the historical Catalyst guards in the `bisonbet/textual`
fork are no longer required by this app and can be dropped when that separate
repository is next rebased. Catalyst was removed in Phase 4.3; nothing in
BisonNotes depends on those guards any more.
