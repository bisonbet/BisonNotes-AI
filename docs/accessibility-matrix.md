# BisonNotes Accessibility Matrix

This matrix tracks common tasks against the app surfaces that must remain usable with VoiceOver and Voice Control where the platform supports them. It is evidence for App Store accessibility labels and release validation, not a legal certification.

## Task Matrix

| Common task | iPhone and iPad | Mac Catalyst | Apple Watch | Control Center and Action Button | Evidence target |
| --- | --- | --- | --- | --- | --- |
| First setup | Setup screen exposes processing method, save/configure, advanced settings, and help as labeled controls. | Same setup screen is reachable in the sidebar and supports keyboard navigation. | Not applicable. | Not applicable. | Automated setup audit plus manual VoiceOver and Full Keyboard Access pass. |
| Start recording | Record tab has a labeled Start Recording button with ready/starting state. | Record view uses the same labeled control and supports microphone-only or meeting-audio settings. | Main circular button announces ready/unavailable state and starts recording. | Shortcut launches app and starts recording on supported hardware. | Record audit, manual microphone test, hardware Action Button smoke test. |
| Pause, resume, stop recording | Timer, pause/resume, stop, recording status, warnings, and live transcript expose text labels and state. | Same controls are available when Catalyst recording is active. | Mute button pauses/resumes capture; main button stops and saves. | Action Button/Control Center start path does not replace in-app stop controls. | Record audit and manual VoiceOver recording session. |
| Import audio or transcripts | Import Audio Files, Import From Link, and Import Transcripts are labeled actionable controls. | Same controls are reachable from the Record view and app menu paths. | Not applicable. | Not applicable. | Record audit plus manual Files/share import smoke test. |
| Browse recordings | Recording rows expose title, date, duration, file size, archive/local audio, iCloud, transcript, summary, and location status. | Same list is usable with keyboard and VoiceOver. | Transferred watch recordings appear once on iPhone. | Not applicable. | Recordings list audit and manual large Dynamic Type list pass. |
| Play, seek, export audio | Audio player labels export, play/pause, skip buttons, Keep on This Device, and the scrubber. Scrubber is adjustable in 15-second increments. | Same player supports keyboard focus and VoiceOver. | Not applicable. | Not applicable. | Audio Player audit and manual adjustable scrubber test. |
| Generate and edit transcripts | Transcript rows label source, recording, date, word count, and summary state. Detail/editor screens expose segment context and save/rerun controls. | Catalyst renders transcript lists inline with the same identifiers. | Not applicable. | Not applicable. | Transcripts audit and manual transcript edit/save test. |
| Generate, view, export summaries | Summary rows label recording, date, task count, reminder count, and generation state. Detail screen labels export, sections, tasks, reminders, titles, attachments, date/location editors, regenerate, and delete. | Same summary surfaces support keyboard and VoiceOver. | Not applicable. | Not applicable. | Summaries and Summary detail audits plus manual export smoke test. |
| Manage iCloud/local-only state | Keep on This Device controls expose on/off state; Settings iCloud toggles include explicit values and privacy notice. | Same settings are available in Catalyst. | Watch transfers local recordings to iPhone; iCloud state is managed on iPhone/iPad/Mac. | Not applicable. | Settings audit plus manual two-device iCloud/local-only test. |
| Use watch recording | Not applicable except receiving transfer. | Not applicable. | Main button, mute button, transfer progress, low-battery chip, and error overlay expose state and hints; pulsing motion respects Reduce Motion. | Not applicable. | Manual Apple Watch VoiceOver and Reduce Motion validation. |
| Use Control Center / Action Button | Setup includes Action Button instructions on supported iPhone models. | Not applicable. | Not applicable. | Start Recording shortcut should launch app and start capture. | Manual real-device Control Center and Action Button smoke tests. |

## Label Evidence Summary

- VoiceOver: Supported for setup, record, recordings, audio player, transcripts, summaries, settings, and watch recording. Validate with the automated audits plus the manual device checks in `docs/testing-regimen.md`.
- Voice Control: Supported for common iPhone/iPad tasks through visible labels and unique contextual action names. Validate import, playback, transcript, summary, and settings flows manually.
- Dynamic Type: Supported by SwiftUI system fonts and wrapping controls. Validate through largest accessibility sizes because several card/list layouts are dense.
- Increase Contrast, Reduce Transparency, Bold Text, Differentiate Without Color, and Grayscale: Expected to work through system colors and explicit text/status labels. Validate manually before release.
- Reduce Motion: Recording indicators on phone and watch should avoid required motion when Reduce Motion is enabled.
- Captions and Audio Descriptions: Do not claim for v1. BisonNotes produces transcripts, but it does not provide time-synchronized captions for all audio/video playback or audio descriptions.
