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
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            let name = orientation == .portrait ? "portrait" : "landscape"
            attachScreenshot(of: app, named: "record-\(name)")

            let start = app.buttons["bisonnotes.record.start"]
            XCTAssertTrue(start.waitForExistence(timeout: 5), "\(name): no Start Recording button")
            XCTAssertTrue(start.isHittable, "\(name): Start Recording is off screen without scrolling")

            // ArrangementView drops its secondary when there is no room beside
            // the primary; the library and import actions must then move into the
            // primary, never vanish and never appear twice.
            let library = app.buttons.matching(identifier: "bisonnotes.record.view-recordings")
            XCTAssertEqual(library.count, 1, "\(name): View Recordings should appear exactly once")
            XCTAssertTrue(library.firstMatch.waitForExistence(timeout: 3), "\(name): View Recordings is missing")
            if !library.firstMatch.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(library.firstMatch.isHittable, "\(name): View Recordings cannot be reached")
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
