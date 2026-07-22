# Native macOS Deferred Parity Audit

## Scope

Phase 3.3 checks whether the existing Share extension, widgets, and App Intents
carry over to the native macOS app. Deferred features do not block the Phase 4
cutover, but each gap needs an explicit owner and acceptance criteria.

## Results

| Area | Current native macOS state | Phase 3.3 decision |
| --- | --- | --- |
| Share extension | Not present. The existing extension imports UIKit, subclasses `UIViewController`, uses `UIApplication` launch paths, and is embedded only for iOS. | Defer a dedicated AppKit/macOS extension to [issue #102](https://github.com/bisonbet/BisonNotes-AI/issues/102). |
| Widgets | Not present. The complication target is watchOS-only, while the Control Widget target explicitly supports only iOS and uses an iOS-only declaration. | Defer a native WidgetKit target to [issue #101](https://github.com/bisonbet/BisonNotes-AI/issues/101). |
| Shortcuts / App Intents | Implemented. `StartRecordingIntent` and `AppShortcuts` compile into the native app, and Xcode emits them in the signed app's App Intents metadata. | No implementation follow-up. Retain a signed-app runtime check in the Phase 3 exit QA. |

## Share extension

The `BisonNotes Share` target is not a cross-platform extension:

- `ShareViewController.swift` imports UIKit and subclasses `UIViewController`.
- Opening the app depends on `UIApplication` runtime and responder-chain calls.
- The extension product is embedded with an iOS platform filter.
- The native `BisonNotes AI macOS` target has no dependency on or embed phase
  for the extension.

The receiving half is already reusable. The native app has the
`group.bisonnotesai.shared` entitlement, authenticated ShareInbox token
consumption, inbox scanning, and Darwin-notification handling. A future Mac
extension should preserve this contract and replace only the extension UI and
app-launch mechanism. File-menu audio, transcript, and link imports cover the
cutover use case until that work is scheduled.

Follow-up: [Port the Share extension to native macOS (#102)](https://github.com/bisonbet/BisonNotes-AI/issues/102).

## Widgets

Neither existing widget target applies to the native Mac app:

- `BisonNotes Watch WidgetExtension` targets watchOS and exposes Watch accessory
  widget families.
- `BisonNotes AI ControlsExtension` targets only iPhone/iPad platforms and its
  source is declared available for iOS 18 or newer.
- The native macOS target embeds neither extension.

A future Mac widget can reuse `StartRecordingIntent` and App Group state. It
should not introduce another recording-control path. Command-N, File-menu
commands, and the Shortcuts action provide native entry points in the meantime.

Follow-up: [Add native macOS WidgetKit support (#101)](https://github.com/bisonbet/BisonNotes-AI/issues/101).

## Shortcuts and App Intents

The existing implementation is included in the native macOS target:

- `StartRecordingIntent` is discoverable, opens the app, and writes the shared
  recording request through `ActionButtonLaunchManager`.
- `AppShortcuts` publishes four Start Recording phrases.
- `ContentView` consumes the request when the app becomes active and starts the
  shared recorder after initialization.
- The native app carries the required App Group entitlement.

The native Debug product contains
`Contents/Resources/Metadata.appintents/extract.actionsdata`. Xcode's extracted
metadata identifies `BisonNotes_AI.StartRecordingIntent`, marks it discoverable
with `openAppWhenRun`, and includes all four phrases. This proves native target
registration and metadata extraction; it does not replace the signed-app check
below.

## Remaining Phase 3 exit QA

- In Shortcuts on macOS, find BisonNotes AI's **Start Recording** action.
- Run it while the app is closed and while it is already open.
- Confirm the native app activates, requests microphone permission when needed,
  navigates to Record, and begins exactly one recording.
- Stop and save the recording, then confirm normal transcript processing still
  works.

