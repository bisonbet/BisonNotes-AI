# macOS Native Migration Plan

**Branch:** `native-macos` (off `v2.2`)
**Goal:** Replace the Mac Catalyst build with a native macOS SwiftUI target, without ever breaking the shipping iOS/Catalyst app, then delete Catalyst and collect the maintenance rewards (unpin aws-sdk-swift, delete the hand-built llama Catalyst slice, drop the textual fork patches).

This document is written for an AI agent (or human) to execute incrementally. Every task has a verification step. Work phase by phase, task by task, committing after each green verification loop.

---

## Progress log

- **Phase 0 — DONE** (commits `930bcbf3`, `3fd6cb53`, `c4195e50`). SafariView, document pickers, and the PlatformApp shim landed; iOS + Catalyst green.
- **Phase 1 — DONE** (commit `42a1a6e0`). Native `BisonNotes AI macOS` target + scheme created; iOS-only APIs fenced. **All three targets build green** (macOS native, iOS Simulator, Mac Catalyst). Launch-verified: the native app runs, opens the Core Data store read-write **in the same container the Catalyst app uses** (`~/Library/Containers/Bison-Networking.BisonNotes-AI/`, same bundle ID — validates the Phase 4.1 data-continuity design), and quits cleanly with no crash report (the historical Catalyst quit-crash did not reproduce). Screenshot verification was blocked by the environment's display sandbox; UI was confirmed via process + open-file inspection instead.
- **Phase 2.1 — IMPLEMENTED, RUNTIME QA PENDING** (commit `a9b92463`). Native macOS now uses the shared Mac AVAudioEngine/AVAudioFile microphone path and ScreenCaptureKit system-audio path. The AVAudioSession retry/deactivation fallback remains Catalyst-only. Native macOS, iOS Simulator, and Mac Catalyst builds are green; a signed native build still needs the Phase 2 exit-criteria mic/system-audio hardware pass.
- **Phase 2.2 — IMPLEMENTED, RUNTIME QA PENDING** (commit `5ed60e59`). Native macOS now discovers microphones with `AVCaptureDevice`, maps them to Core Audio device IDs, identifies the system default input, and applies the selected device directly to the recording engine without changing the system-wide default. Live discovery/default-device mapping and all three builds are green; selection plus recording still needs the signed-app hardware pass.
- **Phase 2.3 — IMPLEMENTED, RUNTIME QA PENDING.** Native macOS now monitors Core Audio's device list and default-input properties, coalesces duplicate change events, and rebuilds the recording engine when the active microphone changes. Each input format records to a separate PCM segment, preserved segments are concatenated during final M4A export, system-audio capture pauses during the gap, and a disconnected preferred microphone falls back to the system default. Native macOS, iOS Simulator, and Mac Catalyst builds are green; physical USB/Bluetooth connect-disconnect testing during a signed recording is still required.
- **Phase 2.4 — IMPLEMENTED, RUNTIME QA PENDING.** Native macOS now wraps long-running transcription and summarization work in `ProcessInfo` activities that prevent App Nap while allowing normal idle system sleep. Mac builds no longer run iOS background-task expiration polling, 25-second task refresh loops, silent-audio keep-alive, or `BGTaskScheduler` registration. iOS retains its existing finite background-task and scheduler behavior. Native macOS, iOS Simulator, and Mac Catalyst builds are green; a long hidden-window transcription/summary pass remains pending.
- **Phase 2.5 — IMPLEMENTED, RUNTIME QA PENDING.** The native macOS PlatformServices layer now covers URL opening, app lifecycle notifications, ProcessInfo activities, and AppKit sharing. Summary exports generate real RTF and paginated PDF files through a shared AppKit/Core Text renderer; summary and diagnostic-log exports use `NSSharingServicePicker` with Finder fallback. All `TODO(macos-phase2)` markers are gone and all three targets build green; native RTF/PDF content and the available sharing destinations still need a signed-app visual pass.
- **Phase 2.6 — IMPLEMENTED, RUNTIME QA PENDING.** The remaining MISC conditionals have been audited. Native macOS now persists and resolves security-scoped recording-archive bookmarks, reports battery state as plugged in/full while still respecting Low Power Mode, uses the existing host-memory MLX guard, excludes Action Button guidance, and retains a no-op WatchConnectivity implementation. Native macOS, iOS Simulator, and Mac Catalyst builds plus the iOS unit-test target are green; a signed-app archive export/relaunch/restore pass remains pending.
- **Phase 3.1 — IMPLEMENTED, VISUAL QA PENDING.** Native summary details now open in independent, movable, resizable Mac windows and use a native `List` viewport for reliable scrolling; the on-device model-download sheet retains bounded page presentation. Native Settings exposes meeting/system-audio capture alongside direct microphone selection. The remaining Catalyst list, sheet, and text-selection conditionals were audited and intentionally stay Catalyst-only. The AppKit sharing delegate also uses an explicit pre-concurrency conformance that passes an isolated Swift 6 strict-concurrency compile check. Native macOS, iOS Simulator, and Mac Catalyst builds plus the iOS unit-test target are green; the reported summary-window case needs a signed-app visual retest.
- **Xcode recommended settings — APPLIED.** Project and shared-scheme upgrade metadata now match Xcode 26.6; the native macOS target enables dead-code stripping and app-group registration in Debug and Release. These settings were present for the green three-platform Phase 2.2 build loop.
- **Next: Phase 3.2** — add native Settings and menu commands plus main-window sizing; Phase 2 signed-app exit QA remains open in parallel.

---

## Ground rules (read before every work session)

1. **Never break the iOS or Catalyst build.** Both must build green after every commit until Phase 4 cutover. Run the verification loop (below) before every commit.
2. **One task per commit.** Small, revertable commits. Conventional prefixes: `refactor:` (Phase 0), `feat(macos):` (Phases 1–3), `chore:` (cleanup).
3. **Do not bump aws-sdk-swift past 1.6.113** until Phase 4 cutover. SPM versions are project-wide; the Catalyst archive bug (see CLAUDE.md "Archive-only failures") applies as long as the Catalyst destination exists.
4. **Do not touch `Frameworks/llama.xcframework/ios-arm64-maccatalyst/`** until Phase 4.
5. **`#if targetEnvironment(macCatalyst)` semantics:** on native macOS this is FALSE. Any behavior currently gated to Catalyst that native macOS also needs must be re-fenced as `#if targetEnvironment(macCatalyst) || os(macOS)`. Any iOS-only API usage must be fenced `#if os(iOS)` (which is TRUE on Catalyst — fence Catalyst-excluded iOS code as `#if os(iOS) && !targetEnvironment(macCatalyst)`).
6. **Known Catalyst UI landmines** (do not regress; both remain relevant until cutover):
   - SwiftUI `ScrollView` is broken inside Mac Catalyst sheets — use `Form`/`List`.
   - Multiple `Button`s in one `Form` row need explicit `.buttonStyle(.borderless)` or they share one tap target.

## Verification loop

Run from `BisonNotes AI/` (the directory containing `BisonNotes AI.xcodeproj`). Build output is large — pipe through `tail`/`grep` and check exit codes.

```bash
# 1. iOS Simulator build (primary platform)
xcodebuild -project "BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build 2>&1 | tail -5   # expect: ** BUILD SUCCEEDED **

# 2. Mac Catalyst build (until Phase 4)
xcodebuild -project "BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  build 2>&1 | tail -5   # expect: ** BUILD SUCCEEDED **

# 3. Unit tests (when logic changed, not for pure UI refactors)
xcodebuild -project "BisonNotes AI.xcodeproj" -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test 2>&1 | tail -10

# 4. Native macOS build (Phase 1 onward)
xcodebuild -project "BisonNotes AI.xcodeproj" -scheme "BisonNotes AI macOS" \
  -destination 'platform=macOS,arch=arm64' \
  build 2>&1 | tail -5

# 5. Catalyst archive smoke test (only before release-tagging, it is slow)
./Scripts/archive-catalyst.sh
```

If a build fails: read the first error (`grep -m5 "error:"`), fix, loop. Do not commit with any step red. If a failure resists 3 fix attempts, stop and record the blocker in this file under "Open issues".

---

## Phase 0 — Cross-platform groundwork (no new target yet)

Shrinks the eventual port and benefits iOS/Catalyst immediately. Each task is independently committable and must keep both builds green.

### 0.1 Replace SafariView with cross-platform link opening
- `Views/SafariView.swift` wraps `SFSafariViewController` with Catalyst conditionals. Find all call sites (`grep -rn "SafariView" --include='*.swift'`).
- Replace usage with `Link` or `@Environment(\.openURL)`; delete `SafariView.swift` if nothing else uses it (in-app Safari sheet UX on iOS is acceptable to lose only if call sites are informational links; otherwise keep an `#if os(iOS)` Safari path and an `openURL` fallback — judgment call, prefer deletion for simplicity).
- Verify: loop steps 1–2.

### 0.2 Replace UIDocumentPicker wrappers with fileImporter/fileExporter
- `DocumentPickerCoordinator.swift` (import) and `DocumentExportPicker.swift` (export) wrap `UIDocumentPickerViewController`.
- Find call sites; replace with `.fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:)` and `.fileExporter`. Preserve security-scoped resource access (`startAccessingSecurityScopedResource`) where present today.
- Watch out: `.fileImporter` on Catalyst presents differently but works; test import of an audio file and export of a summary on both platforms if a simulator/Catalyst run is feasible, else rely on builds + unit tests and note it for manual QA.
- Verify: loop steps 1–3.

### 0.3 PlatformServices shim for UIApplication call sites
- Create `Platform/PlatformServices.swift` exposing the small set of capabilities the app actually uses. Inventory first (`grep -rn "UIApplication" --include='*.swift' "BisonNotes AI"`), expected clusters:
  - `open(_ url:)` → route to `@Environment(\.openURL)` in views; `UIApplication.shared.open` in managers (macOS later: `NSWorkspace`)
  - `isIdleTimerDisabled` (recording keep-awake) → macOS later: `ProcessInfo.processInfo.beginActivity`
  - lifecycle notifications (`didEnterBackground`, `willEnterForeground`, `didBecomeActive`) → abstract as `PlatformLifecycle` notification names (macOS later: `NSApplication` equivalents)
  - `beginBackgroundTask`/`endBackgroundTask` → abstract as `PlatformBackgroundAssertion` (macOS later: no-op / `ProcessInfo` activity)
- Mechanical migration: one call-site cluster per commit is fine; do NOT redesign manager logic while shimming.
- Exclude UITests targets from the shim (they legitimately use `UIApplication`/XCUI APIs).
- Verify: loop steps 1–3 after each cluster.

### Phase 0 exit criteria
- `SafariView.swift`, `DocumentPickerCoordinator.swift`, `DocumentExportPicker.swift` deleted or reduced to cross-platform SwiftUI.
- The only files still referencing `UIApplication` are: `Platform/PlatformApp.swift` (the shim), `AppDelegate.swift` + `BisonNotesAIApp.swift` (delegate adaptor — inherently UIKit until Phase 1), `WatchConnectivity/WatchConnectivityManager.swift` (KEEP-iOS), and the four window-scene/share-sheet sites (`LogExporter.swift`, `Views/SettingsView.swift`, `Views/RecordingsListView.swift`, `Views/DataMigrationView.swift`) whose presentation is feature-specific and ports in Phase 2.5 (NSSharingServicePicker on macOS).
- iOS + Catalyst builds green; unit tests pass.

---

## Phase 1 — Stand up the native macOS target

### 1.1 Create target
- Duplicate the `BisonNotes AI` app target as **`BisonNotes AI macOS`** (native macOS SwiftUI app, NOT Catalyst). Same sources, same asset catalog, same Core Data model. Create a matching scheme `BisonNotes AI macOS`.
- **Bundle ID: use the same bundle ID as the Catalyst app** (`PRODUCT_BUNDLE_IDENTIFIER` unchanged) so the native app inherits the container and replaces the Catalyst app on the App Store at cutover. The two targets cannot be installed simultaneously — that is expected; use the Catalyst target for Catalyst testing and the macOS target for native testing.
- Carry over: `EXCLUDED_ARCHS = x86_64` (app is Apple Silicon-only: MLX + arm64-only llama), entitlements (App Groups, mic, speech, screen capture for ScreenCaptureKit), Info.plist usage strings.
- Exclude from the macOS target's compile sources / dependencies: Watch app embedding, `BisonNotes AI ControlsExtension`, `BisonNotes Share` (deferred), `WatchConnectivity/` sources.

### 1.2 Dependency sanity
- llama.xcframework: native macOS resolves to the stock `macos-arm64_x86_64` slice. No action needed; do NOT touch the Catalyst slice.
- MLX-Swift, FluidAudio, textual: expect to build natively. textual takes its upstream AppKit path on native macOS (the Catalyst guards are `!targetEnvironment(macCatalyst)` and don't affect native macOS).
- aws-sdk-swift: stays pinned (rule 3). Confirm a native macOS **archive** succeeds once the target builds (`xcodebuild archive -scheme "BisonNotes AI macOS" -destination 'generic/platform=macOS' ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64`) — this validates the Phase 4 unpin assumption early.

### 1.3 Compile to first launch
- Iterate: build macOS target, take the first batch of errors, fence iOS-only code (`#if os(iOS)`), stub macOS gaps with `// TODO(macos-phase2)` markers, loop.
- Known iOS-only APIs that will need fencing: `AVAudioSession` (audio files — see Phase 2, stub recording as disabled for now), `BGTaskScheduler`, `UIDevice`, `UIImpactFeedbackGenerator`, `WatchConnectivity`, `UIPasteboard` (→ `NSPasteboard`), `CallKit`/call intelligence if present.
- Milestone: app launches on macOS, shows the recordings list backed by Core Data, playback works, recording button present but disabled.

### Phase 1 exit criteria
- `xcodebuild build` green for all three: iOS sim, Catalyst, macOS.
- macOS app launches and reads/writes Core Data.
- `grep -rn "TODO(macos-phase2)" --include='*.swift'` list captured as the Phase 2 worklist.

---

## Phase 2 — Port the platform layer

Work the `TODO(macos-phase2)` list plus the punch list below, in this order:

### 2.1 Recording engine (highest value, mostly done)
- `ViewModels/AudioRecorderViewModel+CatalystEngine.swift` (AVAudioEngine + AVAudioFile mic recording, CAF→M4A export) and `ViewModels/CatalystSystemAudioCapture.swift` (ScreenCaptureKit system audio) are native-API implementations already. Re-fence both from `#if targetEnvironment(macCatalyst)` to `#if targetEnvironment(macCatalyst) || os(macOS)`. Consider renaming `Catalyst*` → `Mac*` (mechanical, keep it a separate commit).
- Remove/fence their `AVAudioSession` touchpoints for macOS (engine input works without a session on macOS).

### 2.2 Audio session & device management
- `EnhancedAudioSessionManager.swift` (14 conditionals): fence all `AVAudioSession` configuration to `#if os(iOS)`. On macOS, input selection = Core Audio default input device + `AVCaptureDevice.DiscoverySession` enumeration for the Settings picker.
- Mic permission: `AVCaptureDevice.requestAccess(for: .audio)` — same TCC flow, works on macOS.

### 2.3 Interruptions and device changes
- `+Interruptions.swift`, `+MicrophoneReconnection.swift`: AVAudioSession route-change/interruption notifications are iOS-only. macOS equivalent: Core Audio property listeners (`kAudioHardwarePropertyDefaultInputDevice`) to detect mic unplug/change; pause-and-recover semantics should match the existing Catalyst behavior.
- **Risk pocket:** Bluetooth mic connect/disconnect mid-recording. Test explicitly (manual QA note).

### 2.4 Background processing
- `BackgroundProcessingManager.swift` + `+Background.swift`: fence `BGTaskScheduler`/`beginBackgroundTask` to `#if os(iOS)`. On macOS, jobs simply continue running; use `ProcessInfo.beginActivity(.userInitiated)` around long jobs to prevent App Nap. This deletes complexity — do not port iOS scheduling ceremony.

### 2.5 PlatformServices macOS implementations
- Fill in the macOS side of the Phase 0.3 shim: `NSWorkspace.shared.open`, `ProcessInfo` activities, `NSApplication` lifecycle notifications.

### 2.6 Remaining punch list
Work through the categorized conditional inventory (appendix below) tagged MISC: `DeviceCapabilities`, `MLXSwiftEngine`, `PerformanceOptimizer` (battery APIs are iOS-only → on macOS report "plugged in"), `RecordingArchiveService`, `WatchConnectivityManager` (stays iOS-only, fenced).

### Phase 2 exit criteria (loop until all pass on macOS)
- Record a mic-only note → transcript → summary end-to-end.
- Record with system audio (ScreenCaptureKit) → verify mixed/parallel files as on Catalyst.
- On-device transcription + LLM summary (llama and/or MLX path) complete.
- Cloud engines (OpenAI/Bedrock/Gemini) reachable (config permitting).
- Quit app during background processing → relaunch → job recovers (matches memory: quit-crash was a Catalyst Phase-2 test item).
- Zero remaining `TODO(macos-phase2)` markers.

---

## Phase 3 — Mac idioms & UI cleanup

### 3.1 Re-audit Catalyst UI workarounds on native macOS
- For every UI-WORKAROUND conditional in the appendix: check whether native macOS needs it. ScrollView-in-sheet and Form-button bugs are Catalyst-renderer bugs; native macOS likely renders correctly. Keep Catalyst behavior unchanged; add `os(macOS)` branches only where native misbehaves.
- Implemented: native summary buttons open a value-backed `WindowGroup` with default/minimum dimensions, and `SummaryDetailView` uses a `List` on macOS for an explicit scrolling viewport. The model-download sheet keeps native page presentation. Catalyst-only list/Form workarounds remain isolated, and native Settings combines direct microphone selection with system-audio capture controls.
### 3.2 Mac app conventions
- `Settings` scene (⌘,) wrapping the existing settings views; menu-bar `Commands` (New Recording ⌘N, Import…, Export…); `defaultSize` + `minWidth/minHeight` on the main `WindowGroup`; standard Edit-menu behaviors in text views.
### 3.3 Deferred items (create follow-up issues, do not block cutover)
- macOS Share extension port; macOS widgets; Shortcuts/App Intents parity check (App Intents work on macOS — verify `StartRecordingIntent`).

### Phase 3 exit criteria
- Full manual pass of `docs/testing-regimen.md` on native macOS.
- App feels Mac-native: settings window, menu commands, resizable window, keyboard shortcuts.

---

## Phase 4 — Parity testing, data continuity, cutover

### 4.1 Data continuity (must not go wrong)
- On a Mac with the Catalyst app installed and populated: install the native build (same bundle ID) over it. Verify recordings, transcripts, summaries, and settings all present. The container (`~/Library/Containers/<bundle-id>` / App Group) must match; if paths differ, extend `DataMigrationManager` with a one-time relocation and re-test.
### 4.2 Beta
- TestFlight for Mac side-by-side soak; run the Phase-2 checklist from memory (recording, external mic swap, AI inference, long-session scrolling, quit-while-processing).
### 4.3 Cutover & rewards (single PR, in this order)
1. Remove Mac Catalyst from the iOS target's supported destinations.
2. Delete `Frameworks/llama.xcframework/ios-arm64-maccatalyst/` and its `Info.plist` entry.
3. Delete `Scripts/archive-catalyst.sh`.
4. Unpin aws-sdk-swift (verify smithy plugin issue irrelevant for iOS + native macOS archives; bump and archive both).
5. Simplify `textual` fork (drop Catalyst guards at next rebase — separate repo task).
6. Purge now-dead `targetEnvironment(macCatalyst)` branches.
7. Rewrite CLAUDE.md Catalyst sections; update memory files.
- Verify: iOS archive + macOS archive + full test suite green.

---

## Open issues

(record blockers here as they arise)

---

## Appendix: Catalyst-conditional punch list (as of branch creation, 74 sites)

Legend: **AUDIO** = port in Phase 2.1–2.3 · **BACKGROUND** = Phase 2.4 · **UI** = re-audit in Phase 3.1 · **MISC** = Phase 2.6 · **KEEP-iOS** = stays fenced iOS-only

| File | Lines | Category |
|---|---|---|
| EnhancedAudioSessionManager.swift | 138, 156, 210, 231, 256, 274, 290, 299, 312, 323, 342, 373, 387, 499 | AUDIO |
| ViewModels/AudioRecorderViewModel.swift | 14, 89, 114, 200, 214, 263, 430, 458, 493, 539, 593, 605, 683, 702, 748, 780, 903 | AUDIO |
| ViewModels/AudioRecorderViewModel+CatalystEngine.swift | 11 | AUDIO (re-fence for macOS) |
| ViewModels/CatalystSystemAudioCapture.swift | 9 | AUDIO (re-fence for macOS) |
| ViewModels/AudioRecorderViewModel+Interruptions.swift | 59 | AUDIO |
| ViewModels/AudioRecorderViewModel+CallIntelligence.swift | 11 | KEEP-iOS (call detection) |
| ViewModels/AudioRecorderViewModel+Background.swift | 16, 32, 45 | BACKGROUND |
| BackgroundProcessingManager.swift | 2183, 2217, 2237, 2298 | BACKGROUND |
| BisonNotesAIApp.swift | 535, 977 | BACKGROUND |
| PerformanceOptimizer.swift | 17 | MISC (battery APIs) |
| DeviceCapabilities.swift | 43 | MISC |
| MLXSwiftEngine.swift | 586 | MISC |
| Models/RecordingArchiveService.swift | 393, 492 | MISC |
| WatchConnectivity/WatchConnectivityManager.swift | 9, 15, 506 | KEEP-iOS |
| Views/SettingsView.swift | 11, 271, 636, 683, 1192, 1210, 1220 | UI |
| Views/SimpleSettingsView.swift | 10, 163, 170 | UI |
| Views/RecordingsView.swift | 9, 333, 340 | UI |
| SummariesView.swift | 337, 418 | UI |
| Views/MistralOnboardingView.swift | 66, 72 | UI |
| Views/TranscriptViews.swift | 306 | UI |
| Views/AITextView.swift | 80 | UI |
| Views/SafariView.swift | 9, 13 | UI (deleted in Phase 0.1) |
| Views/OnDeviceAIDownloadView.swift | 42 | UI |

Line numbers drift as the branch evolves; re-run
`grep -rn "targetEnvironment(macCatalyst)" --include='*.swift' "BisonNotes AI/BisonNotes AI"`
to refresh before starting each phase.
