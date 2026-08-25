# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Environment Context
- **Year**: 2026
- **Current iOS**: iOS 26 / iPadOS 26
- **Latest Devices**: iPhone models through iPhone 17 series, iPad models with M4 chips and A17 Pro

## Build and Development Commands

This is an iOS application built with Xcode. Use standard Xcode commands to build, run, test, and verify changes when working in a macOS/Xcode environment:

- **Build**: Open `BisonNotes AI.xcodeproj` in Xcode and build (⌘+B)
- **Run**: Build and run on simulator or device (⌘+R)
- **Test**: Run unit tests with ⌘+U
- **Clean**: Clean build folder (⌘+Shift+K)

The project uses Swift Package Manager for dependencies, including Textual, FluidAudio, and MLX Swift for content rendering, transcription, and on-device AI.

## Architecture Overview

### Core Data Architecture
The app has **migrated from legacy file-based storage to Core Data-only architecture**. All data is now managed through Core Data entities:

- **CoreDataManager**: Central data access layer for all entities
- **AppDataCoordinator**: Unified coordinator for all data operations
- **DataMigrationManager**: Handles migration from legacy storage on first launch
- **RecordingEntry**: Core Data entity for audio recordings with metadata
- **TranscriptEntry**: Core Data entity for transcription data
- **SummaryEntry**: Core Data entity for AI-generated summaries

### Key Components

#### Data Flow
1. **Audio Recording** → `AudioRecorderViewModel` → Core Data via `CoreDataManager`
2. **Transcription** → `EnhancedTranscriptionManager` → Core Data
3. **AI Processing** → Various AI engines → Core Data
4. **Background Processing** → `BackgroundProcessingManager` → Core Data

For completed Parakeet recordings, imports, and re-runs, optional **Local Speaker Labels** are a post-ASR enrichment step. `AudioFileChunkingService.reassembleTranscript` remains the single reassembly path: ASR words are reassembled with absolute timing first, then the selected local diarizer runs once against the complete source audio. Labels are off by default and never run during Live Transcription. Offline VBx is Recommended; LS-EEND DIHARD3 is Experimental and supports up to 10 speakers. A failure retains the unlabeled Parakeet transcript and surfaces a warning.

#### AI Integration
The app supports multiple AI engines:
- **Apple Intelligence**: Local processing using Apple frameworks
- **Google AI Studio**: Gemini 2.5 models for AI processing
- **Whisper**: Local Whisper server for transcription
- **Ollama**: Local AI models for privacy-focused processing

#### Core Managers
- **EnhancedTranscriptionManager**: Handles all transcription workflows
- **RecordingWorkflowManager**: Orchestrates recording → transcription → summary pipeline
- **BackgroundProcessingManager**: Manages async jobs and background tasks
- **PerformanceOptimizer**: Battery and memory-aware processing optimization

### Project Structure
```
BisonNotes AI/
├── Models/              # Core Data models and managers
│   ├── CoreDataManager.swift
│   ├── AppDataCoordinator.swift
│   ├── DataMigrationManager.swift
│   └── RecordingWorkflowManager.swift
├── Views/               # SwiftUI views
│   ├── RecordingsView.swift
│   ├── AudioPlayerView.swift
│   ├── AITextView.swift         # MarkdownUI-powered AI content rendering
│   └── DataMigrationView.swift
├── ViewModels/          # View model layer
├── FluidAudio/          # Parakeet plus Local Speaker Labels adapters/settings
├── AI Engines/         # Various AI service integrations
└── Background/         # Background processing
```

### Data Migration
On first app launch, the `DataMigrationManager` automatically migrates legacy data from file-based storage to Core Data. This ensures seamless upgrades for existing users.

### Background Processing
The app uses a sophisticated background processing system:
- Job queuing for transcription and AI processing
- Battery-aware processing optimization
- Progress tracking for long-running operations
- Error recovery and retry mechanisms

## Development Guidelines

### Core Data Usage
Always use `CoreDataManager` for data operations. Never access Core Data directly in views.

### iCloud Sync Arbitration

`iCloudStorageManager` reconciles in a fixed order: flush queued deletions → apply deletion markers → back up (local → cloud) → restore (cloud → local) → prune superseded duplicates. Four rules decide who wins. All four are pure static functions on `iCloudStorageManager` and are covered by `ICloudBackupRegressionTests` — change them there, not inline in the sync legs.

- **Newest edit wins, in both directions.** The backup leg uploads only when the local content timestamp is at least the cloud record's; the restore leg overwrites a local row only when the cloud timestamp is at least the local one. Compare **content** timestamps only (`lastModified` / `createdAt` / `recordingDate`, `generatedAt`) — never `syncUpdatedAt`, which is rewritten on every save and would make the cloud copy look permanently newer, freezing all uploads. Comparison is `>=` so equal timestamps still propagate other field changes, and when either side has no timestamp both rules fall back to overwriting: an unknown age must never strand an item.
- **A deletion marker records when the user deleted, not when the marker uploaded.** Queued deletions replay their original `requestedAt`, and the earliest claim wins when a marker already exists, so a marker that reaches CloudKit days later cannot erase newer work elsewhere.
- **An edit that lands more than `deletionReviveGraceInterval` after a delete beats that delete.** The tombstone is withdrawn and the item uploads again on the same pass. The grace window absorbs cross-device clock skew; a marker with no usable `deletedAt` never revives anything.
- **Only one transcript and one summary per recording sync.** `backupSourceSelection` uploads just the newest row per recording, and reconcile prunes local rows that a newer row supersedes — but never a row the recording still points at, and never with a tombstone, because every device derives the same winner from the same data. `latestPerRecording` (local) and `resolveLatestRecordsPerRecording` (cloud) must stay in step; if they disagree, devices trade uploads and deletions forever.

### iCloud Sync Engine

Every CloudKit request goes through the components under `BisonNotes AI/Services/`, and tests script them rather than the network. Four rules keep routine sync in seconds rather than minutes; `CloudKitBatchExecutorTests`, `CloudKitRetryPolicyTests`, `CloudContentIndexCoordinatorTests`, `ICloudSyncOrchestrationTests`, `CloudAudioAssetPolicyTests`, and `CloudSyncMetricsTests` cover them.

- **Read by known id, in batches.** The `content_index` manifest names every live record, so a routine pass fetches the whole dataset in two batched requests. `CKQuery` scans and zone-change fetches are reserved for first install, a missing or untrusted manifest, explicit repair, and schema diagnostics — never the routine path. Never walk a collection one `CKRecord` at a time.
- **One snapshot per run, one coordinator.** `performBackup` reads the cloud once, decides every winner in memory, and issues one batched save and one batched delete; the restore leg reuses that snapshot. `CloudSyncOperationCoordinator` serializes all operations — requests that arrive mid-run join it or collapse into a single follow-up, and say so in their result rather than returning zeroed counts that look like success.
- **`content_index` is only ever mutated as a delta.** `CloudContentIndexCoordinator` reapplies the run's `ManifestDelta` onto the server's record on `.serverRecordChanged`, a removal always beats a concurrent add, and full replacement is for repair and migration only. The generic copy-every-field merge must never touch the manifest or a deletion marker.
- **Metadata never waits on audio.** Recording records are fetched without `audioAsset`; a recording that turns out to need saving is refetched in full first, so a partially fetched record is never written back. Assets are built from immutable per-run staging copies, and audio bytes and throughput are reported separately from metadata timing.

Retries live in `CloudKitRetryPolicy`: honor `CKErrorRetryAfterKey`, bounded jittered backoff otherwise, at most three retries, and a requested wait over 30 seconds becomes a persisted eligibility time and a deferred result instead of a sleeping foreground task. Nothing — fetch, save, or scan — may issue a request before that time. Automatic triggers ask `shouldStartRoutineSnapshot(force:)` first; queued edits and user deletions are never delayed by the maintenance throttle, and throttle timestamps advance only after a complete run.

Recordings flagged `isCloudSyncDisabled` are excluded from all of the above. "Erase All iCloud Data" in Database Tools deletes every record and custom zone in the app's private CloudKit database, tombstones included, and never touches local data.

### AI Engine Integration
New AI engines should follow the existing pattern:
1. Create service class (e.g., `NewAIService.swift`)
2. Add settings view (e.g., `NewAISettingsView.swift`)
3. Integrate with `EnhancedTranscriptionManager` or appropriate manager
4. Add engine monitoring and error handling
5. Size its output budget and detect truncation as described below

### Reasoning Output Budgets

Every provider's output cap covers the model's **reasoning pass and its answer together**. A budget sized for the answer alone gets eaten by thinking, the payload arrives cut off mid-JSON, and the parser reports a malformed structured response — a message about the symptom, not the cause. `SummaryThinkingModelCatalog` owns the rules; `SummaryThinkingTests` covers them. Add new engines there, not with inline token math in the service.

- **Ask for reasoning + answer, never just the answer.** `completionTokenBudget(configured:modelName:engine:baseURL:)` returns the user's configured Max Tokens plus headroom for models that reason, and the configured value unchanged for models that do not. Every request-building site calls it: `max_completion_tokens` (Compatible API), `max_tokens` (Mistral), `maxOutputTokens` (Gemini), `num_predict` (Ollama), `GenerateParameters.maxTokens` (MLX Swift — except when Light thinking is on, where `MLXSwiftEngine` applies its own `thinkingTokenAllowance` for the budget it explicitly requested).
- **Headroom follows the model, not the Light toggle.** A thinking model reasons whether or not `SummaryThinkingLevel` asked it to, so `emitsReasoningTokens` gates the headroom, and it deliberately matches more names than `profile(...)` does. A cap that is too high costs nothing — providers bill generated tokens, not the cap — while one that is too low truncates the answer. Only `requestOptions` may decide which control *field* to send.
- **Read the provider's own truncation signal; never infer it from the payload.** `finish_reason` of `length`/`max_tokens` (Compatible API, Mistral), `finishReason` of `MAX_TOKENS` (Gemini), `done_reason` of `length` (Ollama). Each is exposed as `wasTruncatedByTokenLimit` next to its response model.
- **Retry once with a doubled budget, then fail loudly.** Reasoning length is unpredictable, so a single growth pass (capped at `maximumCompletionTokenBudget`) recovers the common case. What remains truncated throws `SummarizationError.responseTruncated`, which names the limit and the reasoning cost. Truncated content never reaches a parser. `SummaryManager` deliberately skips its blind retry for this error — the engine already grew the budget, so another pass would fail identically.

### Native macOS Build Notes

Mac Catalyst was removed in Phase 4.3 of the native migration. The iOS target supports only iPhone and iPad destinations; the `BisonNotes AI macOS` scheme is the sole Mac product.

- **Keep `EXCLUDED_ARCHS = x86_64` at the project level.** BisonNotes remains Apple Silicon-only because MLX Swift requires Apple Silicon.
- The native target uses the MLX Swift package for on-device language-model inference. Do not add a vendored llama.cpp framework back to the project.

The historical Catalyst guards in the `bisonbet/textual` fork are no longer required by this app and can be dropped when that separate repository is next rebased.

### Background Processing
For long-running operations, use `BackgroundProcessingManager` to queue jobs and track progress.

### Performance Considerations
- Use `PerformanceOptimizer` for battery and memory-aware processing
- Implement chunking for large audio files (>5 minutes)
- Use streaming processing for memory efficiency

### File Management
All file operations should coordinate with Core Data to maintain data integrity. Use `EnhancedFileManager` for file operations.

### UI and Content Rendering
For AI-generated content display:
- Use `AITextView` with MarkdownUI for all AI summaries, transcripts, and formatted content
- MarkdownUI handles headers, lists, bold text, links, and complex formatting automatically
- Text preprocessing in `AITextView.cleanTextForMarkdown()` removes JSON artifacts and normalizes content
- Supports all configured AI engines, including Gemini, Apple Intelligence, and compatible APIs.

## Key Files to Understand

- `BisonNotesAIApp.swift`: App entry point with Core Data setup
- `ContentView.swift`: Main tab interface
- `Models/CoreDataManager.swift`: Core Data access layer
- `Models/AppDataCoordinator.swift`: Unified data coordination
- `iCloudStorageManager.swift`: CloudKit backup, restore, reconcile, and multi-device arbitration
- `Services/CloudKitTransport.swift`, `Services/CloudKitBatchExecutor.swift`, `Services/CloudContentIndexCoordinator.swift`, `Services/CloudSyncOperationCoordinator.swift`, `Services/CloudSyncMetrics.swift`, `Services/CloudAudioAssetStaging.swift`: the sync engine the manager runs on
- `Views/AITextView.swift`: MarkdownUI-powered content rendering
- `EnhancedTranscriptionManager.swift`: Transcription orchestration
- `FluidAudio/FluidAudioSettingsView.swift`: Parakeet and Local Speaker Labels settings
- `FluidAudio/LocalDiarizationManager.swift`: Independent VBx/LS-EEND model lifecycle and adapters
- `FluidAudio/SpeakerTranscriptAligner.swift`: Complete-source speaker timeline alignment
- `AudioFileChunkingService.swift`: Shared ASR reassembly before post-ASR enrichment
- `BackgroundProcessingManager.swift`: Background job management
- `FutureAIEngines.swift`: AI engine implementations
- `Models/SummaryThinkingModelCatalog.swift`: Model thinking capabilities and reasoning output budgets
- `AISettingsView.swift`: AI engine configuration UI
- `BisonNotes_AI.xcdatamodeld/`: Core Data model definitions

The active supported deployment minimums are iOS 18.5 and native macOS 15. Speaker models are explicitly downloaded over HTTPS, cached for offline use, and kept independent from Parakeet assets; they are never fetched implicitly when a transcription starts. See the user guide and testing regimen for user workflow and release-gate details.
