//
//  AppCommandFocus.swift
//  BisonNotes AI
//

import SwiftUI

/// An action supplied by the currently focused summary scene so app-level
/// commands act on one window instead of broadcasting to every open summary.
struct SummaryExportAction {
    let perform: () -> Void
}

private struct SummaryExportActionKey: FocusedValueKey {
    typealias Value = SummaryExportAction
}

extension FocusedValues {
    var summaryExportAction: SummaryExportAction? {
        get { self[SummaryExportActionKey.self] }
        set { self[SummaryExportActionKey.self] = newValue }
    }
}
