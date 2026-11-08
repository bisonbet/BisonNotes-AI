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
/// The caller owns the selection. `hasSelection` drives which column a collapsed
/// split view shows, and `clearSelection` runs when the user backs out of the
/// detail at compact width, so the selection a compact → regular transition
/// sees is always the one on screen.
///
/// The list column hosts its own `NavigationStack`, so a `NavigationLink` inside
/// the list (such as a "Show N more" page) pushes within the list column instead
/// of replacing the detail.
///
/// Do not cap the column widths: on a partly folded iPhone Duo the system
/// rebalances a split view's columns around the fold only when they are free
/// to resize.
struct ListDetailSplitView<ListContent: View, Detail: View>: View {
    let hasSelection: Bool
    let clearSelection: () -> Void
    @ViewBuilder let list: ListContent
    @ViewBuilder let detail: Detail

    @State private var preferredCompactColumn: NavigationSplitViewColumn

    init(
        hasSelection: Bool,
        clearSelection: @escaping () -> Void,
        @ViewBuilder list: () -> ListContent,
        @ViewBuilder detail: () -> Detail
    ) {
        self.hasSelection = hasSelection
        self.clearSelection = clearSelection
        self.list = list()
        self.detail = detail()
        // A selection restored from scene storage opens on the detail when
        // collapsed, so closing iPhone Duo keeps the item on screen.
        _preferredCompactColumn = State(initialValue: hasSelection ? .detail : .sidebar)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            NavigationStack {
                list
            }
        } detail: {
            NavigationStack {
                detail
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: hasSelection) { _, selected in
            preferredCompactColumn = selected ? .detail : .sidebar
        }
        .onChange(of: preferredCompactColumn) { _, column in
            // Only a collapsed split view changes this on its own: the user
            // went back to the list.
            if column == .sidebar && hasSelection {
                clearSelection()
            }
        }
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
