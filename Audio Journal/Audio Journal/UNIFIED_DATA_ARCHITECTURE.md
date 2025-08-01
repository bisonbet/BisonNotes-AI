# Unified Data Architecture

## Overview

This architecture provides a centralized registry system with proper unique identifiers and relationships for managing recordings, transcripts, and summaries.

## Key Components

### 1. RecordingRegistry.swift
- **RecordingEntry**: Central record for each audio recording with unique UUID
- **ProcessingStatus**: Tracks transcription and summary processing states
- **RecordingRegistryManager**: Manages all recordings, transcripts, and summaries
- **Updated TranscriptData & EnhancedSummaryData**: Now link via recordingId

### 2. UnifiediCloudSyncManager.swift
- Handles CloudKit sync for the new unified structure
- Uses proper Core Data entity names (CD_RecordingEntry, CD_TranscriptEntry, CD_SummaryEntry)
- Maintains relationships between records in the cloud

### 3. AppDataCoordinator.swift
- Main coordinator that manages the unified system
- Provides clean API for the rest of the app
- Handles iCloud sync and data management

## Data Flow

```
Recording Created → RecordingEntry (UUID: A)
     ↓
Transcription → TranscriptData (recordingId: A, UUID: B)
     ↓
Summary → EnhancedSummaryData (recordingId: A, transcriptId: B, UUID: C)
```

## Benefits

1. **No More Linking Issues**: Each piece of data has a unique ID and proper relationships
2. **Reliable iCloud Sync**: CloudKit records maintain proper relationships
3. **Better Data Integrity**: Central registry prevents orphaned data
4. **Easier Debugging**: Clear data lineage and status tracking
5. **Future-Proof**: Easy to add new data types with proper relationships

## Core Data Schema

The new Core Data model includes:

- **RecordingEntry**: Main recording entity with metadata and status
- **TranscriptEntry**: Transcript data linked to recording
- **SummaryEntry**: Summary data linked to recording and optionally transcript
- **Proper relationships**: Cascade deletes and inverse relationships

## Usage in Views

Instead of managing separate SummaryManager and TranscriptManager instances:

```swift
// Old way
@StateObject private var summaryManager = SummaryManager()
@StateObject private var transcriptManager = TranscriptManager()

// New way
@EnvironmentObject var appCoordinator: AppDataCoordinator

// Access data
let recordings = appCoordinator.getAllRecordingsWithData()
let recording = appCoordinator.getRecording(id: recordingId)
```

## Files Modified/Created

### New Files:
- `Models/RecordingRegistry.swift` - Core registry system
- `Models/UnifiediCloudSyncManager.swift` - New iCloud sync
- `Models/AppDataCoordinator.swift` - Main coordinator

### Modified Files:
- `Audio_JournalApp.swift` - Uses new coordinator
- `Audio_Journal.xcdatamodeld` - Updated Core Data schema

This architecture provides a solid foundation for reliable data management and sync across all your audio journal features.