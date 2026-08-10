# Issue #106 A/V Synchronization Test Regimen

This regimen validates native macOS meeting recordings where ScreenCaptureKit system audio and the AVAudioEngine microphone start at different times.

It covers the proposed startup gate, the 1–2 second safety fallback, microphone recovery, pause/resume, finalization, and microphone-only/system-only salvage. Simulator-only testing is insufficient for this issue.

## Release gate

Do not mark issue #106 complete until all of the following are true:

- The deterministic startup-gate and timestamp tests pass.
- The native macOS target builds and the macOS XCTest bundle runs on an Apple-silicon Mac.
- The normal-start, delayed-mic, no-mic, pause/resume, recovery, permission, and finalization cases pass.
- A repeatable marker fixture measures the mixed-track offset within the agreed threshold. The working threshold is one 4096-frame microphone buffer at 48 kHz (about 85 ms), unless a stricter product threshold is chosen before sign-off.
- The evidence record contains first-buffer logs, gate-release/timeout logs, frame counts, finalization-plan logs, output duration, raw-track timing, and playback confirmation.

## Test prerequisites

Use an Apple-silicon Mac running the supported native macOS build, a signed build for permission/TCC cases, and a debug build with recording diagnostics enabled.

The system-audio source must come from another application because BisonNotes excludes its own process audio. QuickTime Player, Music, or a browser playing a local fixture are suitable.

For objective timing measurement, use one of these fixtures:

1. Preferred: feed the same impulse/click sequence to the selected microphone input and to the Mac system-audio path through an audio interface or other controlled splitter.
2. Acceptable manual fallback: play a system click track and create matching microphone claps or spoken markers at known points.

Retain the microphone CAF segments and the system-audio M4A in a debug-only test location before successful finalization removes them. The final mixed file alone is useful for listening but is not sufficient for precise offset measurement.

Before each run, record:

- Mac model, macOS version, app build, and git SHA;
- selected microphone and sample rate/channel format;
- whether Screen & System Audio Recording permission was already granted;
- fixture name and expected marker times;
- test identifier and run number.

## Automated validation

### Repository and build checks

Run from the repository root:

```bash
git diff --check
swiftlint lint --reporter summary

swiftc -parse "BisonNotes AI/BisonNotes AI/ViewModels/AudioRecorderViewModel+MacEngine.swift"
swiftc -parse "BisonNotes AI/BisonNotes AI/ViewModels/MacSystemAudioCapture.swift"
swiftc -parse "BisonNotes AI/BisonNotes AI/ViewModels/AudioRecorderViewModel+MacCaptureHealth.swift"
swiftc -parse "BisonNotes AI/BisonNotes AI/ViewModels/AudioRecorderViewModel+MacFinalization.swift"

xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-test-derived

xcodebuild \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI macOS" \
  -destination 'platform=macOS' \
  -configuration Debug \
  -derivedDataPath /private/tmp/bisonnotes-native-mac-derived \
  build
```

The native macOS scheme currently has no testables. Add a native macOS XCTest bundle/test plan and run it with the macOS destination; a successful macOS app build by itself does not prove that the `#if os(macOS)` capture code was tested.

### Deterministic startup-gate tests

Use a virtual clock and a fake system-capture gate rather than real sleeps. Cover:

- capture starts paused before the first ScreenCaptureKit sample can be accepted;
- the first successful microphone write releases the gate exactly once;
- a microphone write before the timeout cancels the fallback;
- no microphone write releases the gate at the configured timeout;
- a first write racing the timeout has one deterministic winner and never double-releases;
- stopping or aborting cancels the fallback permanently;
- a stale fallback cannot affect a later recording session;
- the initial paused interval is not subtracted twice;
- the first post-release system sample is accepted immediately and later timestamps are monotonic;
- ordinary pause/resume after the initial gate still applies pause-duration compensation;
- startup health recovery does not lose the system capture or create a second gate.

### Audio-asset checks

For retained raw assets and the final output, assert:

- both expected tracks exist when both sources were audible;
- the first marker delta is within the configured threshold;
- no marker sequence is duplicated or missing;
- the final duration is at least the expected microphone duration, within normal encoder tolerance;
- the final asset has a usable audio track;
- microphone-only and system-only fallback paths remain valid.

## Native macOS manual matrix

Run every case at least three times with the built-in microphone and once with an external USB/Bluetooth input when available. Repeat the critical timing cases after restarting the app.

| ID | Scenario | Procedure | Pass condition |
| --- | --- | --- | --- |
| A1 | Normal startup | Start system marker playback, start a meeting recording, then speak/emit matching mic markers. | The gate releases on the first mic write; raw marker delta and audible mixed result are aligned. |
| A2 | Fast first buffer | Repeat A1 with the mic already active and with system audio already playing. | No leading system-audio offset and no lost first marker after release. |
| A3 | Delayed first buffer before timeout | Stall startup briefly, then restore mic input before the fallback. | The first mic write releases capture; the fallback does not later change the recording. |
| A4 | Delayed first buffer after timeout | Hold the mic silent/stalled beyond the configured timeout, then restore it. | System audio remains captured; the later mic write does not create a duplicate release or unexplained gap. Record the expected degraded offset if fallback occurred. |
| A5 | Mic never produces a buffer | Use a present but silent/stalled input and allow automatic recovery to exhaust. | The system track is not silently discarded; it is saved through the supported system-only/recovery path, and no late task touches a new recording. |
| A6 | System audio starts late | Start recording with no system sound, then play the marker fixture after the mic is active. | Mic recording remains valid and later system audio is captured without shifting the mic timeline. |
| A7 | System permission denied/revoked | Test first grant, already-granted, revoked, and quit/reopen flows on a signed build. | Permission failure produces a clear microphone-only recording; no hang or fake system track. |
| A8 | Manual pause/resume | Start both sources, pause for 3–5 seconds while markers continue, resume, and stop. | Paused system samples are handled consistently; no duplicate markers or post-resume synchronization jump. |
| A9 | Microphone hot-swap | Unplug the active mic during a meeting recording, then reconnect or select another input. | Recovery segments are retained, system capture behavior is intentional, and final output has no unexpected gap beyond the device transition. |
| A10 | Stop boundary | Stop before the first mic buffer, during the timeout window, immediately after the first mic buffer, and during finalization. | No crash, leaked capture, empty false-success file, stale timeout, or data loss. |
| A11 | Capture/writer failure | Force or simulate ScreenCaptureKit/writer failure while the mic continues. | Mic-only salvage succeeds and the user receives an actionable status. |
| A12 | Mic failure | Make the mic track unusable while system audio remains audible. | System-only salvage or recovery succeeds; the system file is not deleted as an incidental cleanup. |
| A13 | Silent system audio | Record with meeting capture enabled but no sustained remote audio. | Mic-only finalization is selected; no invalid or misleading system track is retained. |
| A14 | Repeated recordings | Run ten short recordings, including stop/start near the timeout and same-second starts. | Each recording has the correct source tracks, duration, and output URL; no prior finalizer or timeout mutates the next session. |

## Evidence to collect

For each case, save a short record with this shape:

```text
Test ID:
Run:
Mac / macOS:
App build / git SHA:
Microphone:
System-audio source:
Permission state:
Fixture:
Expected marker times:
First mic buffer log/time:
Gate release or timeout log/time:
Raw microphone first marker:
Raw system first marker:
Measured delta:
Mic/system frame counts at stop:
Finalization plan:
Final duration / file size:
Playback result:
Result: PASS / FAIL
Notes / log excerpts:
```

The normal Mac recording logs should include the first-buffer line, stop frame counts, finalization plan, and final duration. The implementation should also log whether the system gate was released by the microphone or by the safety timeout.

## Failure triage

- If the first marker is wrong but both raw tracks are correct, inspect the composition insertion/timestamp path.
- If the system track is silent or missing, inspect gate ordering, timeout cancellation, writer state, and cleanup after `stop()`.
- If only recovery cases fail, inspect session identity, stale timeout tasks, segment ordering, and `macAwaitingRecoveryBuffer` handling.
- If only permission cases fail, repeat with a signed app and verify quit/reopen behavior before changing capture logic.
- If automated tests pass but A1–A5 fail, do not close the issue; the remaining defect is runtime/device-specific.

## Completion record

Attach the completed evidence table and raw-track timing results to the issue or pull request. The final sign-off must identify the Mac, app build, permission state, microphone, fixture, measured maximum offset, and the exact cases run.
