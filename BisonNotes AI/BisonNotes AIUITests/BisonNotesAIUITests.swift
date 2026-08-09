//
//  BisonNotesAIUITests.swift
//  BisonNotes AIUITests
//
//  Created by Tim Champ on 7/26/25.
//

import XCTest
final class BisonNotesAIUITests: XCTestCase {
    private enum LocalSpeakerLabelsTestID {
        static let section = "bisonnotes.settings.local-speaker-labels.section"
        static let toggle = "bisonnotes.settings.local-speaker-labels.toggle"
        static let help = "bisonnotes.settings.local-speaker-labels.help"
        static let offlineVBx = "bisonnotes.settings.local-speaker-labels.method.offline-vbx"
        static let lsEEND = "bisonnotes.settings.local-speaker-labels.method.ls-eend"
        static let modelStatus = "bisonnotes.settings.local-speaker-labels.model-status"
        static let modelProgress = "bisonnotes.settings.local-speaker-labels.model-progress"
        static let modelError = "bisonnotes.settings.local-speaker-labels.model-error"
        static let prepareModel = "bisonnotes.settings.local-speaker-labels.prepare-model"
        static let cancelModel = "bisonnotes.settings.local-speaker-labels.cancel-model"
        static let deleteModel = "bisonnotes.settings.local-speaker-labels.delete-model"
        static let reset = "bisonnotes.settings.transcription.reset"
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

        let section = localSpeakerElement(LocalSpeakerLabelsTestID.section, in: app)
        XCTAssertEqual(section.label, "Speaker Labels (After Recording)")

        let toggle = localSpeakerElement(
            LocalSpeakerLabelsTestID.toggle,
            in: app
        )
        XCTAssertEqual(toggle.value as? String, "0", "Local speaker labels must default off.")

        toggle.setSwitch(on: true)

        assertLocalSpeakerLabelMethods(in: app)
        XCTAssertEqual(
            localSpeakerElement(LocalSpeakerLabelsTestID.offlineVBx, in: app).value as? String,
            "Selected",
            "Offline VBx must be the default speaker-label method."
        )
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
        toggle.setSwitch(on: true)

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

        let configure = app.reachableButton(named: "Configure On Device")
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
        XCTAssertEqual(reopenedExperimentalMethod.value as? String, "Selected")
        XCTAssertEqual(
            localSpeakerElement(LocalSpeakerLabelsTestID.modelStatus, in: app).value as? String,
            "LS-EEND: Download Required"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[LocalSpeakerLabelsTestID.cancelModel].exists
        )
    }
}
extension BisonNotesAIUITests {
    @MainActor
    func testCorruptLocalSpeakerMethodNormalizesToOfflineVBx() throws {
        let app = launchSeededApp(extraArguments: ["--ui-test-corrupt-local-speaker-method"])
        openFluidAudioSettings(in: app)

        XCTAssertEqual(
            localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: app).value as? String,
            "1"
        )
        XCTAssertEqual(
            localSpeakerElement(LocalSpeakerLabelsTestID.offlineVBx, in: app).value as? String,
            "Selected",
            "An unknown stored method must fail closed to Offline VBx."
        )
        assertSpeakerModelIsNotPreparing(in: app)
    }

    @MainActor
    func testResetRestoresSpeakerLabelsOffAndOfflineVBx() throws {
        let app = launchSeededApp()
        openFluidAudioSettings(in: app)

        let toggle = localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: app)
        toggle.setSwitch(on: true)
        localSpeakerElement(LocalSpeakerLabelsTestID.lsEEND, in: app).tap()

        closeFluidAudioSettings(in: app)
        let reset = app.reachableElement(LocalSpeakerLabelsTestID.reset)
        reset.tap()

        let doneButtons = app.buttons.matching(identifier: "Done")
        XCTAssertTrue(doneButtons.firstMatch.waitForExistence(timeout: 5))
        doneButtons.element(boundBy: max(0, doneButtons.count - 1)).tap()

        let transcription = app.buttons.matching(identifier: "Transcription").firstMatch
        XCTAssertTrue(transcription.waitForExistence(timeout: 8))
        transcription.tap()

        let configure = app.reachableButton(named: "Configure On Device")
        configure.tap()
        XCTAssertTrue(app.navigationBars["On Device Transcription"].waitForExistence(timeout: 8))

        let resetToggle = localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: app)
        XCTAssertEqual(resetToggle.value as? String, "0")
        resetToggle.setSwitch(on: true)
        XCTAssertEqual(
            localSpeakerElement(LocalSpeakerLabelsTestID.offlineVBx, in: app).value as? String,
            "Selected"
        )
        assertSpeakerModelIsNotPreparing(in: app)
    }

    @MainActor
    func testSpeakerModelFakeSuccessDeleteAndErrorClearProgress() throws {
        let app = launchSeededApp()
        openFluidAudioSettings(in: app)
        localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: app).setSwitch(on: true)

        let download = localSpeakerElement(LocalSpeakerLabelsTestID.prepareModel, in: app)
        XCTAssertEqual(download.label, "Download Speaker Model")
        download.tap()

        let delete = localSpeakerElement(LocalSpeakerLabelsTestID.deleteModel, in: app)
        XCTAssertEqual(delete.label, "Delete Speaker Model")
        XCTAssertFalse(app.descendants(matching: .any)[LocalSpeakerLabelsTestID.modelProgress].exists)
        delete.tap()

        XCTAssertTrue(
            localSpeakerElement(LocalSpeakerLabelsTestID.prepareModel, in: app).waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.descendants(matching: .any)[LocalSpeakerLabelsTestID.modelProgress].exists)

        app.terminate()
        let errorApp = launchSeededApp(
            extraArguments: ["--ui-test-local-speaker-model-prepare-error"]
        )
        openFluidAudioSettings(in: errorApp)
        localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: errorApp).setSwitch(on: true)
        localSpeakerElement(LocalSpeakerLabelsTestID.prepareModel, in: errorApp).tap()

        let error = localSpeakerElement(LocalSpeakerLabelsTestID.modelError, in: errorApp)
        XCTAssertTrue(error.label.localizedCaseInsensitiveContains("Offline VBx"))
        XCTAssertFalse(
            errorApp.descendants(matching: .any)[LocalSpeakerLabelsTestID.modelProgress].exists
        )
    }

    @MainActor
    func testSpeakerModelCancellationSwitchAndToggleOffClearProgress() throws {
        let app = launchSeededApp(
            extraArguments: ["--ui-test-local-speaker-model-preparing"]
        )
        openFluidAudioSettings(in: app)
        let toggle = localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: app)
        toggle.setSwitch(on: true)

        XCTAssertTrue(
            localSpeakerElement(LocalSpeakerLabelsTestID.modelProgress, in: app).exists
        )
        let cancel = localSpeakerElement(LocalSpeakerLabelsTestID.cancelModel, in: app)
        XCTAssertEqual(cancel.label, "Cancel Download")
        cancel.tap()
        XCTAssertFalse(app.descendants(matching: .any)[LocalSpeakerLabelsTestID.modelProgress].exists)

        localSpeakerElement(LocalSpeakerLabelsTestID.offlineVBx, in: app).tap()
        XCTAssertTrue(
            localSpeakerElement(LocalSpeakerLabelsTestID.modelProgress, in: app)
                .waitForExistence(timeout: 5)
        )
        localSpeakerElement(LocalSpeakerLabelsTestID.lsEEND, in: app).tap()
        XCTAssertFalse(app.descendants(matching: .any)[LocalSpeakerLabelsTestID.modelProgress].exists)
        assertSpeakerModelIsNotPreparing(in: app, methodName: "LS-EEND")

        localSpeakerElement(LocalSpeakerLabelsTestID.offlineVBx, in: app).tap()
        XCTAssertTrue(
            localSpeakerElement(LocalSpeakerLabelsTestID.modelProgress, in: app)
                .waitForExistence(timeout: 5)
        )
        localSpeakerElement(LocalSpeakerLabelsTestID.toggle, in: app).setSwitch(on: false)
        XCTAssertFalse(app.descendants(matching: .any)[LocalSpeakerLabelsTestID.modelProgress].exists)
    }
}

extension BisonNotesAIUITests {
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

        let configure = app.reachableButton(named: "Configure On Device")
        configure.tap()

        XCTAssertTrue(
            app.navigationBars["On Device Transcription"].waitForExistence(timeout: 8)
                || app.staticTexts["On-Device Transcription"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            localSpeakerElement(LocalSpeakerLabelsTestID.section, in: app)
                .waitForExistence(timeout: 8)
        )
    }

    @MainActor
    private func closeFluidAudioSettings(in app: XCUIApplication) {
        let doneButtons = app.buttons.matching(identifier: "Done")
        XCTAssertTrue(doneButtons.firstMatch.waitForExistence(timeout: 5))
        doneButtons.element(boundBy: max(0, doneButtons.count - 1)).tap()
    }

    @MainActor
    private func localSpeakerElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.reachableElement(identifier)
    }

    @MainActor
    private func assertLocalSpeakerLabelMethods(in app: XCUIApplication) {
        let help = localSpeakerElement(LocalSpeakerLabelsTestID.help, in: app)
        XCTAssertTrue(help.label.localizedCaseInsensitiveContains("completed Parakeet recordings"))
        XCTAssertTrue(help.label.localizedCaseInsensitiveContains("imports"))
        XCTAssertTrue(help.label.localizedCaseInsensitiveContains("re-runs"))
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
    private func assertSpeakerModelIsNotPreparing(
        in app: XCUIApplication,
        methodName: String = "Offline VBx"
    ) {
        let status = localSpeakerElement(LocalSpeakerLabelsTestID.modelStatus, in: app)
        XCTAssertEqual(
            status.value as? String,
            "\(methodName): Download Required",
            "Enabling labels or selecting \(methodName) must not start a model download."
        )

        let prepareButton = localSpeakerElement(LocalSpeakerLabelsTestID.prepareModel, in: app)
        XCTAssertTrue(prepareButton.exists)
        XCTAssertEqual(prepareButton.label, "Download Speaker Model")
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
