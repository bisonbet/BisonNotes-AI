# Local Speaker Labels Delegation Plan

This file is the implementation source of truth for optional, local speaker labels on completed Parakeet transcriptions. It is written for GPT-5.6 Luna acting as integration lead and delegating bounded work packages to subagents.

## Copy/paste kickoff prompt for Luna

```text
Work in /Users/champ/Sources/BisonNotes-AI. Read AGENTS.md, CLAUDE.md, docs/testing-regimen.md, and docs/local-speaker-labels-delegation-plan.md completely before taking any implementation action. Treat the local-speaker-labels plan as the source of truth.

Begin with Wave 0 exactly as written and report the current branch, HEAD, worktree state, and baseline validation before editing. You are the integration lead: enforce the ownership table, give every subagent only its bounded package, and do not allow two agents to edit the same file. Packages A and B may start in parallel; C starts after A and B contracts are reviewed; D may run alongside C only after the settings/model interface is frozen; E starts after product names and behavior are stable. Integrate and review one package at a time.

Implement only opt-in, post-recording local speaker labels for Parakeet: Offline VBx is Recommended, and LS-EEND DIHARD3 is Experimental with support for up to 10 speakers. Default the feature off. Run diarization once on the complete source audio after ASR, never independently per ASR chunk. Preserve an unlabeled Parakeet transcript with a visible warning if speaker labeling fails. Leave all Mistral behavior/settings/files and all real-time transcription behavior/files unchanged. Do not add a cloud fallback, silently download models during transcription, upgrade FluidAudio, lower deployment targets, add entitlements, or introduce a second transcript reassembly path.

Require each subagent to return the exact report defined in the plan. Review diffs, call-site evidence, tests, logs, privacy, cache isolation, and cancellation behavior incrementally. Run the focused and aggregate gates in the plan, and distinguish automated simulator/build evidence from physical-device, signed-app, performance, and manual accessibility gates.

Do not commit, push, open a PR, rotate credentials, rewrite history, change GitHub settings, or publish documentation unless I explicitly authorize that separately. Stop and ask for direction if the plan's stop conditions are reached.
```

## 1. Outcome and product contract

Add an optional **Local Speaker Labels** control to the existing On Device / Parakeet settings on iOS and native macOS.

The user-visible choices are:

1. **Off** — default; current Parakeet behavior remains unchanged.
2. **Offline VBx — Recommended** — the normal local speaker-labeling choice. It estimates speaker count rather than imposing an app-side two- or three-speaker cap.
3. **LS-EEND — Experimental** — the higher-speaker-count choice, fixed initially to FluidAudio's DIHARD3 500 ms model, supporting up to 10 speakers. It may over-segment speakers or produce less-stable labels and must be visibly marked Experimental, not by color alone.

Speaker labels apply only after a completed Parakeet recording, import, or re-run. They do not run during Live Transcription. They do not change Mistral transcription or Mistral diarization.

Persist the UI as an `enabled` Boolean plus a selected method (`offlineVBx` or `experimentalLSEEND`). This lets turning the feature off preserve the user's preferred method. Defaults are disabled + VBx. Unknown/corrupt method values fail closed to VBx. Read the effective setting once at job start so a mid-job settings change cannot switch algorithms.

Initial LS-EEND settings are DIHARD3 + 500 ms. DIHARD3 is FluidAudio's broad, up-to-10-speaker variant; the larger step is appropriate for completed-file throughput where streaming latency is irrelevant. Do not expose variant or frame-step tuning in the UI. Compare it with the SDK's 100 ms default in the opt-in quality/performance gate; changing the shipped internal step requires documented evidence and owner review.

## 2. Reviewed starting point

Planning snapshot (the executing lead must verify it rather than assuming it is still current):

- Working directory: `/Users/champ/Sources/BisonNotes-AI`
- Branch: `streamline-options`, tracking `origin/streamline-options`
- HEAD: `64882b67af9a6497d06be6b4c6dfeb5621356cd3`
- Worktree at planning time: clean
- Dependency: FluidAudio 0.15.5, exact revision `19600a485baa4998812e4654b70d2bab8f2c9949`, already linked to iOS and native macOS
- FluidAudio minimums: iOS 17 / macOS 14; current project targets are higher (iOS 18.5 and macOS 15 in the reviewed project settings)
- Project folders are file-system synchronized, so new Swift files beneath the app and test source roots should not require manual `project.pbxproj` membership changes

Relevant current behavior:

- `FluidAudioManager` receives token timings but currently returns one unlabeled `TranscriptSegment`.
- Background Parakeet transcription chunks long audio at 10 minutes, creates chunk-local results, and centralizes reassembly in `AudioFileChunkingService.reassembleTranscript`.
- `TranscriptSegment` and `TranscriptData` already support speaker IDs, time ranges, speaker-name mappings, and speaker-aware summary text. No Core Data migration is expected.
- `FluidAudioManager.deleteModel()` currently deletes the entire `Application Support/FluidAudio` directory. That is unsafe once independent diarizer caches exist and must be narrowed before the feature ships.
- The native macOS scheme has no unit-test action. Portable logic is tested in the existing iOS unit target; native macOS receives build and manual runtime/accessibility validation unless separately authorized to add a Mac test target.

## 3. Protected boundaries

The following are non-negotiable:

- No edits to `MistralTranscribeService.swift`, `MistralTranscribeSettingsView.swift`, Mistral settings keys including `mistralTranscribeDiarize`, or Mistral request/response behavior.
- No edits to `LiveTranscriptionService.swift` or recording-time live transcription behavior/UI.
- No local-to-cloud fallback and no audio upload introduced by this feature.
- No diarization per 10-minute ASR chunk. Speaker identity must come from one complete-file diarization pass.
- Do not create another transcript reassembly system; extend the existing `AudioFileChunkingService.reassembleTranscript` path.
- No automatic model download when a transcription begins. The settings UI must perform an explicit download/preparation action.
- No FluidAudio upgrade or new package unless the checked-in 0.15.5 API is proven insufficient and the owner approves the scope change.
- No deployment-target reduction, new entitlement, Info.plist permission, privacy-manifest declaration, schema migration, bundled model asset, or `project.pbxproj` edit unless build evidence proves it necessary. Stop for review first.
- No committed meeting audio containing patient, client, or other private data.
- Do not regenerate the SwiftLint baseline or treat a clean lint exit as proof that no baseline violations exist.
- No commit, push, PR, release publication, credential action, history rewrite, or repository-setting change without separate authorization.

At final review, prove these protected production files have no diff:

```bash
git diff -- "BisonNotes AI/BisonNotes AI/MistralTranscribeService.swift" \
  "BisonNotes AI/BisonNotes AI/MistralTranscribeSettingsView.swift" \
  "BisonNotes AI/BisonNotes AI/LiveTranscriptionService.swift"
```

If a path has moved, locate the current equivalent and apply the same protection.

## 4. Intended architecture and lifecycle

### 4.1 Processing flow

For a completed Parakeet job:

1. Capture the enabled/method setting at job start.
2. Run the existing Parakeet ASR path. Preserve FluidAudio token timings and convert them to an app-owned, Sendable `TimedTranscriptWord` representation.
3. For chunked ASR, offset word times by each chunk's absolute start time and merge/de-duplicate them through the existing transcript reassembly path.
4. If labels are off, return the current transcript without loading a diarizer.
5. If labels are enabled, verify the selected model is already ready. Missing assets produce a clear `Download Required` outcome; transcription must not silently fetch them.
6. Release/unload the active ASR model where safe before loading diarization, especially on iPhone, to bound peak memory.
7. Run the selected diarizer once against the complete original/normalized source URL that remains valid for the job:
   - VBx: `OfflineDiarizerManager` file-based/memory-mapped batch API.
   - Experimental: `LSEENDDiarizer` DIHARD3/500 ms complete-file API, CPU compute as recommended by the SDK.
8. Align the full-file diarization timeline to the absolute Parakeet words, create normal `TranscriptSegment` values, and persist through the existing transcript path.
9. Release the diarizer and temporary resources on success, failure, or cancellation.

The integration owner must trace the source URL's lifetime for recordings, imports, background jobs, and re-runs. Do not assume a temporary cleaned file still exists when diarization begins.

### 4.2 Deterministic alignment rules

Implement alignment as pure, separately tested app logic:

- Reconstruct words from FluidAudio token timings without losing SentencePiece fragments or punctuation.
- Clamp invalid times to the audio duration and keep words ordered.
- Assign each word to the speaker interval with the greatest temporal overlap.
- Use one documented deterministic tie-breaker for boundary/overlap cases (midpoint containment, then earliest stable speaker order).
- The current app schema assigns one speaker to a word. When diarizer speakers overlap, resolve deterministically rather than duplicating the word.
- Normalize raw diarizer identities by first appearance to stable IDs `speaker_1`, `speaker_2`, and so on.
- Use an explicit Unknown/unlabeled fallback for words outside any credible interval; do not invent a prior speaker across an unbounded gap.
- Merge adjacent words for the same speaker without crossing a meaningful silence/turn boundary.
- Preserve all ASR words in their original order. Normalized plain text must remain semantically equal to the Parakeet text; diarization must never rewrite transcription content.
- Do not force misleading multi-speaker formatting when only one speaker is detected.

### 4.3 Failure and cancellation policy

- ASR success + diarization/model/timing failure: save the complete unlabeled Parakeet transcript, return a structured warning, and show a user-visible completion message such as “Transcription completed without speaker labels.” Do not silently switch to VBx, LS-EEND, or cloud.
- LS-EEND over its documented one-hour complete-file range: do not run it; preserve the unlabeled transcript and show a visible experimental-limit warning. Do not silently use VBx. VBx remains the recommended option for longer meetings.
- Cancellation: propagate `CancellationError`, release resources, and never persist a partially labeled transcript. Follow the existing job's coherent base-transcript cancellation semantics rather than creating a second save path.
- Logs may include model/mode, durations, counts, and error categories, but never transcript text, raw audio, credentials, patient data, or file contents.

### 4.4 Model lifecycle

Parakeet ASR, Offline VBx, and LS-EEND have separate readiness, download, progress, cancellation, unload, and delete state.

- Enabling or selecting a method does not download it.
- Turning labels off or switching methods unloads memory but preserves disk caches.
- Deleting one cache must preserve the other two.
- Cache readiness is reconstructed from verified assets on launch, not trusted from a stale Boolean.
- Restored iCloud preferences may select an absent model; the UI then shows Download Required.
- Use FluidAudio's real progress handlers. Do not synthesize smooth download progress.
- Current planning estimates are about 22 MB for VBx assets and about 45 MB for one DIHARD3 bundle. Re-measure the actual selected 500 ms assets and free-space behavior before publishing these values.
- Use real SDK progress where the pinned API forwards it. The reviewed LS-EEND loader does not currently forward determinate download progress end-to-end, so show an honest indeterminate preparing/downloading state rather than a synthetic percentage.

## 5. Settings and prerequisites contract

Add `Speaker Labels (After Recording)` to both branches of `FluidAudioSettingsView`:

- Toggle: `Local Speaker Labels`, default off.
- Help: applies after a recording, import, or re-run finishes; does not affect Live Transcription.
- Method rows when enabled:
  - `Offline VBx` with a visible `Recommended` badge and copy explaining that it estimates speaker count.
  - `LS-EEND` with a visible `Experimental` badge, “up to 10 speakers,” and a warning about extra/less-stable labels.
- Separate selected-method status/progress/error and `Download Speaker Model`, `Cancel Download`, and `Delete Speaker Model` actions.
- Rename ambiguous existing actions to `Parakeet Model`, `Download / Prepare Parakeet Model`, and `Delete Parakeet Model`.
- Stable accessibility identifiers and meaningful labels/hints for toggle, method rows, badges, status, progress, and destructive actions. State must not depend on color/icon alone.

Persist only user choices in the existing iCloud settings allowlist. Never back up cache paths, readiness flags, download state, or model binaries. Reset-to-defaults and UI-test process defaults must set labels off and VBx selected.

No speaker models become part of mandatory On Device AI onboarding because the feature defaults off. Do not edit the onboarding/downloader flow, change its required Parakeet/MLX model count, or silently include speaker assets as part of this feature.

Prerequisite documentation must state:

- Apple Silicon/Core ML and the app's actual supported iOS/macOS versions for the release branch. The reviewed project targets are iOS 18.5 and macOS 15; reconcile older README iOS 17 wording to the actual intended release minimum without lowering targets.
- One explicit initial HTTPS model download and adequate free space; no API key.
- Audio remains local, and cached models work offline after download.
- Post-recording/import/re-run only; no real-time speaker labels.
- VBx recommended and not app-capped at two or three speakers; LS-EEND experimental, up to 10 speakers, and subject to its complete-file duration limit.
- Exact measured download/disk sizes, supported-device memory findings, and longer-meeting behavior.

No new permission or entitlement is expected because the app processes existing audio and already supports HTTPS model downloads. Verify Info.plist, entitlements, privacy manifest, and package linkage; do not change them speculatively.

## 6. Delegation rules and required worker report

Luna is the only integration lead. A subagent may edit only the files in its package. If a required change falls in another package or an unlisted shared file, stop and report it to Luna; do not cross ownership boundaries.

Every worker returns exactly:

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

“Done” without exact command output, call-site evidence, and unresolved gates is not acceptance.

## 7. Wave 0 — lead-only baseline and scope lock

Before delegating edits, Luna must:

1. Read all controlling files named in the kickoff prompt completely.
2. Record `git status --short --branch`, `git rev-parse HEAD`, `git branch --show-current`, `git worktree list`, and the upstream relationship. Do not overwrite unrelated user changes.
3. Confirm FluidAudio version/revision and inspect its checked-out Offline VBx and LS-EEND APIs/model names/licenses.
4. Confirm current deployment targets, target linkage, file-system-synchronized groups, and native macOS test limitations.
5. Trace the direct, chunked background, imported-audio, and re-run Parakeet call paths plus source-file lifetime.
6. Record a pre-change `git diff --check`, SwiftLint summary, and the normal iOS test gate when the environment permits. Classify any existing failures separately.
7. Freeze the package interfaces: settings value type, `TimedTranscriptWord`, diarizer protocol/result/warning type, model status protocol, and the handoff from ASR/reassembly to whole-file orchestration.
8. Give each worker its exact package and protected boundaries. Record any pre-existing modified files before allowing work.

Stop if the branch/worktree differs materially, unrelated changes overlap owned files, the complete source audio is unavailable at the required point, or the dependency APIs differ from this plan.

## 8. Ownership and sequencing

| Package | May start | Exclusive production ownership | Primary output |
|---|---|---|---|
| A — contracts/alignment | After Wave 0 | New local-diarization types and pure aligner files only | Deterministic tested mapping from timed words + timeline to transcript segments |
| B — model adapters/lifecycle | Parallel with A | `FluidAudioManager.swift`, `FluidAudioModelInfo.swift`, new diarizer/model manager adapters | Independent ASR/VBx/LS caches and injectable FluidAudio runners |
| C — workflow/persistence | After A+B review | Background/reassembly/transcription orchestration, iCloud allowlist, focused unit/integration tests | One complete-file diarization pass after ASR, persistence, warnings/cancellation |
| D — iOS/macOS settings/accessibility | After B interface freeze; may parallel C | Settings views, accessibility IDs, UI-test defaults, UI/accessibility tests | Consistent opt-in settings UX on iOS and native macOS |
| E — docs/regimen/notices | After A-D terminology/behavior freeze | README, guide, testing regimen, accessibility evidence, acknowledgements | Accurate prerequisites, licenses, testing and user guidance |
| Lead — integration | Throughout; final after E | Cross-package interface resolution only after ownership handoff | Reviewed aggregate change and evidence report |

No two active workers may edit the same file. Shared-interface changes are proposed to Luna and applied by the current owner or after an explicit ownership handoff.

## 9. Package A — contracts and pure alignment

Exclusive files:

- New `BisonNotes AI/BisonNotes AI/FluidAudio/LocalDiarizationTypes.swift`
- New `BisonNotes AI/BisonNotes AI/FluidAudio/SpeakerTranscriptAligner.swift`
- New `BisonNotes AI/BisonNotes AITests/LocalSpeakerAlignmentTests.swift`

Work:

- Define Sendable app-owned types for timed words, selected local method, normalized speaker intervals, labeling warning/result, and injectable protocol contracts agreed in Wave 0.
- Implement the deterministic rules in section 4.2 without importing UI or persistence.
- Keep SDK types at the adapter boundary; do not make core transcript models depend on FluidAudio-specific timeline types.

Required tests include token/word reconstruction and punctuation, order/no-loss, strongest overlap, ties/boundaries, overlapping speakers, stable first-appearance IDs, gaps/Unknown, meaningful-silence grouping, timestamp clamping, empty ASR/timeline, nil/malformed timings, one speaker, short interjections, and plain-text equivalence.

Acceptance: all tests use in-memory values, perform no network/model load, and are deterministic over repeated runs.

Stop if preserving text requires changing shared persistence models or if FluidAudio exposes no reliable timing data for the pinned ASR result.

## 10. Package B — FluidAudio adapters and independent model lifecycle

Exclusive files:

- `BisonNotes AI/BisonNotes AI/FluidAudio/FluidAudioManager.swift`
- `BisonNotes AI/BisonNotes AI/FluidAudio/FluidAudioModelInfo.swift`
- New `BisonNotes AI/BisonNotes AI/FluidAudio/LocalDiarizationManager.swift`
- Any additional new adapter files under that same folder approved by Luna
- New `BisonNotes AI/BisonNotes AITests/LocalDiarizationModelManagerTests.swift`

Work:

- Preserve Parakeet word/token timing in the agreed app-owned representation.
- Add protocol-backed VBx and LS-EEND runners so orchestration tests can use fakes.
- Wrap explicit prepare/download, readiness verification, progress, cancellation, unload, and targeted delete for each diarizer.
- Narrow existing Parakeet deletion to Parakeet assets only before introducing other caches.
- Use VBx file-based/memory-mapped processing and LS-EEND DIHARD3/500 ms complete-file processing.
- Leave VBx `minSpeakers`, `maxSpeakers`, and `numSpeakers` unset so the SDK estimates the count; do not introduce an app-side speaker cap.
- Run synchronous complete-file inference away from `MainActor` so settings/transcript UI remains responsive.
- Ensure all cleanup occurs on success, error, and cancellation.

Required tests use an injected temporary cache root/downloader/file manager: default and invalid settings, independent readiness, cached-offline prepare, missing-model no auto-download, progress/cancel/retry, relaunch readiness reconstruction, switching without deletion, and every pairwise cache-delete isolation case.

Acceptance: no unit test reaches Hugging Face or loads Core ML; ASR/VBx/LS assets cannot delete one another; no dependency/project/entitlement change.

Stop if the SDK has no supported targeted cache paths/API, license terms cannot be satisfied, or DIHARD3/500 ms cannot run on the declared minimum supported device.

## 11. Package C — completed-file workflow, reassembly, and persistence

Exclusive production files:

- `BisonNotes AI/BisonNotes AI/EnhancedTranscriptionManager.swift`
- `BisonNotes AI/BisonNotes AI/BackgroundProcessingManager.swift`
- `BisonNotes AI/BisonNotes AI/AudioFileChunkingService.swift`
- `BisonNotes AI/BisonNotes AI/Models/AudioChunkingModels.swift`
- `BisonNotes AI/BisonNotes AI/Models/TranscriptData.swift` only if a metadata-preserving segment-replacement helper is needed
- `BisonNotes AI/BisonNotes AI/Models/TranscriptionStarter.swift` only if the verified entry-point contract requires it
- `BisonNotes AI/BisonNotes AI/iCloudStorageManager.swift`

Exclusive tests:

- New `BisonNotes AI/BisonNotes AITests/LocalDiarizationOrchestrationTests.swift`
- New `BisonNotes AI/BisonNotes AITests/LocalDiarizationPersistenceTests.swift`
- `BisonNotes AI/BisonNotes AITests/AudioTranscriptionRegressionTests.swift`
- `BisonNotes AI/BisonNotes AITests/ICloudBackupRegressionTests.swift`
- `BisonNotes AI/BisonNotes AITests/BisonNotesAIIntegrationTests.swift` only if existing persistence helpers make it necessary
- `BisonNotes AI/BisonNotes AITests/TestHelpers.swift` only if a shared helper is demonstrably preferable to package-local fakes

Work:

- Extend existing result/chunk/reassembly structures with defaulted ephemeral word-timing/warning fields so non-Fluid call sites compile unchanged.
- Offset, sort, clamp, and de-duplicate chunk word timings through `reassembleTranscript`.
- Add one injectable post-ASR orchestration seam that runs only for `.fluidAudio` with local labels enabled.
- Use the complete source URL once, after all ASR chunks have completed and reassembled.
- Apply success/failure/cancellation behavior from section 4.3 and persist through existing structures.
- Add only the enabled/method preference keys to the iCloud backup allowlist.

Required tests:

- Off performs no diarizer call and returns exact prior Parakeet behavior.
- VBx and LS-EEND route correctly; Mistral, Whisper, native Speech, and other engines never invoke local labeling.
- Long chunked input offsets word times and invokes the selected diarizer exactly once with the complete URL.
- Event order proves ASR complete/unload before diarizer load.
- Success persists segments/mappings and speaker-aware summary text.
- Failure retains a successful unlabeled transcript plus structured warning.
- Cancellation writes no partial labels and releases resources.
- Retry/relaunch is idempotent; re-run replaces rather than duplicates label state.
- LS-EEND over one hour is guarded without invocation or data loss.
- iCloud backup includes choices but excludes cache/readiness/path/download state.

Acceptance: no second reassembly/save path; no changed behavior for default-off or non-Fluid engines; stable labels across a 10-minute ASR boundary.

Stop if a Core Data migration appears necessary, the original/cleaned full-file URL cannot safely outlive chunk processing, or background execution cannot complete coherently under current job semantics.

## 12. Package D — settings, reset behavior, and accessibility

Exclusive files:

- `BisonNotes AI/BisonNotes AI/FluidAudio/FluidAudioSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/TranscriptionSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/AccessibilityIdentifiers.swift`
- `BisonNotes AI/BisonNotes AI/UITestSupport.swift`
- `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIUITests.swift`
- `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIAccessibilityTests.swift`

Work:

- Implement section 5 in both the native macOS card layout and iOS/iPadOS Form.
- Do not initiate a model download from toggle/method selection.
- Ensure reset-to-defaults and deterministic UI-test launch defaults are off + VBx.
- Make badges, progress, errors, readiness, and destructive target understandable without color.
- Support VoiceOver, Voice Control, keyboard focus, Dynamic Type, narrow iPhone, and minimum/wide Mac window layouts.

Automated UI tests navigate Settings > Transcription > Configure On Device without downloading: assert default off, VBx Recommended, LS-EEND Experimental/up-to-10 copy, post-recording boundary, status/actions, selection persistence, and no auto-download.

Acceptance: semantic behavior/copy is equivalent on iOS and Mac; stable accessibility identifiers exist; no Mistral or Live Transcription controls/copy are changed.

Stop if the UI requires a new onboarding download contract or partial localization framework. Follow current localizable SwiftUI literal conventions; do not introduce an isolated strings catalog.

## 13. Package E — README, guide, regimen, accessibility evidence, and licenses

Exclusive files:

- `README.md`
- `CLAUDE.md`
- `docs/bisonnotes-ai-guide.html`
- `docs/testing-regimen.md`
- `docs/accessibility-matrix.md`
- `docs/app-store-accessibility.md` only if the existing evidence gate requires a claim update
- `BisonNotes AI/BisonNotes AI/Views/AcknowledgementsView.swift`
- A current-release document only if Luna verifies this feature is assigned to that release

Do not retroactively edit the published `docs/bisonnotes-ai-v2-3.html` merely because it exists. Update the active future/current release surface only after confirming branch/release ownership.

Documentation work:

- README: feature bullets, engine comparison's On Device row, architecture, Parakeet/settings workflow, prerequisites, privacy/offline nuance, model lifecycle/size, limits, troubleshooting, and acknowledgements.
- CLAUDE: update the internal architecture/file map and post-ASR enrichment flow without duplicating the user guide.
- User guide: exact toggle/method/download/delete steps, VBx recommendation, Experimental caveat/up-to-10, speaker rename workflow, missing-model/poor-assignment/over-one-hour troubleshooting, privacy, and offline behavior. Leave the Mistral section itself unchanged.
- Accessibility evidence: add identifiers/labels/badges/progress/destructive actions and manual iOS/Mac evidence; change public claims only through the current testing-regimen gate.
- Acknowledgements: scope any “all dependencies are MIT/Apache” language to software dependencies. Add downloaded model assets separately. The reviewed model cards report the VBx/Pyannote Core ML assets as CC BY 4.0 and LS-EEND model assets as MIT with upstream dataset terms retained. Include exact attribution/license/model URLs and reverify them before release:
  - `https://huggingface.co/FluidInference/speaker-diarization-coreml`
  - `https://huggingface.co/FluidInference/ls-eend-coreml`

Testing-regimen additions:

- Keep ordinary pre-merge tests fully offline with fakes; no model or fixture download.
- Enumerate the focused alignment, model lifecycle, orchestration, persistence, iCloud, UI, and accessibility suites.
- Add an opt-in local diarization model/accuracy gate with prefetch instructions and captured evidence, excluded from ordinary CI.
- Add physical-device/iOS and native-Mac manual matrices from section 15.
- Explicitly smoke-test unchanged Mistral cloud diarization and unchanged Live Transcription without altering them.

Acceptance: repository search shows consistent `Local Speaker Labels`, `Offline VBx` + `Recommended`, and `LS-EEND` + `Experimental`; every surface says completed audio only and local after the initial download; no copy presents LS-EEND as the accurate/default choice; prerequisites match the active project release; license links/attribution are verified.

## 14. Automated validation

Workers run focused tests for their package first. Luna then runs the repository regimen and reports exact commands/results.

Focused test form (confirm exact XCTest identifiers after adding classes):

```bash
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-local-diarization-derived \
  -only-testing:"BisonNotes AITests/LocalSpeakerAlignmentTests" \
  -only-testing:"BisonNotes AITests/LocalDiarizationModelManagerTests" \
  -only-testing:"BisonNotes AITests/LocalDiarizationOrchestrationTests" \
  -only-testing:"BisonNotes AITests/LocalDiarizationPersistenceTests"
```

Aggregate pre-merge gate:

```bash
git diff --check
cd "BisonNotes AI/BisonNotes AI"
swiftlint lint --reporter summary
cd ../..
xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-test-derived
```

Also run changed-file SwiftLint and review every changed file for unused declarations, stale commented implementation, duplicate helpers, placeholder behavior, secrets, and PHI logging. Compare lint to Wave 0; do not hide regressions in the baseline.

Release-candidate validation follows `docs/testing-regimen.md`, including Watch tests/build where required by shared models, native macOS build/archive gates, and explicit separation of unsigned simulator/build success from signed-app, hardware, CloudKit, and manual results. Do not claim native Mac unit tests ran when no test action exists.

All automated tests must use fake diarizers/downloaders and temporary directories. They must pass with networking disabled and without cached FluidAudio models.

## 15. Manual model, quality, device, and accessibility gate

Use only team-recorded audio with written consent and no patient/client/PHI, or public fixtures after redistribution/license review. Maintain a manifest with SHA-256, provenance/license/consent, duration, sample rate/channels, language, speaker count, overlap/noise tags, verbatim reference, and RTTM/turn annotation. If a license prevents committing audio, document an ignored local fixture directory, acquisition steps, and hashes. Do not treat synthetic voices as the accuracy reference.

Fixture matrix:

- 1 speaker; clean 2 speakers; 4 speakers; 6–8 speakers; and 10 speakers for LS-EEND.
- Overlapping speech, short interjections, quiet/distant speech, background speech/noise, silence/music, corrupt/empty input.
- Multilingual Parakeet v3; representative Parakeet v2 run.
- A speaker turn crossing the 10-minute ASR boundary; 30-minute and 60-minute meetings; over-one-hour LS-EEND guard; longer VBx meeting.

Device matrix:

- Physical supported baseline-memory iPhone and a current higher-memory iPhone; supported iPad if advertised.
- Apple-silicon Mac baseline (for example M1/8 GB if it remains supported) and a current higher-memory Mac.
- Do not publish a RAM/device guarantee until the measured supported matrix is approved.

Capture for each mode/device:

- Actual download/on-disk size and insufficient-space behavior.
- First/cached prepare time, ASR time, diarization time, total time, RTFx, peak RSS/memory delta, thermal state, energy/battery, progress monotonicity, cancellation latency, and post-run memory release.
- Speaker count, DER with the stated collar/overlap policy, speaker-attributed WER or word-speaker accuracy, missed speech, false alarms, and label stability across chunks.
- Direct SDK timeline versus app-aligned output; the app layer must add no dropped/reordered words.
- Fresh install, cached airplane-mode run, cancel/resume/retry, network loss, insufficient disk, relaunch, independent deletes, method switch, foreground/background/termination, two serial jobs, and re-run of an existing transcript.

Quality results are evidence, not hard-coded marketing promises. Record VBx and experimental LS-EEND separately. VBx must be tested beyond three speakers; LS-EEND must be tested at 6–10 speakers and clearly retain Experimental status.

Manual accessibility/layout:

- iPhone/iPad and both native Mac layouts.
- VoiceOver reading/order/actions, Voice Control names, full keyboard access/focus, Dynamic Type, progress announcements, non-color status, minimum Mac window, and wide Mac window.
- Confirm labels can be renamed through the existing transcript UI and summaries receive the renamed/speaker-aware text.

## 16. Lead integration and final acceptance

Luna integrates in this order:

1. Review A and B separately, including their tests and public interfaces.
2. Freeze/adapt the interface, then start C; start D only against that frozen interface.
3. Review C's direct and background flow before D/E integration.
4. Freeze visible terminology and behavior; then run E.
5. Run focused tests, aggregate gates, protected-file diffs, and final changed-file inspection.
6. Produce one evidence report separating passed automated gates from pending signed-app, physical-device, accuracy/performance, and manual accessibility gates.

The feature is acceptable only when:

- Default-off users retain current Parakeet behavior.
- Labels run only for completed Parakeet work and once per complete file.
- VBx is Recommended without a two/three-speaker app cap; LS-EEND is visibly Experimental and capped/documented at up to 10 speakers.
- Mistral and real-time transcription production files/behavior are unchanged.
- ASR content is never dropped/reordered; labels and times are deterministic and persist through current transcript/summary/rename paths.
- Diarization failure preserves a complete unlabeled transcript with a visible warning; cancellation never saves partial labels.
- ASR, VBx, and LS-EEND caches are independently downloadable, inspectable, unloadable, and deletable.
- No transcription-triggered network call occurs; cached operation succeeds offline.
- iOS and native macOS settings are accessible and consistent.
- README, canonical guide, testing regimen, accessibility evidence, prerequisites, privacy wording, and model licenses are accurate.
- Automated, build, hardware, quality/performance, and manual gates are reported honestly and separately.

## 17. Stop conditions and owner decisions

Stop and ask the owner before continuing if:

- Worktree changes overlap an owned file or a package needs another active package's file.
- FluidAudio 0.15.5 lacks an API assumed here or a package upgrade/new dependency is proposed.
- Complete source audio cannot be retained safely through the post-ASR pass.
- Any Mistral/live-transcription production edit appears necessary.
- A schema migration, deployment-target change, new entitlement/permission/privacy declaration, bundled model, or manual project-file edit appears necessary.
- Model license/attribution or fixture redistribution terms are unclear.
- Actual minimum-device memory/thermal results make a documented supported device unsafe.
- Existing release documentation conflicts with the project deployment target or active release ownership.
- A test/build failure cannot be classified as baseline, environment, or introduced regression.

Owner-only decisions after implementation evidence:

- Whether measured LS-EEND quality/performance justifies keeping the planned 500 ms completed-file model or reverting to the SDK's 100 ms default.
- The minimum supported device/RAM wording and whether LS-EEND should be hidden on devices that fail the measured gate.
- Whether this feature belongs in a named release document and its App Store/release-note timing.
- Commit, push, PR, and publication authorization.
