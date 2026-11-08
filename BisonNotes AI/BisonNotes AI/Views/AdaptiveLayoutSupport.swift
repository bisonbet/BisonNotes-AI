//
//  AdaptiveLayoutSupport.swift
//  BisonNotes AI
//
//  Shared containers for layouts that adapt across iPhone, iPad and iPhone Duo.
//

import SwiftUI

#if os(iOS)
/// A list with its detail beside it at regular width, collapsing to a push at
/// compact width (the Mail pattern Apple asks for on iPhone Duo's inner display).
///
/// The caller owns the selection and passes its identity as `selectionID`.
/// `clearSelection` runs when the user backs out of the detail at compact
/// width, so the selection a compact → regular transition sees is always the
/// one on screen.
///
/// **Every open must reveal the detail.** A collapsed split view shows whichever
/// column `preferredCompactColumn` names, and the system can reset that on its
/// own (opening or closing iPhone Duo, a scene restored with a selection). Driving
/// it only from "has a selection" changes left a stale selection with the list on
/// screen: tapping another row changed the id but not that flag, and nothing
/// happened. So the column follows every change of `selectionID`, and
/// `revealToken` — bumped by the caller on every tap, including a tap on the row
/// that is already selected — brings the detail forward even when the id did
/// not change.
///
/// **Never push a page inside the list column.** When the split view is
/// collapsed, a page pushed there sits under the detail, and switching to the
/// detail column shows nothing — every row on a "Show N more" page did nothing
/// when tapped on iPhone and iPhone Duo. Show such pages in place with state
/// (the lists' "Show N more" swaps the list content and adds a back button).
///
/// Do not cap the column widths: on a partly folded iPhone Duo the system
/// rebalances a split view's columns around the fold only when they are free
/// to resize.
struct ListDetailSplitView<ListContent: View, Detail: View>: View {
    let selectionID: String?
    let revealToken: Int
    let clearSelection: () -> Void
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: Detail

    @State private var preferredCompactColumn: NavigationSplitViewColumn

    init(
        selectionID: String?,
        revealToken: Int,
        clearSelection: @escaping () -> Void,
        @ViewBuilder list: () -> ListContent,
        @ViewBuilder detail: () -> Detail
    ) {
        self.selectionID = selectionID
        self.revealToken = revealToken
        self.clearSelection = clearSelection
        self.list = list()
        self.detail = detail()
        // A selection restored from scene storage opens on the detail when
        // collapsed, so closing iPhone Duo keeps the item on screen.
        _preferredCompactColumn = State(initialValue: selectionID != nil ? .detail : .sidebar)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            list
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selectionID) { _, newSelection in
            preferredCompactColumn = Self.column(forSelection: newSelection)
        }
        .onChange(of: revealToken) { _, _ in
            preferredCompactColumn = Self.column(forSelection: selectionID)
        }
        .onChange(of: preferredCompactColumn) { _, column in
            // Only a collapsed split view changes this on its own: the user
            // went back to the list.
            if column == .sidebar && selectionID != nil {
                clearSelection()
            }
        }
    }

    static func column(forSelection selectionID: String?) -> NavigationSplitViewColumn {
        selectionID == nil ? .sidebar : .detail
    }
}
#endif

// MARK: - Embedded detail presentation

/// How a detail view is hosted. A detail in a split-view column has no Done
/// button and must not wrap itself in another `NavigationStack`; closing it
/// clears the selection instead of dismissing a sheet.
struct EmbeddedDetailClose {
    let action: () -> Void
    func callAsFunction() { action() }
}

extension EnvironmentValues {
    /// Non-nil when the current detail view is embedded in a list/detail split.
    @Entry var embeddedDetailClose: EmbeddedDetailClose? = nil
}

// MARK: - Unsaved edits in an embedded editor

/// Lets a list ask the editor in its detail column whether it holds unsaved
/// work before replacing it. A sheet guards its editor by blocking dismissal;
/// a column has no dismissal to block, so selecting another row would
/// otherwise drop the edits silently.
///
/// The editor registers itself on appear and reports its dirty state; the
/// list checks `hasUnsavedChanges` before changing the selection and can ask
/// the editor to `save()` first. `owner` keeps an outgoing editor's late
/// `onDisappear` from clearing the incoming editor's registration.
@MainActor
final class UnsavedEditsGuard {
    private(set) var owner: UUID?
    private(set) var hasUnsavedChanges = false
    private var saveAction: (() -> Bool)?

    func register(owner: UUID, save: @escaping () -> Bool) {
        self.owner = owner
        saveAction = save
        hasUnsavedChanges = false
    }

    func update(owner: UUID, hasUnsavedChanges: Bool) {
        guard self.owner == owner else { return }
        self.hasUnsavedChanges = hasUnsavedChanges
    }

    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil
        saveAction = nil
        hasUnsavedChanges = false
    }

    /// Saves the registered editor. False when the save failed (the editor
    /// shows its own error) or no editor is registered.
    func save() -> Bool {
        saveAction?() ?? false
    }
}

extension EnvironmentValues {
    /// Set by a list that hosts an editor in its detail column.
    @Entry var unsavedEditsGuard: UnsavedEditsGuard? = nil
}
