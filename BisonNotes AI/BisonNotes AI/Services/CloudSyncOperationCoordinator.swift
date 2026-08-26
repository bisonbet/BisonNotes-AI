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

    var isRunning: Bool { currentTask != nil }
    var hasPendingFollowUp: Bool { !pending.isEmpty }
    /// Distinct jobs waiting. Equivalent requests collapse, independent ones do not.
    var pendingFollowUpCount: Int { pending.count }

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
        guard let running = runningIntent, let currentTask else {
            try await run(intent: intent, work: work)
            return .completed
        }

        if allowJoiningRunningOperation, coalescesWithEquivalentRequests, running.subsumes(intent) {
            // If the run we are riding on fails, this request failed with it.
            try await currentTask.value
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
        }

        var ranOwnWork = false
        while !satisfiedWaiters.contains(waiterID) {
            if let task = self.currentTask {
                // Another run's failure is not this request's to report; the run
                // covering this request delivers its error through `failuresByWaiter`.
                _ = try? await task.value
                // Awaiting an already-finished task can return without suspending,
                // and the run that owns it clears `currentTask` from its own
                // continuation. Without an explicit yield this loop can spin on the
                // main actor and never let that continuation run.
                await Task.yield()
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

    private func run(
        intent: CloudSyncIntent,
        work: @escaping Work,
        satisfying waiters: Set<Int> = []
    ) async throws {
        let task = Task { @MainActor in
            try await work()
        }
        currentTask = task
        runningIntent = intent

        do {
            try await task.value
        } catch {
            finishRun(intent: intent, satisfying: waiters, error: error)
            throw error
        }
        finishRun(intent: intent, satisfying: waiters, error: nil)
    }

    private func finishRun(intent: CloudSyncIntent, satisfying waiters: Set<Int>, error: (any Error)?) {
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
