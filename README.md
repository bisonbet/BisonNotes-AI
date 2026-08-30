# 🎙️ BisonNotes AI

**AI-Powered Voice Recording, Transcription, and Summarization for Apple Platforms**

<div align="center">

![iOS](https://img.shields.io/badge/iOS-18.5+-blue?style=for-the-badge&logo=apple)
![iPadOS](https://img.shields.io/badge/iPadOS-18.5+-blue?style=for-the-badge&logo=apple)
![watchOS](https://img.shields.io/badge/watchOS-11.5+-black?style=for-the-badge&logo=apple)
![macOS](https://img.shields.io/badge/macOS-15.0+-lightgrey?style=for-the-badge&logo=apple)

![Swift](https://img.shields.io/badge/Swift-6.0-orange?style=for-the-badge&logo=swift)
![SwiftUI](https://img.shields.io/badge/SwiftUI-blue?style=for-the-badge&logo=swift)
![Xcode](https://img.shields.io/badge/Xcode-26.6+-147EFB?style=for-the-badge&logo=xcode)
![Release](https://img.shields.io/github/v/release/bisonbet/BisonNotes-AI?style=for-the-badge&color=success)
![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)

[![Download on the App Store](https://img.shields.io/badge/Download_on_the-App_Store-0D96F6?style=for-the-badge&logo=appstore&logoColor=white)](https://apps.apple.com/us/app/bisonnotes-ai-voice-notes/id6749189425)

</div>

---

## 🌟 Overview

SwiftUI app for recording audio, transcribing it with local or cloud engines, and generating summaries, tasks, and reminders. Ships on **iOS, iPadOS, watchOS, and native macOS**. Core Data powers persistence; background jobs handle long/complex processing; WatchConnectivity imports complete watch recordings back to the phone.

Your recordings can stay entirely on-device: Parakeet handles transcription locally and MLX Swift handles summarization locally, with cloud engines available only if you opt into them.

### ✨ Key Features

- 🎙️ **Record Anywhere** — iPhone, iPad, Apple Watch, and native Mac, with pause/resume, Control Center widget, and Action Button support
- ⌚️ **Independent Watch Recorder** — The watch records on its own and transfers complete files back to the phone, surviving offline, relaunch, and reconnect
- 🖥️ **Native Mac Meeting Capture** — Optional ScreenCaptureKit system-audio capture mixed with your microphone, with selectable inputs and stall/device-recovery monitoring
- 🔒 **Fully On-Device Path** — Parakeet transcription plus MLX Swift summarization run locally; no audio leaves the device unless you choose a cloud engine
- 🤖 **Pluggable AI Engines** — On-device MLX Swift, Apple Foundation Models, OpenAI-compatible, Mistral AI, Google AI Studio, Whisper, Wyoming, and Ollama on native macOS
- 📝 **Summaries, Tasks & Reminders** — Structured extraction from transcripts, rendered with MarkdownUI
- 🔗 **Import From Link** — Direct audio/video files, transcript documents, and public YouTube captions
- ☁️ **Guarded iCloud Sync** — Batched CloudKit sync with throttle-aware retries, per-recording **Keep on This Device** exclusions, durable deletion markers, and explicit review of older cloud-only items
- 🛟 **Interruption Recovery** — A call, a lock, or an unexpected background stop preserves the completed segment and performs one coordinated recovery instead of competing restore loops
- ♿️ **Accessibility Throughout** — VoiceOver, Voice Control, non-color status cues, Reduce Motion, Dynamic Type, and Full Keyboard Access

> **⚠️ Not HIPAA Compliant**
>
> BisonNotes AI is a personal productivity app. It is **not** HIPAA-compliant and we do not provide Business Associate Agreements (BAAs). Do not use it to record or process protected health information, and review the in-app notice before enabling iCloud sync.

Quick links: [Full User Guide](docs/bisonnotes-ai-guide.html) • [v2.4 Release Guide (WordPress)](docs/bisonnotes-ai-v2.4.html) • [v2.3 (Build 14) Release Guide (WordPress)](docs/bisonnotes-ai-v2.3.html) • [v2.2 Release Guide (WordPress)](docs/bisonnotes-ai-v2.2.html) • [llama.cpp Removal Migration](docs/llama-cpp-removal-migration.md) • [Accessibility Matrix](docs/accessibility-matrix.md) • [Mistral AI Free Setup](docs/mistral-free-setup.md) • [Regression Testing Regimen](docs/testing-regimen.md) • [Build & Test](#build-and-test) • [Architecture](#architecture)

The WordPress release guides are versioned snapshots. Publish `docs/bisonnotes-ai-v2.4.html` at `/bisonnotes-ai-v2-4/`, `docs/bisonnotes-ai-v2.3.html` at `/bisonnotes-ai-v2-3/`, and `docs/bisonnotes-ai-v2.2.html` at `/bisonnotes-ai-v2-2/`, and keep all three pages available for the builds that are still installed. Leave the existing `/bisonnotes-ai/` page on the full user guide; it is the fallback for a build whose version cannot be read and it deliberately carries none of the versioned anchors.

In-app Help links derive both the page slug and the anchor from the installed marketing version (`BisonNotesDocumentation`): 2.4 opens `/bisonnotes-ai-v2-4/`, and the Processing Options help button opens `#bn24-ai` on that page. Section anchors are version-scoped, so each release guide must keep its own `bn<major><minor>-*` ids — renaming `bn24-ai` breaks the shipped 2.4 binary's help link.

## v2.4 Highlights
- Routine iCloud metadata sync is rebuilt around batched CloudKit requests. The dataset behind the work — 161 records — took about 3m14s for a full metadata backup plus another 28s of restore enumeration; a routine pass now reads the whole dataset in a couple of batched requests, issues one batched save and one batched delete, and plans an entire deletion-marker set in memory instead of re-reading iCloud once per tombstone.
- CloudKit throttling is honored rather than fought: `CKErrorRetryAfterKey` is respected, other failures back off with bounded jitter and at most three retries, and a requested wait over 30 seconds becomes a persisted eligibility time and a deferred result instead of a sleeping foreground task.
- The `content_index` manifest is mutated as a delta and rebased onto the server record on `.serverRecordChanged`, so two devices syncing concurrently no longer erase each other's entries; a removal always beats a concurrent add.
- All sync operations are serialized through `CloudSyncOperationCoordinator`. Requests arriving mid-run join the run or collapse into a single follow-up and report which happened, and a user-started backup/restore surfaces "Waiting for the sync already in progress" instead of returning zeroed counts that look like a clean empty sync.
- Recording metadata no longer waits on audio: records are fetched without `audioAsset`, a record that needs saving is refetched in full first, assets are staged per run, and audio bytes/throughput are reported separately from metadata timing.
- iOS audio interruption and background recovery is now one coordinated path. A phone call produces one state transition and one single-flight recovery instead of three overlapping restore loops, a recovery that restored nothing is no longer logged as success, and an unexpected background stop preserves the completed segment and defers microphone reacquisition to the foreground.
- Recovery persistence was tightened: deferred recoveries are parked separately and retained until their audio is saved and their row created, a recording correlated with a CallKit call is no longer stranded, a finished recording is persisted even when a newer session supersedes it, and stopping a recording always stops the live transcription service.
- Native macOS meeting capture adds an automatic microphone fallback — live input routes are refreshed, meeting virtual devices are retried, and system-audio capture is preserved when microphone startup is unavailable. A microphone that reconnects mid-recording is allowed back into its own recovery, failed microphone segments are sealed, and the macOS audio import picker is fixed.
- Unbounded caches and logs are now swept by `CacheMaintenanceService`: MLX model blobs are released as soon as a download materializes (a 7.9 GB model previously occupied 15.8 GB), deleting a model reclaims both copies, CloudKit's own copies of transferred assets are bounded by size — never touching an in-flight download, anything under an hour old, or anything whose age cannot be read — and the persistent error log no longer grows without limit.
- A sharded on-device model is only reported as installed when every shard named by `model.safetensors.index.json` is present and non-empty, so an interrupted copy keeps the download cache it needs to resume instead of being offered as ready.
- Deleted imported transcripts no longer resurrect: removal intents are queued before the local delete, intents whose local deletion already committed are kept, and stale transcript rows are removed.
- Summary regeneration commits its Core Data cleanup before queuing iCloud tombstones or deleting attachment folders, so a failed save can no longer leave local rows behind while a later sync deletes their cloud copies.
- In-app Help is version-aware. `BisonNotesDocumentation` derives both the release-guide slug and the section anchor from the installed marketing version (2.4 → `/bisonnotes-ai-v2-4/#bn24-ai`), and falls back to the unversioned landing page with no fragment when the version cannot be read.
- v2.4 dead code was removed across the app and test targets, and the release adds `docs/icloud-sync-performance-plan.md`, `docs/ios-audio-interruption-recovery-delegation-plan.md`, and `docs/v2.4-dead-code-cleanup-delegation-plan.md`.

## v2.3 (Build 14) Highlights
- The Mac app is now a native macOS app while retaining the same bundle identity, app container, Core Data store, and iCloud container used by the previous Catalyst build. It adds native windows, a dedicated Settings window, standard File/Edit commands, keyboard shortcuts, persistent archive bookmarks, AppKit sharing, and native RTF/PDF export.
- Native macOS now includes a Share extension for importing supported audio and transcript files from the Mac Share menu, plus small and medium desktop widgets that open BisonNotes and start a new recording.
- Native Mac recording uses selectable Core Audio inputs plus ScreenCaptureKit meeting-audio capture. It remembers the preferred microphone through temporary disconnects, monitors input-device changes, preserves microphone segments across a device recovery, validates microphone and system tracks independently, saves whichever usable track remains, and retains failed source media in Application Support for recovery.
- Enabling Record Meeting Audio now provides a guided Screen & System Audio Recording permission flow, including the required quit-and-reopen step. If Live Transcription is enabled, the finalized meeting recording is queued for file-based transcription so the combined audio is transcribed.
- Native macOS can run the Ternary Bonsai 27B MLX model on Macs with at least 16 GB RAM; the approximately 8.5 GB model remains excluded from iPhone and iPad.
- On-device Parakeet setup now recovers valid cached models more reliably, reports missing model assets accurately, and waits for model preparation to finish before starting transcription.
- Local Speaker Labels are opt-in post-processing for completed Parakeet recordings, imports, and transcript re-runs. Offline VBx is the recommended method; LS-EEND is experimental, supports up to 10 speakers, and is limited to complete files up to one hour. A failed label pass keeps the complete unlabeled Parakeet transcript.
- Summary controls are shared across the active engines: Brief, Balanced, or Detailed narrative output, plus Off or Light thinking when the selected model supports a safe thinking control. Thinking output stays out of the user-visible summary and structured metadata.
- The provider surface is streamlined: AWS Bedrock/Transcribe and the embedded legacy llama.cpp engine are removed, existing selections migrate to supported replacements, Ollama is native-macOS-only, and external llama.cpp servers remain available through Compatible API.
- Import from web links can now bring in direct audio/video files, transcript documents, and public YouTube captions, with a guided pasted-transcript recovery flow when YouTube blocks automated caption downloads.
- Web downloads are bounded by content type and size, use isolated sessions, validate redirects and final media before persistence, preserve server-provided filenames, and clean up temporary files when downstream import fails.
- Share imports now wait safely when another import is already running instead of deleting staged files, and caption cleanup removes one layer of HTML encoding without changing intentionally escaped text.
- Summary-only deletions now queue removal of both live and backup CloudKit records, including content-index cleanup, so an offline deletion can be completed when iCloud becomes available instead of restoring the deleted summary later.
- Thinking-capable MLX models keep their reasoning internal. Reasoning tags, partial traces, and prose preambles are stripped before summaries, tasks, reminders, and suggested titles are parsed or displayed.
- Common iPhone, iPad, Mac, and Apple Watch tasks now have explicit VoiceOver labels, values, hints, and non-color state cues across setup, recording, imports, recordings, playback, transcripts, summaries, settings, and watch recording.
- The custom audio scrubber remains visually unchanged but is exposed as an adjustable accessibility control with current/remaining time and 15-second seek increments.
- Recording, transcript, and summary rows expose contextual status such as duration, file size, archive/local audio, iCloud/local-only state, transcript availability, summary availability, task/reminder counts, and location availability.
- Apple Watch recording now exposes state for the main record/stop control, mute/pause, transfer progress, low battery, and error recovery, and the pulsing recording indicators respect Reduce Motion.
- A dedicated accessibility evidence set was added: `docs/accessibility-matrix.md`, `docs/app-store-accessibility.md`, `docs/accessibility.html`, and `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIAccessibilityTests.swift`.

## v2.1 Highlights
- iCloud sync now uses stronger guardrails: a HIPAA notice before enabling sync, per-recording **Keep on This Device** exclusions, deletion markers, active-manifest review for older cloud-only items, and clearer production CloudKit schema errors.
- Parakeet transcription recovery is more reliable. The app recognizes cached model files after app updates or settings resets, supports English v2 and multilingual v3 model choices, reports download/prepare progress more accurately, and avoids short final tail chunks during long on-device transcriptions.
- Recording reliability is improved through stricter audio session ownership, safer background processing interruption handling, crash-safe recording recovery, and conservative cleanup of stale temporary audio files.
- Release validation now has app/watch `.xctestplan` files, deterministic UI-test launch fixtures, focused iCloud and transcription regression tests, and a documented regression testing regimen.

## v2.0 Foundation Highlights
- Modernized SwiftUI interface across Recordings, Transcripts, Summaries, Setup, and Settings, with denser action placement and cleaner status surfaces.
- Redesigned watchOS recorder around one large tap target: tap to record, tap to stop, and use mute to pause/resume the same file. Transfer status and low-battery warnings stay visible without crowding the primary action.
- On Device AI is backed by MLX Swift on supported devices. Existing llama.cpp users are moved to the closest Ternary Bonsai model, and known legacy GGUF files are deleted during migration to reclaim storage.
- Watch sync no longer uses live audio chunks or phone-side recording control. The watch records independently, sends the finished file via `WCSession.transferFile`, and receives queued completion/failure confirmations.

## Architecture
- Data: Core Data model at `BisonNotes AI/BisonNotes_AI.xcdatamodeld` stores recordings, transcripts, summaries, and jobs. Sensitive API keys live in the iOS Keychain, never on disk in plaintext.
- Engines: Pluggable services for On Device transcription, compatible APIs, Mistral AI, Google AI Studio, Whisper (REST), Wyoming streaming, Ollama (native macOS only), On Device AI (MLX Swift), and Apple Native (Foundation Models). Each engine pairs a service with a settings view.
- iCloud Sync: `iCloudStorageManager` arbitrates winners; the engine under `Services/` (`CloudKitTransport`, `CloudKitBatchExecutor`, `CloudKitRetryPolicy`, `CloudContentIndexCoordinator`, `CloudSyncOperationCoordinator`, `CloudAudioAssetStaging`, `CloudSyncMetrics`) batches requests, serializes operations, and keeps audio transfer off the metadata path.
- Background: `BackgroundProcessingManager` coordinates queued work with retries, timeouts, and recovery. Large files are chunked and processed streaming‑first. `CacheMaintenanceService` bounds the model, CloudKit asset, and log caches off the main actor.
- Recording: A platform-aware audio pipeline — `AVAudioRecorder` on iOS/iPadOS and `AVAudioEngine`/`AVAudioFile` on native macOS (`AudioRecorderViewModel+MacEngine.swift`) — with shared Pause/Resume support, optional Mac meeting-audio capture through `MacSystemAudioCapture`, first-buffer and stall monitoring, independent track validation, recoverable PCM segments, and crash-safe interruption handling.
- Watch Sync: `WatchConnectivityManager` (on iOS and watch targets) manages reachability, complete-file transfers, duplicate protection, queued acknowledgments, and import recovery. Watch complications and a Control Center recording widget are bundled as separate targets.
- UI: SwiftUI views under `Views/` implement recording, summaries, transcripts, setup, and settings. AI-generated content uses MarkdownUI for professional formatting. View models isolate state and side effects.

## Project Structure
- `BisonNotes AI/`: shared iOS, iPadOS, and native macOS app source
  - Notable folders: `Models/`, `Views/`, `ViewModels/`, `Wyoming/`, `WatchConnectivity/`, `FluidAudio/`, `Services/`
  - Assets: `Assets.xcassets`; config: `Info.plist`, `.entitlements`
  - Uses Xcode's file-system synchronized groups, so dropping new Swift files into these folders automatically adds them to the project—no manual `.xcodeproj` edits are necessary.
- `BisonNotes Share/`: iOS Share Extension target for importing audio from other apps
- `BisonNotes Share macOS/`: native macOS Share Extension target
- `BisonNotes AI Watch App/`: watchOS companion app
- `BisonNotes Watch Widget/`: Watch complications surface for live recording state
- `BisonNotes AI Controls/`: Control Center recording widget (Recording Control Widget)
- Tests: `BisonNotes AITests/` (unit), `BisonNotes AIUITests/` (UI), plus watch tests

## Build and Test
- Open in Xcode: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`
- Build (iOS): `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -configuration Debug build`
- Test (iOS): `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 15'`
- Build (native macOS): `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'platform=macOS' -configuration Debug build`
- Archive (native macOS): `xcodebuild archive -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'generic/platform=macOS' -configuration Release`
- Use the watch app scheme to run the watch target. SwiftPM resolves automatically in Xcode.
- Release validation should follow [docs/testing-regimen.md](docs/testing-regimen.md), including app/watch test plans, native macOS coverage, and manual hardware checks for microphone/device switching, watch transfer, iCloud, Parakeet, share import, Control Center, Action Button, Mac meeting audio, archive restore, and long hidden-window processing.
- Local Speaker Labels are opt-in and default off. They run once on the complete source audio after Parakeet ASR and transcript reassembly, never during Live Transcription or in real time. Audio remains local; the first speaker-model download is an explicit HTTPS action, and cached models can be used offline afterward. No API key is required.
- Accessibility validation should include the automated UI audit class:
  `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:"BisonNotes AIUITests/BisonNotesAIAccessibilityTests"`
- Real-device accessibility release checks are still required for VoiceOver, Voice Control, Switch Control sampling, Full Keyboard Access on iPad/macOS, largest Dynamic Type, light/dark contrast modes, Reduce Motion, Apple Watch VoiceOver, Control Center, and Action Button.
- See `CLAUDE.md` for native macOS build notes and the duplicate-library modulemap cleanup.

## Accessibility Development Notes
- Shared accessibility strings and modifiers live in `BisonNotes AI/BisonNotes AI/AccessibilitySupport.swift`. Prefer these helpers for duration/status strings, row labels, announcements, and custom card semantics instead of one-off labels.
- Stable automation identifiers live in `BisonNotes AI/BisonNotes AI/AccessibilityIdentifiers.swift`. Add identifiers only for surfaces needed by UI tests, audit navigation, or repeated external automation.
- Deterministic accessibility UI tests live in `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIAccessibilityTests.swift` and use DEBUG launch arguments from `UITestSupport.swift`, including `--show-first-setup`.
- App Store accessibility evidence lives in `docs/accessibility-matrix.md` and `docs/app-store-accessibility.md`. Keep those files and the public `docs/accessibility.html` page aligned with implemented behavior before claiming Accessibility Nutrition Labels.
- The shared SwiftUI app surfaces carry over to native macOS, but the Mac release still needs manual VoiceOver, Full Keyboard Access, keyboard navigation, multi-window resizing, and real iCloud/file import validation.

## Dependencies

The project uses Swift Package Manager for dependency management. Major dependencies include:

### **On-Device AI**
- **MLX Swift / MLX Swift LM**: Backs the On Device AI summarization path.
  - Models: Ternary Bonsai 1.7B (~470 MB, 4 GB+ RAM), 4B (~1.1 GB, 6 GB+ RAM, default), and 8B (~2.3 GB, 8 GB+ RAM)
  - Native macOS also offers Ternary Bonsai 27B (~8.5 GB, 16 GB+ RAM); it is not available in the iOS model catalog
  - Models download from Hugging Face on first use and run locally after download
  - 4-6 GB devices use the 1.7B model; 6 GB+ devices default to the 4B model; 8 GB+ devices can select the 8B model
### **UI & Formatting**
- **MarkdownUI**: Professional markdown rendering for AI-generated summaries, headers, lists, and formatted text

### **On-Device Transcription**
- **FluidAudio Parakeet**: On-device transcription using NVIDIA Parakeet models.
  - Complete privacy - audio never leaves device
  - Works offline after model download
  - v2.1 supports Parakeet v2 (English) and Parakeet v3 (multilingual), keeps valid cached downloads across app updates/settings resets, and clears stale download state when model files are missing
  - WhisperKit was removed in v1.8; existing users are automatically migrated to Parakeet

### **Apple Frameworks**
- **WatchConnectivity**: Syncing between iPhone and Apple Watch
- **Core Data**: Local data persistence
- **AVFoundation**: Audio recording and playback

All external dependencies are resolved automatically via Swift Package Manager when building in Xcode.

## Local Dev Setup
- Requirements: macOS with Xcode 26.6+ and Command Line Tools (`xcode-select --install`).
- Clone/fork the repo, then open: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`.
- Select the "BisonNotes AI" scheme (iOS) or the watch scheme, choose a Simulator/device, and Run/ Test.
- Branch/PR: create a feature branch in your fork, push changes, and open a PR. Include build/test results and screenshots for UI changes.

## Key Features
- **Modern v2.0 UI**: Recordings, Transcripts, Summaries, Setup, and Settings use refreshed SwiftUI layouts with clearer action placement, sectioned date lists, and adaptive navigation.
- **Accessibility-ready task flows (v2.3)**: VoiceOver and Voice Control labels, values, hints, contextual row summaries, adjustable playback scrubber support, Reduce Motion handling, accessibility UI audits, and App Store accessibility evidence docs cover the common iPhone/iPad, Mac, and Apple Watch workflows.
- **Native macOS app (v2.3)**: Native Apple Silicon Mac target with movable/resizable content windows, dedicated Settings, Mac commands and shortcuts, persistent archive bookmarks, native export/sharing, selectable microphones, optional ScreenCaptureKit meeting audio, and Mac-aware capture recovery.
- **Pause and Resume Recording**: Pause mid-meeting without stopping the file. Resume seamlessly across iOS, iPadOS, watchOS mute/resume, and Mac (`AVAudioEngine`/PCM segment path).
- **Hardened Credential Storage (v1.11)**: API keys are stored in the iOS Keychain. Legacy values are migrated automatically and kept out of iCloud settings backups. File protection is applied to recordings, transcripts, notes, attachments, and the Core Data SQLite files.
- **Endpoint Safety (v1.11)**: User-configurable compatible API, Ollama, and Whisper endpoints are validated — public cleartext (HTTP/WS) destinations are blocked by default; local/private endpoints stay allowed, with a Development Mode toggle for power users.
- **Source-Centric Workflow (v1.11)**: "Generate Transcript" lives on the recording row; "Generate Summary" lives on the transcript. Buttons only appear where they apply and disappear once the artifact exists — regeneration happens from the existing detail view.
- **iPhone Action Button Support**: Quick-start recording from the Action Button on iPhone 15 Pro/Pro Max, iPhone 16 Pro/Pro Max, and future Pro models. Press the Action Button to launch the app and start recording instantly, even when your phone is locked.
- **Watch App & Complications**: Single-button Apple Watch recorder with tap-to-record/tap-to-stop, mute as pause/resume on the same file, pulsing capture state, low-battery warning, automatic complete-file sync, and watch-face complications.
- **Control Center Recording Widget**: Start/stop recordings from Control Center on iOS 18+ via the bundled Controls widget.
- **Multiple AI Engines**: Support for Google AI Studio, Mistral AI, compatible endpoints, Ollama on native macOS, On Device AI (MLX Swift), and Apple Native (Apple Intelligence).
- **Apple Native AI Engine**: On-device summarization using Apple's Foundation Models framework (iOS 26+, iPhone 15 Pro+). No data leaves the device.
- **On Device AI**: Default local summarization path using MLX Swift and Ternary Bonsai models. Supports 4 GB+ devices with model choices scaled by RAM.
- **Mistral AI (Free & Paid Tiers)**: Guided in-app setup wizard for Mistral's free tier -- transcription and summarization with no credit card required. Paid tiers available for higher rate limits. Cloud transcription via Voxtral Mini with speaker diarization support.
- **On-Device Processing**: Complete privacy with FluidAudio Parakeet transcription and MLX Swift summarization by default on supported devices.
- **Comedy Mode**: Optional summarization tone (snarky and other styles) applied across engines that support custom prompts.
- **Google Calendar Integration**: Send tasks or reminders into Google Calendar (app or web fallback) in addition to Apple Reminders/Calendar.
- **Summary Attachments**: Attach text, PDF, or other documents to a summary and preview them inline (Quick Look fallback for unknown types).
- **Recording Title Editing**: Edit recording titles directly from the audio player or transcript editor; AI-generated alternative titles are still available from the summary view.
- **Audio Export**: Share any recording as an audio file via the iOS share sheet
- **Audio Archive to iCloud Drive**: Offload selected recordings, or recordings older than a chosen age, while keeping transcripts, summaries, and a saved restore pointer in the app. Third-party file providers are disabled for archive targets for now.
- **Import From Link**: Import direct web URLs for audio/video files and transcript documents. YouTube links are parsed for public caption import; if YouTube blocks the caption request, BisonNotes shows a recovery workflow to open the video, copy the transcript, and import pasted transcript text.
- **Video Import**: Import video files; audio is automatically extracted to M4A
- **Audio Cleanup**: Optional pre-transcription DSP processing — high-pass filter, noise gate, dynamic normalization, and peak limiting
- **Live Transcription**: On-device live speech-to-text via SFSpeechRecognizer during recording; transcript auto-saved on stop
- **Share Extension**: Import audio and transcript files directly from Voice Memos, Files, and other apps via the iOS share sheet. Token-based authorization prevents the main app from scanning the shared container without an explicit handoff.
- **Combine Recordings**: Merge two separate recordings into a single continuous audio file
- **PDF Export**: Professional PDF reports with three-pane header (metadata, local map, regional map), pagination, and dedicated tasks/reminders sections
- **Background Processing**: Long recordings and complex processing handled automatically in the background with intelligent stale job detection and automatic recovery
- **iCloud Backup & Sync**: Automatic backup and cross-device reconcile on app activation, CloudKit summary sync with paginated queries and schema-safe fallback, deferred auto-backup, durable recording and summary deletion queues, and a per-recording **Keep on This Device** tag that excludes a recording, transcript, and summary from BisonNotes iCloud sync and backup. Sensitive settings (API keys) are excluded from iCloud settings backups by default.
- **Search Functionality**: Powerful search across recordings, transcripts, and summaries. Search by recording name, transcript text, summary content, tasks, reminders, and titles.
- **Date Filters**: Filter recordings, transcripts, and summaries by date range. Select start and end dates to quickly find content from specific time periods.

## Key Modules
- Recording: `EnhancedAudioSessionManager`, `AudioFileChunkingService`, `AudioRecorderViewModel` (+ `+MacEngine`, `+MacCaptureHealth`, `+MacFinalization`, `+MicrophoneReconnection`, `+Interruptions`, `+Background`, `+CallIntelligence`, `+Warnings`, `+Recovery`, `+RecoveryContinuation`), `AudioInterruptionRecovery`, `MacRecordingReliability`, `MacSystemAudioCapture`, `MacInputDeviceMonitor`, `RecordingCombiner`, `TranscriptionStarter`
- Transcription: `FluidAudioManager` (Parakeet), `MistralTranscribeService`, `WhisperService`, `WyomingWhisperClient`, `LiveTranscriptionService`
- Web Import: `WebImportManager`, `WebImportDownloader`, `WebImportURLClassifier`, `YouTubeImportService`, `YouTubePlayerResponseParser`, `TranscriptCaptionTextCleaner`
- Summarization: Compatible API service, `MistralAISummarizationService`, `GoogleAIStudioService`, `MLXSwiftEngine`, `AppleNativeEngine`
- Security: `KeychainSecretStore`, `EndpointSecurityPolicy`, `AppFileProtection`
- Export: `PDFExportService`, `SummaryExportFormatter`, `RecordingArchiveService`
- UI: `SummariesView`, `SummaryDetailView`, `TranscriptionProgressView`, `AITextView` (with MarkdownUI), `CombineRecordingsView`
- Accessibility: `AccessibilitySupport`, `AccessibilityIdentifiers`, `UITestSupport`, and `BisonNotesAIAccessibilityTests`
- Persistence: `Persistence`, `CoreDataManager`, models under `Models/`
- iCloud Sync: `iCloudStorageManager`, `CloudKitTransport`, `CloudKitBatchExecutor`, `CloudKitRetryPolicy`, `CloudContentIndexCoordinator`, `CloudSyncOperationCoordinator`, `CloudAudioAssetStaging`, `CloudSyncMetrics`
- Background: `BackgroundProcessingManager`, `TemporaryFileCleanupService`, `CacheMaintenanceService`
- Watch: `WatchConnectivityManager` (both targets), `BisonNotesComplications` (Watch Widget target)
- Controls: `RecordingControlWidget` (Control Center recording widget)
- Share Extension: `ShareViewController` (imports audio from other apps via share sheet)
- Action Button: `StartRecordingIntent`, `ActionButtonLaunchManager`, `AppShortcuts`
- Integrations: `SystemIntegrationManager` (Reminders, Apple Calendar, Google Calendar), `IntegrationSelectionView`

## Audio Archive

Audio archive is different from deleting an audio file. When a recording is archived, BisonNotes exports the audio file to iCloud Drive, stores the archive location in Core Data, and can optionally remove only the local audio file. The recording row, transcript, summary, tasks, reminders, and metadata stay in the app.

Archived recordings show their saved iCloud Drive location and a download button when local audio has been offloaded. Restoring copies the audio back into the app, validates that it is playable audio, clears the archive state, and removes the archived iCloud Drive copy so there is not a second stale file left behind. If the app cannot save a trackable iCloud location, it leaves the local audio in place and does not mark the recording archived.

For now, archive destinations are intentionally limited to iCloud Drive. Dropbox, Google Drive, Proton Drive, and other iOS File Provider extensions can appear in Files, but they have not been reliable enough for batch export, restore, and post-restore deletion.

## iCloud Sync Notice

When iCloud Sync is enabled, BisonNotes shows a confirmation notice that BisonNotes AI and uploads to iCloud are not HIPAA-compliant. If enabled, eligible recordings, transcripts, summaries, and selected settings may be uploaded to the user's private iCloud account.

To keep a specific item out of BisonNotes iCloud sync and backup, mark its recording **Keep on This Device** from the recording row or audio player. The tag applies to the recording's audio, transcript, and summary together. When the tag is turned on, BisonNotes skips future app-managed iCloud summary sync and backup for that item and removes known app-created iCloud records for that recording when iCloud is available.

When iCloud Sync is enabled, BisonNotes automatically reconciles eligible recordings, transcripts, and summaries when the app launches or becomes active. The **Include audio files in backup** checkbox controls whether audio files are uploaded and restored; transcripts and summaries are included in app-managed iCloud sync unless the recording is marked **Keep on This Device**. Deleting a recording writes an iCloud deletion marker and removes known app-created iCloud records so other devices on the same iCloud account can apply the deletion before they upload their local state. The app only cleans up records it can prove were deleted or explicitly excluded; active cloud-only records without a deletion marker are restored, while older untrusted cloud-only records are held for review.

Deleting only a summary also creates a durable pending iCloud removal. BisonNotes removes the summary's live record, backup record, and content-index reference immediately when possible, or retries the queued removal when iCloud becomes available.

Since v2.4, a routine pass reads the dataset by known id in batched requests off the `content_index` manifest, decides every winner from one snapshot, and issues one batched save and one batched delete. CloudKit's requested retry delay is honored; a wait longer than 30 seconds becomes a persisted eligibility time and a deferred result rather than a blocked foreground task, and no fetch, save, or scan runs before that time. Operations are serialized, so a backup or restore started during a running sync joins that run or collapses into a single follow-up and reports that it did, and recording metadata syncs without waiting on audio uploads. `CKQuery` scans and zone-change fetches are reserved for first install, a missing or untrusted manifest, explicit repair, and schema diagnostics.

iOS, iPadOS, and native macOS builds use the shared iCloud container `iCloud.Bison-Networking.BisonNotes-AI` for app-managed CloudKit sync. Devices must be signed into the same Apple ID and use the same CloudKit environment to see the same records. A local Debug build uses the CloudKit development environment, while TestFlight and App Store builds use production, so a Debug Mac install will not see records created by a production iPhone or iPad build until the build channel/environment matches.

Production iCloud sync requires the CloudKit production schema for `iCloud.Bison-Networking.BisonNotes-AI` to include the app-managed backup record types `CD_BackupRecording`, `CD_BackupTranscript`, `CD_BackupSummary`, `CD_BackupSettings`, `CD_BackupContentIndex`, and `CD_BackupDeletion`. Before shipping TestFlight or App Store builds that use these records, create/verify them in the development environment and deploy the CloudKit schema changes to production from CloudKit Dashboard. Production clients cannot create new record types themselves.

Current app versions mark synced content as active before it is automatically restored on other devices. Older cloud-only items that are not marked active are held in **Settings > iCloud Sync > Review iCloud Items**, where they can be restored or deleted from BisonNotes iCloud sync records.

## Transcription Engines

The app supports multiple transcription engines for converting audio to text:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **On Device (Parakeet)** | Default. On-device transcription using NVIDIA Parakeet models. Complete privacy. Optional Local Speaker Labels run after completed audio. | iOS 18.5+, macOS 15, model download |
| **Mistral AI** | Cloud transcription using Voxtral Mini with speaker diarization ($0.003/min) | API key, internet |
| **Whisper (Local Server)** | High-quality transcription using Whisper models on your local server | Whisper server running (REST API or Wyoming protocol) |

### On Device Transcription

#### FluidAudio Parakeet (Default)

Parakeet is the sole on-device transcription engine as of v1.8 (WhisperKit was removed). It provides fast, accurate, fully local transcription:

- **Privacy**: 100% local processing - audio never leaves your device
- **Offline**: Works completely offline after initial model download
- **Requirements**: iOS 18.5 or later; native macOS 15 or later
- **Models**: Parakeet v2 for English long-form recall and Parakeet v3 for multilingual transcription across 25 European languages
- **Reliability**: v2.1 recognizes valid cached model files, restores the selected model version when possible, resets stale download state when files are gone, and absorbs very short final tail chunks during long on-device transcriptions
- **Migration**: Existing users who had WhisperKit selected are automatically switched to Parakeet on first launch of v1.8

#### Local Speaker Labels

Local Speaker Labels are an optional post-processing step for completed Parakeet recordings, imported audio, and transcript re-runs. The setting is off by default and does not affect Live Transcription or any other transcription engine.

- **Offline VBx — Recommended**: the normal local choice; it estimates the number of speakers rather than imposing an app-side two- or three-speaker cap.
- **LS-EEND — Experimental**: the DIHARD3 500 ms model supports up to 10 speakers, but labels may be over-segmented or less stable. LS-EEND is guarded at one hour; choose VBx for longer meetings.
- **Model lifecycle**: choose a method, then explicitly download/prepare its speaker model from On Device settings. Enabling labels or switching methods never downloads during transcription. Parakeet, VBx, and LS-EEND readiness, cached files, unload, and delete operations are independent; deleting one does not delete the others. Cached models work offline after the initial HTTPS download.
- **Failures**: if a model is missing, the one-hour LS-EEND limit is reached, or alignment/diarization fails, the complete unlabeled Parakeet transcript is retained and a visible warning explains what happened. No cloud fallback is used.
- **Privacy**: audio and diarization stay on the device and no API key is needed. Do not publish model sizes, RAM/device guarantees, speed, or accuracy until the opt-in measurement gate has captured and approved them.
- **Speaker names**: open the existing transcript speaker controls, rename a speaker, and save. The renamed mapping is reused in speaker-aware transcript and summary presentation.

### Mistral AI Transcription

Mistral AI transcription uses the Voxtral Mini model for cloud-based speech-to-text:

- **Model**: Voxtral Mini Transcribe (`voxtral-mini-latest`)
- **Cost**: $0.003 per minute of audio
- **Speaker Diarization**: Optional — identifies and labels different speakers in the audio
- **Language**: Automatic detection or explicit language code (e.g., `en`, `fr`, `es`)
- **Supported Formats**: MP3, MP4, M4A, WAV, FLAC, OGG, WebM
- **Chunking**: Automatic chunking for files over 24MB or ~22 minutes (combined size/duration strategy)
- **Setup**: Uses the same API key as Mistral AI summarization. Configure in Setup → AI Settings → Mistral AI, then select Mistral AI as your transcription engine in Transcription Settings.

## AI Engines

The app supports multiple AI engines for summarization and content analysis:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **Apple Native** | Apple Intelligence (Foundation Models) — fully on-device | iOS 26+, iPhone 15 Pro+ |
| **Compatible API** | Any compatible chat-completion API (Nebius, Groq, LiteLLM, or an external llama.cpp-compatible server) | API key, internet |
| **Mistral AI** | Mistral Large (25.12), Medium (25.08), Small 4 (26.03), Medium 3.5, Magistral Medium (25.09) | API key, internet |
| **Google AI Studio** | Gemini 3.7 Flash (default), Gemini 3.5 Flash Lite | API key, internet |
| **Ollama** | Local LLM server on native macOS (recommended: qwen3:30b, llama3.2, mistral-small3.2) | Ollama server running on the Mac |
| **On Device AI** | Default on-device summarization with MLX Swift and Ternary Bonsai models | 4 GB+ RAM, model download |

### Mistral AI Models

Mistral AI offers a **free Experiment tier** (no credit card required) with access to all models, plus paid Build and Scale tiers for higher rate limits. The app includes a **guided in-app setup wizard** that walks new users through account creation and API key provisioning in about 2 minutes. See [Mistral AI Free Setup Guide](docs/mistral-free-setup.md) for details.

Summarization models:

- **Mistral Large (25.12)**: Most capable Mistral model with 128K context window (Premium tier)
- **Mistral Medium (25.08)**: Balanced performance and cost with 128K context (Standard tier)
- **Mistral Small 4 (26.03)**: Efficient hybrid instruct/reasoning model with controllable light reasoning (Standard tier)
- **Mistral Medium 3.5**: Current medium model with adjustable reasoning effort and 128K app context cap (Standard tier)
- **Magistral Medium (25.09)**: Economy option with 40K context window (Economy tier)

### Google AI Studio Models

Google AI Studio provides access to Gemini models:

- **Gemini 3.7 Flash**: Fast and efficient — Default (`gemini-3.7-flash`)
- **Gemini 3.5 Flash Lite**: Lightweight variant for quick processing (`gemini-3.5-flash-lite`)

### On-Device AI

The on-device AI feature enables completely private, offline AI processing through MLX Swift. Existing installations that still have llama.cpp selections or downloaded GGUF models are migrated and cleaned up once at startup.

#### MLX Swift (Default)

- **4GB+ RAM**: Ternary Bonsai 1.7B (~470 MB) - compact model for devices with limited memory
- **6GB+ RAM**: Ternary Bonsai 4B (~1.1 GB) - default model for most supported devices
- **8GB+ RAM**: Ternary Bonsai 8B (~2.3 GB) - slower but higher-quality summaries
- **Native macOS, 16GB+ RAM**: Ternary Bonsai 27B (~8.5 GB) - laptop-class reasoning; unavailable on iOS
- **Context Window**: 16K tokens
- **Migration**: Existing llama.cpp model selections map to the closest Ternary Bonsai size tier; the migration removes known legacy GGUF files and llama.cpp settings. Stale selections on devices below 4GB use the Mistral AI fallback because MLX requires 4GB+ RAM.
- **Requirements**: MLX Swift requires 4GB+ RAM. Apple Native requires iOS 26+ and an Apple Intelligence-capable device.
- **Downloads**: WiFi by default with optional cellular download support

## Configuration
- Secrets are entered in‑app via setup views (compatible API, Mistral AI, Google, Whisper). All keys/tokens are persisted to the iOS Keychain through `KeychainSecretStore`; legacy `UserDefaults` values are migrated automatically on first launch of v1.11. Do not commit API keys.
- User-configurable AI endpoints (compatible API, Ollama on native macOS, and Whisper) are validated via `EndpointSecurityPolicy` — public cleartext destinations are blocked unless the per-service Development Mode override is enabled. Ollama defaults to the Mac-local server at `http://localhost:11434`.
- Legacy iPhone/iPad Ollama selections migrate to MLX/on-device AI when the device supports it; native macOS keeps Ollama as a local engine.
- Enable required capabilities in Xcode (Microphone, Background Modes, iCloud if used). Keep `Info.plist` and `.entitlements` aligned with features. `APS_ENVIRONMENT` is set per-configuration so Debug uses `development` and Release uses `production`.
- Before distributing iCloud sync changes through TestFlight or the App Store, deploy CloudKit development schema changes for `iCloud.Bison-Networking.BisonNotes-AI` to production. Production builds cannot create new CloudKit record types at runtime.
- For On Device transcription, Parakeet is the only on-device engine (WhisperKit was removed in v1.8). Download the model in Setup → Transcription Settings → On Device. Local Speaker Labels use a separate explicit speaker-model action; they do not silently download when transcription starts.
- For on-device AI, device capability checks ensure your device meets requirements (4 GB+ RAM for MLX Swift, iOS 26+ and an Apple Intelligence-capable device for Apple Native) before allowing downloads.

## iPhone Action Button Setup
If you have an iPhone 15 Pro, iPhone 15 Pro Max, iPhone 16 Pro, iPhone 16 Pro Max, or future iPhone Pro models with an Action Button, you can configure it to start recording instantly:

1. Open **Settings** on your iPhone
2. Tap **Action Button**
3. Select **Shortcut**
4. Choose **"Start Recording"** from BisonNotes AI
5. Press the Action Button to test - it will launch BisonNotes AI and start recording automatically!

**What happens when you press the Action Button:**
- The app opens automatically (even if it was closed)
- Switches to the Recordings tab
- Recording starts immediately without needing to tap the microphone button
- Recording continues in the background if you switch apps or lock your phone

The Action Button works even when your phone is locked, making it perfect for quick voice notes!

## Search and Filtering

The app includes powerful search and filtering capabilities to help you find your recordings, transcripts, and summaries quickly.

### Search Functionality

Search is available in three main views:

- **Summaries View**: Search across summary content, tasks, reminders, titles, and recording names
- **Transcripts View**: Search through transcript text and recording names
- **Recordings View**: Search by recording name

**How to use:**
- Tap the search bar at the top of any view
- Type your search terms
- Results filter in real-time as you type
- Search is case-insensitive and matches partial text

### Date Filters

Date range filtering helps you find content from specific time periods:

- **Available in**: Summaries, Transcripts, and Recordings views
- **How to use**:
  1. Tap the filter icon (three horizontal lines with circle) in the navigation bar
  2. Select a start date and end date
  3. Tap "Apply" to filter results
  4. The active filter is shown with a banner at the top of the list
  5. Tap the X on the banner to clear the filter

**Filter Behavior:**
- Filters can be combined with search for precise results
- Date range includes the full day (00:00:00 to 23:59:59) for both start and end dates
- Filters persist until manually cleared

## Share Extension

Import audio and transcript files from other apps directly into BisonNotes AI using the iPhone, iPad, or Mac Share menu:

- **Supported audio formats**: M4A, MP3, WAV, CAF, AIFF, AIF
- **Supported document formats**: TXT, MD, VTT, SRT, PDF, DOC, DOCX
- **How it works**:
  1. Open Voice Memos, Files, Finder, or another app with an audio or transcript file
  2. Tap or click the share button and select "BisonNotes AI"
  3. The file is saved to the protected shared container
  4. BisonNotes AI opens or is notified and imports the file
- **Background import**: If the main app is already running, a Darwin notification wakes it to scan for new files immediately
- **Busy import handling**: If another import is active, the new file remains staged and is retried on a later app activation instead of being discarded
- **File naming**: Imported files are prefixed with a UUID to prevent name collisions

## Import From Link

Import audio, video, and transcript content from web addresses without downloading the file manually first:

- **Where to start**: Tap **Import From Link** on the Recordings screen, or use **File > Import From Link...** on Mac.
- **Direct audio/video URLs**: Supported media links include M4A, MP3, WAV, CAF, AIFF, AIF, MP4, MOV, M4V, AVI, and MKV. Video imports extract the audio to M4A for transcription.
- **Direct transcript URLs**: Supported transcript/document links include TXT, MD, VTT, SRT, PDF, DOC, and DOCX. Imported transcripts can be summarized without an audio file.
- **YouTube links**: YouTube share links are recognized and the app attempts to import public captions as a transcript. YouTube audio/video is not downloaded directly.
- **YouTube recovery flow**: If YouTube blocks the caption request, the sheet shows directions, an **Open YouTube Video** button, and a pasted-transcript import box. Copy the transcript from YouTube, paste it into BisonNotes, and import it for summary generation.
- **Endpoint safety**: Public HTTP links are blocked. Use HTTPS, localhost, or private-network addresses.

## Combine Recordings

Merge two separate recordings into a single continuous audio file:

1. Open the Recordings tab
2. Enter selection mode and tap the checkbox next to two recordings
3. Tap "Combine" to open the combination interface
4. Choose the playback order (which recording comes first)
5. Preview the combined duration, then tap "Combine Recordings"
6. The new combined recording appears in your list; optionally delete the originals

**Requirements**: Both recordings must have no existing transcripts or summaries. Delete any transcripts/summaries first, then combine. After combining, generate new transcripts and summaries for the merged file.

## Acknowledgments

BisonNotes AI is built on the shoulders of several outstanding open-source projects. We gratefully acknowledge the following:

### Direct Dependencies

| Project | Description | License | Link |
|---------|-------------|---------|------|
| **Textual** | Markdown rendering library used to display AI-generated summaries, transcripts, and formatted content. | MIT | [gonzalezreal/Textual](https://github.com/gonzalezreal/Textual) |
| **FluidAudio** | On-device speech framework powering Parakeet transcription. | Apache 2.0 | [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) |
| **MLX Swift / MLX Swift LM** | Apple Silicon ML framework and language-model utilities used for on-device summarization with Ternary Bonsai models. | MIT | [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) / [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) |
| **Swift Transformers** | Hugging Face tokenizers and transformer utilities for local ML model pipelines. | Apache 2.0 | [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers) |

### Transitive Dependencies

The direct dependencies bring in a number of excellent open-source libraries from the Apple Swift ecosystem and broader community:

- **Swift libraries**: [Swift NIO](https://github.com/apple/swift-nio), [Swift Crypto](https://github.com/apple/swift-crypto), [Swift Collections](https://github.com/apple/swift-collections), [Swift Atomics](https://github.com/apple/swift-atomics), [Swift System](https://github.com/apple/swift-system), [Swift Numerics](https://github.com/apple/swift-numerics), and [Swift ASN1](https://github.com/apple/swift-asn1)
- **Networking and data utilities**: [EventSource](https://github.com/mattt/EventSource), [yyjson](https://github.com/ibireme/yyjson)
- **Hugging Face**: [Swift Jinja](https://github.com/huggingface/swift-jinja), [Swift HuggingFace](https://github.com/huggingface/swift-huggingface)
- **UI support**: [SwiftUI Math](https://github.com/gonzalezreal/swiftui-math)
- **Point-Free**: [Swift Concurrency Extras](https://github.com/pointfreeco/swift-concurrency-extras)

The software dependencies listed above are MIT or Apache 2.0 licensed as shown; see each project's repository for full license terms. Downloaded model assets are separate from software dependencies and have their own terms:

- **Offline VBx / Pyannote Core ML assets**: [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml), CC BY 4.0 for the parent Pyannote material; the FluidAudio SDK is Apache 2.0.
- **LS-EEND DIHARD3 Core ML assets**: [FluidInference/ls-eend-coreml](https://huggingface.co/FluidInference/ls-eend-coreml), MIT; upstream dataset terms remain applicable.

The LS-EEND model card and original paper/source credits should be reviewed with the model terms before release. BisonNotes does not redistribute consented or evaluation fixtures.

## Contributing
Follow the Local Dev Setup above to run and validate changes before opening a PR.

## License
See LICENSE.
