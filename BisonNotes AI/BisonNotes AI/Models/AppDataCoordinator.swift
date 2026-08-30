import Foundation
import SwiftUI

// MARK: - App Data Coordinator
// Manages the unified registry system for recordings, transcripts, and summaries

@MainActor
class AppDataCoordinator: ObservableObject {

    // Core Data system
    @Published var coreDataManager: CoreDataManager
    @Published var workflowManager: RecordingWorkflowManager

    @Published var isInitialized = false

    /// The recording shown in the single native-macOS player window. The app
    /// deliberately supports only one player window at a time, so this drives a
    /// singleton Window scene rather than a per-recording WindowGroup.
    @Published var macPlayerRecordingID: UUID?

    private var networkRestoredObserver: (any NSObjectProtocol)?

    init(persistenceController: PersistenceController? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        // Initialize Core Data system
        self.coreDataManager = CoreDataManager(persistenceController: resolvedPersistenceController)
        self.workflowManager = RecordingWorkflowManager(persistenceController: resolvedPersistenceController)

        // SummaryManager initializes its engine registry during first access.
        // Migrate the Mac-only Ollama selection before that access so an older
        // iPhone/iPad install cannot restore an unsupported engine into memory.
        BisonNotesAIApp.migrateIOSOllamaSelection()

        // Set up the circular reference after initialization
        self.workflowManager.setAppCoordinator(self)
        SummaryManager.shared.configure(with: self)

        Task {
            await initializeSystem()
        }
    }

    private func initializeSystem() async {
        // Core Data system initialization
        isInitialized = true

        let migrationReport = SummaryManager.shared.migrateLegacySummariesIfNeeded(using: self)
        if migrationReport.decodedCount > 0 || migrationReport.failedCount > 0 || migrationReport.unresolvedCount > 0 {
            let message = "Legacy summary migration: decoded=\(migrationReport.decodedCount), migrated=\(migrationReport.migratedCount), preserved=\(migrationReport.preservedExistingCount), unresolved=\(migrationReport.unresolvedCount), failed=\(migrationReport.failedCount)"
            if migrationReport.didComplete {
                AppLog.shared.coreData(message, level: .debug)
            } else {
                AppLog.shared.coreData(message, level: .error)
            }
        }
    }

    // MARK: - Public Interface

    func addRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) -> UUID {
        let id = workflowManager.createRecording(
            url: url,
            name: name,
            date: date,
            fileSize: fileSize,
            duration: duration,
            quality: quality,
            locationData: locationData
        )
        scheduleAutoBackupIfEnabled()
        return id
    }

    func addWatchRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) -> UUID {
        let id = workflowManager.createRecording(
            url: url,
            name: name,
            date: date,
            fileSize: fileSize,
            duration: duration,
            quality: quality,
            locationData: locationData
        )
        scheduleAutoBackupIfEnabled()
        return id
    }

    func addTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) -> UUID? {
        let result = workflowManager.createTranscript(
            for: recordingId,
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: processingTime,
            confidence: confidence
        )
        if result != nil, shouldBackUpToiCloud(recordingId: recordingId) {
            scheduleAutoBackupIfEnabled()
        }
        return result
    }

    func addSummary(for recordingId: UUID, transcriptId: UUID, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0) -> UUID? {
        let result = workflowManager.createSummary(
            for: recordingId,
            transcriptId: transcriptId,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: aiEngine,
            aiModel: aiModel,
            originalLength: originalLength,
            processingTime: processingTime
        )
        if result != nil, shouldBackUpToiCloud(recordingId: recordingId) {
            scheduleAutoBackupIfEnabled()
        }
        return result
    }

    func getRecording(id: UUID) -> RecordingEntry? {
        return coreDataManager.getRecording(id: id)
    }

    func getRecording(url: URL) -> RecordingEntry? {
        return coreDataManager.getRecording(url: url)
    }

    /// Gets the current absolute URL for a recording, handling container ID changes automatically
    func getAbsoluteURL(for recording: RecordingEntry) -> URL? {
        return coreDataManager.getAbsoluteURL(for: recording)
    }

    /// Gets the stored URL for a recording without checking file existence (for archived recordings)
    func getStoredURL(for recording: RecordingEntry) -> URL? {
        return coreDataManager.getStoredURL(for: recording)
    }

    /// Gets transcript entry for a recording
    func getTranscript(for recordingId: UUID) -> TranscriptEntry? {
        return coreDataManager.getTranscript(for: recordingId)
    }

    /// Gets transcript data for a recording
    func getTranscriptData(for recordingId: UUID) -> TranscriptData? {
        return coreDataManager.getTranscriptData(for: recordingId)
    }

    /// Gets all transcripts
    func getAllTranscripts() -> [TranscriptEntry] {
        return coreDataManager.getAllTranscripts()
    }

    /// Gets summary entry for a recording
    func getSummary(for recordingId: UUID) -> SummaryEntry? {
        return coreDataManager.getSummary(for: recordingId)
    }

    /// Gets all summaries
    func getAllSummaries() -> [SummaryEntry] {
        return coreDataManager.getAllSummaries()
    }

    func getAllSummaryData() -> [EnhancedSummaryData] {
        return coreDataManager.getAllSummaryData()
    }

    @discardableResult
    func upsertSummary(
        _ summary: EnhancedSummaryData,
        for recordingId: UUID? = nil,
        transcriptId: UUID? = nil,
        identityPolicy: SummaryUpsertIdentityPolicy = .preserveExisting
    ) throws -> UUID {
        let resolvedRecordingId = recordingId ?? summary.recordingId ?? coreDataManager.getRecording(url: summary.recordingURL)?.id
        guard let resolvedRecordingId else {
            throw SummaryUpsertError.recordingIdentityUnavailable
        }
        return try coreDataManager.upsertSummary(
            summary,
            for: resolvedRecordingId,
            transcriptId: transcriptId,
            identityPolicy: identityPolicy
        )
    }

    func getCompleteRecordingData(id: UUID) -> (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        return coreDataManager.getCompleteRecordingData(id: id)
    }

    func getAllRecordingsWithData() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return coreDataManager.getAllRecordingsWithData()
    }


    func deleteRecording(id: UUID) {
        let transcriptIds = coreDataManager.getTranscript(for: id).flatMap { $0.id }.map { [$0] } ?? []
        let summaryIds = coreDataManager.getSummary(for: id).flatMap { $0.id }.map { [$0] } ?? []
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        // Persist the deletion intent first so a crash after the local save
        // still tells other devices. Withdraw it if the local delete rolls back.
        iCloudManager.enqueueRecordingDeletionForiCloud(
            recordingId: id,
            transcriptIds: transcriptIds,
            summaryIds: summaryIds
        )
        do {
            try coreDataManager.deleteRecording(id: id)
        } catch {
            // Covers the not-found case too: nothing was deleted here, so the
            // marker queued a moment ago must not go on to delete it elsewhere.
            iCloudManager.clearPendingRecordingDeletion(recordingId: id)
            AppLog.shared.coreData("Failed to delete recording \(id); withdrew the iCloud deletion marker: \(error)", level: .error)
            return
        }

        Task {
            do {
                try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
            } catch {
                AppLog.shared.coreData("Deleted local recording and queued iCloud deletion marker for retry: \(error)", level: .error)
            }
        }
    }

    /// Deletes only a transcript. The recording, audio, and any summary remain, while
    /// the transcript's cloud tombstone is retained until iCloud accepts it.
    func deleteTranscript(id: UUID) async throws {
        let transcript = coreDataManager.getTranscript(id: id)
        let recordingId = transcript?.recordingId ?? transcript?.recording?.id
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        iCloudManager.enqueueTranscriptRemovalFromiCloud(
            transcriptId: id,
            recordingId: recordingId
        )

        do {
            try coreDataManager.deleteTranscript(id: id)
            guard coreDataManager.getTranscript(id: id) == nil else {
                // Nothing was deleted — the row was not there. Withdraw the marker
                // rather than tombstoning something this device never saw.
                iCloudManager.clearPendingTranscriptRemoval(transcriptId: id)
                return
            }
        } catch {
            iCloudManager.clearPendingTranscriptRemoval(transcriptId: id)
            throw error
        }

        do {
            try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
        } catch {
            AppLog.shared.coreData("Deleted local transcript and queued iCloud deletion marker for retry: \(error)", level: .error)
        }
        objectWillChange.send()
    }

    /// Removes an imported transcript placeholder while retaining its recording
    /// metadata and summary. Unlike an ordinary missing-file cleanup, this is an
    /// explicit user deletion: its cloud audio removal and any stale transcript
    /// identity must survive until CloudKit accepts them.
    func deleteImportedTranscriptPreservingSummary(
        recordingId: UUID,
        transcriptId: UUID? = nil
    ) async throws {
        guard let initialRecording = coreDataManager.getRecording(id: recordingId) else {
            throw NSError(
                domain: "AppDataCoordinator",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Recording no longer exists."]
            )
        }

        let iCloudManager = SummaryManager.shared.getiCloudManager()
        let initialSummary = coreDataManager.getSummary(for: recordingId) ?? initialRecording.summary
        let transcriptIds = Set([
            transcriptId,
            initialRecording.transcriptId,
            initialRecording.transcript?.id,
            initialSummary?.transcriptId,
            initialSummary?.transcript?.id
        ].compactMap { $0 })

        // Persist both removal intents before touching anything locally, the same
        // way `deleteSummary` and `setCloudSyncDisabled` do. Queuing them after the
        // save left a window where a termination between the two would take the
        // transcript and audio away locally with nothing durable telling the other
        // devices — and the next sync would restore exactly what the user deleted,
        // which is the resurrection this method exists to prevent. Withdrawn below
        // if the local work does not commit.
        //
        // `deletionDate` is when the user asked, which is also what the markers must
        // carry: a marker that reaches CloudKit days later must not erase newer work.
        let deletionDate = Date()
        for transcriptId in transcriptIds {
            iCloudManager.enqueueTranscriptRemovalFromiCloud(
                transcriptId: transcriptId,
                recordingId: recordingId,
                requestedAt: deletionDate
            )
        }
        iCloudManager.enqueueImportedAudioRemovalFromiCloud(
            recordingId: recordingId,
            requestedAt: deletionDate
        )

        // `deleteTranscript` commits a save of its own, so its rows can be durably
        // gone even when the work below fails. Withdrawing a marker for one of those
        // would leave the transcript deleted locally with nothing telling the other
        // devices — the resurrection this method exists to prevent — so only intents
        // whose mutation has not committed are taken back.
        var committedTranscriptIds: Set<UUID> = []

        func withdrawUncommittedRemovals() {
            for transcriptId in transcriptIds where !committedTranscriptIds.contains(transcriptId) {
                iCloudManager.clearPendingTranscriptRemoval(transcriptId: transcriptId)
            }
            // `recordingURL` is only cleared by the `saveContext()` below, so if that
            // did not land the audio is still referenced locally and its intent goes.
            iCloudManager.clearPendingImportedAudioRemoval(recordingId: recordingId)
        }

        do {
            if let transcriptId {
                // The marker is already queued; this only removes the local row.
                // Works when the request's relationship is stale, too.
                try coreDataManager.deleteTranscript(id: transcriptId, enqueueCloudDeletion: false)
                committedTranscriptIds.insert(transcriptId)
            }

            guard let recording = coreDataManager.getRecording(id: recordingId) else {
                throw NSError(
                    domain: "AppDataCoordinator",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Recording no longer exists."]
                )
            }

            let currentTranscriptId = recording.transcriptId ?? recording.transcript?.id
            if currentTranscriptId.map({ transcriptIds.contains($0) }) ?? true {
                recording.transcript = nil
                recording.transcriptId = nil
                recording.transcriptionStatus = ProcessingStatus.notStarted.rawValue
            }

            if let summary = coreDataManager.getSummary(for: recordingId) ?? recording.summary {
                let currentSummaryTranscriptId = summary.transcriptId ?? summary.transcript?.id
                if currentSummaryTranscriptId.map({ transcriptIds.contains($0) }) ?? true {
                    summary.transcript = nil
                    summary.transcriptId = nil
                }
            }

            recording.recordingURL = nil
            recording.lastModified = deletionDate
            try coreDataManager.saveContext()
        } catch {
            withdrawUncommittedRemovals()
            throw error
        }

        do {
            try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
        } catch {
            AppLog.shared.coreData(
                "Imported transcript cleanup saved locally; queued iCloud removal for retry: \(error)",
                level: .error
            )
        }
        objectWillChange.send()
    }

    func deleteSummary(id: UUID) async throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        let summary = coreDataManager.getSummary(id: id)
        let recordingId = summary?.recordingId
            ?? summary?.recording?.id
            ?? coreDataManager.getRecording(forSummaryId: id)?.id

        // Attachment files are removed by deleteSummary once its save commits.
        // Doing it here destroyed the user's notes even when the delete below
        // threw and the marker was withdrawn.

        // Persist the deletion intent before the local delete. This closes the crash window
        // where a device could remove its local summary and never tell the other devices.
        iCloudManager.enqueueSummaryRemovalFromiCloud(
            summaryId: id,
            recordingId: recordingId
        )

        do {
            try coreDataManager.deleteSummary(id: id)
            guard coreDataManager.getSummary(id: id) == nil else {
                iCloudManager.clearPendingSummaryRemoval(summaryId: id)
                return
            }
        } catch {
            iCloudManager.clearPendingSummaryRemoval(summaryId: id)
            throw error
        }

        do {
            try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
        } catch {
            AppLog.shared.coreData("Deleted local summary but failed to remove iCloud summary records: \(error)", level: .error)
        }
    }

    func updateRecordingName(recordingId: UUID, newName: String) {
        workflowManager.updateRecordingName(recordingId: recordingId, newName: newName)
    }

    func setCloudSyncDisabled(for recordingId: UUID, disabled: Bool) async throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        if disabled {
            iCloudManager.enqueueLocalOnlyCloudRemoval(recordingId: recordingId)
        }

        do {
            try coreDataManager.updateCloudSyncDisabled(for: recordingId, disabled: disabled)
        } catch {
            if disabled {
                iCloudManager.clearPendingLocalOnlyCloudRemoval(recordingId: recordingId)
            }
            throw error
        }

        if disabled {
            do {
                try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
            } catch {
                AppLog.shared.coreData("Marked recording local-only and queued iCloud removal for retry: \(error)", level: .error)
            }
        } else {
            iCloudManager.clearPendingLocalOnlyCloudRemoval(recordingId: recordingId)
            scheduleAutoBackupIfEnabled()
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("RecordingCloudSyncPreferenceChanged"),
            object: nil,
            userInfo: ["recordingId": recordingId, "disabled": disabled]
        )
        objectWillChange.send()
    }

    func syncRecordingURLs() {
        // First, migrate any remaining absolute URLs to relative paths
        coreDataManager.migrateURLsToRelativePaths()

        // Then run the legacy sync (should be minimal after migration)
        coreDataManager.syncRecordingURLs()
    }

    /// Cleans up duplicate and orphaned summaries/transcripts, keeping only the most recent for each recording.
    /// Returns a tuple with (summariesDeleted, transcriptsDeleted)
    func cleanupDuplicates() -> (summaries: Int, transcripts: Int) {
        return coreDataManager.cleanupDuplicates()
    }

    // MARK: - Location Methods

    /// Gets the absolute URL for a location file associated with a recording
    func getLocationFileURL(for recording: RecordingEntry) -> URL? {
        return coreDataManager.getLocationFileURL(for: recording)
    }

    /// Loads location data for a recording using proper URL resolution
    /// First tries Core Data fields, then falls back to file-based storage
    func loadLocationData(for recording: RecordingEntry) -> LocationData? {
        // First try Core Data fields (preferred method)
        if let location = coreDataManager.getLocationData(for: recording) {
            return location
        }
        // Fallback to file-based location
        return coreDataManager.loadLocationData(for: recording)
    }

    // MARK: - Cleanup Methods

    /// Cleans up orphaned recordings that have no audio file and no meaningful content
    func cleanupOrphanedRecordings() -> Int {
        return coreDataManager.cleanupOrphanedRecordings()
    }

    /// Fixes recordings that should have been deleted completely but still exist as orphans
    func fixIncompletelyDeletedRecordings() -> Int {
        return coreDataManager.fixIncompletelyDeletedRecordings()
    }

    /// Cleans up recordings that reference missing files
    func cleanupRecordingsWithMissingFiles() -> Int {
        return coreDataManager.cleanupRecordingsWithMissingFiles()
    }

    // MARK: - Auto-Backup

    /// Schedules a debounced auto-backup to iCloud when sync is enabled.
    /// Called automatically after new transcripts and summaries are persisted.
    private func scheduleAutoBackupIfEnabled() {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        iCloudManager.scheduleAutoBackup(appCoordinator: self)
    }

    private func shouldBackUpToiCloud(recordingId: UUID) -> Bool {
        return coreDataManager.getRecording(id: recordingId)?.isCloudSyncDisabled != true
    }

    /// Asks the sync engine for one routine pass.
    ///
    /// The decision to run belongs to `iCloudStorageManager`: it knows whether work
    /// is pending, when the last successful check was, and whether CloudKit has
    /// asked for a backoff. Requests that arrive while a run is in flight are
    /// coalesced there rather than starting a second pass.
    func reconcileiCloudIfEnabled(reason: CloudSyncReason, force: Bool = false) {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        guard iCloudManager.isEnabled else { return }
        guard iCloudManager.shouldStartRoutineSnapshot(force: force, appCoordinator: self) else { return }

        Task {
            do {
                let result = try await iCloudManager.reconcileAllDataWithiCloud(
                    appCoordinator: self,
                    reason: reason
                )
                guard !result.wasCoalescedIntoRunningSync else { return }
                if let deferredUntil = result.wasDeferredUntil {
                    AppLog.shared.coreData(
                        "iCloud sync deferred for \(Int(deferredUntil.timeIntervalSinceNow))s at CloudKit's request",
                        level: .debug
                    )
                    return
                }
                syncRecordingURLs()
                NotificationCenter.default.post(name: NSNotification.Name("iCloudReconcileCompleted"), object: nil)
                objectWillChange.send()
            } catch {
                AppLog.shared.coreData("Automatic iCloud reconcile failed: \(error)", level: .error)
            }
        }
    }

    /// Picks queued work back up when the network returns.
    func observeNetworkRestorationForiCloud() {
        guard networkRestoredObserver == nil else { return }
        networkRestoredObserver = NotificationCenter.default.addObserver(
            forName: iCloudStorageManager.networkRestoredNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileiCloudIfEnabled(reason: .networkRestored, force: true)
            }
        }
    }
}
