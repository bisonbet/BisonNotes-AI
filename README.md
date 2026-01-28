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
  - `AWSBedrock` & `AWSBedrockRuntime`: Claude AI models (Claude 4.5 Haiku, Sonnet 4/4.5, Llama 4 Maverick)
  - `AWSTranscribe` & `AWSTranscribeStreaming`: Speech-to-text
  - `AWSS3`: File storage and retrieval
  - `AWSClientRuntime`: Core AWS functionality

### **On-Device AI**
- **LocalLLMClient**: Swift wrapper for llama.cpp enabling on-device LLM inference
  - GitHub: https://github.com/bisonbet/LocalLLMClient-iOS
  - Supports GGUF model format with Q4_K_M quantization (optimal for mobile)
  - Built-in download management for Hugging Face models
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
- **On-Device Processing**: Complete privacy with WhisperKit transcription and On-Device AI summarization
- **Background Processing**: Long recordings and complex processing handled automatically in the background
- **Search Functionality**: Powerful search across recordings, transcripts, and summaries. Search by recording name, transcript text, summary content, tasks, reminders, and titles.
- **Date Filters**: Filter recordings, transcripts, and summaries by date range. Select start and end dates to quickly find content from specific time periods.

## Key Modules
- Recording: `EnhancedAudioSessionManager`, `AudioFileChunkingService`, `AudioRecorderViewModel`
- Transcription: `WhisperKitManager` (On Device), `OpenAITranscribeService`, `WhisperService`, `WyomingWhisperClient`, `AWSTranscribeService`
- Summarization: `OpenAISummarizationService`, `MistralAISummarizationService`, `GoogleAIStudioService`, `AWSBedrockService`, `OnDeviceLLMService`
- UI: `SummariesView`, `SummaryDetailView`, `TranscriptionProgressView`, `AITextView` (with MarkdownUI)
- Persistence: `Persistence`, `CoreDataManager`, models under `Models/`
- Background: `BackgroundProcessingManager`
- Watch: `WatchConnectivityManager` (both targets)
- Action Button: `StartRecordingIntent`, `ActionButtonLaunchManager`, `AppShortcuts`

## Transcription Engines

The app supports multiple transcription engines for converting audio to text:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **On Device** | High-quality on-device transcription. Your audio never leaves your device, ensuring complete privacy. | iOS 17.0+, 4GB+ RAM, model download (150-520MB) |
| **OpenAI** | Cloud-based transcription using OpenAI's GPT-4o models and Whisper API | API key, internet |
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

## AI Engines

The app supports multiple AI engines for summarization and content analysis:

| Engine | Description | Requirements |
|--------|-------------|--------------|
| **OpenAI** | GPT-4.1 models (GPT-4.1, GPT-4.1 Mini, GPT-4.1 Nano) and GPT-5 Mini | API key, internet |
| **OpenAI Compatible** | Any OpenAI-compatible API (Nebius, Groq, LiteLLM, llama.cpp, etc.) | API key, internet |
| **Mistral AI** | Mistral Large/Medium, Magistral (25.08-25.12) | API key, internet |
| **Google AI Studio** | Gemini models | API key, internet |
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

**Adding LocalLLMClient to the project:**
1. In Xcode, go to File → Add Package Dependencies
2. Enter: `https://github.com/bisonbet/LocalLLMClient-iOS`
3. Set version rule to "Branch" → `main`
4. Add `LocalLLMClient` to your target

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

## Contributing
See AGENTS.md for repository guidelines (style, structure, commands, testing, PRs). Follow the Local Dev Setup above to run and validate changes before opening a PR.

## License
See LICENSE.
