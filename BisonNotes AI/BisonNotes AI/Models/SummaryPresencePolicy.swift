//
//  SummaryPresencePolicy.swift
//  BisonNotes AI
//

import Foundation

/// Decides whether persisted recording metadata proves that a summary exists.
/// The relationship and identifier outrank the cached processing status because
/// older regeneration and restore paths could leave that cache as "Not Started."
enum SummaryPresencePolicy {
    static func hasStoredSummary(
        relationshipExists: @autoclosure () -> Bool,
        summaryID: UUID?,
        status: String?
    ) -> Bool {
        summaryID != nil ||
            status == ProcessingStatus.completed.rawValue ||
            relationshipExists()
    }
}

extension RecordingEntry {
    var hasStoredSummary: Bool {
        SummaryPresencePolicy.hasStoredSummary(
            relationshipExists: summary != nil,
            summaryID: summaryId,
            status: summaryStatus
        )
    }
}
