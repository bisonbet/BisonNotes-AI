# Live transcription callback crash fix

## Evidence and scope

The v2.3 customer export shows two unclean relaunches within two seconds of
starting live transcription on September 5 (UTC). Its only MetricKit crash stack
is from August 28 and symbolicates to the already-fixed Speech authorization
callback. The September crash stack is unavailable, so attribution of those
later failures to the audio tap remains provisional.

The current live audio tap and Speech result handler are constructed inside a
MainActor service. An iOS Swift 6 compiler probe confirms that the audio-tap
pattern inherits MainActor isolation and emits an executor check. Framework
callbacks need to be constructed outside that isolation.

## Implementation plan

1. Construct audio and recognition callbacks in an explicitly nonisolated factory.
   Capture file/request references directly; pass only transcript text to a
   MainActor update closure.
2. Serialize the complete write/append operation with tap deactivation, so stop
   waits for an accepted buffer before ending the Speech request. The former
   locked Boolean check allowed stop to overtake a buffer after its check.
   `stop()` awaits that wait off the main actor: deactivation blocks on the lock
   the tap holds across `AVAudioFile.write` and the Speech `append`, and holding
   the main thread on the tap thread's disk I/O trades a crash for a hang.
3. Add regression coverage that constructs callbacks from MainActor and invokes
   them on a background queue. Verify audio writes, suppression after stop,
   successful/error Speech results, and deactivation waiting for an accepted
   buffer without hardware or model access.
4. Run focused regression tests, relevant iOS/native macOS builds, lint, and diff
   checks. Record actual results below; automated checks do not prove hardware
   recording behavior.

## Physical-device gate

On a signed iPad build, enable Live Transcription, start/stop repeatedly, verify
partial transcript updates and nonzero playable exported audio, and stop while
audio/results are arriving. Also exercise first-use Speech permission allow/deny.
Obtain the matching September crash report if available to confirm attribution.

## Validation results

Validated September 6, 2026, on branch `v2.5`, based on
`c889c1bc067cc953ae82b61129207c2f921a5d11`:

- The final callback factory's Swift 6 SIL, compiled against the installed iOS
  SDK, marks both framework callbacks nonisolated. Only the transcript-delivery
  task is MainActor isolated; neither framework callback has an executor check.
- iPad Pro 13-inch (M5), iOS 26.5 Simulator: all 500 app unit tests passed,
  zero failures/skips, including four new callback tests, Speech authorization,
  and existing recording-fallback tests. This also builds the iOS app.
  Result: `/private/tmp/bisonnotes-live-callback-all-unit.xcresult`.
- Focused SwiftLint on all three changed Swift files: zero violations.
- Full repository SwiftLint: 2,038 violations, 273 serious; the repository-wide
  lint gate remains non-green. The committed baseline was not changed.
- `git diff --check` passed. All 24 first-party build configurations remain on
  Swift 6; no Swift 5 configurations were found.
- Native macOS Debug build passed with signing disabled. Log:
  `/private/tmp/bisonnotes-live-callback-macos.log`.
- Signed hardware recording, customer iOS 27 reproduction, UI/accessibility,
  and separate Watch runtime tests were not run. The physical-device gate above
  remains required before claiming that the customer's failure is resolved.

Existing authorization behavior and
handling of Speech errors without results were retained. Broader startup/export
recovery behavior and unrelated logging/performance issues are outside this fix.
