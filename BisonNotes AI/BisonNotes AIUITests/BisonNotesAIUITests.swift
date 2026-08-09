//
//  BisonNotesAIUITests.swift
//  BisonNotes AIUITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest

final class BisonNotesAIUITests: XCTestCase {
    private enum LocalSpeakerLabelsTestID {
        static let toggle = "bisonnotes.settings.local-speaker-labels.toggle"
        static let help = "bisonnotes.settings.local-speaker-labels.help"
        static let offlineVBx = "bisonnotes.settings.local-speaker-labels.method.offline-vbx"
        static let lsEEND = "bisonnotes.settings.local-speaker-labels.method.ls-eend"
        static let modelStatus = "bisonnotes.settings.local-speaker-labels.model-status"
        static let prepareModel = "bisonnotes.settings.local-speaker-labels.prepare-model"
        static let cancelModel = "bisonnotes.settings.local-speaker-labels.cancel-model"
    }

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
    func testLocalSpeakerLabelsDefaultsAndNoAutoDownload() throws {
        let app = launchSeededApp()
        openFluidAudioSettings(in: app)

        let toggle = localSpeakerElement(
            LocalSpeakerLabelsTestID.toggle,
            in: app
        )
        XCTAssertEqual(toggle.value as? String, "0", "Local speaker labels must default off.")

        toggle.tap()

        assertLocalSpeakerLabelMethods(in: app)
        assertSpeakerModelIsNotPreparing(in: app)
    }

    @MainActor
    func testLocalSpeakerLabelsMethodSelectionPersistsWithoutPreparation() throws {
        let app = launchSeededApp()
        openFluidAudioSettings(in: app)

        let toggle = localSpeakerElement(
            LocalSpeakerLabelsTestID.toggle,
            in: app
        )
        toggle.tap()

        let experimentalMethod = localSpeakerElement(
            LocalSpeakerLabelsTestID.lsEEND,
            in: app
        )
        XCTAssertTrue(experimentalMethod.waitForExistence(timeout: 5))
        experimentalMethod.tap()

        let doneButtons = app.buttons.matching(identifier: "Done")
        XCTAssertTrue(doneButtons.element(boundBy: 0).waitForExistence(timeout: 5))
        let done = doneButtons.element(boundBy: max(0, doneButtons.count - 1))
        done.tap()

        let configure = app.buttons.matching(identifier: "Configure").firstMatch
        XCTAssertTrue(configure.waitForExistence(timeout: 8))
        configure.tap()

        let reopenedToggle = localSpeakerElement(
            LocalSpeakerLabelsTestID.toggle,
            in: app
        )
        XCTAssertEqual(reopenedToggle.value as? String, "1")

        let reopenedExperimentalMethod = localSpeakerElement(
            LocalSpeakerLabelsTestID.lsEEND,
            in: app
        )
        XCTAssertTrue(reopenedExperimentalMethod.waitForExistence(timeout: 5))
        XCTAssertTrue(reopenedExperimentalMethod.isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Download Required"))
                .firstMatch
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[LocalSpeakerLabelsTestID.cancelModel].exists
        )
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

    @MainActor
    private func openFluidAudioSettings(in app: XCUIApplication) {
        app.navigateToSection("Setup")
        app.buttons["bisonnotes.setup.additional-settings"].tap()

        let settingsScroll = app.scrollViews["bisonnotes.settings.scroll"]
        XCTAssertTrue(settingsScroll.waitForExistence(timeout: 8))

        let transcription = app.buttons.matching(identifier: "Transcription").firstMatch
        XCTAssertTrue(transcription.waitForExistence(timeout: 8))
        transcription.tap()

        let configure = app.buttons.matching(identifier: "Configure").firstMatch
        XCTAssertTrue(configure.waitForExistence(timeout: 8))
        configure.tap()

        XCTAssertTrue(
            app.navigationBars["On Device Transcription"].waitForExistence(timeout: 8)
                || app.staticTexts["On-Device Transcription"].waitForExistence(timeout: 8)
        )
    }

    @MainActor
    private func localSpeakerElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 8), "Missing UI element \(identifier).")
        return element
    }

    @MainActor
    private func assertLocalSpeakerLabelMethods(in app: XCUIApplication) {
        let help = localSpeakerElement(LocalSpeakerLabelsTestID.help, in: app)
        XCTAssertTrue(help.label.localizedCaseInsensitiveContains("completed Parakeet"))
        XCTAssertTrue(help.label.localizedCaseInsensitiveContains("Live Transcription"))

        let offlineMethod = localSpeakerElement(LocalSpeakerLabelsTestID.offlineVBx, in: app)
        let experimentalMethod = localSpeakerElement(LocalSpeakerLabelsTestID.lsEEND, in: app)
        XCTAssertTrue(offlineMethod.label.localizedCaseInsensitiveContains("Offline VBx"))
        XCTAssertTrue(experimentalMethod.label.localizedCaseInsensitiveContains("LS-EEND"))

        for copy in ["Recommended", "Experimental", "up to 10 speakers"] {
            XCTAssertTrue(
                app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", copy))
                    .firstMatch
                    .waitForExistence(timeout: 5),
                "Missing speaker-label copy: \(copy)"
            )
        }
    }

    @MainActor
    private func assertSpeakerModelIsNotPreparing(in app: XCUIApplication) {
        let status = localSpeakerElement(LocalSpeakerLabelsTestID.modelStatus, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Download Required"))
                .firstMatch
                .waitForExistence(timeout: 8),
            "Enabling labels must not start a model download."
        )

        let prepareButton = localSpeakerElement(LocalSpeakerLabelsTestID.prepareModel, in: app)
        XCTAssertTrue(prepareButton.exists)
        XCTAssertFalse(
            app.descendants(matching: .any)[LocalSpeakerLabelsTestID.cancelModel].exists,
            "A download should not be running until the explicit prepare action is used."
        )
        XCTAssertTrue(status.exists)
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
