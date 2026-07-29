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
        XCTAssertTrue(app.buttons["Keep on This Device for UI Test Recording"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play Audio for UI Test Recording"].waitForExistence(timeout: 5))

        app.buttons["Done"].tap()
        app.navigateToSection("Setup")
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
        XCTAssertTrue(app.buttons["bisonnotes.record.view-recordings"].waitForExistence(timeout: 20))
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

@MainActor
extension XCUIApplication {
    func navigateToSection(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let tab = tabBars.buttons[name]
        if tab.waitForExistence(timeout: 1) {
            tab.tap()
            return
        }

        let sidebarIdentifier = "bisonnotes.sidebar.\(name.lowercased())"
        let sidebarItem = staticTexts.matching(identifier: sidebarIdentifier).firstMatch
        XCTAssertTrue(
            sidebarItem.waitForExistence(timeout: 8),
            "Could not find \(name) in either the tab bar or adaptive sidebar.",
            file: file,
            line: line
        )
        sidebarItem.tap()
    }
}
