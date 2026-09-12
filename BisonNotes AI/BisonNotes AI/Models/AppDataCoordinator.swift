import Foundation
import SwiftUI
import CoreData

// MARK: - App Data Coordinator
// Manages the unified registry system for recordings, transcripts, and summaries

@MainActor
class AppDataCoordinator: ObservableObject {

    // Core Data system
    @Published var coreDataManager: CoreDataManager
    @Published var workflowManager: RecordingWorkflowManager

    @Published var isInitialized = false
    @Published private(set) var storageStatus: PersistenceStoreStatus
    @Published private(set) var migrationBoundaryStatus: SQLiteMigrationStartupBoundaryStatus = .notPrepared
    @Published private(set) var migrationSettingsNormalization: LibrarySettingsNormalizationResult?
    @Published private(set) var lastObservedLibraryRevision: Int64?

    /// Storage-neutral access used by callers that have already moved off
    /// managed-object mutation. Core Data remains authoritative until the
    /// migration coordinator selects a SQLite generation.
    private let libraryRepository: any LibraryRepository
    private let libraryObservation: any LibraryObservation

    /// The recording shown in the single native-macOS player window. The app
    /// deliberately supports only one player window at a time, so this drives a
    /// singleton Window scene rather than a per-recording WindowGroup.
    @Published var macPlayerRecordingID: UUID?

    private var networkRestoredObserver: (any NSObjectProtocol)?
    private var hasInstalledPersistentStoreRemoteChangeObserver = false
    private var observationSubscription: LibraryObservationSubscription?
    private var observationTask: Task<Void, Never>?

    init(persistenceController: PersistenceController? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        self.storageStatus = resolvedPersistenceController.storageStatus
        let viewContext = resolvedPersistenceController.container.viewContext
        // Initialize Core Data system
        self.coreDataManager = CoreDataManager(persistenceController: resolvedPersistenceController)
        self.workflowManager = RecordingWorkflowManager(persistenceController: resolvedPersistenceController)
        self.libraryRepository = CoreDataLibraryRepository(
            context: viewContext,
            maintenanceGate: resolvedPersistenceController.maintenanceGate
        )
        self.libraryObservation = CoreDataLibraryObservation(container: resolvedPersistenceController.container)

        // SummaryManager initializes its engine registry during first access.
        // Migrate the Mac-only Ollama selection before that access so an older
        // iPhone/iPad install cannot restore an unsupported engine into memory.
        BisonNotesAIApp.migrateIOSOllamaSelection()

        // Set up the circular reference after initialization
        self.workflowManager.setAppCoordinator(self)
        if storageStatus.isOperational {
            SummaryManager.shared.configure(with: self)
            SummaryManager.shared.getiCloudManager().bindPendingMutationContext(
                to: coreDataManager.managedObjectContext
            )

            Task {
                await initializeSystem()
            }
        } else {
            AppLog.shared.coreData(
                "AppDataCoordinator is paused because library storage is unavailable.",
                level: .fault
            )
        }
    }

    deinit {
        observationTask?.cancel()
        observationSubscription?.cancel()
    }

    private func initializeSystem() async {
        guard storageStatus.isOperational else { return }

        // Core Data system initialization
        isInitialized = true

        await prepareSQLiteMigrationBoundary()

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

    /// Moves the coordinator into the same safe state used when the persistent
    /// store fails during construction. Startup-critical read failures must not
    /// leave the UI treating a partially readable library as writable.
    func markStorageUnavailable() {
        storageStatus = .unavailable
    }

    /// Prepares the future migration inputs without changing the current
    /// authoritative Core Data generation. In-memory previews/tests do not
    /// need persistent-history observation and are explicitly marked out of
    /// scope rather than producing a misleading startup failure.
    private func prepareSQLiteMigrationBoundary() async {
        guard storageStatus.isDurable else {
            migrationBoundaryStatus = .notApplicable
            return
        }

        do {
            // The cursor is anchored before any future source snapshot can be
            // taken. This pre-cutover preparation does not take that snapshot;
            // the eventual migration run will create its own anchored input.
            let subscription = try await LibraryObservationSubscription.anchored(
                to: libraryObservation
            )
            let normalization = try await SQLiteMigrationStartupBoundary.captureNormalizedSettings()
            observationSubscription = subscription
            migrationSettingsNormalization = normalization
            lastObservedLibraryRevision = subscription.cursor
            migrationBoundaryStatus = .ready
            installPersistentStoreRemoteChangeObserver()

            AppLog.shared.coreData(
                "SQLite migration startup boundary ready: normalized "
                    + "\(normalization.changedKeys.count) setting(s), omitted "
                    + "\(normalization.omittedKeys.count) platform-specific setting(s)",
                level: .debug
            )
        } catch {
            migrationBoundaryStatus = .needsReview
            AppLog.shared.coreData(
                "SQLite migration startup boundary requires review; Core Data remains "
                    + "authoritative: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func installPersistentStoreRemoteChangeObserver() {
        guard !hasInstalledPersistentStoreRemoteChangeObserver else { return }
        hasInstalledPersistentStoreRemoteChangeObserver = true
        _ = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollLibraryObservationIfNeeded()
            }
        }
    }

    /// Polls the durable source cursor after a store notification or app
    /// activation. The cursor advances only after a complete validated batch.
    func pollLibraryObservationIfNeeded() {
        guard migrationBoundaryStatus == .ready,
              observationSubscription != nil,
              observationTask == nil else {
            return
        }

        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pollLibraryObservation()
            self.observationTask = nil
        }
    }

    private func pollLibraryObservation() async {
        guard var subscription = observationSubscription else { return }

        do {
            let changes = try await subscription.poll()
            observationSubscription = subscription
            guard let lastChange = changes.last else { return }
            lastObservedLibraryRevision = lastChange.revision
        } catch {
            migrationBoundaryStatus = .needsReview
            AppLog.shared.coreData(
                "SQLite migration observation cursor requires review; Core Data remains "
                    + "authoritative: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    // MARK: - Public Interface

    /// Synchronous Core Data-only compatibility entry point for UI-test
    /// fixtures and legacy callers. Production recording creation uses
    /// `createRecordingUsingRepository` so a failed metadata commit remains
    /// visible to the caller and no second source of truth is introduced.
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

    /// Creates recording metadata through the storage-neutral repository.
    /// Audio ownership and file movement remain with the caller; this method
    /// is the async path used while production callers are being migrated.
    @discardableResult
    func createRecordingUsingRepository(
        url: URL,
        name: String,
        date: Date,
        fileSize: Int64,
        duration: TimeInterval,
        quality: AudioQuality,
        locationData: LocationData? = nil
    ) async throws -> UUID {
        guard let recordingURL = coreDataManager.urlToRelativePath(url) else {
            throw LibraryRepositoryError.invalidCommand(
                "recording URL could not be represented as a relative path"
            )
        }

        let snapshot = try await libraryRepository.createRecording(
            LibraryRecordingCreateCommand(
                recordingURL: recordingURL,
                name: name,
                recordingDate: date,
                duration: duration,
                fileSize: fileSize,
                audioQuality: quality.rawValue,
                locationAccuracy: locationData.map { $0.accuracy ?? 0.0 },
                locationAddress: locationData?.address,
                locationLatitude: locationData?.latitude,
                locationLongitude: locationData?.longitude,
                locationTimestamp: locationData?.timestamp
            )
        )
        guard let legacyID = snapshot.legacyID,
              let recordingID = UUID(uuidString: legacyID) else {
            throw LibraryRepositoryError.invalidRecord(
                entity: "recordings",
                field: "id"
            )
        }

        scheduleAutoBackupIfEnabled()
        objectWillChange.send()
        return recordingID
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

    /// Persists a transcript through the storage-neutral repository. The
    /// synchronous API above remains for legacy/test callers while production
    /// transcription paths move to this async boundary.
    func addTranscriptUsingRepository(
        for recordingId: UUID,
        segments: [TranscriptSegment],
        speakerMappings: [String: String] = [:],
        engine: TranscriptionEngine? = nil,
        processingTime: TimeInterval = 0,
        confidence: Double = 0.5
    ) async -> UUID? {
        let encoder = JSONEncoder()
        guard let segmentsData = try? encoder.encode(segments),
              let segmentsJSON = String(data: segmentsData, encoding: .utf8) else {
            AppLog.shared.backgroundProcessing(
                "Failed to encode transcript segments for repository persistence",
                level: .error
            )
            return nil
        }

        let speakerMappingsJSON: String?
        if speakerMappings.isEmpty {
            speakerMappingsJSON = nil
        } else if let mappingsData = try? encoder.encode(speakerMappings),
                  let mappingsString = String(data: mappingsData, encoding: .utf8) {
            speakerMappingsJSON = mappingsString
        } else {
            AppLog.shared.backgroundProcessing(
                "Failed to encode transcript speaker mappings for repository persistence",
                level: .error
            )
            return nil
        }

        let now = Date()
        do {
            let snapshot = try await libraryRepository.upsertTranscript(
                LibraryTranscriptUpsertCommand(
                    id: UUID(),
                    recordingReference: LibraryRecordingReference(
                        legacyID: recordingId.uuidString
                    ),
                    createdAt: now,
                    segments: segmentsJSON,
                    speakerMappings: speakerMappingsJSON,
                    engine: engine?.rawValue,
                    processingTime: processingTime,
                    confidence: confidence,
                    modifiedAt: now
                )
            )
            if shouldBackUpToiCloud(recordingId: recordingId) {
                scheduleAutoBackupIfEnabled()
            }
            guard let legacyID = snapshot.legacyID,
                  let transcriptID = UUID(uuidString: legacyID) else {
                AppLog.shared.backgroundProcessing(
                    "Repository returned a transcript without a UUID identity",
                    level: .error
                )
                return nil
            }
            return transcriptID
        } catch {
            AppLog.shared.backgroundProcessing(
                "Failed to persist transcript through repository: \(error.localizedDescription)",
                level: .error
            )
            return nil
        }
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

    /// Persists a generated summary through the storage-neutral repository.
    /// Supplemental notes and attachments remain outside this command; keeping
    /// the existing summary identity lets those files stay associated with the
    /// same logical summary during regeneration.
    func upsertSummaryUsingRepository(
        _ summary: EnhancedSummaryData,
        for recordingId: UUID,
        transcriptId: UUID? = nil,
        identityPolicy: LibrarySummaryUpsertIdentityPolicy = .preserveExisting
    ) async throws -> UUID {
        let encoder = JSONEncoder()
        guard let tasksData = try? encoder.encode(summary.tasks),
              let tasks = String(data: tasksData, encoding: .utf8),
              let remindersData = try? encoder.encode(summary.reminders),
              let reminders = String(data: remindersData, encoding: .utf8),
              let titlesData = try? encoder.encode(summary.titles),
              let titles = String(data: titlesData, encoding: .utf8) else {
            throw LibraryRepositoryError.invalidCommand(
                "summary structured payloads could not be encoded"
            )
        }

        let previousSummaryID: UUID?
        if identityPolicy == .incomingSummary {
            let existingSummaries = try await libraryRepository.fetchSummarySnapshots()
            let incomingSummaryID = summary.id.uuidString.lowercased()
            let incomingSummaryAlreadyExists = existingSummaries.contains {
                $0.legacyID?.lowercased() == incomingSummaryID
            }
            previousSummaryID = incomingSummaryAlreadyExists
                ? nil
                : existingSummaries
                    .filter {
                        $0.recordingLegacyID?.lowercased() == recordingId.uuidString.lowercased()
                    }
                    .sorted {
                        ($0.generatedAt ?? .distantPast) > ($1.generatedAt ?? .distantPast)
                    }
                    .compactMap { $0.legacyID.flatMap(UUID.init(uuidString:)) }
                    .first
        } else {
            previousSummaryID = nil
        }

        let snapshot = try await libraryRepository.upsertSummary(
            LibrarySummaryUpsertCommand(
                id: summary.id,
                recordingReference: LibraryRecordingReference(
                    legacyID: recordingId.uuidString
                ),
                identityPolicy: identityPolicy,
                transcriptID: transcriptId ?? summary.transcriptId,
                summary: summary.summary,
                tasks: tasks,
                reminders: reminders,
                titles: titles,
                contentType: summary.contentType.rawValue,
                aiMethod: SummaryMetadataCodec.encode(
                    aiEngine: summary.aiEngine,
                    aiModel: summary.aiModel
                ),
                generatedAt: summary.generatedAt,
                version: Int64(summary.version),
                wordCount: Int64(summary.wordCount),
                originalLength: Int64(summary.originalLength),
                compressionRatio: summary.compressionRatio,
                confidence: summary.confidence,
                processingTime: summary.processingTime
            )
        )

        guard let legacyID = snapshot.legacyID,
              let persistedID = UUID(uuidString: legacyID) else {
            throw LibraryRepositoryError.invalidRecord(
                entity: "summaries",
                field: "id"
            )
        }
        if let previousSummaryID, previousSummaryID != persistedID {
            do {
                try SummaryAttachmentStore.shared.migrate(
                    from: previousSummaryID,
                    to: persistedID
                )
            } catch {
                AppLog.shared.coreData(
                    "Cloud summary identity updated, but supplemental data migration failed: \(error)",
                    level: .error
                )
            }
        }
        if shouldBackUpToiCloud(recordingId: recordingId) {
            scheduleAutoBackupIfEnabled()
        }
        objectWillChange.send()
        return persistedID
    }

    /// Persists a cloud summary that has no local recording through the
    /// storage-neutral repository. The repository creates the zero-audio
    /// summary anchor and summary in one transaction; a later audio restore is
    /// a separate file/media operation.
    @discardableResult
    func upsertOrphanedSummaryUsingRepository(
        _ summary: EnhancedSummaryData
    ) async throws -> UUID {
        let encoder = JSONEncoder()
        guard let tasksData = try? encoder.encode(summary.tasks),
              let tasks = String(data: tasksData, encoding: .utf8),
              let remindersData = try? encoder.encode(summary.reminders),
              let reminders = String(data: remindersData, encoding: .utf8),
              let titlesData = try? encoder.encode(summary.titles),
              let titles = String(data: titlesData, encoding: .utf8) else {
            throw LibraryRepositoryError.invalidCommand(
                "summary structured payloads could not be encoded"
            )
        }

        let recordingID = summary.recordingId ?? UUID()
        let snapshot = try await libraryRepository.upsertOrphanedSummary(
            LibrarySummaryAnchorUpsertCommand(
                recordingID: recordingID,
                recordingName: summary.recordingName,
                recordingDate: summary.recordingDate,
                id: summary.id,
                transcriptID: summary.transcriptId,
                summary: summary.summary,
                tasks: tasks,
                reminders: reminders,
                titles: titles,
                contentType: summary.contentType.rawValue,
                aiMethod: SummaryMetadataCodec.encode(
                    aiEngine: summary.aiEngine,
                    aiModel: summary.aiModel
                ),
                generatedAt: summary.generatedAt,
                version: Int64(summary.version),
                wordCount: Int64(summary.wordCount),
                originalLength: Int64(summary.originalLength),
                compressionRatio: summary.compressionRatio,
                confidence: summary.confidence,
                processingTime: summary.processingTime
            )
        )

        guard let persistedID = snapshot.legacyID,
              let summaryID = UUID(uuidString: persistedID) else {
            throw LibraryRepositoryError.invalidRecord(
                entity: "summaries",
                field: "id"
            )
        }
        objectWillChange.send()
        return summaryID
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

    /// Startup-critical reads must preserve the distinction between an empty
    /// library and a failed persistent store.
    func fetchStartupSnapshot() throws -> (recordings: [RecordingEntry], transcripts: [TranscriptEntry]) {
        try coreDataManager.fetchStartupSnapshot()
    }


    func deleteRecording(id: UUID) {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        do {
            try coreDataManager.deleteRecording(id: id)
        } catch {
            AppLog.shared.coreData("Failed to delete recording \(id): \(error)", level: .error)
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

    /// Deletes a whole recording through the storage-neutral repository.
    ///
    /// The caller remains responsible for any audio file operation. The
    /// repository transaction owns metadata, attachment cleanup and the
    /// durable CloudKit deletion intent; an unavailable CloudKit account or a
    /// transient network failure leaves that intent queued for retry, matching
    /// the legacy coordinator behavior.
    func deleteRecordingUsingRepository(
        id: UUID,
        enqueueCloudDeletion: Bool = true,
        requestedAt: Date = Date()
    ) async throws {
        try await libraryRepository.deleteRecording(
            LibraryRecordingDeleteCommand(
                reference: LibraryRecordingReference(legacyID: id.uuidString),
                requestedAt: requestedAt,
                enqueueCloudDeletion: enqueueCloudDeletion
            )
        )

        if enqueueCloudDeletion {
            let iCloudManager = SummaryManager.shared.getiCloudManager()
            do {
                try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
            } catch {
                AppLog.shared.coreData(
                    "Deleted local recording and queued iCloud deletion marker for retry: \(error)",
                    level: .error
                )
            }
        }
        objectWillChange.send()
    }

    /// Applies an inbound whole-recording tombstone through the storage-neutral
    /// repository. The source device already owns the cloud deletion intent, so
    /// this local application must not enqueue a second marker. A missing row is
    /// an idempotent no-op because the marker may be replayed after a prior
    /// successful application.
    @discardableResult
    func applyRemoteRecordingDeletionUsingRepository(
        id: UUID,
        requestedAt: Date
    ) async throws -> Bool {
        do {
            try await libraryRepository.deleteRecording(
                LibraryRecordingDeleteCommand(
                    reference: LibraryRecordingReference(legacyID: id.uuidString),
                    requestedAt: requestedAt,
                    enqueueCloudDeletion: false
                )
            )
        } catch LibraryRepositoryError.recordingNotFound {
            return false
        }
        objectWillChange.send()
        return true
    }

    /// Removes a recording's audio and transcript while retaining its summary
    /// through the storage-neutral repository boundary.
    func deleteRecordingPreservingSummaryUsingRepository(
        id: UUID,
        transcriptIds: [UUID] = [],
        enqueueCloudDeletion: Bool = true,
        requestedAt: Date = Date()
    ) async throws {
        try await libraryRepository.deleteRecordingPreservingSummary(
            LibraryRecordingPreserveSummaryDeleteCommand(
                reference: LibraryRecordingReference(legacyID: id.uuidString),
                transcriptIds: transcriptIds,
                requestedAt: requestedAt,
                enqueueCloudDeletion: enqueueCloudDeletion
            )
        )

        if enqueueCloudDeletion {
            let iCloudManager = SummaryManager.shared.getiCloudManager()
            do {
                try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
            } catch {
                AppLog.shared.coreData(
                    "Preserved summary locally and queued transcript/audio removal for retry: \(error)",
                    level: .error
                )
            }
        }
        objectWillChange.send()
    }

    /// Deletes only a transcript. The recording, audio, and any summary remain, while
    /// the transcript's cloud tombstone is retained until iCloud accepts it.
    func deleteTranscript(id: UUID) async throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        _ = try await libraryRepository.deleteTranscript(
            LibraryTranscriptDeleteCommand(id: id)
        )

        do {
            try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
        } catch {
            AppLog.shared.coreData("Deleted local transcript and queued iCloud deletion marker for retry: \(error)", level: .error)
        }
        objectWillChange.send()
    }

    /// Applies an inbound transcript tombstone through the storage-neutral
    /// repository. The source device already owns the cloud deletion intent, so
    /// this local application must not enqueue a second marker. A missing row is
    /// an idempotent no-op because markers can be replayed after a prior success.
    @discardableResult
    func applyRemoteTranscriptDeletionUsingRepository(
        id: UUID,
        requestedAt: Date
    ) async throws -> Bool {
        let deleted = try await libraryRepository.deleteTranscript(
            LibraryTranscriptDeleteCommand(
                id: id,
                requestedAt: requestedAt,
                enqueueCloudDeletion: false
            )
        )
        if deleted {
            objectWillChange.send()
        }
        return deleted
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

        let initialSummary = coreDataManager.getSummary(for: recordingId) ?? initialRecording.summary
        let transcriptIds = Set([
            transcriptId,
            initialRecording.transcriptId,
            initialRecording.transcript?.id,
            initialSummary?.transcriptId,
            initialSummary?.transcript?.id
        ].compactMap { $0 })

        let deletionDate = Date()
        try await deleteRecordingPreservingSummaryUsingRepository(
            id: recordingId,
            transcriptIds: Array(transcriptIds),
            requestedAt: deletionDate
        )
    }

    func deleteSummary(id: UUID) async throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()

        let deleted = try await libraryRepository.deleteSummary(
            LibrarySummaryDeleteCommand(id: id)
        )
        if deleted {
            // Attachment files are outside the metadata transaction. Remove them
            // only after the repository has committed the summary deletion.
            try? SummaryAttachmentStore.shared.deleteAll(for: id)
        }

        do {
            try await iCloudManager.flushPendingiCloudDeletions(appCoordinator: self)
        } catch {
            AppLog.shared.coreData("Deleted local summary but failed to remove iCloud summary records: \(error)", level: .error)
        }
        if deleted {
            objectWillChange.send()
        }
    }

    /// Applies an inbound summary tombstone through the storage-neutral
    /// repository. The source device already owns the cloud deletion intent, so
    /// this local application must not enqueue a second marker. A missing row is
    /// an idempotent no-op because markers can be replayed after a prior success.
    @discardableResult
    func applyRemoteSummaryDeletionUsingRepository(
        id: UUID,
        requestedAt: Date
    ) async throws -> Bool {
        let deleted = try await libraryRepository.deleteSummary(
            LibrarySummaryDeleteCommand(
                id: id,
                requestedAt: requestedAt,
                enqueueCloudDeletion: false
            )
        )
        if deleted {
            // The repository commit succeeded, so local supplemental data can
            // now be removed without risking loss on a rolled-back delete.
            try? SummaryAttachmentStore.shared.deleteAll(for: id)
            objectWillChange.send()
        }
        return deleted
    }

    /// Applies an inbound imported-audio tombstone through the storage-neutral
    /// repository. The file is removed before the metadata transaction clears
    /// its URL: if the process dies between those operations, the still-present
    /// URL lets the replayed cloud marker retry the cleanup. A missing file is
    /// already a successful cleanup and still allows the URL to be cleared.
    @discardableResult
    func applyRemoteImportedAudioRemovalUsingRepository(
        id: UUID,
        requestedAt: Date
    ) async throws -> Bool {
        let recordings = try await libraryRepository.fetchRecordingSummaries()
        guard let recording = recordings.first(where: { snapshot in
            guard let legacyID = snapshot.legacyID else { return false }
            return legacyID.caseInsensitiveCompare(id.uuidString) == .orderedSame
        }) else {
            return false
        }
        guard recording.isCloudSyncDisabled != true else {
            return false
        }

        // Keep the URL in metadata until file cleanup succeeds. The inbound
        // CloudKit marker is the durable retry record if the app is killed after
        // this operation and before the repository transaction below commits.
        if let storedURL = recording.recordingURL, !storedURL.isEmpty {
            _ = try LibraryImportedAudioFileStore.remove(storedURL: storedURL)
        }

        let cleared = try await libraryRepository.removeImportedAudio(
            LibraryImportedAudioRemovalCommand(
                id: id,
                requestedAt: requestedAt,
                enqueueCloudDeletion: false
            )
        )
        if cleared {
            objectWillChange.send()
        }
        return cleared
    }

    func updateRecordingName(recordingId: UUID, newName: String) async throws {
        _ = try await libraryRepository.renameRecording(
            LibraryRecordingRenameCommand(
                reference: LibraryRecordingReference(
                    legacyID: recordingId.uuidString
                ),
                name: newName
            )
        )
        objectWillChange.send()
    }

    @discardableResult
    func updateRecordingDateUsingRepository(
        recordingId: UUID,
        recordingDate: Date,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) async throws -> LibraryRecordingSnapshot {
        let snapshot = try await libraryRepository.updateRecordingDate(
            LibraryRecordingDateUpdateCommand(
                reference: LibraryRecordingReference(legacyID: recordingId.uuidString),
                recordingDate: recordingDate,
                expectedLastModified: expectedLastModified,
                modifiedAt: modifiedAt
            )
        )
        objectWillChange.send()
        return snapshot
    }

    @discardableResult
    func updateRecordingLocationUsingRepository(
        recordingId: UUID,
        location: LibraryRecordingLocationSnapshot?,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) async throws -> LibraryRecordingSnapshot {
        let snapshot = try await libraryRepository.updateRecordingLocation(
            LibraryRecordingLocationUpdateCommand(
                reference: LibraryRecordingReference(legacyID: recordingId.uuidString),
                location: location,
                expectedLastModified: expectedLastModified,
                modifiedAt: modifiedAt
            )
        )
        objectWillChange.send()
        return snapshot
    }

    @discardableResult
    func setRecordingArchiveState(
        recordingId: UUID,
        archived: Bool,
        archivedAt: Date? = nil,
        archiveNote: String? = nil,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) async throws -> LibraryRecordingSnapshot {
        let snapshot = try await libraryRepository.setArchiveState(
            LibraryRecordingArchiveCommand(
                reference: LibraryRecordingReference(
                    legacyID: recordingId.uuidString
                ),
                archived: archived,
                archivedAt: archivedAt,
                archiveNote: archiveNote,
                expectedLastModified: expectedLastModified,
                modifiedAt: modifiedAt
            )
        )
        objectWillChange.send()
        return snapshot
    }

    @discardableResult
    func restoreRecordingAudioUsingRepository(
        recordingId: UUID,
        recordingURL: String,
        fileSize: Int64? = nil,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) async throws -> LibraryRecordingSnapshot {
        let snapshot = try await libraryRepository.restoreRecordingAudio(
            LibraryRecordingAudioRestoreCommand(
                reference: LibraryRecordingReference(
                    legacyID: recordingId.uuidString
                ),
                recordingURL: recordingURL,
                fileSize: fileSize,
                expectedLastModified: expectedLastModified,
                modifiedAt: modifiedAt
            )
        )
        objectWillChange.send()
        return snapshot
    }

    @discardableResult
    func upsertArchiveLocationUsingRepository(
        _ command: LibraryArchiveLocationUpsertCommand
    ) async throws -> LibraryArchiveLocationSnapshot {
        let snapshot = try await libraryRepository.upsertArchiveLocation(command)
        objectWillChange.send()
        return snapshot
    }

    /// Reads archive-location metadata through the storage-neutral repository.
    /// Callers receive copied values, so this remains safe when the active
    /// backend later changes from Core Data to SQLite.
    func fetchArchiveLocationSnapshotsUsingRepository() async throws -> [LibraryArchiveLocationSnapshot] {
        try await libraryRepository.fetchArchiveLocationSnapshots()
    }

    func setCloudSyncDisabled(for recordingId: UUID, disabled: Bool) async throws {
        let iCloudManager = SummaryManager.shared.getiCloudManager()
        _ = try await libraryRepository.setCloudSyncDisabled(
            LibraryRecordingCloudSyncCommand(
                reference: LibraryRecordingReference(
                    legacyID: recordingId.uuidString
                ),
                disabled: disabled
            )
        )

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
