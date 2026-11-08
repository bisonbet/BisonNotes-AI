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

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
