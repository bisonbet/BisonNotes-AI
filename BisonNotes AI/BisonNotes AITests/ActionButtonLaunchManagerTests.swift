//
//  ActionButtonLaunchManagerTests.swift
//  BisonNotes AITests
//

import XCTest
@testable import BisonNotes_AI

final class ActionButtonLaunchManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ActionButtonLaunchManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRequestPersistsBeforePostingNotification() {
        var requestWasPendingWhenNotificationPosted = false

        ActionButtonLaunchManager.requestRecordingStart(defaults: defaults) {
            requestWasPendingWhenNotificationPosted =
                ActionButtonLaunchManager.consumeRecordingRequest(defaults: self.defaults)
        }

        XCTAssertTrue(requestWasPendingWhenNotificationPosted)
        XCTAssertFalse(ActionButtonLaunchManager.consumeRecordingRequest(defaults: defaults))
    }

    func testPendingRequestIsConsumedExactlyOnce() {
        ActionButtonLaunchManager.requestRecordingStart(defaults: defaults) {}

        XCTAssertTrue(ActionButtonLaunchManager.consumeRecordingRequest(defaults: defaults))
        XCTAssertFalse(ActionButtonLaunchManager.consumeRecordingRequest(defaults: defaults))
    }
}
