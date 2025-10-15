# Audio Journal

SwiftUI iOS + watchOS app for recording audio, transcribing it with local or cloud engines, and generating summaries, tasks, and reminders. Core Data powers persistence; background jobs handle long/complex processing; WatchConnectivity syncs state between watch and phone.

AVAILABLE ON THE APP STORE: https://apps.apple.com/us/app/bisonnotes-ai-voice-notes/id6749189425

Quick links: [Usage Quick Start](USAGE.md) • [Full User Guide](HOW_TO_USE.md) • [Build & Test](#build-and-test) • [Architecture](#architecture)

## Architecture
- Data: Core Data model at `BisonNotes AI/BisonNotes_AI.xcdatamodeld` stores recordings, transcripts, summaries, and jobs.
- Engines: Pluggable services for Apple on‑device NLP, OpenAI, Google AI Studio, AWS Bedrock/Transcribe, Whisper (REST), Wyoming streaming, and Ollama. Each engine pairs a service with a settings view.
- Background: `BackgroundProcessingManager` coordinates queued work with retries, timeouts, and recovery. Large files are chunked and processed streaming‑first.
- Watch Sync: `WatchConnectivityManager` (on iOS and watch targets) manages reachability, queued transfers, and state recovery.
- UI: SwiftUI views under `Views/` implement recording, summaries, transcripts, and settings. AI-generated content uses MarkdownUI for professional formatting. View models isolate state and side effects.

## Project Structure
- `BisonNotes AI/`: iOS app source
  - Notable folders: `Models/`, `Views/`, `ViewModels/`, `OpenAI/`, `AWS/`, `Wyoming/`, `WatchConnectivity/`
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
  - `AWSBedrock` & `AWSBedrockRuntime`: Claude AI models
  - `AWSTranscribe` & `AWSTranscribeStreaming`: Speech-to-text
  - `AWSS3`: File storage and retrieval
  - `AWSClientRuntime`: Core AWS functionality

### **UI & Formatting**
- **MarkdownUI**: Professional markdown rendering for AI-generated summaries, headers, lists, and formatted text

### **Apple Frameworks**
- **WatchConnectivity**: Syncing between iPhone and Apple Watch
- **Core Data**: Local data persistence
- **AVFoundation**: Audio recording and playback
- **Speech**: On-device speech recognition

All external dependencies are resolved automatically via Swift Package Manager when building in Xcode.

## Local Dev Setup
- Requirements: macOS with Xcode (15+ recommended) and Command Line Tools (`xcode-select --install`).
- Clone/fork the repo, then open: `open "BisonNotes AI/BisonNotes AI.xcodeproj"`.
- Select the "BisonNotes AI" scheme (iOS) or the watch scheme, choose a Simulator/device, and Run/ Test.
- Branch/PR: create a feature branch in your fork, push changes, and open a PR. Include build/test results and screenshots for UI changes.

## Key Modules
- Recording: `EnhancedAudioSessionManager`, `AudioFileChunkingService`, `AudioRecorderViewModel`
- Transcription: `OpenAITranscribeService`, `WhisperService`, `WyomingWhisperClient`, `AWSTranscribeService`
- Summarization: `OpenAISummarizationService`, `GoogleAIStudioService`, `AWSBedrockService`, `EnhancedAppleIntelligenceEngine`
- UI: `SummariesView`, `SummaryDetailView`, `TranscriptionProgressView`, `AITextView` (with MarkdownUI)
- Persistence: `Persistence`, `CoreDataManager`, models under `Models/`
- Background: `BackgroundProcessingManager`
- Watch: `WatchConnectivityManager` (both targets)

## Configuration
- Secrets are entered in‑app via settings views (OpenAI, Google, AWS, Ollama, Whisper). Do not commit API keys.
- Enable required capabilities in Xcode (Microphone, Background Modes, iCloud if used). Keep `Info.plist` and `.entitlements` aligned with features.

## Contributing
See AGENTS.md for repository guidelines (style, structure, commands, testing, PRs). Follow the Local Dev Setup above to run and validate changes before opening a PR.

## License
See LICENSE.
