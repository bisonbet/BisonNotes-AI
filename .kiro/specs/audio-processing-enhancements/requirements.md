# Requirements Document

## Introduction

This feature enhances the Audio Journal app with advanced audio processing capabilities, background operation support, cloud storage integration, and improved file management. The enhancements focus on providing a seamless user experience for recording, transcribing, and summarizing audio content while maintaining system audio playback and supporting background operations.

## Requirements

### Requirement 1

**User Story:** As a user, I want to record audio without interrupting my music or other audio playback, so that I can capture thoughts while listening to content.

#### Acceptance Criteria

1. WHEN the app starts THEN the system SHALL NOT interrupt existing audio playback from other apps
2. WHEN I start recording THEN the system SHALL allow simultaneous audio recording and playback from other sources
3. WHEN recording is active THEN the system SHALL use appropriate audio session configuration to enable mixed audio

### Requirement 2

**User Story:** As a user, I want to record audio while the app is in the background, so that I can capture content while using other applications.

#### Acceptance Criteria

1. WHEN the app is backgrounded during recording THEN the system SHALL continue recording audio
2. WHEN recording in background THEN the system SHALL maintain recording session without interruption
3. WHEN returning to foreground during background recording THEN the system SHALL show current recording status

### Requirement 3

**User Story:** As a user, I want large audio files to be automatically split for processing, so that transcription services can handle them within their limits.

#### Acceptance Criteria

1. WHEN audio file exceeds 24MB for OpenAI THEN the system SHALL split the file into smaller chunks
2. WHEN using Whisper or AWS Transcribe THEN the system SHALL split files longer than 2 hours into time-based segments
3. WHEN using Apple Intelligence THEN the system SHALL split files longer than 15 minutes into time-based segments
4. WHEN files are split THEN the system SHALL maintain sequence tracking for proper reassembly
5. WHEN processing split files THEN the system SHALL reconstruct transcripts in correct chronological order
6. WHEN processing is complete, THEN the system SHALL remove split files from storage and just keep the original recording

### Requirement 4

**User Story:** As a user, I want transcription and summarization to run in the background, so that I can navigate the app while processing continues.

#### Acceptance Criteria

1. WHEN starting transcription or summarization THEN the system SHALL allow navigation to other app sections
2. WHEN background processing is active THEN the system SHALL prevent starting additional transcription/summarization jobs
3. WHEN background processing completes THEN the system SHALL automatically update the transcript/summary and generate appropriate titles
4. WHEN app is backgrounded during processing THEN the system SHALL continue processing and check status periodically

### Requirement 5

**User Story:** As a user, I want to save my summaries to iCloud, so that I can access them across my devices and have backup storage.

#### Acceptance Criteria

1. WHEN in settings THEN the system SHALL provide an option to enable iCloud storage for summaries
2. WHEN iCloud storage is enabled THEN the system SHALL save new summaries to iCloud
3. WHEN iCloud storage is enabled THEN the system SHALL sync existing summaries to iCloud
4. WHEN iCloud storage is disabled THEN the system SHALL store summaries locally only

### Requirement 6

**User Story:** As a user, I want to delete recordings while keeping their summaries, so that I can manage storage while preserving processed content.

#### Acceptance Criteria

1. WHEN deleting a recording THEN the system SHALL keep the associated summary
2. WHEN recording is deleted THEN the system SHALL automatically delete the associated transcript
3. WHEN summary exists without recording THEN the system SHALL clearly indicate the audio source is no longer available