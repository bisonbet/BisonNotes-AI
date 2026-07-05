//
//  BisonNotesAIUITests.swift
//  BisonNotes AIUITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest

final class BisonNotesAIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSeededRecordingNavigationAndICloudNotice() throws {
        let app = launchSeededApp()

        app.buttons["bisonnotes.record.view-recordings"].tap()
        XCTAssertTrue(app.staticTexts["UI Test Recording"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Keep on This Device"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play Audio"].waitForExistence(timeout: 5))

        app.buttons["Done"].tap()
        app.tabBars.buttons["Setup"].tap()
        app.buttons["bisonnotes.setup.additional-settings"].tap()

        let iCloudToggle = findICloudToggle(in: app)
        XCTAssertTrue(iCloudToggle.exists)
        iCloudToggle.tap()

        XCTAssertTrue(app.alerts["iCloud Sync Notice"].waitForExistence(timeout: 5))
        app.alerts["iCloud Sync Notice"].buttons["Cancel"].tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure {
            let app = XCUIApplication()
            app.launchArguments = [
                "--ui-testing",
                "--reset-test-data",
                "--seed-sample-recording",
                "--disable-cloud-services"
            ]
            app.launch()
        }
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
    private func findICloudToggle(in app: XCUIApplication) -> XCUIElement {
        let settingsScroll = app.scrollViews["bisonnotes.settings.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 8))

        let identifierToggle = app.descendants(matching: .any)["bisonnotes.settings.icloud.enable"]
        let labelToggle = app.switches["Enable iCloud Sync"]
        for _ in 0..<4 {
            if identifierToggle.exists {
                return identifierToggle
            }
            if labelToggle.exists {
                return labelToggle
            }
            settingsScroll.swipeUp()
        }

        return identifierToggle.exists ? identifierToggle : labelToggle
    }
}
