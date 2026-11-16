import XCTest

final class ActionReadabilityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDarkRecordingMenuFitsWithoutWrapping() throws {
        try checkMenu(dark: true)
    }

    @MainActor
    func testLightRecordingMenuFitsWithoutWrapping() throws {
        try checkMenu(dark: false)
    }

    @MainActor
    func testDarkTranscriptActionsContrast() throws {
        try checkTranscript(dark: true)
    }

    @MainActor
    func testLightTranscriptActionsContrast() throws {
        try checkTranscript(dark: false)
    }

    @MainActor
    func testLargestTranscriptActionsRemainReachable() throws {
        try checkTranscript(dark: true, largestText: true)
    }

    @MainActor
    private func launch(dark: Bool, largestText: Bool = false, library: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-test-data", "--disable-cloud-services",
            library ? "--seed-sample-library" : "--seed-sample-recording",
            "-alwaysDarkAppearance", dark ? "YES" : "NO",
            "-betaFeaturesEnabled", "YES", "-betaFeature.transcriptCleanup.enabled", "YES"
        ]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func checkMenu(dark: Bool) throws {
        let app = launch(dark: dark, library: true)
        defer { app.terminate() }
        app.showRecordScreen()
        app.buttons["bisonnotes.record.view-recordings"].tap()
        let actions = app.buttons["Recording Actions"]
        let overflow = app.buttons["More"]
        XCTAssertTrue(
            actions.waitForExistence(timeout: 5) || overflow.waitForExistence(timeout: 5), app.debugDescription
        )
        (actions.exists ? actions : overflow).tap()
        var bounds: [CGRect] = []
        for title in ["Combine", "Archive", "Export", "Archive by Date"] {
            let label = app.buttons[title]
            XCTAssertTrue(label.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertLessThanOrEqual(label.frame.height, 44, "Menu labels must fit on one line at standard text size")
            XCTAssertTrue(label.isHittable)
            bounds.append(label.frame)
        }
        attachScreenshot(app, name: "Recording menu dark=\(dark)")
        try auditContrast(app, bounds: bounds)
        app.buttons["Archive by Date"].tap()
        XCTAssertTrue(app.staticTexts["Archive Older Than"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func checkTranscript(dark: Bool, largestText: Bool = false) throws {
        let app = launch(dark: dark, largestText: largestText)
        defer { app.terminate() }
        app.navigateToSection("Transcripts")
        let edit = app.buttons["Edit Transcript for UI Test Recording"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let copy = app.buttons["bisonnotes.transcript.copy"]
        let share = app.buttons["bisonnotes.transcript.share"]
        let editor = app.descendants(matching: .any)["bisonnotes.transcript.detail"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        for _ in 0..<5 where !copy.isHittable || !share.isHittable { editor.swipeUp() }
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(copy.isHittable)
        XCTAssertTrue(share.isHittable)
        XCTAssertEqual(copy.label, "Copy Original")
        XCTAssertEqual(share.label, "Share Original")
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertGreaterThanOrEqual(share.frame.height, 44)
        XCTAssertLessThanOrEqual(copy.frame.height, largestText ? 85 : 50)
        XCTAssertLessThanOrEqual(share.frame.height, largestText ? 85 : 50)
        if largestText { XCTAssertGreaterThan(copy.frame.height, 50) }
        attachScreenshot(app, name: "Transcript actions dark=\(dark) largestText=\(largestText)")
        try auditContrast(app, bounds: [copy.frame, share.frame])
        copy.tap()
        XCTAssertTrue(share.isEnabled, "Copy must leave the editor usable")
        try checkSaveContrast(app)
    }

    @MainActor
    private func checkSaveContrast(_ app: XCUIApplication) throws {
        let save = app.buttons["bisonnotes.transcript.save"]
        if !save.isHittable {
            let editor = app.descendants(matching: .any)["bisonnotes.transcript.detail"]
            for _ in 0..<6 where !save.isHittable { editor.swipeDown() }
        }
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(save.isHittable)
        attachScreenshot(app, name: "Transcript Save action")
        try auditContrast(app, bounds: [save.frame])
    }

    @MainActor
    private func auditContrast(_ app: XCUIApplication, bounds: [CGRect]) throws {
        try app.performAccessibilityAudit(for: .contrast) { issue in
            guard let element = issue.element else { return false }
            let isOutsideScope = !bounds.contains { $0.intersects(element.frame) }
            let evidence = XCTAttachment(string: """
            Outside action scope: \(isOutsideScope); active bounds: \(bounds)
            Element: \(element.identifier); label: \(element.label); frame: \(element.frame)
            Issue: \(issue.detailedDescription)
            """)
            evidence.name = isOutsideScope ? "Outside action scope" : "Action contrast issue"
            evidence.lifetime = .keepAlways
            self.add(evidence)
            return isOutsideScope
        }
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
