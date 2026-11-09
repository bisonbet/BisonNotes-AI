//
//  RecordLayoutUITests.swift
//  BisonNotes AIUITests
//
//  M4 of docs/iphone-duo-implementation-plan.md: the Record screen keeps its
//  controls on screen without scrolling — including iPhone Duo's short outer
//  display in landscape — and the library and import actions stay reachable.
//

import XCTest

final class RecordLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRecordControlsAreVisibleWithoutScrollingInEveryOrientation() throws {
        try checkRecordLayout(textSize: nil, startMustBeVisibleWithoutScrolling: true)
    }

    /// M4's exit criterion: Start Recording on screen without scrolling at AX3,
    /// including a short landscape screen.
    @MainActor
    func testRecordControlsAreVisibleWithoutScrollingAtAX3() throws {
        try checkRecordLayout(textSize: "UICTContentSizeCategoryAccessibilityXL", startMustBeVisibleWithoutScrolling: true)
    }

    /// M5: at the largest text size everything must still be reachable, even if
    /// it takes a scroll.
    @MainActor
    func testRecordControlsAreReachableAtAX5() throws {
        try checkRecordLayout(textSize: "UICTContentSizeCategoryAccessibilityXXXL", startMustBeVisibleWithoutScrolling: false)
    }

    @MainActor
    private func checkRecordLayout(textSize: String?, startMustBeVisibleWithoutScrolling: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        if let textSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", textSize]
        }
        app.launch()
        app.showRecordScreen()
        let sizeName = textSize.map { $0.replacingOccurrences(of: "UICTContentSizeCategory", with: "") } ?? "default"

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            let name = "\(sizeName) \(orientation == .portrait ? "portrait" : "landscape")"
            attachScreenshot(of: app, named: "record-\(name)")

            let start = app.buttons["bisonnotes.record.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "\(name): no Start Recording button")
            if startMustBeVisibleWithoutScrolling {
                XCTAssertTrue(start.isHittable, "\(name): Start Recording is off screen without scrolling")
            } else {
                scrollUntilHittable(start, in: app)
                XCTAssertTrue(start.isHittable, "\(name): Start Recording cannot be reached")
            }

            // ArrangementView drops its secondary when there is no room beside
            // the primary; the library and import actions must then move into the
            // primary, never vanish and never appear twice.
            let library = app.buttons.matching(identifier: "bisonnotes.record.view-recordings")
            XCTAssertEqual(library.count, 1, "\(name): View Recordings should appear exactly once")
            XCTAssertTrue(library.firstMatch.waitForExistence(timeout: 3), "\(name): View Recordings is missing")
            scrollUntilHittable(library.firstMatch, in: app)
            XCTAssertTrue(library.firstMatch.isHittable, "\(name): View Recordings cannot be reached")

            // Back to the top for the next orientation.
            for _ in 0..<4 { app.swipeDown() }
        }
    }

    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
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
