# Post-Commit Work: a convention to stop a recurring class of bug

**Status:** planned, not started
**Branch:** `v3.0-post-commit-convention`, cut from `v3.0-reliability-hardening` at `e3ae604a`
**Depends on:** PR #131 merging to `v3.0` first. Rebase onto `v3.0` before opening the PR.

---

## 1. The bug this prevents

Five times in PR #131, the same accident produced a user-visible failure:

> A `do` block spans a durable commit. Work after the commit throws. The `catch`
> was written for failures *before* the commit, so it reports the whole
> operation as failed — discarding, re-running, or re-billing work that already
> succeeded.

The cost is never cosmetic. In the five confirmed cases it was: a second
billable provider request for a summary that already existed (×3), a re-run
transcription that could overwrite a valid transcript, and a recording stranded
permanently because the retry died on the already-deleted first item.

This is not a style preference. Each instance was found by review, one at a
time, across five unrelated files — which is the signal that the shape is
habitual rather than accidental.

### The boundary

A **commit** is any call that makes state durable. In this codebase:

| Function | File |
|---|---|
| `saveContext(operation:)` | `Models/CoreDataManager.swift:1911` |
| `performIsolatedMutation(operation:_:)` | `Models/CoreDataManager.swift:1944` |
| `createRecording(url:name:date:...)` | `Models/RecordingWorkflowManager.swift:57` |
| `createSummary(for:transcriptId:...)` | `Models/RecordingWorkflowManager.swift:139` |
| `addTranscript(for:segments:...)` | `Models/AppDataCoordinator.swift` |
| `publish(_:)` / `markMetadataCommitted(_:recordingID:)` | `MediaOperationRecoveryStore.swift` |
| `FileManager` moves that publish into Documents | various |

After any of these, the operation has **succeeded**. Everything later is
bookkeeping, cleanup, or an optional enrichment.

---

## 2. What to build

### 2.1 The helper

New file: `BisonNotes AI/BisonNotes AI/Models/PostCommit.swift`

```swift
/// Runs work that follows a durable commit and must not fail the operation.
///
/// By the time this runs the commit has already happened, so an error here is
/// not a failure of what the caller was doing — it is a loose end to report,
/// never to propagate. Returning the error instead of throwing it is the point:
/// a caller has to opt in to caring, and cannot leak it into a `catch` written
/// for pre-commit failures.
///
/// See docs/post-commit-convention-plan.md for the five bugs this replaces.
@discardableResult
func afterCommit(
    _ description: String,
    category: LogCategory,
    level: OSLogType = .error,
    _ body: () throws -> Void
) -> Error?
```

Behavior:
- Run `body()`. On success return `nil`.
- On throw, log `"<description> did not complete after its commit: <error>"` at
  `level` in `category`, and return the error.
- No `async` variant unless a migration site needs one (site 2 does not —
  check before adding).

`LogCategory` is at `EnhancedLoggingSystem.swift:19`; `AppLog.shared.log(_:level:category:)`
at line 310.

### 2.2 Tests

New file: `BisonNotes AI/BisonNotes AITests/PostCommitTests.swift`

Cover:
1. Success returns `nil` and runs the body exactly once.
2. A throwing body returns that exact error (identity, not just non-nil).
3. A throwing body does **not** propagate — the enclosing scope continues.
4. The description appears in the returned/logged context.

These are cheap and fast; the value is that the helper's contract is pinned
before anything depends on it.

---

## 3. Migration — the five known sites

Migrate all five. Each should become materially shorter; if one does not, stop
and reconsider the helper's shape rather than forcing it.

| # | Site | Current marker to find |
|---|---|---|
| 1 | `BackgroundProcessingManager.swift:~2103` | comment `Best-effort, and deliberately isolated:` |
| 2 | `BackgroundProcessingManager.swift:~1323` | `} else if outputCommitted, !completionStatePersisted {` |
| 3 | `SummaryRegenerationManager.swift:~144` | `"Bulk regeneration saved the summary but could not rename recording "` |
| 4 | `SummaryRegenerationManager.swift:~238` | `"Regeneration saved the summary but could not rename recording "` |
| 5 | `Views/CombineRecordingsView.swift:~606` | comment `Each original is retired independently` |

**Site 2 is the exception — do not force it.** It is not an optional step in a
`do` block; it is a *terminal acknowledgement*, and its fix needed two separate
facts (`outputCommitted` = the work is durable, `completionStatePersisted` = that
success was recorded). The helper does not express that. Leave the logic as-is
and only adopt the helper's logging wording if it fits. Note in the PR that
site 2 stays hand-written and why.

**Site 5 is a loop, not a single step.** The pattern there is "retire N items
independently, already-absent counts as done, report failures together." If two
or more such loops exist, consider a second small helper; with one, leave it.

### Related sites — read, do not migrate blindly

These were fixed in PR #131 and are the same *family* but different shapes.
Read them for context; migrate only if the helper genuinely fits:

- `Models/RecordingArchiveService.swift:~513` — `retireArchiveSource`, returns a
  user-facing description rather than just logging.
- `Models/RecordingArchiveService.swift:~127` — batch cleanup accumulating
  `localRemovalFailures`.
- `Views/TranscriptViews.swift:~1517` — imported-transcript audio retained.
- `EnhancedFileManager.swift:~284` — resumed post-commit cleanup.

---

## 4. The CLAUDE.md rule

Most editing on this repo is done by agents that read `CLAUDE.md` every session,
and there is no CI. That makes `CLAUDE.md` the enforcement mechanism, not a
consolation prize — the existing iCloud arbitration rule ("All four are pure
static functions … change them there, not inline in the sync legs") has
visibly held.

Add a section under **Development Guidelines**, after *Core Data Usage*:

```markdown
### Post-Commit Work

A `do` block must not span a durable commit. Once `saveContext`,
`performIsolatedMutation`, `createRecording`, `createSummary`, `addTranscript`,
or a media `publish` has returned, the operation has succeeded — and a later
failure is a loose end, never a failure of the thing the caller was doing.

Run anything after that point through `afterCommit(_:category:_:)`. It logs and
returns the error rather than throwing, so it cannot reach a `catch` written for
pre-commit failures. Five separate bugs in v3.0 reliability hardening were this
exact shape: three re-billed an AI provider for a summary that already existed,
one re-ran a transcription over a valid result, and one stranded a recording
permanently behind a retry that died on an already-deleted id.

Cleanup that must eventually happen needs a durable intent, not a retry in the
same call. Cleanup the user can do themselves — a file in a folder they chose —
needs to be *named to them*, not automated.
```

Keep it short. The value is the rule plus the named helper, not the history.

---

## 5. Out of scope

- **A lint rule.** Expressing "a `try` after a commit in the same `do`" needs
  SwiftSyntax; SwiftLint's `custom_rules` are regex-only and cannot see block
  structure. The repo has no `.swiftlint.yml` and no CI, so a tool would be
  introducing both from scratch and nothing would run it. Revisit if CI lands.
- **Rewriting error handling generally.** This addresses one specific, evidenced
  shape. Do not generalize into a broader refactor.
- **Retrofitting the related sites in §3** unless the helper fits cleanly.

---

## 6. Definition of done

- [ ] `PostCommit.swift` added, with the doc comment explaining *why* it returns
      rather than throws.
- [ ] `PostCommitTests.swift` added; all cases pass.
- [ ] Sites 1, 3, 4 migrated and shorter. Site 5 migrated or explicitly declined
      in the PR body. Site 2 left hand-written, with the reason stated.
- [ ] `CLAUDE.md` section added.
- [ ] `xcodebuild build -scheme "BisonNotes AI macOS"` passes.
- [ ] Full suite passes with no net loss; it was **671 passing, 0 failed,
      0 skipped** at `e3ae604a`.
- [ ] PR body states plainly that this is a refactor of already-fixed bugs — it
      changes no behavior that a user can observe, and the tests it adds pin the
      helper, not the original bugs. Those remain pinned by the fixes in #131.

## 7. Verification note

Do not claim these paths are covered. Migrating a site does not test it — none
of the five are reachable from the suite without failure injection. The one
place that *is* exercised is the merge boundary (`MergeCommitBoundaryTests`,
using the `mergeCommitFailureForTesting` seam). If you want real coverage for a
migrated site, extend that seam pattern to its commit; that is separate work and
should be its own PR.
