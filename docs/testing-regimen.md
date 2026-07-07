# BisonNotes Regression Testing Regimen

This regimen protects the release-critical paths that are expensive to rediscover manually: recording file validity, transcription flow, iCloud exclusions, watch transfer state, share import, Catalyst audio, and launch/navigation smoke coverage.

## Local Pre-Merge Gate

Run this before merging code changes that touch app behavior:

```bash
git diff --check
swiftlint lint --reporter summary
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /private/tmp/bisonnotes-test-derived
```

Expected result: app unit tests, security tests, seeded UI smoke tests, launch tests, and accessibility audit tests pass without live network, CloudKit mutation, microphone input, or model downloads.

## Accessibility Gate

Run the local pre-merge gate after changes that touch SwiftUI layout, labels, navigation, media controls, Settings, Setup, Watch recording, or App Store metadata. The UI test target includes `BisonNotesAIAccessibilityTests.swift`, which uses seeded data and `XCUIApplication.performAccessibilityAudit` for:

- Record
- Recordings list
- Audio Player
- Transcripts
- Summaries
- Summary detail
- Setup
- Settings

Automated audit failures must either be fixed or documented with a specific exception and manual evidence. Keep `docs/accessibility-matrix.md`, `docs/app-store-accessibility.md`, and the public accessibility page in sync with the actual evidence.

## Release Candidate Gate

Run the local pre-merge gate, then run:

```bash
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI Watch App" -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' -derivedDataPath /private/tmp/bisonnotes-watch-test-derived
xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=macOS,variant=Mac Catalyst' -configuration Debug -derivedDataPath /private/tmp/bisonnotes-catalyst-derived build
```

Expected result: watch metadata tests pass, the watch scheme builds, and the Catalyst build compiles with the current SwiftPM package graph.

## Manual Hardware Validation

Simulator tests are not enough for these capabilities. Capture evidence for every release candidate:

- iPhone/iPad: record with the real microphone, stop, verify playback duration is non-zero, and generate a transcript.
- Mac Catalyst: record microphone-only audio, then record a real meeting/system-audio source with meeting-audio capture enabled; verify the final audio plays and has non-zero duration.
- Apple Watch: tap to record, mute to pause, unmute to resume, stop, transfer to iPhone, and verify import appears once.
- Parakeet: download or reuse the on-device model on a supported device and transcribe a short known audio fixture.
- iCloud: verify eligible content syncs across two devices or matching TestFlight builds, and verify a recording marked Keep on This Device does not sync.
- Share extension: import audio from Voice Memos or Files, then verify the app creates a recording without scanning unrelated shared-container files.
- System integrations: smoke-test Control Center recording and Action Button launch on supported devices.
- Accessibility: complete common tasks with VoiceOver and Voice Control on iPhone/iPad; sample Switch Control; verify Full Keyboard Access on iPad keyboard and Mac Catalyst; test largest Dynamic Type sizes; test light/dark, Increase Contrast, Reduce Transparency, Bold Text, Grayscale, and Differentiate Without Color; enable Reduce Motion and verify recording indicators remain understandable; test Apple Watch VoiceOver for start, mute, stop, transfer progress, low battery, and error recovery.

Record screenshots, resulting audio duration, transcript text, sync/import status, and relevant log excerpts for the release notes or PR.

## UI Test Launch Contract

The app supports these DEBUG-only launch arguments for deterministic UI tests:

- `--ui-testing`: enables stable first-launch defaults and the app-ready marker.
- `--reset-test-data`: clears local Core Data rows and test fixture files in the test app container.
- `--seed-sample-recording`: creates a local sample recording, transcript, and summary without microphone, network, CloudKit, or model downloads.
- `--disable-cloud-services`: forces iCloud sync and automatic CloudKit work off for the test process.
- `--show-first-setup`: keeps the first-launch setup screen visible for setup accessibility audits.

Do not use these launch arguments for manual validation of real CloudKit, microphone, watch, or ScreenCaptureKit behavior.
