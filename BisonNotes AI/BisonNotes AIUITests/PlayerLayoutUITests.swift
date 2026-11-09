//
//  PlayerLayoutUITests.swift
//  BisonNotes AIUITests
//
//  M4 of docs/iphone-duo-implementation-plan.md: the player keeps its transport
//  on screen in every orientation, and its transcript follows beside it when
//  there is room — never twice, never in place of the transport.
//

import XCTest

final class PlayerLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTransportStaysOnScreenAndTheTranscriptAppearsOnlyBesideIt() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-test-data",
            "--seed-sample-recording",
            "--disable-cloud-services"
        ]
        app.launch()
        app.showRecordScreen()
        app.buttons["bisonnotes.record.view-recordings"].tap()
        let play = app.buttons["Play Audio for UI Test Recording"]
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        play.tap()

        // The playback section's container identifier hides its buttons' own,
        // so the play button is found by its label.
        let transport = app.buttons.matching(NSPredicate(format: "label == 'Play Audio' OR label == 'Pause Audio'")).firstMatch
        let transcript = app.descendants(matching: .any)["bisonnotes.audio-player.transcript"]

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1.5)
            let name = orientation == .portrait ? "portrait" : "landscape"
            attachScreenshot(of: app, named: "player-\(name)")

            XCTAssertTrue(transport.waitForExistence(timeout: 5), "\(name): the player is gone")
            XCTAssertTrue(transport.isHittable, "\(name): the play button is off screen")
            XCTAssertEqual(
                app.buttons.matching(NSPredicate(format: "label == 'Play Audio' OR label == 'Pause Audio'")).count, 1,
                "\(name): the transport appears more than once"
            )
            if transcript.exists {
                let segment = app.buttons.matching(NSPredicate(format: "value CONTAINS 'deterministic transcript'")).firstMatch
                XCTAssertTrue(segment.exists, "\(name): the transcript beside the player is not the recording's")

                // Tapping a line plays from there even when nothing is playing
                // yet — there is no player to seek until playback starts.
                XCTAssertTrue(app.buttons["Play Audio"].exists, "\(name): expected to start paused")
                segment.tap()
                XCTAssertTrue(
                    app.buttons["Pause Audio"].waitForExistence(timeout: 5),
                    "\(name): tapping a transcript line did not start playback"
                )
                if app.buttons["Pause Audio"].exists { app.buttons["Pause Audio"].tap() }
            }
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
