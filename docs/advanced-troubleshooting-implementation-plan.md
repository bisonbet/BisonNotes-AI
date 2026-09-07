# Advanced Troubleshooting implementation handoff for Luna

## Objective and provenance

Implement the approved Settings review: replace the legacy troubleshooting screen with a small, understandable maintenance screen containing a read-only local diagnostic report, a safe orphaned-audio review, and the existing iCloud erase/fresh-backup flow.

- Repository: `/Users/champ/Sources/BisonNotes-AI`
- Implementation branch: `codex/advanced-troubleshooting-cleanup`
- Base: local `v2.5`, commit `6ae2fe78e68ba1598b176a7b9518e98fa5267280`
- Base includes the orphaned-audio scan feedback fix. Preserve visible progress, empty results, and error feedback as the implementation evolves.
- This document is the handoff; no implementation has been performed yet.

Before editing, read `AGENTS.md`, verify branch/HEAD/status, and inspect any changes since this base. Preserve unrelated work. Do not switch to another branch, reset, stash, or absorb concurrent changes. Implement and validate locally; do not commit, push, create a PR, or run destructive operations against real user data unless separately requested.

## Approved product scope

Keep the Settings label **Advanced Troubleshooting**. Replace the Tools/Check/Repair tabs and migration terminology with one screen:

1. **Local Data Report**: on-demand, read-only diagnostics, with visible progress, results, and errors. No automatic repair or deletion.
2. **Review Unreferenced Audio**: scan, show specific candidates with names/sizes, allow explicit selection and confirmation, and safely delete only approved candidates.
3. **Erase All iCloud Data**: retain the existing coordinated erase and fresh-upload flow, including typed confirmation, partial-failure handling, and existing backup options.

Keep normal Settings **Backup**, **Restore**, **Review iCloud Items**, **Background Processing**, and **Export Diagnostic Logs** in their existing locations. Opening diagnostics should not require a blanket destructive warning; place accurate warnings at the actual deletion actions. Preserve native macOS presentation, dismissal, scrolling, and iOS accessibility behavior.

Remove these controls and their screen-only state/actions/results:

| Existing control | Disposition |
| --- | --- |
| Check for Issues / Start Integrity Check | Replace with read-only Local Data Report |
| Repair Issues / Start Repair | Remove; do not carry missing-audio deletion into the replacement |
| Recover from iCloud | Remove; normal Restore handles current backup data |
| Upload All Summaries to iCloud | Remove; normal Backup handles current backup data |
| Repair Orphaned Summaries | Remove this entry point |
| Cleanup Duplicate Summaries | Remove this entry point |
| Background Processing | Remove only the troubleshooting shortcut |
| Verify iCloud Sync / Sync Missing Summaries | Remove; do not claim a local report verifies cloud completeness |
| Cleanup Orphaned Data | Remove |
| View Database Info | Replace with visible Local Data Report |
| Clear All Data | Remove; do not introduce a new reset feature |
| Back to Migration / other tab navigation | Remove with the obsolete tab structure |

## Evidence and source touchpoints

All paths below are repository-relative. Line numbers from the review are approximate; locate symbols again before editing.

- `BisonNotes AI/BisonNotes AI/Views/SettingsView.swift`: both Advanced Troubleshooting entry points and the sheet presenting `DataMigrationView`; existing Backup/Restore and cloud review.
- `BisonNotes AI/BisonNotes AI/Views/DataMigrationView.swift`: existing controls, orphaned scan/delete actions, `cleanupOrphanedData`, legacy cloud verification, and cloud maintenance UI. Rename to a troubleshooting-oriented view if practical, updating project membership and all references.
- `BisonNotes AI/BisonNotes AI/Models/DataMigrationManager.swift`: `performDataIntegrityCheck`, `repairDataIntegrityIssues`, `findMissingAudioFiles`, `cleanupMissingAudioFiles`, `recoverDataFromiCloud`, `clearAllCoreData`, `debugCoreDataContents`. Missing-audio repair unconditionally deletes linked content and ignores archives. The old check sets progress to 1 but leaves `isCompleted` false, disabling several controls indefinitely.
- `BisonNotes AI/BisonNotes AI/EnhancedFileManager.swift`: `findOrphanedAudioFiles` scans top-level Documents for m4a/wav/mp3/aac and treats failed enumeration as an empty result. `cleanupOrphanedAudioFiles` rescans and deletes its new results, rather than the user's reviewed set.
- `BisonNotes AI/BisonNotes AI/Models/CoreDataManager.swift`: `getAllRecordings` converts fetch errors into an empty array; destructive scans must not use this ambiguity. `repairOrphanedSummaries` creates synthetic recordings without first resolving an existing recording identity. `cleanupDuplicates` deletes older rows without reconnecting survivors and also deletes orphaned rows.
- `BisonNotes AI/BisonNotes AI/Models/RecordingArchiveService.swift`: `archiveRecordings` intentionally removes local audio while retaining recording metadata. An archive is not an orphan.
- `BisonNotes AI/BisonNotes AI/Models/AppDataCoordinator.swift`: ordinary recording/transcript/summary deletion publishes cloud deletion intents. Local diagnostic inconsistencies must never invoke those paths.
- `BisonNotes AI/BisonNotes AI/iCloudStorageManager.swift`: retain `eraseAlliCloudData`, its operation coordination, and `backupAllDataToiCloud`. Legacy verification reads only legacy summary IDs; its fetch ignores pagination, and summary uploads can swallow errors. Removing the UI does not authorize broad changes to shared cloud APIs.

## Implementation sequence

### 1. Remove unsafe and redundant UI entry points

Replace the old screen structure and remove obsolete state, alerts, callbacks, result models, and imports only after checking references. Keep the cloud maintenance implementation working during the refactor. Do not leave hidden navigation paths to Start Repair, Cleanup Orphaned Data, or Clear All Data in this screen.

Audit every remaining caller before deleting backend declarations:

- `ContentView.swift` still invokes `performDataMigration()` at startup. Preserve startup migration and its helpers.
- `SummariesView.swift` also invokes `repairOrphanedSummaries()`. Removing the Settings button does not authorize deleting this shared method or silently changing the summaries flow. Record this remaining risk explicitly in the handoff.
- Current iCloud reconciliation uses `deleteSupersededDuplicates`; preserve it.
- Existing tests may directly exercise `clearAllCoreData` and other methods. Distinguish production callers, safety regression coverage, and truly obsolete tests. Do not delete safety tests simply to enable a broader cleanup.
- Do not remove persistence fields, migrations, cloud record types, outbox behavior, or shared legacy cloud APIs merely because their Settings buttons disappear.

Prefer retaining a shared implementation with documented callers over widening this task. Remove demonstrably unused screen-only backend code after full call-site and project-membership verification.

### 2. Implement a read-only local report

Use a small testable report service/model and throwing data access. Keep Core Data work on its owning context; pass value snapshots to off-main disk work. No unmanaged objects crossing actor boundaries and no main-thread disk sweep disguised by a short sleep.

Report recording/transcript/summary counts and narrowly defined inconsistencies:

- Relationship/foreign-key disagreements where a required relationship is actually expected under the current data model.
- Duplicate stable IDs or multiple content rows for one recording as diagnostic candidates, never as authorization to remove content. Repeated display names alone are not duplicates.
- Unexpected missing local audio, separately from intentionally archived/offloaded content and records that legitimately have no audio. Inspect current import/restore/archive semantics before choosing predicates; do not infer every missing file is broken.

Do not classify valid imported transcripts, summary-only records, archives, or metadata-only restores as corrupt merely for lacking local audio. If cloud availability is unknown, say so; do not claim the content is lost or backed up. A local report must not fetch or mutate CloudKit.

Show a timestamp and distinguish successful empty results from partial/failed inspection. A failed fetch must never yield “No issues found.” Use explicit operation state with guaranteed completion/error cleanup rather than the old migration progress/isCompleted combination. Re-running and canceling/dismissing must leave the screen usable. Diagnostics must not save, repair, delete, enqueue cloud mutations, or prune attachments.

### 3. Harden unreferenced-audio scanning and deletion

The scan is a candidate review, not proof that an unreferenced file is disposable. A file may be an interrupted recording or a pending import.

- Obtain a complete recording-reference snapshot using throwing access. On database or directory-read failure, show an error and disable deletion; never treat failure as an empty database.
- Define and display scan coverage accurately. Reuse existing supported-audio/path helpers where suitable; do not claim to scan all Documents content if only a top-level subset is supported. Avoid an unrelated recursive storage cleanup expansion.
- Resolve/normalize local references using the authoritative URL rules. Limit deletion to regular local audio files in the intended scan root; avoid symlink/path escapes and ambiguous identities.
- Inspect recording, import, conversion, restore, and job ownership paths. Exclude in-flight files and prevent deletion during relevant work. Implement a real ownership/activity guard, not just a button label. Recheck at execution time; if safe exclusion cannot be established for an operation, make deletion unavailable while it is active.
- Keep scan results as a stable review snapshot. Show filenames and sizes; deletion must be limited to explicitly selected and confirmed candidates. Never delete new files discovered during confirmation or execution.
- Immediately before deletion, successfully re-read references and validate candidate identity/existence and active ownership again. Skip files that became referenced, changed/replaced, or are otherwise uncertain. Do not rely solely on a stale URL or timestamp.
- Delete only approved audio and any specifically permitted associated sidecars after revalidation. Never delete transcripts, summaries, recording rows, archive references, attachments, or cloud records as a side effect.
- Return actual deleted counts/bytes, skipped candidates with reasons, and per-file failures. Errors and zero results must be visible; re-scan without automatically deleting anything after completion.

Use injectable persistence/file-operation boundaries so failure cases can be tested with temporary directories and in-memory stores. Keep design proportional; do not build a generic maintenance framework.

### 4. Preserve cloud erase/fresh-backup behavior

Keep the typed confirmation and existing cloud operation coordinator. Preserve enabled-state checks, busy-state handling, cancellation of confirmation, incomplete-erase reporting, and the rule that fresh upload is offered only after successful erase. Fresh upload must keep using current backup options, including sensitive-settings gating.

Do not replace the erase with direct CloudKit calls or add automatic erasure/upload on screen entry. Do not claim the erase suspends other devices indefinitely. Keep this operation visibly separate from local file cleanup.

### 5. Finish integration and documentation

Update references, accessibility identifiers, previews, and Xcode project membership if files/types move. Search documentation for the removed troubleshooting workflow and update applicable current guidance without rewriting historical release notes. Avoid leaving migration wording or buttons that appear to do nothing. Inspect the final diff for unused declarations, stale comments, duplicate helpers, placeholder behavior, and accidental secrets.

## Required validation

Read `docs/testing-regimen.md` and use its current schemes/destinations, verifying availability locally. Run builds sequentially with isolated DerivedData and an existing package cache where available. Do not execute maintenance on the user's real database, recordings, or iCloud account.

Add meaningful focused regression tests using in-memory stores and temporary audio files:

1. Reports preserve all rows, relationships, files, attachments, and cloud-deletion outbox state; valid archives/imports/summary-only records are not falsely condemned.
2. Same-name recordings with different IDs are not declared duplicate solely by name; genuine identity/link inconsistencies are reported without mutation.
3. Database-fetch and directory-enumeration failures produce errors and no deletions.
4. Referenced audio and in-flight files are protected. Files becoming referenced/active after scan are skipped.
5. Newly discovered, unselected, replaced, moved, or out-of-root files cannot be deleted from an earlier confirmation.
6. An explicitly selected, still-unreferenced eligible file can be deleted; partial failures report correct counts/bytes and preserve unrelated files and data.
7. Empty scan, failed scan, repeated scan, and canceled confirmation leave controls usable.
8. Relevant existing cloud erase/backup regression coverage remains green; UI refactoring does not change successful/partial-failure behavior.

Run the appropriate focused suites, then the repository's required iOS unit/UI/accessibility pre-merge gate and a native macOS build. Run `git diff --check` and relevant SwiftLint; report actual warning/error counts and baseline/tool limitations. Do not equate parse/lint/diff success with compilation or an interrupted test run with passing tests.

Perform a Settings navigation smoke check on iOS Simulator and native macOS using disposable data: new report, repeated scans, explicit file review, dismissal, accessible labels, and absence of removed controls. No live cloud erase. Physical-device accessibility and real multi-device CloudKit behavior remain separate, explicitly unverified gates unless actually exercised with authorized disposable accounts/data.

## Acceptance and final handoff

The user can inspect local data without changing it, review and safely remove only approved unreferenced audio, and access the established iCloud erase/fresh-backup flow. Legacy repair, summary-only sync/verification, duplicate job navigation, and database reset controls are absent. Startup migration and existing normal Settings actions remain functional.

Provide a concise final report with:

- Branch, base, and final HEAD; exact changed files and working-tree status.
- Removed/replaced controls and implemented safety behavior.
- Test/build/lint results with commands, counts, and limitations.
- Any intentionally retained shared legacy methods and their remaining callers, especially `SummariesView` orphan repair.
- Any unresolved risks or incomplete acceptance criteria; do not claim completion if the safe deletion contract is incomplete.

Leave implementation changes available for review. Commit/push/PR creation are outside this handoff's authorization.
