# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current Environment Context
- **Year**: 2026
- **Current iOS**: iOS 26 / iPadOS 26
- **Latest Devices**: iPhone models through iPhone 17 series, iPad models with M4 chips and A17 Pro

## Build and Development Commands

**CRITICAL: DO NOT BUILD OR RUN WITHOUT EXPLICIT USER REQUEST**

Never run `xcodebuild`, build commands, or any compilation/execution commands unless the user explicitly asks you to do so. This includes:
- Do NOT run `xcodebuild` to verify fixes
- Do NOT compile to check for errors
- Do NOT run tests automatically
- Do NOT execute the app to verify functionality

If you make code changes, explain what you fixed and let the user verify by building themselves.

This is an iOS application built with Xcode. When explicitly requested by the user, use standard Xcode commands:

- **Build**: Open `BisonNotes AI.xcodeproj` in Xcode and build (⌘+B)
- **Run**: Build and run on simulator or device (⌘+R)
- **Test**: Run unit tests with ⌘+U
- **Clean**: Clean build folder (⌘+Shift+K)

The project uses Swift Package Manager for dependencies, primarily AWS SDK for iOS and MarkdownUI for content formatting.

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

#### AI Integration
The app supports multiple AI engines:
- **Apple Intelligence**: Local processing using Apple frameworks
- **OpenAI**: GPT-4o models for transcription and summarization
- **Google AI Studio**: Gemini 2.5 models for AI processing
- **AWS Bedrock**: Claude models (Sonnet 4, Sonnet 4.5, Haiku 4.5) and Llama 4 Maverick
- **Whisper**: Local Whisper server for transcription
- **Ollama**: Local AI models for privacy-focused processing
- **AWS Transcribe**: Cloud-based transcription service

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
├── OpenAI/             # OpenAI integration
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

### AI Engine Integration
New AI engines should follow the existing pattern:
1. Create service class (e.g., `NewAIService.swift`)
2. Add settings view (e.g., `NewAISettingsView.swift`)
3. Integrate with `EnhancedTranscriptionManager` or appropriate manager
4. Add engine monitoring and error handling

#### AWS Bedrock Models
The app includes comprehensive AWS Bedrock integration (`AWS/AWSBedrockModels.swift`):
- **Claude 4.5 Haiku**: Default model for fast, efficient processing (Standard tier)
  - Model ID: `global.anthropic.claude-haiku-4-5-20251001-v1:0` (global cross-region inference profile)
- **Claude Sonnet 4/4.5**: Premium models for advanced reasoning and analysis
  - Model IDs: `global.anthropic.claude-sonnet-4-20250514-v1:0`, `global.anthropic.claude-sonnet-4-5-20250929-v1:0`
- **Llama 4 Maverick**: Meta's economy-tier model with 128K context window
  - Model ID: `us.meta.llama4-maverick-17b-instruct-v1:0`

**Important**:
- Legacy model migration: `claude35Haiku` automatically migrates to `claude45Haiku`
- Security: Response validation includes 500KB max length and control character sanitization
- **Model ID Formats**:
  - **Cross-Region Inference Profiles**: Claude and Llama models use `us.*`, `global.*`, `eu.*` prefixes for cross-region routing
  - Cross-region profiles provide ~10% cost savings and higher throughput by routing requests to available regions

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
- Supports all AI engines: OpenAI, Claude (Bedrock), Gemini, Apple Intelligence, etc.

## Key Files to Understand

- `BisonNotesAIApp.swift`: App entry point with Core Data setup
- `ContentView.swift`: Main tab interface
- `Models/CoreDataManager.swift`: Core Data access layer
- `Models/AppDataCoordinator.swift`: Unified data coordination
- `Views/AITextView.swift`: MarkdownUI-powered content rendering
- `EnhancedTranscriptionManager.swift`: Transcription orchestration
- `BackgroundProcessingManager.swift`: Background job management
- `AWS/AWSBedrockModels.swift`: AWS Bedrock model definitions and API handling
- `FutureAIEngines.swift`: AI engine implementations including AWS Bedrock
- `AISettingsView.swift`: AI engine configuration UI
- `BisonNotes_AI.xcdatamodeld/`: Core Data model definitions