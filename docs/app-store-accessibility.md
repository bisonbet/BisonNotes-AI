# App Store Accessibility Artifact

Use this file with `docs/accessibility-matrix.md` when preparing App Store Connect accessibility nutrition labels and release notes.

## Public Accessibility URL

Publish `docs/accessibility.html` at:

`https://www.bisonnetworking.com/bisonnotes-ai/accessibility/`

The page describes supported accessibility features, known limitations, and the support contact path.

## Accessibility Nutrition Labels

### iPhone and iPad

| Feature | Label stance | Evidence |
| --- | --- | --- |
| VoiceOver | Supported | Automated audits for Record, Recordings list, Audio Player, Transcripts, Summaries, Summary detail, Setup, and Settings; manual device pass required. |
| Voice Control | Supported | Buttons and rows use visible labels or contextual accessibility labels. Manual task completion required. |
| Larger Text | Supported | Uses SwiftUI system text and wrapping. Manual largest Dynamic Type pass required. |
| Sufficient Contrast | Supported | Uses system colors and non-color status text. Manual light/dark and Increase Contrast pass required. |
| Reduced Motion | Supported | Phone and watch recording indicators respect Reduce Motion. Manual pass required. |
| Captions | Do not claim | Transcripts are available, but playback does not provide synchronized caption tracks for all media. |
| Audio Descriptions | Do not claim | App does not provide audio-description tracks. |

### Mac Catalyst

| Feature | Label stance | Evidence |
| --- | --- | --- |
| VoiceOver | Supported | Same labeled SwiftUI surfaces as iPad, plus manual Catalyst pass. |
| Keyboard Navigation | Supported | Navigation rows and controls are standard SwiftUI buttons/toggles. Full Keyboard Access manual pass required. |
| Larger Text and Contrast | Supported | Same system text/color strategy as iPad. Manual pass required. |
| Captions and Audio Descriptions | Do not claim | Same limitation as iPhone/iPad. |

### Apple Watch

| Feature | Label stance | Evidence |
| --- | --- | --- |
| VoiceOver | Supported | Main recording button, mute, transfer progress, low-battery chip, and error overlay expose labels, values, and hints. Manual watch pass required. |
| Reduced Motion | Supported | Pulsing recording rings are suppressed when Reduce Motion is enabled. |
| Larger Text and Contrast | Supported with watchOS system text/colors | Manual watch pass required. |
| Captions and Audio Descriptions | Not applicable | Watch app records and transfers audio; it does not play media with captions or descriptions. |

## Known Limitations

- Transcripts are not the same as synchronized captions. Do not claim Captions until BisonNotes ships time-synchronized caption playback support.
- Audio Descriptions are not supported.
- Full confidence requires real-device checks for microphone capture, Apple Watch recording/transfer, iCloud sync, Control Center, and Action Button because simulator audits cannot validate hardware integrations.
- Voice Control labels are designed for common task completion, but cloud-provider sign-in pages or external system sheets may have separate accessibility behavior outside BisonNotes.

## Support Contact

Accessibility feedback should go through the support path linked from the public BisonNotes page:

`https://www.bisonnetworking.com/bisonnotes-ai/`

Include device model, OS version, assistive technology used, the BisonNotes app version, and the task that failed.
