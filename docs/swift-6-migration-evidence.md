# Swift 6 Migration Evidence

This is the lead-owned evidence ledger for `docs/swift-6-migration-delegation-plan.md`.
It records the live baseline, staged strict-concurrency diagnostics, package handoffs,
target migration matrix, and release/manual evidence. Compilation and automated tests
do not prove signed-app, hardware, provider-service, CloudKit, or accessibility-release
acceptance.

## Wave 0 baseline

Captured 2026-08-16 on the owner-authorized `swift6migration` branch.

### Repository and ownership

- Branch: `swift6migration`
- HEAD: `8ee5cda0c8ff3d9c4c6dfd93feaf29a3f72e6aab`
- Upstream: `origin/swift6migration`
- Baseline worktree before lead-owned staged edits: clean; `git diff --check` passed
- Existing detached worktree recorded by `git worktree list --porcelain` and left untouched:
  `.claude/worktrees/affectionate-proskuriakova-22daf9` at `3bed7d25bfb3cd10220c94e1dba642c9141bbbf6`
- No required-file dirty set was present, so the plan's Wave 0 overlap stop condition did not apply.

### Toolchain and targets

Commands:

```text
xcodebuild -version
Xcode 26.6
Build version 17F113

xcrun swift --version
Apple Swift version 6.3.3

xcode-select -p
/Applications/Xcode.app/Contents/Developer
```

The iPhoneOS, macOS, and watchOS SDKs all reported `26.5`. `xcodebuild -list`
reported 12 first-party targets, Debug/Release configurations, and these schemes:

- `BisonNotes AI`
- `BisonNotes AI ControlsExtension`
- `BisonNotes AI macOS`
- `BisonNotes AI Watch App`
- `BisonNotes AI Watch App (Complication)`
- `BisonNotes Mac Widget`
- `BisonNotes Share`
- `BisonNotes Share macOS`
- `BisonNotes Watch WidgetExtension`

### Swift settings and package resolution

Before staging the diagnostic setting, a deterministic project-file audit reported:

- `SWIFT_VERSION = 5.0`: 24 configurations
- `SWIFT_VERSION = 6.0`: 0 configurations
- `SWIFT_STRICT_CONCURRENCY`: not set
- `SWIFT_DEFAULT_ACTOR_ISOLATION`: not set
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`: 10 configurations

The committed resolution file is:
`BisonNotes AI/BisonNotes AI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
The package graph resolved in the isolated `/private/tmp/bisonnotes-swift6-wave0-packages`
location, and the committed resolution file remained unchanged. Relevant pins include:

- FluidAudio `0.15.5`
- MLX Swift `0.31.3`
- MLX Swift LM `2.31.3`
- Swift Transformers `1.2.1`
- Swift Concurrency Extras `1.4.0`
- Swift NIO `2.100.0`
- Textual `main` at `ad589638b23e80557aaf2fa959760feac643a1e1`

### Static baseline

From `BisonNotes AI/BisonNotes AI`:

```text
swiftlint lint --reporter summary
Done linting! Found 294 violations, 85 serious in 182 files.
```

This is the existing baseline. It is not a migration regression by itself; future
handoffs must compare changed-file findings and total counts without regenerating
`SwiftLintBaseline.json`.

### Build and test baseline

All Xcode commands used the committed Swift 5 settings, `-disableAutomaticPackageResolution`,
the isolated package checkout path above, and unique `/private/tmp` DerivedData paths.

| Gate | Command/result | Evidence |
|---|---|---|
| iOS local pre-merge gate | Build completed; test execution ran 19 tests but failed 3 baseline tests | `/private/tmp/bisonnotes-swift6-wave0-ios.xcresult` |
| Native macOS Debug build | `** BUILD SUCCEEDED **` | `/private/tmp/bisonnotes-swift6-wave0-macos.xcresult` |
| Watch scheme test/build | `** TEST SUCCEEDED **`; 4 Watch UI tests and the Watch XCTest case executed | `/private/tmp/bisonnotes-swift6-wave0-watch.xcresult` |

The iOS baseline failures were classified as pre-existing source/test behavior, not
package-resolution or migration failures:

- `BisonNotesAIAccessibilityTests.testRecordScreenAccessibilityAudit()` — `Contrast failed`.
- `BisonNotesAIAccessibilityTests.testSetupAccessibilityAudit()` — `Contrast nearly passed`.
- `LocalDiarizationModelManagerTests.testCancellationWaitsForPreparationToTerminateWithoutDeletingCache()`.

The accessibility suite otherwise executed its seeded UI coverage, and the iOS result
included the main model/import/local-diarization test suites. These baseline failures
remain tracked separately from Swift 6 work unless a later owned diagnostic proves a
direct migration dependency.

## Wave 1 staged diagnostic

The lead enabled `SWIFT_STRICT_CONCURRENCY = complete` only for the main iOS app's
Debug and Release configurations while retaining `SWIFT_VERSION = 5.0`. No project-wide
default actor isolation was added.

The lead ran the scheme diagnostic with a unique derived-data path:

```text
xcodebuild build -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" -sdk iphonesimulator -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-strict-ios-derived \
  -clonedSourcePackagesDirPath /private/tmp/bisonnotes-swift6-wave0-packages \
  -disableAutomaticPackageResolution
```

Result: exit 65 before a complete strict-concurrency diagnostic set was emitted. The
only first-party compiler error was the pre-existing cross-platform target failure:
`BisonNotes AI/BisonNotes Watch Widget/BisonNotesComplications.swift:107` reports
`WidgetFamily.accessoryCorner` unavailable in iOS while compiling target
`BisonNotes Watch WidgetExtension`. The same graph also emitted the expected warning
that `TARGETED_DEVICE_FAMILY = 4` has no iOS device family. The complete log is retained
at `/private/tmp/bisonnotes-swift6-strict-ios.log`.

A follow-up target invocation used isolated `OBJROOT`, `SYMROOT`, module-cache, and
precompiled-header paths and excluded only `BisonNotesComplications.swift` through a
command-line diagnostic override. It reached the remaining target graph but stopped on
the pre-existing watch asset error that `BisonNotes AI Watch App/Assets.xcassets` has no
applicable `AppIcon` content for iOS (exit 65). Its complete log is retained at
`/private/tmp/bisonnotes-swift6-strict-ios-target-excluded.log`.

These are classifiable target/platform setup failures, not Swift 6 concurrency fixes;
no first-party `Sendable`, actor-isolation, or data-race diagnostics were observed
before either build stopped. The staged setting remains in place for the next serialized
lead build after package handoffs, and the platform-target errors remain a separate
F-package/target-integration item rather than being “fixed” with a migration suppression.

## Lead integration and Swift 6 gate

Packages A-F were fanned out, reviewed, and integrated on the owner-authorized branch.
The lead then hardened the shared integration points without adding a new unsafe or
preconcurrency escape: main-actor ownership was made explicit for UI/persistence
services, provider/on-device value contracts were made transferable, real-time and
delegate callbacks hand off typed values, and Speech/AV export task groups now await
main-actor-created task handles rather than sending framework objects through child
closures.

The final staged strict-in-Swift-5 focused action was:

```text
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-f-focused-11-derived \
  -clonedSourcePackagesDirPath /private/tmp/bisonnotes-swift6-wave0-packages \
  -disableAutomaticPackageResolution \
  -only-testing:'BisonNotes AITests/Swift6ValueSemanticsTests' \
  -only-testing:'BisonNotes AITests/Swift6ProviderIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6PersistenceIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6AudioConcurrencyTests'
```

It exited 0 with `** TEST SUCCEEDED **`; all 10 synchronized migration tests passed.
The only first-party diagnostic in the complete log was the pinned FluidAudio boundary
at `FluidAudio/LocalDiarizationAdapters.swift:282`: `OfflineDiarizerManager` is a
non-Sendable imported class whose `process` method is nonisolated. The runner actor is
the correct lifetime owner, but Swift 6 rejects sending that SDK object to its method.
The FluidAudio 0.15.5 source itself documents mutable Core ML state with
`nonisolated(unsafe)`. The plan forbids adding a new `@preconcurrency`, unchecked, or
unsafe waiver as a quick fix, so this is an explicit third-party upgrade/API-boundary
blocker rather than a hidden suppression. The remaining linker duplicate `-lc++`
message is a separate existing package-link warning.

The command-line Swift 6 focused action used the same selectors and passed every test
up to compilation, then exited 65 on exactly that one FluidAudio error. The command-line
Swift 6 scheme build also exited 65 before app compilation on the known cross-platform
Watch Widget diagnostic at
`BisonNotes AI/BisonNotes Watch Widget/BisonNotesComplications.swift:107`
(`WidgetFamily.accessoryCorner` is unavailable in iOS). No repository Swift-version
flip was made; the final target migration remains gated on these two classified blockers.

### Historical Swift 6 target reruns before FluidAudio redesign

After the final first-party hardening, the focused strict-in-Swift-5 test action was
rerun with the four synchronized migration selectors. It exited 0 with
`** TEST SUCCEEDED **`; all 10 tests passed. The complete log is
`/private/tmp/bisonnotes-swift6-f-focused-final.log`, with the result bundle under
`/private/tmp/bisonnotes-swift6-f-focused-final-derived/Logs/Test/`.

The same four-selector action was then run in Swift 6 language mode:

```text
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-tests-swift6-final-derived \
  -clonedSourcePackagesDirPath /private/tmp/bisonnotes-swift6-wave0-packages \
  -disableAutomaticPackageResolution \
  -only-testing:'BisonNotes AITests/Swift6ValueSemanticsTests' \
  -only-testing:'BisonNotes AITests/Swift6ProviderIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6PersistenceIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6AudioConcurrencyTests' \
  SWIFT_VERSION=6.0 SWIFT_STRICT_CONCURRENCY=complete
```

It exited 65 before test execution on exactly one compiler error:
`LocalDiarizationAdapters.swift:282:40: sending 'manager' risks causing data races`.
The complete log is `/private/tmp/bisonnotes-swift6-tests-swift6-final.log`.

The native macOS Swift 6 build was also rerun with `SWIFT_VERSION=6.0` and
`SWIFT_STRICT_CONCURRENCY=complete`; it reached the same single FluidAudio error and
had no additional first-party errors. The complete log is
`/private/tmp/bisonnotes-swift6-macos-swift6-4.log`. First-party fixes covered the
`MacSystemAudioCapture` lifecycle actor boundary, Timer callback ownership, the
nonisolated recorder deinitializer, the macOS Share completion hop, and the MLX VM page
size query (`host_page_size` instead of the imported mutable `vm_kernel_page_size`).

The Watch App Swift 6 scheme was run against `Apple Watch Series 11 (46mm)`; its
dependency build was canceled at the same shared FluidAudio error before Watch test
execution. The complete log is `/private/tmp/bisonnotes-swift6-watch-swift6-final.log`.
The earlier WidgetKit diagnostic only occurs in the separate diagnostic invocation
that forces the entire project to use the iOS SDK; the destination-aware focused test
action compiled the Watch WidgetExtension for watchOS before reaching FluidAudio.

The lead then ran the focused Package A test through the test action, which uses the
main app's strict Debug setting without the build-action-only extension failure:

```text
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-package-a-derived-2 \
  -clonedSourcePackagesDirPath /private/tmp/bisonnotes-swift6-wave0-packages \
  -disableAutomaticPackageResolution \
  -only-testing:'BisonNotes AITests/Swift6ValueSemanticsTests'
```

Result: `** TEST SUCCEEDED **`; all four Package A tests passed. The same complete log
contained 346 matching first-party strict-concurrency diagnostic lines (repeated by
Xcode's compilation output), with no matching diagnostics in Package A's changed files.
Representative remaining categories were global mutable/non-Sendable singletons and
model statics (B/C1), provider and on-device state (B), async bridge/data-race warnings
(D), recorder/transcription and audio-session state (E), and platform/UI statics (F).
Third-party MLX C++17-extension warnings remain separate. The focused result bundle is
`/private/tmp/bisonnotes-swift6-package-a-2.xcresult`.

After Packages A, B, C1, and D were integrated, the lead ran the serialized strict
concurrency test action for all synchronized package tests:

```text
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-abcd-derived-3 \
  -clonedSourcePackagesDirPath /private/tmp/bisonnotes-swift6-wave0-packages \
  -disableAutomaticPackageResolution \
  -only-testing:'BisonNotes AITests/Swift6ValueSemanticsTests' \
  -only-testing:'BisonNotes AITests/Swift6ProviderIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6PersistenceIsolationTests'
```

Result: exit 0 and `** TEST SUCCEEDED **`; all nine focused tests passed. The strict
compile emitted 151 matching Swift 6-mode warning lines across 37 first-party files,
but no compiler errors. Remaining warnings are recorded as the not-yet-owned E/F and
lead integration work; the complete log and result bundle are retained at
`/private/tmp/bisonnotes-swift6-abcd-3.log` and
`/private/tmp/bisonnotes-swift6-abcd-3.xcresult`.

Two compile diagnostics found during the serialized integration loop were corrected
at the call sites after reviewing their ownership: `RecordingFile.dateString` is now
main-actor isolated because it reads the main-actor `UserPreferences.shared`, and
`EnhancedErrorHandlingSystem` converts an underlying `Error` to its localized String
before constructing the Sendable `SystemError.unknown` value. No unsafe annotation or
project setting was added for either fix.

Package C2 was then integrated on the lead branch. Its serialized validation used the
same three focused test selectors and produced exit 0 with `** TEST SUCCEEDED **`; all
nine tests passed. The strict compile emitted 118 matching Swift 6-mode warning lines
and no compiler errors. C2 reduced the iCloud/network-monitor diagnostics, but the
eight `SummaryManager` engine-send diagnostics remain an explicit shared A/B/lead
handoff. The complete validation log is
`/private/tmp/bisonnotes-swift6-abcd-c2-escalated.log`.

### Final project-setting reruns

The historical FluidAudio diagnostic above is superseded by a safe ownership
redesign. `OfflineVBxRunner` now creates the non-Sendable `OfflineDiarizerManager`,
prepares its models, and processes audio inside one nonisolated async operation. No
new `@unchecked Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` waiver was
added. `Package.resolved` remains unchanged.

The project language-mode cutover was audited with the project file:

```text
SWIFT_VERSION = 6.0: 24 configurations
SWIFT_VERSION = 5.0: 0 configurations
SWIFT_STRICT_CONCURRENCY = complete: retained in the main iOS Debug/Release configurations
SWIFT_DEFAULT_ACTOR_ISOLATION: not set
```

The four-selector iOS action was rerun using the committed Swift 6 project settings,
without a command-line language-version override:

```text
xcodebuild test -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-swift6-project-ios-final-derived \
  -clonedSourcePackagesDirPath /private/tmp/bisonnotes-swift6-wave0-packages \
  -disableAutomaticPackageResolution \
  -only-testing:'BisonNotes AITests/Swift6ValueSemanticsTests' \
  -only-testing:'BisonNotes AITests/Swift6ProviderIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6PersistenceIsolationTests' \
  -only-testing:'BisonNotes AITests/Swift6AudioConcurrencyTests'
```

Result: exit 0 with `** TEST SUCCEEDED **`; all 10 focused migration tests passed.
The complete log is `/private/tmp/bisonnotes-swift6-project-ios-final-rerun.log`, with the
result bundle under `/private/tmp/bisonnotes-swift6-project-ios-final-rerun.xcresult`.

The native macOS Swift 6 project-setting build also passed with
`** BUILD SUCCEEDED **`. Its complete log is
`/private/tmp/bisonnotes-swift6-project-macos-final-rerun.log`, with the result bundle
under `/private/tmp/bisonnotes-swift6-project-macos-final-rerun.xcresult`.

The Watch App Swift 6 project-setting test was run against `Apple Watch Series 11
(46mm)`. It passed 4 UI tests and the Watch XCTest case with zero failures. The
complete log is `/private/tmp/bisonnotes-swift6-project-watch-final-rerun.log`, with the
result bundle under `/private/tmp/bisonnotes-swift6-project-watch-final-rerun.xcresult`.

Target-specific result bundles report `status: succeeded` and `errorCount: 0` for
the iOS Controls and Share extensions and the native Mac Widget and Share extension:

| Target/build | Evidence |
|---|---|
| `BisonNotes AI ControlsExtension` | `/private/tmp/bisonnotes-swift6-controls-target-final.xcresult` |
| `BisonNotes Share` | `/private/tmp/bisonnotes-swift6-share-ios-target-final.xcresult` |
| `BisonNotes Mac Widget` | `/private/tmp/bisonnotes-swift6-mac-widget-target-final.xcresult` |
| `BisonNotes Share macOS` | `/private/tmp/bisonnotes-swift6-share-mac-target-final.xcresult` |

The direct `BisonNotes Watch WidgetExtension` target build with `-sdk watchsimulator`
exited 0. The separate `BisonNotes AI Watch App (Complication)` scheme is a
multi-platform scheme whose forced watchsimulator invocation pulls the iOS-only
`BisonNotes Share/ShareViewController.swift` dependency and fails on unavailable
watchOS `UIViewController`/`UIResponder` APIs. This is a scheme/target-graph issue,
not a Swift 6 concurrency diagnostic; the supported Watch App scheme and direct Watch
Widget product build pass.

All successful current builds have zero first-party Swift compiler errors. Non-blocking warnings
remain and are classified separately: MLX C++17-extension notices, two deprecated
`OnDeviceLLM` `init(cString:)` calls, native Mac `MacSystemAudioCapture` queue-capture
warnings, AppIntents metadata notices, and the existing duplicate `-lc++` linker
message. The broad iOS test graph also emits actor-isolation warnings from legacy/UI
test call sites; the focused Swift 6 migration action passes 10/10.

## Package handoffs

Each accepted handoff must include the exact structure required by the controlling plan:

```text
Work package:
Owned files actually touched:
Compiler diagnostics addressed:
Isolation/Sendable decision and why it is true:
Behavior intentionally changed:
Call-site and target-membership evidence:
Tests added or updated:
Commands run and exact result:
Unsafe annotations added or retained:
Risks or assumptions:
Unresolved items / requested ownership handoff:
```

| Package | Status | Lead acceptance / evidence |
|---|---|---|
| A — value contracts and global immutability | accepted | Six owned files plus synchronized-group test; `Swift6ValueSemanticsTests` passed 4/4; no unsafe annotations; `WhisperService.swift:196,555,796` handed to E |
| B — UI/provider/global actor ownership | accepted | Provider isolation, UI/global actor ownership, Sendable error/location/value contracts, and synchronized provider tests integrated; strict package test passed 2/2; no unsafe annotations |
| C1 — persistence and file-store isolation | accepted | Main-actor ownership for persistence/file-store state plus migration/round-trip tests integrated; strict package test passed 3/3; no unsafe annotations |
| C2 — iCloud/summary concurrency | accepted with handoff | `NetworkStatus`/`NetworkMonitor` boundary integrated; no CloudKit schema or merge behavior changed; strict focused action passed 9/9; eight checked CloudKit continuations still need cancellation/teardown gates and SummaryManager’s engine boundary remains handed off |
| D — networking/import/export async bridges | accepted | Sendable network/export contracts, cancellation/exactly-once continuation gates, and lock-backed import state integrated; strict package test action compiled and passed with A/B/C1 tests; no unsafe annotations added, existing lock-backed `@unchecked Sendable` retained |
| E — audio/transcription/background real-time boundary | accepted | Audio/session/transcription/background/FluidAudio ownership and callback hardening integrated; `Swift6AudioConcurrencyTests` passed 1/1 inside the 10/10 focused action. No new unsafe annotation; the FluidAudio manager now remains local to one async operation. |
| F — platform UI, Watch, widgets, controls, share | accepted with scheme note | AppDelegate, PlatformApp, SummaryDetail, WatchConnectivity, WatchAudio, ShareExtension, controls, widgets, and Watch boundaries integrated. Supported iOS, macOS, Watch App, Controls, Share, and Mac Widget builds pass; the separate complication scheme retains the documented cross-platform dependency issue. |

## Final target matrix

Populate this table only with a live project-file/effective-settings audit and build/test evidence.

| Target | Debug Swift version | Release Swift version | Strict diagnostics/build/tests | Status |
|---|---:|---:|---|---|
| BisonNotes AI | 6.0 | 6.0 | Project-setting focused action passed 10/10 | green for automated focused scope |
| BisonNotes AITests | 6.0 | 6.0 | Included in project-setting focused action; 10/10 migration tests passed | green for automated focused scope |
| BisonNotes AIUITests | 6.0 | 6.0 | Test runner built by the iOS focused action; Watch UI tests passed separately | green for tested scope |
| BisonNotes AI macOS | 6.0 | 6.0 | Project-setting Debug build passed | green for automated build |
| BisonNotes AI Watch App | 6.0 | 6.0 | Project-setting Watch action passed 4 UI tests and the Watch XCTest case | green |
| BisonNotes AI Watch AppTests | 6.0 | 6.0 | Watch XCTest case passed | green |
| BisonNotes AI Watch AppUITests | 6.0 | 6.0 | 4 Watch UI tests passed | green |
| BisonNotes AI ControlsExtension | 6.0 | 6.0 | Target-specific iOS build succeeded with zero errors | green |
| BisonNotes Share | 6.0 | 6.0 | Target-specific iOS build succeeded with zero errors | green |
| BisonNotes Watch WidgetExtension | 6.0 | 6.0 | Direct target build with `-sdk watchsimulator` exited 0 | green |
| BisonNotes Mac Widget | 6.0 | 6.0 | Target-specific macOS build succeeded with zero errors | green |
| BisonNotes Share macOS | 6.0 | 6.0 | Target-specific macOS build succeeded with zero errors | green |

## Manual and release evidence

These remain separate from automated proof and are not claimed complete by the Wave 0
builds/tests:

- signed release/archive validation;
- physical iPhone/iPad recording, interruption, playback, transcription, and local labels;
- native Mac microphone/system-audio, device switching, salvage, recovery, and window/modal checks;
- Watch recording/transfer on hardware;
- provider-service/network cancellation behavior;
- two-device CloudKit behavior and local-only exclusions;
- iOS/macOS share imports, widgets, Control Center, and Action Button/AppIntent;
- VoiceOver, Voice Control, keyboard access, Dynamic Type, and native Mac accessibility.
