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

// MARK: - Coordinator

@MainActor
final class CloudSyncOperationCoordinator {
    typealias Work = @MainActor () async throws -> Void

    /// Work waiting for the current run to finish.
    ///
    /// Two requests share an entry only when one intent subsumes the other — a
    /// second routine snapshot rides along with the first, but a queued restore
    /// and a queued upload are different jobs and both have to happen. Dropping
    /// one on priority alone let its caller believe the work was done: an
    /// auto-backup that lost the slot returned an empty result, and the device
    /// then cleared its pending-changes flag with the edits still unsent.
    private struct PendingRun {
        var intent: CloudSyncIntent
        var work: Work
        /// Submitters this entry will satisfy when it runs.
        var waiters: Set<Int>
        /// False for work whose caller reads a result out of its own closure.
        /// Collapsing two of those would hand the loser an untouched, zero-valued
        /// result that reads as a completed transfer — and silently drop whatever
        /// options its closure had captured.
        var allowsCoalescing: Bool
    }

    private(set) var runningIntent: CloudSyncIntent?
    /// Runs that actually executed work. Orchestration tests assert on this.
    private(set) var completedRunCount = 0
    private(set) var lastCompletedIntent: CloudSyncIntent?

    private var currentTask: Task<Void, any Error>?
    private var pending: [PendingRun] = []
    private var satisfiedWaiters: Set<Int> = []
    /// Errors from a run, addressed to every submitter that run was covering.
    /// A shared run's failure belongs to all of them: without this, the waiters
    /// that did not execute it returned a coalesced outcome and their callers
    /// reported a zero-valued transfer as though it had succeeded.
    private var failuresByWaiter: [Int: any Error] = [:]
    private var nextWaiterID = 0

    private var isCacheMaintenanceInProgress = false
    private var cacheMaintenanceYieldRequested = false
    private let cacheMaintenancePollNanoseconds: UInt64 = 25_000_000

    /// Identifies each run so a joiner can wait for *its* run rather than for the
    /// queue to fall idle. Runs are strictly sequential, so "run N has finished"
    /// is `finishedRunID >= N`.
    private var nextRunID = 0
    private var currentRunID = -1
    private var finishedRunID = -1

    var isRunning: Bool { currentTask != nil }
    var hasPendingFollowUp: Bool { !pending.isEmpty }
    /// Distinct jobs waiting. Equivalent requests collapse, independent ones do not.
    var pendingFollowUpCount: Int { pending.count }

    /// Reserves the CloudKit side of the cache-maintenance exclusion. The sweep
    /// runs off the main actor, so this reservation keeps a new sync from starting
    /// while the filesystem pass is deleting assets.
    @discardableResult
    func beginCacheMaintenance() -> Bool {
        guard currentTask == nil, pending.isEmpty, !isCacheMaintenanceInProgress else {
            return false
        }
        isCacheMaintenanceInProgress = true
        cacheMaintenanceYieldRequested = false
        return true
    }

    /// A sync or deletion request that arrives during the sweep asks it to stop
    /// at its next per-cache-item checkpoint, then waits for the reservation to
    /// release before starting its own CloudKit work.
    func requestCacheMaintenanceYield() {
        guard isCacheMaintenanceInProgress else { return }
        cacheMaintenanceYieldRequested = true
    }

    var shouldYieldCacheMaintenance: Bool {
        cacheMaintenanceYieldRequested
    }

    func endCacheMaintenance() {
        isCacheMaintenanceInProgress = false
        cacheMaintenanceYieldRequested = false
    }

    /// Submits work, waiting until either it or the run that covers it has finished.
    ///
    /// - Parameter allowJoiningRunningOperation: pass `false` for work whose input
    ///   changed after the running operation read its snapshot — a user deletion,
    ///   or an explicit user-initiated transfer — so it is guaranteed its own pass.
    /// - Parameter coalescesWithEquivalentRequests: pass `false` when the caller
    ///   reads a result out of its own closure, so its work is never replaced by
    ///   an equivalent request's. This also stops the request joining a run
    ///   already in flight: joining has exactly the same effect — the caller's
    ///   closure never runs — and a request that cannot afford to be coalesced
    ///   cannot afford to be joined either.
    @discardableResult
    func submit(
        intent: CloudSyncIntent,
        allowJoiningRunningOperation: Bool = true,
        coalescesWithEquivalentRequests: Bool = true,
        work: @escaping Work
    ) async throws -> CloudSyncRunOutcome {
        try Task.checkCancellation()
        while isCacheMaintenanceInProgress {
            requestCacheMaintenanceYield()
            try await Task.sleep(nanoseconds: cacheMaintenancePollNanoseconds)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()

        guard let running = runningIntent, let currentTask else {
            try await run(intent: intent, work: work)
            return .completed
        }

        if allowJoiningRunningOperation, coalescesWithEquivalentRequests, running.subsumes(intent) {
            // If the run we are riding on fails, this request failed with it.
            try await waitForRunToFinish(currentRunID, task: currentTask)
            return .joinedRunningOperation(running)
        }

        let waiterID = nextWaiterID
        nextWaiterID += 1
        let coalescedInto = enqueue(
            intent: intent,
            work: work,
            waiterID: waiterID,
            allowsCoalescing: coalescesWithEquivalentRequests
        )
        defer {
            satisfiedWaiters.remove(waiterID)
            failuresByWaiter.removeValue(forKey: waiterID)
            cancelWaiter(waiterID)
        }

        var ranOwnWork = false
        while !satisfiedWaiters.contains(waiterID) {
            try Task.checkCancellation()
            if self.currentTask != nil {
                // Do not await the running task directly here. A cancelled waiter
                // must be able to leave while the shared CloudKit operation keeps
                // running for its other callers; polling the actor-owned handle
                // also avoids a cancelled waiter remaining in the queue forever.
                try await Task.sleep(nanoseconds: cacheMaintenancePollNanoseconds)
                continue
            }
            guard let next = takeHighestPriorityPending() else { break }
            ranOwnWork = ranOwnWork || next.waiters.contains(waiterID)
            do {
                try await run(intent: next.intent, work: next.work, satisfying: next.waiters)
            } catch {
                // This may be someone else's job that this submitter happened to
                // drain. Its failure belongs to its own waiters, who receive it
                // through `failuresByWaiter`; throwing here would abandon the loop
                // and leave this request's work with nobody left to run it. Our own
                // failure, if this was our entry, is delivered the same way below.
            }
        }

        if let failure = failuresByWaiter[waiterID] {
            throw failure
        }
        return ranOwnWork ? .completed : .coalescedIntoFollowUp(coalescedInto)
    }

    /// Waits for one specific run, then reports its result.
    ///
    /// Deliberately keyed on `runID` rather than on `currentTask != nil`: follow-up
    /// work can claim the slot in the same main-actor turn the joined run releases
    /// it, so a poller watching the shared handle never observes the idle window
    /// and ends up waiting for the whole queue to drain instead of for the run it
    /// actually joined. Polling — rather than awaiting `task.value` directly — is
    /// what lets a cancelled joiner leave while the run continues for its other
    /// callers.
    private func waitForRunToFinish(_ runID: Int, task: Task<Void, any Error>) async throws {
        while finishedRunID < runID {
            try await Task.sleep(nanoseconds: cacheMaintenancePollNanoseconds)
        }
        try await task.value
    }

    /// Adds this request to the queue, merging it into an existing entry only when
    /// one of the two intents covers the other.
    /// - Returns: the intent whose run will satisfy this request.
    private func enqueue(
        intent: CloudSyncIntent,
        work: @escaping Work,
        waiterID: Int,
        allowsCoalescing: Bool
    ) -> CloudSyncIntent {
        if allowsCoalescing {
            if let index = pending.firstIndex(where: { $0.allowsCoalescing && $0.intent.subsumes(intent) }) {
                // An equivalent or broader job is already queued; ride on it.
                pending[index].waiters.insert(waiterID)
                return pending[index].intent
            }

            if let index = pending.firstIndex(where: { $0.allowsCoalescing && intent.subsumes($0.intent) }) {
                // This request covers one that is queued: take over its waiters
                // rather than leaving them behind.
                pending[index].intent = intent
                pending[index].work = work
                pending[index].waiters.insert(waiterID)
                return intent
            }
        }

        pending.append(
            PendingRun(intent: intent, work: work, waiters: [waiterID], allowsCoalescing: allowsCoalescing)
        )
        return intent
    }

    private func takeHighestPriorityPending() -> PendingRun? {
        guard !pending.isEmpty else { return nil }
        let index = pending.indices.max { pending[$0].intent.priority < pending[$1].intent.priority } ?? 0
        return pending.remove(at: index)
    }

    /// Removes a cancelled caller from queued work without cancelling the shared
    /// run itself. If it was the last waiter, the work is no longer needed and can
    /// be discarded before another submitter drains the queue.
    private func cancelWaiter(_ waiterID: Int) {
        for index in pending.indices.reversed() {
            pending[index].waiters.remove(waiterID)
            if pending[index].waiters.isEmpty {
                pending.remove(at: index)
            }
        }
    }

    private func run(
        intent: CloudSyncIntent,
        work: @escaping Work,
        satisfying waiters: Set<Int> = []
    ) async throws {
        let task = Task { @MainActor in
            try await work()
        }
        let runID = nextRunID
        nextRunID += 1
        currentRunID = runID
        currentTask = task
        runningIntent = intent

        do {
            try await task.value
        } catch {
            finishRun(runID, intent: intent, satisfying: waiters, error: error)
            throw error
        }
        finishRun(runID, intent: intent, satisfying: waiters, error: nil)
    }

    private func finishRun(
        _ runID: Int,
        intent: CloudSyncIntent,
        satisfying waiters: Set<Int>,
        error: (any Error)?
    ) {
        finishedRunID = max(finishedRunID, runID)
        currentTask = nil
        runningIntent = nil
        completedRunCount += 1
        lastCompletedIntent = intent
        // The work ran, successfully or not; nobody should keep waiting for it.
        satisfiedWaiters.formUnion(waiters)
        if let error {
            // Everyone this run was covering asked for work that has now failed.
            for waiter in waiters {
                failuresByWaiter[waiter] = error
            }
        }

        if intent == .erase, error == nil {
            cancelQueuedWorkSupersededByErase()
        }
    }

    /// An upload queued before the user erased iCloud would put the content back
    /// the moment the erase finished. Those entries are dropped and their callers
    /// told why, rather than being run against the container they just emptied.
    private func cancelQueuedWorkSupersededByErase() {
        let superseded = pending.filter { $0.intent.writesToCloud }
        guard !superseded.isEmpty else { return }
        pending.removeAll { $0.intent.writesToCloud }

        for entry in superseded {
            satisfiedWaiters.formUnion(entry.waiters)
            for waiter in entry.waiters {
                failuresByWaiter[waiter] = CloudSyncSupersededByEraseError()
            }
        }
    }

    #if DEBUG
    func resetCountersForTesting() {
        completedRunCount = 0
        lastCompletedIntent = nil
    }
    #endif
}
