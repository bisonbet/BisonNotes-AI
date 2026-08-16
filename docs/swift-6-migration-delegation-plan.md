# BisonNotes AI Swift 6 Migration Delegation Plan

## Copy/paste activation instruction for Luna

> Execute `docs/swift-6-migration-delegation-plan.md` as the controlling source of truth. Read this plan completely, then read `AGENTS.md`, `CLAUDE.md`, and `docs/testing-regimen.md` completely before taking any implementation action. Use one lead agent to own branch state, the Xcode project, shared-interface decisions, integration, and final validation. Start with the read-only Wave 0 baseline and scope lock. If the checkout is dirty in any file required by this plan, do not stash, reset, overwrite, or absorb those changes; stop and ask the owner how to preserve them. Delegate only the work packages and files assigned here, and never let two active agents edit the same file. Follow the dependency order and validate each package before starting a dependent package. Do not set project-wide default MainActor isolation, add an unsafe concurrency escape, upgrade a dependency, change deployment targets, alter persistence schemas, create a branch, commit, push, open a pull request, rewrite history, or change repository settings unless this plan explicitly permits it or the owner separately authorizes it. If Wave 0 is clean and no stop condition applies, continue through the packages and return the required evidence report.

## 1. Goal and truthful definition of “Swift 6”

Migrate all first-party BisonNotes targets from Swift 5 language mode to Swift 6 language mode while preserving current behavior across iOS, iPadOS, native macOS, watchOS, widgets, controls, share extensions, unit tests, and UI tests.

The migration is complete enough to advertise “Swift 6” only when:

- every first-party Debug and Release target configuration resolves to `SWIFT_VERSION = 6.0`;
- all first-party targets compile under Swift 6 strict concurrency semantics;
- concurrency fixes express real ownership and isolation rather than hiding diagnostics broadly;
- the required automated build/test matrix is green or an external blocker is precisely documented;
- release-critical recording, transcription, persistence, provider, Watch, extension, and native Mac behavior has been validated according to `docs/testing-regimen.md`;
- the README and active internal documentation describe the proven compiler/Xcode requirement accurately.

Third-party packages may retain their own declared language modes. They must resolve and compile with the supported Swift 6 toolchain, but their manifests do not need to be rewritten merely to support the app's Swift 6 claim.

## 2. Reviewed starting point

This plan was written on 2026-08-16 from:

- branch: `v2.3`;
- commit: `a0426948385693cfa8ccdef4194ae62889fd664d`;
- Xcode used for the review: Xcode 26.6, build 17F113;
- 12 first-party native targets, each with Debug and Release configurations;
- 24 explicit `SWIFT_VERSION = 5.0` settings;
- no explicit `SWIFT_STRICT_CONCURRENCY` setting;
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` in only 10 configurations; this is not equivalent to Swift 6 language mode;
- README badge: Swift 5.0.

The executing lead must treat this snapshot as stale until Wave 0 re-verifies it.

### Existing worktree changes at plan creation

The checkout was not clean. These files were already modified and are user-owned:

- `BisonNotes AI/BisonNotes AI/GoogleAIStudioService.swift`
- `BisonNotes AI/BisonNotes AI/Info.plist`
- `BisonNotes AI/BisonNotes AI/Models/RecordingNameGenerator.swift`
- `BisonNotes AI/BisonNotes AI/OllamaService.swift`
- `BisonNotes AI/BisonNotes AI/OnDeviceLLM/OnDeviceLLMService.swift`
- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAIPromptGenerator.swift`
- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAIResponseParser.swift`
- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAISummarizationService.swift`
- `BisonNotes AI/BisonNotes AI/OpenAICompatibleSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/SummaryDetailView.swift`
- `BisonNotes AI/BisonNotes AI/Views/SettingsView.swift`
- `BisonNotes AI/BisonNotes AITests/BisonNotesAITests.swift`
- `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIAccessibilityTests.swift`

Several overlap this migration plan. Luna must not begin implementation in this checkout while those overlaps remain unresolved. The owner may later commit/preserve them, provide a clean branch/worktree, or explicitly assign their integration. Luna must not choose among those options without authorization.

### Current package baseline

The package graph resolved during review. Important pins include:

- Textual: branch `main`, revision `ad589638b23e80557aaf2fa959760feac643a1e1`;
- FluidAudio `0.15.5`;
- MLX Swift `0.31.3`;
- MLX Swift LM `2.31.3`;
- Swift Transformers `1.2.1`;
- Swift Concurrency Extras `1.4.0`;
- Swift NIO `2.100.0`.

Textual's moving `main` branch is a reproducibility risk, but this plan does not authorize changing it. Package upgrades, branch-to-version pinning, or patches to third-party source require owner approval and separate evidence that the current pin is an actual blocker.

## 3. Audit evidence and known initial diagnostics

The source review found approximately:

- 180 shared app Swift files and 221 Swift files across the inspected targets/tests;
- 83 files using `@MainActor`;
- 49 files containing `ObservableObject` state;
- 32 files using `DispatchQueue`;
- 13 files using checked continuations;
- 4 files using `Task.detached`;
- 3 files using `@unchecked Sendable`;
- 19 files using `@preconcurrency`.

A temporary Swift 6 diagnostic compile reached first-party app code and exposed these initial failure classes. They seed the work; they are not the complete diagnostic list:

1. `StartRecordingIntent.swift`: mutable static AppIntent metadata was rejected as unsafe shared global state.
2. `OpenAI/OpenAIModels.swift`: `ResponseFormat.json` was rejected because `ResponseFormat` is non-Sendable; its nested `JSONSchema` stores `[String: Any]`.
3. `Models/SummarizationEngine.swift`: `withTimeout<T>` uses `withThrowingTaskGroup` without a Sendable result/closure contract.
4. `Models/SummaryAttachmentStore.swift` and `Models/TranscriptManager.swift`: static shared instances expose non-Sendable global state.
5. `WhisperService.swift`: static default configurations contain a non-Sendable value type/protocol enum.
6. `ViewModels/AudioRecorderViewModel.swift` and its delegate extension: Swift 6 rejected the inferred Sendable/delegate conformance arrangement, exposing a larger actor-boundary decision.

A diagnostic attempt to apply project-wide default MainActor isolation also produced third-party SwiftNIO diagnostics. Do not use `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` as a project-wide shortcut.

### Primary external migration references

Use primary documentation, not blog/forum shortcuts, when a compiler behavior or setting is unclear:

- Swift migration guide: <https://www.swift.org/migration/>
- Swift 6 migration strategy: <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/migrationstrategy/>
- Incremental concurrency adoption: <https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/>
- Apple's Swift 6 adoption guidance: <https://developer.apple.com/documentation/swift/adoptingswift6>
- Apple's Xcode build-settings reference: <https://developer.apple.com/documentation/Xcode/build-settings-reference>

Repository instructions and the pinned toolchain/package graph control the concrete implementation. If current compiler behavior differs from a referenced example, capture the exact diagnostic and toolchain version in the evidence report.

## 4. Non-negotiable implementation rules

1. The lead agent owns branch/worktree state, `project.pbxproj`, package resolution, shared-interface decisions, build serialization, integration, and final reporting.
2. A subagent edits only its assigned files. If a diagnostic requires another package's file, stop and request a lead-mediated ownership handoff.
3. No two active agents may edit the same production file or test file.
4. Preserve behavior. Do not combine concurrency migration with provider redesign, UI redesign, persistence migration, cleanup, formatting churn, or unrelated warning repair.
5. Prefer declarations that state the true ownership model: `@MainActor` for UI-owned state, actors for independently mutable services, immutable Sendable values for transferred data, and narrow `nonisolated` delegate entry points that immediately hand off typed values.
6. Do not add `@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`, or unsafe global-state suppression as a quick compiler fix. Any new unsafe escape requires owner approval, a written invariant, call-site evidence, and focused tests.
7. Existing `@unchecked Sendable` and `@preconcurrency` uses may remain only after explicit review. The evidence report must list each retained instance, its synchronization/interop rationale, and the tests or platform limitation supporting it.
8. Do not blanket-wrap work in `MainActor.run` when the owning type should declare its isolation. Do not dispatch to the main queue as a substitute for a coherent actor contract.
9. Do not move AVFoundation, ScreenCaptureKit, URLSession delegate, Core Location, WatchConnectivity, CloudKit, or Core Data objects across actors unless the framework contract and object lifetime make that safe.
10. Do not pass `NSManagedObject`, `NSManagedObjectContext`, framework delegate objects, `[String: Any]`, or mutable reference models through `@Sendable` closures. Pass Sendable values, stable identifiers, or actor-owned operations instead.
11. Every checked continuation must resume exactly once on success, error, cancellation, and delegate teardown. Add focused cancellation/error tests when behavior changes.
12. Do not change deployment targets, entitlements, privacy declarations, Core Data schemas, iCloud record formats, or persisted preference keys unless the owner approves an expanded scope.
13. Do not upgrade packages or edit `Package.resolved` to silence a cache or DerivedData problem. Resolve packages once, use unique DerivedData paths, and distinguish cache failure from source incompatibility.
14. Never make a writable diagnostic copy whose source folders are symlinked back into the real checkout. Use a real authorized worktree/copy or read-only command-line diagnostics. Verify `git status` after every diagnostic patch or scripted rewrite.
15. Do not regenerate the SwiftLint baseline. Compare before/after totals and changed-file findings.
16. Do not commit, push, create a PR, create/delete a branch, rotate credentials, rewrite history, or change repository settings without explicit owner authorization.
17. If commits are later authorized, keep one reviewed logical package per commit, stage only intended files, and include `Co-authored-by: OpenAI Codex <codex@openai.com>` unless the owner opts out.

## 5. Required report from every subagent

Each subagent must return this exact structure:

```text
Work package:
Owned files actually touched:
Compiler diagnostics addressed:
Isolation/Sendable decision and why it is true:
Behavior intentionally changed:
Call-site and target-membership evidence:
Tests added or updated:
Commands run and exact result:
Unsafe annotations added or retained:
Risks or assumptions:
Unresolved items / requested ownership handoff:
```

“Done,” “builds,” or “should pass” is not an acceptable report. The lead reads each diff and reproduces critical diagnostics/checks before accepting it.

## 6. Target inventory and final migration order

| Order | Target | Configurations | Primary validation |
|---:|---|---|---|
| 1 | `BisonNotes AI` | Debug, Release | iOS Simulator build and full iOS test plan |
| 2 | `BisonNotes AITests` | Debug, Release | Executed XCTest, not compile-only |
| 3 | `BisonNotes AIUITests` | Debug, Release | Seeded UI smoke and accessibility audits |
| 4 | `BisonNotes AI macOS` | Debug, Release | Native macOS build, archive later in RC gate |
| 5 | `BisonNotes AI Watch App` | Debug, Release | Watch simulator tests/build |
| 6 | `BisonNotes AI Watch AppTests` | Debug, Release | Executed Watch XCTest |
| 7 | `BisonNotes AI Watch AppUITests` | Debug, Release | Watch UI launch coverage when available |
| 8 | `BisonNotes AI ControlsExtension` | Debug, Release | Generic iOS extension build and host integration |
| 9 | `BisonNotes Share` | Debug, Release | Generic iOS/share-host build and manual import smoke |
| 10 | `BisonNotes Watch WidgetExtension` | Debug, Release | Generic watchOS/widget build |
| 11 | `BisonNotes Mac Widget` | Debug, Release | Native macOS widget build/host inspection |
| 12 | `BisonNotes Share macOS` | Debug, Release | Native macOS share extension build/manual smoke |

The lead migrates one target pair at a time after shared source is green. Do not perform a single global Swift 6 flip and then distribute an unclassified error flood.

## 7. Wave 0 — Lead-only read-only baseline and scope lock

Do not delegate implementation until this wave is complete.

### Repository and ownership baseline

- [ ] Read this plan, `AGENTS.md`, `CLAUDE.md`, and `docs/testing-regimen.md` completely.
- [ ] Run `git status --short --branch`.
- [ ] Record `git rev-parse HEAD`, `git branch --show-current`, upstream, and `git worktree list --porcelain`.
- [ ] Compare the live dirty set with section 2. If any required file is dirty, stop. Do not stash/reset/checkout over it.
- [ ] Create `codex/swift-6-migration` or another branch only if the owner explicitly authorizes branch creation and identifies the starting commit.
- [ ] Run `git diff --check` and save the exact result.
- [ ] Record `xcodebuild -version`, `xcrun swift --version`, selected developer directory, and SDK versions.
- [ ] Inventory all 12 targets and available schemes with `xcodebuild -list`.
- [ ] Capture the effective `SWIFT_VERSION`, `SWIFT_STRICT_CONCURRENCY`, `SWIFT_APPROACHABLE_CONCURRENCY`, `SWIFT_DEFAULT_ACTOR_ISOLATION`, and upcoming-feature settings for every target/configuration using `xcodebuild -showBuildSettings` or a deterministic project-file audit.
- [ ] Verify the 24 expected `SWIFT_VERSION = 5.0` settings and record any drift.
- [ ] Record the current package pins and whether package resolution uses the committed `Package.resolved` without mutation.

### Baseline static/build/test evidence

- [ ] From `BisonNotes AI/BisonNotes AI`, run `swiftlint lint --reporter summary` and save counts. Existing baseline findings are not new regressions.
- [ ] Run the current local pre-merge gate from `docs/testing-regimen.md` in Swift 5 mode.
- [ ] Build the native macOS scheme in Swift 5 mode.
- [ ] Run/build the Watch scheme in Swift 5 mode.
- [ ] If dependencies need resolution, resolve once with a clean, unique DerivedData/SourcePackages location; subsequent diagnostic builds should use `-disableAutomaticPackageResolution` where practical.
- [ ] Classify every failure as baseline source, package/cache, simulator/service, signing/CloudKit bootstrap, hardware/manual, or unknown.

### Wave 0 stop conditions

Stop and ask the owner if:

- the checkout is dirty in an owned file;
- the intended base branch/commit is ambiguous;
- a branch or worktree is needed but not authorized;
- baseline tests/builds fail and the failure cannot be classified confidently;
- package resolution changes `Package.resolved` unexpectedly;
- a required Xcode destination is unavailable and no equivalent supported destination is approved.

## 8. Wave 1 — Lead-owned strict-concurrency diagnostic ledger

The lead owns `BisonNotes AI/BisonNotes AI.xcodeproj/project.pbxproj` throughout the migration.

### Staged setting procedure

1. Keep `SWIFT_VERSION = 5.0`.
2. Enable `SWIFT_STRICT_CONCURRENCY = complete` for the main iOS app's Debug and Release configurations.
3. Build the main iOS target with a unique DerivedData path and capture the complete concurrency diagnostics.
4. Categorize every first-party diagnostic by work package and file. Record third-party diagnostics separately.
5. Add the iOS test targets to strict checking only after app-source diagnostics are categorized.
6. Repeat this strict-in-Swift-5 staging for native macOS, Watch, and extensions only after their shared source dependencies are green.
7. Use an isolated real worktree/copy for any exploratory Swift 6 compile. Never apply temporary compiler workarounds to the production checkout merely to expose the next error.

Create and maintain `docs/swift-6-migration-evidence.md` during implementation. It must record:

- baseline branch, commit, toolchain, settings, package pins, lint counts, builds, and tests;
- each diagnostic category and owning package;
- actor/Sendable decisions that affect public interfaces;
- every added or retained unsafe/preconcurrency annotation;
- per-package commands/results;
- final target-by-target settings/build/test matrix;
- manual/signed/hardware/CloudKit checks as passed, failed, blocked, or pending.

Do not edit source in Wave 1 except for the lead-owned project setting change and the evidence report.

## 9. Delegation and sequencing map

| Package | May start | May run in parallel with | Must finish before | Exclusive shared-file warning |
|---|---|---|---|---|
| A — value contracts and global immutability | After Wave 1 | None initially | B, C, D, E, F | Freezes shared Sendable/value contracts |
| B — UI/provider/global actor ownership | After A | C1, D | E | Owns provider services and UI-bound singleton state |
| C1 — persistence and file-store isolation | After A | B, D | C2, E | Owns Core Data and attachment/transcript stores |
| C2 — iCloud/summary concurrency | After C1 | B or D if files remain disjoint | E and final gate | Owns `iCloudStorageManager.swift` and `SummaryManager.swift` |
| D — networking/import/export async bridges | After A | B, C1/C2 | E and final gate | Owns URLSession/Wyoming/import/export continuation files |
| E — audio/transcription/background real-time boundary | After A+B+C+D interfaces freeze | None | F and target flips | Owns recorder, audio session, transcription, FluidAudio, background processing |
| F — platform UI, Watch, widgets, controls, share | After E shared build is green | None | Final target flips | Owns remaining platform/UI async diagnostics and UI/Watch tests |
| Lead — project/settings/docs/integration | Throughout | Coordinates all | Final | Sole owner of project file, package file, evidence, README, regimen |

Only B, C1, and D are intended for parallel execution, and only after A's interfaces are reviewed and frozen. Xcode builds/package resolution should be serialized by the lead even while static work runs in parallel.

## 10. Package A — value contracts, immutable statics, and generic Sendable boundaries

### Exclusive production files

- `BisonNotes AI/BisonNotes AI/StartRecordingIntent.swift`
- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAIModels.swift`
- `BisonNotes AI/BisonNotes AI/Models/SummarizationEngine.swift`
- `BisonNotes AI/BisonNotes AI/Models/AudioModels.swift`
- `BisonNotes AI/BisonNotes AI/Models/DeviceCompatibility.swift`
- Additional pure model/type files only after lead approval

### Exclusive tests

- New `BisonNotes AI/BisonNotes AITests/Swift6ValueSemanticsTests.swift`
- Existing focused model tests only after the lead assigns exclusive ownership

### Tasks

- [ ] Convert AppIntent metadata that is semantically immutable from `static var` to `static let` and verify AppIntent extraction/phrases remain intact.
- [ ] Make pure value types genuinely Sendable when all stored fields support it; include related enums such as protocol/method identifiers.
- [ ] Redesign `ResponseFormat`/`JSONSchema` so structured JSON does not rely on an unchecked `[String: Any]` crossing a concurrency boundary. Preserve exact Codable wire output and call-site behavior.
- [ ] Tighten `withTimeout` and similar task-group helpers with compiler-proven Sendable result and closure contracts. Preserve cancellation, timeout, and underlying error behavior.
- [ ] Replace mutable static device-compatibility cache/log flags with immutable computation, an actor, or a narrowly synchronized store. Do not add a global unsafe annotation.
- [ ] Search all call sites before changing public initializers or generic signatures.

### Required tests/evidence

- Codable round-trip and encoded JSON equivalence for response-format structures.
- Timeout helper: success, operation error, timeout, cancellation, and no leaked child task.
- Device compatibility: deterministic cached/uncached result and one-time log behavior without races.
- AppIntent source/build inspection and final metadata extraction in the native Mac release gate.
- Strict-concurrency diagnostics in owned files reduced to zero without an unsafe escape.

### Stop conditions

Stop if the JSON redesign requires broad provider parsing/prompt changes, if changing a generic contract requires another active package's file, or if an SDK type cannot safely become Sendable without an adapter type.

## 11. Package B — UI/provider state and global actor ownership

### Exclusive production files

- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAISummarizationService.swift`
- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAIPromptGenerator.swift`
- `BisonNotes AI/BisonNotes AI/OpenAI/OpenAIResponseParser.swift`
- `BisonNotes AI/BisonNotes AI/GoogleAIStudioService.swift`
- `BisonNotes AI/BisonNotes AI/OllamaService.swift`
- `BisonNotes AI/BisonNotes AI/OpenAICompatibleSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/AISettingsView.swift`
- `BisonNotes AI/BisonNotes AI/MLXSwiftEngine.swift`
- `BisonNotes AI/BisonNotes AI/OnDeviceAIDownloadMonitor.swift`
- Files under `BisonNotes AI/BisonNotes AI/OnDeviceLLM/`
- `BisonNotes AI/BisonNotes AI/ErrorHandlingSystem.swift`
- `BisonNotes AI/BisonNotes AI/LocationManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/UserPreferences.swift`
- `BisonNotes AI/BisonNotes AI/EnhancedFileManager.swift`

### Exclusive tests

- New `BisonNotes AI/BisonNotes AITests/Swift6ProviderIsolationTests.swift`
- Existing provider regression tests only when assigned exclusively by the lead

### Tasks

- [ ] Classify each type as UI-owned state, independently mutable service state, or immutable request configuration before annotating it.
- [ ] Mark UI-observed mutable state `@MainActor` where true; remove redundant main-queue dispatch only after actor isolation makes it redundant.
- [ ] Separate immutable Sendable request snapshots from UI configuration wrappers when network/model work must run away from MainActor.
- [ ] Protect `OllamaService.requestCounter`, on-device logging configuration, and similar mutable statics through real synchronization/actor ownership.
- [ ] Move LocationManager's global geocoding cache/pending-request state behind one coherent actor or main-actor contract. Preserve delegate behavior, cache semantics, and completion ordering.
- [ ] Ensure ErrorHandler and UserPreferences publish changes from their declared actor.
- [ ] Audit every Task/closure capture introduced by the actor changes; use typed Sendable values instead of capturing mutable service instances.
- [ ] Preserve provider URLs, payloads, model selection, retries, streaming behavior, credentials, prompts, response parsing, and user-visible errors.

### Required tests/evidence

- Provider configuration snapshot and request routing without live network calls.
- Ollama/request counter concurrency test or deterministic synchronization evidence.
- Location cache: duplicate-request coalescing, success, error, cancellation/teardown, and main-actor publication.
- UserPreferences and error publication from non-main callers through the declared contract.
- Existing provider regression tests remain green.

### Stop conditions

Stop if provider behavior/payloads must change, a credential migration is implicated, a third-party model API requires unsafe Sendable conformance, or a file overlaps unresolved user work.

## 12. Package C1 — Core Data, transcript, and attachment-store isolation

### Exclusive production files

- `BisonNotes AI/BisonNotes AI/Persistence.swift`
- `BisonNotes AI/BisonNotes AI/Models/CoreDataManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/AppDataCoordinator.swift`
- `BisonNotes AI/BisonNotes AI/Models/TranscriptManager.swift`
- `BisonNotes AI/BisonNotes AI/Models/SummaryAttachmentStore.swift`
- `BisonNotes AI/BisonNotes AI/Models/DataMigrationManager.swift` only if diagnostics require it
- `BisonNotes AI/BisonNotes AI/Models/RecordingWorkflowManager.swift` only if diagnostics require it

### Exclusive tests

- New `BisonNotes AI/BisonNotes AITests/Swift6PersistenceIsolationTests.swift`
- Relevant integration tests only after exclusive assignment by the lead

### Tasks

- [ ] Align `PersistenceController.shared`, CoreDataManager, AppDataCoordinator, and TranscriptManager under a coherent Core Data actor/context contract.
- [ ] Remove direct unisolated Core Data access from TranscriptManager.
- [ ] Do not pass `NSManagedObject` or `NSManagedObjectContext` across actor boundaries. Use IDs, values, or actor-owned fetch/update operations.
- [ ] Isolate SummaryAttachmentStore's mutable file/encoder/decoder operations with an actor or proven serialization design. Do not add unchecked Sendable as the implementation.
- [ ] Preserve synchronous API behavior only when it remains race-free; otherwise propose an explicit async call-site migration to the lead before expanding ownership.
- [ ] Preserve current persistence formats, URLs, IDs, migration behavior, attachment encoding, and error semantics.

### Required tests/evidence

- Create/fetch/update/delete through the authoritative coordinator.
- Concurrent transcript/attachment operations serialize without duplication, corruption, or cross-context access.
- Existing migration and integration tests remain green.
- No schema/model version change and no CloudKit network mutation in ordinary tests.
- Strict-concurrency diagnostics in owned files reduced to zero.

### Stop conditions

Stop if a Core Data schema migration appears necessary, if a public synchronous API cannot remain safe without broad call-site changes, or if the fix would alter iCloud record behavior before C2 owns it.

## 13. Package C2 — iCloud and summary concurrency

Start only after C1 is integrated and its actor/API contract is frozen.

### Exclusive production files

- `BisonNotes AI/BisonNotes AI/iCloudStorageManager.swift`
- `BisonNotes AI/BisonNotes AI/SummaryManager.swift`
- Summary-related coordinator files only through a formal handoff from C1

### Exclusive tests

- `BisonNotes AI/BisonNotes AITests/ICloudBackupRegressionTests.swift`
- A new package-specific concurrency test file if the existing file is occupied

### Tasks

- [ ] Audit every CloudKit checked continuation for exactly-once resume, error, cancellation, and teardown.
- [ ] Keep CloudKit/database objects within their valid ownership boundary; convert callback results to Sendable app-owned values before actor handoff.
- [ ] Preserve pending mutation queues, deletion markers, restore/upsert behavior, local-only exclusions, and summary identity.
- [ ] Keep SummaryManager's UI-observed state and Core Data/iCloud calls aligned with the C1 contract.
- [ ] Do not change cloud record schemas, container identifiers, conflict policy, backup eligibility, or migration behavior.

### Required tests/evidence

- Existing iCloud backup regression suite runs without live CloudKit mutation.
- Continuation success/error/cancellation paths are deterministic and resume once.
- Deleted summaries do not resurrect; restores/upserts do not duplicate data.
- CloudKit bootstrap/signing limitations are reported separately from compilation and executed tests.

### Stop conditions

Stop if a CloudKit schema/container change appears necessary, if tests require real account data, or if a concurrency fix changes merge/conflict/deletion semantics.

## 14. Package D — networking, imports, exports, and async bridge safety

### Exclusive production files

- `BisonNotes AI/BisonNotes AI/BoundedWebImportTransfer.swift`
- `BisonNotes AI/BisonNotes AI/WebImportManager.swift`
- `BisonNotes AI/BisonNotes AI/YouTubeImportService.swift`
- `BisonNotes AI/BisonNotes AI/FileImportManager.swift`
- `BisonNotes AI/BisonNotes AI/PerformanceOptimizer.swift`
- `BisonNotes AI/BisonNotes AI/Wyoming/WyomingTCPClient.swift`
- `BisonNotes AI/BisonNotes AI/Wyoming/WyomingWebSocketClient.swift`
- `BisonNotes AI/BisonNotes AI/Wyoming/WyomingWhisperClient.swift`
- `BisonNotes AI/BisonNotes AI/Wyoming/WyomingProtocol.swift`
- `BisonNotes AI/BisonNotes AI/Services/PDFExportService.swift`
- `BisonNotes AI/BisonNotes AI/Services/MacSummaryExportMaps.swift`

### Exclusive tests

- New `BisonNotes AI/BisonNotes AITests/Swift6AsyncBridgeTests.swift`
- Existing web/import/Wyoming tests only after exclusive assignment

### Tasks

- [ ] Audit BoundedWebImportTransfer's lock-protected state and existing `@unchecked Sendable` conformance. Make closure contracts Sendable where true and document the exact lock/lifetime invariant if the conformance must remain.
- [ ] Ensure URLSession delegate callbacks update one synchronized owner and resume their continuation once.
- [ ] Audit Wyoming actors, detached tasks, sockets, continuations, reconnects, and cancellation. Do not capture mutable clients unsafely.
- [ ] Convert MapKit/export callback results into actor-safe values before UI publication.
- [ ] Preserve import size limits, redirects, temporary-file cleanup, network errors, Wyoming framing/protocol behavior, PDF/RTF output, and map fallbacks.
- [ ] Use injected sessions/fakes and temporary directories; ordinary tests must not contact live services.

### Required tests/evidence

- URLSession success, redirect, too-large response, write failure, cancellation, and delegate teardown.
- Wyoming connect/send/receive/error/cancel/reconnect behavior with a local fake transport.
- Export/map completion, error, and cancellation with deterministic stubs where possible.
- No continuation leak/double-resume under repeated cancellation.
- Existing `@unchecked Sendable` retention, if any, documented in the evidence report.

### Stop conditions

Stop if a network protocol or output format must change, a live service is required for ordinary tests, or safe isolation requires another active package's stateful manager.

## 15. Package E — audio, transcription, diarization, and background real-time boundaries

This is the highest-risk package. Start only after A, B, C, and D interfaces are reviewed and frozen. Use one subagent or a strictly sequential internal handoff; do not split the recorder extensions among simultaneous agents.

### Exclusive production files

- `BisonNotes AI/BisonNotes AI/ViewModels/AudioRecorderViewModel.swift`
- Every `BisonNotes AI/BisonNotes AI/ViewModels/AudioRecorderViewModel+*.swift` extension
- `BisonNotes AI/BisonNotes AI/EnhancedAudioSessionManager.swift`
- `BisonNotes AI/BisonNotes AI/ViewModels/MacSystemAudioCapture.swift`
- `BisonNotes AI/BisonNotes AI/Models/MacRecordingReliability.swift`
- `BisonNotes AI/BisonNotes AI/LiveTranscriptionService.swift`
- `BisonNotes AI/BisonNotes AI/EnhancedTranscriptionManager.swift`
- `BisonNotes AI/BisonNotes AI/AudioFileChunkingService.swift`
- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift`
- `BisonNotes AI/BisonNotes AI/WhisperService.swift`
- `BisonNotes AI/BisonNotes AI/MistralTranscribeService.swift`
- Relevant files under `BisonNotes AI/BisonNotes AI/FluidAudio/`

### Exclusive tests

- `BisonNotes AI/BisonNotes AITests/AudioTranscriptionRegressionTests.swift`
- Existing local diarization alignment/orchestration/model/persistence tests
- New `BisonNotes AI/BisonNotes AITests/Swift6AudioConcurrencyTests.swift`
- Other audio tests only after lead verifies exclusive ownership

### Required design checkpoint before edits

Return a short design note to the lead answering:

- Which state is UI-owned and therefore MainActor-isolated?
- Which AVFoundation/ScreenCaptureKit delegate methods must be `nonisolated`?
- What Sendable value is handed from each real-time callback to the owner?
- Which state remains lock-protected because it is touched on a real-time callback thread?
- How are cancellation, first-buffer gating, interruption recovery, device switching, source-track salvage, and finalization ordered?
- Why no new unchecked/unsafe annotation is needed, or what exact approved invariant justifies one?

Do not begin implementation until the lead accepts this boundary.

### Tasks

- [ ] Establish coherent isolation for AudioRecorderViewModel and all of its delegate conformances/extensions. Do not make a non-final mutable view model Sendable merely to satisfy a protocol diagnostic.
- [ ] Keep real-time AVAudio/ScreenCapture callbacks lightweight and deterministic. Hand off typed values without unbounded main-actor work or copied framework objects.
- [ ] Preserve first-buffer recording-state gating, interruption handling, microphone reconnection, no-mic timeout, Bluetooth/USB transitions, raw-track retention, system/microphone mixing, salvage, and finalization.
- [ ] Align EnhancedAudioSessionManager's notification callbacks with actor isolation; extract typed Sendable metadata rather than passing `[AnyHashable: Any]` across actors.
- [ ] Audit checked continuations in live/enhanced transcription for exactly-once behavior and cancellation.
- [ ] Make Whisper configuration/protocol values Sendable where genuine while preserving endpoint and request behavior.
- [ ] Preserve Parakeet complete-source reassembly and the single post-ASR local-diarization pass. Do not create another reassembly path or corrupt canonical ASR text.
- [ ] Keep BackgroundProcessingManager MainActor/UI state separate from long-running provider/transcription work without changing job ordering, retry, cancellation, or persistence behavior.
- [ ] Review `RecordingCaptureHealth`'s existing `@unchecked Sendable` lock invariant and retain it only with evidence.

### Required automated evidence

- Audio/transcription regression and local-diarization suites pass.
- Start/stop/cancel/interruption/reconnection/finalization state transitions are deterministic under tests/fakes.
- Delegate callbacks cannot mutate UI-published state off its actor.
- Continuations resume once under success/error/cancellation.
- Complete-source ASR reassembly and canonical-text reconciliation remain unchanged.
- Main iOS and native macOS targets build with strict concurrency after this package.

### Required manual evidence before release acceptance

- Physical iPhone/iPad microphone recording, interruption/backgrounding, playback, and transcription.
- Native Mac microphone-only and meeting/system-audio recording, device changes, no-input stall, track salvage, and finalization/recovery.
- Parakeet/local speaker labels on physical supported devices, including safe unlabeled fallback.
- Provider/streaming cancellation and background job behavior.

### Stop conditions

Stop if a concurrency fix changes audio timing/order, requires removing raw-track recovery, risks real-time callback blocking, alters transcript identity/reassembly, requires a new `@unchecked Sendable`/`nonisolated(unsafe)` waiver, or cannot be validated on the relevant platform.

## 16. Package F — platform UI, Watch, widgets, controls, and share extensions

Start after E's shared iOS/macOS build is green.

### Exclusive production areas

- `BisonNotes AI/BisonNotes AI/SummaryDetailView.swift`
- `BisonNotes AI/BisonNotes AI/Views/SettingsView.swift`
- `BisonNotes AI/BisonNotes AI/Platform/PlatformApp.swift`
- `BisonNotes AI/BisonNotes AI/AppDelegate.swift`
- `BisonNotes AI/BisonNotes AI/ActionButtonLaunchManager.swift`
- `BisonNotes AI/BisonNotes AI/WatchConnectivity/WatchConnectivityManager.swift`
- `BisonNotes AI/BisonNotes AI Watch App/`
- `BisonNotes AI/BisonNotes AI Controls/`
- `BisonNotes AI/BisonNotes Share/`
- `BisonNotes AI/BisonNotes AI Watch Widget/`
- `BisonNotes AI/BisonNotes Mac Widget/`
- `BisonNotes AI/BisonNotes Share macOS/`
- Shared Share Support files only after target-membership verification

### Exclusive tests

- `BisonNotes AI/BisonNotes AIUITests/`
- `BisonNotes AI/BisonNotes AI Watch AppTests/`
- `BisonNotes AI/BisonNotes AI Watch AppUITests/`
- New platform-specific unit tests only after lead assignment

### Tasks

- [ ] Audit `Task.detached` in SummaryDetailView, Settings, and WatchLocationManager. Transfer immutable Sendable values and return results to the correct actor.
- [ ] Review MapSnapshotCache and PlatformApp.ActivityRegistry's existing synchronization/unchecked Sendable invariants.
- [ ] Align WatchConnectivity delegates and Watch observable state with explicit actor/nonisolated boundaries.
- [ ] Resolve extension-specific strict-concurrency diagnostics without changing host-extension contracts, app groups, intents, widget timelines, or share import behavior.
- [ ] Preserve Summary detail layout/scroll behavior and Settings behavior; concurrency migration is not authorization for UI redesign.
- [ ] Keep visible content-level modal dismissal and existing accessibility behavior intact.

### Required tests/evidence

- Seeded UI smoke tests and accessibility audits pass.
- Watch unit/UI tests and metadata transfer behavior pass.
- Controls/AppIntent starts exactly one recording when the app is closed or already active.
- iOS/macOS share import and widget/control builds pass.
- Native Mac minimum/wide window and modal dismissal checks remain green.

### Stop conditions

Stop if an extension entitlement/app-group change is proposed, if target membership is unclear, if UI work overlaps unresolved owner changes, or if a platform SDK protocol appears to require a new unsafe waiver.

## 17. Lead-only final target migration and documentation

After Packages A-F are reviewed and strict-in-Swift-5 diagnostics are resolved:

1. Set `SWIFT_VERSION = 6.0` for the main iOS target's Debug and Release configurations.
2. Build and execute its tests before moving on.
3. Migrate the native macOS target pair and build it.
4. Migrate Watch app/test/UI target pairs and run/build them.
5. Migrate controls, share, and widget target pairs and build each host/extension combination.
6. Migrate iOS unit/UI test target pairs if not already migrated.
7. Confirm all 24 first-party configurations resolve to Swift 6 and none remain Swift 5.
8. Re-run every relevant strict diagnostic. Swift 6 concurrency errors must be zero in first-party code.
9. Keep, normalize, or remove explicit `SWIFT_STRICT_CONCURRENCY = complete` consistently based on the proven Xcode build behavior; Swift 6 mode itself remains mandatory.
10. Do not globally add `SWIFT_DEFAULT_ACTOR_ISOLATION`. Preserve existing `SWIFT_APPROACHABLE_CONCURRENCY`/upcoming-feature settings unless a reviewed target-specific decision changes them.

Only after the automated target matrix is green:

- update the README Swift badge from 5.0 to 6;
- determine and document the minimum Xcode version actually required by Swift language mode and pinned package manifests; do not guess;
- update `CLAUDE.md` if the actor/concurrency architecture changed materially;
- update `docs/testing-regimen.md` with a durable Swift 6 verification gate if commands/settings differ from the existing regimen;
- do not retroactively rewrite historical release documents merely to change a language-version badge.

## 18. Per-package validation

Every package runs static checks before handoff:

```bash
git diff --check
cd "BisonNotes AI/BisonNotes AI"
swiftlint lint --reporter summary
```

Also:

- compare full lint counts to Wave 0 and run focused lint on changed files;
- verify only assigned files changed with `git status --short` and `git diff --name-only`;
- inspect changed files for unused declarations, duplicate helpers, stale commented implementation, placeholder behavior, secrets, PHI, and broad formatting churn;
- search for newly added `@unchecked Sendable`, `nonisolated(unsafe)`, and `@preconcurrency` and document every result;
- run the package's focused tests, then have the lead run a serialized main iOS strict-concurrency build.

Representative iOS aggregate command:

```bash
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-ios-derived
```

Representative native Mac build:

```bash
xcodebuild \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI macOS" \
  -destination 'platform=macOS' \
  -configuration Debug \
  -derivedDataPath /private/tmp/bisonnotes-swift6-macos-derived \
  build
```

Representative Watch test:

```bash
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI Watch App" \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-watch-derived
```

Confirm exact destinations and test identifiers at execution time. A successful compile is not proof that XCTest executed. Unsigned builds are not signed-app/hardware validation.

## 19. Final automated and manual acceptance gate

### Project/settings proof

- [ ] `rg -n 'SWIFT_VERSION = 5\.0;' "BisonNotes AI/BisonNotes AI.xcodeproj/project.pbxproj"` returns no first-party configuration.
- [ ] `rg -c 'SWIFT_VERSION = 6\.0;' "BisonNotes AI/BisonNotes AI.xcodeproj/project.pbxproj"` reports the expected 24 configurations.
- [ ] Effective `xcodebuild -showBuildSettings` confirms Swift 6 for every target/configuration.
- [ ] `Package.resolved` is unchanged unless an owner-approved dependency action was required.
- [ ] Deployment targets, entitlements, privacy declarations, Core Data schemas, and cloud identifiers are unchanged unless separately approved.

### Automated proof

- [ ] `git diff --check` passes.
- [ ] SwiftLint introduces no new findings relative to Wave 0.
- [ ] First-party Swift 6 concurrency diagnostics are zero across all target builds.
- [ ] Main iOS unit/UI/accessibility tests execute and pass.
- [ ] Native macOS Debug build passes; archive is performed at the release-candidate gate.
- [ ] Watch unit/build gate passes.
- [ ] Controls, share, and widget extension builds pass for their supported platforms.
- [ ] Provider, persistence, iCloud-fake, import/export, recording/transcription, and local-diarization regression suites pass.
- [ ] Retained `@unchecked Sendable` and `@preconcurrency` uses are enumerated with rationale; no unapproved unsafe annotation was added.

### Manual/release-candidate proof

Follow `docs/testing-regimen.md` and report separately:

- physical iPhone/iPad microphone, interruption/background, playback, and transcription;
- native Mac microphone/system-audio capture, device switching, stalls, salvage, recovery, and window/modal behavior;
- Watch recording/transfer;
- Parakeet/local speaker labels and canonical-text fallback;
- provider streaming/cancellation and local provider availability;
- iCloud two-device behavior and local-only exclusions;
- iOS/macOS share imports, widgets, Control Center, Action Button/AppIntent;
- VoiceOver, Voice Control, keyboard access, Dynamic Type, and native Mac accessibility/layout.

Do not label pending signed-app, hardware, CloudKit, provider-service, or manual evidence as passed because compilation/tests succeeded.

## 20. Lead integration checklist

After each subagent returns:

- [ ] Read the complete diff; do not accept the summary alone.
- [ ] Confirm only assigned files changed.
- [ ] Re-run critical call-site and unsafe-annotation searches.
- [ ] Confirm the declared actor/Sendable model is true at every entry point.
- [ ] Reject blanket MainActor, broad unsafe conformance, unrelated cleanup, formatting churn, or behavior redesign.
- [ ] Run focused checks before accepting the package.
- [ ] Update the diagnostic/evidence ledger and reassign remaining diagnostics.
- [ ] Freeze shared interfaces before starting a dependent package.
- [ ] If commits are authorized, keep package history reviewable and record exact SHAs.

## 21. Stop conditions and owner-only decisions

Stop and ask the owner before continuing if:

- worktree changes overlap an owned file or two packages need the same file;
- a new `@unchecked Sendable`, `nonisolated(unsafe)`, or broad `@preconcurrency` waiver is proposed;
- project-wide default actor isolation is proposed;
- a package upgrade, package patch, Textual pinning change, or new dependency appears necessary;
- a deployment target, entitlement, privacy declaration, Core Data schema, CloudKit schema/container, app-group, or persisted-data format must change;
- recording timing, device-recovery behavior, reassembly, canonical transcript text, provider payloads, iCloud conflict behavior, or user-visible UI behavior would change;
- a compiler/build failure cannot be classified as baseline, first-party migration, third-party incompatibility, cache/environment, signing/CloudKit bootstrap, or simulator/hardware;
- required hardware/signed-app evidence is unavailable for a release claim.

Owner-only decisions include:

- branch/worktree creation and the base commit;
- acceptance of any unsafe concurrency waiver;
- dependency upgrades or pin changes;
- deployment/platform support changes;
- whether pending manual gates are sufficient for a particular release stage;
- commit, push, PR, release-note, App Store, and publication authorization.

## 22. Final deliverable from Luna

Luna's final response must include:

1. baseline branch/commit/toolchain/settings/package evidence;
2. packages implemented, skipped, or blocked;
3. files changed by package;
4. actor/Sendable architecture decisions;
5. added and retained unsafe/preconcurrency annotations with rationale;
6. exact build/test/lint commands and results;
7. target-by-target Swift 6 settings/build matrix;
8. signed-app, hardware, CloudKit, provider-service, and manual checks separated from automated proof;
9. remaining risks and owner decisions;
10. exact commit and remote SHAs only if delivery was separately authorized.
