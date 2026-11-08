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
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))

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
            let back = app.navigationBars.buttons["Summaries"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))

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
        let viewRecordings = app.buttons["bisonnotes.record.view-recordings"]
        XCTAssertTrue(viewRecordings.waitForExistence(timeout: 20))
        viewRecordings.tap()

        let play = app.buttons["Play Audio for UI Test Recording"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        let isRegularWidth = app.windows.firstMatch.frame.width >= 700
        attachScreenshot(of: app, named: isRegularWidth ? "regular-library" : "compact-library")

        play.tap()

        let closePlayer = app.buttons["Close Audio Player"]
        XCTAssertTrue(closePlayer.waitForExistence(timeout: 8))
        attachScreenshot(of: app, named: isRegularWidth ? "regular-library-and-player" : "compact-player-pushed")

        // Close returns to the library either way.
        closePlayer.tap()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertTrue(play.isHittable)
        XCTAssertFalse(closePlayer.exists)
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
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))
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
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))
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
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))
        app.navigateToSection("Transcripts")
        attachScreenshot(of: app, named: "relaunch-transcripts")

        if editor.waitForExistence(timeout: 3) {
            app.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        }

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

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
