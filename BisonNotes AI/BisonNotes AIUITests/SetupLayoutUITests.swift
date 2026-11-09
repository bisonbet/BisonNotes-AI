//
//  SetupLayoutUITests.swift
//  BisonNotes AIUITests
//
//  Setup keeps the processing-method picker and its Save button together and
//  reachable in every layout — one column, or split around iPhone Duo's fold —
//  and shows the Action Button guide only on iPhones that have one.
//

import XCTest

final class SetupLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testPickerAndSaveStayReachableInEveryOrientation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        app.navigateToSection("Setup")

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            let name = orientation == .portrait ? "portrait" : "landscape"
            attachScreenshot(of: app, named: "setup-\(name)")

            let picker = app.descendants(matching: .any)["bisonnotes.setup.processing-method"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "\(name): no processing-method picker")
            let save = app.buttons["bisonnotes.setup.save"]
            XCTAssertEqual(app.buttons.matching(identifier: "bisonnotes.setup.save").count, 1, "\(name): Save should appear once")
            // Scroll toward Save from whichever side it is on; a plain swipe-up
            // loop overshot on a short landscape screen and left it just above
            // the top edge.
            let scroll = app.scrollViews["bisonnotes.setup.scroll"]
            let window = app.windows.firstMatch.frame
            func saveIsOnScreen() -> Bool {
                let frame = save.frame
                return !frame.isEmpty && window.contains(CGPoint(x: frame.midX, y: frame.midY))
            }
            // Short drags without momentum: a full swipe moves further than a
            // 402-point landscape screen is tall and skips straight past Save.
            func drag(up: Bool) {
                let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.65 : 0.35))
                let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.35 : 0.65))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            var attempts = 0
            while !saveIsOnScreen() && attempts < 20 {
                drag(up: save.frame.midY > window.midY)
                attempts += 1
            }
            XCTAssertTrue(saveIsOnScreen(), "\(name): Save cannot be reached")
            XCTAssertEqual(
                app.scrollViews.matching(identifier: "bisonnotes.setup.scroll").count, 1,
                "\(name): the Setup scroll view should be identified exactly once"
            )
            for _ in 0..<4 { app.scrollViews["bisonnotes.setup.scroll"].swipeDown() }
        }
    }

    /// iPhone Duo is in an Action Button iPhone family but has none.
    @MainActor
    func testActionButtonGuideOnlyOnIPhonesWithAnActionButton() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--disable-cloud-services"]
        app.launch()
        app.showRecordScreen()
        app.navigateToSection("Setup")

        let guide = app.staticTexts["Action Button Setup"]
        let scroll = app.scrollViews["bisonnotes.setup.scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 8))
        for _ in 0..<5 where !guide.exists { app.swipeUp() }

        if model == "iPhone19,4" || model.hasPrefix("iPad") {
            XCTAssertFalse(guide.exists, "\(model) has no Action Button, so Setup must not explain one")
        } else if model.hasPrefix("iPhone") {
            XCTAssertTrue(guide.exists, "\(model) has an Action Button; Setup should explain it")
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
