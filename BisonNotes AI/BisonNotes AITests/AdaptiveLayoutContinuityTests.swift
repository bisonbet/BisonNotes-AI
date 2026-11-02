//
//  AdaptiveLayoutContinuityTests.swift
//  BisonNotes AITests
//
//  iPhone Duo crosses the compact / regular size-class boundary every time it
//  opens or closes. These pin the pieces that must not depend on size class.
//

import SwiftUI
import XCTest
@testable import BisonNotes_AI

@MainActor
final class AdaptiveLayoutContinuityTests: XCTestCase {
    func testAppearanceFollowsSystemUnlessAlwaysDark() {
        XCTAssertNil(AppAppearance.preferredColorScheme(alwaysDark: false))
        XCTAssertEqual(AppAppearance.preferredColorScheme(alwaysDark: true), .dark)
    }

    func testAlwaysDarkJoinsSettingsBackup() {
        XCTAssertTrue(iCloudStorageManager.backedUpSettingsKeys.contains(AppAppearance.alwaysDarkKey))
    }

    func testNavigateToSectionNamesMapToSections() {
        XCTAssertEqual(SidebarItem(navigationName: "record"), .record)
        XCTAssertEqual(SidebarItem(navigationName: "transcripts"), .transcripts)
        XCTAssertEqual(SidebarItem(navigationName: "summaries"), .summaries)
        XCTAssertEqual(SidebarItem(navigationName: "settings"), .settings)
        XCTAssertNil(SidebarItem(navigationName: "Record"))
    }

    func testSectionSelectionRoundTripsThroughSceneStorage() {
        // @SceneStorage persists the raw value; a renamed case would silently
        // reset every user's restored section to Record.
        for item in SidebarItem.allCases {
            XCTAssertEqual(SidebarItem(rawValue: item.rawValue), item)
        }
        XCTAssertEqual(SidebarItem.allCases.map(\.rawValue), ["Record", "Transcripts", "Summaries", "Setup"])
    }
}
