//
//  CloudSyncIntent.swift
//  BisonNotes AI
//
//  The vocabulary callers use to ask CloudSyncOperationCoordinator for work and
//  to read back what happened. It lives apart from the coordinator because four
//  other files reason about intents without touching the serialization itself.
//

import Foundation

// MARK: - Intents

enum CloudSyncIntent: String, CaseIterable, Sendable {
    /// The ordinary bidirectional pass: tombstones, snapshot, winners, manifest.
    case routineSnapshot
    /// Durable outbound deletions. Never waits behind maintenance throttling.
    case deletionFlush
    /// "Back Up Now" — this device is the source.
    case seedFromThisDevice
    /// "Restore From iCloud" — the cloud is the source.
    case restoreToThisDevice
    /// Explicit full-cloud repair/diagnostics. The local report never requests it.
    case fullRepair
    /// Cloud-only review discovery.
    case reviewScan
    /// "Erase All iCloud Data".
    case erase

    /// Higher wins when choosing which queued request becomes the follow-up.
    var priority: Int {
        switch self {
        case .erase, .fullRepair, .restoreToThisDevice, .seedFromThisDevice:
            return 3
        case .deletionFlush:
            return 2
        case .routineSnapshot:
            return 1
        case .reviewScan:
            return 0
        }
    }

    /// True when running this puts content back into CloudKit.
    ///
    /// A restore reads the cloud, but neither of its paths only reads it: a review
    /// restore reactivates the selected records and adds them to the manifest, and
    /// a full restore flushes queued deletion markers before it reads. Either one,
    /// run against the container the user has just emptied, repopulates it after
    /// the erase has already reported itself finished.
    var writesToCloud: Bool {
        switch self {
        case .routineSnapshot, .deletionFlush, .seedFromThisDevice, .fullRepair, .restoreToThisDevice:
            return true
        case .reviewScan, .erase:
            return false
        }
    }

    /// True when running this can write audio files into Documents.
    ///
    /// The restore leg installs a CloudKit asset and only then assigns the
    /// recording's URL, with the save batched after the loop, so a file on disk
    /// may not yet be referenced by a saved row. Maintenance that deletes
    /// unreferenced audio must stand down for all of these — not only the
    /// user-initiated restore, since `routineSnapshot` runs the same leg.
    var installsLocalAudio: Bool {
        switch self {
        case .restoreToThisDevice, .routineSnapshot, .fullRepair:
            return true
        case .seedFromThisDevice, .deletionFlush, .reviewScan, .erase:
            return false
        }
    }

    /// True when a run of `self` already does everything `other` would have done.
    func subsumes(_ other: CloudSyncIntent) -> Bool {
        if self == other { return true }
        switch (self, other) {
        case (.fullRepair, .routineSnapshot), (.fullRepair, .reviewScan), (.fullRepair, .deletionFlush):
            return true
        case (.routineSnapshot, .deletionFlush):
            // A routine pass flushes durable tombstones as its first phase.
            return true
        default:
            return false
        }
    }
}

/// Thrown to work that was still queued when the user erased their iCloud data.
/// Running it afterwards would put the content straight back — which is the one
/// thing someone who just erased their cloud copy did not ask for.
struct CloudSyncSupersededByEraseError: LocalizedError, Equatable {
    var errorDescription: String? {
        "This sync was cancelled because iCloud data was erased. " +
            "Use Back Up Now when you want this device's data in iCloud again."
    }
}

enum CloudSyncRunOutcome: Equatable {
    /// This request's own work ran.
    case completed
    /// A running operation already covered this request; its work did not run again.
    case joinedRunningOperation(CloudSyncIntent)
    /// Folded into a single follow-up run, which has now finished.
    case coalescedIntoFollowUp(CloudSyncIntent)
    /// CloudKit asked for a backoff longer than a foreground wait. Nothing was sent.
    case deferred(until: Date)
}
