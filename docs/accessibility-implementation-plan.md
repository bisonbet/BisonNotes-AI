# BisonNotes Accessibility Implementation Plan

## Summary

Make BisonNotes accessible across iPhone/iPad, Mac Catalyst, Apple Watch, and Control Center/Action Button flows, using Apple's current guidance as the baseline:

- [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [VoiceOver](https://developer.apple.com/design/human-interface-guidelines/voiceover)
- [Dynamic Type](https://developer.apple.com/design/human-interface-guidelines/typography#Supporting-Dynamic-Type)
- [Accessibility audits](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Accessibility Nutrition Labels](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels)

Target App Store label readiness for common tasks, not just "no missing labels." Do not claim Captions or Audio Descriptions in v1 unless BisonNotes adds time-synchronized captions/audio-description support beyond transcripts.

## Key Changes

- Add `docs/accessibility-matrix.md` with common tasks by device: first setup, start/stop recording, import audio/transcripts, browse recordings, play/seek/export audio, generate/edit transcripts, generate/view/export summaries, manage iCloud/local-only state, use watch recording, and use Control Center/Action Button.
- Add an internal `AccessibilitySupport.swift` helper layer for shared duration/status strings, contextual row labels, announcement helpers, and reusable modifiers for custom cards/buttons.
- Expand `BisonNotesAccessibilityID` only where needed for audit navigation: audio scrubber, transcript list/detail, summary list/detail, settings sections, and first-launch setup.
- Update App Store release artifacts: create an accessibility URL/page describing supported features, known limitations, and contact path; use the matrix to fill Accessibility Nutrition Labels per device.

## Implementation

- Recording and playback: make recording timer/status, pause/resume/stop, live transcript, import actions, playback controls, and `AudioScrubber` fully operable by VoiceOver and Voice Control. Keep the custom scrubber visual, but expose it as an adjustable control with current/remaining time and 15-second increment/decrement actions.
- Lists and cards: give recording, transcript, and summary rows concise contextual labels/values; include file, archive, iCloud, transcript, summary, and location status without relying on color. Make destructive and repeated actions include the recording/import name.
- Details and dialogs: ensure summaries, tasks, reminders, titles, attachments, maps, delete/archive confirmations, and date/location editors have logical headings, focus order, button traits, selected values, and non-color state cues.
- Settings/setup: label modern navigation rows as single actionable controls, add values/hints to toggles and status pills, make progress overlays modal to assistive tech, and keep text wrapping at large sizes.
- Watch and motion: add state values/hints to the main watch recording button, mute button, transfer progress, low-battery chip, and error overlay. Respect Reduce Motion for pulsing rings and recording indicators on both watch and phone.
- Visual accessibility: verify Dynamic Type through largest accessibility sizes, light/dark mode, Increase Contrast, Reduce Transparency, Bold Text, Grayscale, and Differentiate Without Color. Prefer system colors where possible and meet WCAG AA contrast targets Apple cites.

## Test Plan

- Add `BisonNotesAIAccessibilityTests.swift` using existing deterministic launch args and `XCUIApplication.performAccessibilityAudit` for Record, Recordings list, Audio Player, Transcripts, Summaries, Summary detail, Setup, and Settings.
- Add manual validation to `docs/testing-regimen.md`: VoiceOver, Voice Control, Switch Control sampling, Full Keyboard Access on Catalyst/iPad keyboard, largest Dynamic Type, contrast modes, Reduce Motion, Apple Watch VoiceOver, and real-device Action Button/Control Center smoke tests.
- Acceptance: automated audits pass or have documented justified exceptions; every matrix common task can be completed with VoiceOver and Voice Control where the platform supports it; no unreadable overlap/truncation at max Dynamic Type; App Store labels match the evidence.

## Assumptions

- This is an Apple accessibility/App Store readiness plan, not a legal certification.
- Keep existing BisonNotes UI structure and visual style unless accessibility testing proves a layout must change.
- Current dirty worktree changes are unrelated web-import work and should be preserved during implementation.
- Full verification requires macOS/Xcode and real-device checks; Linux-only agents can lint and inspect but cannot run the complete accessibility gate.
