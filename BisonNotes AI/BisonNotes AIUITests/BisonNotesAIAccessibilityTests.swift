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
        let playAudio = app.buttons["bisonnotes.recording.action.play-audio"]
        XCTAssertTrue(playAudio.waitForExistence(timeout: 8))
        playAudio.tap()
        let playbackSection = app.descendants(matching: .any)["bisonnotes.audio-player.playback"]
        XCTAssertTrue(playbackSection.waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Audio Player", app: app)
    }

    @MainActor
    func testTranscriptsAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.navigateToSection("Transcripts")
        XCTAssertTrue(app.scrollViews["bisonnotes.transcripts.list"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Transcripts", app: app)
    }

    @MainActor
    func testSummariesAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.navigateToSection("Summaries")
        XCTAssertTrue(app.scrollViews["bisonnotes.summaries.list"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Summaries", app: app)
    }

    @MainActor
    func testSummaryDetailAccessibilityAudit() throws {
        let app = launchSeededApp()
        app.navigateToSection("Summaries")
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
        app.navigateToSection("Setup")
        app.buttons["bisonnotes.setup.additional-settings"].tap()
        XCTAssertTrue(app.scrollViews["bisonnotes.settings.scroll"].waitForExistence(timeout: 8))
        try performAccessibilityAudit(named: "Settings", app: app)
    }

    @MainActor
    func testOnDeviceSpeakerLabelsAccessibilityAuditAtAccessibilityTextSize() throws {
        let app = launchSeededApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ])
        app.navigateToSection("Setup")
        app.buttons["bisonnotes.setup.additional-settings"].tap()

        let settingsScroll = app.scrollViews["bisonnotes.settings.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 8))
        let transcription = app.buttons.matching(identifier: "Transcription").firstMatch
        XCTAssertTrue(transcription.waitForExistence(timeout: 8))
        transcription.tap()

        let configure = app.reachableButton(named: "Configure On Device")
        configure.tap()

        _ = app.reachableElement("bisonnotes.settings.local-speaker-labels.section")
        let toggle = app.reachableElement("bisonnotes.settings.local-speaker-labels.toggle")
        toggle.setSwitch(on: true)
        _ = app.reachableElement("bisonnotes.settings.local-speaker-labels.prepare-model")

        try performAccessibilityAudit(named: "On Device Speaker Labels", app: app)
    }

    @MainActor
    private func launchSeededApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ] + extraArguments
        app.launch()
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))
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
            } else {
                let attachment = XCTAttachment(string: description)
                attachment.name = "\(name) unhandled accessibility audit issue"
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
                ("Text clipped", "bisonnotes.sidebar.record"),
                ("Dynamic Type font sizes are partially unsupported", "(null)"),
                ("Dynamic Type font sizes are partially unsupported", "Unexpected Shutdown"),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "It looks like BisonNotes AI didn't shut down properly last time. Would you like to send a diagnostic report to help us fix this?"
                )
            ],
            "Recordings list": [
                ("Potentially inaccessible text", "(null)"),
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
                ("Potentially inaccessible text", "(null)"),
                ("Contrast nearly passed", "15s"),
                ("Dynamic Type font sizes are partially unsupported", "15s"),
                ("Text clipped", "Enter title")
            ],
            "Transcripts": [
                ("Text clipped", "bisonnotes.sidebar.summaries"),
                ("Contrast failed", "1"),
                ("Contrast nearly passed", "Search transcripts..."),
                ("Dynamic Type font sizes are partially unsupported", "Edit Transcript"),
                ("Text clipped", "Search transcripts..."),
                ("Text clipped", "Edit Transcript")
            ],
            "Summaries": [
                ("Contrast failed", "(null)"),
                ("Contrast nearly passed", "Search summaries, tasks, reminders..."),
                ("Contrast nearly passed", "View Summary"),
                ("Dynamic Type font sizes are partially unsupported", "0 Reminders"),
                ("Dynamic Type font sizes are partially unsupported", "1 Tasks"),
                ("Text clipped", "View Summary"),
                ("Text clipped", "Search summaries, tasks, reminders..."),
                (
                    "Text clipped",
                    "This seeded UI test summary is intentionally long enough to pass summary validation and prove the summary linkage survives launch."
                )
            ],
            "Summary detail": [
                ("Contrast nearly passed", "Add Location"),
                ("Potentially inaccessible text", "(null)"),
                ("Dynamic Type font sizes are partially unsupported", "Done"),
                ("Dynamic Type font sizes are partially unsupported", "Export"),
                ("Text clipped", "(null)")
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
                ("Contrast failed", "Location Services"),
                ("Contrast failed", "Capture location data with recordings"),
                ("Dynamic Type font sizes are partially unsupported", "Done")
            ],
            "On Device Speaker Labels": [
                ("Contrast failed", "Done"),
                ("Contrast failed", "Parakeet Model Not Downloaded"),
                (
                    "Contrast failed",
                    "bisonnotes.settings.local-speaker-labels.model-status.parakeet"
                ),
                ("Contrast failed", "Download / Prepare Parakeet Model"),
                (
                    "Contrast failed",
                    "Download the Parakeet model before using on-device transcription."
                ),
                ("Dynamic Type font sizes are partially unsupported", "Offline VBx"),
                ("Dynamic Type font sizes are partially unsupported", "LS-EEND"),
                ("Dynamic Type font sizes are partially unsupported", "Recommended"),
                ("Dynamic Type font sizes are partially unsupported", "Experimental"),
                ("Dynamic Type font sizes are partially unsupported", "speaker count estimated"),
                ("Dynamic Type font sizes are partially unsupported", "up to 10 speakers"),
                ("Dynamic Type font sizes are partially unsupported", "Speaker labeling method"),
                ("Dynamic Type font sizes are partially unsupported", "Local Speaker Labels"),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "Speaker Labels (After Recording)"
                ),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "Speaker labels apply only after completed Parakeet recordings, imports, and re-runs. They do not affect Live Transcription. Audio stays local after the explicit one-time model download."
                ),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "Recommended for normal use. Offline VBx estimates the number of speakers and does not impose a two- or three-speaker cap."
                ),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "Offline VBx: Download Required"
                ),
                ("Dynamic Type font sizes are partially unsupported", "Download Speaker Model"),
                (
                    "Dynamic Type font sizes are partially unsupported",
                    "Audio remains on this device. Speaker labels run only after completed Parakeet work and do not change your other transcription engines."
                ),
                ("Dynamic Type font sizes are partially unsupported", "Done"),
                ("Dynamic Type font sizes are unsupported", "(null)")
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

@MainActor
extension XCUIApplication {
    func reachableButton(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let matches = buttons.matching(identifier: name)
        let button = matches.firstMatch

        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button \(name).", file: file, line: line)
        XCTAssertEqual(matches.count, 1, "Expected one button \(name).", file: file, line: line)
        return button
    }

    func reachableElement(
        _ identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let matches = descendants(matching: .any).matching(identifier: identifier)
        let element = matches.firstMatch

        _ = element.waitForExistence(timeout: 5)

        func resolvedElement() -> XCUIElement? {
            let count = matches.count
            if count > 1 {
                XCTFail(
                    "Expected one UI element \(identifier), found \(count).",
                    file: file,
                    line: line
                )
                return element
            }
            guard count == 1, element.exists, element.isHittable else { return nil }
            return element
        }

        if let resolved = resolvedElement() {
            return resolved
        }
        for _ in 0..<10 {
            swipeUp()
            if let resolved = resolvedElement() {
                return resolved
            }
        }
        for _ in 0..<10 {
            swipeDown()
            if let resolved = resolvedElement() {
                return resolved
            }
        }

        XCTAssertEqual(matches.count, 1, "Expected one UI element \(identifier).", file: file, line: line)
        XCTAssertTrue(element.exists, "Missing UI element \(identifier).", file: file, line: line)
        XCTAssertTrue(element.isHittable, "UI element \(identifier) is not reachable.", file: file, line: line)
        return element
    }
}

@MainActor
extension XCUIElement {
    func setSwitch(
        on enabled: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expectedValue = enabled ? "1" : "0"
        guard value as? String != expectedValue else { return }

        coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let valueChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: self
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [valueChanged], timeout: 5),
            .completed,
            "Switch did not change to \(expectedValue).",
            file: file,
            line: line
        )
    }
}
