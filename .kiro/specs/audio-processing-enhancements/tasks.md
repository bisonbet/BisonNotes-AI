# Implementation Plan

- [x] 1. Set up enhanced audio session management
  - Create EnhancedAudioSessionManager class with mixed audio recording capabilities
  - Implement audio session configuration methods for non-interrupting recording
  - Add background recording permission handling and Info.plist updates
  - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3_

- [x] 2. Implement audio file chunking service
  - [x] 2.1 Create AudioFileChunkingService with service-specific chunking strategies
    - Implement file size-based chunking for OpenAI (24MB limit)
    - Implement duration-based chunking for Whisper/AWS (2 hours) and Apple Intelligence (15 minutes)
    - Create AudioChunk and TranscriptChunk data models
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

  - [x] 2.2 Implement audio file splitting and reassembly logic
    - Write file splitting methods using AVAsset for accurate duration handling
    - Implement transcript reassembly with proper sequence ordering
    - Add chunk cleanup functionality to remove temporary files
    - _Requirements: 3.4, 3.5, 3.6_

- [x] 3. Create background processing management system
  - [x] 3.1 Implement BackgroundProcessingManager with job queuing
    - Create ProcessingJob data model and job queue management
    - Implement single job constraint to prevent concurrent processing
    - Add job persistence across app lifecycle using UserDefaults
    - _Requirements: 4.1, 4.2_

  - [x] 3.2 Integrate background processing with existing transcription services
    - Modify existing transcription services to work with chunked files
    - Update OpenAI, Whisper, AWS, and Apple Intelligence services for chunk processing
    - Implement progress tracking and status updates for background jobs
    - _Requirements: 4.1, 4.3, 4.4_

  - [x] 3.3 Add background task management and completion handling
    - Implement proper background task lifecycle with beginBackgroundTask
    - Add automatic title generation and post-processing completion
    - Create local notifications for processing completion alerts
    - _Requirements: 4.3, 4.4_

- [x] 4. Implement iCloud storage integration
  - [x] 4.1 Create iCloudStorageManager with CloudKit integration
    - Set up CloudKit container and schema for summary storage
    - Implement iCloud sync enable/disable functionality in settings
    - Create sync status tracking and UI updates
    - _Requirements: 5.1, 5.2_

  - [x] 4.2 Add summary synchronization and conflict resolution
    - Implement summary upload and download from CloudKit
    - Add conflict resolution for concurrent edits across devices
    - Handle network availability changes and offline scenarios
    - _Requirements: 5.2, 5.3, 5.4_

- [x] 5. Enhance file management system for selective deletion
  - [x] 5.1 Create EnhancedFileManager with relationship tracking
    - Implement FileRelationships model to track recording/transcript/summary connections
    - Create methods to query and update file relationships
    - Add UI indicators for file availability status
    - _Requirements: 6.1, 6.2, 6.4_

  - [x] 5.2 Implement selective deletion logic
    - Modify deletion workflows to preserve summaries when recordings are deleted
    - Ensure transcripts are automatically deleted with recordings
    - Update UI to clearly indicate when audio source is no longer available
    - _Requirements: 6.1, 6.2, 6.3, 6.4_

- [x] 6. Update existing services to support chunking
  - [x] 6.1 Modify OpenAI transcription service for chunked processing
    - Update OpenAITranscribeService to handle file size checking and chunking
    - Implement chunk processing with proper sequence tracking
    - Add transcript reassembly for chunked results
    - _Requirements: 3.1, 3.4, 3.5_

  - [x] 6.2 Update Whisper service for duration-based chunking
    - Modify WhisperService to check file duration and chunk if needed
    - Implement 1-hour duration limit with proper time-based splitting
    - Add chunk processing and transcript reassembly
    - _Requirements: 3.2, 3.4, 3.5_

  - [x] 6.3 Update AWS Transcribe service for duration-based chunking
    - Modify AWSTranscribeService to handle 2-hour duration limits
    - Implement time-based chunking with sequence tracking
    - Add reassembly logic for AWS transcript format
    - Ensure that when the last chunk is processed and reassembled that the naming all works together so that summary will see the updated transcript and not the placeholder
    - _Requirements: 3.2, 3.4, 3.5_

  - [x] 6.4 Update Apple Intelligence service for duration-based chunking
    - Modify Apple Intelligence transcription to handle 15-minute limit
    - Implement duration checking and chunking for longer files
    - Add transcript reassembly for Apple Intelligence format
    - _Requirements: 3.3, 3.4, 3.5_

- [x] 7. Integrate enhanced audio session with recording workflow
  - [x] 7.1 Update AudioRecorderViewModel with enhanced audio session
    - Replace existing audio session configuration with EnhancedAudioSessionManager
    - Add mixed audio recording support to startRecording method
    - Implement background recording continuation logic
    - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3_

  - [x] 7.2 Add audio interruption handling and recovery
    - Implement audio interruption notification handling
    - Add automatic session recovery when returning to foreground
    - Update UI to show recording status during background operation
    - _Requirements: 2.2, 2.3_

- [x] 8. Update UI components for new functionality
  - [x] 8.1 Add iCloud sync settings to SettingsView
    - Display iCloud sync status and toggle
    - Show sync progress and last sync time
    - Provide manual sync trigger option
    - _Requirements: 3.1, 3.2, 3.3_

  - [x] 8.2 Add background processing status to recording UI
    - Show active transcription/summarization jobs
    - Display progress indicators for background tasks
    - Provide job management controls
    - _Requirements: 2.1, 2.2, 2.3_

  - [x] 8.3 Enhance deletion confirmation dialogs
    - Show file relationships (recording → transcript → summary)
    - Provide options to preserve summaries when deleting recordings
    - Display file sizes and creation dates
    - _Requirements: 4.1, 4.2, 4.3_

- [x] 9. Add comprehensive error handling and recovery
  - [x] 9.1 Implement AudioProcessingError types and handling
    - Create comprehensive error types for all new functionality
    - Add error recovery strategies for common failure scenarios
    - Implement user-friendly error messages and recovery suggestions
    - _Requirements: All requirements - error handling_

  - [x] 9.2 Add logging and debugging support
    - Implement detailed logging for chunking, background processing, and sync operations
    - Add debug modes for troubleshooting processing issues
    - Create diagnostic information for support purposes
    - _Requirements: All requirements - debugging support_

- [x] 10. Write comprehensive tests for new functionality
  - [x] 10.1 Create unit tests for core services
    - Write tests for EnhancedAudioSessionManager functionality
    - Test AudioFileChunkingService with various file sizes and durations
    - Create tests for BackgroundProcessingManager job handling
    - _Requirements: All requirements - testing_

  - [x] 10.2 Add integration tests for end-to-end workflows
    - Test complete recording workflow with mixed audio
    - Test large file processing with chunking and background processing
    - Test iCloud sync functionality across different scenarios
    - _Requirements: All requirements - integration testing_

- [x] 11. Performance optimization and memory management
  - [x] 11.1 Optimize chunking performance and memory usage
    - Implement streaming for large file processing to minimize memory usage
    - Add progress tracking for chunking operations
    - Optimize temporary file management and cleanup
    - _Requirements: 3.6, performance considerations_

  - [x] 11.2 Optimize background processing and battery usage
    - Implement efficient background task management
    - Add battery usage monitoring and optimization
    - Optimize network usage for iCloud sync operations
    - _Requirements: 4.4, 5.2, performance considerations_

- [x] 12. Final integration and testing
  - [x] 12.1 Integration testing with existing app functionality
    - Test all new features with existing recording and summarization workflows
    - Verify backward compatibility with existing data
    - Test app lifecycle scenarios (backgrounding, termination, restart)
    - _Requirements: All requirements - final integration_

  - [x] 12.2 User acceptance testing and polish
    - Test user workflows for all new functionality
    - Refine UI/UX based on testing feedback
    - Add final documentation and help text
    - _Requirements: All requirements - user experience_