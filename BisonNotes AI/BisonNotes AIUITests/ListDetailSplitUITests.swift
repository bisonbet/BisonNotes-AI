//
//  ListDetailSplitUITests.swift
//  BisonNotes AIUITests
//
//  M3 of docs/iphone-duo-implementation-plan.md: at regular width (iPad,
//  iPhone Duo's inner display) a summary opens beside the list; at compact
//  width it pushes and Back returns to the list.
//

import XCTest

final class ListDetailSplitUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSummaryOpensBesideListOrPushes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()

        app.navigateToSection("Summaries")

        let viewSummary = app.buttons["View Summary for UI Test Recording"]
        XCTAssertTrue(viewSummary.waitForExistence(timeout: 8))

        let isRegularWidth = app.windows.firstMatch.frame.width >= 700
        if isRegularWidth {
            XCTAssertTrue(
                app.staticTexts["Select a Summary"].waitForExistence(timeout: 5),
                "The detail column should invite a selection before one is made."
            )
        }

        viewSummary.tap()

        let detail = app.descendants(matching: .any)["bisonnotes.summary.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Done"].exists, "An embedded summary has nothing to dismiss.")
        attachScreenshot(of: app, named: isRegularWidth ? "regular-list-and-summary" : "compact-summary-pushed")

        if isRegularWidth {
            XCTAssertTrue(viewSummary.isHittable, "The list should stay visible beside the summary.")
        } else {
            XCTAssertFalse(viewSummary.isHittable, "At compact width the summary is pushed over the list.")
            // On iPhone Duo the system Back sits in the vertical side strip with
            // no "Summaries" label, so find it by its system identifier too.
            let back = app.buttons.matching(
                NSPredicate(format: "identifier == 'BackButton' OR (label == 'Summaries' AND NOT (identifier BEGINSWITH 'bisonnotes.sidebar'))")
            ).allElementsBoundByIndex.first(where: { $0.isHittable && $0.identifier != "bisonnotes.sidebar.summaries" })
                ?? app.navigationBars.buttons["Summaries"]
            XCTAssertTrue(back.waitForExistence(timeout: 5), "No Back button from the pushed summary")
            back.tap()
            XCTAssertTrue(viewSummary.waitForExistence(timeout: 5))
            XCTAssertTrue(viewSummary.isHittable)
            XCTAssertFalse(detail.exists)
        }
    }

    @MainActor
    func testTranscriptOpensBesideListOrPushes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()

        app.navigateToSection("Transcripts")

        let editTranscript = app.buttons["Edit Transcript for UI Test Recording"]
        XCTAssertTrue(editTranscript.waitForExistence(timeout: 8))

        let isRegularWidth = app.windows.firstMatch.frame.width >= 700
        if isRegularWidth {
            XCTAssertTrue(app.staticTexts["Select a Transcript"].waitForExistence(timeout: 5))
        }

        editTranscript.tap()

        let editor = app.descendants(matching: .any)["bisonnotes.transcript.detail"]
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        attachScreenshot(of: app, named: isRegularWidth ? "regular-list-and-transcript" : "compact-transcript-pushed")

        if isRegularWidth {
            XCTAssertTrue(editTranscript.isHittable, "The list should stay visible beside the transcript.")
        } else {
            XCTAssertFalse(editTranscript.isHittable, "At compact width the transcript is pushed over the list.")
            XCTAssertFalse(
                app.navigationBars.buttons["Transcripts"].exists,
                "The system Back would skip the unsaved-edits prompt, so Cancel replaces it."
            )
        }

        // With no edits, Cancel closes straight away.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(editTranscript.waitForExistence(timeout: 5))
        XCTAssertTrue(editTranscript.isHittable)
        XCTAssertFalse(editor.exists)
    }

    @MainActor
    func testRecordingPlayerOpensBesideLibraryOrPushes() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        let viewRecordings = app.buttons["bisonnotes.record.view-recordings"]
        viewRecordings.tap()

        let play = app.buttons["Play Audio for UI Test Recording"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        let isRegularWidth = app.windows.firstMatch.frame.width >= 700
        attachScreenshot(of: app, named: isRegularWidth ? "regular-library" : "compact-library")

        play.tap()

        // The playback section's container identifier hides its buttons' own,
        // so the play button is found by its label.
        let transport = app.buttons.matching(NSPredicate(format: "label == 'Play Audio' OR label == 'Pause Audio'")).firstMatch
        XCTAssertTrue(transport.waitForExistence(timeout: 8), "The player did not open")
        XCTAssertTrue(transport.isHittable, "The player's play button is off screen")
        XCTAssertFalse(
            app.staticTexts["Audio Player"].exists,
            "In the library's column the player uses the recording's title, not its own header"
        )
        attachScreenshot(of: app, named: isRegularWidth ? "regular-library-and-player" : "compact-player-pushed")

        // Beside the library there is no Back, so the player has a Close;
        // pushed, Back returns to the library.
        let closePlayer = app.buttons["Close Audio Player"]
        if closePlayer.waitForExistence(timeout: 2) {
            closePlayer.tap()
        } else {
            let back = app.buttons.matching(NSPredicate(format: "identifier == 'BackButton'"))
                .allElementsBoundByIndex.first(where: \.isHittable)
            XCTAssertNotNil(back, "No way back from the pushed player")
            back?.tap()
        }
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        XCTAssertFalse(transport.exists)
    }

    /// A real library: several transcripts, date sections and a "Show N more" page.
    /// Every way of opening a transcript must open the editor — the first row,
    /// a second transcript after closing one, switching while one is open, and
    /// a row on the full-list page.
    @MainActor
    func testEveryTranscriptInALibraryOpensItsEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--seed-sample-library",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        app.navigateToSection("Transcripts")

        let editor = app.descendants(matching: .any)["bisonnotes.transcript.detail"]
        let isRegularWidth = app.windows.firstMatch.frame.width >= 700

        func open(_ name: String, step: String) {
            // The same row can be on the main page and on a pushed page; tap the
            // copy the user can actually see.
            let matches = app.buttons.matching(NSPredicate(format: "label == %@", "Edit Transcript for \(name)"))
            let anyMatch = app.buttons["Edit Transcript for \(name)"]
            XCTAssertTrue(anyMatch.waitForExistence(timeout: 8), "\(step): no Edit Transcript button for \(name)")
            let button = matches.allElementsBoundByIndex.last(where: \.isHittable) ?? anyMatch
            button.tap()
            XCTAssertTrue(
                editor.waitForExistence(timeout: 5),
                "\(step): tapping Edit Transcript for \(name) did not open the editor"
            )
            XCTAssertTrue(
                app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch.waitForExistence(timeout: 5)
                    || app.staticTexts[name].exists,
                "\(step): the editor is not showing \(name)"
            )
        }

        func closeEditor() {
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Cancel did not close the editor")
        }

        open("Library Recording 1", step: "first row")
        attachScreenshot(of: app, named: "library-first-transcript")
        closeEditor()

        open("Library Recording 2", step: "second transcript after closing the first")
        if isRegularWidth {
            // The list stays beside the editor, so the next row is right there.
            open("Library Recording 3", step: "switching while one is open")
        }
        closeEditor()

        let showMore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' more transcripts'")).firstMatch
        XCTAssertTrue(showMore.waitForExistence(timeout: 5), "No Show N more row for a seven-transcript library")
        showMore.tap()
        // Only Today's section starts expanded on the full-list page.
        open("Library Recording 1", step: "a row on the full-list page")
        attachScreenshot(of: app, named: "library-full-list-transcript")
        closeEditor()

        // Back from the full list returns to the short list.
        let back = app.buttons["bisonnotes.transcripts.full-list.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The full transcript list has no way back")
        back.tap()
        XCTAssertTrue(showMore.waitForExistence(timeout: 5))

        // Summaries has the same "Show N more" page.
        app.navigateToSection("Summaries")
        let showMoreSummaries = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Show ' AND label ENDSWITH ' more summaries'")
        ).firstMatch
        XCTAssertTrue(showMoreSummaries.waitForExistence(timeout: 5), "No Show N more row for summaries")
        showMoreSummaries.tap()
        let viewSummary = app.buttons.matching(
            NSPredicate(format: "label == %@", "View Summary for Library Recording 1")
        ).allElementsBoundByIndex.last(where: \.isHittable)
        XCTAssertNotNil(viewSummary, "No visible View Summary button on the full summary list")
        viewSummary?.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["bisonnotes.summary.detail"].waitForExistence(timeout: 5),
            "A summary on the full-list page did not open"
        )
    }

    /// The selection is kept in scene storage, so a relaunch can come back with
    /// a transcript still selected. Every tap after that must open the editor —
    /// the selected transcript and any other. A leftover selection with the list
    /// on screen used to swallow every tap.
    @MainActor
    func testEditTranscriptStillOpensAfterARelaunchRestoresASelection() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--seed-sample-library",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        app.navigateToSection("Transcripts")

        let editor = app.descendants(matching: .any)["bisonnotes.transcript.detail"]
        let first = app.buttons["Edit Transcript for Library Recording 2"]
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        first.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        // Backgrounding saves scene storage; then relaunch on the same data.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--disable-cloud-services"]
        app.launch()
        // Scene storage comes back only if the system restored the scene. The
        // tab is scene-stored too, so a launch back on Transcripts is the proof;
        // without it this simulator did not restore, and nothing here can be
        // checked.
        let editorRestored = editor.waitForExistence(timeout: 10)
        // iPad's floating tab bar exposes each tab as two nested buttons with
        // the same identifier.
        let transcriptsTab = app.buttons["bisonnotes.sidebar.transcripts"].firstMatch
        let sceneRestored = editorRestored || (transcriptsTab.waitForExistence(timeout: 5) && transcriptsTab.isSelected)
        attachScreenshot(of: app, named: "relaunch-transcripts")
        if !sceneRestored {
            throw XCTSkip("The system did not restore the scene on relaunch, so scene storage was not exercised")
        }

        // The open transcript comes back: scene storage keeps the selection, and
        // nothing on the way through a relaunch may clear it.
        XCTAssertTrue(
            editor.waitForExistence(timeout: 8),
            "The transcript open before the relaunch was not restored"
        )
        XCTAssertTrue(
            app.textFields.matching(NSPredicate(format: "value == %@", "Library Recording 2")).firstMatch.exists
                || app.staticTexts["Library Recording 2"].exists,
            "The restored editor is not showing the transcript that was open"
        )
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))

        for name in ["Library Recording 2", "Library Recording 3"] {
            let button = app.buttons["Edit Transcript for \(name)"]
            XCTAssertTrue(button.waitForExistence(timeout: 8), "No Edit Transcript button for \(name)")
            button.tap()
            XCTAssertTrue(
                editor.waitForExistence(timeout: 5),
                "After a relaunch, Edit Transcript for \(name) did not open the editor"
            )
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        }
    }

    /// The editor hides the system Back because leaving must go through its
    /// Save/Discard prompt. The collapsed split view's edge swipe, and the column
    /// moving to the list for any other reason, must not get around that: a
    /// completed pop destroys the edits.
    @MainActor
    func testADirtyTranscriptCannotBeSwipedAwayWithoutThePrompt() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        guard app.windows.firstMatch.frame.width < 700 else {
            throw XCTSkip("Only a collapsed split view pushes the editor")
        }
        app.navigateToSection("Transcripts")

        let editor = app.descendants(matching: .any)["bisonnotes.transcript.detail"]
        app.buttons["Edit Transcript for UI Test Recording"].tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))

        // The segment's editor carries the segment's label ("Speaker 1, starts at
        // 0:00"); the first text view in the hierarchy is not necessarily it.
        let segment = app.textViews.matching(
            NSPredicate(format: "label CONTAINS 'starts at' OR label BEGINSWITH 'Transcript segment'")
        ).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "No editable transcript segment")
        segment.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "The segment did not take focus")
        app.typeText(" unsaved-edit-marker")

        // Prove the editor is dirty the way a user would see it: Cancel asks.
        let prompt = app.staticTexts["Save Changes to Transcript?"]
        // The dialog's cancel is not a button the toolbar's "Cancel" can be told
        // apart from, so "keep editing" dismisses the dialog itself.
        func keepEditing() {
            // On iPhone the dialog is a popover whose cancel is a tap outside it.
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            if dismissRegion.exists {
                dismissRegion.tap()
            } else {
                app.sheets.buttons["Cancel"].tap()
            }
        }
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "Typing did not make the editor dirty")
        keepEditing()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        attachScreenshot(of: app, named: "dirty-editor-before-swipe")

        // A left-edge swipe, as the system Back gesture.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        attachScreenshot(of: app, named: "dirty-editor-after-swipe")

        if prompt.waitForExistence(timeout: 2) {
            // Refusing the swipe may surface the editor's own prompt; stay.
            keepEditing()
        }
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "An edge swipe removed the dirty editor")

        // The edit survived: Cancel still asks, and Discard is what finally leaves.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "The swipe discarded the unsaved edit")
        app.buttons["Discard Changes"].firstMatch.tap()
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
    }

    /// Going back to the list keeps the selection (only the detail's own close
    /// ends it) but is remembered, so a relaunch shows the list rather than
    /// reopening what the user closed.
    @MainActor
    func testBackFromASummarySurvivesARelaunchWithoutReopeningIt() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        guard app.windows.firstMatch.frame.width < 700 else {
            throw XCTSkip("Only a collapsed split view has a Back to the list")
        }
        app.navigateToSection("Summaries")

        let viewSummary = app.buttons["View Summary for UI Test Recording"]
        let detail = app.descendants(matching: .any)["bisonnotes.summary.detail"]
        XCTAssertTrue(viewSummary.waitForExistence(timeout: 8))
        viewSummary.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5))

        let back = app.buttons.matching(
            NSPredicate(format: "identifier == 'BackButton' OR (label == 'Summaries' AND NOT (identifier BEGINSWITH 'bisonnotes.sidebar'))")
        ).allElementsBoundByIndex.first(where: \.isHittable)
        XCTAssertNotNil(back, "No Back from the pushed summary")
        back?.tap()
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--disable-cloud-services"]
        app.launch()
        XCTAssertTrue(app.buttons["bisonnotes.sidebar.summaries"].waitForExistence(timeout: 20))
        app.navigateToSection("Summaries")

        XCTAssertTrue(viewSummary.waitForExistence(timeout: 8))
        XCTAssertFalse(detail.exists, "A summary the user went back from reopened after a relaunch")
        viewSummary.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "The summary did not open again after the relaunch")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
