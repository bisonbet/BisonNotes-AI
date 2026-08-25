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

/// An action supplied by the currently focused transcript editor so the app's
/// File > Save command targets only the active document window.
struct TranscriptSaveAction {
    let perform: () -> Void
}

private struct SummaryExportActionKey: FocusedValueKey {
    typealias Value = SummaryExportAction
}

private struct TranscriptSaveActionKey: FocusedValueKey {
    typealias Value = TranscriptSaveAction
}

extension FocusedValues {
    var summaryExportAction: SummaryExportAction? {
        get { self[SummaryExportActionKey.self] }
        set { self[SummaryExportActionKey.self] = newValue }
    }

    var transcriptSaveAction: TranscriptSaveAction? {
        get { self[TranscriptSaveActionKey.self] }
        set { self[TranscriptSaveActionKey.self] = newValue }
    }
}
