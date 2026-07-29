# Native macOS Window Presentation Audit

## Scope

This audit covers every secondary SwiftUI presentation in the main app source as of Phase 3. It was prompted by transcript and summary details inheriting sheet content size, which could create windows taller than the display with inaccessible content.

The inventory contained 60 presentation sites:

- 28 settings, engine-configuration, and onboarding presentations.
- 13 recording, import, archive, player, and deletion presentations.
- 12 summary, attachment, location, and system-integration presentations.
- 5 transcript, speaker, location, and filter presentations.
- 2 background-processing and data-migration presentations.

## Native presentation policy

Document-like content that users may read or work with alongside the main app opens in an independent, movable, resizable macOS window. Each window has an explicit default size and content minimum:

| Content | Window scene | Route value |
| --- | --- | --- |
| Summary detail | `summary-detail` | Recording UUID |
| Transcript viewer/editor | `transcript-detail` | Recording UUID |
| Audio player/recording detail | `recording-detail` | Recording UUID |
| Recordings library | `recordings-library` | Single window |
| Location map/detail | `location-detail` | Encoded `LocationData` |
| Background processing | `background-processing` | Single window |
| Processing job detail | `processing-job-detail` | Job UUID |

True modal work remains attached to its parent window: filters, confirmations, pickers, title/date/note/speaker editors, attachment previews, import forms, archive/combine flows, and engine configuration. Every such presentation now receives a bounded native Mac viewport through `nativeMacModalSizing`; its contained `List`, `Form`, `ScrollView`, map, or PDF view owns scrolling. iPhone full-screen onboarding flows use `platformFullScreenCover`, which presents a bounded sheet on native macOS while retaining the full-screen cover on iOS and Catalyst.

## Entry-point audit

- `TranscriptsView` routes both audio and imported transcript rows to the transcript window.
- `RecordingsListView` routes row activation, the Play button, and post-archive restoration to the recording window.
- Summary rows continue to route to the summary window using an explicit scene ID.
- Location actions in transcript, recording, and summary views route to the location window.
- Background-processing actions in recording, settings, and migration views route to one activity window; job cards route to job-detail windows.
- Settings/configuration, attachment, import, filter, confirmation, and editor presentations remain modal and use bounded sizing.

## Verification

- Swift syntax parsing covers every changed presentation file.
- Native macOS, iOS Simulator, and Mac Catalyst targets must build before commit.
- The iOS unit-test target must pass before commit.
- Signed-app visual QA should open each independent window, move and resize it, confirm scrolling at minimum size, and exercise at least one representative modal from each inventory group.
