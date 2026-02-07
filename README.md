# BisonNotes AI

SwiftUI iOS + watchOS app for recording audio, transcribing it with local or cloud engines, and generating summaries, tasks, and reminders. Core Data powers persistence; background jobs handle long/complex processing; WatchConnectivity syncs state between watch and phone.

AVAILABLE ON THE APP STORE: https://apps.apple.com/us/app/bisonnotes-ai-voice-notes/id6749189425

Quick links: [Usage Quick Start](USAGE.md) • [Full User Guide](HOW_TO_USE.md) • [Build & Test](#build-and-test) • [Architecture](#architecture)

## Architecture
- Data: Core Data model at `BisonNotes AI/BisonNotes_AI.xcdatamodeld` stores recordings, transcripts, summaries, and jobs.
- Engines: Pluggable services for On Device transcription, OpenAI, OpenAI-compatible APIs, Mistral AI, Google AI Studio, AWS Bedrock/Transcribe, Whisper (REST), Wyoming streaming, Ollama, and On-Device AI. Each engine pairs a service with a settings view.
- Background: `BackgroundProcessingManager` coordinates queued work with retries, timeouts, and recovery. Large files are chunked and processed streaming‑first.
- Watch Sync: `WatchConnectivityManager` (on iOS and watch targets) manages reachability, queued transfers, and state recovery.
- UI: SwiftUI views under `Views/` implement recording, summaries, transcripts, and settings. AI-generated content uses MarkdownUI for professional formatting. View models isolate state and side effects.

## Project Structure
- `BisonNotes AI/`: iOS app source
  - Notable folders: `Models/`, `Views/`, `ViewModels/`, `OpenAI/`, `AWS/`, `Wyoming/`, `WatchConnectivity/`, `OnDeviceLLM/`, `WhisperKit/`
  - Assets: `Assets.xcassets`; config: `Info.plist`, `.entitlements`
  - Uses Xcode's file-system synchronized groups, so dropping new Swift files into these folders automatically adds them to the project—no manual `.xcodeproj` edits are necessary.
- `BisonNotes Share/`: Share Extension target for importing audio from other apps
- `BisonNotes AI Watch App/`: watchOS companion app
- Tests: `BisonNotes AITests/` (unit), `BisonNotes AIUITests/` (UI), plus watch tests

## Build and Test
- Open in Xcode: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`
- Build (iOS): `xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -configuration Debug build`
- Test (iOS): `xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 15'`
- Use the watch app scheme to run the watch target. SwiftPM resolves automatically in Xcode.

## Dependencies

The project uses Swift Package Manager for dependency management. Major dependencies include:

### **Cloud Services**
- **AWS SDK for Swift**: Cloud transcription and AI processing
  - `AWSBedrock` & `AWSBedrockRuntime`: Claude AI models (Claude 4.5 Haiku, Claude Sonnet 4.5, Llama 4 Maverick)
  - `AWSTranscribe` & `AWSTranscribeStreaming`: Speech-to-text
  - `AWSS3`: File storage and retrieval
  - `AWSClientRuntime`: Core AWS functionality

### **On-Device AI**
- **llama.cpp**: Embedded as a pre-compiled xcframework (`Frameworks/llama.xcframework`) for Metal-accelerated on-device LLM inference
  - GitHub: https://github.com/ggerganov/llama.cpp
  - Supports GGUF model format with Q4_K_M quantization (optimal for mobile)
  - Available models: Gemma 3n E4B/E2B, Granite 4.0 H Tiny/Micro, Ministral 3B, Qwen3 4B/1.7B, LFM 2.5 1.2B
  - Models filtered by device RAM (6GB+ for most, 8GB+ for larger models)

### **UI & Formatting**
- **MarkdownUI**: Professional markdown rendering for AI-generated summaries, headers, lists, and formatted text

### **On-Device Transcription**
- **WhisperKit**: High-quality on-device speech recognition
  - GitHub: https://github.com/argmaxinc/whisperkit
  - Supports multiple model sizes (Higher Quality ~520MB, Faster Processing ~150MB)
  - Complete privacy - audio never leaves device
  - Works offline after model download

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
- **iPhone Action Button Support**: Quick-start recording from the Action Button on iPhone 15 Pro/Pro Max, iPhone 16 Pro/Pro Max, and future Pro models. Press the Action Button to launch the app and start recording instantly, even when your phone is locked.
- **Watch App**: Full recording control from Apple Watch with automatic sync via WatchConnectivity
- **Multiple AI Engines**: Support for OpenAI, AWS Bedrock, Google AI Studio, Mistral AI, Ollama, and On-Device AI
- **Mistral AI Transcription**: Cloud transcription via Voxtral Mini with speaker diarization support ($0.003/min)
- **On-Device Processing**: Complete privacy with WhisperKit transcription and On-Device AI summarization (default for new installs)
- **Share Extension**: Import audio files directly from Voice Memos, Files, and other apps via the iOS share sheet
- **Combine Recordings**: Merge two separate recordings into a single continuous audio file
- **PDF Export**: Professional PDF reports with three-pane header (metadata, local map, regional map), pagination, and dedicated tasks/reminders sections
- **Background Processing**: Long recordings and complex processing handled automatically in the background
- **Search Functionality**: Powerful search across recordings, transcripts, and summaries. Search by recording name, transcript text, summary content, tasks, reminders, and titles.
- **Date Filters**: Filter recordings, transcripts, and summaries by date range. Select start and end dates to quickly find content from specific time periods.

## Key Modules
- Recording: `EnhancedAudioSessionManager`, `AudioFileChunkingService`, `AudioRecorderViewModel`, `RecordingCombiner`
- Transcription: `WhisperKitManager` (On Device), `OpenAITranscribeService`, `MistralTranscribeService`, `WhisperService`, `WyomingWhisperClient`, `AWSTranscribeService`
- Summarization: `OpenAISummarizationService`, `MistralAISummarizationService`, `GoogleAIStudioService`, `AWSBedrockService`, `OnDeviceLLMService`
- Export: `PDFExportService`, `SummaryExportFormatter`
- UI: `SummariesView`, `SummaryDetailView`, `TranscriptionProgressView`, `AITextView` (with MarkdownUI), `CombineRecordingsView`
- Persistence: `Persistence`, `CoreDataManager`, models under `Models/`
- Background: `BackgroundProcessingManager`
- Watch: `WatchConnectivityManager` (both targets)
- Share Extension: `ShareViewController` (imports audio from other apps via share sheet)
- Action Button: `StartRecordingIntent`, `ActionButtonLaunchManager`, `AppShortcuts`

## Transcription Engines

The app supports multiple transcription engines for converting audio to text:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **On Device** | High-quality on-device transcription. Your audio never leaves your device, ensuring complete privacy. | iOS 17.0+, 4GB+ RAM, model download (150-520MB) |
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

On Device transcription provides completely private, offline transcription:

- **Models**:
  - **Higher Quality** (~520MB): Best accuracy and quality. Takes longer to process but produces more accurate transcriptions.
  - **Faster Processing** (~150MB): Faster transcription with good quality. Ideal for quick transcriptions with slightly lower accuracy.
- **Storage**: Models stored in Documents directory (150-520MB depending on model)
- **Requirements**:
  - iOS 17.0 or later
  - 4GB+ RAM (most modern iPhones and iPads)
  - 150-520MB free storage space
- **Privacy**: 100% local processing - audio never leaves your device
- **Offline**: Works completely offline after initial model download

**Model Selection Guide**:
- **Voice Notes / Journaling** → Use "Faster Processing" (you're close to mic; speed is better)
- **Meeting / Interview** → Use "Higher Quality" (handling multiple voices requires extra accuracy)
- **Noisy Environment** → Use "Higher Quality" (Faster Processing will fail to separate voice from noise)
- **Long Battery Life Needed** → Use "Faster Processing" (Higher Quality uses significantly more power)

### Mistral AI Transcription

Mistral AI transcription uses the Voxtral Mini model for cloud-based speech-to-text:

- **Model**: Voxtral Mini Transcribe (`voxtral-mini-latest`)
- **Cost**: $0.003 per minute of audio
- **Speaker Diarization**: Optional — identifies and labels different speakers in the audio
- **Language**: Automatic detection or explicit language code (e.g., `en`, `fr`, `es`)
- **Supported Formats**: MP3, MP4, M4A, WAV, FLAC, OGG, WebM
- **Chunking**: Automatic chunking for files over 24MB or ~22 minutes (combined size/duration strategy)
- **Setup**: Uses the same API key as Mistral AI summarization. Configure in Settings → AI Settings → Mistral AI, then select Mistral AI as your transcription engine in Transcription Settings.

## AI Engines

The app supports multiple AI engines for summarization and content analysis:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **OpenAI** | GPT-4.1 models (GPT-4.1, GPT-4.1 Mini, GPT-4.1 Nano) and GPT-5 Mini | API key, internet |
| **OpenAI Compatible** | Any OpenAI-compatible API (Nebius, Groq, LiteLLM, llama.cpp, etc.) | API key, internet |
| **Mistral AI** | Mistral Large (25.12), Medium (25.08), Magistral Medium (25.09) | API key, internet |
| **Google AI Studio** | Gemini 2.5 Flash, 2.5 Flash Lite, 3 Pro Preview, 3 Flash Preview | API key, internet |
| **AWS Bedrock** | Claude 4.5 Haiku, Claude Sonnet 4.5, Llama 4 Maverick 17B Instruct | AWS credentials |
| **Ollama** | Local LLM server (recommended: qwen3:30b, gpt-oss:20b, mistral-small3.2) | Ollama server running |
| **On-Device AI** | Fully offline, privacy-focused | iPhone 15 Pro+, model (2-4.5 GB) |

### OpenAI Models

OpenAI summarization supports multiple models:

- **GPT-4.1**: Most robust and comprehensive analysis with advanced reasoning capabilities (Premium tier)
- **GPT-4.1 Mini**: Balanced performance and cost, suitable for most summarization tasks (Standard tier) - Default
- **GPT-4.1 Nano**: Fastest and most economical for basic summarization needs (Economy tier)
- **GPT-5 Mini**: Next-generation model with enhanced reasoning and efficiency (Premium tier)

### AWS Bedrock Models

AWS Bedrock provides access to multiple foundation models:

- **Claude 4.5 Haiku**: Fast and efficient model optimized for quick responses (Standard tier) - Default
- **Claude Sonnet 4.5**: Latest Claude Sonnet with advanced reasoning, coding, and analysis capabilities (Premium tier)
- **Llama 4 Maverick 17B Instruct**: Meta's latest Llama 4 model with enhanced reasoning and performance (Economy tier)

### Mistral AI Models

Mistral AI summarization supports multiple models:

- **Mistral Large (25.12)**: Most capable Mistral model with 128K context window (Premium tier)
- **Mistral Medium (25.08)**: Balanced performance and cost with 128K context (Standard tier)
- **Magistral Medium (25.09)**: Economy option with 40K context window (Economy tier)

### Google AI Studio Models

Google AI Studio provides access to Gemini models:

- **Gemini 2.5 Flash**: Fast and efficient, good for most summarization tasks - Default
- **Gemini 2.5 Flash Lite**: Lightweight variant for quick processing
- **Gemini 3 Pro Preview**: Advanced reasoning and analysis capabilities (Preview)
- **Gemini 3 Flash Preview**: Fast next-generation model (Preview)

### On-Device AI

The on-device AI feature enables completely private, offline AI processing:

- **Recommended Models** (by device RAM):
  - **8GB+ RAM**: Granite 4.0 H Tiny (4.3 GB) - Recommended for best quality
  - **6GB+ RAM**: Granite 4.0 Micro (2.1 GB) - Recommended for fast processing
  - **6GB+ RAM**: Gemma 3n E2B (3.0 GB) - Good quality, smaller size
  - **8GB+ RAM**: Gemma 3n E4B (4.5 GB) - Best overall quality
  - **6GB+ RAM**: Ministral 3B (2.1 GB) - Best for tasks and reminders

- **Experimental Models** (enable in settings):
  - **4GB+ RAM**: LFM 2.5 1.2B (731 MB) - Fast, minimal summaries (summary only)
  - **4GB+ RAM**: Qwen3 1.7B (1.1 GB) - Latest Qwen3 model (summary only)
  - **8GB+ RAM**: Qwen3 4B (2.7 GB) - Excellent detail extraction

- **Quantization**: Q4_K_M only (optimal balance of quality and memory usage)
- **Storage**: Models stored in Application Support (731 MB - 4.5 GB each)
- **Context Window**: 16K tokens (automatically adjusted based on device RAM)
- **Requirements**:
  - **Transcription**: iOS 17.0+, 4GB+ RAM (most modern iPhones and iPads). Uses On Device transcription (requires model download: 150-520MB)
  - **AI Summary**: iPhone 15 Pro, iPhone 16 or newer, iOS 18.1+ (requires more processing power)
  - Device capability check prevents downloads on unsupported devices
  - Models are filtered based on available RAM (6GB+ for most models, 8GB+ for larger models)
- **Downloads**: WiFi by default with optional cellular download support

## Configuration
- Secrets are entered in‑app via settings views (OpenAI, Mistral AI, Google, AWS, Ollama, Whisper). Do not commit API keys.
- Enable required capabilities in Xcode (Microphone, Background Modes, iCloud if used). Keep `Info.plist` and `.entitlements` aligned with features.
- For On Device transcription, download a model (Higher Quality or Faster Processing) in Settings → Transcription Settings → On Device.
- For on-device AI, device capability checks ensure your device meets requirements (iPhone 15 Pro+ for AI summaries) before allowing downloads.

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

Import audio files from other apps directly into BisonNotes AI using the iOS share sheet:

- **Supported audio formats**: M4A, MP3, WAV, CAF, AIFF, AIF
- **Supported document formats**: TXT, MD, PDF, DOC, DOCX
- **How it works**:
  1. Open Voice Memos, Files, or any app with audio files
  2. Tap the share button and select "BisonNotes AI"
  3. The file is saved to the shared container
  4. BisonNotes AI opens automatically and imports the file
- **Background import**: If the main app is already running, a Darwin notification wakes it to scan for new files immediately
- **File naming**: Imported files are prefixed with a UUID to prevent name collisions

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
| **WhisperKit** | On-device speech recognition using OpenAI Whisper models. We maintain a fork for iOS-specific fixes and optimizations. | MIT | [argmaxinc/WhisperKit](https://github.com/argmaxinc/whisperkit) |
| **Textual** (swift-markdown-ui) | Markdown rendering library used to display AI-generated summaries, transcripts, and formatted content. We maintain a fork with custom styling adjustments. | MIT | [gonzalezreal/swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui) |
| **llama.cpp** | C/C++ inference engine for on-device LLM processing. Embedded as a pre-compiled xcframework for Metal-accelerated local AI summarization. | MIT | [ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp) |
| **AWS SDK for Swift** | Cloud services SDK powering AWS Bedrock (Claude, Llama), Transcribe, and S3 integrations. | Apache 2.0 | [awslabs/aws-sdk-swift](https://github.com/awslabs/aws-sdk-swift) |
| **Swift Transformers** | Hugging Face tokenizers and transformer utilities for local ML model pipelines. | Apache 2.0 | [huggingface/swift-transformers](https://github.com/huggingface/swift-transformers) |

### Forked Repositories

We maintain forks of the following projects at [github.com/bisonbet](https://github.com/bisonbet):

- **[bisonbet/WhisperKit](https://github.com/bisonbet/WhisperKit)** — Fork of argmaxinc/WhisperKit
- **[bisonbet/textual](https://github.com/bisonbet/textual)** — Fork of gonzalezreal/swift-markdown-ui

### Transitive Dependencies

The AWS SDK and other direct dependencies bring in a number of excellent open-source libraries from the Apple Swift ecosystem and broader community:

- **Apple Swift Server libraries**: [Swift NIO](https://github.com/apple/swift-nio), [Swift Crypto](https://github.com/apple/swift-crypto), [Swift Protobuf](https://github.com/apple/swift-protobuf), [Swift Collections](https://github.com/apple/swift-collections), [Swift Algorithms](https://github.com/apple/swift-algorithms), [Swift Log](https://github.com/apple/swift-log), [Swift Metrics](https://github.com/apple/swift-metrics), [Swift Atomics](https://github.com/apple/swift-atomics), [Swift System](https://github.com/apple/swift-system), [Swift Async Algorithms](https://github.com/apple/swift-async-algorithms), [Swift Argument Parser](https://github.com/apple/swift-argument-parser), [Swift Numerics](https://github.com/apple/swift-numerics), [Swift Certificates](https://github.com/apple/swift-certificates), [Swift ASN1](https://github.com/apple/swift-asn1), [Swift HTTP Types](https://github.com/apple/swift-http-types), [Swift Distributed Tracing](https://github.com/apple/swift-distributed-tracing), [Swift Service Context](https://github.com/apple/swift-service-context), and related networking/TLS packages
- **Swift Server community**: [Async HTTP Client](https://github.com/swift-server/async-http-client), [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle)
- **gRPC**: [gRPC Swift](https://github.com/grpc/grpc-swift)
- **Observability**: [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift)
- **AWS infrastructure**: [AWS CRT Swift](https://github.com/awslabs/aws-crt-swift), [Smithy Swift](https://github.com/smithy-lang/smithy-swift)
- **Hugging Face**: [Swift Jinja](https://github.com/huggingface/swift-jinja)
- **Point-Free**: [Swift Concurrency Extras](https://github.com/pointfreeco/swift-concurrency-extras)

All dependencies are MIT or Apache 2.0 licensed. See each project's repository for full license terms.

## Contributing
See AGENTS.md for repository guidelines (style, structure, commands, testing, PRs). Follow the Local Dev Setup above to run and validate changes before opening a PR.

## License
See LICENSE.
