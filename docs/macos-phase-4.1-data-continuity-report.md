# Native macOS Phase 4.1 Data-Continuity Report

**Branch:** `native-macos`

**Date:** 2026-07-19

**Status:** Continuity and settings spot check passed; extended manual QA deferred

## Replacement candidates

| Property | Installed Catalyst app | Native candidate |
| --- | --- | --- |
| Location | `/Applications/BisonNotes AI.app` | `/private/tmp/BisonNotes-Native-Mac-Phase3-final.xcarchive/Products/Applications/BisonNotes AI.app` |
| Platform | `MACCATALYST` | native `MACOS` |
| Version | 2.1 (8) | 2.2 (7) |
| Architecture | arm64 | arm64 |
| Bundle identifier | `Bison-Networking.BisonNotes-AI` | `Bison-Networking.BisonNotes-AI` |
| Team identifier | `4W55VW7UXX` | `4W55VW7UXX` |
| Sandbox | enabled | enabled |
| App Group | `group.bisonnotesai.shared` | `group.bisonnotesai.shared` |
| iCloud containers | `iCloud.Bison-Networking.BisonNotes-AI` | `iCloud.Bison-Networking.BisonNotes-AI` |

Both builds therefore resolve the same sandbox container, App Group container, Core Data model name, Documents directory, and standard `UserDefaults` domain. `PersistenceController` uses the default store URL for `NSPersistentContainer(name: "BisonNotes_AI")`; no platform-specific relocation path is present.

## Populated Catalyst baseline

The Catalyst app was closed before capture. Its existing sandbox is:

`~/Library/Containers/Bison-Networking.BisonNotes-AI`

| Data | Pre-install value |
| --- | ---: |
| Container logical size | 36 GB |
| Documents logical size | 647 MB |
| Document files | 59 |
| Document bytes | 678,638,632 |
| M4A files | 44 |
| MP3 files | 2 |
| Location sidecars | 6 |
| Recording metadata sidecars | 6 |
| Relationship manifests | 1 |
| Recording Core Data rows | 54 |
| Transcript Core Data rows | 31 |
| Summary Core Data rows | 53 |
| Processing-job rows | 0 |
| Archive-location rows | 0 |

Pre-install stable-file hashes:

- Preferences: `d99c9c6482c7661e54be395354b76c49701c3c6fb4ea7ee4d3f29376c7f7e3d0`
- File relationships: `79983f32910eebc1689df9afcd261f05fcc804fd97b11b36cc63036062e4fea0`

The 32 GB cache directory is primarily downloaded/rebuildable AI-model content and was deliberately excluded from the rollback copy.

## Rollback snapshot

An APFS clone-based snapshot was created at:

`/private/tmp/bisonnotes-phase41-backup.QIXwtm`

It contains the original Catalyst app plus Documents, the Core Data store and WAL/SHM files, preferences, summary-location snapshots, and the App Group container. The copied Documents, Core Data, and preferences were compared with their sources immediately after capture and matched byte-for-byte. Snapshot logical size is 678 MB.

## Native replacement result

The installed Catalyst bundle was moved intact to the rollback snapshot, and the native candidate was installed at `/Applications/BisonNotes AI.app`. Post-install inspection confirmed:

- `/Applications/BisonNotes AI.app` is version 2.2 (7), platform `MACOS`.
- The preserved installed app remains version 2.1 (8), platform `MACCATALYST`, at `/private/tmp/bisonnotes-phase41-backup.QIXwtm/BisonNotes AI Installed Catalyst.app`.
- The first native launch ran the executable from `/Applications` and opened the original `BisonNotes_AI.sqlite`, WAL, and SHM files in the existing sandbox.
- Core Data remained at 54 recordings, 31 transcripts, 53 summaries, zero processing jobs, and zero archive locations.
- Documents remained at 59 files and 678,638,632 bytes and matched the rollback snapshot byte-for-byte.
- The relationship manifest hash remained unchanged.
- The preferences plist was rewritten during launch, but all 111 pre-install preference keys remained present with no additions or removals.
- No Core Data, persistent-store, migration, failure, fault, or crash messages appeared in the native launch log.

The native app then quit cleanly. Closed-store counts and Documents still matched the baseline. A second native launch again opened the same persistent store, retained every count and document, and emitted no matching persistence/migration faults.

## Native settings-window follow-up

Manual inspection of the installed native app exposed two presentation defects that did not affect persisted data:

- Settings and nested engine sheets could lose their navigation toolbar dismissal controls, leaving no visible Done button and no Escape-key exit.
- The FluidAudio and Mistral Transcription forms inherited unsuitable iOS form geometry on native macOS, causing excessive blank space, misaligned fields, and clipped values.

The native window routing now supplies a content-level dismissal control with Escape-key support to Settings, Transcription, AI-engine, and nested configuration sheets. FluidAudio and Mistral Transcription use bounded, top-aligned native macOS card layouts while retaining their existing iOS and Catalyst forms.

The corrected Release archive is:

`/private/tmp/BisonNotes-Native-Mac-Phase41-settings-ui.xcarchive`

The installed `/Applications/BisonNotes AI.app` was compared with that archive and matched exactly. It remains version 2.2 (7), platform `MACOS`. The preceding native bundle is retained at `/private/tmp/bisonnotes-phase41-backup.QIXwtm/BisonNotes AI Native Pre-Settings-UI-Fix.app` in addition to the original Catalyst rollback copy.

Verification for the follow-up build:

- Swift source parsing passed for the changed settings views.
- Normal SwiftLint passed with zero violations in 173 files.
- Native macOS, Mac Catalyst, and iOS Simulator Debug builds passed.
- The signed native macOS Release archive passed.
- The Catalyst unit-test host stalled on the first existing Core Data regression test and was stopped without producing a test result. The same suite had passed before the final presentation-only layout refinement.

On 2026-07-19, the user manually checked the corrected installed build and reported that the affected windows looked okay. This is recorded as a Phase 4.1 spot-check pass, not an exhaustive release sign-off. Broader manual validation—including additional recording playback and wider transcript, summary, and settings coverage—was explicitly deferred to a later session. The automated data comparisons found no need for a one-time data relocation.

## Native Settings second-pass polish

Screenshots captured on 2026-07-21 exposed a broader presentation problem than the first follow-up addressed. Opening Settings from Setup still presented a large sheet over the main window, and opening a provider or model panel stacked another sheet on top. SwiftUI `Form` also produced unsuitable native Mac geometry in Acknowledgements and MLX On Device AI: oversized empty title regions, centered or clipped content, controls stretched across the whole window, and advanced settings without useful grouping.

The second pass establishes one macOS settings hierarchy:

- Setup's settings action opens the app's dedicated SwiftUI `Settings` scene.
- Settings, AI Settings, Transcription Settings, Preferences, Background Processing, and provider/model destinations push within one navigation stack on macOS. iOS and Catalyst retain their existing modal presentation behavior.
- True tasks such as migration, cloud review, model download, and onboarding remain modal.
- Acknowledgements and MLX On Device AI use purpose-built, bounded Mac layouts with readable cards, consistent spacing, and scrollable advanced content.
- Remaining settings forms opt into grouped macOS form styling rather than inheriting the iOS sheet geometry.
- Shared settings rows preserve their accessibility button role and activation action.

Verification for this second pass:

- Native macOS, iOS Simulator, and Mac Catalyst Debug builds passed.
- The root native Settings window was launched and inspected live. It opened as a separate, correctly sized window with top-aligned cards and no dimmed or stacked parent sheet.
- The first user walkthrough exposed that the root `navigationDestination` modifiers were attached to the outside of the `NavigationStack`, so SwiftUI ignored Display Preferences, AI Settings, Transcription Settings, and Acknowledgements. Moving the modifiers onto the stack's content resolved the console warnings.
- A rebuilt live UI pass opened Display Preferences, AI Settings, Transcription Settings, Acknowledgements, and the separate Background Processing window successfully. Deeper provider controls still require the continuing panel-by-panel user walkthrough.
- Normal SwiftLint passed with zero violations in 173 files, and the final whitespace check passed.
