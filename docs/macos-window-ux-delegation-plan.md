# Native macOS Window Chrome and Settings UX Delegation Plan

## Copy/paste instruction for Luna

> Execute `docs/macos-window-ux-delegation-plan.md` as the controlling plan on branch `macoslook`. Use one lead agent for branch state, shared presentation infrastructure, Xcode project ownership, integration, and final validation. Start with Wave 0 and do not skip the baseline. Delegate only the file-exclusive packages listed below, with no more than three implementation agents active alongside the lead. Complete each dependency wave before starting the next. Preserve the iPhone and iPad presentation behavior unless this plan explicitly says otherwise. Do not commit, push, open a pull request, switch branches, rewrite history, or alter unrelated files without explicit user authorization. Stop and report the exact evidence if the branch, worktree, baseline, or required native-macOS validation is not as expected.

## Status and reviewed starting point

- Planning date: August 22, 2026.
- Requested working branch: `macoslook`.
- Branch point: clean local `v2.3` at `05efd15bf415e53ecfb72399d362bf90fdfa60a8`.
- The plan file itself may be the only expected uncommitted file when Luna begins. It is an approved planning artifact, not authorization to commit it.
- Native target: `BisonNotes AI macOS`, minimum macOS 15, Apple silicon only.
- Mobile targets remain supported. This project no longer has a Mac Catalyst product; do not use the stale Catalyst gate in `docs/macos-window-presentation-audit.md`.
- This plan supersedes the button-placement and Settings-navigation portions of `docs/macos-window-presentation-audit.md`. Its modeless-window versus modal-sheet classification remains useful.

The executing lead must recheck all of this. A matching commit in a detached checkout is not sufficient; the branch must be exactly `macoslook` in the intended worktree.

## Goal

Make the native Mac app behave like a Mac app instead of placing iPhone-style navigation controls inside ordinary windows.

The finished experience must:

- rely on the standard red window control and Command-W to close independent windows;
- make Transcript Save commit successfully and then close, with safe unsaved-change handling for every other close path;
- replace the Settings push stack with stable Mac settings panes, eliminating the floating centered Back button;
- use platform-semantic confirmation and cancellation placement only in true modal tasks;
- keep common actions in a real window toolbar or menu, away from the traffic-light controls;
- apply the presentation contract to every native-Mac window, Settings pane, sheet, popover, alert, and other presented surface, not only the supplied examples;
- retain clear keyboard, accessibility, resize, scrolling, and destructive-action behavior;
- preserve iOS and iPadOS navigation and sheet behavior.

This is a native-macOS interaction and presentation project. It is not permission to redesign the data model, providers, summary content, transcription algorithms, or the entire visual identity.

## Product decisions and defaults

Unless the user answers differently before implementation, use these defaults:

1. Use a six-pane toolbar-style Settings window: General, Recording, Transcription, AI, Storage, and Advanced. This follows the current Apple guidance for Mac settings and stays at the recommended maximum of six visible panes.
2. Keep Settings changes immediate, as they are today. Settings panes therefore have no Save, Cancel, Done, or Back button. A control that cannot truthfully apply immediately must use a real draft and a transactional sheet; it may not display a cosmetic Cancel button that fails to revert changes.
3. Make Edit Transcript an explicit Save-and-close editor: the Save button and Command-S persist the transcript and close only after success. Command-W or the red window control closes immediately when clean and presents Save, Discard Changes, and Cancel when dirty.
4. Defer restyling mobile-looking cards, colors, badges, and in-content action buttons to a separate pass. This plan changes window chrome, navigation, action placement, action semantics, sizing, scrolling, keyboard behavior, and accessibility only where needed for consistent Mac presentation.
5. Keep the deployment minimum at macOS 15. Use system components that automatically adopt the current appearance; do not hand-build or back-deploy Liquid Glass.

## Evidence from the supplied screenshots

| Screenshot | Runtime route | Current problem | Target behavior |
| --- | --- | --- | --- |
| Edit Transcript | `WindowGroup("Transcript")` -> `NativeTranscriptWindowView` -> `EditableTranscriptView` | Cancel is crowded against the traffic lights; Save is an iOS navigation action; normal Save produces an unnecessary success alert before closing | No Cancel button in window chrome. Use a trailing Save action plus File > Save / Command-S. Successful Save closes immediately without a success alert; failed Save keeps the editor open. Other close paths prompt only when dirty. |
| Summary, all three captures | `WindowGroup("Summary")` -> `NativeSummaryWindowView` -> `SummaryDetailView` | Export is crowded against the traffic lights and Done duplicates the red window control | Remove Done. Put Export in the trailing action area and retain File > Export Summary. Close with the window control or Command-W. |
| Preferences | `Settings` -> `SettingsView` -> pushed `PreferencesView` | A lone Back chevron floats near the center of the title area | Preferences becomes the General pane in the Settings toolbar; no Back or Done control. |
| On-Device Transcription | `SettingsView` -> `TranscriptionSettingsView` -> pushed `FluidAudioSettingsView` | The same centered Back control makes a settings editor look like a phone navigation stack | Transcription becomes a top-level Settings pane with stable engine selection and an inline detail area; no Back or Done control. |
| Background Processing | `Window("Background Processing")` -> `BackgroundProcessingView` | Done is crowded against the traffic lights and duplicates standard close | Remove Done. Keep a trailing More menu for maintenance actions. Closing the window must not cancel jobs. |
| AI Settings | `SettingsView` -> pushed `AISettingsView` | Centered Back control and an iOS drill-down model | AI becomes a top-level Settings pane with an engine list/detail layout and no Back button. |
| Compatible API | `AISettingsView` -> pushed `OpenAICompatibleSettingsView` | Back and Done sit together in the center; Done is redundant because values already persist while editing | Show provider configuration in the AI pane detail area. No Back/Done. Keep validation, connection testing, Keychain storage, and scroll behavior. |

## Current implementation findings

- `BisonNotesAIApp.swift` defines the Settings scene and eight independent secondary Mac window scenes.
- `SettingsView.swift` owns one `NavigationStack` and uses `navigationDestination` for Preferences, AI, Transcription, Background Processing, and Acknowledgements on macOS.
- `AISettingsView.swift` and `TranscriptionSettingsView.swift` add another level of Mac `navigationDestination` routing for engine configuration.
- `NativeWindowRouting.swift` contains `nativeMacModalDismissControl`, which places a bordered button in a top-leading overlay. There are currently 15 external uses of this fallback.
- A current source search finds 51 `.sheet` presentation sites across 13 main-app files, three full-screen-cover wrappers, and eight secondary Mac window scenes in addition to the primary app window and Settings scene. The implementation must re-inventory these numbers at Wave 0 because they can drift.
- Several views are reused as both an independent Mac window and an iOS sheet. Their dismissal controls must depend on presentation context, not merely on `os(macOS)`.
- Some provider configuration views show Cancel/Save even though `@AppStorage` and `@SecureStorage` mutate immediately. Moving buttons without fixing that semantic mismatch is not acceptable.
- Closing `AudioPlayerView` through its custom Close button stops playback, but closing its independent Mac window may bypass that path. Removing the button requires lifecycle cleanup verification.
- `EditableTranscriptView` has no complete dirty-state model or standard-window close guard. Its current Save success alert closes the window after acknowledgment.

## Complete-surface coverage rule

The supplied screenshots are examples, not the boundary of the work. The implementation is incomplete until every native-Mac presentation surface has been inventoried, classified, and checked against this plan.

The inventory must include:

- the primary app window, the Settings scene, and every `Window` or `WindowGroup` scene;
- every Settings pane and every selectable engine/provider detail within a pane;
- every Mac-active `.sheet`, `.fullScreenCover`, `platformFullScreenCover`, `.popover`, inspector, attachment preview, Quick Look presentation, file importer/exporter, and onboarding flow;
- every alert and confirmation dialog whose roles, labels, default action, cancellation, or destructive behavior can differ on macOS;
- every menu or toolbar action that opens, closes, saves, exports, cancels, or navigates one of those surfaces;
- every dual-use view whose Mac window behavior must differ from its iPhone/iPad sheet behavior.

“Consistent” does not mean giving every surface the same buttons. It means every surface of the same type follows the same contract: modeless windows use standard window close, Settings uses stable panes, transactional sheets use honest Cancel/Save actions, read-only sheets use Close, and multistep flows reserve Back for actual navigation. The final inventory must contain no unclassified or “not reviewed” Mac surface.

## Apple design basis

Use current official Apple guidance as the design source of truth:

- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings): a Mac settings window typically uses a stable, noncustomizable toolbar for panes, indicates the selected pane, updates the window title, and restores the most recently used pane.
- [SwiftUI Settings](https://developer.apple.com/documentation/swiftui/settings): a root `TabView` is the system-supported way to group a Mac Settings scene into collections. On macOS 15, a root scene `TabView` adopts the toolbar-style presentation.
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars): navigation belongs on the leading side; important and primary actions belong on the trailing side; only one action should receive primary prominence.
- [ToolbarItemPlacement](https://developer.apple.com/documentation/swiftui/toolbaritemplacement): prefer semantic placements such as `primaryAction`, `secondaryAction`, `confirmationAction`, `cancellationAction`, and `destructiveAction` so SwiftUI can place them appropriately on each platform.
- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets): Back navigates within a real hierarchy and does not dismiss; a sheet needs an honest alternative to Done; complex document-like work is often better in a separate Mac window.
- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows): use system window appearances and behaviors so foreground state, resizing, and standard controls remain familiar.
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout): test common tiled and resized window dimensions, and do not put critical ordinary-window controls where the bottom can be pushed offscreen.
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons): use native button roles and standard controls, clear verb labels, adequate targets, and restrained prominence.

## Native Mac presentation contract

Every surface must be classified before it is edited.

| Surface type | Close or navigation behavior | Action placement | Keyboard behavior |
| --- | --- | --- | --- |
| Modeless read-only or monitoring window | Standard red window control and Command-W; no Done, Close, Cancel, or X button in content | Window toolbar for frequent actions; trailing More menu for secondary/destructive maintenance | Command-W closes only the window; background work continues unless the user explicitly cancels it |
| Modeless editor window | Standard close, with a dirty-state save/discard/cancel decision when needed | Commit action in trailing `primaryAction`; related tools in `secondaryAction`; expose the commit command in the File menu | For Edit Transcript, Command-S saves and closes after success; Command-W requests close; Escape does not silently discard the whole window |
| Settings pane | Switch using the Settings toolbar; changes apply immediately | Controls live in the pane; no dismissal action | Command-comma opens Settings; Command-W closes; pane selection is restored |
| Transactional modal editor | Explicit Cancel and Save/Apply with real draft semantics | Semantic `cancellationAction` and `confirmationAction`; one primary action | Escape/Command-period cancels; Return invokes the enabled default action when safe |
| Read-only modal sheet | Close is visible in the sheet and does not imply saving | Semantic modal placement or a system sheet action area, never a floating overlay | Escape/Command-period closes |
| Multi-step modal flow | First step has Cancel; later steps use Back/Next; final step uses Finish | Use the wizard's action area; never show Back, Cancel, and Done together | Escape cancels with loss protection; Return advances only when validation passes |
| Destructive confirmation | Keep the parent context visible and require an explicit destructive choice | System alert/confirmation dialog with a destructive role | Cancel remains the safe default |

### Global rules

- Do not reposition, replace, or visually compete with the traffic-light controls.
- Do not put text buttons immediately after the traffic lights.
- A modeless window never needs an additional Done or Close control merely to prove it can close.
- Use a meaningful window title. Multiple summary or transcript windows must identify their recording, for example `Recording Name — Summary` and `Recording Name — Transcript`.
- Avoid duplicated visible titles such as a window title of “Summary” plus an unnecessary second toolbar title of “Summary.” Retain a clear content heading only when it improves document hierarchy.
- Use semantic toolbar placements instead of `.navigationBarLeading` and `.navigationBarTrailing` on native Mac paths.
- Keep no more than one visually prominent action in window chrome or a modal action set.
- Use standard `Button`, `Menu`, toolbar, keyboard-shortcut, and action-role behavior for chrome and modal actions. Do not use this pass to restyle unrelated cards, badges, status blocks, or in-content controls.
- A destructive action must use `role: .destructive` and an appropriate confirmation. Color alone is not the warning.
- Icon-only actions need a discoverable help tooltip, accessibility label, and adequate target. Use text when the symbol is ambiguous.
- Use standard materials and button styles. Do not add custom glass effects, custom traffic lights, or private AppKit appearance hacks.
- Preserve one scroll owner per pane/window and verify controls remain reachable at minimum size.

## Settings information architecture

The macOS `Settings` scene must render a Mac-specific root instead of the current push stack. The iOS/iPadOS `SettingsView` remains behaviorally unchanged.

### Toolbar panes versus a sidebar

A toolbar-pane Settings window places a small row of labeled icons across the top of the window. Selecting General, Recording, Transcription, AI, Storage, or Advanced replaces the whole settings pane below it. This is the classic Mac Preferences/Settings pattern, keeps the content area wide, and lets SwiftUI's root Settings `TabView` manage selection, title, and restoration without a Back button.

A sidebar Settings window keeps a vertical category list visible on the left and displays the selected category on the right, similar to System Settings or a Finder window. It scales better when an app has many categories or deep hierarchy, but permanently consumes horizontal space and makes a compact app settings window feel more like a second main application window.

The default recommendation for BisonNotes is toolbar panes because there are exactly six top-level categories and several content-heavy forms benefit from the extra width. If the user chooses a sidebar, keep the same six-category map and complete-surface rules; only the root selection container changes.

### Required Mac panes

1. **General** — time format, display preferences, behavior, and comedy-mode controls.
2. **Recording** — microphone choice, meeting/system-audio capture, location capture, and recording defaults.
3. **Transcription** — live-transcription options, engine choice, selected engine status, and the selected engine's configuration detail.
4. **AI** — current summary engine, engine library, selected engine configuration, summary detail/thinking, timeout, and regeneration management.
5. **Storage** — iCloud controls, local-only behavior, backup/restore, review, and storage status.
6. **Advanced** — background-processing link, migration/database tools, logs/troubleshooting, acknowledgements, and app information.

### Settings behavior

- Build the Settings scene around a root `TabView` with labels and SF Symbols. Do not make it customizable.
- Before extracting panes, map every current Settings section, control, action, engine, and provider detail to exactly one destination pane. Nothing may be dropped, duplicated, or left reachable only through an obsolete push route.
- Persist or restore the most recently selected pane using the system behavior or an explicit stable setting if required by the selected SwiftUI API.
- Let each pane own its vertical scrolling and sensible content width. Do not nest a second vertical `ScrollView` around a scrolling provider form.
- AI and Transcription may use a stable list/detail arrangement inside their pane for engine selection and configuration. Selecting a provider changes the detail; it must not push a new full-window screen or reveal a Back button.
- Provider settings that already use `@AppStorage` or `@SecureStorage` remain immediate. Remove Done/Save/Cancel chrome and ensure `onConfigurationChanged` fires when committed storage actually changes.
- If a provider is converted to a modal editor, first introduce a complete draft model and tests proving Cancel restores every field, including the Keychain-backed secret. Never call an immediate binding “Cancel.”
- Model downloads, connection tests, reset, and delete actions remain explicit actions; they do not happen merely because a pane becomes visible.
- Background Processing stays an independent modeless window. The Advanced pane opens or activates it rather than pushing a duplicate copy into Settings.
- Acknowledgements can be an Advanced-pane detail or a bounded read-only sheet, but it must not create another iOS-style Back button.
- Update the Settings window title for the active pane and verify Command-comma, close/reopen, and pane restoration.

## Screen-specific requirements

### Edit Transcript

- On native macOS, remove the leading Cancel button and the save-success alert that closes the window.
- Add an explicit dirty-state snapshot for segment text and speaker mappings. Do not treat the separately saved recording-title field as an unsaved transcript change unless its persistence is intentionally refactored.
- Save must be disabled while clean or saving, enabled while dirty, and remain available as a trailing primary toolbar item and File > Save command.
- The Save button and Command-S perform the same operation once. A successful save closes the window immediately without a success alert. A failure keeps the draft and editor open and shows the existing error.
- Red close and Command-W close immediately when clean. When dirty, show Save, Discard Changes, and Cancel. Save closes only after persistence succeeds; Discard closes without writing; Cancel returns to editing.
- Scope any AppKit close-interception bridge to this window. Do not replace a shared `NSWindow` delegate without preserving/restoring existing behavior.
- Rerun Transcription keeps its destructive confirmation and must update the dirty baseline correctly when replacement text arrives.
- The speaker editor remains a true modal editor with Cancel and Apply, semantic placement, Escape/Return shortcuts, and no floating overlay.

### Summary windows

- Remove Done from an independent summary window.
- Move Export to a trailing toolbar action, use a standard label and control size, and keep File > Export Summary wired through the existing focused scene value.
- Show the recording name in the window title so multiple summary windows can be distinguished.
- Keep scrolling stable at minimum size.
- Do not restyle summary cards or in-content action buttons in this pass unless a change is strictly required to remove duplicate window chrome or preserve action semantics.
- Preserve summary generation, task/reminder integration, attachments, date, location, export formats, and delete behavior.
- Convert summary-owned editor sheets to explicit semantic modal actions. Read-only attachment sheets use Close; note/title/date/location editors use honest Cancel plus Save/Apply.

### Background processing and job detail

- Remove Done from the independent Background Processing and Processing Job windows.
- Keep the More menu trailing. Give destructive maintenance commands a confirmation if they can remove history or cancel work.
- Closing the activity window does not cancel or clear jobs.
- Preserve the current status-card styling; verify existing status labels remain understandable without color.
- An active job's Cancel Job action remains explicit and destructive; do not make it look like ordinary window dismissal.

### Audio player, recordings, and location windows

- Remove native-Mac-only Close/X controls from independent windows; retain mobile sheet dismissal controls.
- Closing the Audio Player window must stop or release playback exactly once, matching the existing explicit Close path.
- Keep recordings actions in a trailing toolbar/More menu. Remove the custom X from the independent Recordings window.
- Remove Done from the independent Location window. Put Open in Maps and Copy Coordinates in standard toolbar or compact content controls with accessible labels.
- Verify all views still behave correctly when presented as a sheet on iOS/iPadOS.

### Remaining presentation surfaces

- Reclassify every current use of `nativeMacModalDismissControl` rather than mechanically moving it.
- Retain `nativeMacModalSizing`, but replace the top-leading overlay implementation after all call sites migrate.
- Inspect every scene, Settings pane/detail, `.sheet`, `.fullScreenCover`, `platformFullScreenCover`, `.popover`, alert, confirmation dialog, Quick Look/attachment preview, and file presentation under the main app source.
- For each Mac-active site, record: presenter, presented view, modal/modeless purpose, action semantics, dirty state, keyboard behavior, scroll owner, default/minimum size, accessibility name, and iOS impact.
- Do not add duplicate fallback buttons around a view that already owns correct semantic actions.
- Do not stack a sheet on top of another sheet when the first can be dismissed or the child can be represented inline.

## Ownership and delegation rules

1. The lead owns `BisonNotesAIApp.swift`, `Platform/NativeWindowRouting.swift`, `AccessibilityIdentifiers.swift`, the Xcode project, shared command/focused-value declarations, UI-test integration, and final documentation updates.
2. Each package below has exclusive file ownership while active. No agent edits outside its package without lead reassignment.
3. No two agents edit `SettingsView.swift`, `AISettingsView.swift`, `TranscriptionSettingsView.swift`, `SummaryDetailView.swift`, `TranscriptViews.swift`, `RecordingsListView.swift`, or any test file simultaneously.
4. The lead integrates and validates a wave before handing shared infrastructure to the next wave.
5. New Swift files under the filesystem-synchronized app/test groups should not require manual `project.pbxproj` edits. Only the lead may verify or change target membership.
6. Do not perform broad formatting, rename persistence keys, move Keychain data, alter provider defaults, or change navigation on iOS/iPadOS.
7. Do not add a new global `NSWindowDelegate`, private API, or custom title-bar/traffic-light implementation.
8. Preserve unrelated edits and existing worktrees. Do not stash, reset, or change branches to repair a mismatch.
9. No commit or push is authorized by this plan.

## Required report from every implementation agent

```text
Work package:
Starting branch and HEAD:
Files changed:
Presentation classification for each changed surface:
Behavior changed:
macOS-specific behavior:
iOS/iPadOS behavior preserved:
Keyboard and accessibility behavior:
Tests added or updated:
Commands run and exact result:
Screenshots/manual checks performed:
Risks or assumptions:
Unresolved items:
```

“Done,” “looks native,” or “tests should pass” is not an acceptable report.

## Wave 0 — Lead-only baseline and inventory lock

### Branch and worktree guard

- [ ] Run `pwd` and confirm `/Users/champ/Sources/BisonNotes-AI`.
- [ ] Run `git status --short --branch` and confirm branch `macoslook`.
- [ ] Record `git rev-parse HEAD`, `git rev-parse --abbrev-ref HEAD`, and `git worktree list --porcelain`.
- [ ] If HEAD is still the planning branch point, it must be `05efd15bf415e53ecfb72399d362bf90fdfa60a8`.
- [ ] Permit only the uncommitted plan file unless the user has intentionally added other work. Stop on any overlap with required files.
- [ ] Read `AGENTS.md`, `CLAUDE.md`, `docs/testing-regimen.md`, this plan, and `docs/macos-window-presentation-audit.md` completely.

### Current inventory

- [ ] Re-run searches for scenes, Settings panes/details, sheets, full-screen covers, popovers, alerts, confirmation dialogs, Quick Look/file presentations, navigation destinations, toolbar placements, focused commands, and `nativeMacModalDismissControl`.
- [ ] Create a complete inventory table. Every Mac-active presentation must receive one of the classifications in the presentation contract; screenshots are not a scope filter.
- [ ] Record which views are dual-use between a Mac window and a mobile sheet.
- [ ] Record all window-specific cleanup side effects such as stopping playback.
- [ ] Record all settings controls that persist immediately versus those with a real draft.

### Baseline checks

- [ ] Run `git diff --check`.
- [ ] From `BisonNotes AI/BisonNotes AI`, run `swiftlint lint --reporter summary` and save exact totals.
- [ ] Run the local pre-merge iOS test gate from `docs/testing-regimen.md` using a fresh `/private/tmp` DerivedData path.
- [ ] Build `BisonNotes AI macOS` with a fresh `/private/tmp` DerivedData path.
- [ ] Launch the current native Mac app and capture the nine supplied workflows plus every other reachable window/pane/presentation as the before-state if a signed/runnable build is available.

### Stop conditions

Stop if the branch/worktree is wrong, required files contain unrelated user edits, package resolution cannot be separated from source failures, the baseline native build fails, or the current persistence semantics of a displayed Save/Cancel pair cannot be established.

## Wave 1 — Lead-owned presentation foundation

The lead implements and validates the shared contract before parallel UI packages begin.

### Owned files

- `BisonNotes AI/BisonNotes AI/BisonNotesAIApp.swift`
- `BisonNotes AI/BisonNotes AI/Platform/NativeWindowRouting.swift`
- `BisonNotes AI/BisonNotes AI/AccessibilityIdentifiers.swift`
- New shared Mac presentation/close-guard file if needed
- Shared command or focused-value declarations
- Central UI-test files during integration only

### Tasks

- [ ] Add context-aware building blocks for modeless window chrome, semantic modal actions, and any scoped transcript close guard.
- [ ] Keep `nativeMacModalSizing` unless evidence shows a better system sizing API for a specific sheet.
- [ ] Do not provide another generic overlay that blindly adds Cancel or Done.
- [ ] Define shared, stable accessibility identifiers for Settings panes, transcript Save, and any close-confirmation actions.
- [ ] Add the focused Save action and File > Save command wiring for the active transcript window without interfering with text-field editing or other scenes.
- [ ] Establish a dynamic-title approach for recording-specific Summary and Transcript windows.
- [ ] Ensure Command-W retains system behavior and is not globally intercepted.
- [ ] Add DEBUG-only launch support only if necessary for deterministic native-Mac window QA; do not affect release behavior.

### Acceptance

- Shared APIs compile with empty/minimal adoption.
- No global style or delegate changes alter all windows.
- iOS continues to compile.
- Package agents have stable interfaces and do not need to edit lead-owned files.

## Wave 2 — Settings packages in parallel

Run Packages A, B, and C concurrently only after Wave 1 is green.

### Package A — Settings scene and top-level panes

Owned files:

- `BisonNotes AI/BisonNotes AI/Views/SettingsView.swift`
- `BisonNotes AI/BisonNotes AI/Views/PreferencesView.swift`
- A new Mac Settings root/pane file if useful
- A new package-specific test file if useful

Tasks:

- [ ] Build the six-pane Mac `TabView` shell and extract/reuse existing controls without duplicating storage logic.
- [ ] Keep the existing mobile `NavigationStack`, sheets, and Done behavior under non-macOS paths.
- [ ] Remove Mac `navigationDestination` routes for Preferences, AI, Transcription, Background Processing, and Acknowledgements.
- [ ] Map General, Recording, Storage, and Advanced controls from the current monolithic Settings content.
- [ ] Make the Advanced pane open the existing modeless Background Processing and iCloud Review windows.
- [ ] Restore the last selected pane and update the Settings window title.
- [ ] Verify no Back button appears in General/Preferences.

Acceptance:

- Command-comma opens one Settings window.
- All six pane controls are visible, stable, and keyboard reachable.
- General changes apply immediately and survive close/reopen.
- Background Processing opens as its modeless window, not a pushed settings page.
- No copied settings state creates two sources of truth.

### Package B — AI pane and provider details

Owned files:

- `BisonNotes AI/BisonNotes AI/AISettingsView.swift`
- `BisonNotes AI/BisonNotes AI/OpenAICompatibleSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/GoogleAIStudioSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/MistralAISettingsView.swift`
- `BisonNotes AI/BisonNotes AI/MLXSwiftSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/OllamaSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/Views/MistralOnboardingView.swift`
- A new package-specific test file if useful

Tasks:

- [ ] Make AI Settings embeddable as the AI pane without owning a Mac navigation stack.
- [ ] Replace Mac provider `navigationDestination` pushes with a stable list/detail selection inside the AI pane.
- [ ] Remove Back and Done/Save/Cancel chrome from immediate-persistence provider details.
- [ ] Preserve Keychain writes, endpoint security, model fetching, connection tests, model lifecycle, engine selection, and callbacks.
- [ ] If any field truly waits for Save, introduce a complete draft and a real transactional sheet instead of silently changing its commit timing.
- [ ] Keep Mistral onboarding as a bounded multi-step modal with Cancel, Back/Next, and Finish semantics appropriate to each step.
- [ ] Keep the detail scroller stable and avoid nesting scrolling forms.

Acceptance:

- The AI pane has no floating Back or Done controls.
- Selecting Compatible API, Google AI Studio, Mistral, MLX, Ollama, or Apple Native changes the detail without opening another window-sized navigation layer.
- A test connection uses current visible settings once and reports its result without closing the pane.
- API keys remain masked and no secret value appears in logs, tests, screenshots, or diffs.
- Existing provider availability/restoration behavior remains intact.

### Package C — Transcription pane and engine details

Owned files:

- `BisonNotes AI/BisonNotes AI/TranscriptionSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/FluidAudio/FluidAudioSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/MistralTranscribeSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/WhisperSettingsView.swift`
- A new package-specific test file if useful

Tasks:

- [ ] Make Transcription Settings embeddable as the Transcription pane.
- [ ] Replace Mac engine pushes with a stable engine list/detail selection.
- [ ] Remove the centered Back button and Mac-only Done controls.
- [ ] Preserve live transcription, selected file engine, model download/delete/cancel, speaker-label settings, server configuration, and status observation.
- [ ] Keep one explicit scroll owner and ensure model controls remain reachable at minimum Settings size.
- [ ] Preserve iOS sheets and their dismissal controls.

Acceptance:

- On-Device Transcription appears as a stable detail inside Settings with no Back/Done control.
- Parakeet and speaker-label state/progress remain non-color-readable and accessible.
- Model download cancellation and destructive deletion retain explicit roles and confirmation.
- Mistral and Whisper configuration remain reachable and persist exactly as before.

## Wave 3 — Independent window packages in parallel

Run Packages D, E, and F concurrently after Wave 2 is integrated and the shared foundation remains green.

### Package D — Transcript editor and transcript-owned modals

Owned files:

- `BisonNotes AI/BisonNotes AI/Views/TranscriptViews.swift`
- A new transcript editor state/behavior test file

Tasks:

- [ ] Implement the document-style transcript requirements above.
- [ ] Adopt the lead's focused Save action and scoped dirty-close guard.
- [ ] Remove Mac Cancel/Save navigation placements while preserving the iOS sheet toolbar.
- [ ] Replace transcript-owned modal overlays with semantic Cancel/Apply or Close behavior.
- [ ] Keep speaker rename, rerun, summary navigation, location, and imported transcript behavior intact.
- [ ] Add pure tests for dirty detection and close-decision transitions where possible.

Acceptance:

- Command-S saves once and closes only after success, without a success alert.
- Closing clean content is immediate.
- Save/Discard/Cancel protects a dirty draft; a failed Save never closes.
- Escape cancels the speaker editor but does not discard the whole transcript window.
- iOS Edit Transcript retains a clear Cancel/Save sheet flow.

### Package E — Summary window and summary-owned modals

Owned files:

- `BisonNotes AI/BisonNotes AI/SummaryDetailView.swift`
- `BisonNotes AI/BisonNotes AI/Views/NativeSummaryWindowView.swift`
- New package-specific tests if useful

Tasks:

- [ ] Remove independent-window Done and move Export to the trailing toolbar area.
- [ ] Adopt the dynamic window title.
- [ ] Standardize affected summary action buttons without changing their underlying operations.
- [ ] Rework summary-owned attachment, note, title, date, and location sheets according to the modal contract.
- [ ] Preserve focused File > Export Summary behavior and all PDF/RTF paths.

Acceptance:

- No action crowds the traffic lights.
- Export works from the toolbar and File menu.
- Command-W closes only the active Summary window.
- Multiple summaries have distinguishable titles.
- Delete, regenerate, integrations, attachments, date, and location still work.

### Package F — Activity and reference windows

Owned files:

- `BisonNotes AI/BisonNotes AI/Views/BackgroundProcessingView.swift`
- `BisonNotes AI/BisonNotes AI/Views/AudioPlayerView.swift`
- `BisonNotes AI/BisonNotes AI/Views/RecordingsListView.swift`
- `BisonNotes AI/BisonNotes AI/LocationDetailView.swift`
- New package-specific tests if useful

Tasks:

- [ ] Remove redundant Done/Close/X controls only on independent Mac-window paths.
- [ ] Keep secondary actions in standard trailing toolbars or More menus.
- [ ] Make Audio Player cleanup run on standard window close exactly once.
- [ ] Make destructive job/recording actions use roles and confirmation where appropriate.
- [ ] Preserve in-content visual styling unless changing a control is necessary to remove duplicate window dismissal or correct action semantics.
- [ ] Preserve mobile sheet dismissal and playback behavior.

Acceptance:

- Standard close works for all four window types.
- Closing Background Processing does not change jobs.
- Closing Audio Player stops/releases playback exactly once.
- Location actions and recording actions remain discoverable without a custom Close/X.
- Windows remain movable, resizable, and scrollable at minimum size.

## Wave 4 — Remaining presentation audit and integration cleanup

### Package G — Uncovered presentation surfaces

Owned files, after the lead removes any overlap with earlier packages:

- `BisonNotes AI/BisonNotes AI/ContentView.swift`
- `BisonNotes AI/BisonNotes AI/Views/RecordingsView.swift`
- `BisonNotes AI/BisonNotes AI/Views/DataMigrationView.swift`
- `BisonNotes AI/BisonNotes AI/Views/SimpleSettingsView.swift`
- `BisonNotes AI/BisonNotes AI/Views/WebImportSheet.swift`
- `BisonNotes AI/BisonNotes AI/Views/CombineRecordingsView.swift`
- `BisonNotes AI/BisonNotes AI/Views/EnhancedDeleteDialog.swift`
- `BisonNotes AI/BisonNotes AI/Views/AcknowledgementsView.swift`
- `BisonNotes AI/BisonNotes AI/IntegrationSelectionView.swift`
- `BisonNotes AI/BisonNotes AI/PerformanceOptimizer.swift`

Tasks:

- [ ] Finish the exhaustive inventory of all Mac windows, Settings panes/details, sheets, full-screen covers, popovers, alerts, confirmation dialogs, previews, file panels, and presentation commands.
- [ ] Replace remaining generic dismiss overlays with explicit surface-owned actions.
- [ ] Use semantic modal placements and honest action labels.
- [ ] Verify import, combine, migration, acknowledgement, integration, performance, and setup/onboarding flows.
- [ ] Remove `nativeMacModalDismissControl` only after its external use count reaches zero and every replaced surface has a tested close path.
- [ ] Remove or simplify stale routing comments/helpers only after call-site verification.

Acceptance:

- No true modal is trapped.
- No modeless window carries a redundant Done/Close control.
- No Mac settings flow displays the centered Back button.
- No view shows Back, Cancel, and Done simultaneously.
- Escape/Command-period and default actions behave according to the surface classification.
- The final inventory contains no unclassified Mac presentation surface.

## Per-package validation

Every agent runs and reports:

```bash
git diff --check
swiftc -parse "path/to/each/changed.swift"
```

Run changed-file SwiftLint as practical and report exact violations. Do not treat the committed baseline or a zero process exit as proof that the whole repository has no violations.

After each wave, the lead runs from the repository root with fresh, wave-specific `/private/tmp` paths:

```bash
xcodebuild -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI macOS" \
  -destination 'platform=macOS' \
  -configuration Debug \
  -derivedDataPath /private/tmp/bisonnotes-macoslook-mac-derived \
  build

xcodebuild test \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /private/tmp/bisonnotes-macoslook-ios-tests
```

Serialize package resolution and Xcode builds if they share caches. A parse pass is syntax evidence only. A build is not executed XCTest, and neither is visual QA.

## Lead integration checklist

After every agent report:

- [ ] Inspect the diff rather than accepting the summary.
- [ ] Confirm exclusive file ownership and no unrelated formatting churn.
- [ ] Re-run changed presentation call-site searches.
- [ ] Verify every removed dismiss control has another proven close path.
- [ ] Verify dual-use views still present correctly on iPhone/iPad.
- [ ] Verify immediate Settings persistence and callbacks were not silently changed.
- [ ] Verify no secret value or realistic credential entered tests, logs, screenshots, or diffs.
- [ ] Run the wave build/tests before releasing dependent packages.
- [ ] Keep implementation commits logical only if the user later authorizes commits.

## Native Mac manual QA matrix

Use a signed or locally runnable native Mac app. Automated builds do not satisfy this matrix.

### Window chrome and commands

- [ ] Edit Transcript: no button beside traffic lights; dynamic title; Save toolbar action; Save and Command-S close only after success; clean close; dirty Save/Discard/Cancel; failed-save retention.
- [ ] Summary: no Done; trailing Export; File > Export Summary; Command-W; multiple titled windows.
- [ ] Background Processing: no Done; trailing More menu; close/reopen while jobs continue.
- [ ] Processing Job: no Done; active job cancellation remains explicit.
- [ ] Audio Player: no full-width Close in its modeless window; window close stops playback once.
- [ ] Recordings: no custom X; actions remain in toolbar/menu.
- [ ] Location: no Done; Open in Maps and Copy Coordinates work.
- [ ] iCloud Review and any other independent window: standard close and scroll behavior.

### Settings

- [ ] Command-comma opens the Settings scene.
- [ ] Six panes are visible in the toolbar, selected state is obvious, and the title follows the pane.
- [ ] Closing and reopening restores the last pane.
- [ ] General/Preferences has no Back button.
- [ ] Transcription and every engine detail have no Back/Done control.
- [ ] AI and every provider detail have no Back/Done control.
- [ ] Immediate changes persist after switching panes and reopening Settings.
- [ ] Background Processing opens/activates its independent window.
- [ ] Model operations and connection tests remain explicit and do not trigger on pane selection.

### Modal workflows

- [ ] Speaker editor: Cancel/Escape and Apply/Return.
- [ ] Note, title, date, and location editors: honest Cancel plus Save/Apply.
- [ ] Read-only attachment: Close/Escape.
- [ ] Import, combine, migration, and provider onboarding: clear Cancel/Back/Next/Finish progression with no trapped or stacked sheet.
- [ ] Destructive actions show confirmation and safe cancellation.

### Layout and accessibility

- [ ] Test default, minimum, wide, half-screen, third-screen, and maximized sizes.
- [ ] Test light and dark appearance, Increase Contrast, Reduce Transparency, and keyboard focus visibility.
- [ ] Verify Full Keyboard Access, Tab/Shift-Tab order, VoiceOver names/roles, and no color-only status.
- [ ] Verify all scrollbars and critical controls remain reachable.
- [ ] Verify icon-only actions have labels and help.
- [ ] Recapture the nine supplied screenshot states for before/after comparison.

### Mobile regression

- [ ] On iPhone and iPad, Settings still uses the expected mobile navigation/sheets.
- [ ] Edit Transcript still has clear Cancel/Save controls.
- [ ] Summary, audio, location, background, and modal flows remain dismissible.
- [ ] Run the seeded accessibility/UI smoke coverage from `docs/testing-regimen.md`.

## Final acceptance gate

- [ ] Branch is still `macoslook`; worktree contains only intended plan/implementation changes.
- [ ] `git diff --check` passes.
- [ ] Full SwiftLint introduces no new violations relative to Wave 0.
- [ ] Native macOS Debug build passes.
- [ ] iOS unit, security, seeded UI, launch, and accessibility tests execute and pass, or the exact environmental blocker is reported separately.
- [ ] Native Mac manual QA matrix is complete with screenshots and exact failures/deferred items.
- [ ] Search confirms no external uses of `nativeMacModalDismissControl`, unless a reviewed exception documents why the overlay is still necessary.
- [ ] Search confirms every remaining Mac-active positional navigation-bar placement is intentional and mobile-only or has a documented reason.
- [ ] The exhaustive presentation inventory confirms every native-Mac window, pane, detail, sheet, popover, alert, confirmation, preview, and file presentation was reviewed and has an assigned contract.
- [ ] Standard window close, Command-W, Command-S, Escape/Command-period, Return/default action, and destructive confirmations are all verified in their applicable contexts.
- [ ] No provider, persistence, transcription, summary-generation, playback, job, iCloud, or model-lifecycle behavior changed outside the documented UX contract.
- [ ] Final report lists packages integrated, exact test/build results, manual evidence, residual risks, and commit SHAs only if commits were later authorized.

## Explicitly out of scope

- Changing macOS deployment target or adopting an SDK-only visual effect that excludes macOS 15.
- Redesigning summary text, AI prompts, transcript reconciliation, model catalogs, persistence, CloudKit, or provider networking.
- Replacing standard traffic-light controls or creating borderless/custom title bars.
- A full typography, color-palette, or branding redesign.
- Restyling mobile-looking cards, colorful content buttons, badges, status blocks, or other in-content visuals; schedule that as a separate pass.
- macOS hardware, model-quality, provider-service, or CloudKit certification beyond the focused smoke checks required by touched behavior.
- Commit, push, pull request, or release work without separate user authorization.
