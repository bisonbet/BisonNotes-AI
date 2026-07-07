# BisonNotes AI

SwiftUI app for recording audio, transcribing it with local or cloud engines, and generating summaries, tasks, and reminders. Ships on **iOS, iPadOS, watchOS, and macOS (Mac Catalyst)**. Core Data powers persistence; background jobs handle long/complex processing; WatchConnectivity imports complete watch recordings back to the phone.

AVAILABLE ON THE APP STORE: https://apps.apple.com/us/app/bisonnotes-ai-voice-notes/id6749189425

Quick links: [Full User Guide](docs/bisonnotes-ai-guide.html) • [Accessibility Matrix](docs/accessibility-matrix.md) • [Mistral AI Free Setup](docs/mistral-free-setup.md) • [Regression Testing Regimen](docs/testing-regimen.md) • [Build & Test](#build-and-test) • [Architecture](#architecture)

## v2.2 Highlights
- Import from web links can now bring in direct audio/video files, transcript documents, and public YouTube captions, with a guided pasted-transcript recovery flow when YouTube blocks automated caption downloads.
- Common iPhone, iPad, Mac Catalyst, and Apple Watch tasks now have explicit VoiceOver labels, values, hints, and non-color state cues across setup, recording, imports, recordings, playback, transcripts, summaries, settings, and watch recording.
- The custom audio scrubber remains visually unchanged but is exposed as an adjustable accessibility control with current/remaining time and 15-second seek increments.
- Recording, transcript, and summary rows expose contextual status such as duration, file size, archive/local audio, iCloud/local-only state, transcript availability, summary availability, task/reminder counts, and location availability.
- Apple Watch recording now exposes state for the main record/stop control, mute/pause, transfer progress, low battery, and error recovery, and the pulsing recording indicators respect Reduce Motion.
- A dedicated accessibility evidence set was added: `docs/accessibility-matrix.md`, `docs/app-store-accessibility.md`, `docs/accessibility.html`, and `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIAccessibilityTests.swift`.

## v2.1 Highlights
- Mac Catalyst can optionally record meeting audio from other Mac apps and mix it with the microphone recording. The setting lives in Settings > Recording as **Record Meeting Audio**, requires macOS Screen & System Audio Recording permission, and falls back to microphone-only audio if permission or mixing fails.
- iCloud sync now uses stronger guardrails: a HIPAA notice before enabling sync, per-recording **Keep on This Device** exclusions, deletion markers, active-manifest review for older cloud-only items, and clearer production CloudKit schema errors.
- Parakeet transcription recovery is more reliable. The app recognizes cached model files after app updates or settings resets, supports English v2 and multilingual v3 model choices, reports download/prepare progress more accurately, and avoids short final tail chunks during long on-device transcriptions.
- Recording reliability is improved through stricter audio session ownership, safer background processing interruption handling, crash-safe recording recovery, and conservative cleanup of stale temporary audio files.
- Release validation now has app/watch `.xctestplan` files, deterministic UI-test launch fixtures, focused iCloud and transcription regression tests, and a documented regression testing regimen.

## v2.0 Foundation Highlights
- Modernized SwiftUI interface across Recordings, Transcripts, Summaries, Setup, and Settings, with denser action placement and cleaner status surfaces.
- Redesigned watchOS recorder around one large tap target: tap to record, tap to stop, and use mute to pause/resume the same file. Transfer status and low-battery warnings stay visible without crowding the primary action.
- On Device AI is now backed by MLX Swift by default on supported devices. New/legacy users with 4 GB+ RAM migrate to MLX automatically; devices below that fall back to Mistral AI.
- Legacy llama.cpp On-Device AI remains available for 6 GB+ devices, but the removed LFM 2.5 model is deleted during migration and no longer appears in model lists.
- Mac Catalyst support is arm64-only with a dedicated archive script and Catalyst entitlements for microphone, networking, calendar, file access, app sandbox, and iCloud.
- Watch sync no longer uses live audio chunks or phone-side recording control. The watch records independently, sends the finished file via `WCSession.transferFile`, and receives queued completion/failure confirmations.

## Architecture
- Data: Core Data model at `BisonNotes AI/BisonNotes_AI.xcdatamodeld` stores recordings, transcripts, summaries, and jobs. Sensitive credentials (API keys, AWS access keys, Bedrock session tokens) live in the iOS Keychain, never on disk in plaintext.
- Engines: Pluggable services for On Device transcription, OpenAI, OpenAI-compatible APIs, Mistral AI, Google AI Studio, AWS Bedrock/Transcribe, Whisper (REST), Wyoming streaming, Ollama, On Device AI (MLX Swift), On Device AI Legacy (llama.cpp), and Apple Native (Foundation Models). Each engine pairs a service with a settings view.
- Background: `BackgroundProcessingManager` coordinates queued work with retries, timeouts, and recovery. Large files are chunked and processed streaming‑first.
- Recording: A platform-aware audio pipeline — `AVAudioRecorder` on iOS/iPadOS, `AVAudioEngine` on Mac Catalyst (`AudioRecorderViewModel+CatalystEngine.swift`) — with shared Pause/Resume support, optional Mac meeting-audio capture through `CatalystSystemAudioCapture`, and crash-safe interruption handling.
- Watch Sync: `WatchConnectivityManager` (on iOS and watch targets) manages reachability, complete-file transfers, duplicate protection, queued acknowledgments, and import recovery. Watch complications and a Control Center recording widget are bundled as separate targets.
- UI: SwiftUI views under `Views/` implement recording, summaries, transcripts, setup, and settings. AI-generated content uses MarkdownUI for professional formatting. View models isolate state and side effects.

## Project Structure
- `BisonNotes AI/`: iOS / iPadOS / Mac Catalyst app source
  - Notable folders: `Models/`, `Views/`, `ViewModels/`, `OpenAI/`, `AWS/`, `Wyoming/`, `WatchConnectivity/`, `OnDeviceLLM/`, `FluidAudio/`, `Services/`
  - Assets: `Assets.xcassets`; config: `Info.plist`, `.entitlements`
  - Uses Xcode's file-system synchronized groups, so dropping new Swift files into these folders automatically adds them to the project—no manual `.xcodeproj` edits are necessary.
- `BisonNotes Share/`: Share Extension target for importing audio from other apps (excluded from Mac Catalyst embed phase)
- `BisonNotes AI Watch App/`: watchOS companion app (excluded from Mac Catalyst embed phase)
- `BisonNotes Watch Widget/`: Watch complications surface for live recording state
- `BisonNotes AI Controls/`: Control Center recording widget (Recording Control Widget)
- Tests: `BisonNotes AITests/` (unit), `BisonNotes AIUITests/` (UI), plus watch tests

## Build and Test
- Open in Xcode: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`
- Build (iOS): `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -configuration Debug build`
- Test (iOS): `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 15'`
- Build (Mac Catalyst): `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=macOS,variant=Mac Catalyst' -configuration Debug build`
- Archive (Mac Catalyst): `Scripts/archive-catalyst.sh`. Use this script instead of Product > Archive so the arm64-only Catalyst setting reaches SwiftPM package targets.
- Use the watch app scheme to run the watch target. SwiftPM resolves automatically in Xcode.
- Release validation should follow [docs/testing-regimen.md](docs/testing-regimen.md), including app/watch test plans, Mac Catalyst build coverage, and manual hardware checks for microphone, watch transfer, iCloud, Parakeet, share import, Control Center, Action Button, and Mac meeting audio.
- Accessibility validation should include the automated UI audit class:
  `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:"BisonNotes AIUITests/BisonNotesAIAccessibilityTests"`
- Real-device accessibility release checks are still required for VoiceOver, Voice Control, Switch Control sampling, Full Keyboard Access on iPad/Mac Catalyst, largest Dynamic Type, light/dark contrast modes, Reduce Motion, Apple Watch VoiceOver, Control Center, and Action Button.
- See `CLAUDE.md` for the manual `llama.xcframework` Mac Catalyst slice, duplicate-library modulemap cleanup, AWS/Smithy archive constraint, and `bisonbet/textual` Catalyst guards if you rebuild dependencies.

## Accessibility Development Notes
- Shared accessibility strings and modifiers live in `BisonNotes AI/BisonNotes AI/AccessibilitySupport.swift`. Prefer these helpers for duration/status strings, row labels, announcements, and custom card semantics instead of one-off labels.
- Stable automation identifiers live in `BisonNotes AI/BisonNotes AI/AccessibilityIdentifiers.swift`. Add identifiers only for surfaces needed by UI tests, audit navigation, or repeated external automation.
- Deterministic accessibility UI tests live in `BisonNotes AI/BisonNotes AIUITests/BisonNotesAIAccessibilityTests.swift` and use DEBUG launch arguments from `UITestSupport.swift`, including `--show-first-setup`.
- App Store accessibility evidence lives in `docs/accessibility-matrix.md` and `docs/app-store-accessibility.md`. Keep those files and the public `docs/accessibility.html` page aligned with implemented behavior before claiming Accessibility Nutrition Labels.
- The shared SwiftUI app surfaces carry over to Mac Catalyst, but Catalyst still needs manual VoiceOver, Full Keyboard Access, keyboard navigation, window resizing, and real iCloud/file import validation on a Mac.

## Dependencies

The project uses Swift Package Manager for dependency management. Major dependencies include:

### **Cloud Services**
- **AWS SDK for Swift**: Cloud transcription and AI processing
  - Pinned to exact `1.6.113` in v2.0 to avoid the Smithy build-tool plugin archive collision in Mac Catalyst archives
  - `AWSBedrock` & `AWSBedrockRuntime`: Claude AI models (Claude 4.5 Haiku, Claude Sonnet 4.5, Llama 4 Maverick)
  - `AWSTranscribe` & `AWSTranscribeStreaming`: Speech-to-text
  - `AWSS3`: File storage and retrieval
  - `AWSClientRuntime`: Core AWS functionality

### **On-Device AI**
- **MLX Swift / MLX Swift LM**: Backs the default On Device AI summarization path in v2.0.
  - Models: Ternary Bonsai 1.7B (~470 MB, 4 GB+ RAM), 4B (~1.1 GB, 6 GB+ RAM, default), and 8B (~2.3 GB, 8 GB+ RAM)
  - Models download from Hugging Face on first use and run locally after download
  - 4-6 GB devices use the 1.7B model; 6 GB+ devices default to the 4B model; 8 GB+ devices can select the 8B model
- **llama.cpp**: Embedded as a pre-compiled xcframework (`Frameworks/llama.xcframework`) for Metal-accelerated on-device LLM inference
  - GitHub: https://github.com/ggerganov/llama.cpp
  - Supports GGUF model format with Q4_K_M quantization (optimal for mobile)
  - Available models: Gemma 3n E4B/E2B, Granite 4.0 H Tiny/Micro, Ministral 3B, Qwen3.5 2B/4B
  - Legacy engine in v2.0; models require 6 GB+ RAM, with 8 GB+ for larger models
  - **Mac Catalyst note**: The upstream xcframework has no `maccatalyst` slice. The `ios-arm64-maccatalyst` slice in this repo was manually created from the macOS arm64 binary (`lipo -thin arm64`) and patched with `vtool -set-build-version maccatalyst 14.0 15.5`. If you rebuild or update the xcframework, repeat these steps and update `Frameworks/llama.xcframework/Info.plist` accordingly. Full instructions are in `CLAUDE.md` under "Mac Catalyst Build Notes".

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
- Requirements: macOS with Xcode (15+ recommended) and Command Line Tools (`xcode-select --install`).
- Clone/fork the repo, then open: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`.
- Select the "BisonNotes AI" scheme (iOS) or the watch scheme, choose a Simulator/device, and Run/ Test.
- Branch/PR: create a feature branch in your fork, push changes, and open a PR. Include build/test results and screenshots for UI changes.

## Key Features
- **Modern v2.0 UI**: Recordings, Transcripts, Summaries, Setup, and Settings use refreshed SwiftUI layouts with clearer action placement, sectioned date lists, and Catalyst-friendly navigation.
- **Accessibility-ready task flows (v2.2)**: VoiceOver and Voice Control labels, values, hints, contextual row summaries, adjustable playback scrubber support, Reduce Motion handling, accessibility UI audits, and App Store accessibility evidence docs cover the common iPhone/iPad, Mac Catalyst, and Apple Watch workflows.
- **Mac Catalyst (v2.1)**: Native Apple Silicon Mac build with a Catalyst-specific audio pipeline, optional meeting-audio capture from other Mac apps, sandbox entitlements, iCloud archive support, and an arm64-only archive path.
- **Pause and Resume Recording**: Pause mid-meeting without stopping the file. Resume seamlessly across iOS, iPadOS, watchOS mute/resume, and Mac Catalyst (separate `AVAudioEngine` path on Catalyst).
- **Hardened Credential Storage (v1.11)**: API keys, AWS credentials, and Bedrock session tokens stored in the iOS Keychain. Legacy values are migrated automatically and kept out of iCloud settings backups. File protection is applied to recordings, transcripts, notes, attachments, and the Core Data SQLite files.
- **Endpoint Safety (v1.11)**: User-configurable OpenAI, OpenAI-compatible, Ollama, and Whisper endpoints are validated — public cleartext (HTTP/WS) destinations are blocked by default; local/private endpoints stay allowed, with a Development Mode toggle for power users.
- **Source-Centric Workflow (v1.11)**: "Generate Transcript" lives on the recording row; "Generate Summary" lives on the transcript. Buttons only appear where they apply and disappear once the artifact exists — regeneration happens from the existing detail view.
- **iPhone Action Button Support**: Quick-start recording from the Action Button on iPhone 15 Pro/Pro Max, iPhone 16 Pro/Pro Max, and future Pro models. Press the Action Button to launch the app and start recording instantly, even when your phone is locked.
- **Watch App & Complications**: Single-button Apple Watch recorder with tap-to-record/tap-to-stop, mute as pause/resume on the same file, pulsing capture state, low-battery warning, automatic complete-file sync, and watch-face complications.
- **Control Center Recording Widget**: Start/stop recordings from Control Center on iOS 18+ via the bundled Controls widget.
- **Multiple AI Engines**: Support for OpenAI, AWS Bedrock, Google AI Studio, Mistral AI, OpenAI-compatible endpoints, Ollama, On Device AI (MLX Swift), On Device AI Legacy (llama.cpp), and Apple Native (Apple Intelligence).
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
- **iCloud Backup & Sync**: Automatic backup and cross-device reconcile on app activation, CloudKit summary sync with paginated queries and schema-safe fallback, deferred auto-backup, and a per-recording **Keep on This Device** tag that excludes a recording, transcript, and summary from BisonNotes iCloud sync and backup. Sensitive settings (API keys, AWS credentials) are excluded from iCloud settings backups by default.
- **Search Functionality**: Powerful search across recordings, transcripts, and summaries. Search by recording name, transcript text, summary content, tasks, reminders, and titles.
- **Date Filters**: Filter recordings, transcripts, and summaries by date range. Select start and end dates to quickly find content from specific time periods.

## Key Modules
- Recording: `EnhancedAudioSessionManager`, `AudioFileChunkingService`, `AudioRecorderViewModel` (+ `+CatalystEngine`, `+Interruptions`, `+Background`, `+CallIntelligence`, `+Warnings`), `CatalystSystemAudioCapture`, `RecordingCombiner`, `TranscriptionStarter`
- Transcription: `FluidAudioManager` (Parakeet), `OpenAITranscribeService`, `MistralTranscribeService`, `WhisperService`, `WyomingWhisperClient`, `AWSTranscribeService`, `LiveTranscriptionService`
- Web Import: `WebImportManager`, `WebImportDownloader`, `WebImportURLClassifier`, `YouTubeImportService`, `YouTubePlayerResponseParser`, `TranscriptCaptionTextCleaner`
- Summarization: `OpenAISummarizationService`, `MistralAISummarizationService`, `GoogleAIStudioService`, `AWSBedrockService`, `OnDeviceLLMService`, `MLXSwiftEngine`, `AppleNativeEngine`
- Security: `KeychainSecretStore`, `AWSCredentialsManager`, `AWSClientCredentialResolver`, `EndpointSecurityPolicy`, `AppFileProtection`
- Export: `PDFExportService`, `SummaryExportFormatter`, `RecordingArchiveService`
- UI: `SummariesView`, `SummaryDetailView`, `TranscriptionProgressView`, `AITextView` (with MarkdownUI), `CombineRecordingsView`
- Accessibility: `AccessibilitySupport`, `AccessibilityIdentifiers`, `UITestSupport`, and `BisonNotesAIAccessibilityTests`
- Persistence: `Persistence`, `CoreDataManager`, models under `Models/`
- Background: `BackgroundProcessingManager`, `TemporaryFileCleanupService`
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

iOS, iPadOS, and Mac Catalyst builds use the shared iCloud container `iCloud.Bison-Networking.BisonNotes-AI` for app-managed CloudKit sync. Devices must be signed into the same Apple ID and use the same CloudKit environment to see the same records. A local Debug build uses the CloudKit development environment, while TestFlight and App Store builds use production, so a Debug Mac Catalyst install will not see records created by a production iPhone or iPad build until the build channel/environment matches.

Production iCloud sync requires the CloudKit production schema for `iCloud.Bison-Networking.BisonNotes-AI` to include the app-managed backup record types `CD_BackupRecording`, `CD_BackupTranscript`, `CD_BackupSummary`, `CD_BackupSettings`, `CD_BackupContentIndex`, and `CD_BackupDeletion`. Before shipping TestFlight or App Store builds that use these records, create/verify them in the development environment and deploy the CloudKit schema changes to production from CloudKit Dashboard. Production clients cannot create new record types themselves.

Current app versions mark synced content as active before it is automatically restored on other devices. Older cloud-only items that are not marked active are held in **Settings > iCloud Sync > Review iCloud Items**, where they can be restored or deleted from BisonNotes iCloud sync records.

## Transcription Engines

The app supports multiple transcription engines for converting audio to text:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **On Device (Parakeet)** | Default. On-device transcription using NVIDIA Parakeet models. Complete privacy. | iOS 17.0+, model download |
| **OpenAI** | Cloud-based transcription using OpenAI's GPT-4o models and Whisper API | API key, internet |
| **Mistral AI** | Cloud transcription using Voxtral Mini with speaker diarization ($0.003/min) | API key, internet |
| **Whisper (Local Server)** | High-quality transcription using OpenAI's Whisper model on your local server | Whisper server running (REST API or Wyoming protocol) |
| **AWS Transcribe** | Cloud-based transcription service with support for long audio files | AWS credentials, internet |

### OpenAI Transcription Models

OpenAI transcription supports multiple models:

- **GPT-4o Transcribe**: Most robust transcription with GPT-4o model. Supports streaming for real-time transcription.
- **GPT-4o Mini Transcribe**: Cheapest and fastest transcription with GPT-4o Mini model. Supports streaming. Recommended for most use cases.
- **Whisper-1**: Legacy transcription with Whisper V2 model. Does not support streaming.

### On Device Transcription

#### FluidAudio Parakeet (Default)

Parakeet is the sole on-device transcription engine as of v1.8 (WhisperKit was removed). It provides fast, accurate, fully local transcription:

- **Privacy**: 100% local processing - audio never leaves your device
- **Offline**: Works completely offline after initial model download
- **Requirements**: iOS 17.0 or later
- **Models**: Parakeet v2 for English long-form recall and Parakeet v3 for multilingual transcription across 25 European languages
- **Reliability**: v2.1 recognizes valid cached model files, restores the selected model version when possible, resets stale download state when files are gone, and absorbs very short final tail chunks during long on-device transcriptions
- **Migration**: Existing users who had WhisperKit selected are automatically switched to Parakeet on first launch of v1.8

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
| **OpenAI** | GPT-4.1 Mini, GPT-5 Mini, GPT-5.4 Mini | API key, internet |
| **OpenAI Compatible** | Any OpenAI-compatible API (Nebius, Groq, LiteLLM, llama.cpp, etc.) | API key, internet |
| **Mistral AI** | Mistral Large (25.12), Medium (25.08), Magistral Medium (25.09) | API key, internet |
| **Google AI Studio** | Gemini 3 Flash Preview (default), Gemini 3.1 Flash Lite Preview | API key, internet |
| **AWS Bedrock** | Claude 4.5 Haiku, Claude Sonnet 4.5, Llama 4 Maverick 17B Instruct | AWS credentials |
| **Ollama** | Local LLM server (recommended: qwen3:30b, gpt-oss:20b, mistral-small3.2) | Ollama server running |
| **On Device AI** | Default on-device summarization with MLX Swift and Ternary Bonsai models | 4 GB+ RAM, model download |
| **On Device AI (Legacy)** | Fully offline llama.cpp summaries with GGUF models | 6 GB+ RAM, model download |

### OpenAI Models

OpenAI summarization supports multiple models:

- **GPT-4.1 Mini**: Balanced performance and cost, suitable for most summarization tasks (Standard tier) - Default
- **GPT-5 Mini**: Next-generation reasoning model with enhanced efficiency (Premium tier)
- **GPT-5.4 Mini**: Latest GPT-5 mini with improved reasoning and efficiency (Premium tier)

### AWS Bedrock Models

AWS Bedrock provides access to multiple foundation models:

- **Claude 4.5 Haiku**: Fast and efficient model optimized for quick responses (Standard tier) - Default
- **Claude Sonnet 4.5**: Latest Claude Sonnet with advanced reasoning, coding, and analysis capabilities (Premium tier)
- **Llama 4 Maverick 17B Instruct**: Meta's latest Llama 4 model with enhanced reasoning and performance (Economy tier)

### Mistral AI Models

Mistral AI offers a **free Experiment tier** (no credit card required) with access to all models, plus paid Build and Scale tiers for higher rate limits. The app includes a **guided in-app setup wizard** that walks new users through account creation and API key provisioning in about 2 minutes. See [Mistral AI Free Setup Guide](docs/mistral-free-setup.md) for details.

Summarization models:

- **Mistral Large (25.12)**: Most capable Mistral model with 128K context window (Premium tier)
- **Mistral Medium (25.08)**: Balanced performance and cost with 128K context (Standard tier)
- **Magistral Medium (25.09)**: Economy option with 40K context window (Economy tier)

### Google AI Studio Models

Google AI Studio provides access to Gemini models:

- **Gemini 3 Flash Preview**: Fast and efficient — Default (`gemini-3-flash-preview`)
- **Gemini 3.1 Flash Lite Preview**: Lightweight variant for quick processing (`gemini-3.1-flash-lite-preview`)

### On-Device AI

The on-device AI feature enables completely private, offline AI processing. v2.1 uses MLX Swift as the default local summarization engine and keeps the original llama.cpp engine as a legacy option for higher-memory devices.

#### MLX Swift (Default)

- **4GB+ RAM**: Ternary Bonsai 1.7B (~470 MB) - compact model for devices with limited memory
- **6GB+ RAM**: Ternary Bonsai 4B (~1.1 GB) - default model for most supported devices
- **8GB+ RAM**: Ternary Bonsai 8B (~2.3 GB) - slower but higher-quality summaries
- **Context Window**: 16K tokens
- **Migration**: Existing users on the removed LFM model or legacy llama on sub-6GB devices are moved to MLX 1.7B when possible. Devices below 4GB fall back to Mistral AI.

#### On-Device AI Legacy (llama.cpp)

- **Recommended Models** (by device RAM):
  - **8GB+ RAM**: Gemma 3n E4B (4.5 GB) - Best overall quality
  - **6GB+ RAM**: Gemma 3n E2B (3.0 GB) - Good quality, smaller size
  - **6GB+ RAM**: Granite 4.0 Micro (2.1 GB) - Very fast processing

- **Experimental Models** (enable in settings):
  - **8GB+ RAM**: Granite 4.0 H Tiny (4.3 GB) - Reliable and accurate
  - **6GB+ RAM**: Ministral 3B (2.1 GB) - Best for tasks and reminders
  - **6GB+ RAM**: Qwen3.5 2B (1.3 GB) - Latest Qwen3.5 model, thinking mode (summary only)
  - **8GB+ RAM**: Qwen3.5 4B (2.7 GB) - Excellent detail extraction, thinking mode

- **Quantization**: Q4_K_M only (optimal balance of quality and memory usage)
- **Storage**: Models stored in Application Support (1.3 GB - 4.5 GB each)
- **Context Window**: 16K tokens (automatically adjusted based on device RAM)
- **Requirements**:
  - **Transcription**: iOS 17.0+, 4GB+ RAM (most modern iPhones and iPads). Uses Parakeet on-device transcription by default when supported (requires model download)
  - **AI Summary**: MLX Swift requires 4GB+ RAM. Legacy llama.cpp models require 6GB+ RAM. Apple Native requires iOS 26+ and an Apple Intelligence-capable device.
  - Device capability check prevents downloads on unsupported devices
  - Models are filtered based on available RAM
- **Downloads**: WiFi by default with optional cellular download support

## Configuration
- Secrets are entered in‑app via setup views (OpenAI, Mistral AI, Google, AWS, Ollama, Whisper). All keys/tokens are persisted to the iOS Keychain through `KeychainSecretStore`; legacy `UserDefaults` values are migrated automatically on first launch of v1.11. Do not commit API keys.
- AWS process-environment credentials (`AWS_ACCESS_KEY_ID` etc.) are cleared at launch; Bedrock, Transcribe, and background jobs use explicit credential resolvers from `AWSCredentialsManager`.
- User-configurable AI endpoints (OpenAI/OpenAI-Compatible/Ollama/Whisper) are validated via `EndpointSecurityPolicy` — public cleartext destinations are blocked unless the per-service Development Mode override is enabled.
- Enable required capabilities in Xcode (Microphone, Background Modes, iCloud if used). Keep `Info.plist` and `.entitlements` aligned with features. `APS_ENVIRONMENT` is set per-configuration so Debug uses `development` and Release uses `production`.
- Before distributing iCloud sync changes through TestFlight or the App Store, deploy CloudKit development schema changes for `iCloud.Bison-Networking.BisonNotes-AI` to production. Production builds cannot create new CloudKit record types at runtime.
- For On Device transcription, Parakeet is the only on-device engine (WhisperKit was removed in v1.8). Download the model in Setup → Transcription Settings → On Device.
- For on-device AI, device capability checks ensure your device meets requirements (4 GB+ RAM for MLX Swift, 6 GB+ RAM for legacy llama.cpp models, iOS 26+ and an Apple Intelligence-capable device for Apple Native) before allowing downloads.

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

Import audio and transcript files from other apps directly into BisonNotes AI using the iOS share sheet:

- **Supported audio formats**: M4A, MP3, WAV, CAF, AIFF, AIF
- **Supported document formats**: TXT, MD, VTT, SRT, PDF, DOC, DOCX
- **How it works**:
  1. Open Voice Memos, Files, or any app with audio or transcript files
  2. Tap the share button and select "BisonNotes AI"
  3. The file is saved to the shared container
  4. BisonNotes AI opens automatically and imports the file
- **Background import**: If the main app is already running, a Darwin notification wakes it to scan for new files immediately
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
| **llama.cpp** | C/C++ inference engine for on-device LLM processing. Embedded as a pre-compiled xcframework for Metal-accelerated local AI summarization. | MIT | [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| **AWS SDK for Swift** | Cloud services SDK powering AWS Bedrock (Claude, Llama), Transcribe, and S3 integrations. | Apache 2.0 | [awslabs/aws-sdk-swift](https://github.com/awslabs/aws-sdk-swift) |
| **Swift Transformers** | Hugging Face tokenizers and transformer utilities for local ML model pipelines. | Apache 2.0 | [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers) |

### Transitive Dependencies

The AWS SDK and other direct dependencies bring in a number of excellent open-source libraries from the Apple Swift ecosystem and broader community:

- **Apple Swift Server libraries**: [Swift NIO](https://github.com/apple/swift-nio), [Swift NIO Extras](https://github.com/apple/swift-nio-extras), [Swift NIO HTTP/2](https://github.com/apple/swift-nio-http2), [Swift NIO SSL](https://github.com/apple/swift-nio-ssl), [Swift NIO Transport Services](https://github.com/apple/swift-nio-transport-services), [Swift Crypto](https://github.com/apple/swift-crypto), [Swift Protobuf](https://github.com/apple/swift-protobuf), [Swift Collections](https://github.com/apple/swift-collections), [Swift Algorithms](https://github.com/apple/swift-algorithms), [Swift Log](https://github.com/apple/swift-log), [Swift Metrics](https://github.com/apple/swift-metrics), [Swift Atomics](https://github.com/apple/swift-atomics), [Swift System](https://github.com/apple/swift-system), [Swift Async Algorithms](https://github.com/apple/swift-async-algorithms), [Swift Argument Parser](https://github.com/apple/swift-argument-parser), [Swift Numerics](https://github.com/apple/swift-numerics), [Swift Certificates](https://github.com/apple/swift-certificates), [Swift ASN1](https://github.com/apple/swift-asn1), [Swift HTTP Types](https://github.com/apple/swift-http-types), [Swift HTTP Structured Headers](https://github.com/apple/swift-http-structured-headers), [Swift Distributed Tracing](https://github.com/apple/swift-distributed-tracing), [Swift Service Context](https://github.com/apple/swift-service-context), and [Swift Configuration](https://github.com/apple/swift-configuration)
- **Swift Server community**: [Async HTTP Client](https://github.com/swift-server/async-http-client), [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle)
- **Networking and data utilities**: [EventSource](https://github.com/mattt/EventSource), [yyjson](https://github.com/ibireme/yyjson)
- **gRPC**: [gRPC Swift](https://github.com/grpc/grpc-swift)
- **Observability**: [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift)
- **AWS infrastructure**: [AWS CRT Swift](https://github.com/awslabs/aws-crt-swift), [Smithy Swift](https://github.com/smithy-lang/smithy-swift)
- **Hugging Face**: [Swift Jinja](https://github.com/huggingface/swift-jinja), [Swift HuggingFace](https://github.com/huggingface/swift-huggingface)
- **UI support**: [SwiftUI Math](https://github.com/gonzalezreal/swiftui-math)
- **Point-Free**: [Swift Concurrency Extras](https://github.com/pointfreeco/swift-concurrency-extras)

All dependencies are MIT or Apache 2.0 licensed. See each project's repository for full license terms.

## Contributing
Follow the Local Dev Setup above to run and validate changes before opening a PR.

## License
See LICENSE.
