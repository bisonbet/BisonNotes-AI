# BisonNotes Regression Testing Regimen

This regimen protects the release-critical paths that are expensive to rediscover manually: recording file validity, transcription flow, iCloud exclusions, watch transfer state, share import, Catalyst and native Mac behavior, and launch/navigation smoke coverage.

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
xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'platform=macOS' -configuration Debug -derivedDataPath /private/tmp/bisonnotes-native-mac-derived build
```

Expected result: watch metadata tests pass, the watch scheme builds, and both Mac targets compile with the current SwiftPM package graph.

Before a native Mac beta or cutover candidate, also archive the native app:

```bash
xcodebuild archive -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'generic/platform=macOS' -archivePath /private/tmp/BisonNotes-Native-Mac.xcarchive ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64
```

## Native macOS Phase 3 Exit Gate

Use a signed native build. The Phase 3 gate is complete only when the automated checks are green and every interaction below has been exercised. Record results in `docs/macos-phase-3-exit-report.md`.

### Automated and product inspection

- Run `git diff --check` and normal SwiftLint from `BisonNotes AI/BisonNotes AI` using the committed baseline.
- Build native macOS, iOS Simulator, and Mac Catalyst; run the iOS unit-test target.
- Inspect the native product's `Metadata.appintents/extract.actionsdata` for `StartRecordingIntent` and its App Shortcut phrases.
- Inspect the compiled asset catalog for every Mac AppIcon rendition from 16×16 through 512×512 points at 1x/2x.
- Confirm the main window is resizable, honors its minimum size, and reopens after its last window is closed.

### Mac-native interaction pass

- Open Settings with Command-comma; confirm it is a separate, closable Settings window and controls remain scrollable.
- Verify File-menu commands and key equivalents: New Recording (Command-N), Import Audio (Command-I), Import Transcript (Shift-Command-I), and Import From Link (Shift-Command-L).
- Open Import From Link from the File menu and confirm it is a bounded modal attached to the main window.
- Verify Command-1/2/3 navigation and the standard Undo, Redo, Cut, Copy, Paste, and Select All Edit commands in a text field.
- Open summary, transcript, recording/player, recordings-library, location, background-processing, and processing-job windows where data is available. Move and resize them, confirm their whole content scrolls at minimum size, and confirm they close normally.
- From Edit Transcript, open its summary, then close it with both Done and Escape.
- Exercise one representative bounded modal for import, settings/configuration, and content editing.
- In the Shortcuts app, find BisonNotes AI's Start Recording action. Run it once while the app is closed and once while it is already open; each run must activate the native app and start exactly one recording.
- Verify the Dock/Finder icon is the BisonNotes icon rather than a blank placeholder.

Phase 2 hardware/runtime cases such as external-microphone hot swap, ScreenCaptureKit meeting audio, long background processing, export/share destinations, and archive bookmark restoration remain mandatory before Phase 4 beta even if the Phase 3 Mac-idiom gate is green.

## Manual Hardware Validation

Simulator tests are not enough for these capabilities. Capture evidence for every release candidate:

- iPhone/iPad: record with the real microphone, stop, verify playback duration is non-zero, and generate a transcript.
- Mac Catalyst: record microphone-only audio, then record a real meeting/system-audio source with meeting-audio capture enabled; verify the final audio plays and has non-zero duration.
- Native macOS: repeat the microphone-only and meeting/system-audio recordings; change the selected microphone, hot-plug an external input during recording, and verify the final audio has no clicks, clipping, gaps beyond the device transition, or duplicated system audio.
- Native macOS capture integrity: start with the built-in input and each USB/Bluetooth input, including Poly Sync 10 when available. Confirm the UI does not enter the recording state until a real input buffer is committed. Mute or otherwise stall the active input and verify the app reports reconnection, retries the engine, and either resumes on confirmed audio or stops and saves the audio captured before the stall.
- Native macOS salvage: with meeting-audio capture enabled, make one track unavailable at a time and confirm the usable microphone-only or system-only track is saved. Force a finalization failure in a development build and confirm the source media remains under Application Support/Recording Recovery and appears in the exported diagnostic inventory.
- Apple Watch: tap to record, mute to pause, unmute to resume, stop, transfer to iPhone, and verify import appears once.
- Parakeet: download or reuse the on-device model on a supported device and transcribe a short known audio fixture.
- iCloud: verify eligible content syncs across two devices or matching TestFlight builds, and verify a recording marked Keep on This Device does not sync.
- Share extension: import audio from Voice Memos or Files, then verify the app creates a recording without scanning unrelated shared-container files.
- System integrations: smoke-test Control Center recording and Action Button launch on supported devices.
- Accessibility: complete common tasks with VoiceOver and Voice Control on iPhone/iPad; sample Switch Control; verify Full Keyboard Access on iPad keyboard, Mac Catalyst, and native macOS; test largest Dynamic Type sizes; test light/dark, Increase Contrast, Reduce Transparency, Bold Text, Grayscale, and Differentiate Without Color; enable Reduce Motion and verify recording indicators remain understandable; test Apple Watch VoiceOver for start, mute, stop, transfer progress, low battery, and error recovery.

For every Mac recording case, capture the first-buffer log line, frame counts at stop, finalization-plan log line, resulting audio duration, and playback of each expected source. Also record screenshots, transcript text, sync/import status, and other relevant log excerpts for the release notes or PR.

## UI Test Launch Contract

The app supports these DEBUG-only launch arguments for deterministic UI tests:

- `--ui-testing`: enables stable first-launch defaults and the app-ready marker.
- `--reset-test-data`: clears local Core Data rows and test fixture files in the test app container.
- `--seed-sample-recording`: creates a local sample recording, transcript, and summary without microphone, network, CloudKit, or model downloads.
- `--disable-cloud-services`: forces iCloud sync and automatic CloudKit work off for the test process.
- `--show-first-setup`: keeps the first-launch setup screen visible for setup accessibility audits.

Do not use these launch arguments for manual validation of real CloudKit, microphone, watch, or ScreenCaptureKit behavior.
