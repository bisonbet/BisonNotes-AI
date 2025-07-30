# Design Document

## Overview

This design enhances the Audio Journal app with advanced audio processing capabilities, background operation support, cloud storage integration, and improved file management. The solution focuses on providing seamless audio recording without interrupting system audio, intelligent file chunking for transcription services, background processing capabilities, iCloud integration, and flexible deletion options.

## Architecture

### Core Components

1. **Enhanced Audio Session Manager** - Manages audio session configuration for mixed audio recording
2. **Background Processing Manager** - Handles transcription and summarization in background
3. **Audio File Chunking Service** - Splits large audio files based on service-specific limits
4. **iCloud Storage Manager** - Manages cloud synchronization for summaries
5. **Enhanced File Management System** - Handles selective deletion and file relationships

### System Integration Points

- **AVAudioSession** - For mixed audio recording configuration
- **Background App Refresh** - For continued processing when backgrounded
- **CloudKit** - For iCloud storage synchronization
- **Core Data** - Enhanced to track file relationships and processing states
- **Existing Services** - Integration with current transcription and summarization engines

## Components and Interfaces

### 1. Enhanced Audio Session Manager

```swift
class EnhancedAudioSessionManager: ObservableObject {
    func configureMixedAudioSession() async throws
    func configureBackgroundRecording() async throws
    func restoreAudioSession() async throws
    func handleAudioInterruption(_ notification: Notification)
}
```

**Responsibilities:**
- Configure audio session for mixed audio (recording + playback)
- Handle audio interruptions gracefully
- Manage background recording permissions
- Restore audio session when returning to foreground

### 2. Background Processing Manager

```swift
class BackgroundProcessingManager: ObservableObject {
    @Published var activeJobs: [ProcessingJob] = []
    @Published var processingStatus: ProcessingStatus = .idle
    
    func startTranscription(_ job: TranscriptionJob) async throws
    func startSummarization(_ job: SummarizationJob) async throws
    func cancelActiveJob() async
    func getJobStatus(_ jobId: UUID) -> ProcessingStatus
}

struct ProcessingJob: Identifiable {
    let id: UUID
    let type: JobType
    let recordingURL: URL
    let status: ProcessingStatus
    let progress: Double
    let startTime: Date
}

enum JobType {
    case transcription(engine: TranscriptionEngine)
    case summarization(engine: String)
}

enum ProcessingStatus {
    case idle, queued, processing, completed, failed(Error)
}
```

**Responsibilities:**
- Queue and manage background processing jobs
- Ensure only one job runs at a time
- Handle job persistence across app backgrounding
- Update UI with processing status
- Complete post-processing tasks (title generation, etc.)

### 3. Audio File Chunking Service

```swift
class AudioFileChunkingService {
    func shouldChunkFile(_ url: URL, for service: TranscriptionService) async -> Bool
    func chunkAudioFile(_ url: URL, for service: TranscriptionService) async throws -> [AudioChunk]
    func reassembleTranscript(from chunks: [TranscriptChunk]) -> TranscriptData
    func cleanupChunks(_ chunks: [AudioChunk]) async
}

struct AudioChunk: Identifiable {
    let id: UUID
    let originalURL: URL
    let chunkURL: URL
    let sequenceNumber: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let fileSize: Int64
}

struct TranscriptChunk {
    let chunkId: UUID
    let sequenceNumber: Int
    let transcript: String
    let segments: [TranscriptSegment]
}

enum ChunkingStrategy {
    case fileSize(maxBytes: Int64)  // For OpenAI (24MB)
    case duration(maxSeconds: TimeInterval)  // For Whisper/AWS (2 hours), Apple Intelligence (15 minutes)
}
```

**Responsibilities:**
- Determine if files need chunking based on service limits
- Split audio files using appropriate strategy
- Track chunk sequence for proper reassembly
- Reassemble transcripts in correct order
- Clean up temporary chunk files after processing

### 4. iCloud Storage Manager

```swift
class iCloudStorageManager: ObservableObject {
    @Published var isEnabled: Bool = false
    @Published var syncStatus: SyncStatus = .idle
    
    func enableiCloudSync() async throws
    func disableiCloudSync() async throws
    func syncSummary(_ summary: EnhancedSummaryData) async throws
    func syncAllSummaries() async throws
    func getSyncStatus() -> SyncStatus
}

enum SyncStatus {
    case idle, syncing, completed, failed(Error)
}
```

**Responsibilities:**
- Manage iCloud sync settings
- Sync summaries to CloudKit
- Handle sync conflicts and errors
- Provide sync status to UI

### 5. Enhanced File Management System

```swift
class EnhancedFileManager: ObservableObject {
    func deleteRecording(_ url: URL, preserveSummary: Bool) async throws
    func getFileRelationships(_ url: URL) -> FileRelationships
    func updateFileRelationships(for url: URL, relationships: FileRelationships) async
}

struct FileRelationships {
    let recordingURL: URL?
    let transcriptExists: Bool
    let summaryExists: Bool
    let iCloudSynced: Bool
}
```

**Responsibilities:**
- Track relationships between recordings, transcripts, and summaries
- Handle selective deletion logic
- Update UI to reflect file availability
- Manage cleanup of orphaned files

## Data Models

### Enhanced Processing Job Model

```swift
struct ProcessingJobData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let jobType: JobType
    let status: ProcessingStatus
    let progress: Double
    let startTime: Date
    let completionTime: Date?
    let chunks: [AudioChunk]?
    let error: String?
}
```

### Audio Session Configuration

```swift
struct AudioSessionConfig {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let allowMixedAudio: Bool
    let backgroundRecording: Bool
}
```

### Chunking Configuration

```swift
struct ChunkingConfig {
    let openAIMaxSize: Int64 = 24 * 1024 * 1024  // 24MB
    let whisperMaxDuration: TimeInterval = 2 * 60 * 60  // 2 hours
    let awsMaxDuration: TimeInterval = 2 * 60 * 60  // 2 hours
    let appleIntelligenceMaxDuration: TimeInterval = 15 * 60  // 15 minutes
    let chunkOverlap: TimeInterval = 5.0  // 5 seconds overlap for continuity
}
```

## Error Handling

### Enhanced Error Types

```swift
enum AudioProcessingError: Error, LocalizedError {
    case audioSessionConfigurationFailed(String)
    case backgroundRecordingNotPermitted
    case chunkingFailed(String)
    case iCloudSyncFailed(String)
    case backgroundProcessingFailed(String)
    case fileRelationshipError(String)
    
    var errorDescription: String? {
        switch self {
        case .audioSessionConfigurationFailed(let message):
            return "Audio session configuration failed: \(message)"
        case .backgroundRecordingNotPermitted:
            return "Background recording permission not granted"
        case .chunkingFailed(let message):
            return "Audio file chunking failed: \(message)"
        case .iCloudSyncFailed(let message):
            return "iCloud synchronization failed: \(message)"
        case .backgroundProcessingFailed(let message):
            return "Background processing failed: \(message)"
        case .fileRelationshipError(let message):
            return "File relationship error: \(message)"
        }
    }
}
```

### Error Recovery Strategies

1. **Audio Session Failures** - Fallback to standard recording mode
2. **Chunking Failures** - Attempt processing with original file
3. **Background Processing Failures** - Queue for retry when app returns to foreground
4. **iCloud Sync Failures** - Store locally and retry on next sync cycle
5. **File Relationship Errors** - Rebuild relationships from available data

## Testing Strategy

### Unit Tests

1. **Audio Session Manager Tests**
   - Test mixed audio configuration
   - Test background recording setup
   - Test interruption handling

2. **Chunking Service Tests**
   - Test file size-based chunking (OpenAI)
   - Test duration-based chunking (Whisper, AWS, Apple Intelligence)
   - Test transcript reassembly
   - Test chunk cleanup

3. **Background Processing Tests**
   - Test job queuing and execution
   - Test single job constraint
   - Test job persistence across app lifecycle
   - Test status updates

4. **iCloud Storage Tests**
   - Test sync enable/disable
   - Test summary synchronization
   - Test conflict resolution
   - Test offline handling

5. **File Management Tests**
   - Test selective deletion
   - Test relationship tracking
   - Test orphaned file cleanup

### Integration Tests

1. **End-to-End Recording Tests**
   - Record with music playing
   - Record in background
   - Process large files with chunking

2. **Background Processing Integration**
   - Start processing and background app
   - Verify processing continues
   - Verify completion handling

3. **iCloud Sync Integration**
   - Sync across multiple devices
   - Handle network interruptions
   - Verify data consistency

### Performance Tests

1. **Audio Session Performance**
   - Measure session configuration time
   - Test audio quality with mixed recording

2. **Chunking Performance**
   - Measure chunking time for various file sizes
   - Test memory usage during chunking

3. **Background Processing Performance**
   - Measure processing time in background
   - Test battery usage impact

4. **iCloud Sync Performance**
   - Measure sync time for various data sizes
   - Test sync efficiency

## Implementation Considerations

### Audio Session Management

- Use `.playAndRecord` category with `.allowBluetooth` and `.mixWithOthers` options
- Handle audio interruptions from phone calls, other apps
- Request background audio permission in Info.plist
- Monitor audio route changes for device switching

### Background Processing

- Use Background App Refresh capability
- Implement proper task management with `beginBackgroundTask`
- Store processing state in UserDefaults for persistence
- Use local notifications for completion alerts

### File Chunking

- Use AVAsset for accurate duration-based splitting
- Implement overlap between chunks for transcript continuity
- Use temporary directory for chunk storage
- Implement robust cleanup to prevent storage bloat

### iCloud Integration

- Use CloudKit for summary storage
- Implement conflict resolution for concurrent edits
- Handle network availability changes
- Provide clear sync status to users

### Memory Management

- Stream large files during chunking to minimize memory usage
- Implement proper cleanup of temporary resources
- Use weak references in delegate patterns
- Monitor memory usage during background processing

### Security Considerations

- Ensure iCloud data is properly encrypted
- Validate file integrity after chunking
- Implement secure cleanup of temporary files
- Handle sensitive data appropriately in background