import XCTest

final class RecordingReadabilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLightRecordingsAndTranscriptionOptionsContrast() throws {
        try checkReadability(appearance: .light)
    }

    @MainActor
    func testDarkRecordingsAndTranscriptionOptionsContrast() throws {
        try checkReadability(appearance: .dark)
    }

    @MainActor
    func testLargestTextKeepsBothTranscriptionChoicesReachable() throws {
        try checkReadability(appearance: .dark, largestText: true)
    }

    @MainActor
    func testAudioPlayerUsesTheSameOptionsSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-test-data", "--disable-cloud-services", "--seed-untranscribed-recording",
            "-alwaysDarkAppearance", "YES"
        ]
        app.launch()
        defer { app.terminate() }
        app.showRecordScreen()
        app.buttons["bisonnotes.record.view-recordings"].tap()
        let play = app.buttons["bisonnotes.recording.action.play-audio"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        let generate = app.buttons["bisonnotes.audio-player.transcript"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(app.buttons["bisonnotes.transcription-options.clean"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bisonnotes.transcription-options.original"].isHittable)
        app.buttons["bisonnotes.transcription-options.cancel"].tap()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.isEnabled)
    }

    @MainActor
    func testTranscriptsUsesTheSameOptionsSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-test-data", "--disable-cloud-services", "--seed-untranscribed-recording",
            "-alwaysDarkAppearance", "YES"
        ]
        app.launch()
        defer { app.terminate() }
        app.navigateToSection("Transcripts")
        let generate = app.buttons["Generate Transcript for UI Test Recording"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        XCTAssertTrue(app.buttons["bisonnotes.transcription-options.clean"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bisonnotes.transcription-options.original"].isHittable)
        app.buttons["bisonnotes.transcription-options.cancel"].tap()
        XCTAssertTrue(generate.waitForExistence(timeout: 5))
        XCTAssertTrue(generate.isEnabled)
    }

    @MainActor
    private func checkReadability(appearance: XCUIDevice.Appearance, largestText: Bool = false) throws {
        let previousAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = appearance
        defer { XCUIDevice.shared.appearance = previousAppearance }

        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-test-data", "--disable-cloud-services", "--seed-untranscribed-recording",
            "-alwaysDarkAppearance", appearance == .dark ? "YES" : "NO"
        ]
        if largestText {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        }
        app.launch()
        defer { app.terminate() }
        app.showRecordScreen()
        app.buttons["bisonnotes.record.view-recordings"].tap()
        XCTAssertTrue(app.scrollViews["bisonnotes.recordings.list"].waitForExistence(timeout: 10))
        attachScreenshot(app, name: "Recordings \(appearance) largestText=\(largestText)")
        try auditContrast(app, surface: "bisonnotes.recordings.list")

        let action = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "bisonnotes.recording.generate-transcript.")
        ).firstMatch
        for _ in 0..<6 where !action.isHittable {
            app.scrollViews["bisonnotes.recordings.list"].swipeUp()
        }
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isHittable)
        action.tap()

        let clean = app.buttons["bisonnotes.transcription-options.clean"]
        let original = app.buttons["bisonnotes.transcription-options.original"]
        let cancel = app.buttons["bisonnotes.transcription-options.cancel"]
        XCTAssertTrue(clean.waitForExistence(timeout: 5))
        XCTAssertTrue(original.exists)
        if largestText {
            XCTAssertGreaterThan(app.staticTexts["Clean audio first?"].frame.height, 45)
        }
        let optionsContent = app.scrollViews["bisonnotes.transcription-options.content"]
        let viewport = optionsContent.frame.insetBy(dx: -1, dy: -1)
        if largestText {
            for _ in 0..<4 where !viewport.contains(original.frame) { optionsContent.swipeUp() }
        }
        XCTAssertTrue(original.isHittable)
        XCTAssertTrue(viewport.contains(original.frame), "The complete alternative must be readable")
        attachScreenshot(app, name: "Transcription options \(appearance) largestText=\(largestText)")
        try auditContrast(app, surface: "bisonnotes.transcription-options.content")
        checkCancelAndReopen(action: action, clean: clean, cancel: cancel)
    }

    @MainActor
    private func checkCancelAndReopen(action: XCUIElement, clean: XCUIElement, cancel: XCUIElement) {
        cancel.tap()
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        XCTAssertTrue(action.isEnabled, "Cancel must leave transcription unstarted")

        // Cancel clears the item binding: opening the same recording again must work.
        action.tap()
        XCTAssertTrue(clean.waitForExistence(timeout: 5))
        cancel.tap()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func auditContrast(_ app: XCUIApplication, surface identifier: String) throws {
        let surface = app.scrollViews[identifier]
        XCTAssertTrue(surface.exists)
        let bounds = surface.frame
        XCTAssertFalse(bounds.isEmpty)
        try app.performAccessibilityAudit(for: .contrast) { issue in
            guard let element = issue.element else { return false }
            let frame = element.frame
            let isBackground = !bounds.intersects(frame) && !element.isHittable
            // The audit samples the whole text frame, including the portion
            // clipped by a scroll viewport. Record these partial text samples;
            // retain issues on controls and on text too tall to fit after scrolling.
            let isClippedText = element.elementType == .staticText
                && bounds.intersects(frame) && !bounds.contains(frame)
                && frame.height <= bounds.height
                && frame.minX >= bounds.minX && frame.maxX <= bounds.maxX
            // iPad leaves the dimmed presenting screen visible around a sheet.
            // Exclusions are scoped and attached, never a general contrast waiver.
            let evidence = XCTAttachment(string: """
            Background: \(isBackground); scroll-clipped static text: \(isClippedText)
            Panel: \(identifier), bounds: \(bounds)
            Element: \(element.identifier), label: \(element.label), frame: \(element.frame)
            Issue: \(issue.detailedDescription)
            """)
            evidence.name = isBackground || isClippedText ? "Scoped contrast sample" : "Active contrast issue"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            return isBackground || isClippedText
        }
    }
}
