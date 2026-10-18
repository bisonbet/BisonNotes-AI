# Developing BisonNotes AI

Build, test, and architecture notes for contributors. Rules that agents and
reviewers must follow, such as post-commit work, iCloud arbitration, and
reasoning budgets, live in [`CLAUDE.md`](../CLAUDE.md).

## Requirements

| | Version |
| --- | --- |
| App version | 3.0 |
| Xcode | 26.6 or later (tested with Xcode 27) |
| Swift | 6 (Swift 6 language mode on every target) |
| iOS / iPadOS deployment target | 18.5 |
| macOS deployment target | 15.0, Apple silicon only |
| watchOS deployment target | 11.5 |

Mac builds are Apple silicon only (`EXCLUDED_ARCHS = x86_64`) because MLX Swift
requires it. Mac Catalyst has been removed; the `BisonNotes AI macOS` scheme
builds the native Mac app.

## Build and test

```bash
open "BisonNotes AI/BisonNotes AI.xcodeproj"
```

```bash
xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

```bash
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```bash
xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'platform=macOS' -configuration Debug build
```

```bash
xcodebuild archive -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" -destination 'generic/platform=macOS' -configuration Release
```

Unit tests run from the iOS scheme. Use the watch app scheme to run the watch
target. Swift Package Manager dependencies resolve automatically in Xcode.

In Linux cloud sessions without Xcode, `.claude/swift-check/swift-check.sh`
offers `parse`, `typecheck`, and `test` for Foundation-only sources; anything
else still needs an Xcode build.

### Agent-driven builds and tests

The project registers Sentry's [MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP)
(formerly XcodeBuildMCP) in `.mcp.json`, pinned to a fixed version with
Sentry telemetry turned off. `.mobilebuildmcp/config.yaml` sets the project,
scheme, and default simulator, so its tools run without extra arguments. The
same tools are available from the command line:

```bash
npx -y mobilebuildmcp@2.7.1 simulator build-and-run
```

- **Simulator**: build, run, test, LLDB debugging, and UI automation (read the
  accessibility tree, tap, type, swipe, take screenshots). The app's
  `AccessibilityIdentifiers` show up as element ids.
- **Physical device**: build, install, launch, stop, and run XCTest. UI
  automation and debugger attach work only in the simulator, so to drive a
  device, use the UI test target with `test_device`. Pass the device's UDID
  with `--device-id`; it isn't committed.
- A Debug build on a device uses the CloudKit development environment and
  replaces any TestFlight or App Store install of the app.

Release validation follows the [regression testing regimen](testing-regimen.md),
including the app and watch test plans and the manual hardware checks.

## Project structure

| Path | Contents |
| --- | --- |
| `BisonNotes AI/BisonNotes AI/` | Shared iOS, iPadOS, and macOS app source: `Models/`, `Views/`, `ViewModels/`, `Services/`, `FluidAudio/`, `Wyoming/`, `WatchConnectivity/` |
| `BisonNotes AI/BisonNotes AI Watch App/` | watchOS app |
| `BisonNotes AI/BisonNotes Watch Widget/` | Watch complications |
| `BisonNotes AI/BisonNotes AI Controls/` | Control Center recording widget |
| `BisonNotes AI/BisonNotes Mac Widget/` | macOS desktop widgets |
| `BisonNotes AI/BisonNotes Share/`, `BisonNotes Share macOS/` | Share extensions |
| `BisonNotes AI/BisonNotes AITests/`, `BisonNotes AIUITests/` | Unit and UI tests, plus watch tests |
| `docs/` | User guides, release guides, and engineering records ([index](README.md)) |

The project uses Xcode's file-system synchronized groups, so new Swift files
dropped into these folders are added to the project automatically.

## Architecture

- **Data**: Core Data (`BisonNotes_AI.xcdatamodeld`) stores recordings,
  transcripts, summaries, and jobs. Go through `CoreDataManager` and
  `AppDataCoordinator`; views never touch Core Data directly.
- **Recording**: `AVAudioRecorder` on iOS and iPadOS, `AVAudioEngine` with
  `AVAudioFile` on macOS (`AudioRecorderViewModel+MacEngine.swift`). Mac meeting
  audio comes from `MacSystemAudioCapture`. Interruption recovery is coordinated
  by `AudioInterruptionRecoveryCoordinator`.
- **Transcription**: `EnhancedTranscriptionManager` orchestrates the engines.
  `AudioFileChunkingService.reassembleTranscript` is the single reassembly path;
  Local Speaker Labels run once over the complete source audio afterwards
  (`FluidAudio/LocalDiarizationManager.swift`, `SpeakerTranscriptAligner.swift`).
- **AI engines**: each engine pairs a service with a settings view. Output
  budgets come from `SummaryThinkingModelCatalog`, and prompt text from
  `SummaryPromptComposer`.
- **Background work**: `BackgroundProcessingManager` queues jobs with retries,
  timeouts, and recovery. `CacheMaintenanceService` bounds the model, CloudKit
  asset, and log caches.
- **iCloud sync**: `iCloudStorageManager` decides which copy wins. The engine in
  `Services/` (`CloudKitTransport`, `CloudKitBatchExecutor`,
  `CloudKitRetryPolicy`, `CloudContentIndexCoordinator`,
  `CloudSyncOperationCoordinator`, `CloudAudioAssetStaging`, `CloudSyncMetrics`)
  batches requests and serializes operations.
- **Watch**: `WatchConnectivityManager` sends complete files with
  `WCSession.transferFile` and handles acknowledgements and duplicates.
- **UI**: SwiftUI views under `Views/`. AI content renders through `AITextView`
  using Textual.

### Key modules

| Area | Types |
| --- | --- |
| Recording | `AudioRecorderViewModel` and its extensions, `EnhancedAudioSessionManager`, `MacInputDeviceMonitor`, `RecordingCombiner` |
| Transcription | `FluidAudioManager`, `MistralTranscribeService`, `WhisperService`, `WyomingWhisperClient`, `LiveTranscriptionService` |
| Summaries | `MLXSwiftEngine`, `AppleNativeEngine`, `MistralAISummarizationService`, `GoogleAIStudioService`, Compatible API service |
| Transcript cleanup | `TranscriptCleanupCoordinator`, `TranscriptCleanupQueue` |
| Web import | `WebImportManager`, `WebImportDownloader`, `YouTubeImportService` |
| Security | `KeychainSecretStore`, `EndpointSecurityPolicy`, `AppFileProtection` |
| Export | `PDFExportService`, `SummaryExportFormatter`, `RecordingArchiveService` |
| System integration | `SystemIntegrationManager`, `StartRecordingIntent`, `ActionButtonLaunchManager`, `RecordingControlWidget` |
| Feature gates | `BetaFeatures`, `BetaFeaturesView` |

## Configuration

- Never commit API keys. They are entered in the app and stored in the Keychain
  through `KeychainSecretStore`.
- `EndpointSecurityPolicy` blocks public cleartext endpoints unless the
  service's Development Mode override is on. Ollama defaults to
  `http://localhost:11434`.
- Keep `Info.plist` and the `.entitlements` files in step with the features you
  use. `APS_ENVIRONMENT` is `development` for Debug and `production` for
  Release.

### CloudKit schema

The app syncs through the `iCloud.Bison-Networking.BisonNotes-AI` container.
Production builds can't create record types, so any schema change must be made
in the development environment and deployed to production from CloudKit
Dashboard before a TestFlight or App Store release. The app-managed record types
are `CD_BackupRecording`, `CD_BackupTranscript`, `CD_BackupSummary`,
`CD_BackupSettings`, `CD_BackupContentIndex`, and `CD_BackupDeletion`.

## In-app help and user guides

Each app release has its own complete user guide in
[`docs/user-guide/`](user-guide/README.md), published at
`/bisonnotes-ai-v<major>-<minor>/`. In-app Help opens the guide for the
installed version (`BisonNotesDocumentation`), and `/bisonnotes-ai/` redirects
to the guide for the current App Store release.

- Section anchors (`bn-ai`) are the same in every guide. Never rename or
  remove one.
- Publish a release's guide before its build goes to TestFlight, and move the
  `/bisonnotes-ai/` redirect when it goes live on the App Store.
- `BisonNotesDocumentationTests` fails if the current version has no guide, or
  if a guide is missing an anchor the app links to.

The [user guide README](user-guide/README.md) has the full process and the
website's redirect setup.

## Accessibility

- Shared strings and modifiers: `AccessibilitySupport.swift`. Use these helpers
  rather than one-off labels.
- Automation identifiers: `AccessibilityIdentifiers.swift`. Add them only for
  surfaces that UI tests or audits need.
- UI audits: `BisonNotesAIAccessibilityTests.swift`, using the DEBUG launch
  arguments in `UITestSupport.swift`.

```bash
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:"BisonNotes AIUITests/BisonNotesAIAccessibilityTests"
```

Keep the [accessibility matrix](accessibility-matrix.md), the [App Store
accessibility notes](app-store-accessibility.md), and the public
[accessibility page](accessibility.html) in line with what the app actually
does. A release still needs checks on real devices: VoiceOver, Voice Control,
Switch Control, Full Keyboard Access, the largest Dynamic Type sizes, contrast,
Reduce Motion, and Apple Watch VoiceOver.

## Speaker model publishing

Don't publish speaker-model sizes, RAM requirements, speed, or accuracy until the
measurement gate in the [Local Speaker Labels plan](local-speaker-labels-delegation-plan.md)
has captured and approved them. Review the LS-EEND model card and its source
credits before each release.

## Contributing

Create a feature branch in your fork and open a pull request. Include build and
test results, and screenshots for UI changes.
