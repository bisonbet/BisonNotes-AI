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

/// The Record screen shows its library and import actions beside the controls
/// only when ArrangementView really put a secondary there.
@MainActor
final class RecordArrangementTests: XCTestCase {
    func testThePrimaryAloneIsNotASplit() {
        // iPhone portrait, the Duo's outer display: the primary fills it.
        XCTAssertFalse(RecordingsView.isArrangementSplit(primaryWidth: 402, arrangementWidth: 402))
        XCTAssertFalse(RecordingsView.isArrangementSplit(primaryWidth: 382, arrangementWidth: 382))
        // iPad landscape: two halves.
        XCTAssertTrue(RecordingsView.isArrangementSplit(primaryWidth: 465, arrangementWidth: 930))
        // Not measured yet: assume one column, so nothing is out of reach.
        XCTAssertFalse(RecordingsView.isArrangementSplit(primaryWidth: 0, arrangementWidth: 930))
        XCTAssertFalse(RecordingsView.isArrangementSplit(primaryWidth: 465, arrangementWidth: 0))
    }
}
