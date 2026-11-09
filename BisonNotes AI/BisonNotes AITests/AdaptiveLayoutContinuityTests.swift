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

/// The list/detail split asks this before replacing an editor in its detail
/// column; a wrong answer silently drops the user's transcript edits.
@MainActor
final class UnsavedEditsGuardTests: XCTestCase {
    func testReportsTheRegisteredEditorsDirtyState() {
        let guardian = UnsavedEditsGuard()
        let editor = UUID()
        guardian.register(owner: editor, save: { true })
        XCTAssertFalse(guardian.hasUnsavedChanges)

        guardian.update(owner: editor, hasUnsavedChanges: true)
        XCTAssertTrue(guardian.hasUnsavedChanges)
    }

    func testOutgoingEditorCannotClearTheIncomingOne() {
        let guardian = UnsavedEditsGuard()
        let outgoing = UUID()
        let incoming = UUID()
        guardian.register(owner: outgoing, save: { true })

        // SwiftUI can show the new editor before the old one disappears.
        guardian.register(owner: incoming, save: { true })
        guardian.update(owner: incoming, hasUnsavedChanges: true)
        guardian.update(owner: outgoing, hasUnsavedChanges: false)
        guardian.unregister(owner: outgoing)

        XCTAssertEqual(guardian.owner, incoming)
        XCTAssertTrue(guardian.hasUnsavedChanges)
    }

    func testSaveReportsTheEditorsResult() {
        let guardian = UnsavedEditsGuard()
        XCTAssertFalse(guardian.save(), "No editor registered means nothing was saved.")

        let editor = UUID()
        var saves = 0
        guardian.register(owner: editor, save: { saves += 1; return false })
        XCTAssertFalse(guardian.save())
        XCTAssertEqual(saves, 1)

        guardian.unregister(owner: editor)
        XCTAssertNil(guardian.owner)
        XCTAssertFalse(guardian.hasUnsavedChanges)
        XCTAssertFalse(guardian.save())
    }
}

/// What a collapsed `ListDetailSplitView` does when its column changes. It must
/// never end the selection itself, and it must never leave a detail that holds
/// unsaved work.
@MainActor
final class ListDetailSplitColumnTests: XCTestCase {
    private typealias Split = ListDetailSplitView<EmptyView, EmptyView>

    func testASelectionOpensOnTheDetailUnlessTheUserWentBack() {
        XCTAssertEqual(Split.initialColumn(selectionID: "a", detailDismissed: false), .detail)
        XCTAssertEqual(Split.initialColumn(selectionID: "a", detailDismissed: true), .sidebar)
        XCTAssertEqual(Split.initialColumn(selectionID: nil, detailDismissed: false), .sidebar)
    }

    func testLeavingADetailWithUnsavedWorkIsRefused() {
        XCTAssertEqual(
            Split.columnAfterChange(to: .sidebar, selectionID: "a", allowsLeavingDetail: false),
            .detail,
            "A swipe or a system reset must not pop an editor with unsaved edits"
        )
        XCTAssertEqual(Split.columnAfterChange(to: .sidebar, selectionID: "a", allowsLeavingDetail: true), .sidebar)
        XCTAssertEqual(
            Split.columnAfterChange(to: .sidebar, selectionID: nil, allowsLeavingDetail: false),
            .sidebar,
            "With nothing selected there is no detail to protect"
        )
        XCTAssertEqual(Split.columnAfterChange(to: .detail, selectionID: "a", allowsLeavingDetail: false), .detail)
    }

    func testTheEditorCanAskForItsOwnPrompt() {
        let guardian = UnsavedEditsGuard()
        var prompts = 0
        guardian.register(owner: UUID(), save: { true }, requestClose: { prompts += 1 })
        guardian.requestClose()
        XCTAssertEqual(prompts, 1)
    }
}

/// Record, the player and Setup lay out around iPhone Duo's fold, and show
/// their secondary content only where ArrangementView really put it.
@MainActor
final class RecordArrangementTests: XCTestCase {
    func testTheFoldDecidesTheSplit() {
        // Book pose: the fold runs down the screen — side by side.
        XCTAssertEqual(ArrangementSplit.axes(forDivisions: [CGRect(x: 500, y: 0, width: 20, height: 900)]), .horizontal)
        // Laptop pose: the fold runs across it — top and bottom.
        XCTAssertEqual(ArrangementSplit.axes(forDivisions: [CGRect(x: 0, y: 500, width: 900, height: 20)]), .vertical)
        // No fold (iPad, flat): side by side, never a narrow top/bottom split.
        XCTAssertEqual(ArrangementSplit.axes(forDivisions: []), .horizontal)
    }

    func testThePrimaryAloneIsNotASplit() {
        // iPhone portrait, the Duo's outer display: the primary fills it.
        XCTAssertEqual(ArrangementSplit.layout(primarySize: CGSize(width: 402, height: 874), arrangementSize: CGSize(width: 402, height: 874)), .single)
        // iPad landscape or the book pose: two halves side by side.
        XCTAssertEqual(ArrangementSplit.layout(primarySize: CGSize(width: 465, height: 834), arrangementSize: CGSize(width: 930, height: 834)), .sideBySide)
        // Laptop pose: the primary has the full width and the top half.
        XCTAssertEqual(ArrangementSplit.layout(primarySize: CGSize(width: 900, height: 480), arrangementSize: CGSize(width: 900, height: 980)), .topAndBottom)
        // Not measured yet: assume one column, so nothing is out of reach.
        XCTAssertEqual(ArrangementSplit.layout(primarySize: .zero, arrangementSize: CGSize(width: 930, height: 834)), .single)
    }
}

/// Which transcript segment the player's read-along highlights.
@MainActor
final class PlayerTranscriptTests: XCTestCase {
    private let segments = [
        TranscriptSegment(speaker: "A", text: "one", startTime: 0, endTime: 4),
        TranscriptSegment(speaker: "B", text: "two", startTime: 4, endTime: 9),
        TranscriptSegment(speaker: "A", text: "three", startTime: 12, endTime: 15)
    ]

    func testTheSegmentThatHasStartedIsCurrent() {
        XCTAssertEqual(PlayerTranscriptView.segmentIndex(at: 0, in: segments), 0)
        XCTAssertEqual(PlayerTranscriptView.segmentIndex(at: 5, in: segments), 1)
        XCTAssertEqual(PlayerTranscriptView.segmentIndex(at: 10, in: segments), 1, "A gap keeps the last segment")
        XCTAssertEqual(PlayerTranscriptView.segmentIndex(at: 30, in: segments), 2)
        XCTAssertNil(PlayerTranscriptView.segmentIndex(at: 0, in: []))
    }

    func testTimeLabels() {
        XCTAssertEqual(PlayerTranscriptView.timeLabel(0), "0:00")
        XCTAssertEqual(PlayerTranscriptView.timeLabel(65.9), "1:05")
        XCTAssertEqual(PlayerTranscriptView.timeLabel(3_600), "60:00")
    }
}

/// Action Button support is decided by model identifier; there is no API.
final class ActionButtonSupportTests: XCTestCase {
    func testIPhoneDuoHasNoActionButton() {
        XCTAssertFalse(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone19,4"))
    }

    func testActionButtonIPhones() {
        XCTAssertTrue(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone16,1"), "iPhone 15 Pro")
        XCTAssertTrue(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone16,2"), "iPhone 15 Pro Max")
        XCTAssertTrue(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone17,1"))
        XCTAssertTrue(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone19,1"))
    }

    func testOlderIPhonesAndOtherDevicesHaveNone() {
        XCTAssertFalse(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone16,3"), "iPhone 15")
        XCTAssertFalse(DeviceCapabilities.hasActionButton(modelIdentifier: "iPhone15,2"))
        XCTAssertFalse(DeviceCapabilities.hasActionButton(modelIdentifier: "iPad16,3"))
        XCTAssertFalse(DeviceCapabilities.hasActionButton(modelIdentifier: "arm64"))
    }
}
