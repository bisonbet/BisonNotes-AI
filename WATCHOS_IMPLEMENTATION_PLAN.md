# WatchOS Companion App Implementation Plan

This document provides a complete step-by-step implementation plan for adding a watchOS companion app to the BisonNotes AI audio recording app. Each task is designed as a clear prompt for Claude Code to execute.

## Prerequisites
- Xcode project: `BisonNotes AI.xcodeproj`
- Existing iOS app with Core Data recording architecture
- Target deployment: watchOS 8.0+, iOS 15.0+

---

## Phase 1: Project Setup and Connectivity Foundation

### Task 1.1: Add WatchOS App Target
**Prompt**: "Add a new watchOS app target to the existing Xcode project. Configure it with the following specifications:
- Target name: BisonNotes AI Watch App
- Bundle identifier: com.yourcompany.bisonnotesai.watchapp
- Deployment target: watchOS 8.0
- Language: Swift
- Interface: SwiftUI
- Include Watch App Extension
- Configure app groups: group.bisonnotesai.shared"

### Task 1.2: Configure WatchConnectivity Entitlements
**Prompt**: "Add WatchConnectivity capabilities to both iOS and watchOS targets:
- Add WatchConnectivity.framework to both targets
- Configure Info.plist entries for background modes (audio recording)
- Add NSMicrophoneUsageDescription to both Info.plist files
- Set up app groups entitlement in both targets"

### Task 1.3: Create Shared Data Models
**Prompt**: "Create shared data models for watch-phone communication:
- Create `WatchRecordingMessage.swift` with message types: start, stop, pause, resume, status
- Create `WatchRecordingState.swift` enum with states: idle, recording, paused, processing
- Create `WatchAudioChunk.swift` for audio data transfer
- Add these files to both iOS and watchOS targets"

---

## Phase 2: Watch Connectivity Infrastructure

### Task 2.1: Create WatchConnectivityManager for iOS
**Prompt**: "Create `WatchConnectivityManager.swift` in the iOS app with the following functionality:
- Singleton pattern with WCSession management
- Methods: `sendRecordingCommand()`, `sendAudioChunk()`, `sendStatusUpdate()`
- Delegate methods to handle incoming watch messages
- Integration points with existing `AudioRecorderViewModel`
- Error handling and session state management"

### Task 2.2: Create WatchConnectivityManager for watchOS
**Prompt**: "Create `WatchConnectivityManager.swift` in the watchOS app with the following functionality:
- Mirror structure of iOS version but adapted for watch
- Methods: `sendRecordingCommand()`, `sendAudioData()`, `requestPhoneStatus()`
- Handle phone app activation when watch initiates recording
- Background app refresh and session reactivation logic"

### Task 2.3: Integrate Watch Connectivity with AudioRecorderViewModel
**Prompt**: "Modify the existing `AudioRecorderViewModel.swift` to support watch connectivity:
- Add `WatchConnectivityManager` property and initialization
- Add methods: `handleWatchRecordingCommand()`, `syncStateWithWatch()`
- Modify `startRecording()` to support watch-initiated sessions
- Add watch status broadcasting in recording state changes
- Ensure Core Data integration works with watch-initiated recordings"

---

## Phase 3: Watch App Core Implementation

### Task 3.1: Create WatchAudioManager
**Prompt**: "Create `WatchAudioManager.swift` for watchOS with the following functionality:
- `AVAudioRecorder` setup with watch-optimized settings
- Audio session configuration for watchOS
- Methods: `startRecording()`, `stopRecording()`, `pauseRecording()`, `resumeRecording()`
- Audio chunk generation for transfer to phone
- Battery-aware recording with duration limits"

### Task 3.2: Create WatchRecordingViewModel
**Prompt**: "Create `WatchRecordingViewModel.swift` as the main state manager for the watch app:
- `@Published` properties: `isRecording`, `isPaused`, `recordingTime`, `connectionStatus`
- Integration with `WatchAudioManager` and `WatchConnectivityManager`
- Methods: `startRecording()`, `stopRecording()`, `togglePause()`, `syncWithPhone()`
- Timer management for recording duration display
- Error handling and user feedback"

### Task 3.3: Create Main Watch Interface
**Prompt**: "Create `WatchRecordingView.swift` as the main SwiftUI interface for the watch app:
- Large circular record button (red when recording, green when idle)
- Pause/resume button below record button (visible only when recording)
- Recording timer display in MM:SS format
- Connection status indicator (connected/disconnected to phone)
- Use SF Symbols for icons: record.circle, pause.circle, phone.connection
- Haptic feedback for button presses"

---

## Phase 4: Advanced Recording Features

### Task 4.1: Implement Audio Chunk Transfer
**Prompt**: "Implement audio chunk transfer system:
- Modify `WatchAudioManager` to generate 5-second audio chunks during recording
- Add chunk buffering system in case of connectivity issues
- Implement progressive transfer of audio data to phone via WatchConnectivity
- Add chunk validation and error recovery on phone side
- Integrate received watch audio chunks with phone's primary recording"

### Task 4.2: Add Recording State Synchronization
**Prompt**: "Implement comprehensive state synchronization between watch and phone:
- Real-time sync of recording state (idle/recording/paused)
- Bidirectional communication for recording controls
- Handle edge cases: watch disconnection mid-recording, phone app termination
- Add automatic reconnection and state recovery
- Implement conflict resolution when both devices have different states"

### Task 4.3: Enhance Phone App for Watch Integration
**Prompt**: "Modify the phone app to fully support watch-initiated recordings:
- Update `RecordingWorkflowManager` to handle watch-originated recordings
- Add watch audio integration to Core Data recording entries
- Modify UI to show watch connection status and recording source
- Add settings toggle for watch integration enable/disable
- Ensure all existing AI processing pipeline works with watch recordings"

---

## Phase 5: User Experience and Polish

### Task 5.1: Add Watch App Navigation and Settings
**Prompt**: "Create additional watch app screens:
- Settings view with recording quality options and phone sync status
- Recording history view showing recent recordings (titles only)
- Connection troubleshooting view with manual sync button
- Add navigation between views using SwiftUI NavigationView
- Implement proper view transitions and state management"

### Task 5.2: Implement Haptic and Audio Feedback
**Prompt**: "Add comprehensive feedback systems to the watch app:
- Haptic feedback for recording start/stop (different patterns)
- Audio confirmation sounds when available (respect silent mode)
- Visual animations for recording state changes
- Progress indicators for audio chunk transfers
- Error state visual feedback with clear user messages"

### Task 5.3: Add Battery and Performance Optimization
**Prompt**: "Implement battery and performance optimizations:
- Battery level monitoring and low battery warnings
- Automatic recording quality adjustment based on battery level
- Background app refresh optimization for connectivity
- Memory management for audio buffers
- Recording duration limits based on available storage and battery"

---

## Phase 6: Testing and Integration

### Task 6.1: Create Watch App Testing Suite
**Prompt**: "Create comprehensive testing for watch app functionality:
- Unit tests for `WatchRecordingViewModel` state management
- Integration tests for WatchConnectivity message handling
- Mock objects for testing without physical watch hardware
- Test edge cases: connection loss, battery depletion, storage full
- Performance tests for audio chunk transfer efficiency"

### Task 6.2: Add Error Handling and Recovery
**Prompt**: "Implement robust error handling throughout the watch app:
- Connection failure recovery with user-friendly messages
- Audio recording failure fallbacks
- Storage and memory error handling
- Network timeout and retry logic for connectivity
- User guidance for common error scenarios"

### Task 6.3: Final Integration and UI Polish
**Prompt**: "Complete final integration and user experience refinements:
- Ensure consistent design language between phone and watch apps
- Add onboarding flow for first-time watch app users
- Implement accessibility features (VoiceOver support)
- Add localization support for watch app strings
- Final testing on physical devices and App Store preparation"

---

## Phase 7: Documentation and Deployment

### Task 7.1: Update Project Documentation
**Prompt**: "Update all project documentation to include watch app functionality:
- Update CLAUDE.md with watch app architecture details
- Add watch app development guidelines
- Document watch-phone communication protocols
- Update build and deployment instructions for watch target"

### Task 7.2: App Store Preparation
**Prompt**: "Prepare both apps for App Store submission:
- Create watch app screenshots for App Store listing
- Update app descriptions to mention watch companion functionality
- Ensure both apps meet Apple's review guidelines
- Test final builds on multiple device combinations
- Prepare release notes highlighting watch integration features"

---

## Implementation Notes

### File Structure After Completion
```
BisonNotes AI/
├── BisonNotes AI/                    # iOS App
│   ├── WatchConnectivity/
│   │   ├── WatchConnectivityManager.swift
│   │   └── WatchRecordingMessage.swift
│   └── [existing iOS files]
├── BisonNotes AI Watch App/          # watchOS App
│   ├── Views/
│   │   ├── WatchRecordingView.swift
│   │   └── WatchSettingsView.swift
│   ├── ViewModels/
│   │   └── WatchRecordingViewModel.swift
│   ├── Managers/
│   │   ├── WatchConnectivityManager.swift
│   │   └── WatchAudioManager.swift
│   └── Models/
│       ├── WatchRecordingState.swift
│       └── WatchAudioChunk.swift
└── Shared/                           # Shared between iOS and watchOS
    └── WatchRecordingMessage.swift
```

### Key Integration Points
- `AudioRecorderViewModel.swift` - Enhanced with watch connectivity
- `RecordingWorkflowManager.swift` - Updated to handle watch recordings
- Core Data - Extended to store watch audio metadata
- Background processing - Configured for watch-initiated recordings

### Success Criteria
- [ ] Watch app can start/stop/pause recordings on phone
- [ ] Watch records backup audio and transfers to phone
- [ ] Phone app processes watch recordings through normal AI pipeline
- [ ] Robust error handling and disconnection recovery
- [ ] Battery-efficient operation on both devices
- [ ] Seamless user experience across both platforms

This implementation plan provides a complete roadmap for adding watchOS functionality to your existing audio recording app while maintaining the sophisticated Core Data and AI processing architecture you've already built.