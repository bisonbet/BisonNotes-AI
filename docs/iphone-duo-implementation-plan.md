# iPhone Duo: first-class layout plan

Status: **plan, nothing implemented**. Prepared 2026-11-01 on branch `iphone-duo-implementation`, cut from `v3.0` at `8dfca3b`.

Source paths below are relative to `BisonNotes AI/BisonNotes AI/` unless they start with `docs/`.

## 1. What Apple asks for

Apple's guidance is consistent across the HIG page and the five tech talks (sources in section 9). Condensed to what matters for this app:

- **It is still an iPhone.** Two size classes cover every pose: outer display = compact width (portrait is regular height, landscape is compact height); inner display = regular × regular. Don't design per pose, don't branch on idiom or interface orientation, and don't use fixed widths or screen metrics. Use size classes, layout margins and safe areas.
- **One experience across both displays.** People open and close the device constantly. Keep state, functionality and hierarchy the same on both displays. The inner display can show *one more level* of hierarchy. Mail shows list *or* message when closed, and list *and* message when open.
- **Bars move to the side.** On the outer display, and on the inner display in landscape, toolbars, tab bars, navigation buttons, the status bar and the Dynamic Island stack vertically on the trailing edge. You only get this from system bars hosted by `NavigationStack` / `NavigationSplitView` / `TabView`. Bars you build yourself inside the content stay horizontal and eat vertical space.
  - Items need **both a title and a symbol**. Text-only items stay horizontal.
  - Order from top to bottom: Back/Close (`cancellationAction`), then the prominent action (`topBarPinnedTrailing`), then the remaining groups.
  - Overflow goes into the system menu (`ToolbarOverflowMenu`). Reserve the ellipsis symbol for that menu. `visibilityPriority` decides what overflows first.
  - In a split view, only the detail column's bar goes vertical. List-column controls stay horizontal above their list ("controls near the content they affect").
- **The fold is a reserved region.** When the device is partly folded, interactive elements must stay out of the centre crease. System containers (split views, sheets, alerts, menus) move out of it on their own. A custom centred layout does not. Apple says to audit centred layouts in particular. The tools for this:
  - `ArrangementView` (split or overlay) for "primary + secondary" content.
  - `GeometryProxy.reservedRegions(kind:)` for hand-placed controls.
  - Scrolling content does not need to avoid the fold.
- **Seated (laptop) pose.** Content you watch from a distance goes in the top half. Controls you touch go in the bottom half, which is the stable surface. Keep the same controls in every pose.
- **Expect resizing everywhere.** The app can be shown in a Split View on either half of the inner display, and safe areas are asymmetric there. A pinned Picture in Picture video shrinks the app vertically. The outer display honours supported orientations, and Apple recommends landscape because of the tent pose. The inner display ignores supported orientations.
- **Housekeeping.** Build with Xcode 27.1+ / iOS 27.1 SDK. Without it the app doesn't extend under the status bar or camera, and gets no vertical bars. Replace `UIScreen.main` with the trait, environment or scene screen; it becomes ambiguous on two displays and will be deprecated. Test in Device Hub in every pose, and in Split View on both sides. Run Xcode's **App Resizability** skill.

Apple's own demo for the adaptive-layout talk is an **audio note app with a player and a secondary list**. That is almost exactly our player screen.

## 2. Where BisonNotes stands today

These findings come from reading the current `v3.0` code, not from running it on the device. Running it is milestone 0.

| # | Finding | Location | Duo impact |
|---|---|---|---|
| F1 | The root picks between two different view trees by size class. Compact gets `TabView` with `selectedTab: Int`. Regular gets `AdaptiveNavigationView`'s `NavigationSplitView` with its own `selectedItem`. | `ContentView.swift:163`, `Views/AdaptiveNavigationView.swift:68` | **Highest risk.** Every open or close crosses this boundary, so the whole tree is torn down. The selected section resets, navigation and scroll are lost, and `@StateObject`s inside `RecordingsView` are rebuilt. That loses in-flight import alerts and dismisses open sheets such as the recordings library or web import. This directly contradicts "keep state the same between displays". |
| F2 | `.preferredColorScheme(horizontalSizeClass == .compact ? .dark : nil)` | `ContentView.swift:58` | Opening the device switches the whole app from dark to the system appearance, and closing it switches back. The same flip already happens on iPad when the app enters a narrow Split View. |
| F3 | Detail opens as a **modal sheet** from Summaries, Transcripts and the Recordings library, even on regular width. | `SummariesView.swift:115`, `Views/TranscriptViews.swift:116`, `Views/RecordingsView.swift:429`, `Views/RecordingsListView.swift:335` | The inner display never shows list and detail together (no Mail pattern). Sheets also centre on the inner display and cover the list. `SummaryDetailView` wraps itself in its own `NavigationStack` with a text-only **Done** (`SummaryDetailView.swift:201`, `:247-252`). |
| F4 | Custom in-content bars. The Recordings library header puts filter and "more" buttons in an `HStack`, with an `ellipsis` custom menu. The Record screen puts Help as an in-content circle button. | `Views/RecordingsListView.swift:100-110`, `:451-500`; `Views/RecordingsView.swift:252` | None of these become vertical bar items, so they eat vertical space on the short outer display. The ellipsis menu clashes with the system overflow menu. |
| F5 | 39 toolbar items use the deprecated `.navigationBarLeading/.navigationBarTrailing`. Many items are text-only ("Done", "Cancel", "Save"). | across `Views/`, `SummaryDetailView.swift`, `SummariesView.swift`, `TranscriptViews.swift`, settings views | They lose semantic ordering in the vertical bar and fall back to horizontal. "Done" doesn't pin to the top. |
| F6 | The Record screen and the player are single centred columns inside a `ScrollView`. The Record screen is capped at `maxWidth: 620`. The player stacks the waveform, scrubber and transport vertically with fixed heights. | `Views/RecordingsView.swift:235-357`, `Views/AudioPlayerView.swift:59-195` | On the inner display, partly folded, the record button and the transport controls sit **in the crease**. On the outer display (wide and short), the hero logo pushes the record button and import actions below the fold, so the user has to scroll. |
| F7 | iPhone orientations conflict. `Info.plist` lists portrait only. The build settings (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`) list portrait + landscape. | `Info.plist`, `project.pbxproj` | Need to check which one ships. If portrait-only, the outer display can't be used in the tent or landscape pose that Apple recommends supporting. |
| F8 | `UIScreen.main.scale` | `SummaryDetailView.swift:3730`, `Services/PDFExportService.swift:46`, `:682` | Ambiguous with two displays, and slated for deprecation. |
| F9 | Multiple scenes aren't declared on iOS (generated scene manifest only). | `project.pbxproj` | The inner display supports several windows of the app. That's optional; see M6. |
| F10 | There's no Live Activity for recording. | — | On Duo the Dynamic Island grows in the side strip for Live Activities. Not a layout bug, but a natural follow-up (section 8). |

Things that are already fine: `NavigationSplitView` and `TabView` are already used, and so are `.searchable`, `cancellationAction`/`confirmationAction` in most editor sheets, and `Form`/`List` for settings, which scroll and need no fold handling. There are no `LazyVGrid`s and no orientation checks for layout. `userInterfaceIdiom` appears only in the Action Button capability check, which is correct because it's a hardware question. The large fixed widths are all macOS-only. None of the macOS window code is in scope.

## 3. Target experience

| Pose | Navigation | Recordings / Transcripts / Summaries | Record | Player |
|---|---|---|---|---|
| Closed, portrait | Tab bar in the vertical side strip | List → push detail | Compact hero; record button visible without scrolling | Single column |
| Closed, landscape / tent | Same; toolbar items overflow first | Same | Hero hidden; controls and status side by side | Transport left, transcript right if it fits, otherwise player only |
| Open, landscape (flat) | Sidebar | List column + detail column (Mail pattern) | Controls and live transcript split left/right | Player + synchronized transcript split |
| Open, book (partly folded) | Sidebar | Columns rebalance 50/50 around the fold (system) | Controls on one side, transcript on the other, nothing in the crease | Same as flat; the split follows the fold |
| Open, laptop (seated) | Horizontal bars | Same split | Status and transcript on the top half, controls on the bottom half | Waveform and transcript on top, transport on the bottom |
| Open, Split View (either side) | Bars on the app's outer edge | Collapses to list → push at compact width | Single column | Single column |

The rule this table encodes is that **closing the device never loses anything**. The selected section, the selected item and any open editor carry across, and the inner display just adds the next level of hierarchy.

## 4. Milestones

Each milestone ships on its own and keeps iOS 18.5 / iPadOS 18.5 working. Duo-only APIs (`ArrangementView`, `reservedRegions`, `visibilityPriority`, `ToolbarOverflowMenu`, `axisBehavior`, `defaultTabBarPlacement`, `toolbarVerticalCompressionBehavior`) sit behind `if #available(iOS 27.1, *)`. They live in one small helper file, `Views/AdaptiveLayoutSupport.swift`, which has a stack/no-op fallback, so call sites stay readable and the deployment target doesn't change. iPad gets most of M1–M3 for free, and that is intended.

### M0: Baseline (no code changes)

1. Build the `BisonNotes AI` scheme with Xcode 27.1+ (27.2 is installed) against the iOS 27.1 SDK and run it on the **iPhone Duo** simulator.
2. Use Device Hub to capture every tab and the key sheets in each of these states:
   - outer display, portrait and landscape
   - inner display, flat landscape and portrait
   - book pose, laptop pose
   - Split View on the left and on the right
   - with a PiP video pinned
3. Store the screenshots under `docs/duo-baseline/`. Check them against F1–F8 and correct this plan.
4. Confirm which orientation list ships (F7) by inspecting the built product's `Info.plist`.
5. Run Xcode's **App Resizability** skill and file its findings into the milestones below.

**M0 progress (2026-11-01, partial):**

- The iOS scheme builds cleanly with Xcode 27.2 and runs on the iPhone Duo simulator (iOS 27.1 runtime). Baselines use a dedicated simulator, "BisonNotes Duo Baseline", because the stock "iPhone Duo" simulator is shared with other projects. It was shut down, and had BisonHealth AI launched onto it, mid-capture.
- Launch with `--ui-testing --reset-test-data --seed-sample-recording --disable-cloud-services` to get deterministic content.
- Capture with `xcrun simctl io <udid> screenshot --display=1|3 --mask=black`. Display 1 is the outer panel (1398×2034 px, 466×678 pt). Display 3 is the inner panel (2007×2853 px).
- Opening, closing, folding and rotating can only be driven from Xcode's Device Hub. `simctl io screenConfig power` does not simulate opening; the inner panel stays dark.
- **F7 confirmed.** The built product ships `UISupportedInterfaceOrientations = [Portrait]` for iPhone, so the outer display cannot be used in landscape or the tent pose.
- **Outer display, portrait** (`docs/duo-baseline/outer-portrait-01…07`). The system pieces already adapt; everything we built ourselves doesn't.
  - **Works today:**
    - The `TabView` tab bar sits in the vertical side strip, icons only.
    - The Transcripts and Summaries filter buttons are real `.toolbar` items, and they move into the strip.
    - `.searchable` in the Recordings library becomes the system search button at the bottom of the strip.
  - **F4, in-content controls stay in the content:**
    - Record's Help button.
    - Setup's advanced-settings gear.
    - The Recordings library header (filter, ellipsis menu, close). The squeezed header hyphenates the large title as "Record-ings".
  - **F5, sheet bars stay horizontal.** Text-only and custom items stay in a horizontal bar across the top of the sheet:
    - Transcript editor: Cancel / Save.
    - Summary detail: an "Export" icon+text custom label, and Done.

    This happens even though Apple's default for sheets on the outer display is a vertical bar.
  - **F6, the Record screen needs scrolling.** The "Record" title block and the logo hero push the import actions down, so "Import Transcripts" is off-screen.
  - **F2:** the app is forced dark on this display.
- **Inner display, portrait** (`docs/duo-baseline/inner-portrait-01…04`):
  - **F2:** the app switches from dark to light as soon as the device opens.
  - **Collapsed sidebar:** the `NavigationSplitView` sidebar starts collapsed behind a toggle, and Record fills the screen as one centred column.
  - **New finding (F11):** the sidebar opens as an overlay, and it stays open after a section is picked, so the user has to dismiss it by hand. M1's `sidebarAdaptable` `TabView` replaces it.
  - **Bars are horizontal,** as Apple specifies for inner portrait.
  - **F3:** "View Summary" opens a sheet that covers almost the whole display and hides the list.
- **F1 confirmed** (`docs/duo-baseline/continuity-01-after-close-reset-to-record.png`):
  - Start on Summaries with a summary sheet open on the inner display, then close the device.
  - The outer display comes back on **Record**: the selected section is lost, the sheet is gone, and the appearance has flipped back to dark.
- **Inner display, landscape, flat** (`docs/duo-baseline/inner-landscape-01…03`):
  - **Sidebar:** pinned permanently.
  - **Detail-column bars (Summaries filter and search):** they move into the vertical strip on the right, as Apple describes.
  - **Record (F6):** the card and the Start Recording button are centred across the middle of the display, which is where the fold runs in the book pose.
  - **F3:** the summary opens as a centred sheet over the list, again straddling the middle, instead of the Mail-style list | detail.
- **Still to capture:** book, laptop and Split View (needs Device Hub), and outer landscape. Outer landscape needs M1's orientation fix first, which is itself a finding.

### M1: Continuity foundation (fixes F1, F2, F7, F8)

- **One navigation root on iOS.** Replace the `if horizontalSizeClass == .compact` branch with a single `TabView(selection:)` that uses the `Tab` API and `.tabViewStyle(.sidebarAdaptable)` (iOS 18+). On iOS 27.1, add `.defaultTabBarPlacement(.sidebar)` so the inner display opens with the sidebar.
  - Keep `SidebarItem` as the single selection type, and persist it with `@SceneStorage` so it survives resizes and relaunches.
  - Fold the `NavigateToSection` / `SwitchToRecordTabForImport` handlers into that one place. Today the compact path ignores `NavigateToSection`.
  - Leave macOS on `AdaptiveNavigationView` unchanged.
- **Keep view identity stable across resizes.** The `@StateObject`s that hold in-flight work (import managers, the web import manager) must not live in a subtree that gets rebuilt. M1's single root fixes this by construction. Add a UI test that opens the library sheet and the web-import sheet, toggles the size class, and asserts they're still there.
- **Appearance must not depend on size class (F2).** Remove the `horizontalSizeClass`-keyed `preferredColorScheme`. Follow the system by default, and add an "Always dark" toggle to Preferences. It is one `@AppStorage` key, applied at the root on every platform, and joins iCloud settings backup like the other appearance settings.
- **Orientation (F7).** Allow landscape on iPhone and remove the conflicting `Info.plist` entry so only one source of truth remains. Check compact-height layouts (they're covered in M4).
- **F8.** Use `@Environment(\.displayScale)` in SwiftUI and `traitCollection.displayScale` or the window scene's screen elsewhere. PDF export takes the scale as a parameter.

**Exit:** Opening and closing the device in every tab keeps the selected tab, the scroll position and any presented sheet. The appearance doesn't flip. Unit tests pass, and the new UI test passes on iPhone 17, iPad and iPhone Duo simulators.

### M2: System bars (fixes F4, F5)

- **Move in-content bars into `.toolbar`:**
  - The Recordings library filter becomes `Label("Filter", systemImage:)`.
  - Combine / Archive / Export / Archive Older Than go into `ToolbarOverflowMenu` on 27.1, or a `Menu` with a non-ellipsis symbol before that.
  - Help on Record becomes a toolbar `Label("Help", systemImage: "questionmark.circle")`.
  - Do the same for the `ellipsis.circle` menus in `SummariesView.swift:677` and `TranscriptViews.swift:853`.
- **Migrate `.navigationBarLeading/Trailing` to semantic placements:**
  - `cancellationAction` for Close/Cancel.
  - `topBarPinnedTrailing` (27.1) or `confirmationAction` for Done/Save.
  - `primaryAction` for the main action, such as Export.
  - Prefer the system close button (`Button(role: .close)`, iOS 26+) over a text "Done" in presented sheets, so they go vertical.
  - Give every item a title *and* a symbol.
- **Priorities.** Search and Filter get `visibilityPriority(.high)`. Export and Share overflow first. A badge for the background-processing queue count is optional.
- **Compression.** Tabs stay navigation-focused (the default). Editor sheets, such as the transcript editor, speaker editor and trim view, use `.toolbarVerticalCompressionBehavior(.prefersToolbarItems)`.
- **Opt out where Apple says to.** A sheet whose only bar item is Close uses `.toolbarVerticalBehavior(.disabled)`.

**Exit:** In the outer-display screenshots, every action sits in the side strip or the overflow menu, and no content scrolls under it. The same is true in the inner-display landscape screenshots.

### M3: List + detail on the inner display (fixes F3)

- Inside the Transcripts, Summaries and Recordings-library tabs, host a `NavigationSplitView(content | detail)` (the selection lives in that tab).
  - At regular width the list and detail sit side by side. At compact width the split collapses to a push.
  - This replaces the modal sheet everywhere, iPhone included, so both displays behave the same way.
  - A `TabView` hosting split views is the arrangement Apple supports. `ArrangementView` is **not** used here because it doesn't navigate.
- **Make `SummaryDetailView`, the transcript detail and `AudioPlayerView` embeddable.** When `isEmbeddedInSplitView` is set, don't wrap in a `NavigationStack` and don't show Done. Their bar items then become the detail column's vertical bar.
- **Keep the user's place.** Persist the selected recording, transcript or summary ID per tab (`@SceneStorage`). On a compact → regular transition the item is still selected, and on regular → compact it stays pushed.
- **Show a useful empty detail.** Without a selection, show `ContentUnavailableView` ("Select a summary") rather than a blank column.
- **Recordings library.** It's a sheet from the Record tab today. On regular width, open it as a column or a navigation destination rather than a sheet. Decide during M3 with the M0 screenshots.

**Exit:** On the inner display a user can scan summaries on the left and read one on the right. Closing the device shows that same summary, and opening it again shows the list beside it.

### M4: Fold-aware Record and Player (fixes F6)

- **Record screen.**
  - Restructure into a primary (record/stop/pause + timer) and a secondary (live transcript while recording; import actions and recent recordings while idle).
  - On 27.1, use `ArrangementView` with `.split`. On earlier releases it falls back to the current `VStack`.
  - The record button is the primary, so it's always shown and never in the crease.
  - With `verticalSizeClass == .compact` (outer display landscape), hide the 116 pt logo hero and the subtitle so the controls fit without scrolling.
  - For the laptop pose, Apple wants status on top and controls on the bottom. A vertical split puts the primary on top, so either accept that or place the control bar with `reservedRegions(kind: .division)`. Decide on device, not in theory.
- **Player.**
  - Use Apple's sample shape directly: `ArrangementView { player } secondary: { synchronized transcript }` with `.split.axes(.horizontal)`. Player only in portrait; player | transcript when wide or folded.
  - Transport buttons keep their position across poses ("small adjustments over rearrangement").
- **Custom centred elements.** Check the splash, the empty states and the download/progress panels. Anything interactive that can land in the crease moves to `reservedRegions`-aware placement. Text-only views can stay centred.

**Exit:** In book and laptop screenshots, no button or slider intersects the division region. On the outer display in landscape, the record button is visible without scrolling at the default text size and at AX3.

### M5: Resizing edge cases and polish

- Run the app in Split View on both sides of the inner display. Check that the asymmetric safe areas don't put content under the bar on the opposite edge, and fix any symmetric-inset assumptions the resizability skill reports.
- Pin a PiP video and confirm the Record and player screens compress without clipping.
- Set sheet placement explicitly where it matters (`presentationPlacement`). A trailing placement gets vertical bars.
- Check Dynamic Type up to AX5 on the outer display in landscape. That is the tightest space the app will ever see.
- Full-bleed backgrounds (splash) can extend under the vertical bar with `backgroundExtensionEffect()`. Rounded cards near the screen edge use `ConcentricRectangle` where they sit flush with the edge.

### M6 (follow-up, not on this branch): Multiple windows on the inner display

The inner display, like iPad, can host several windows of the app. Opening a summary or transcript in its own window would reuse the routing already built for macOS (`Platform/NativeWindowRouting.swift`, `NativeSummaryWindowView`).

The risk is shared singletons, in particular the one recorder and the one `AppDataCoordinator`, across scenes. Recording would have to stay single-scene. Use `UIWindowSceneActivationAction` so the action disappears on the outer display, where new windows aren't allowed. Only worth it if M0–M3 testing shows users want two summaries open at once.

## 5. Testing

- **Simulator matrix:** iPhone 17 (regression), an iPad (regression, because M1 and M3 change iPad too), and iPhone Duo in every Device Hub pose from M0. Repeat the matrix at the end of each milestone and compare against `docs/duo-baseline/`.
- **UI tests** (`BisonNotes AIUITests`):
  - The continuity test from M1.
  - Selection survives a size-class change (M3).
  - Toolbar actions can be reached by accessibility identifier on the outer display (M2).
  - Existing accessibility identifiers keep working through the toolbar migration. `docs/accessibility-matrix.md` lists them.
- **Hardware gate before release:** recording, live transcription and playback run uninterrupted while the device is opened, closed and folded. Audio isn't tied to a scene, but the UI around it is, so check the timer and the live transcript.
- Add the Duo poses to `docs/testing-regimen.md`.

## 6. Documentation and release

- `CLAUDE.md`: a short "iPhone Duo" section with the rules from section 1 that future work must keep. In particular:
  - no size-class-keyed view trees
  - system bars only
  - detail in a split column, not a sheet
  - interactive controls never in a division region
- User guide: if this ships in a new minor version, the new guide's Recording and Playback sections get Duo notes, following `docs/user-guide/README.md`. Keep every `bn-*` anchor.
- App Store: iPhone Duo screenshots for both displays, using Apple's screenshot specifications.

## 7. Decisions (agreed 2026-11-01)

1. **Appearance (F2): follow the system everywhere, with an optional "Always dark" preference.** The size-class-keyed `preferredColorScheme` goes away in M1. The new preference is a single setting read the same way on every display and device, so opening or closing never changes the appearance.
2. **Detail as split column instead of sheet (M3): yes.** iPhone and iPad also move from sheets to push/columns, so every display behaves the same.
3. **Multiple windows (M6): follow-up.** It is not part of the initial work on this branch.

## 8. Out of scope / follow-ups

- A recording **Live Activity**. It benefits every iPhone, and on Duo it shows in the side-strip Dynamic Island.
- The hinge-angle API (`onHingeChange`) is for effects, not layout. There's no natural use in a recording app, so it isn't planned.
- `CameraCaptureAccessory` doesn't apply; the app doesn't capture video.
- Watch, widgets, the Controls extension and native macOS aren't affected.

## 9. Sources

- HIG: [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- Documentation: [Preparing your app for iPhone Duo](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo)
- Tech talks:
  - [Design for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111466/)
  - [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
  - [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)
  - [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
  - [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/)
