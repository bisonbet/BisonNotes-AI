# Native macOS Extension Parity

## Scope

Phase 3.3 originally audited whether the existing Share extension, widgets, and
App Intents carried over to the native macOS app. Issues #101 and #102 now
implement the two deferred extension gaps. This document records the chosen
scope, architecture, target isolation, automated evidence, and remaining signed
runtime checks.

## Results

| Area | Current native macOS state | Phase 3.3 decision |
| --- | --- | --- |
| Share extension | Implemented by `BisonNotes Share macOS`. Its AppKit controller uses `NSExtensionContext.open`, and both platform extensions use one shared processor for file selection, App Group storage, token creation, and Darwin notification. | Complete implementation for [issue #102](https://github.com/bisonbet/BisonNotes-AI/issues/102); retain signed-runtime Finder and source-app checks below. |
| Widgets | Implemented by `BisonNotes Mac Widget` with small and medium families. Its high-contrast button invokes the existing `StartRecordingIntent`, with an App Group request plus Darwin notification protecting both app-activation orderings. | Complete implementation for [issue #101](https://github.com/bisonbet/BisonNotes-AI/issues/101); retain signed-runtime add/remove/action checks below. |
| Shortcuts / App Intents | Implemented. `StartRecordingIntent` and `AppShortcuts` compile into the native app, and Xcode emits them in the signed app's App Intents metadata. | No implementation follow-up. Retain a signed-app runtime check in the Phase 3 exit QA. |

## Share extension

The platform presentation targets remain intentionally separate:

- `BisonNotes Share` remains iOS-only and keeps its existing UIKit/runtime
  activation fallbacks.
- `BisonNotes Share macOS` uses `NSViewController` and
  `NSExtensionContext.open(_:completionHandler:)`; it has no UIApplication or
  responder-chain workaround.
- `Shared Share Support/ShareExtensionProcessor.swift` is compiled into both
  extensions and the app. It owns the supported file extensions and UTType
  priority, copies payloads to the App Group ShareInbox, writes the UUID token,
  and posts the existing Darwin notification fallback.
- `ShareImportAuthorization` consumes the same contract constants and remains
  the only component that authorizes a pending or URL-triggered import. Neither
  extension duplicates receiving-side token validation.

The Mac target accepts the same audio and document types as iOS:
`m4a`, `mp3`, `wav`, `caf`, `aiff`, `aif`, `txt`, `text`, `md`, `markdown`,
`pdf`, `doc`, and `docx`. If a provider's temporary URL has no extension, the
processor safely derives one from its suggested name or registered UTType
before applying the allowlist.

The native app has explicit dependencies on and an **Embed App Extensions**
phase for the Mac Share and widget products. The iOS app's platform-filtered
embed phase still contains only the existing iOS Share and Control extensions.

## Widgets

The useful first Mac scope is a focused **Start Recording** widget:

- Small and medium system families provide Mac-appropriate layouts.
- The button invokes `StartRecordingIntent`, which writes the existing App
  Group request and opens the app. There is no second recording trigger path.
- macOS can activate the host before `AppIntent.perform()` finishes. The
  request is therefore persisted first and followed by a Darwin notification.
  `ContentView` consumes on launch/activation and when that notification
  arrives, covering both orderings while preserving one-shot consumption.
- The widget uses an explicit dark blue/teal background and a translucent,
  outlined control instead of the system accent-tinted prominent button. Its
  microphone and **Record** text are explicit views in the non-accented render
  group, preserving their contrast when macOS remaps widget colors.
- Recent recordings/status were deliberately excluded from this increment.
  The app does not publish durable, widget-safe recording metadata today, so a
  status view would be stale or require a second state model.
- The existing iOS Control Widget and watchOS complication targets, platform
  settings, source, and embedding remain unchanged.

## Automated evidence

- Xcode enumerates separate `BisonNotes Mac Widget` and
  `BisonNotes Share macOS` targets and schemes.
- The Mac widget Debug target builds and extracts
  `StartRecordingIntent` metadata.
- The Mac Share Debug target builds with application-extension-only API checks.
- The existing iOS Share Debug simulator target builds after adopting the
  shared processor.
- `ShareImportAuthorizationTests` verifies that the shared contract constructs
  an accepted authenticated URL, uses the same token filename, and exposes the
  expected import extension set. It also covers extensionless provider URLs and
  sanitizes suggested names; all eight focused tests pass on iPhone 17 Pro.
- `ActionButtonLaunchManagerTests` verifies that the App Group request is
  persisted before the wake-up notification is posted and that a request is
  consumed exactly once; both focused tests pass on iPhone 17 Pro.
- The full native macOS Debug app build succeeds and validates both embedded
  extension binaries.
- A locally signed native Debug build succeeds with the rebuilt widget
  embedded and validated.
- A signed universal Release archive succeeds after automatic provisioning for
  both new bundle identifiers. The verification archive used
  `STRIP_INSTALLED_PRODUCT=NO` to bypass a local `/tmp` atomic-replacement
  failure in `strip`; this does not change source or signing settings. Xcode
  validates both embedded binaries, and an independent
  `codesign --verify --deep --strict` pass confirms the host app, widget, and
  Share extension satisfy their designated requirements.
- The signed archive contains exactly `BisonNotes Mac Widget.appex` and
  `BisonNotes Share macOS.appex` under `Contents/PlugIns`. The iOS simulator app
  still contains only `BisonNotes Share.appex` and
  `BisonNotes AI ControlsExtension.appex`.
- The app and both Mac extensions carry the same
  `group.bisonnotesai.shared` App Group entitlement. Their signed bundle
  identifiers are the expected host identifier plus `.mac-widget` and
  `.mac-share`.

## Shortcuts and App Intents

The existing implementation is included in the native macOS target:

- `StartRecordingIntent` is discoverable, opens the app, and writes the shared
  recording request through `ActionButtonLaunchManager`, then posts a Darwin
  wake-up notification after persistence.
- `AppShortcuts` publishes four Start Recording phrases.
- `ContentView` consumes the request when the app becomes active and starts the
  shared recorder after initialization.
- The native app carries the required App Group entitlement.

## July 25 runtime feedback

A signed medium widget was successfully added on macOS. The first **Record**
click activated BisonNotes but did not start recording because activation
reached `ContentView` before the widget's intent finished writing its App Group
request. The request remained pending. Launching the rebuilt signed Debug app
consumed it, navigated to Record, and started exactly one recording. The
breadcrumb log recorded `Action button recording requested`, `Triggering
action button recording`, microphone permission granted, and the first input
buffer. This confirms the failed runtime path was the handoff race addressed
above, not a recorder failure.

The same runtime check also confirmed the user's washed-out control came from
the accent-tinted prominent button. The rebuilt widget now supplies explicit
foreground and background contrast rather than relying on the system tint.

The native Debug product contains
`Contents/Resources/Metadata.appintents/extract.actionsdata`. Xcode's extracted
metadata identifies `BisonNotes_AI.StartRecordingIntent`, marks it discoverable
with `openAppWhenRun`, and includes all four phrases. This proves native target
registration and metadata extraction; it does not replace the signed runtime
check below.

## Remaining signed-runtime QA

- In Shortcuts on macOS, find BisonNotes AI's **Start Recording** action.
- Run it while the app is closed and while it is already open.
- Confirm the native app activates, requests microphone permission when needed,
  navigates to Record, and begins exactly one recording.
- Stop and save the recording, then confirm normal transcript processing still
  works.
- Re-add the rebuilt BisonNotes AI widget in macOS Edit Widgets. The medium
  family was discovered and added successfully before the July 25 handoff and
  contrast fixes; re-check the rebuilt small and medium layouts, then remove
  and add once more.
- Click **Record** with the app closed and open. Confirm the same single-start
  behavior as Shortcuts and ensure the widget does not start a second recording.
- From Finder, share one supported audio file and one supported document to
  BisonNotes AI. Confirm the app activates and imports each exactly once.
- Repeat from at least one source app (for example Voice Memos, Pages, or
  TextEdit), then confirm an unsupported file is not offered or imported.
- Re-run one iOS Share extension import and one iOS Control Widget action on a
  signed iPhone build; re-check the watch complication independently.
