//
//  CloudSyncOperationCoordinator.swift
//  BisonNotes AI
//
//  Every CloudKit operation in the app funnels through one coordinator, so two
//  legs can never interleave against the same records. Requests that arrive while
//  work is running either join that run or collapse into a single follow-up —
//  never a queue of duplicates, and never a silent no-op that a caller could
//  mistake for a successful empty sync.
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
    /// Database Tools repair. Allowed to query and scan zones.
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

// MARK: - Coordinator

@MainActor
final class CloudSyncOperationCoordinator {
    typealias Work = @MainActor () async throws -> Void

    private(set) var runningIntent: CloudSyncIntent?
    /// Runs that actually executed work. Orchestration tests assert on this.
    private(set) var completedRunCount = 0
    private(set) var lastCompletedIntent: CloudSyncIntent?

    private var currentTask: Task<Void, any Error>?
    private var followUp: (intent: CloudSyncIntent, work: Work)?

    var isRunning: Bool { currentTask != nil }
    var hasPendingFollowUp: Bool { followUp != nil }

    /// Submits work, waiting until either it or the run that covers it has finished.
    ///
    /// - Parameter allowJoiningRunningOperation: pass `false` for work whose input
    ///   changed after the running operation read its snapshot — a user deletion,
    ///   or an explicit user-initiated transfer — so it is guaranteed its own pass.
    @discardableResult
    func submit(
        intent: CloudSyncIntent,
        allowJoiningRunningOperation: Bool = true,
        work: @escaping Work
    ) async throws -> CloudSyncRunOutcome {
        guard let running = runningIntent, let currentTask else {
            try await run(intent: intent, work: work)
            return .completed
        }

        if allowJoiningRunningOperation, running.subsumes(intent) {
            _ = try? await currentTask.value
            return .joinedRunningOperation(running)
        }

        // At most one follow-up exists at a time; the highest-priority intent to
        // arrive owns it, and every other waiter rides on its completion.
        if let existing = followUp {
            if intent.priority > existing.intent.priority {
                followUp = (intent, work)
            }
        } else {
            followUp = (intent, work)
        }
        let coalescedInto = followUp?.intent ?? intent

        while true {
            if let task = self.currentTask {
                _ = try? await task.value
                // Awaiting an already-finished task can return without suspending,
                // and the run that owns it clears `currentTask` from its own
                // continuation. Without an explicit yield this loop can spin on the
                // main actor and never let that continuation run.
                await Task.yield()
                continue
            }
            if let pending = followUp {
                followUp = nil
                try await run(intent: pending.intent, work: pending.work)
            }
            return .coalescedIntoFollowUp(coalescedInto)
        }
    }

    private func run(intent: CloudSyncIntent, work: @escaping Work) async throws {
        let task = Task { @MainActor in
            try await work()
        }
        currentTask = task
        runningIntent = intent

        do {
            try await task.value
        } catch {
            finishRun(intent: intent)
            throw error
        }
        finishRun(intent: intent)
    }

    private func finishRun(intent: CloudSyncIntent) {
        currentTask = nil
        runningIntent = nil
        completedRunCount += 1
        lastCompletedIntent = intent
    }

    #if DEBUG
    func resetCountersForTesting() {
        completedRunCount = 0
        lastCompletedIntent = nil
    }
    #endif
}
