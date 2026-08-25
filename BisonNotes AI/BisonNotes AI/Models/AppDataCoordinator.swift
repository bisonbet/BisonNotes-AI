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

    private var lastAutomaticiCloudReconcileDate: Date?
    private let automaticiCloudReconcileMinInterval: TimeInterval = 300

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
                try await iCloudManager.flushPendingiCloudMutations(appCoordinator: self)
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
            try await iCloudManager.flushPendingiCloudMutations(appCoordinator: self)
        } catch {
            AppLog.shared.coreData("Deleted local transcript and queued iCloud deletion marker for retry: \(error)", level: .error)
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
            try await iCloudManager.flushPendingiCloudMutations(appCoordinator: self)
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
                try await iCloudManager.flushPendingiCloudMutations(appCoordinator: self)
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

    func reconcileiCloudIfEnabled(reason: String, force: Bool = false) {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        guard iCloudManager.isEnabled else { return }

        if !force,
           let lastAutomaticiCloudReconcileDate,
           Date().timeIntervalSince(lastAutomaticiCloudReconcileDate) < automaticiCloudReconcileMinInterval {
            return
        }
        lastAutomaticiCloudReconcileDate = Date()

        Task {
            do {
                _ = try await iCloudManager.reconcileAllDataWithiCloud(
                    appCoordinator: self,
                    reason: reason
                )
                syncRecordingURLs()
                NotificationCenter.default.post(name: NSNotification.Name("iCloudReconcileCompleted"), object: nil)
                objectWillChange.send()
            } catch {
                AppLog.shared.coreData("Automatic iCloud reconcile failed: \(error)", level: .error)
            }
        }
    }

}
