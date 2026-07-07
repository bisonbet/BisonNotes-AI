//
//  BisonNotesAIAccessibilityTests.swift
//  BisonNotes AIUITests
//

import XCTest

final class BisonNotesAIAccessibilityTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordScreenAccessibilityAudit() throws {
        let app = launchSeededApp()
        try performAccessibilityAudit(named: "Record", app: app)
    }

    @MainActor
    func testRecordingsListAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.buttons["bisonnotes.record.view-recordings"].tap()
        XCTAssertTrue(app.scrollViews["bisonnotes.recordings.list"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Recordings list", app: app)
    }

    @MainActor
    func testAudioPlayerAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.buttons["bisonnotes.record.view-recordings"].tap()
        XCTAssertTrue(app.buttons["Play Audio for UI Test Recording"].waitForExistence(timeout: 8))
        app.buttons["Play Audio for UI Test Recording"].tap()
        XCTAssertTrue(app.otherElements["bisonnotes.audio-player.playback"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Audio Player", app: app)
    }

    @MainActor
    func testTranscriptsAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.tabBars.buttons["Transcripts"].tap()
        XCTAssertTrue(app.scrollViews["bisonnotes.transcripts.list"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Transcripts", app: app)
    }

    @MainActor
    func testSummariesAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.tabBars.buttons["Summaries"].tap()
        XCTAssertTrue(app.scrollViews["bisonnotes.summaries.list"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Summaries", app: app)
    }

    @MainActor
    func testSummaryDetailAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.tabBars.buttons["Summaries"].tap()
        XCTAssertTrue(app.buttons["View Summary for UI Test Recording"].waitForExistence(timeout: 8))
        app.buttons["View Summary for UI Test Recording"].tap()
        XCTAssertTrue(app.collectionViews["bisonnotes.summary.detail"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Summary detail", app: app)
    }

    @MainActor
    func testSetupAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--disable-cloud-services",
            "--show-first-setup"
        ]
        app.launch()
        XCTAssertTrue(app.scrollViews["bisonnotes.setup.scroll"].waitForExistence(timeout: 20))
        try performAccessibilityAudit(named: "Setup", app: app)
    }

    @MainActor
    func testSettingsAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.tabBars.buttons["Setup"].tap()
        app.buttons["bisonnotes.setup.additional-settings"].tap()
        XCTAssertTrue(app.scrollViews["bisonnotes.settings.scroll"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Settings", app: app)
    }

    @MainActor
    private func launchSeededApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["bisonnotes.app.ready"].waitForExistence(timeout: 20))
        return app
    }

    @MainActor
    private func performAccessibilityAudit(named name: String, app: XCUIApplication) throws {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("Accessibility audits require iOS 17 or newer.")
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) accessibility audit screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        try app.performAccessibilityAudit { issue in
            let description = String(describing: issue)
            let isDocumentedException = self.documentedAuditException(description)

            if isDocumentedException {
                let attachment = XCTAttachment(string: description)
                attachment.name = "\(name) documented accessibility audit exception"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }

            return isDocumentedException
        }
    }

    private func documentedAuditException(_ description: String) -> Bool {
        // Current baseline exceptions are visual-audit prompts that still need the
        // manual device checks in docs/testing-regimen.md before App Store labels
        // are claimed for a release.
        description.contains("Dynamic Type font sizes are partially unsupported")
            || description.contains("Contrast failed")
            || description.contains("Contrast nearly passed")
            || description.contains("Text clipped")
    }
}
