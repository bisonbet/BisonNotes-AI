//
//  TranscriptCleanupQueue.swift
//  BisonNotes AI
//
//  Runs automatic transcript cleanup after the raw transcript is saved.
//
//  Cleanup used to run before the transcript was saved, inside the job that
//  produced it: a slow pass delayed the transcript, and backgrounding or a kill
//  lost the completed transcription with it. Now the job saves first and leaves
//  a durable intent here. The queue runs intents one at a time while the app is
//  in the foreground — iOS refuses GPU work from a backgrounded app, and MLX runs
//  on the GPU — pauses when it leaves, and resumes from a per-recording
//  checkpoint of finished passages.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Checkpoint

/// Finished cleanup passages for one recording, on disk.
///
/// Keys come from `TranscriptCleanupCoordinator.checkpointKey`, which hashes the
/// passage text, so an edited segment never reuses a stale result. A checkpoint
/// written by a different model revision or prompt version is discarded whole.
/// Failing to write one is logged and otherwise ignored: a checkpoint only saves
/// work, it never decides what is correct.
///
/// Get instances from `TranscriptCleanupCheckpointStore.checkpoint(for:)`, which
/// hands every caller the same one per file. Two instances with separate
/// in-memory copies would overwrite each other's entries on disk. Writes are
/// batched — every passage used to rewrite the whole file, which is quadratic
/// over a long transcript — and `flush` makes the rest durable when a run ends.
actor TranscriptCleanupFileCheckpoint: TranscriptCleanupCheckpointing {
    private struct Payload: Codable {
        var modelRevision: String
        var promptVersion: String
        var updatedAt: Date
        var pieces: [String: TranscriptCleanupPieceOutcome]

        static func empty() -> Payload {
            Payload(
                modelRevision: TranscriptCleanupSettings.modelRevision,
                promptVersion: TranscriptCleanupSettings.promptVersion,
                updatedAt: Date(),
                pieces: [:]
            )
        }

        var isCurrent: Bool {
            modelRevision == TranscriptCleanupSettings.modelRevision
                && promptVersion == TranscriptCleanupSettings.promptVersion
        }
    }

    /// A kill loses at most this many finished passages.
    static let writeBatchSize = 8
    static let writeInterval: TimeInterval = 5

    nonisolated let url: URL
    private var payload: Payload?
    /// Set when the checkpoint's transcript or recording is deleted. A run
    /// holding this instance can still be finishing a passage; without this,
    /// its `record` and `flush` re-created the file with the deleted text.
    private var isInvalidated = false
    private var unwrittenCount = 0
    private var lastWrite = Date.distantPast
    /// The invalidation of a discarded instance for the same file. Until it
    /// finishes, that instance's delayed delete could remove this one's writes,
    /// or its last write could hand this one the deleted text, so every file
    /// access waits for it first.
    private var predecessor: Task<Void, Never>?

    init(url: URL, after predecessor: Task<Void, Never>? = nil) {
        self.url = url
        self.predecessor = predecessor
    }

    private func awaitPredecessor() async {
        guard let predecessor else { return }
        await predecessor.value
        self.predecessor = nil
    }

    func outcome(forPiece key: String) async -> TranscriptCleanupPieceOutcome? {
        await awaitPredecessor()
        return loadedPayload().pieces[key]
    }

    func record(_ outcome: TranscriptCleanupPieceOutcome, forPiece key: String) async {
        await awaitPredecessor()
        guard !isInvalidated else { return }
        var current = loadedPayload()
        current.pieces[key] = outcome
        current.updatedAt = Date()
        payload = current
        unwrittenCount += 1
        if unwrittenCount >= Self.writeBatchSize || Date().timeIntervalSince(lastWrite) >= Self.writeInterval {
            write()
        }
    }

    func flush() async {
        await awaitPredecessor()
        guard !isInvalidated else { return }
        if unwrittenCount > 0 { write() }
    }

    /// Deletes the file and ignores every later write, permanently. For a
    /// deleted transcript or recording, whose text must not come back.
    func invalidate() {
        isInvalidated = true
        remove()
    }

    var hasBeenInvalidated: Bool { isInvalidated }

    /// Number of finished passages on record. The queue compares it across a
    /// time-limited run to tell progress from a stall.
    func recordedPieceCount() async -> Int {
        await awaitPredecessor()
        return loadedPayload().pieces.count
    }

    func remove() {
        payload = .empty()
        unwrittenCount = 0
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.shared.transcription(
                "[TranscriptCleanup] Could not remove the cleanup checkpoint: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func write() {
        guard let payload else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(payload).write(to: url, options: .atomic)
            AppFileProtection.apply(to: url)
            unwrittenCount = 0
            lastWrite = Date()
        } catch {
            AppLog.shared.transcription(
                "[TranscriptCleanup] Could not write the cleanup checkpoint: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func loadedPayload() -> Payload {
        if isInvalidated { return .empty() }
        if let payload { return payload }
        let loaded: Payload
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data),
           decoded.isCurrent {
            loaded = decoded
        } else {
            loaded = .empty()
        }
        payload = loaded
        return loaded
    }
}

enum TranscriptCleanupCheckpointStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TranscriptCleanup/Checkpoints", isDirectory: true)
    }

    /// Held weakly: an instance lives only while a run or editor holds it, so
    /// a finished recording's cleaned passages do not stay in memory for the
    /// life of the process. The next caller reloads the file.
    private final class WeakCheckpoint {
        weak var value: TranscriptCleanupFileCheckpoint?
        init(_ value: TranscriptCleanupFileCheckpoint) { self.value = value }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var instances: [URL: WeakCheckpoint] = [:]
    /// Invalidations of discarded instances still running, by file. A new
    /// instance for the same file waits for its entry before touching it.
    nonisolated(unsafe) private static var invalidations: [URL: Task<Void, Never>] = [:]

    static func url(for recordingId: UUID, in directory: URL = directory) -> URL {
        directory.appendingPathComponent("\(recordingId.uuidString).json", isDirectory: false)
    }

    /// The one live checkpoint instance for this recording's file.
    static func checkpoint(for recordingId: UUID, in directory: URL = directory) -> TranscriptCleanupFileCheckpoint {
        let url = url(for: recordingId, in: directory)
        lock.lock()
        defer { lock.unlock() }
        if let existing = instances[url]?.value { return existing }
        instances = instances.filter { $0.value.value != nil }
        let created = TranscriptCleanupFileCheckpoint(url: url, after: invalidations[url])
        instances[url] = WeakCheckpoint(created)
        return created
    }

    /// Deletes a recording's checkpoint — it holds that recording's cleaned
    /// text — and invalidates the instance, so a run still holding it cannot
    /// write it back. A later cleanup of the same recording gets a new one.
    ///
    /// The invalidation runs on the checkpoint's actor after any write already
    /// in progress, and itself deletes the file; whatever order the two land
    /// in, no file survives. A replacement transcript is often queued at once,
    /// so a new instance for the same file waits for that invalidation before
    /// its first read or write — the delayed delete cannot remove its work.
    static func discard(for recordingId: UUID, in directory: URL = directory) {
        let url = url(for: recordingId, in: directory)
        lock.lock()
        if let instance = instances.removeValue(forKey: url)?.value {
            let earlier = invalidations[url]
            let invalidation = Task {
                await earlier?.value
                await instance.invalidate()
            }
            invalidations[url] = invalidation
            Task {
                await invalidation.value
                forget(invalidation, for: url)
            }
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }

    private static func forget(_ invalidation: Task<Void, Never>, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        if invalidations[url] == invalidation {
            invalidations[url] = nil
        }
    }

    /// Removes checkpoints nobody has touched for `maximumAge`, except those
    /// in `keeping`. A finished or abandoned run's checkpoint is otherwise only
    /// deleted by the run that publishes it, or when its transcript or recording
    /// is deleted. A queued cleanup's checkpoint is never pruned for age: an app
    /// left closed for a week would otherwise redo every finished passage.
    static func prune(
        maximumAge: TimeInterval,
        in directory: URL = directory,
        keeping pendingRecordingIds: Set<UUID> = [],
        now: Date = Date()
    ) {
        let keptNames = Set(pendingRecordingIds.map { url(for: $0, in: directory).lastPathComponent })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        for file in files where file.pathExtension == "json" && !keptNames.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > maximumAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - Queue

/// One recording whose saved transcript should be cleaned. `source` is the
/// transcript as it was saved; an intent whose transcript has changed since is
/// dropped, because its result would describe text that no longer exists.
struct TranscriptCleanupIntent: Codable, Equatable, Sendable {
    let recordingId: UUID
    let source: TranscriptCleanupSourceSnapshot
    let languageCode: String?
    let enqueuedAt: Date
}

/// Reads and writes the transcripts the queue cleans. Injected so the queue's
/// ordering, staleness and pause behavior can be tested without Core Data.
@MainActor
protocol TranscriptCleanupQueueStore {
    var isAvailable: Bool { get }
    func transcript(for recordingId: UUID) throws -> TranscriptData?
    /// Replaces the recording's transcript segments with cleaned ones,
    /// keeping its identity, mappings and metadata.
    func saveCleanedSegments(_ segments: [TranscriptSegment], for transcript: TranscriptData, recordingId: UUID) throws
}

@MainActor
struct AppTranscriptCleanupQueueStore: TranscriptCleanupQueueStore {
    private var coordinator: AppDataCoordinator? { EnhancedFileManager.shared.getCoordinator() }

    var isAvailable: Bool { coordinator != nil }

    func transcript(for recordingId: UUID) throws -> TranscriptData? {
        guard let coordinator else { return nil }
        return try coordinator.coreDataManager.fetchTranscriptData(for: recordingId)
    }

    func saveCleanedSegments(_ segments: [TranscriptSegment], for transcript: TranscriptData, recordingId: UUID) throws {
        guard let coordinator else {
            throw BackgroundProcessingError.processingFailed("App data is unavailable while saving the cleaned transcript")
        }
        guard try coordinator.addTranscript(
            for: recordingId,
            segments: segments,
            speakerMappings: transcript.speakerMappings,
            engine: transcript.engine,
            processingTime: transcript.processingTime,
            confidence: transcript.confidence
        ) != nil else {
            throw BackgroundProcessingError.processingFailed("The cleaned transcript could not be saved")
        }
    }
}

@MainActor
final class TranscriptCleanupQueue: ObservableObject {
    static let shared = TranscriptCleanupQueue()

    /// Posted when a queued cleanup ends in any way other than a pause. The
    /// `userInfo` carries `recordingId` (UUID), `cleaned` (Bool) and, when there
    /// is something to tell the user, `warning` (String).
    static let didFinishNotification = Notification.Name("TranscriptCleanupQueueDidFinish")
    /// Unused checkpoints are deleted after this long.
    static let checkpointMaximumAge: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var progress: [UUID: TranscriptCleanupProgress] = [:]
    @Published private(set) var activeRecordingId: UUID?
    @Published private(set) var intents: [TranscriptCleanupIntent] = []

    private let coordinator: TranscriptCleanupCoordinator
    private let store: any TranscriptCleanupQueueStore
    private let queueFileURL: URL
    private let checkpointDirectory: URL
    private let canRunNow: @MainActor () -> Bool
    private let isCleanupEnabled: @MainActor () -> Bool
    private let notifyUser: @MainActor (String) -> Void
    private let observesLifecycle: Bool
    private var runTask: Task<Void, Never>?
    /// After a transient failure the queue waits this long before trying the
    /// same intent again, rather than spinning on it.
    private let transientRetryDelay: TimeInterval
    /// Consecutive transient failures after which an intent is given up.
    static let maximumTransientFailures = 3
    private var retryNotBefore: Date?
    private var transientFailures: [UUID: Int] = [:]
    private var started = false
    private var loadedFromDisk = false
    /// Recordings whose transcript editor is open. That editor shows a run's
    /// outcome itself; any other outcome becomes a user notification, because
    /// otherwise a queued run that failed or only partly worked would go unseen.
    private var viewedRecordingIds: [UUID: Int] = [:]
    private var observers: [NSObjectProtocol] = []

    init(
        coordinator: TranscriptCleanupCoordinator = .shared,
        store: any TranscriptCleanupQueueStore = AppTranscriptCleanupQueueStore(),
        queueFileURL: URL = TranscriptCleanupQueue.defaultQueueFileURL,
        checkpointDirectory: URL = TranscriptCleanupCheckpointStore.directory,
        canRunNow: @escaping @MainActor () -> Bool = TranscriptCleanupQueue.canRunByDefault,
        isCleanupEnabled: @escaping @MainActor () -> Bool = { TranscriptCleanupSettings.isEnabled() },
        notifyUser: @escaping @MainActor (String) -> Void = TranscriptCleanupQueue.postUserNotification,
        transientRetryDelay: TimeInterval = 30,
        observesLifecycle: Bool = true
    ) {
        self.transientRetryDelay = transientRetryDelay
        self.coordinator = coordinator
        self.store = store
        self.queueFileURL = queueFileURL
        self.checkpointDirectory = checkpointDirectory
        self.canRunNow = canRunNow
        self.isCleanupEnabled = isCleanupEnabled
        self.notifyUser = notifyUser
        self.observesLifecycle = observesLifecycle
    }

    static func postUserNotification(_ message: String) {
        Task {
            await BackgroundProcessingManager.shared.sendNotification(title: "Transcript Cleanup", body: message)
        }
    }

    static var defaultQueueFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("TranscriptCleanup/queue.json", isDirectory: false)
    }

    /// GPU work is refused from a backgrounded iOS app. macOS has no such
    /// restriction, and hiding a Mac app is not a reason to stop.
    static func isAppInForeground() -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    /// Foreground only, and never alongside a transcription job: S1-mini and
    /// that job's ASR and speaker-label models would otherwise be resident
    /// together. `BackgroundProcessingManager` pauses the queue when such a
    /// job starts and kicks it when the job ends.
    static func canRunByDefault() -> Bool {
        isAppInForeground() && BackgroundProcessingManager.shared.currentJob?.type.isTranscription != true
    }

    /// Loads pending intents and begins running them. Call once app data is
    /// available; safe to call again.
    func start() {
        guard !started else {
            kick()
            return
        }
        started = true
        loadIntentsIfNeeded()
        TranscriptCleanupCheckpointStore.prune(
            maximumAge: Self.checkpointMaximumAge,
            in: checkpointDirectory,
            keeping: Set(intents.map(\.recordingId))
        )
        if observesLifecycle {
            observeLifecycle()
        }
        if !intents.isEmpty {
            AppLog.shared.transcription("[TranscriptCleanup] Resuming \(intents.count) queued cleanup(s)")
        }
        kick()
    }

    func enqueue(recordingId: UUID, source: TranscriptCleanupSourceSnapshot, languageCode: String?) {
        // An intent queued before `start` — a job that finished early in launch
        // — must merge with the saved queue, not overwrite it.
        loadIntentsIfNeeded()
        if activeRecordingId == recordingId {
            runTask?.cancel()
        }
        intents.removeAll { $0.recordingId == recordingId }
        intents.append(
            TranscriptCleanupIntent(
                recordingId: recordingId,
                source: source,
                languageCode: languageCode,
                enqueuedAt: Date()
            )
        )
        persistIntents()
        AppLog.shared.transcription("[TranscriptCleanup] Queued cleanup for recording \(recordingId.uuidString)")
        // Enqueueing means app data is readable, so the queue can run even if
        // the launch path that normally starts it has not got there yet.
        if !started, store.isAvailable {
            start()
        } else {
            kick()
        }
    }

    /// Queues cleanup of a transcript that has just been saved, reading it back
    /// so the intent records exactly what was committed. Runs after the commit:
    /// a failure is logged and the transcript simply stays uncleaned.
    func enqueueSavedTranscript(recordingId: UUID, languageCode: String?) {
        afterCommit("Queueing transcript cleanup", category: .transcription) {
            guard let saved = try store.transcript(for: recordingId) else {
                throw BackgroundProcessingError.processingFailed("The saved transcript could not be reread")
            }
            enqueue(
                recordingId: recordingId,
                source: TranscriptCleanupSourceSnapshot(transcript: saved),
                languageCode: languageCode
            )
        }
    }

    /// Call after a new raw transcript commits. The previous transcript's
    /// cleanup state is discarded, and the new one is queued when its preflight
    /// allows. Every path that saves a fresh transcript goes through here.
    func transcriptSaved(recordingId: UUID, preflight: TranscriptCleanupPreflight, languageCode: String?) {
        transcriptReplaced(recordingId: recordingId)
        if preflight == .ready {
            enqueueSavedTranscript(recordingId: recordingId, languageCode: languageCode)
        }
    }

    /// Withdraws a queued or running cleanup — for example when the user starts
    /// one by hand. The checkpoint is kept, so the manual run starts from it.
    /// Returns the withdrawn intent so a manual run that does not finish can
    /// hand it back with `restore`.
    @discardableResult
    func cancel(recordingId: UUID) -> TranscriptCleanupIntent? {
        loadIntentsIfNeeded()
        let withdrawn = intents.first { $0.recordingId == recordingId }
        intents.removeAll { $0.recordingId == recordingId }
        if withdrawn != nil { persistIntents() }
        if activeRecordingId == recordingId {
            runTask?.cancel()
        }
        return withdrawn
    }

    /// Re-queues an intent withdrawn by `cancel`. Its source snapshot is kept,
    /// so it is dropped as stale if the transcript changed in the meantime.
    func restore(_ intent: TranscriptCleanupIntent) {
        guard !hasPendingCleanup(for: intent.recordingId) else { return }
        enqueue(recordingId: intent.recordingId, source: intent.source, languageCode: intent.languageCode)
    }

    func hasPendingCleanup(for recordingId: UUID) -> Bool {
        intents.contains { $0.recordingId == recordingId }
    }

    /// What the transcript editor shows for one recording's queued cleanup.
    struct RecordingStatus: Equatable {
        let isActive: Bool
        let progress: TranscriptCleanupProgress?
    }

    /// Nil when nothing is queued or running for the recording.
    func status(for recordingId: UUID) -> RecordingStatus? {
        let isActive = activeRecordingId == recordingId
        guard isActive || hasPendingCleanup(for: recordingId) else { return nil }
        return RecordingStatus(isActive: isActive, progress: progress[recordingId])
    }

    /// The recording was deleted: withdraw its cleanup and delete its
    /// checkpoint, which holds that recording's cleaned text.
    func discard(recordingId: UUID) {
        cancel(recordingId: recordingId)
        TranscriptCleanupCheckpointStore.discard(for: recordingId, in: checkpointDirectory)
    }

    /// A new raw transcript replaced the recording's previous one. Any queued
    /// or running cleanup, and the checkpoint, described the old text: withdraw
    /// and delete them, whether or not the new transcript is queued for
    /// cleanup next. Call after the replacement commits, before queuing.
    func transcriptReplaced(recordingId: UUID) {
        discard(recordingId: recordingId)
    }

    func beginViewing(recordingId: UUID) {
        viewedRecordingIds[recordingId, default: 0] += 1
    }

    func endViewing(recordingId: UUID) {
        guard let count = viewedRecordingIds[recordingId] else { return }
        viewedRecordingIds[recordingId] = count > 1 ? count - 1 : nil
    }

    /// Stops the running cleanup without dropping it; it resumes from its
    /// checkpoint on the next `kick`.
    func pause() {
        guard runTask != nil else { return }
        AppLog.shared.transcription("[TranscriptCleanup] Pausing queued cleanup")
        runTask?.cancel()
    }

    /// Call when the cleanup setting may have changed. Turning cleanup off
    /// withdraws every queued cleanup and cancels the one that is running —
    /// checking only before the next run let an active run keep generating and
    /// save cleaned text after the user had turned the feature off. Finished
    /// passages stay in their checkpoints in case it is turned back on.
    func cleanupSettingDidChange() {
        guard !isCleanupEnabled(), !intents.isEmpty || runTask != nil else { return }
        AppLog.shared.transcription(
            "[TranscriptCleanup] Cleanup was turned off; withdrawing \(intents.count) queued cleanup(s)"
        )
        // Withdraw first, so the cancelled run ends as withdrawn — not paused,
        // which would leave its intent to run again.
        if !intents.isEmpty {
            intents.removeAll()
            persistIntents()
        }
        runTask?.cancel()
    }

    /// Starts the next intent if nothing is running and the app may use the GPU.
    func kick() {
        guard started, runTask == nil else { return }
        if !isCleanupEnabled() {
            // Turning cleanup off stops work already queued, not just new work.
            cleanupSettingDidChange()
            return
        }
        if let retryNotBefore, Date() < retryNotBefore {
            return
        }
        guard store.isAvailable, canRunNow(), let next = intents.first else {
            return
        }
        runTask = Task { [weak self] in
            await self?.run(next)
        }
    }

    /// For tests: waits for the running cleanup, if any, to end.
    func waitForCurrentRun() async {
        await runTask?.value
    }

    private func run(_ intent: TranscriptCleanupIntent) async {
        let recordingId = intent.recordingId
        activeRecordingId = recordingId
        let checkpoint = TranscriptCleanupCheckpointStore.checkpoint(for: recordingId, in: checkpointDirectory)
        defer {
            activeRecordingId = nil
            progress[recordingId] = nil
            runTask = nil
            // A paused run leaves the app in the background, where `kick`
            // declines; anything else moves straight on to the next intent.
            kick()
        }

        let transcript: TranscriptData
        do {
            guard let loaded = try store.transcript(for: recordingId) else {
                AppLog.shared.transcription(
                    "[TranscriptCleanup] Dropped queued cleanup: recording \(recordingId.uuidString) has no transcript"
                )
                await finish(intent, checkpoint: checkpoint, removeCheckpoint: true)
                return
            }
            transcript = loaded
        } catch {
            // Probably transient: the transcript may be readable moments later
            // or after relaunch. Keep the intent and try again later.
            await deferAfterTransientFailure(intent, checkpoint: checkpoint, reason: "read the transcript", error: error)
            return
        }

        guard intent.source.matches(transcript) else {
            // Edited or replaced since it was queued; its cleanup would
            // describe text that no longer exists.
            AppLog.shared.transcription(
                "[TranscriptCleanup] Dropped queued cleanup: the transcript changed since it was queued"
            )
            await finish(intent, checkpoint: checkpoint, removeCheckpoint: true)
            return
        }

        let finishedBefore = await checkpoint.recordedPieceCount()
        let result = await coordinator.clean(
            segments: transcript.segments,
            configuration: TranscriptCleanupConfiguration(
                enabled: true,
                mode: .automatic,
                languageCode: intent.languageCode
            ),
            checkpoint: checkpoint,
            progress: { [weak self] update in
                Task { @MainActor [weak self] in
                    guard self?.activeRecordingId == recordingId else { return }
                    self?.progress[recordingId] = update
                }
            }
        )

        // A pause or withdrawal can land after the coordinator's last
        // cancellation check, leaving a complete result with no `.cancelled`
        // warning. It must still not be saved: Cancel, a superseding manual
        // cleanup and backgrounding all mean "do not publish this". Paused, or
        // withdrawn by `cancel` — which already removed the intent — either way
        // the checkpoint keeps every finished passage for whoever resumes.
        if Task.isCancelled {
            return
        }

        if result.warning == .cancelled {
            // Cancelled by something other than this queue. Keeping the
            // intent would restart it at once from `kick`, in a loop.
            await finish(intent, checkpoint: checkpoint, removeCheckpoint: false, warning: .resourceFailure)
            return
        }

        if result.warning == .timeLimitReached {
            // The run stopped so other on-device model work could take the
            // permit. If it finished new passages, go to the back of the queue
            // and continue later; if it finished none, count it as a transient
            // failure so a run that never progresses is eventually given up.
            let finishedAfter = await checkpoint.recordedPieceCount()
            if Task.isCancelled { return }
            if finishedAfter > finishedBefore {
                transientFailures[recordingId] = nil
                intents.removeAll { $0 == intent }
                intents.append(intent)
                persistIntents()
                AppLog.shared.transcription(
                    "[TranscriptCleanup] Run reached its time limit; \(finishedAfter) passage(s) kept, continuing later"
                )
            } else {
                await deferAfterTransientFailure(
                    intent,
                    checkpoint: checkpoint,
                    reason: "finish a passage within the run time limit",
                    error: TranscriptCleanupWarning.timeLimitReached
                )
            }
            return
        }

        let current: TranscriptData?
        do {
            current = try store.transcript(for: recordingId)
        } catch {
            await deferAfterTransientFailure(
                intent, checkpoint: checkpoint, reason: "reread the transcript before saving", error: error
            )
            return
        }
        guard let current, intent.source.matches(current) else {
            await finish(intent, checkpoint: checkpoint, removeCheckpoint: true, warning: .staleResult)
            return
        }

        let keepsResult = result.cleanedSegmentCount > 0
            && (result.warning == nil || result.warning?.keepsCleanedResult == true)
        guard keepsResult else {
            if result.warning == .resourceFailure {
                // Every passage failed for a reason that may pass — a timeout,
                // a GPU or memory error. Retry like a store failure instead of
                // giving the cleanup up after one attempt; repeatable failures
                // are in the checkpoint, so a retry does not redo them.
                await deferAfterTransientFailure(
                    intent,
                    checkpoint: checkpoint,
                    reason: "clean the transcript",
                    error: TranscriptCleanupWarning.resourceFailure
                )
                return
            }
            // Nothing usable. Keep the checkpoint: a later manual run — after
            // downloading the model, say — reuses whatever did finish.
            await finish(intent, checkpoint: checkpoint, removeCheckpoint: false, warning: result.warning)
            return
        }

        // Nothing has suspended since the check above, but the synchronous
        // store re-read can re-enter the queue — a notification observer that
        // withdraws or pauses this run — so check once more before saving.
        if Task.isCancelled {
            return
        }

        guard isCleanupEnabled() else {
            // Turned off while this run was generating, by a path the settings
            // observer did not see. Do not save text the user opted out of.
            AppLog.shared.transcription("[TranscriptCleanup] Cleanup was turned off during a run; result not saved")
            await finish(intent, checkpoint: checkpoint, removeCheckpoint: false)
            return
        }

        do {
            try store.saveCleanedSegments(result.segments, for: current, recordingId: recordingId)
        } catch {
            await deferAfterTransientFailure(intent, checkpoint: checkpoint, reason: "save the cleaned transcript", error: error)
            return
        }

        // The cleaned transcript is durable; everything below is a loose end.
        await finish(intent, checkpoint: checkpoint, removeCheckpoint: true, warning: result.warning, cleaned: true)
    }

    /// A store read or save failed in a way that may pass. The intent stays
    /// queued — dropping it lost the cleanup for good — and the queue waits
    /// `transientRetryDelay` before trying again, so it does not spin. Every
    /// finished passage is in the checkpoint, so the retry is cheap. After
    /// `maximumTransientFailures` in a row the intent is given up and the user
    /// is told.
    private func deferAfterTransientFailure(
        _ intent: TranscriptCleanupIntent,
        checkpoint: TranscriptCleanupFileCheckpoint,
        reason: String,
        error: Error
    ) async {
        let failures = (transientFailures[intent.recordingId] ?? 0) + 1
        AppLog.shared.transcription(
            "[TranscriptCleanup] Could not \(reason) (attempt \(failures)): \(error.localizedDescription)",
            level: .error
        )
        guard failures < Self.maximumTransientFailures else {
            transientFailures[intent.recordingId] = nil
            await finish(intent, checkpoint: checkpoint, removeCheckpoint: false, warning: .resourceFailure)
            return
        }
        transientFailures[intent.recordingId] = failures
        retryNotBefore = Date().addingTimeInterval(transientRetryDelay)
        let delay = UInt64(transientRetryDelay * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.retryNotBefore = nil
            self?.kick()
        }
    }

    private func finish(
        _ intent: TranscriptCleanupIntent,
        checkpoint: TranscriptCleanupFileCheckpoint,
        removeCheckpoint: Bool,
        warning: TranscriptCleanupWarning? = nil,
        cleaned: Bool = false
    ) async {
        intents.removeAll { $0 == intent }
        transientFailures[intent.recordingId] = nil
        persistIntents()
        if removeCheckpoint {
            await checkpoint.remove()
        }
        var userInfo: [String: Any] = ["recordingId": intent.recordingId, "cleaned": cleaned]
        if let warning {
            userInfo["warning"] = warning.userVisibleMessage
            AppLog.shared.transcription(
                "[TranscriptCleanup] Queued cleanup ended: category=\(warning.logCategory)",
                level: .info
            )
            if viewedRecordingIds[intent.recordingId] == nil {
                notifyUser(warning.userVisibleMessage)
            }
        }
        NotificationCenter.default.post(name: Self.didFinishNotification, object: nil, userInfo: userInfo)
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        // The toggle, Reset to Defaults and a settings restore all write the
        // same UserDefaults key; observing the store catches every one of them.
        observers.append(
            center.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cleanupSettingDidChange() }
            }
        )
        observers.append(
            center.addObserver(
                forName: PlatformLifecycle.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.kick() }
            }
        )
        #if os(iOS)
        observers.append(
            center.addObserver(
                forName: PlatformLifecycle.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            }
        )
        #endif
    }

    private func loadIntentsIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        let saved = loadIntents()
        let pendingIds = Set(intents.map(\.recordingId))
        intents = saved.filter { !pendingIds.contains($0.recordingId) } + intents
    }

    private func loadIntents() -> [TranscriptCleanupIntent] {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return [] }
        do {
            return try JSONDecoder().decode([TranscriptCleanupIntent].self, from: Data(contentsOf: queueFileURL))
        } catch {
            AppLog.shared.transcription(
                "[TranscriptCleanup] Could not read the cleanup queue; starting empty: \(error.localizedDescription)",
                level: .error
            )
            return []
        }
    }

    private func persistIntents() {
        do {
            try FileManager.default.createDirectory(
                at: queueFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(intents).write(to: queueFileURL, options: .atomic)
            AppFileProtection.apply(to: queueFileURL)
        } catch {
            AppLog.shared.transcription(
                "[TranscriptCleanup] Could not save the cleanup queue: \(error.localizedDescription)",
                level: .error
            )
        }
    }
}
