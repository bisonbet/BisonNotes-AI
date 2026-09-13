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
    @Published private(set) var storageState: PersistenceStoreState

    /// The recording shown in the single native-macOS player window. The app
    /// deliberately supports only one player window at a time, so this drives a
    /// singleton Window scene rather than a per-recording WindowGroup.
    @Published var macPlayerRecordingID: UUID?

    private var networkRestoredObserver: (any NSObjectProtocol)?
    private let persistenceController: PersistenceController

    init(persistenceController: PersistenceController? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        self.persistenceController = resolvedPersistenceController
        self.storageState = resolvedPersistenceController.storeState
        // Initialize Core Data system
        let resolvedCoreDataManager = CoreDataManager(persistenceController: resolvedPersistenceController)
        self.coreDataManager = resolvedCoreDataManager
        self.workflowManager = RecordingWorkflowManager(
            persistenceController: resolvedPersistenceController,
            coreDataManager: resolvedCoreDataManager
        )

        // SummaryManager initializes its engine registry during first access.
        // Migrate the Mac-only Ollama selection before that access so an older
        // iPhone/iPad install cannot restore an unsupported engine into memory.
        BisonNotesAIApp.migrateIOSOllamaSelection()

        guard storageState.isOperational else {
            AppLog.shared.coreData(
                "Persistence-dependent app services withheld because local storage is unavailable",
                level: .fault
            )
            return
        }

        // Set up the circular reference after initialization. Summary and
        // CloudKit managers are deliberately not touched on the unavailable
        // path because their initialization can read and migrate local state.
        self.workflowManager.setAppCoordinator(self)
        SummaryManager.shared.configure(with: self)
        SummaryManager.shared.getiCloudManager().bindPendingMutationContext(
            to: coreDataManager.managedObjectContext
        )

        Task {
            await initializeSystem()
        }
    }

    private func initializeSystem() async {
        guard storageState.isOperational else { return }

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

    /// The production readiness gate used by callers that must retain local
    /// state across a relaunch. Explicit preview/test stores are not durable.
    func requireDurableStore() throws {
        try persistenceController.requireDurableStore()
    }

    func addRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) throws -> UUID {
        let id = try workflowManager.createRecording(
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

    func addWatchRecording(url: URL, name: String, date: Date, fileSize: Int64, duration: TimeInterval, quality: AudioQuality, locationData: LocationData? = nil) throws -> UUID {
        let id = try workflowManager.createRecording(
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

    func addTranscript(for recordingId: UUID, segments: [TranscriptSegment], speakerMappings: [String: String] = [:], engine: TranscriptionEngine? = nil, processingTime: TimeInterval = 0, confidence: Double = 0.5) throws -> UUID? {
        let result = try workflowManager.createTranscript(
            for: recordingId,
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: processingTime,
            confidence: confidence
        )
        if result != nil {
            do {
                if try shouldBackUpToiCloud(recordingId: recordingId) {
                    scheduleAutoBackupIfEnabled()
                }
            } catch {
                AppLog.shared.coreData(
                    "Transcript saved, but iCloud backup was withheld because recording lookup failed: \(error.localizedDescription)",
                    level: .error
                )
            }
        }
        return result
    }

    func addSummary(for recordingId: UUID, transcriptId: UUID, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], titles: [TitleItem] = [], contentType: ContentType = .general, aiEngine: String = "Unknown", aiModel: String, originalLength: Int, processingTime: TimeInterval = 0) throws -> UUID? {
        let result = try workflowManager.createSummary(
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
        if result != nil {
            do {
                if try shouldBackUpToiCloud(recordingId: recordingId) {
                    scheduleAutoBackupIfEnabled()
                }
            } catch {
                AppLog.shared.coreData(
                    "Summary saved, but iCloud backup was withheld because recording lookup failed: \(error.localizedDescription)",
                    level: .error
                )
            }
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
    func getAllTranscripts() throws -> [TranscriptEntry] {
        return try coreDataManager.getAllTranscripts()
    }

    /// Gets summary entry for a recording
    func getSummary(for recordingId: UUID) -> SummaryEntry? {
        return coreDataManager.getSummary(for: recordingId)
    }

    /// Gets all summaries
    func getAllSummaries() throws -> [SummaryEntry] {
        return try coreDataManager.getAllSummaries()
    }

    func getAllSummaryData() throws -> [EnhancedSummaryData] {
        return try coreDataManager.getAllSummaryData()
    }

    @discardableResult
    func upsertSummary(
        _ summary: EnhancedSummaryData,
        for recordingId: UUID? = nil,
        transcriptId: UUID? = nil,
        identityPolicy: SummaryUpsertIdentityPolicy = .preserveExisting
    ) throws -> UUID {
        let resolvedRecordingId: UUID?
        if let recordingId {
            resolvedRecordingId = recordingId
        } else if let summaryRecordingId = summary.recordingId {
            resolvedRecordingId = summaryRecordingId
        } else {
            resolvedRecordingId = try coreDataManager.fetchRecording(url: summary.recordingURL)?.id
        }
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

    func getAllRecordingsWithData() throws -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return try coreDataManager.getAllRecordingsWithData()
    }


    func deleteRecording(id: UUID) throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        try coreDataManager.deleteRecording(id: id)

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
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        try coreDataManager.deleteTranscript(id: id)

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
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        try coreDataManager.deleteImportedTranscriptPreservingSummary(
            recordingId: recordingId,
            transcriptId: transcriptId
        )

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

        // Attachment files are removed by deleteSummary once its save commits.
        // Doing it here destroyed the user's notes even when the delete below
        // threw and the marker was withdrawn.
        try coreDataManager.deleteSummary(id: id)

        do {
            try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
        } catch {
            AppLog.shared.coreData("Deleted local summary but failed to remove iCloud summary records: \(error)", level: .error)
        }
    }

    func updateRecordingName(recordingId: UUID, newName: String) throws {
        try coreDataManager.updateRecordingName(for: recordingId, newName: newName)
    }

    func setCloudSyncDisabled(for recordingId: UUID, disabled: Bool) async throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        try coreDataManager.updateCloudSyncDisabled(for: recordingId, disabled: disabled)

        if disabled {
            do {
                try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
            } catch {
                AppLog.shared.coreData("Marked recording local-only and queued iCloud removal for retry: \(error)", level: .error)
            }
        } else {
            scheduleAutoBackupIfEnabled()
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("RecordingCloudSyncPreferenceChanged"),
            object: nil,
            userInfo: ["recordingId": recordingId, "disabled": disabled]
        )
        objectWillChange.send()
    }

    func syncRecordingURLs() throws {
        // First, migrate any remaining absolute URLs to relative paths
        try coreDataManager.migrateURLsToRelativePaths()

        // Then run the legacy sync (should be minimal after migration)
        try coreDataManager.syncRecordingURLs()
    }

    /// Cleans up duplicate and orphaned summaries/transcripts, keeping only the most recent for each recording.
    /// Returns a tuple with (summariesDeleted, transcriptsDeleted)
    func cleanupDuplicates() throws -> (summaries: Int, transcripts: Int) {
        return try coreDataManager.cleanupDuplicates()
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
    func cleanupOrphanedRecordings() throws -> Int {
        return try coreDataManager.cleanupOrphanedRecordings()
    }

    /// Fixes recordings that should have been deleted completely but still exist as orphans
    func fixIncompletelyDeletedRecordings() throws -> Int {
        return try coreDataManager.fixIncompletelyDeletedRecordings()
    }

    /// Cleans up recordings that reference missing files
    func cleanupRecordingsWithMissingFiles() throws -> Int {
        return try coreDataManager.cleanupRecordingsWithMissingFiles()
    }

}

extension AppDataCoordinator {
    // MARK: - Auto-Backup

    /// Schedules a debounced auto-backup to iCloud when sync is enabled.
    /// Called automatically after new transcripts and summaries are persisted.
    private func scheduleAutoBackupIfEnabled() {
        guard storageState.isOperational else {
            AppLog.shared.coreData(
                "Automatic iCloud backup withheld because local storage is unavailable",
                level: .fault
            )
            return
        }
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        iCloudManager.scheduleAutoBackup(appCoordinator: self)
    }

    private func shouldBackUpToiCloud(recordingId: UUID) throws -> Bool {
        return try coreDataManager.fetchRecording(id: recordingId)?.isCloudSyncDisabled != true
    }

    /// Asks the sync engine for one routine pass.
    ///
    /// The decision to run belongs to `iCloudStorageManager`: it knows whether work
    /// is pending, when the last successful check was, and whether CloudKit has
    /// asked for a backoff. Requests that arrive while a run is in flight are
    /// coalesced there rather than starting a second pass.
    func reconcileiCloudIfEnabled(reason: CloudSyncReason, force: Bool = false) {
        guard storageState.isOperational else {
            AppLog.shared.coreData(
                "iCloud reconcile withheld because local storage is unavailable",
                level: .fault
            )
            return
        }
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        guard iCloudManager.isEnabled else { return }
        do {
            guard try iCloudManager.shouldStartRoutineSnapshot(force: force, appCoordinator: self) else {
                return
            }
        } catch {
            AppLog.shared.coreData(
                "iCloud reconcile withheld because local collection reads failed: \(error.localizedDescription)",
                level: .error
            )
            return
        }

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
                try syncRecordingURLs()
                NotificationCenter.default.post(name: NSNotification.Name("iCloudReconcileCompleted"), object: nil)
                objectWillChange.send()
            } catch {
                AppLog.shared.coreData("Automatic iCloud reconcile failed: \(error)", level: .error)
            }
        }
    }

    /// Picks queued work back up when the network returns.
    func observeNetworkRestorationForiCloud() {
        guard storageState.isOperational else {
            AppLog.shared.coreData(
                "iCloud network-restoration observer withheld because local storage is unavailable",
                level: .fault
            )
            return
        }
        guard networkRestoredObserver == nil else { return }
        networkRestoredObserver = NotificationCenter.default.addObserver(
            forName: iCloudStorageManager.networkRestoredNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` delivers on the main thread, and the main-actor check
            // is a thread check, so `assumeIsolated` happened to hold here. It is
            // still an assumption about how the notification is delivered rather
            // than something the type system enforces, and getting it wrong is a
            // trap at runtime. Hop explicitly instead: the work this schedules is
            // asynchronous either way.
            Task { @MainActor in
                self?.reconcileiCloudIfEnabled(reason: .networkRestored, force: true)
            }
        }
    }
}
