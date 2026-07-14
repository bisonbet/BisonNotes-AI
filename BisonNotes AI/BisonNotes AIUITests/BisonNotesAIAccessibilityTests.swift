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
            let isDocumentedException = self.documentedAuditException(
                screen: name,
                description: description
            )

            if isDocumentedException {
                let attachment = XCTAttachment(string: description)
                attachment.name = "\(name) documented accessibility audit exception"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }

            return isDocumentedException
        }
    }

    private func documentedAuditException(screen: String, description: String) -> Bool {
        // These are exact screen, issue, and element exceptions captured by the
        // release audit. A new issue type or a new affected element must fail.
        let exceptions: [String: [(issue: String, element: String)]] = [
            "Record": [
                ("Dynamic Type font sizes are partially unsupported", "(null)"),
                ("Dynamic Type font sizes are partially unsupported", "Unexpected Shutdown"),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "It looks like BisonNotes AI didn't shut down properly last time. Would you like to send a diagnostic report to help us fix this?"
                )
            ],
            "Recordings list": [
                ("Dynamic Type font sizes are partially unsupported", "0:02"),
                ("Dynamic Type font sizes are partially unsupported", "Complete"),
                ("Dynamic Type font sizes are partially unsupported", "132 KB"),
                ("Dynamic Type font sizes are partially unsupported", "Feb 25, 2026 at 1:13 AM"),
                ("Text clipped", "1 recording"),
                ("Text clipped", "0:02"),
                ("Text clipped", "Feb 25, 2026 at 1:13 AM"),
                ("Text clipped", "132 KB")
            ],
            "Audio Player": [
                ("Contrast nearly passed", "15s"),
                ("Dynamic Type font sizes are partially unsupported", "15s"),
                ("Text clipped", "Enter title")
            ],
            "Transcripts": [
                ("Contrast nearly passed", "Search transcripts..."),
                ("Dynamic Type font sizes are partially unsupported", "bisonnotes.app.ready"),
                ("Dynamic Type font sizes are partially unsupported", "Edit Transcript"),
                ("Text clipped", "Search transcripts..."),
                ("Text clipped", "bisonnotes.app.ready"),
                ("Text clipped", "Edit Transcript")
            ],
            "Summaries": [
                ("Contrast nearly passed", "Search summaries, tasks, reminders..."),
                ("Contrast nearly passed", "View Summary"),
                ("Dynamic Type font sizes are partially unsupported", "0 Reminders"),
                ("Dynamic Type font sizes are partially unsupported", "bisonnotes.app.ready"),
                ("Dynamic Type font sizes are partially unsupported", "1 Tasks"),
                ("Text clipped", "bisonnotes.app.ready"),
                ("Text clipped", "View Summary"),
                ("Text clipped", "Search summaries, tasks, reminders..."),
                (
                    "Text clipped",
                    "This seeded UI test summary is intentionally long enough to pass summary validation and prove the summary linkage survives launch."
                )
            ],
            "Summary detail": [
                ("Contrast nearly passed", "Add Location"),
                ("Dynamic Type font sizes are partially unsupported", "Done"),
                ("Dynamic Type font sizes are partially unsupported", "Export")
            ],
            "Setup": [
                ("Contrast failed", "BisonNotes AI"),
                ("Contrast failed", "Choose how recordings become transcripts, summaries, tasks, and reminders."),
                ("Contrast failed", "Processing Method"),
                ("Contrast failed", "Pick the default path for new audio notes."),
                ("Contrast failed", "On-Device AI Setup"),
                ("Contrast failed", "Private processing for users who want recordings and summaries to stay local."),
                ("Contrast failed", "Setup Process"),
                ("Contrast failed", "Step 1: Download transcription model (150-520MB)"),
                ("Contrast failed", "Step 2: Download AI summary model (2-3GB)"),
                ("Contrast failed", "Total storage needed: ~3.5GB"),
                ("Contrast failed", "Important Notes"),
                ("Contrast failed", "Best for recordings under 60 minutes"),
                ("Contrast failed", "May be less accurate than cloud services"),
                ("Contrast failed", "Save & Configure"),
                ("Contrast failed", "On-Device AI"),
                ("Contrast failed", "Private, on-device AI processing"),
                ("Text clipped", "Private, on-device AI processing"),
                ("Text clipped", "Save & Configure")
            ],
            "Settings": [
                ("Contrast failed", "Refresh Microphones"),
                ("Dynamic Type font sizes are partially unsupported", "Done")
            ]
        ]

        return exceptions[screen, default: []].contains { exception in
            let issueToken = "CompactDescription:\"\(exception.issue)\""
            let elementToken = exception.element == "(null)"
                ? "Element:(null)"
                : "Element:\"\(exception.element)\""
            return description.contains(issueToken) && description.contains(elementToken)
        }
    }
}
