# BisonNotes AI - Feature Inventory for Android Port

## Executive Summary

BisonNotes AI is a comprehensive iOS audio recording and transcription application with AI-powered summarization capabilities. This document provides a complete feature inventory for the Android port.

**App Type**: Audio Recording, Transcription, and AI Analysis
**Current Platform**: iOS 26+ / iPadOS 26+ / watchOS
**Target Platform**: Android
**Primary Language**: Swift (iOS) → Kotlin (Android)
**Architecture**: Core Data + SwiftUI → Room DB + Jetpack Compose

---

## Core Features

### 1. Audio Recording
- **High-quality audio recording** with multiple format support
- **Real-time recording timer** with visual feedback
- **Background recording** continues when app is backgrounded
- **Multiple audio input sources** (built-in mic, Bluetooth, external)
- **Audio session management** with interruption handling
- **Failsafe recovery** for recording interruptions
- **Watch app companion** for standalone Apple Watch recording
- **Location tracking** during recording (optional)
- **Recording quality settings** (bitrate, sample rate, channels)
- **Control Center integration** (iOS 18+)
- **Action Button integration** for quick recording start

### 2. Transcription Engine Support

The app supports **multiple transcription engines** with automatic fallback:

#### Apple Speech Recognition
- Local on-device transcription
- Privacy-focused, no data leaves device
- Supports multiple languages
- Real-time transcription capability
- Chunked processing for large files (5-minute chunks with 2-second overlap)

#### OpenAI Whisper API
- Cloud-based transcription via OpenAI API
- High accuracy
- Multiple model support (Whisper-1, GPT-4o-mini-transcribe)
- Custom base URL support for self-hosted alternatives
- API key authentication

#### Local Whisper Server
- Self-hosted Whisper server support
- Two protocols: REST API and Wyoming protocol
- Configurable server URL and port
- Privacy-focused local processing

#### AWS Transcribe
- Cloud transcription via AWS
- S3 integration for audio upload
- Support for multiple AWS regions
- IAM credentials management
- Batch processing support

#### Google AI Studio (Future)
- Gemini model support
- Planned integration

#### Ollama (Local AI)
- Local AI model support
- Privacy-focused processing
- Custom model support

### 3. AI-Powered Summarization

#### Supported AI Engines for Summarization:

**OpenAI (GPT-4o, GPT-4o-mini)**
- Smart summarization with structured output
- Task extraction from conversations
- Reminder extraction with intelligent date parsing
- Title generation (3 suggested titles)
- Content type detection (meeting, lecture, conversation, etc.)
- Custom base URL support

**AWS Bedrock (Claude Models)**
- Claude 3.5 Sonnet, Claude 3 Haiku, Claude 3 Opus
- Advanced reasoning capabilities
- Structured output with JSON parsing
- IAM credential management
- Regional endpoint support

**Apple Intelligence**
- On-device summarization (iOS 18.1+)
- Privacy-focused processing
- Integration with Apple's Writing Tools API

**Google AI Studio (Gemini)**
- Gemini Pro model support
- API key authentication
- Multi-turn conversation analysis

**Ollama (Local Models)**
- Self-hosted AI models
- Custom model support (llama3, mistral, etc.)
- Privacy-focused processing

### 4. Data Management

#### Core Data Architecture
**4 Main Entities:**

1. **RecordingEntry**
   - Audio file metadata
   - Recording date and duration
   - Audio quality and file size
   - Location data (lat/long, address, accuracy)
   - Transcription and summary status tracking
   - Relationships to transcript and summary

2. **TranscriptEntry**
   - Full transcript text in segments
   - Speaker identification (diarization)
   - Transcription engine used
   - Processing time and confidence score
   - Created and modified timestamps
   - Relationship to recording and summaries

3. **SummaryEntry**
   - AI-generated summary text
   - Extracted tasks (JSON array)
   - Extracted reminders (JSON array)
   - Suggested titles (3 options)
   - Content type classification
   - AI method used and version
   - Word count, compression ratio
   - Processing metadata
   - Relationship to recording and transcript

4. **ProcessingJobEntry**
   - Background job tracking
   - Job type (transcription/summarization)
   - Engine used
   - Status (queued/processing/completed/failed)
   - Progress tracking
   - Error messages
   - Start and completion times

#### Data Migration
- Automatic migration from legacy file-based storage to Core Data
- Orphaned record cleanup
- URL path migration (absolute → relative)
- Data integrity validation

#### File Management
- Audio files stored in Documents directory
- Relative path storage for resilience
- Automatic file sync and recovery
- Location data stored as sidecar files (.location)
- Thumbnail generation for recordings

### 5. Background Processing

**BackgroundProcessingManager**:
- Job queue system for transcription and summarization
- Battery-aware processing optimization
- Progress tracking for long-running operations
- Error recovery and retry mechanisms
- Notification support for completion
- BGTaskScheduler integration (iOS)
- Background app refresh support

**Performance Optimization**:
- Battery level monitoring
- Memory-aware processing
- Chunking for large audio files (>5 minutes)
- Streaming processing for memory efficiency
- Concurrent processing with limits

### 6. User Interface Features

#### Main Views (SwiftUI → Jetpack Compose):

1. **RecordingsView**
   - List of all recordings
   - Recording controls (start/stop/pause)
   - Audio playback with scrubber
   - Delete with confirmation dialog
   - Location indicators
   - Status badges (transcribing, summarizing)

2. **SummariesView**
   - Grid/List view of summaries
   - MarkdownUI rendering for formatted content
   - Task and reminder extraction display
   - Export functionality (PDF, RTF, Markdown)
   - Share sheet integration
   - Regeneration support

3. **TranscriptsView**
   - Full transcript display
   - Speaker diarization
   - Time-stamped segments
   - Search/filter capability
   - Export support

4. **SettingsView**
   - AI engine configuration
   - Transcription settings
   - Recording quality settings
   - Location tracking toggle
   - Time format preferences (12h/24h)
   - Credentials management

#### Additional UI Components:
- **AudioPlayerView**: Playback controls with scrubber
- **AITextView**: Markdown-rendered AI content
- **DataMigrationView**: First-launch migration UI
- **BackgroundProcessingView**: Job queue monitoring
- **EnhancedDeleteDialog**: Confirmation with options
- **FileAvailabilityIndicator**: Visual file status

### 7. Export and Sharing

**Export Formats**:
- PDF (formatted with metadata)
- RTF (Rich Text Format)
- Plain text
- JSON (structured data)
- Markdown

**Export Services**:
- `PDFExportService`: Generates formatted PDFs
- `RTFExportService`: Creates RTF documents
- `SummaryExportFormatter`: Formats summary data

**Share Sheet**:
- Native iOS share functionality
- Export to Files app
- Share via Messages, Mail, etc.

### 8. Apple Watch Integration

**Watch App Features**:
- Standalone recording on Apple Watch
- Watch Connectivity framework for sync
- Reliable transfer protocol with confirmation
- Chunk-based audio transfer (16KB chunks)
- Background sync support
- Complication support
- Location tracking
- Haptic feedback

**WatchConnectivity**:
- Bidirectional communication
- Reliable message delivery
- File transfer with progress tracking
- Application context sync

### 9. Location Services

**LocationManager**:
- Real-time location tracking during recording
- Reverse geocoding for addresses
- Configurable accuracy levels
- Privacy-aware permission handling
- Map snapshot generation
- Location data persistence

### 10. Cloud and Sync

**iCloud Integration**:
- Core Data + CloudKit sync
- Cross-device data sync
- Conflict resolution

**AWS Integration**:
- S3 for audio file upload (transcription)
- Transcribe for cloud transcription
- Bedrock for Claude AI access
- IAM credential management
- Multi-region support

### 11. Import Features

**File Import**:
- Audio file import (.m4a, .wav, .mp3)
- Transcript import (.txt, .docx, .json)
- Document picker integration
- Automatic format detection

**TranscriptImportManager**:
- DOCX parsing with speaker detection
- Plain text import
- JSON structured import
- Smart speaker attribution

### 12. Advanced Features

**Content Analysis**:
- Task extraction with NLP
- Reminder extraction with date/time parsing
- Title generation (3 suggestions)
- Content type classification
- Sentiment analysis (future)

**Smart Naming**:
- Automatic recording name generation
- Location-based naming
- Timestamp-based naming
- Custom naming support

**Enhanced Logging**:
- Structured logging system
- Debug mode support
- Error tracking
- Performance monitoring

**Token Management**:
- API usage tracking
- Cost estimation
- Rate limiting awareness

---

## Technical Specifications

### Audio Specifications
- **Formats**: M4A (AAC), WAV, CAF
- **Sample Rates**: 8kHz - 48kHz
- **Bit Depth**: 16-bit, 24-bit
- **Channels**: Mono, Stereo
- **Bitrate**: 32kbps - 320kbps

### Transcription Specs
- **Max audio length**: Unlimited (chunked processing)
- **Chunk size**: 5 minutes (configurable)
- **Overlap**: 2 seconds (configurable)
- **Timeout**: 1 hour per transcription
- **Languages**: Depends on engine (Apple: 50+, Whisper: 99)

### Performance Targets
- **Recording startup**: <100ms
- **Transcription**: Real-time for on-device, varies for cloud
- **Summarization**: 2-10 seconds depending on engine
- **UI responsiveness**: 60fps target
- **Battery impact**: <5% per hour of recording

### Data Storage
- **Audio files**: Documents directory
- **Metadata**: Core Data SQLite
- **Location data**: Sidecar JSON files
- **Cache**: Thumbnails, snapshots

---

## Platform-Specific Features (iOS)

These features need Android alternatives:

1. **Control Center controls** → Android Quick Settings Tile
2. **Action Button integration** → Android hardware button mapping (limited)
3. **Apple Watch app** → Wear OS app (separate implementation)
4. **iCloud sync** → Google Drive or Firebase sync
5. **CloudKit** → Firebase Realtime Database or Firestore
6. **SFSpeechRecognizer** → Android SpeechRecognizer
7. **AVAudioSession** → Android AudioManager
8. **BGTaskScheduler** → WorkManager (Android)
9. **UserNotifications** → Android NotificationManager
10. **WidgetKit** → Android App Widgets

---

## Feature Priority for Android Port

### Phase 1 - MVP (Minimum Viable Product)
- ✅ Audio recording and playback
- ✅ Local transcription (Android SpeechRecognizer)
- ✅ Basic Room database
- ✅ Simple UI (recordings list, player)
- ✅ File management

### Phase 2 - Cloud Integrations
- ✅ OpenAI Whisper integration
- ✅ OpenAI GPT summarization
- ✅ AWS Transcribe integration
- ✅ Background processing with WorkManager

### Phase 3 - Advanced AI
- ✅ AWS Bedrock (Claude) integration
- ✅ Google AI Studio integration
- ✅ Local Ollama support
- ✅ Advanced summarization features

### Phase 4 - Enhanced Features
- ✅ Location tracking
- ✅ Export functionality
- ✅ Import support
- ✅ Markdown rendering

### Phase 5 - Ecosystem
- ⚠️ Wear OS app (optional)
- ⚠️ Cloud sync (Firebase/Drive)
- ⚠️ Widgets
- ⚠️ Quick settings tile

---

## Total Feature Count

- **Core Features**: 12 major feature areas
- **AI Engines**: 6 supported (4 production-ready)
- **Export Formats**: 5
- **Import Formats**: 3
- **Database Entities**: 4
- **Main Views**: 4 + 6 component views
- **Background Services**: 3 major managers
- **Platform Integrations**: 10 iOS-specific

**Estimated Complexity**: High - This is a feature-rich, production-grade application requiring significant engineering effort for a complete port.

---

## Notes for Android Implementation

1. **Architecture**: Use MVVM with Jetpack Compose + Room + WorkManager
2. **Audio**: MediaRecorder/MediaPlayer for basic, consider Oboe for low-latency
3. **AI Integration**: Same REST APIs will work (OpenAI, AWS, Google)
4. **Local AI**: Implement Whisper.cpp for Android or use ML Kit
5. **Background Processing**: WorkManager for jobs, Foreground Service for recording
6. **UI**: Jetpack Compose replaces SwiftUI (1:1 conceptual mapping)
7. **Database**: Room replaces Core Data (similar ORM patterns)
8. **Location**: FusedLocationProviderClient replaces CLLocationManager
9. **Permissions**: Runtime permission model (Android 6+)
10. **File Storage**: Use internal storage + scoped storage (Android 10+)

---

**Document Version**: 1.0
**Last Updated**: 2025-11-22
**Status**: Comprehensive Inventory Complete
