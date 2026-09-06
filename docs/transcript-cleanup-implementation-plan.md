# English transcript cleanup with S1-mini: implementation handoff

Status: proposed implementation plan; no application code implemented.
Prepared 2026-09-06 against branch `v2.5-transcript-clean-llm`, HEAD `cc00a2ce4a688df3a85a3782e8696a37e69a5a4b`. Working tree was clean before adding this document. Reverify provenance before implementation; this is a baseline, not permission to reset a newer checkout.

## 1. Product contract

Add an optional, on-device step that turns completed English ASR text into readable written English using exactly `mlx-community/S1-mini-MLX-8bit` through the existing Swift MLX stack.

- A new `transcriptCleanupEnabled` preference defaults to **false**, including absent keys, upgrades, reset settings, and test launches. Keep it device-local; do not import another device's opt-in through iCloud settings restore.
- Settings label: **Clean up transcripts (English only)**. Supporting copy: “Improve punctuation, remove fillers, and resolve spoken corrections on this device. Original text and speaker labels are preserved.” Show **S1-mini by Superwhisper** as the model attribution.
- The toggle enables automatic cleanup of newly completed file transcriptions, including recorded/imported audio and ASR reruns, across supported ASR engines. Run after final reassembly and any diarization. Never run on live partial text or separately on intermediate ASR chunks.
- Add **Clean up English transcript** to existing transcript actions, including imported text transcripts. This explicit one-time action does not enable the global preference or rerun ASR/diarization. Imported text is not automatically cleaned in v1.
- Preserve original text. Offer **Original / Cleaned** when a cleaned revision exists, and label it AI-cleaned. A successful new cleanup selects Cleaned in that editor; opening an existing transcript defaults to Original, so toggling the global setting off never hides the original. Turning off automation does not delete saved cleaned revisions.
- Copy/share/export follows the selected representation. Existing automatic summaries and their input remain based on original text in v1; changing summary behavior is a separate feature. Make this boundary clear in the cleanup help text.
- Supported execution targets: existing MLX-capable Apple-silicon native macOS and physical iOS/iPadOS builds. Keep unsupported targets and simulator compilable; show an unavailable reason rather than offering a nonfunctional action. Do not add Watch inference, servers, API keys, a cloud fallback, Python runtime, or another inference framework.

The requested model is a specialized normalizer, not a general-purpose reasoning/chat model. “More logical” here means resolving spoken false starts and corrections and improving written form. Do not promise fact correction, knowledge supplementation, or guaranteed preservation of meaning. Do not add an instruction to invent missing context.

## 2. Verified upstream model contract

Source: [MLX model card](https://huggingface.co/mlx-community/S1-mini-MLX-8bit), read 2026-09-06. This section fixes v1 choices; do not expose unnecessary tuning controls.

| Item | Required implementation |
| --- | --- |
| Model | `mlx-community/S1-mini-MLX-8bit` |
| System message | Copy the exact `SYSTEM` string from the card's source-model quickstart into a dedicated constant, preserving wording. Do not substitute the app's summary prompt. |
| User message | `[Styling: semi-formal] [Structure: prose] [Context: general]`, then one newline, then raw segment text. |
| Chat template | Apply the model tokenizer's template with `add_generation_prompt` enabled and `enable_thinking` explicitly **false**. Passing nil is insufficient. |
| Decoding | Greedy, temperature 0; disable sampling filters and repetition penalties rather than inheriting summary preferences. Confirm the pinned Swift API's greedy behavior. |
| Length | The card recommends approximately 1,000 input tokens and chunking longer input. App policy: maximum 1,000 tokens for the fully rendered request, measured using this tokenizer; 1,024 new output tokens per call. |
| Session | Fresh history for every request. No previous transcript, speaker turn, summary, or hidden chat history. |
| Output | Plain normalized text. No JSON, speaker labels, added instructions, or explanatory wrapper. |

The exact prompt/template requirements are part of the model's trained interface. Add a fixture verifying the actual rendered template, including the empty thinking-block assistant prefix described on the card. Stripping reasoning after generation is not an alternative to disabling it before generation.

The model card's small-file size and accuracy figures include source/GGUF discussion: do not reuse them as measurements for this MLX download or supported-device claims. Measure actual assets and runtime memory. The converted model is not yet load-tested by this plan. The standalone `generation_config.json` could not be retrieved during planning; inspect it and the tokenizer/config files at the pinned revision during milestone 0, while retaining the card's explicit greedy/non-thinking task recipe.

[Model license](https://huggingface.co/mlx-community/S1-mini-MLX-8bit/raw/main/LICENSE) includes an additional naming term. Preserve the name **S1-mini by Superwhisper** in settings and acknowledgements and retain the license with the downloaded model. Record the exact Hugging Face commit used for the initial release; do not assume the upstream source model's `v1` tag exists in the converted repository.

## 3. Data design: protect diarization by construction

Use an additive optional value on `TranscriptSegment`, proposed as `cleanup: TranscriptSegmentCleanup?`, with normalized text, model ID/revision, prompt version, and creation date. Keep `text` as original ASR/import text. Use `decodeIfPresent` and `encodeIfPresent`; absent cleanup must decode identically to old records.

Existing segments are JSON inside `TranscriptEntry.segments`. Prefer that existing storage route, avoiding a Core Data schema change. Verify every persistence/sync route before relying on it.

Hard invariants for a cleanup operation:

1. Transcript ID, recording ID, segment IDs, segment order/count, `speaker`, `startTime`, `endTime`, `hasLeadingSpace`, speaker mappings, original text, and raw word/token timing remain unchanged.
2. Never send speaker IDs, names, timestamps, or structural identifiers to S1-mini. Never parse model text to recover speaker assignments. Associate output with the source segment in application code.
3. Normalize one existing segment at a time; do not merge adjacent segments, even for the same speaker. Split an oversized segment internally, then join its results back into that same segment. This trades some cross-segment fluency for reliable attribution.
4. Never rerun alignment against rewritten words. Cleaned text is anchored to the original segment's time range; it does not acquire word-accurate timestamps. Timestamp/caption exports requiring word accuracy continue using originals and say so.
5. Keep raw accessors `plainText`, `fullText`, and `textForSummarization` unchanged. Add explicit representation-aware accessors for UI and ordinary text export. Speaker names still come from mappings, so renaming works in both representations.
6. Do not use existing `updatedTranscript(...)` for attaching cleanup: it constructs a new transcript identity. Add an identity-preserving copy operation. The default `TranscriptSegment` initializer also creates a new UUID; provide a preserving copy operation rather than reconstructing cleaned segments with it.
7. Editing original segment text clears that segment's cleanup in the same save. Speaker rename preserves cleanup. ASR rerun replaces old cleanup with results derived from the new raw text; disabling cleanup on that rerun leaves no stale cleaned payload. Cleanup always starts from original text, not an earlier cleaned result.

A successful all-filler input can normalize to empty text. Preserve the segment and its original metadata even when its cleaned text is empty; keep its row available in the cleaned editor so speaker turns do not disappear. Empty output from substantive input is a failure. Use a small, explicit filler-only allowlist to accept emptiness; ambiguous cases retain original text.

Use whole-operation atomic publication: generate in memory, then persist all cleanup values together only after all segments validate. If any segment fails, retain the previously persisted transcript/cleanup and show a recoverable warning. Initial transcription still saves its original result when optional cleanup fails. A user cancelling cleanup returns to original text; cancellation of the entire transcription job retains existing job-cancellation semantics and must not publish a partial result.

## 4. Proposed components and current integration map

All source paths below are relative to `BisonNotes AI/BisonNotes AI/`; proposed new files are not existing APIs.

| File/component | Work |
| --- | --- |
| New `TranscriptCleanupSettings.swift` | Default-off preference, immutable per-operation configuration, availability and English-only policy. |
| New `TranscriptCleanupCoordinator.swift` | Injectable normalizer protocol, token chunking, validation, cancellation, result/warning types, atomic assembly. Keep pure orchestration testable without MLX. |
| New `MLXTranscriptCleanupService.swift` | Fixed model, exact prompt, explicit non-thinking template, greedy generation, finish-reason checks, memory/lifecycle ownership. |
| New `TranscriptCleanupModelManager.swift` | Independent explicit download/cancel/retry/delete/readiness state. Reuse narrow cache/download primitives where appropriate; do not copy a second uncoordinated cache implementation. |
| `Models/TranscriptData.swift` | Optional cleanup payload, preserving copy helpers, explicit representation accessors; preserve original summary behavior. |
| `BackgroundProcessingManager.swift` | Final-result hook after reassembly and optional local labeling, immediately before `saveTranscript`. Cover both reassembled and direct single-chunk branches. Preserve speaker warnings alongside a distinct cleanup warning. |
| `EnhancedTranscriptionManager.swift` | Direct complete-file hook after engine result and labeling; suppress it for calls serving background chunk transcription to prevent double processing. Audit all callers before choosing the parameter/wrapper. |
| `Models/TranscriptionStarter.swift` | Direct fallback warning propagation and persistence. |
| `Models/RecordingWorkflowManager.swift`, `Models/CoreDataManager.swift`, `Models/TranscriptManager.swift` | Verify new/replacement save and conversion preserve optional payloads and identity. |
| `Views/TranscriptViews.swift` | One-time action, progress/cancel, Original/Cleaned, copy/share, original-edit invalidation, rename, direct/background rerun updates and warnings. |
| `TranscriptionSettingsView.swift` and native Mac settings entry points | Shared toggle/help/model controls, accessible status and unsupported-device explanation. |
| `iCloudStorageManager.swift`, import/export and backup adapters | Audit segment round trip; sync derived text with its transcript under existing local-only rules. Exclude preference, downloads, readiness, progress, caches. |
| `Services/CacheMaintenanceService.swift`, `MLXSwiftEngine.swift` | Coordinate active inference/download/cache maintenance; summary selection and defaults remain intact. |

Do not add S1-mini as a selectable summarization model. The existing MLX download singleton is tied to summary-model selection, and the summary generation method uses summary prompts/preferences. Neither is an appropriate direct cleanup API. The present non-thinking summary branch passes nil template context, which also does not satisfy this model's requirement.

The background manager has its own reassembly/labeling/save flow; changing only `transcribeAudioFile` will not correctly cover it. Conversely, adding cleanup to every provider result will run it on intermediate chunks before diarization. Establish two explicit final-result hooks that call one coordinator, with a tested suppression path for intermediate work.

## 5. Execution, language, and failure policy

- At operation start, snapshot the feature preference, raw segment content/IDs and transcript revision (`lastModified` plus source-content fingerprint). Before final save, refetch and compare; discard stale results if an edit, rerun, deletion, or another cleanup changed the source. Do not resurrect deleted records.
- Automatic English eligibility uses trusted ASR language metadata where present. Otherwise classify the whole original transcript with NaturalLanguage; proposed conservative threshold is English probability at least 0.9. Reject known non-English metadata regardless of detector result. Check sufficiently long segments for clearly non-English content too; mixed/uncertain transcripts skip automatically with an explanation. This is an app heuristic, not a model guarantee. The one-time English-labelled action can serve as user confirmation for an uncertain short transcript; known non-English text must not be translated.
- Explicitly download the model from settings/action setup before inference. Toggle-on never downloads or loads by itself. Missing assets leave ASR successful and show “Transcript saved. Download S1-mini to clean up English text.” Manual action offers the same download controls. Do not invoke a loader that silently fetches missing assets.
- Tokenize the fully rendered prompt. Split only within the current segment, preferring sentence boundaries then whitespace; measure candidate requests after templating. No overlapping input windows or duplicate output. If an unbreakable token/text unit cannot fit, return a recoverable failure. Join internal cleaned pieces with one separating space, retaining punctuation emitted by each piece.
- Inspect generation finish reason: token-limit termination is failure, never successful truncated prose. Permit a bounded retry by splitting that piece into smaller inputs once; if still invalid, fail the whole cleanup. Apply cancellation between requests and during generation; bound a request to 120 seconds with a cancellation-aware implementation. Do not use an unbounded retry loop or a timeout race that leaves Metal generation running unnoticed.
- Validate output for substantive-input emptiness, generated special/chat/control tokens, and implausible expansion (initial guard: more than twice the input token count plus 32 tokens). These are rejection heuristics, not proof of semantic accuracy. Do not require exact word/number equality: normalizing spoken numbers and explicit corrections is intended behavior. Human fixture review must check negation, names, numbers, dates and invented content.
- Reuse the project's platform guards and iOS MLX memory setup. Audit global MLX/Metal state. Serialize model loading/generation/unloading with other MLX consumers using explicit operation ownership; an actor alone does not prevent reentrant overlapping work across awaits. Coordinate cache deletion with active readers and download writers. Do not load ASR, diarization, cleanup and summary models concurrently just because each has a separate actor.
- Unload cleanup weights and release its resources on success, failure and cancellation before the next summary job. Do not clear global buffers underneath another active owner. Do not copy large-model RAM tiers as an unsupported minimum for S1-mini; determine capability with existing platform checks and measured memory headroom.
- Warnings distinguish missing model, unsupported platform, non-English/uncertain language, resource failure, invalid output and stale result. Never replace or erase the existing diarization warning. Log IDs, counts, durations and failure categories, not transcript/prompt/generated content.

## 6. Ordered implementation milestones

**0 — Establish baseline and model compatibility.** Read `AGENTS.md`, `CLAUDE.md`, `docs/testing-regimen.md` and this plan. Record branch, HEAD, status and comparison base. Inventory all complete/intermediate transcription callers, raw text consumers, MLX/cache owners and sync serializers. Inspect pinned Swift MLX APIs for template context, tokenizer, stop reason, cancellation, local-only loading and revision selection. Record the model revision and license. A minimal opt-in physical-device/Mac probe must demonstrate loading this quantization and the required template before claiming compatibility; no model download belongs in ordinary tests. If an SDK update is necessary, identify the exact incompatibility and isolate that dependency change for review.

**1 — Data and pure orchestration.** Add optional payloads, identity-preserving copies, language eligibility, chunk budgeting, validation and injected fake normalizer. Prove original/diarization invariants, legacy decoding and stale-result guards before wiring MLX or UI.

**2 — Model lifecycle and inference.** Implement dedicated model management and service, serialize resource ownership, add template fixtures and generation failure tests. Preserve summary configuration. Check compilation for real-device and native macOS targets as well as simulator stubs.

**3 — Automatic integration.** Wire background reassembled/single-chunk and direct completed-file paths, snapshot once per logical job, preserve warnings and cancellation, and prove exactly-once execution after labeling. Save originals on optional cleanup failure. No live-transcription cleanup.

**4 — User workflow and persistence.** Add settings/download UI, manual cleanup, representation selection, edit invalidation and export behavior. Verify persistence, rerun, rename, iCloud and local-only exclusion paths. Update acknowledgements and user documentation. Warn in release notes that an older app may ignore/drop optional cleaned fields when it rewrites a record; the original remains usable.

**5 — Validation and handoff.** Run the checks below, inspect the final diff for unused declarations/placeholders/duplicate helpers/secrets, and write an evidence report separating automated proof from hardware/model/sync proof. Do not commit, push or open a PR unless separately requested.

## 7. Required acceptance tests

Add focused suites under `BisonNotes AI/BisonNotes AITests/`, using fakes and temporary storage by default:

1. Missing/false preference: zero cleanup, tokenizer, download or model-load calls; original ASR/summary behavior unchanged. Explicit manual action works without changing the preference. Reset returns off.
2. Correct fixed model/prompt/control line, false thinking flag in the actual rendered template, greedy parameters, fresh history and independence from every summary preference.
3. Two/many speakers, overlap, empty/filler turns, renamed speakers, short turns and an ASR chunk boundary: exact segment IDs/order/count/timing/speakers/mappings/raw text retained. Labels never enter model requests.
4. Exact token-budget boundaries, long single segments, no punctuation, Unicode and repeated text: no omissions/duplication, no cross-speaker requests, bounded retry and output truncation rejection.
5. Failure/cancel/memory pressure/missing download: original remains readable, prior cleanup is not partially overwritten, distinct warnings coexist, resources are released and the next job succeeds.
6. Complete-file/background/single-chunk/direct fallback/rerun routes: cleanup once after ASR/reassembly/diarization; never on intermediate chunks or live partials. Original-derived automatic summaries remain unchanged.
7. Legacy JSON, new JSON, Core Data new/replace/reload, backup/restore, sync serialization, original edits, rename, rerun while disabled and deletion during generation. Preserve both transcript and segment identity; reject stale completion.
8. English, non-English, mixed language and uncertain short text policies. Detection failures skip automatically. No translation behavior.
9. Download lifecycle: cancellation and restart, incomplete assets, offline cache use, deletion during inference, cache maintenance and overlapping summary request. No implicit downloads or selected-model changes.
10. UI: English-only/default-off labels, model attribution/status, accessibility, download/cancel/retry, manual action, Original/Cleaned, empty cleaned turn, copy/export choice and both warning types.

Run `git diff --check`, relevant SwiftLint with honest baseline counts, focused cleanup tests, existing diarization reconciliation/orchestration/persistence tests, `AudioTranscriptionRegressionTests`, `MLXDownloadGenerationTests`, `MLXSwiftResponseCleanerTests`, `ICloudBackupRegressionTests`, and affected transcript editor tests. Follow `docs/testing-regimen.md` for the full pre-merge and accessibility gates. Build native macOS and a generic iOS device target because simulator compilation excludes real MLX code. Do not describe parsing or lint as compilation.

Hardware acceptance is separate: on Apple-silicon Mac and supported physical iPhone/iPad, explicitly download and run English fixtures covering fillers, correction of dates/numbers, negation, names, domain terminology, multi-speaker turns, a long transcript and cancellation. Record model revision, actual download size, OS/device, latency, peak memory and observed output quality. Verify offline reuse and sequential summary/cleanup. Review originals beside cleaned text; confirm no invented facts or speaker reassignment. Verify both representations and mappings survive an actual two-device iCloud round trip. Do not claim these checks passed based on fake tests or this planning document.

## 8. Copy/paste kickoff prompt

> Implement `docs/transcript-cleanup-implementation-plan.md` in milestone order. Treat its product contract and preservation invariants as requirements. First read the repository instructions and report current branch, HEAD, worktree status, comparison base and the milestone-0 integration findings. Then implement and validate each milestone. Keep cleanup off by default and English-only, use the fixed S1-mini MLX model and upstream exact prompt with thinking explicitly false, and preserve original transcript and speaker/timing data. Use fakes for ordinary tests. Do not change summary behavior, silently download models, or claim hardware evidence you have not obtained. Report concrete blockers and remaining hardware gates. Do not commit, push or create a PR unless I ask.
