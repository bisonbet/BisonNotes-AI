# BisonNotes AI Cleanup and Hardening Delegation Plan

## Copy/paste instruction for Luna

> Execute `docs/code-quality-cleanup-delegation-plan.md` as the controlling plan. Start with Wave 0 and do not skip its verification. Use one lead agent to integrate changes and delegate only the work packages listed below. Do not let two agents edit the same file at the same time. Complete and validate one wave before starting a dependent wave. Preserve unrelated edits. Do not push, open a pull request, rotate credentials, rewrite Git history, or change GitHub repository settings unless the user explicitly authorizes that action. Stop and report evidence whenever a required macOS/Xcode validation cannot run.

## Goal

Improve repository safety and maintainability without changing user-visible behavior accidentally. The work covers:

- secret-file prevention and repository rules;
- confirmed dead or commented-out code;
- false-success and placeholder behavior;
- credential consistency;
- repeated AI requests;
- transcript recording identity;
- the legacy summary state split between UserDefaults, memory, Core Data, and iCloud;
- gradual reduction of oversized files and the SwiftLint baseline.

This is not permission to delete every comment, TODO, warning, deprecated method, or apparently unused declaration. Each deletion or consolidation must be supported by call-site evidence and validation.

## Reviewed starting point

The review was performed on branch `v2.3` at commit `e32ff430b2f9cc7719db8f080eac9fbf6007cb4c`. The executing lead must verify the actual branch and commit again because this snapshot can become stale.

Important corrections to the original recommendations:

- No tracked `.env` file, private-key file, or recognizable live provider key was found in the current tree or reachable Git history. Do not rotate credentials or rewrite history without new evidence.
- The `.gitignore` gap is real: environment and common private-key files are not generally ignored.
- Transcript reassembly is already centralized in `AudioFileChunkingService.reassembleTranscript`. Do not create a second reassembly coordinator. Fix recording-ID fallbacks at its callers.
- The primary `SummaryManager.generateEnhancedSummary` path already calls `engine.processComplete` once. Optimize only the secondary helpers and background-provider paths that still repeat complete requests.
- Most comments are documentation. Remove only genuine commented-out implementation, obsolete debug statements, and misleading comments.

## Non-negotiable rules

1. The lead agent owns branch state, integration, shared-file sequencing, and final validation.
2. A subagent may edit only the files assigned to its work package.
3. No two active work packages may edit `SummaryManager.swift`, `BackgroundProcessingManager.swift`, `EnhancedFileManager.swift`, a test file, or the Xcode project simultaneously.
4. Search all call sites before removing or changing a declaration. Include tests, Watch code, extensions, and conditional compilation paths.
5. Do not infer that a protocol requirement, SwiftUI callback, Objective-C selector, notification name, App Intent, or Codable field is dead from a simple text count.
6. Do not modify `project.pbxproj` unless a new file truly requires target membership. Prefer adding a small type to an existing correctly targeted file when that keeps the change clear.
7. Do not regenerate or delete the full SwiftLint baseline as part of an unrelated fix.
8. Never print secret values. Tests must use obvious fake values.
9. Preserve backward decoding for saved data and credentials.
10. If running on Linux, do not claim builds or tests passed. Report syntax/lint checks separately and leave the macOS gate for the lead.
11. No commit or push unless the user authorizes it. If commits are requested, the lead stages only reviewed files and uses the repository's required co-author trailer.

## Required report from every subagent

Each subagent must return this exact information:

```text
Work package:
Files changed:
Behavior changed:
Call-site evidence:
Tests added or updated:
Commands run and exact result:
Risks or assumptions:
Unresolved items:
```

A response such as “done,” “looks good,” or “tests should pass” is not acceptable.

## Wave 0 — Lead-only baseline and scope lock

Do this before delegating implementation.

### Steps

- [ ] Run `git status --short --branch`.
- [ ] Record `git rev-parse HEAD` and `git rev-parse --abbrev-ref HEAD`.
- [ ] Inspect `git worktree list --porcelain` and avoid any worktree with user changes.
- [ ] Read `AGENTS.md`, `CLAUDE.md`, and `docs/testing-regimen.md`.
- [ ] Run `git diff --check`.
- [ ] From `BisonNotes AI/BisonNotes AI`, run `swiftlint lint --reporter summary` and save the counts as the before-state. A nonzero result can be pre-existing; record it honestly.
- [ ] On macOS, attempt the local pre-merge test gate from `docs/testing-regimen.md` before changes if dependencies are available.
- [ ] Create a new branch only if the user authorized branch creation. Use the `codex/` prefix unless the user requested another name.
- [ ] Assign each work package to one agent and record file ownership.

### Stop conditions

Stop and ask the user if the checkout is dirty in files required by this plan, the target branch is ambiguous, or baseline tests fail in a way that cannot be distinguished from the planned work.

## Delegation map

| Package | Risk | May run in parallel with | Must finish before | Shared-file warning |
|---|---:|---|---|---|
| A. Repository safeguards | Low | B, C | Final gate | Owns `.gitignore` and `AGENTS.md` |
| B. Keychain credential storage | Medium | A, C | Final gate | Owns credential storage and its tests |
| C. Confirmed dead/commented code | Low | A, B | D–G integration | Must not edit shared managers |
| D. False-success behavior | Medium | None if F is active | Final gate | Owns `BackgroundProcessingManager.swift` and `EnhancedFileManager.swift` |
| E. Repeated AI requests | Medium | None while F is active | G | Owns `SummaryManager.swift` and may revisit `BackgroundProcessingManager.swift` |
| F. Transcript recording identity | Medium | None while E is active | Final gate | Owns transcription services and may revisit `BackgroundProcessingManager.swift` |
| G1. Legacy summary migration | High | Nothing touching summaries/iCloud | G2 | Owns summary, coordinator, and migration tests |
| G2. Core Data/iCloud cutover | High | Nothing touching summaries/iCloud | Final gate | Same ownership as G1 |
| H. File-size/lint reduction | Medium | Only after A–G | Optional follow-up | One large file per change |

Recommended order: Wave 1 = A, B, C in parallel. Wave 2 = D, then E, then F. Wave 3 = G1, then G2. Wave 4 = H as separate follow-up work. E and F are sequential because both may need to edit `BackgroundProcessingManager.swift`.

## Package A — Repository safeguards and agent rules

### Owned files

- `.gitignore`
- `AGENTS.md`
- Optional new secret-scanning configuration only with explicit user approval

### Tasks

- [ ] Add precise ignore rules for `.env`, `.env.*`, `*.env`, `*.pem`, `*.p12`, and `*.key`.
- [ ] Keep `!.env.example` only if a documented, credential-free example file exists or is intentionally added.
- [ ] Do not use the overbroad pattern `env*`; it can hide legitimate source files.
- [ ] Preserve the existing `gha-creds-*.json` rule.
- [ ] Correct the stale `AGENTS.md` statement that says no `.swiftlint.yml` exists. The repository has a committed baseline configuration.
- [ ] Add this end-of-session rule to `AGENTS.md`, adapted only for formatting:

```text
Before handoff, inspect modified files for newly unused declarations, stale commented-out implementation, duplicate helpers, placeholder behavior, and accidentally introduced secrets. Remove code only after call-site verification. Run git diff --check and relevant lint/tests, and report anything intentionally retained.
```

- [ ] Document GitHub Secret Scanning and Push Protection as an owner action. Do not claim it is enabled without repository-setting evidence.
- [ ] Do not add a third-party scanning action or pin an action version without user approval and official-source verification.

### Acceptance checks

```bash
git check-ignore -v .env .env.local test.env private.pem signing.p12 local.key
git ls-files | rg '(^|/)\.env($|\.)|\.pem$|\.p12$|\.key$'
git diff --check
```

Expected: the synthetic filenames are ignored; no real secret file becomes newly tracked; existing tracked source files are unaffected.

## Package B — Keychain failure handling and legacy provider cleanup

### Owned files

- `BisonNotes AI/BisonNotes AI/KeychainSecretStore.swift`
- `BisonNotes AI/BisonNotes AITests/KeychainSecretStoreTests.swift`

### Tasks

- [ ] Change Keychain mutation APIs so `SecItemAdd`, `SecItemUpdate`, and deletion failures are returned or thrown instead of silently ignored.
- [ ] Treat `errSecSuccess` and expected `errSecItemNotFound` explicitly.
- [ ] Update callers to show or log a non-secret failure without logging key names and values together.
- [ ] Add tests for create, update, delete, empty-string deletion, and legacy UserDefaults migration.
- [ ] Remove provider-specific credential storage only after confirming it has no remaining call sites.

### Acceptance checks

- Keychain tests pass without exposing values in logs.
- Manual gate: enter, update, and remove the remaining provider credentials.

## Package C — Confirmed dead and commented-out code

### Owned files

- `BisonNotes AI/BisonNotes AI/Persistence.swift`
- `BisonNotes AI/BisonNotes AI/PerformanceOptimizer.swift`
- `BisonNotes AI/BisonNotes AI/OnDeviceLLM/OnDeviceLLM.swift`
- `BisonNotes AI/BisonNotes AI/OllamaService.swift`
- `BisonNotes AI/BisonNotes AI/Views/SettingsView.swift`
- Other files only after the lead explicitly expands ownership

### Candidate list

- The obsolete commented `Item` preview loop in `Persistence.swift`.
- `PerformanceOptimizer.stopMemoryMonitoring()` if it remains declaration-only and `stopAllMonitoring()` owns the behavior.
- `OnDeviceLLM.rollbackLastUserInputIfEmptyResponse(_:)` if the actual rollback remains in `generateResponseStream` cleanup.
- `OllamaService.cleanTitleResponse(_:)` if all title cleaning uses `RecordingNameGenerator` directly.
- `OllamaService.createTasksAndRemindersTool()` and `createTitlesTool()` if no active tool registration path references them.
- `SettingsView.clearAllSummaries()` if it remains an empty private method with no call site.
- Commented-out debug `print` statements in changed files.

### Tasks

- [ ] Run an exact-symbol `rg -n` search for every candidate before deleting it.
- [ ] Inspect protocol conformances, `#if` branches, selectors, notifications, previews, and tests.
- [ ] Remove the declaration and comments that only explain the removed declaration.
- [ ] Do not remove public compatibility methods, migration code, or TODOs outside the candidate list without lead approval.
- [ ] Keep explanatory comments that describe non-obvious behavior or platform constraints.

### Acceptance checks

- Each removed symbol has a recorded call-site search showing no active caller.
- On-device LLM cancellation and empty-response behavior remain covered or receive a focused regression test.
- Ollama tool registration still exposes the currently supported complete-processing tool.
- `git diff --check` and targeted SwiftLint complete without new violations.

## Package D — Remove false-success and placeholder behavior

### Owned files

- `BisonNotes AI/BisonNotes AI/EnhancedFileManager.swift`
- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift`
- A new or existing focused test file assigned by the lead

### Tasks

- [ ] Recheck call sites for `EnhancedFileManager.deleteSummary(for:)` and `deleteTranscript(for:)`.
- [ ] If they still have no callers, remove the methods instead of preserving a second deletion API.
- [ ] If a real caller exists, resolve the recording through `AppDataCoordinator`, call the coordinator/Core Data deletion API, and update relationship state only after persistence succeeds.
- [ ] Never log “Deleted” before the delete operation succeeds.
- [ ] Replace hard-coded `iCloudSynced = false` with real derived state if an authoritative source exists. Otherwise rename/remove the field rather than presenting false status.
- [ ] Replace the Ollama placeholder summary in background processing. Route the request through the existing Ollama `SummarizationEngine.processComplete` path using the explicitly selected engine.
- [ ] If the selected engine cannot be resolved or Ollama is disabled/unreachable, throw the existing user-visible unavailable/processing error. Do not create a successful summary containing “not yet implemented.”
- [ ] Resolve recording dates from the recording entry or file metadata instead of unconditional `Date()` where the original date is available.

### Acceptance checks

- No code path logs a successful summary/transcript deletion without deleting persisted data.
- Searching for `not yet implemented` finds no successful result payload in background processing.
- An unavailable Ollama service produces a failure state, not a completed job.
- A successful Ollama path uses the real configured service and returns summary, tasks, reminders, and titles.
- Add regression coverage for the branch-selection behavior without making a live network request.

## Package E — Eliminate repeated complete AI requests

### Owned files

- `BisonNotes AI/BisonNotes AI/SummaryManager.swift`
- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift` only after Package D is integrated
- `BisonNotes AI/BisonNotes AI/Models/SummarizationEngine.swift`
- Provider engines/services explicitly assigned by the lead
- Focused summarization tests

### Stage E1: behavior fix without broad type migration

- [ ] Keep the existing primary `generateEnhancedSummary` call to `engine.processComplete`.
- [ ] Change `extractTasksAndRemindersFromText` so one complete result is obtained and projected into tasks/reminders.
- [ ] Remove `extractTasksRemindersAndTitlesFromText` if it still has no caller. If it gains a caller, make it obtain one complete result.
- [ ] In background compatible-API processing, replace separate summary/task/reminder/title requests with one supported complete-processing request.
- [ ] Check every provider wrapper before changing it; individual extraction methods are protocol API and may still be used independently.
- [ ] Add a spy/fake engine test that counts calls and proves a combined operation invokes `processComplete` exactly once.

### Stage E2: replace the five-element tuple

Do this as a separate commit only after E1 is green.

- [ ] Introduce a named `SummarizationResult` value type containing summary, tasks, reminders, titles, and content type.
- [ ] Change the protocol and implementations mechanically, one engine at a time.
- [ ] Avoid changing prompts, parsing, retry behavior, chunking, or provider selection in this stage.
- [ ] Compile after each provider conversion so errors remain attributable.

### Acceptance checks

- Combined extraction performs one provider request per attempt, excluding documented retry/chunk behavior.
- Individual extraction methods still return the same field values.
- Cancellation, safety-block, and retry semantics remain unchanged.
- The large-tuple lint violation is removed from the migrated API without broad baseline regeneration.

## Package F — Preserve recording identity through transcription

### Owned files

- `BisonNotes AI/BisonNotes AI/MistralTranscribeService.swift`
- `BisonNotes AI/BisonNotes AI/WhisperService.swift`
- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift` only after Package D is integrated
- `BisonNotes AI/BisonNotes AI/AudioFileChunkingService.swift` only if its API must enforce identity
- `BisonNotes AI/BisonNotes AITests/AudioTranscriptionRegressionTests.swift`

### Tasks

- [ ] Do not create another transcript reassembly helper; use `AudioFileChunkingService.reassembleTranscript`.
- [ ] Trace every transcription entry point and identify where the Core Data recording is created.
- [ ] Make the production chunk/reassembly path require the real recording UUID.
- [ ] Remove `recordingId ?? UUID()` fallbacks from provider services.
- [ ] If no recording can be resolved in background processing, fail with a typed error before saving a transcript.
- [ ] If an import workflow legitimately begins without a recording, create the recording through `AppDataCoordinator` first and pass its returned UUID.
- [ ] Keep any UUID-generating behavior only in an explicitly named test/ephemeral helper, not production provider code.

### Acceptance checks

- Existing reassembly sorting/segment-offset tests remain green.
- Add a test proving the supplied recording ID survives each shared reassembly path.
- Add a test proving missing identity fails before transcript persistence.
- A transcript, recording, and generated summary share the same UUID in the integration test.

## Package G1 — Idempotent migration of legacy summary data

This is data-migration work. It must not be delegated until Packages E and F are integrated and green.

### Owned files

- `BisonNotes AI/BisonNotes AI/SummaryManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/AppDataCoordinator.swift`
- `BisonNotes AI/BisonNotes AI/Models/CoreDataManager.swift` only if a tested upsert is missing
- `BisonNotes AI/BisonNotes AITests/BisonNotesAIIntegrationTests.swift`
- A dedicated summary migration test file if needed

### Test-first requirements

- [ ] Legacy JSON with a matching recording migrates into Core Data.
- [ ] Running migration twice does not duplicate a summary.
- [ ] Corrupt JSON does not crash and is not silently marked migrated.
- [ ] A legacy summary with no matching recording is retained for later recovery and reported.
- [ ] The legacy key is deleted only after every migratable item is saved successfully.

### Implementation requirements

- [ ] Use recording UUID as identity whenever available; use normalized recording URL only to resolve older records.
- [ ] Upsert rather than append.
- [ ] Store a versioned migration-complete marker, not a generic Boolean with no schema meaning.
- [ ] Make migration safe to resume after partial failure.
- [ ] Do not perform CloudKit mutation as a side effect of local migration tests.

## Package G2 — Core Data as the sole live summary source

### Owned files

- Same files as G1
- `BisonNotes AI/BisonNotes AI/iCloudStorageManager.swift`
- `BisonNotes AI/BisonNotes AITests/ICloudBackupRegressionTests.swift`
- Summary views only when a direct dependency is proven

### Tasks

- [ ] Replace iCloud reads and writes of `SummaryManager.shared.enhancedSummaries` with coordinator/Core Data queries and upserts.
- [ ] Convert remaining in-memory append/update paths to coordinator writes.
- [ ] Replace summary statistics and regeneration enumeration with Core Data-backed values.
- [ ] Remove `loadEnhancedSummariesLegacy`, `saveEnhancedSummariesToDisk`, `loadEnhancedSummaries`, and `SavedEnhancedSummaries` only after G1 tests prove migration.
- [ ] Remove or reduce `@Published enhancedSummaries` only after all UI and iCloud consumers use the authoritative store.
- [ ] Keep cloud exclusion and deletion-marker behavior unchanged.

### Acceptance checks

- Relaunching does not resurrect deleted summaries.
- Local summary edits survive relaunch and appear once.
- iCloud backup selection reads Core Data and excludes secrets/local-only recordings as before.
- Restore/upsert does not duplicate summaries.
- `ICloudBackupRegressionTests` and integration tests pass.
- Manual two-device iCloud validation remains a release gate and must be reported separately from simulator tests.

## Package H — Gradual file-size and SwiftLint reduction

Treat this as follow-up work, not part of the correctness commits.

### Rules

- [ ] Choose one oversized file and one responsibility boundary per change.
- [ ] Move code without changing behavior first; functional changes belong in later commits.
- [ ] Start with cohesive seams such as provider adapters, CloudKit record encoding/decoding, restore orchestration, settings sections, or summary statistics.
- [ ] Do not begin by splitting every view or manager.
- [ ] Verify the committed baseline from a clean clone at a different absolute path. If it is path-sensitive, use the supported SwiftLint baseline workflow; do not hand-edit the one-line JSON file.
- [ ] Reduce baseline entries only for code actually fixed in the change.

### Suggested order

1. `BackgroundProcessingManager.swift`
2. `SummaryManager.swift` after G2
3. Provider settings views
4. `iCloudStorageManager.swift`, one CloudKit responsibility at a time

## Per-package validation

Every package must run:

```bash
git diff --check
cd "BisonNotes AI/BisonNotes AI"
swiftlint lint --reporter summary
```

Record the before/after violation totals. Existing baseline violations are not permission to introduce new ones.

On macOS, the lead must run after each behavior-changing package:

```bash
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-test-derived
```

Useful focused classes:

- Package B: `KeychainSecretStoreTests`
- Package D: new background-processing/deletion regression tests
- Package E: new summarization request-count tests
- Package F: `AudioTranscriptionRegressionTests`
- Packages G1/G2: `BisonNotesAIIntegrationTests` and `ICloudBackupRegressionTests`

Do not call a package green if tests only compiled but the runner exited during CloudKit bootstrap. Report compilation, test execution, simulator state, signed-app checks, hardware checks, and manual CloudKit checks separately.

## Lead integration checklist

After each subagent returns:

- [ ] Read the diff; do not accept the summary alone.
- [ ] Confirm only assigned files changed.
- [ ] Re-run the subagent's call-site searches.
- [ ] Reject broad formatting churn or unrelated baseline changes.
- [ ] Run package checks before integrating the next shared-file package.
- [ ] Keep one logical change per commit if commits were authorized.
- [ ] Record deferred manual checks explicitly.

## Final acceptance gate

- [ ] `git status --short --branch` shows only intended changes or is clean after authorized commits.
- [ ] `git diff --check` passes.
- [ ] No tracked `.env`, private-key, or credential export file exists.
- [ ] No recognizable real secret was added to the diff or history.
- [ ] Full SwiftLint introduces no new violations relative to Wave 0.
- [ ] iOS simulator tests pass, or the exact environmental blocker is recorded.
- [ ] Native macOS build is run when touched code is shared with macOS.
- [ ] Watch tests/build are run if shared models or Watch-visible behavior changed.
- [ ] Credential, Ollama, migration, iCloud, and hardware validations are listed separately when they require real services/devices.
- [ ] The final report lists implemented packages, skipped packages, test evidence, remaining risk, and exact commit SHAs if commits were authorized.

## Owner-only actions

These cannot be proven or safely completed by source edits alone:

- Enable GitHub Secret Scanning and Push Protection, then capture the repository-setting evidence.
- Rotate a provider key only if an actual credential is discovered or the provider reports exposure.
- Validate Ollama against the user's configured local server and model.
- Perform signed-app, hardware, and two-device CloudKit tests from `docs/testing-regimen.md`.
