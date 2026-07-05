# BisonNotes Regression Testing Regimen

This regimen protects the release-critical paths that are expensive to rediscover manually: recording file validity, transcription flow, iCloud exclusions, watch transfer state, share import, Catalyst audio, and launch/navigation smoke coverage.

## Local Pre-Merge Gate

Run this before merging code changes that touch app behavior:

```bash
git diff --check
swiftlint lint --reporter summary
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /private/tmp/bisonnotes-test-derived
```

Expected result: app unit tests, security tests, seeded UI smoke tests, and launch tests pass without live network, CloudKit mutation, microphone input, or model downloads.

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

Record screenshots, resulting audio duration, transcript text, sync/import status, and relevant log excerpts for the release notes or PR.

## UI Test Launch Contract

The app supports these DEBUG-only launch arguments for deterministic UI tests:

- `--ui-testing`: enables stable first-launch defaults and the app-ready marker.
- `--reset-test-data`: clears local Core Data rows and test fixture files in the test app container.
- `--seed-sample-recording`: creates a local sample recording, transcript, and summary without microphone, network, CloudKit, or model downloads.
- `--disable-cloud-services`: forces iCloud sync and automatic CloudKit work off for the test process.

Do not use these launch arguments for manual validation of real CloudKit, microphone, watch, or ScreenCaptureKit behavior.
