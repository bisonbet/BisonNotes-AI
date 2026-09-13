//
//  CoreDataManager.swift
//  Audio Journal
//
//  Created by Kiro on 8/1/25.
//

import Foundation
import CoreData
import CoreLocation

enum SummaryUpsertError: LocalizedError {
    case recordingNotFound(UUID)
    case recordingIdentityUnavailable
    case summaryIDBelongsToAnotherRecording(UUID)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .recordingNotFound(let recordingId):
            return "Recording not found for summary migration: \(recordingId.uuidString)"
        case .recordingIdentityUnavailable:
            return "Recording identity is unavailable for summary upsert"
        case .summaryIDBelongsToAnotherRecording(let summaryId):
            return "Summary ID belongs to another recording: \(summaryId.uuidString)"
        case .encodingFailed:
            return "Summary structured data could not be encoded"
        }
    }
}

enum SummaryUpsertIdentityPolicy: Equatable {
    /// Local generation and editing retain the existing Core Data UUID so supplemental
    /// notes and attachments remain associated with the same summary.
    case preserveExisting

    /// Restore operations treat the incoming summary UUID as authoritative.
    case incomingSummary
}

/// Why a delete could not be completed. Callers that queue a cloud deletion
/// marker before the local delete use this to withdraw it again.
enum CoreDataDeletionError: Error, Equatable {
    case recordingNotFound(UUID)
}

/// A collection fetch failed. This stays distinct from an empty collection so
/// callers cannot accidentally authorize cleanup, reconciliation, or a
/// successful empty-library state after a store read failure.
struct CoreDataCollectionReadError: Error, Equatable, LocalizedError {
    let operation: String
    let failure: PersistenceStoreFailure

    init(operation: String, failure: PersistenceStoreFailure) {
        self.operation = operation
        self.failure = failure
    }

    var errorDescription: String? {
        "The local \(operation) could not be read."
    }

    var diagnosticDescription: String {
        "\(operation):\(failure.diagnosticDescription)"
    }
}

/// A local save failed after a mutation was prepared. Keep the diagnostic
/// sanitized for the same reason as `CoreDataCollectionReadError`.
struct CoreDataSaveError: Error, Equatable, LocalizedError {
    let operation: String
    let failure: PersistenceStoreFailure

    init(operation: String, failure: PersistenceStoreFailure) {
        self.operation = operation
        self.failure = failure
    }

    var errorDescription: String? {
        "The local \(operation) could not be saved."
    }

    var diagnosticDescription: String {
        "\(operation):\(failure.diagnosticDescription)"
    }
}

enum CoreDataProcessingJobError: Error, Equatable, LocalizedError {
    case missingIdentity
    case jobNotFound(UUID)
    case temporaryObjectID
    case contextUnavailable

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "The processing job is missing its identifier."
        case .jobNotFound(let id):
            return "Processing job not found: \(id.uuidString)"
        case .temporaryObjectID:
            return "The processing job is not yet persisted."
        case .contextUnavailable:
            return "A storage-isolated processing context is unavailable."
        }
    }
}

enum CoreDataMutationError: Error, Equatable, LocalizedError {
    case contextUnavailable

    var errorDescription: String? {
        "A storage-isolated mutation context is unavailable."
    }
}

/// Identifies failures at the local persistence boundary. Processing callers
/// may retain a recoverable source for retry, but must not bypass a failed job
/// or metadata save with direct work.
func isPersistenceBoundaryFailure(_ error: Error) -> Bool {
    if error is CoreDataCollectionReadError ||
        error is CoreDataSaveError ||
        error is CoreDataProcessingJobError ||
        error is CoreDataMutationError {
        return true
    }

    if let backgroundError = error as? BackgroundProcessingError {
        switch backgroundError {
        case .persistenceUnavailable,
             .recordingIdentityUnavailable,
             .recordingDeletedDuringProcessing:
            return true
        default:
            break
        }
    }
    return false
}

/// Side effects of a delete that must be committed with the Core Data change.
///
/// Cloud mutations are inserted into the same persistent store transaction as
/// the deleted rows. Attachment folders remain post-commit filesystem effects:
/// unlike an outbox row, they cannot be rolled back by SQLite.
@MainActor
struct DeferredDeletionEffects {
    private var summaries: [(summaryId: UUID, recordingId: UUID?, requestedAt: Date, deleteAttachments: Bool)] = []
    private var transcripts: [(transcriptId: UUID, recordingId: UUID?, requestedAt: Date)] = []
    private var recordings: [(recordingId: UUID, transcriptIds: [UUID], summaryIds: [UUID], requestedAt: Date)] = []
    private var localOnlyRemovals: [(recordingId: UUID, requestedAt: Date)] = []
    private var importedAudioRemovals: [(recordingId: UUID, requestedAt: Date)] = []

    var isEmpty: Bool {
        summaries.isEmpty && transcripts.isEmpty && recordings.isEmpty &&
            localOnlyRemovals.isEmpty && importedAudioRemovals.isEmpty
    }

    mutating func stage(
        summary: SummaryEntry,
        requestedAt: Date = Date(),
        deleteAttachments: Bool = true
    ) {
        guard let summaryId = summary.id else { return }
        summaries.append((
            summaryId,
            summary.recordingId ?? summary.recording?.id,
            requestedAt,
            deleteAttachments
        ))
    }

    mutating func stageSummary(
        id summaryId: UUID,
        recordingId: UUID?,
        requestedAt: Date = Date(),
        deleteAttachments: Bool = true
    ) {
        summaries.append((summaryId, recordingId, requestedAt, deleteAttachments))
    }

    mutating func stage(transcript: TranscriptEntry, requestedAt: Date = Date()) {
        guard let transcriptId = transcript.id else { return }
        transcripts.append((transcriptId, transcript.recordingId ?? transcript.recording?.id, requestedAt))
    }

    /// Stages a transcript tombstone by identity, for an id whose local row is
    /// already gone. A missing row is not evidence that the cloud copy should
    /// survive — for an imported placeholder it is the normal case, and without
    /// this the next reconcile restores the transcript the user just deleted.
    mutating func stageTranscript(
        id transcriptId: UUID,
        recordingId: UUID?,
        requestedAt: Date = Date()
    ) {
        transcripts.append((transcriptId, recordingId, requestedAt))
    }

    mutating func stage(recording: RecordingEntry, requestedAt: Date = Date()) {
        guard let recordingId = recording.id else { return }
        recordings.append((
            recordingId,
            [recording.transcriptId ?? recording.transcript?.id].compactMap { $0 },
            [recording.summaryId ?? recording.summary?.id].compactMap { $0 },
            requestedAt
        ))
    }

    mutating func stageLocalOnlyRemoval(recordingId: UUID, requestedAt: Date = Date()) {
        localOnlyRemovals.append((recordingId, requestedAt))
    }

    mutating func stageImportedAudioRemoval(recordingId: UUID, requestedAt: Date = Date()) {
        importedAudioRemovals.append((recordingId, requestedAt))
    }

    /// Inserts every outbound intent into the transaction that deletes the rows.
    /// A thrown error leaves the caller's context free to roll back the whole
    /// deletion, including any outbox rows inserted so far.
    func stageCloudMutations(in context: NSManagedObjectContext) throws {
        for recording in recordings {
            // A whole-recording deletion supersedes an earlier explicit imported
            // audio removal for the same target. Keep the old enqueue API's
            // coalescing behavior inside this transaction too.
            try PendingCloudMutationStore.remove(
                kind: .importedAudioRemoval,
                targetId: recording.recordingId,
                from: context
            )
            try PendingCloudMutationStore.enqueue(
                PendingCloudMutation(
                    kind: .recordingDeletion,
                    targetId: recording.recordingId,
                    transcriptIds: recording.transcriptIds,
                    summaryIds: recording.summaryIds,
                    requestedAt: recording.requestedAt
                ),
                in: context
            )
        }
        for transcript in transcripts {
            try PendingCloudMutationStore.enqueue(
                PendingCloudMutation(
                    kind: .transcriptRemoval,
                    targetId: transcript.transcriptId,
                    recordingId: transcript.recordingId,
                    requestedAt: transcript.requestedAt
                ),
                in: context
            )
        }
        for summary in summaries {
            try PendingCloudMutationStore.enqueue(
                PendingCloudMutation(
                    kind: .summaryRemoval,
                    targetId: summary.summaryId,
                    recordingId: summary.recordingId,
                    requestedAt: summary.requestedAt
                ),
                in: context
            )
        }
        for removal in localOnlyRemovals {
            try PendingCloudMutationStore.enqueue(
                PendingCloudMutation(
                    kind: .localOnlyRemoval,
                    targetId: removal.recordingId,
                    requestedAt: removal.requestedAt
                ),
                in: context
            )
        }
        for removal in importedAudioRemovals {
            try PendingCloudMutationStore.enqueue(
                PendingCloudMutation(
                    kind: .importedAudioRemoval,
                    targetId: removal.recordingId,
                    requestedAt: removal.requestedAt
                ),
                in: context
            )
        }
    }

    /// Removes attachment files after a successful database commit. No cloud
    /// publication happens here; the outbox row is already durable.
    func commit() {
        for summary in summaries where summary.deleteAttachments {
            try? SummaryAttachmentStore.shared.deleteAll(for: summary.summaryId)
        }
    }

    /// Removes the attachment files without publishing any tombstone, for local
    /// cleanup that every device derives independently.
    func commitLocalOnly() {
        for summary in summaries where summary.deleteAttachments {
            try? SummaryAttachmentStore.shared.deleteAll(for: summary.summaryId)
        }
    }
}

/// Core Data manager that provides clean access to recordings, transcripts, and summaries
/// Replaces the legacy registry system with proper Core Data operations
@MainActor
class CoreDataManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext

    #if DEBUG
    /// Deterministic collection-read fault seam for focused failure tests. It
    /// is never set by production code and does not touch the user's library.
    static var injectedCollectionReadFailure: PersistenceStoreFailure?
    static var injectedCollectionReadOperation: String?
    /// Deterministic save fault seam for focused failure tests. It is never
    /// set by production code and can be scoped to one operation.
    static var injectedSaveFailure: PersistenceStoreFailure?
    static var injectedSaveOperation: String?

    var contextForTesting: NSManagedObjectContext {
        context
    }
    #endif

    /// The context that backs this manager. Restore and deletion coordination must use
    /// the coordinator's context rather than the process-wide shared persistence store.
    var managedObjectContext: NSManagedObjectContext {
        context
    }

    var persistenceState: PersistenceStoreState {
        persistenceController.storeState
    }

    init(persistenceController: PersistenceController? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        self.persistenceController = resolvedPersistenceController
        self.context = resolvedPersistenceController.container.viewContext
        if resolvedPersistenceController.storeState.isOperational {
            _ = PendingCloudMutationStore.migrateLegacyQueuesIfNeeded(in: context)
        }
    }

    // MARK: - Context Management

    /// Refreshes all objects in the Core Data context to ensure fresh data
    func refreshContext() {
        context.refreshAllObjects()
    }

    // MARK: - Recording Operations

    private func fetchCollection<Object: NSManagedObject>(
        _ request: NSFetchRequest<Object>,
        operation: String,
        in fetchContext: NSManagedObjectContext? = nil
    ) throws -> [Object] {
        let fetchContext = fetchContext ?? context
        do {
            #if DEBUG
            if let injectedFailure = Self.injectedCollectionReadFailure,
               Self.injectedCollectionReadOperation == nil ||
                    Self.injectedCollectionReadOperation == operation {
                throw CoreDataCollectionReadError(operation: operation, failure: injectedFailure)
            }
            #endif
            return try fetchContext.fetch(request)
        } catch let error as CoreDataCollectionReadError {
            AppLog.shared.coreData(
                "durable_read_failed operation=\(operation) cause=\(error.failure.diagnosticDescription)",
                level: .error
            )
            throw error
        } catch {
            let wrappedError = CoreDataCollectionReadError(
                operation: operation,
                failure: PersistenceStoreFailure(error: error)
            )
            AppLog.shared.coreData(
                "durable_read_failed operation=\(operation) cause=\(wrappedError.failure.diagnosticDescription)",
                level: .error
            )
            throw wrappedError
        }
    }

    func getAllRecordings() throws -> [RecordingEntry] {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RecordingEntry.recordingDate, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "recordings")
    }

    /// Fetches recording rows for a diagnostic snapshot without converting a
    /// read failure into an empty result. Callers must copy the values they
    /// need while this manager's owning context is isolated to the main actor.
    func fetchRecordingsForDiagnostics() throws -> [RecordingEntry] {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RecordingEntry.recordingDate, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "recordings")
    }

    // MARK: - URL Management Helpers

    /// Migrates all existing absolute URL paths to relative paths for resilience
    func migrateURLsToRelativePaths() throws {
        let allRecordings = try getAllRecordings()
        var updatedCount = 0

        // Only show migration progress if there's work to do
        let needsMigration = allRecordings.contains { recording in
            guard let urlString = recording.recordingURL,
                  let url = URL(string: urlString) else { return false }
            return url.scheme != nil
        }

        if needsMigration {
            AppLog.shared.coreData("Migrating absolute URLs to relative paths...")
        }

        for recording in allRecordings {
            guard let urlString = recording.recordingURL,
                  let url = URL(string: urlString),
                  url.scheme != nil else { continue } // Skip if already relative

            // Convert absolute URL to relative path
            if let relativePath = urlToRelativePath(url) {
                recording.recordingURL = relativePath
                recording.lastModified = Date()
                updatedCount += 1
            }
        }

        if updatedCount > 0 {
            do {
                try context.save()
                AppLog.shared.coreData("Migrated \(updatedCount) URLs to relative paths")
            } catch {
                AppLog.shared.coreData("Failed to save URL migrations: \(error)", level: .error)
                context.rollback()
                throw error
            }
        } else if needsMigration {
            AppLog.shared.coreData("No URLs needed migration")
        }
    }

    /// Converts an absolute URL to a relative path for storage
    func urlToRelativePath(_ url: URL) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        // Check if URL is within documents directory
        let urlString = url.absoluteString
        let documentsString = documentsURL.absoluteString

        if urlString.hasPrefix(documentsString) {
            // Remove the documents path prefix to get relative path
            let relativePath = String(urlString.dropFirst(documentsString.count))
            return relativePath.isEmpty ? nil : relativePath
        }

        // If not in documents directory, store the filename only
        return url.lastPathComponent
    }

    /// Converts a relative path back to an absolute URL
    private func relativePathToURL(_ relativePath: String) -> URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        return Self.storedURLCandidates(relativePath, documentsURL: documentsURL).first
    }

    /// The pure form of the rules `getAbsoluteURL` applies to a stored
    /// `recordingURL`: the path the string names, plus the Documents-relative
    /// filename fallback used when a container path changed.
    ///
    /// This is the single definition of those rules. Read-only callers — the
    /// troubleshooting report and the reviewed-audio scan — use it instead of
    /// restating them, so a change here cannot leave one of them protecting a
    /// different set of files than `getAbsoluteURL` resolves. Unlike
    /// `getAbsoluteURL` it touches neither the file system nor the managed
    /// object, so a diagnostic can call it without rewriting a row.
    nonisolated static func storedURLCandidates(_ storedURL: String, documentsURL: URL) -> [URL] {
        let primaryURL: URL?
        if storedURL.hasPrefix("/") {
            primaryURL = URL(fileURLWithPath: storedURL)
        } else if let parsed = URL(string: storedURL), parsed.isFileURL {
            // Only an explicit `file:` URL takes this branch. Testing
            // `scheme != nil` instead would capture ordinary filenames that
            // happen to contain a colon — `URL(string:)` reads
            // "meeting:notes.m4a" as scheme "meeting" — and strand a recording
            // whose audio is sitting in Documents under exactly that name.
            primaryURL = parsed
        } else {
            // Decode URL-encoded characters (like %20 for spaces)
            let decoded = storedURL.removingPercentEncoding ?? storedURL
            primaryURL = documentsURL.appendingPathComponent(decoded)
        }

        guard let primaryURL else { return [] }
        let fallbackURL = documentsURL.appendingPathComponent(primaryURL.lastPathComponent)
        return fallbackURL == primaryURL ? [primaryURL] : [primaryURL, fallbackURL]
    }

    /// Gets the current absolute URL for a recording, handling container ID changes
    func getAbsoluteURL(for recording: RecordingEntry) -> URL? {
        guard let urlString = recording.recordingURL else {
            // Don't log anything - orphaned records are cleaned up at app startup
            return nil
        }

        // Resolved through the one definition of the stored-URL rules rather than a
        // second `URL(string:) + scheme != nil` test of its own. That test reads an
        // ordinary filename containing a colon — "meeting:notes.m4a" — as scheme
        // "meeting", so this resolver used to return nil for audio that is sitting
        // in Documents and that `getStoredURL` and the reviewed-audio scan both
        // resolve correctly. Two resolvers disagreeing about one row is exactly what
        // `storedURLCandidates` exists to prevent.
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            AppLog.shared.coreData("Failed to convert relative path to absolute URL", level: .error)
            return nil
        }
        let candidates = Self.storedURLCandidates(urlString, documentsURL: documentsURL)
        guard let primaryURL = candidates.first else {
            AppLog.shared.coreData("Failed to convert relative path to absolute URL", level: .error)
            return nil
        }

        if FileManager.default.fileExists(atPath: primaryURL.path) {
            return primaryURL
        }

        // The remaining candidate is the Documents-relative filename fallback used
        // when the app's container path changed. URL resolution is intentionally
        // read-only here: a caller must not receive a usable URL while a hidden
        // path-repair save is still pending or has failed.
        AppLog.shared.coreData("File not found at stored path, trying filename search", level: .debug)
        for fallbackURL in candidates.dropFirst()
        where FileManager.default.fileExists(atPath: fallbackURL.path) {
            AppLog.shared.coreData("File found by filename; retaining stored path until an explicit repair save")
            return fallbackURL
        }

        AppLog.shared.coreData("File not found anywhere for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
        return nil
    }

    /// Returns a URL derived from the stored recordingURL string without checking file existence.
    /// Used for archived recordings where the local file may have been intentionally removed.
    func getStoredURL(for recording: RecordingEntry) -> URL? {
        guard let urlString = recording.recordingURL else { return nil }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        // Shares the one definition of the stored-URL rules, so a filename
        // containing a colon resolves here the same way it does everywhere else.
        return Self.storedURLCandidates(urlString, documentsURL: documentsURL).first
    }

    private func preservedContentURL(for recording: RecordingEntry, recordingId: UUID) -> URL {
        if let storedURL = getStoredURL(for: recording) {
            return storedURL
        }

        return URL(fileURLWithPath: "/preserved-recordings/\(recordingId.uuidString)")
    }

    // MARK: - Location Data Helpers

    func getLocationData(for recording: RecordingEntry) -> LocationData? {
        // Check if location data exists
        guard recording.locationLatitude != 0.0 || recording.locationLongitude != 0.0 else {
            return nil
        }

        // Create LocationData from Core Data fields
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(
                latitude: recording.locationLatitude,
                longitude: recording.locationLongitude
            ),
            altitude: 0,
            horizontalAccuracy: recording.locationAccuracy,
            verticalAccuracy: 0,
            timestamp: recording.locationTimestamp ?? Date()
        )

        var locationData = LocationData(location: location)

        // Override address if stored
        if let storedAddress = recording.locationAddress {
            // Create a new LocationData with the stored address
            locationData = LocationData(
                id: UUID(),
                latitude: recording.locationLatitude,
                longitude: recording.locationLongitude,
                timestamp: recording.locationTimestamp ?? Date(),
                accuracy: recording.locationAccuracy,
                address: storedAddress
            )
        }

        return locationData
    }

    func getRecording(id: UUID) -> RecordingEntry? {
        do {
            return try fetchRecording(id: id)
        } catch {
            return nil
        }
    }

    /// Throwing identity lookup for mutations. The optional result means only
    /// "not found"; a store read failure remains an error.
    func fetchRecording(id: UUID) throws -> RecordingEntry? {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try fetchCollection(fetchRequest, operation: "recording").first
    }

    /// Compatibility entry point for existing optional-lookup callers. New
    /// read-dependent operations use fetchRecording(url:) and propagate failure.
    func getRecording(url: URL) -> RecordingEntry? {
        do {
            return try fetchRecording(url: url)
        } catch {
            // fetchCollection already records the sanitized failure.
            return nil
        }
    }

    /// Resolves legacy encoded paths and moved containers without rewriting rows.
    func fetchRecording(url: URL) throws -> RecordingEntry? {
        let recordings = try getAllRecordings()
        let targetPath = normalizedURLPath(url)
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CoreDataCollectionReadError(
                operation: "recording URL resolution",
                failure: PersistenceStoreFailure(domain: "BisonNotes.Persistence", code: 3)
            )
        }
        for recording in recordings {
            guard let storedURL = recording.recordingURL else { continue }
            let candidates = Self.storedURLCandidates(storedURL, documentsURL: documentsURL)
            if candidates.contains(where: { normalizedURLPath($0) == targetPath }) {
                return recording
            }
        }
        // Preserve the legacy filename fallback, including percent-encoded names.
        return recordings.first { recording in
            guard let storedURL = recording.recordingURL else { return false }
            return Self.storedURLCandidates(storedURL, documentsURL: documentsURL)
                .contains { $0.lastPathComponent == url.lastPathComponent }
        }
    }

    private func normalizedURLPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func getRecording(name: String) -> RecordingEntry? {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", name)

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            AppLog.shared.coreData("Error fetching recording by name: \(error)", level: .error)
            return nil
        }
    }

    // MARK: - Transcript Operations

    func getTranscript(for recordingId: UUID) -> TranscriptEntry? {
        do {
            return try fetchTranscript(for: recordingId)
        } catch {
            return nil
        }
    }

    /// Throwing recording-scoped transcript lookup for mutation decisions.
    func fetchTranscript(for recordingId: UUID) throws -> TranscriptEntry? {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        // Older and partially restored rows may have the Core Data relationship
        // populated while the denormalized recordingId field is absent.
        fetchRequest.predicate = NSPredicate(
            format: "recordingId == %@ OR recording.id == %@",
            recordingId as CVarArg,
            recordingId as CVarArg
        )
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.lastModified, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "transcript").first
    }

    func getTranscript(id: UUID) -> TranscriptEntry? {
        do {
            return try fetchTranscript(id: id)
        } catch {
            return nil
        }
    }

    /// Throwing identity lookup for mutations. The optional result means only
    /// "not found"; a store read failure remains an error.
    func fetchTranscript(id: UUID) throws -> TranscriptEntry? {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try fetchCollection(fetchRequest, operation: "transcript").first
    }

    func getTranscriptData(for recordingId: UUID) -> TranscriptData? {
        do {
            return try fetchTranscriptData(for: recordingId)
        } catch {
            return nil
        }
    }

    /// Throwing value conversion used before a transcript mutation or cleanup
    /// decision. A failed lookup cannot masquerade as "no prior transcript".
    func fetchTranscriptData(for recordingId: UUID) throws -> TranscriptData? {
        guard let transcriptEntry = try fetchTranscript(for: recordingId),
              let recordingEntry = try fetchRecording(id: recordingId) else {
            return nil
        }

        return convertToTranscriptData(transcriptEntry: transcriptEntry, recordingEntry: recordingEntry)
    }

    func getAllTranscripts() throws -> [TranscriptEntry] {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.createdAt, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "transcripts")
    }

    /// Throwing counterpart used by read-only troubleshooting snapshots.
    func fetchTranscriptsForDiagnostics() throws -> [TranscriptEntry] {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.createdAt, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "transcripts")
    }

    /// Deletes a transcript and, once the save has landed, tells iCloud.
    ///
    /// `enqueueCloudDeletion` is false when applying a marker that came from
    /// another device — see `deleteRecording(id:enqueueCloudDeletion:)`.
    func deleteTranscript(id: UUID?, enqueueCloudDeletion: Bool = true) throws {
        do {
            var effects = DeferredDeletionEffects()
            let didDelete = try performIsolatedMutation(operation: "transcript deletion") { isolatedContext in
                guard try stageTranscriptDeletion(
                    id: id,
                    effects: &effects,
                    in: isolatedContext
                ) else {
                    return false
                }
                if enqueueCloudDeletion {
                    try effects.stageCloudMutations(in: isolatedContext)
                }
                return true
            }
            guard didDelete else { return }
            if enqueueCloudDeletion {
                effects.commit()
            } else {
                effects.commitLocalOnly()
            }
            AppLog.shared.coreData("Deleted transcript with ID: \(id?.uuidString ?? "nil")")
        } catch {
            AppLog.shared.coreData("Error deleting transcript: \(error)", level: .error)
            throw error
        }
    }

    /// Stages a transcript deletion without saving. Compound user actions use
    /// this to put every local edit and every corresponding outbox row in one
    /// persistent transaction.
    @discardableResult
    func stageTranscriptDeletion(
        id: UUID?,
        effects: inout DeferredDeletionEffects,
        requestedAt: Date = Date(),
        in mutationContext: NSManagedObjectContext? = nil
    ) throws -> Bool {
        guard let id else { return false }
        let mutationContext = mutationContext ?? context

        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let transcripts = try fetchCollection(
            fetchRequest,
            operation: "transcripts",
            in: mutationContext
        )
        guard !transcripts.isEmpty else {
            AppLog.shared.coreData("No transcript found with ID: \(id)", level: .debug)
            return false
        }

        // Only rows that point at *this* transcript. Matching on the parent
        // recording instead would clear the link on a recording that has since
        // moved to a newer transcript, which is exactly the id an iCloud
        // deletion marker for a superseded duplicate carries.
        let recordings = try fetchRecordings(
            matching: NSPredicate(format: "transcriptId == %@ OR transcript.id == %@", id as CVarArg, id as CVarArg),
            in: mutationContext
        )
        let summaryEntries = try fetchSummaries(
            matching: NSPredicate(format: "transcriptId == %@ OR transcript.id == %@", id as CVarArg, id as CVarArg),
            in: mutationContext
        )
        for recording in recordings {
            recording.transcript = nil
            recording.transcriptId = nil
            recording.transcriptionStatus = ProcessingStatus.notStarted.rawValue
            recording.lastModified = requestedAt
        }

        for summary in summaryEntries {
            summary.transcript = nil
            summary.transcriptId = nil
        }

        for transcript in transcripts {
            effects.stage(transcript: transcript, requestedAt: requestedAt)
            mutationContext.delete(transcript)
        }
        return true
    }

    /// Removes an imported transcript placeholder while retaining its recording
    /// anchor and summary. The complete local mutation, including cloud intent,
    /// runs in an isolated context so a failed save cannot roll back unrelated
    /// edits staged in the view context.
    func deleteImportedTranscriptPreservingSummary(
        recordingId: UUID,
        transcriptId: UUID? = nil
    ) throws {
        guard let initialRecording = try fetchRecording(id: recordingId) else {
            throw CoreDataDeletionError.recordingNotFound(recordingId)
        }

        _ = try performIsolatedMutation(operation: "imported transcript deletion") { isolatedContext in
            guard let recording = try isolatedContext.existingObject(with: initialRecording.objectID) as? RecordingEntry else {
                throw CoreDataDeletionError.recordingNotFound(recordingId)
            }

            let summary = try fetchSummary(for: recordingId, in: isolatedContext) ?? recording.summary
            let transcriptIds = Set([
                transcriptId,
                recording.transcriptId,
                recording.transcript?.id,
                summary?.transcriptId,
                summary?.transcript?.id
            ].compactMap { $0 })
            let deletionDate = Date()
            var effects = DeferredDeletionEffects()

            for transcriptId in transcriptIds {
                let removedLocalRow = try stageTranscriptDeletion(
                    id: transcriptId,
                    effects: &effects,
                    requestedAt: deletionDate,
                    in: isolatedContext
                )
                if !removedLocalRow {
                    effects.stageTranscript(
                        id: transcriptId,
                        recordingId: recordingId,
                        requestedAt: deletionDate
                    )
                }
            }

            let currentTranscriptId = recording.transcriptId ?? recording.transcript?.id
            if currentTranscriptId.map({ transcriptIds.contains($0) }) ?? true {
                recording.transcript = nil
                recording.transcriptId = nil
                recording.transcriptionStatus = ProcessingStatus.notStarted.rawValue
            }

            if let summary {
                let currentSummaryTranscriptId = summary.transcriptId ?? summary.transcript?.id
                if currentSummaryTranscriptId.map({ transcriptIds.contains($0) }) ?? true {
                    summary.transcript = nil
                    summary.transcriptId = nil
                }
            }

            recording.recordingURL = nil
            recording.lastModified = deletionDate
            effects.stageImportedAudioRemoval(recordingId: recordingId, requestedAt: deletionDate)
            try effects.stageCloudMutations(in: isolatedContext)
        }
    }

    /// Applies another device's imported-audio tombstone: unlinks the recording from
    /// its audio and removes the local placeholder, keeping the recording row and its
    /// summary. Returns false when there was nothing left to unlink.
    ///
    /// Deliberately scoped to the audio. The transcript half of an imported deletion
    /// travels as its own tombstone, and clearing `transcriptId` here would strand a
    /// real transcript row on any device whose markers arrive in the other order.
    ///
    /// Saves a durable preparation before removing the file, then saves the unlink.
    /// A failed filesystem operation or final save leaves the URL in Core Data, so
    /// the marker remains eligible for retry. The two isolated saves also keep a
    /// failed inbound marker from rolling back unrelated pending UI edits.
    /// Saves local-only: this is someone else's marker being applied, and raising a
    /// tombstone of our own would re-create one a revive had withdrawn.
    @discardableResult
    func applyImportedAudioRemoval(recordingId: UUID, requestedAt: Date) throws -> Bool {
        guard let recording = try fetchRecording(id: recordingId),
              let storedURL = recording.recordingURL else {
            return false
        }

        // Establish the marker's timestamp durably before touching the owned
        // source. If this save fails, no file operation is attempted.
        _ = try performIsolatedMutation(operation: "imported audio removal preparation") { isolatedContext in
            guard let isolatedRecording = try isolatedContext.existingObject(with: recording.objectID) as? RecordingEntry else {
                throw CoreDataDeletionError.recordingNotFound(recordingId)
            }
            if let existing = isolatedRecording.lastModified, existing > requestedAt {
                isolatedRecording.lastModified = existing
            } else {
                isolatedRecording.lastModified = requestedAt
            }
        }

        guard let documentsURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw NSError(
                domain: "CoreDataManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Documents directory is unavailable"]
            )
        }

        let fileManager = FileManager.default
        let candidates = Self.storedURLCandidates(storedURL, documentsURL: documentsURL)
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                // A concurrent cleanup can win between the existence check and
                // removeItem. Only a file that is still present is a failed delete.
                if fileManager.fileExists(atPath: url.path) {
                    AppLog.shared.coreData(
                        "Could not remove imported audio for recording \(recordingId.uuidString): \(error)",
                        level: .error
                    )
                    throw error
                }
            }
        }
        guard !candidates.contains(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw NSError(
                domain: "CoreDataManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Imported audio still exists after removal"]
            )
        }

        // Sidecars are useful cleanup, but the main audio file is the retry gate.
        // A stale sidecar must not keep the recording URL alive forever.
        for url in candidates {
            for ext in AdvancedTroubleshootingService.permittedSidecarExtensions {
                let sidecarURL = url.deletingPathExtension().appendingPathExtension(ext)
                guard fileManager.fileExists(atPath: sidecarURL.path) else { continue }
                do {
                    try fileManager.removeItem(at: sidecarURL)
                } catch {
                    AppLog.shared.coreData(
                        "Could not remove imported audio sidecar for recording \(recordingId.uuidString): \(error)",
                        level: .error
                    )
                }
            }
        }

        // The source is now gone. Save only the operation-owned unlink in a
        // sibling context; if this save fails the durable URL still identifies
        // the already-retained operation for retry/reconciliation.
        _ = try performIsolatedMutation(operation: "imported audio removal") { isolatedContext in
            guard let isolatedRecording = try isolatedContext.existingObject(with: recording.objectID) as? RecordingEntry else {
                throw CoreDataDeletionError.recordingNotFound(recordingId)
            }
            isolatedRecording.recordingURL = nil
            if let existing = isolatedRecording.lastModified, existing > requestedAt {
                isolatedRecording.lastModified = existing
            } else {
                isolatedRecording.lastModified = requestedAt
            }
        }

        AppLog.shared.coreData(
            "Applied imported audio removal for recording \(recordingId.uuidString)",
            level: .debug
        )
        return true
    }

    // MARK: - Repair Operations

    /// Repairs orphaned summaries by creating missing recording entries
    func repairOrphanedSummaries() throws -> Int {
        let allSummaries = try getAllSummaries()
        var repairedCount = 0

        AppLog.shared.coreData("Starting repair of \(allSummaries.count) summaries...", level: .debug)

        for (index, summary) in allSummaries.enumerated() {
            if summary.recording == nil {
                AppLog.shared.coreData("Repairing orphaned summary \(index): ID \(summary.id?.uuidString ?? "nil")", level: .debug)

                // Create a recording entry for this summary
                let recordingEntry = RecordingEntry(context: context)
                let newRecordingId = summary.recordingId ?? UUID()

                recordingEntry.id = newRecordingId
                recordingEntry.recordingName = "Recovered Summary \(index + 1)"
                recordingEntry.recordingDate = summary.generatedAt ?? Date()
                recordingEntry.recordingURL = nil // No audio file
                recordingEntry.duration = 0
                recordingEntry.fileSize = 0
                recordingEntry.summaryId = summary.id
                recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
                recordingEntry.lastModified = Date()

                // Link them together bidirectionally
                summary.recording = recordingEntry
                recordingEntry.summary = summary

                AppLog.shared.coreData("Created recording \(newRecordingId.uuidString) for summary \(summary.id?.uuidString ?? "nil")", level: .debug)
                repairedCount += 1
            } else {
                AppLog.shared.coreData("Summary \(index) already has recording relationship", level: .debug)
            }
        }

        if repairedCount > 0 {
            do {
                try context.save()
                AppLog.shared.coreData("Successfully repaired \(repairedCount) orphaned summaries in Core Data")
            } catch {
                AppLog.shared.coreData("Failed to save repaired summaries: \(error)", level: .error)
                context.rollback()
                throw error
            }
        } else {
            AppLog.shared.coreData("No orphaned summaries found to repair")
        }

        return repairedCount
    }

    // MARK: - Duplicate Cleanup

    /// Cleans up duplicate summaries and transcripts, keeping only the most recent for each recording.
    /// Returns a tuple with (summariesDeleted, transcriptsDeleted)
    /// Deletes duplicate transcript/summary rows that a newer row for the same
    /// recording has superseded.
    ///
    /// Unlike `cleanupDuplicates`, this writes no iCloud deletion markers. The winner
    /// is chosen by a rule every device applies to the same data and therefore reaches
    /// the same answer, so a permanent tombstone would add nothing and would outlive
    /// the duplicate it describes. Rows a recording still points at are never removed
    /// here — only unreferenced leftovers.
    func deleteSupersededDuplicates(
        transcriptIds: [UUID],
        summaryIds: [UUID]
    ) throws -> (transcripts: Int, summaries: Int) {
        guard !transcriptIds.isEmpty || !summaryIds.isEmpty else { return (0, 0) }

        // Read every collection before deleting anything. A failed fetch must
        // leave the local rows and the reconcile transaction untouched.
        let recordings = try getAllRecordings()
        let transcripts = try getAllTranscripts()
        let summaries = try getAllSummaries()
        var recordingsByID: [UUID: [RecordingEntry]] = [:]
        for recording in recordings {
            if let id = recording.id { recordingsByID[id, default: []].append(recording) }
        }
        let ambiguousIDs = Set(recordingsByID.filter { $0.value.count > 1 }.keys)

        var transcriptsDeleted = 0
        var summariesDeleted = 0

        for transcriptId in transcriptIds {
            guard let transcript = transcripts.first(where: { $0.id == transcriptId }) else { continue }
            guard ![transcript.recordingId, transcript.recording?.id].compactMap({ $0 })
                .contains(where: ambiguousIDs.contains) else { continue }
            let recording = transcript.recording ?? transcript.recordingId.flatMap { recordingsByID[$0]?.first }
            guard isUnreferencedDuplicate(transcript, recording: recording) else { continue }
            context.delete(transcript)
            transcriptsDeleted += 1
        }

        var effects = DeferredDeletionEffects()
        for summaryId in summaryIds {
            guard let summary = summaries.first(where: { $0.id == summaryId }) else { continue }
            guard ![summary.recordingId, summary.recording?.id].compactMap({ $0 })
                .contains(where: ambiguousIDs.contains) else { continue }
            let recording = summary.recording ?? summary.recordingId.flatMap { recordingsByID[$0]?.first }
            guard isUnreferencedDuplicate(summary, recording: recording) else { continue }
            effects.stage(summary: summary)
            context.delete(summary)
            summariesDeleted += 1
        }

        guard transcriptsDeleted > 0 || summariesDeleted > 0 else { return (0, 0) }

        do {
            // Local-only: the winner is derived identically on every device, so a
            // tombstone would add nothing and outlive the duplicate it describes.
            try save(committing: effects, localOnly: true)
            AppLog.shared.coreData(
                "Removed \(transcriptsDeleted) superseded transcript row(s) and \(summariesDeleted) superseded summary row(s)"
            )
        } catch {
            AppLog.shared.coreData("Failed to remove superseded duplicates: \(error)", level: .error)
            throw error
        }

        return (transcriptsDeleted, summariesDeleted)
    }

    private func isUnreferencedDuplicate(_ transcript: TranscriptEntry, recording: RecordingEntry?) -> Bool {
        guard let transcriptId = transcript.id else { return false }
        guard let recording else {
            // An orphaned row has no recording to supersede it; leave it to cleanupDuplicates.
            return false
        }
        return recording.transcriptId != transcriptId && recording.transcript?.id != transcriptId
    }

    private func isUnreferencedDuplicate(_ summary: SummaryEntry, recording: RecordingEntry?) -> Bool {
        guard let summaryId = summary.id else { return false }
        guard let recording else {
            return false
        }
        return recording.summaryId != summaryId && recording.summary?.id != summaryId
    }

    func cleanupDuplicates() throws -> (summaries: Int, transcripts: Int) {
        var summariesDeleted = 0
        var transcriptsDeleted = 0

        var effects = DeferredDeletionEffects()

        AppLog.shared.coreData("Starting duplicate cleanup...")

        // Complete all reads before mutating any row. An unavailable collection
        // is not evidence that there are no duplicates or orphans.
        let recordings = try getAllRecordings()
        let allSummaries = try getAllSummaries()
        let allTranscripts = try getAllTranscripts()
        AppLog.shared.coreData("Checking \(recordings.count) recordings for duplicates", level: .debug)

        var summariesByRecordingID: [UUID: [SummaryEntry]] = [:]
        for summary in allSummaries {
            if let recordingId = summary.recordingId ?? summary.recording?.id {
                summariesByRecordingID[recordingId, default: []].append(summary)
            }
        }

        var transcriptsByRecordingID: [UUID: [TranscriptEntry]] = [:]
        for transcript in allTranscripts {
            if let recordingId = transcript.recordingId ?? transcript.recording?.id {
                transcriptsByRecordingID[recordingId, default: []].append(transcript)
            }
        }

        for recording in recordings {
            guard let recordingId = recording.id else { continue }

            // Check for duplicate summaries
            let summaries = (summariesByRecordingID[recordingId] ?? []).sorted { lhs, rhs in
                Self.summaryIsConvergentlyEarlier(
                    lhsTimestamp: rhs.generatedAt ?? rhs.recording?.recordingDate,
                    lhsId: rhs.id,
                    rhsTimestamp: lhs.generatedAt ?? lhs.recording?.recordingDate,
                    rhsId: lhs.id
                )
            }
            if summaries.count > 1 {
                AppLog.shared.coreData("Found \(summaries.count) summaries for recording ID: \(recordingId)", level: .debug)
                // Keep the first (most recent), delete the rest
                for (index, summary) in summaries.enumerated() {
                    if index > 0 {
                        let summaryLength = summary.summary?.count ?? 0
                        AppLog.shared.coreData("Deleting duplicate summary ID: \(summary.id?.uuidString ?? "nil") (length: \(summaryLength) chars)", level: .debug)
                        effects.stage(summary: summary)
                        context.delete(summary)
                        summariesDeleted += 1
                    } else {
                        let summaryLength = summary.summary?.count ?? 0
                        AppLog.shared.coreData("Keeping most recent summary ID: \(summary.id?.uuidString ?? "nil") (length: \(summaryLength) chars)", level: .debug)
                    }
                }
            }

            // Check for duplicate transcripts
            let transcripts = (transcriptsByRecordingID[recordingId] ?? []).sorted { lhs, rhs in
                (lhs.lastModified ?? lhs.createdAt ?? .distantPast)
                    > (rhs.lastModified ?? rhs.createdAt ?? .distantPast)
            }
            if transcripts.count > 1 {
                AppLog.shared.coreData("Found \(transcripts.count) transcripts for recording ID: \(recordingId)", level: .debug)
                // Keep the first (most recent), delete the rest
                for (index, transcript) in transcripts.enumerated() {
                    if index > 0 {
                        let segmentsLength = transcript.segments?.count ?? 0
                        AppLog.shared.coreData("Deleting duplicate transcript ID: \(transcript.id?.uuidString ?? "nil") (segments: \(segmentsLength) chars)", level: .debug)
                        effects.stage(transcript: transcript)
                        context.delete(transcript)
                        transcriptsDeleted += 1
                    } else {
                        let segmentsLength = transcript.segments?.count ?? 0
                        AppLog.shared.coreData("Keeping most recent transcript ID: \(transcript.id?.uuidString ?? "nil") (segments: \(segmentsLength) chars)", level: .debug)
                    }
                }
            }
        }

        // Also check for orphaned summaries (no matching recording)
        let recordingIds = Set(recordings.compactMap { $0.id })
        for summary in allSummaries {
            if let summaryRecordingId = summary.recordingId ?? summary.recording?.id,
               !recordingIds.contains(summaryRecordingId) {
                AppLog.shared.coreData("Deleting orphaned summary (no recording): ID \(summary.id?.uuidString ?? "nil")", level: .debug)
                effects.stage(summary: summary)
                context.delete(summary)
                summariesDeleted += 1
            }
        }

        // Also check for orphaned transcripts (no matching recording)
        for transcript in allTranscripts {
            if let transcriptRecordingId = transcript.recordingId ?? transcript.recording?.id,
               !recordingIds.contains(transcriptRecordingId) {
                AppLog.shared.coreData("Deleting orphaned transcript (no recording): ID \(transcript.id?.uuidString ?? "nil")", level: .debug)
                effects.stage(transcript: transcript)
                context.delete(transcript)
                transcriptsDeleted += 1
            }
        }

        if summariesDeleted > 0 || transcriptsDeleted > 0 {
            do {
                try save(committing: effects)
                AppLog.shared.coreData("Cleanup complete: deleted \(summariesDeleted) duplicate/orphaned summaries, \(transcriptsDeleted) duplicate/orphaned transcripts")
            } catch {
                AppLog.shared.coreData("Failed to save cleanup changes: \(error)", level: .error)
                throw error
            }
        } else {
            AppLog.shared.coreData("No duplicates or orphans found")
        }

        return (summariesDeleted, transcriptsDeleted)
    }

    // MARK: - Summary Operations

    /// Inserts or updates one summary while preserving the legacy summary ID when possible.
    /// The recording UUID is the authoritative identity; the recording URL is not accepted here
    /// as a substitute because callers must resolve it before writing.
    @discardableResult
    private func summaryForUpsert(
        in context: NSManagedObjectContext, objectID: NSManagedObjectID?, summaryID: UUID
    ) throws -> SummaryEntry {
        guard let objectID else { return SummaryEntry(context: context) }
        guard let summary = try context.existingObject(with: objectID) as? SummaryEntry else {
            throw SummaryUpsertError.summaryIDBelongsToAnotherRecording(summaryID)
        }
        return summary
    }

    private func applySummaryContent(_ summary: EnhancedSummaryData, to isolatedSummary: SummaryEntry) {
            isolatedSummary.contentType = summary.contentType.rawValue
            isolatedSummary.aiMethod = SummaryMetadataCodec.encode(
                aiEngine: summary.aiEngine,
                aiModel: summary.aiModel
            )
            isolatedSummary.generatedAt = summary.generatedAt
            isolatedSummary.version = Int32(summary.version)
            isolatedSummary.wordCount = Int32(summary.wordCount)
            isolatedSummary.originalLength = Int32(summary.originalLength)
            isolatedSummary.compressionRatio = summary.compressionRatio
            isolatedSummary.confidence = summary.confidence
            isolatedSummary.processingTime = summary.processingTime
    }

    func upsertSummary(
        _ summary: EnhancedSummaryData,
        for recordingId: UUID,
        transcriptId: UUID? = nil,
        identityPolicy: SummaryUpsertIdentityPolicy = .preserveExisting
    ) throws -> UUID {
        guard let recordingEntry = try fetchRecording(id: recordingId) else {
            throw SummaryUpsertError.recordingNotFound(recordingId)
        }
        let recordingObjectID = recordingEntry.objectID

        if let embeddedRecordingId = summary.recordingId, embeddedRecordingId != recordingId {
            throw SummaryUpsertError.summaryIDBelongsToAnotherRecording(summary.id)
        }

        let summaryByID = try fetchSummary(id: summary.id)
        if let summaryByID,
           let existingRecordingId = summaryByID.recordingId ?? summaryByID.recording?.id,
           existingRecordingId != recordingId {
            throw SummaryUpsertError.summaryIDBelongsToAnotherRecording(summary.id)
        }

        let summariesForRecording = try fetchSummaries(forRecordingId: recordingId)
        let existingSummaryObjectID = summaryByID?.objectID
        let firstSummaryObjectID = summariesForRecording.first?.objectID
        let summaryId: UUID
        let previousSummaryId: UUID?
        switch identityPolicy {
        case .preserveExisting:
            summaryId = summaryByID?.id ?? summariesForRecording.first?.id ?? summary.id
            previousSummaryId = nil
        case .incomingSummary:
            summaryId = summary.id
            previousSummaryId = summaryByID == nil ? summariesForRecording.first?.id : nil
        }

        let tasksData = try JSONEncoder().encode(summary.tasks)
        let remindersData = try JSONEncoder().encode(summary.reminders)
        let titlesData = try JSONEncoder().encode(summary.titles)
        guard let tasksString = String(data: tasksData, encoding: .utf8),
              let remindersString = String(data: remindersData, encoding: .utf8),
              let titlesString = String(data: titlesData, encoding: .utf8) else {
            throw SummaryUpsertError.encodingFailed
        }

        // Resolve the optional transcript before mutating a sibling context.
        // A failed read is not equivalent to a missing transcript for this
        // operation; only a successful lookup can authorize the link decision.
        let resolvedTranscriptId = transcriptId ?? summary.transcriptId
        if let resolvedTranscriptId {
            _ = try fetchTranscript(id: resolvedTranscriptId)
        }

        try performIsolatedMutation(operation: "summary upsert") { isolatedContext in
            guard let isolatedRecording = try isolatedContext.existingObject(with: recordingObjectID) as? RecordingEntry else {
                throw SummaryUpsertError.recordingNotFound(recordingId)
            }

            let isolatedSummary = try summaryForUpsert(
                in: isolatedContext, objectID: existingSummaryObjectID ?? firstSummaryObjectID, summaryID: summary.id
            )

            isolatedSummary.id = summaryId
            isolatedSummary.recordingId = recordingId
            isolatedSummary.summary = summary.summary
            isolatedSummary.tasks = tasksString
            isolatedSummary.reminders = remindersString
            isolatedSummary.titles = titlesString
            applySummaryContent(summary, to: isolatedSummary)
            isolatedSummary.recording = isolatedRecording
            isolatedRecording.summary = isolatedSummary
            isolatedRecording.summaryId = summaryId
            isolatedRecording.summaryStatus = ProcessingStatus.completed.rawValue
            advanceLastModified(isolatedRecording, to: summary.generatedAt)

            if let resolvedTranscriptId {
                let request: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", resolvedTranscriptId as CVarArg)
                let transcript = try fetchCollection(
                    request,
                    operation: "transcript",
                    in: isolatedContext
                ).first
                if transcript != nil || identityPolicy == .incomingSummary {
                    isolatedSummary.transcriptId = resolvedTranscriptId
                    isolatedSummary.transcript = transcript
                }
            } else if identityPolicy == .incomingSummary {
                isolatedSummary.transcriptId = nil
                isolatedSummary.transcript = nil
            }
        }

        // Keep one authoritative summary per recording after the save succeeds.
        let duplicateSummaryIDs: [UUID] = summariesForRecording.compactMap { existing -> UUID? in
            guard existing.objectID != existingSummaryObjectID,
                  existing.id != summaryId else { return nil }
            return existing.id
        }
        if !duplicateSummaryIDs.isEmpty {
            var effects = DeferredDeletionEffects()
            for duplicateSummary in summariesForRecording where duplicateSummaryIDs.contains(duplicateSummary.id ?? UUID()) {
                effects.stage(summary: duplicateSummary)
            }
            try deleteSummariesAfterSave(ids: duplicateSummaryIDs, effects: effects)
        }

        if let previousSummaryId, previousSummaryId != summaryId {
            do {
                try SummaryAttachmentStore.shared.migrate(from: previousSummaryId, to: summaryId)
            } catch {
                AppLog.shared.coreData(
                    "Summary identity updated, but supplemental data migration failed: \(error)",
                    level: .error
                )
            }
        }

        return summaryId
    }

    /// Persists a cloud summary that has no matching local recording by creating a stable
    /// summary-only recording anchor. Repeated restores return the existing summary instead
    /// of creating another anchor.
    @discardableResult
    func upsertOrphanedSummary(_ summary: EnhancedSummaryData) throws -> UUID {
        if let existingSummary = try fetchSummary(id: summary.id) {
            guard let recordingEntry = existingSummary.recording,
                  let recordingId = recordingEntry.id else {
                throw SummaryUpsertError.recordingIdentityUnavailable
            }

            let result = try upsertSummary(
                summary,
                for: recordingId,
                transcriptId: summary.transcriptId,
                identityPolicy: .incomingSummary
            )
            let recordingObjectID = recordingEntry.objectID
            try performIsolatedMutation(operation: "orphaned summary metadata") { isolatedContext in
                guard let isolatedRecording = try isolatedContext.existingObject(with: recordingObjectID) as? RecordingEntry else {
                    throw SummaryUpsertError.recordingNotFound(recordingId)
                }
                isolatedRecording.recordingName = summary.recordingName
                isolatedRecording.recordingDate = summary.recordingDate
                advanceLastModified(isolatedRecording, to: summary.generatedAt)
            }
            return result
        }

        let tasksData = try JSONEncoder().encode(summary.tasks)
        let remindersData = try JSONEncoder().encode(summary.reminders)
        let titlesData = try JSONEncoder().encode(summary.titles)
        guard let tasks = String(data: tasksData, encoding: .utf8),
              let reminders = String(data: remindersData, encoding: .utf8),
              let titles = String(data: titlesData, encoding: .utf8) else {
            throw SummaryUpsertError.encodingFailed
        }

        let recordingId = summary.recordingId ?? UUID()
        try performIsolatedMutation(operation: "orphaned summary creation") { isolatedContext in
            let recordingEntry = RecordingEntry(context: isolatedContext)
            recordingEntry.id = recordingId
            recordingEntry.recordingName = summary.recordingName
            recordingEntry.recordingDate = summary.recordingDate
            recordingEntry.recordingURL = nil
            recordingEntry.duration = 0
            recordingEntry.fileSize = 0
            recordingEntry.summaryId = summary.id
            recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
            advanceLastModified(recordingEntry, to: summary.generatedAt)

            let summaryEntry = SummaryEntry(context: isolatedContext)
            summaryEntry.id = summary.id
            summaryEntry.recordingId = recordingId
            summaryEntry.transcriptId = summary.transcriptId
            summaryEntry.generatedAt = summary.generatedAt
            summaryEntry.aiMethod = SummaryMetadataCodec.encode(aiEngine: summary.aiEngine, aiModel: summary.aiModel)
            summaryEntry.processingTime = summary.processingTime
            summaryEntry.confidence = summary.confidence
            summaryEntry.summary = summary.summary
            summaryEntry.contentType = summary.contentType.rawValue
            summaryEntry.wordCount = Int32(summary.wordCount)
            summaryEntry.originalLength = Int32(summary.originalLength)
            summaryEntry.compressionRatio = summary.compressionRatio
            summaryEntry.version = Int32(summary.version)
            summaryEntry.tasks = tasks
            summaryEntry.reminders = reminders
            summaryEntry.titles = titles
            summaryEntry.recording = recordingEntry
            recordingEntry.summary = summaryEntry
        }

        return summary.id
    }

    /// Reads the authoritative summary for a recording.
    ///
    /// This used to delete the losing duplicates here, along with their
    /// attachment files, and queue cloud tombstones for them — all as a side
    /// effect of a read. That published a durable deletion for a summary another
    /// device might still be pointing at, without any of the safeguards the
    /// convergent prune applies: no unreferenced check, and a winner chosen by a
    /// different rule, so two devices could each delete the other's copy.
    ///
    /// Duplicates are now left alone. `pruneSupersededLocalDuplicates` removes
    /// them during reconcile, where every device derives the same winner from the
    /// same data and no tombstone is written.
    func getSummary(for recordingId: UUID) -> SummaryEntry? {
        do {
            return try fetchSummary(for: recordingId)
        } catch {
            return nil
        }
    }

    /// Throwing recording-scoped summary lookup for mutation decisions. A nil
    /// result means only that no summary exists; a store read failure remains an
    /// error and cannot authorize cleanup or an empty-success path.
    func fetchSummary(
        for recordingId: UUID,
        in fetchContext: NSManagedObjectContext? = nil
    ) throws -> SummaryEntry? {
        let summaries = try fetchSummaries(forRecordingId: recordingId, in: fetchContext)
        guard summaries.count > 1 else {
            return summaries.first
        }

        AppLog.shared.coreData(
            "Found \(summaries.count) summaries for recording \(recordingId); "
                + "returning the row iCloud arbitration converges on",
            level: .debug
        )
        return summaries.max { lhs, rhs in
            Self.summaryIsConvergentlyEarlier(
                lhsTimestamp: lhs.generatedAt ?? lhs.recording?.recordingDate,
                lhsId: lhs.id,
                rhsTimestamp: rhs.generatedAt ?? rhs.recording?.recordingDate,
                rhsId: rhs.id
            )
        }
    }

    func fetchSummary(for recordingId: UUID) throws -> SummaryEntry? {
        try fetchSummary(for: recordingId, in: nil)
    }

    /// Orders two summaries exactly as `iCloudStorageManager.latestPerRecording`
    /// does, so a read shows the same row the sync will settle on. Newest content
    /// timestamp wins; equal timestamps break on the identifier.
    static func summaryIsConvergentlyEarlier(
        lhsTimestamp: Date?,
        lhsId: UUID?,
        rhsTimestamp: Date?,
        rhsId: UUID?
    ) -> Bool {
        let lhs = lhsTimestamp ?? .distantPast
        let rhs = rhsTimestamp ?? .distantPast
        if lhs != rhs {
            return lhs < rhs
        }
        return (lhsId?.uuidString ?? "") < (rhsId?.uuidString ?? "")
    }

    func getSummaryData(for recordingId: UUID) -> EnhancedSummaryData? {
        guard let summaryEntry = getSummary(for: recordingId),
              let recordingEntry = getRecording(id: recordingId) else {
            return nil
        }

        return convertToEnhancedSummaryData(summaryEntry: summaryEntry, recordingEntry: recordingEntry)
    }

    /// Throwing counterpart for workflows that use the complete snapshot to
    /// authorize a mutation. A failed recording, transcript, or summary read
    /// must remain distinct from a legitimately missing relationship.
    func fetchSummaryData(for recordingId: UUID) throws -> EnhancedSummaryData? {
        guard let summaryEntry = try fetchSummary(for: recordingId),
              let recordingEntry = try fetchRecording(id: recordingId) else {
            return nil
        }

        return convertToEnhancedSummaryData(summaryEntry: summaryEntry, recordingEntry: recordingEntry)
    }

    func getAllSummaries() throws -> [SummaryEntry] {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \SummaryEntry.generatedAt, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "summaries")
    }

    /// Throwing identity lookup for mutations. The optional result means only
    /// "not found"; a store read failure remains an error.
    func fetchSummary(id: UUID) throws -> SummaryEntry? {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try fetchCollection(fetchRequest, operation: "summary").first
    }

    /// Fetches all summaries that belong to a recording, including older rows
    /// whose inverse relationship is populated but whose denormalized ID is not.
    func fetchSummaries(
        forRecordingId recordingId: UUID,
        in fetchContext: NSManagedObjectContext? = nil
    ) throws -> [SummaryEntry] {
        try fetchSummaries(
            matching: NSPredicate(
                format: "recordingId == %@ OR recording.id == %@",
                recordingId as CVarArg,
                recordingId as CVarArg
            ),
            in: fetchContext
        )
    }

    /// Throwing counterpart used by read-only troubleshooting snapshots.
    func fetchSummariesForDiagnostics() throws -> [SummaryEntry] {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \SummaryEntry.generatedAt, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "summaries")
    }

    /// Returns the complete summary value objects represented by the Core Data store.
    /// SummaryEntry is the authoritative source; this method is the only conversion path
    /// callers should use when they need all summaries for display or cloud backup.
    func getAllSummaryData() throws -> [EnhancedSummaryData] {
        let summaries = try getAllSummaries()
        let recordings = try getAllRecordings()
        var recordingsByID: [UUID: RecordingEntry] = [:]
        for recording in recordings {
            if let recordingId = recording.id {
                recordingsByID[recordingId] = recording
            }
        }

        return summaries.compactMap { summaryEntry in
            guard let recordingId = summaryEntry.recordingId ?? summaryEntry.recording?.id,
                  let recordingEntry = recordingsByID[recordingId] else {
                AppLog.shared.coreData(
                    "Skipping summary \(summaryEntry.id?.uuidString ?? "nil") without a resolvable recording",
                    level: .error
                )
                return nil
            }
            return convertToEnhancedSummaryData(summaryEntry: summaryEntry, recordingEntry: recordingEntry)
        }
    }

    func getSummary(id: UUID) -> SummaryEntry? {
        do {
            return try fetchSummary(id: id)
        } catch {
            return nil
        }
    }

    /// Deletes a summary and, once the save has landed, removes its attachment
    /// files and tells iCloud.
    ///
    /// `enqueueCloudDeletion` is false when applying a marker that came from
    /// another device. Attachment files are still removed either way — they are
    /// local state, not a claim about what the user deleted.
    func deleteSummary(id: UUID?, enqueueCloudDeletion: Bool = true) throws {
        guard let id = id else {
            AppLog.shared.coreData("Cannot delete summary: ID is nil", level: .error)
            return
        }

        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            var effects = DeferredDeletionEffects()
            let didDelete = try performIsolatedMutation(operation: "summary deletion") { isolatedContext in
                let summaries = try fetchCollection(
                    fetchRequest,
                    operation: "summaries",
                    in: isolatedContext
                )
                guard !summaries.isEmpty else {
                    AppLog.shared.coreData("No summary found with ID: \(id)", level: .debug)
                    return false
                }

                // Only rows that point at *this* summary — see deleteTranscript.
                let recordings = try fetchRecordings(
                    matching: NSPredicate(format: "summaryId == %@ OR summary.id == %@", id as CVarArg, id as CVarArg),
                    in: isolatedContext
                )
                for recording in recordings {
                    recording.summary = nil
                    recording.summaryId = nil
                    recording.summaryStatus = ProcessingStatus.notStarted.rawValue
                    recording.lastModified = Date()
                }

                for summary in summaries {
                    AppLog.shared.coreData("Deleting summary with ID: \(id)", level: .debug)
                    effects.stage(summary: summary)
                    isolatedContext.delete(summary)
                }
                if enqueueCloudDeletion {
                    try effects.stageCloudMutations(in: isolatedContext)
                }
                return true
            }
            guard didDelete else { return }
            if enqueueCloudDeletion {
                effects.commit()
            } else {
                effects.commitLocalOnly()
            }
            AppLog.shared.coreData("Successfully deleted summary with ID: \(id)")
        } catch {
            AppLog.shared.coreData("Error deleting summary: \(error)", level: .error)
            throw error
        }
    }

    // MARK: - Combined Operations

    func getCompleteRecordingData(id: UUID) -> (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        guard let recording = getRecording(id: id) else {
            return nil
        }

        let transcript = getTranscriptData(for: id)
        let summary = getSummaryData(for: id)

        return (recording: recording, transcript: transcript, summary: summary)
    }

    /// Throwing complete snapshot used by mutation workflows. Optional values
    /// here mean only that a relationship is absent; any store read failure is
    /// propagated to the caller.
    func fetchCompleteRecordingData(id: UUID) throws -> (recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)? {
        guard let recording = try fetchRecording(id: id) else {
            return nil
        }

        let transcript = try fetchTranscriptData(for: id)
        let summary = try fetchSummaryData(for: id)
        return (recording: recording, transcript: transcript, summary: summary)
    }

    func getAllRecordingsWithData() throws -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        let recordings = try getAllRecordings()
        let transcripts = try getAllTranscripts()
        let summaries = try getAllSummaries()

        var transcriptsByRecordingID: [UUID: [TranscriptEntry]] = [:]
        for transcript in transcripts {
            if let recordingId = transcript.recordingId ?? transcript.recording?.id {
                transcriptsByRecordingID[recordingId, default: []].append(transcript)
            }
        }

        var summariesByRecordingID: [UUID: [SummaryEntry]] = [:]
        for summary in summaries {
            if let recordingId = summary.recordingId ?? summary.recording?.id {
                summariesByRecordingID[recordingId, default: []].append(summary)
            }
        }

        return recordings.map { recording in
            let transcript = recording.id.flatMap { recordingId in
                let transcriptEntry = transcriptsByRecordingID[recordingId]?.max { lhs, rhs in
                    (lhs.lastModified ?? lhs.createdAt ?? .distantPast)
                        < (rhs.lastModified ?? rhs.createdAt ?? .distantPast)
                }
                return transcriptEntry.flatMap {
                    convertToTranscriptData(transcriptEntry: $0, recordingEntry: recording)
                }
            }
            let summary = recording.id.flatMap { recordingId in
                let summaryEntry = summariesByRecordingID[recordingId]?.max { lhs, rhs in
                    Self.summaryIsConvergentlyEarlier(
                        lhsTimestamp: lhs.generatedAt ?? lhs.recording?.recordingDate,
                        lhsId: lhs.id,
                        rhsTimestamp: rhs.generatedAt ?? rhs.recording?.recordingDate,
                        rhsId: rhs.id
                    )
                }
                return summaryEntry.flatMap {
                    convertToEnhancedSummaryData(summaryEntry: $0, recordingEntry: recording)
                }
            }
            return (recording: recording, transcript: transcript, summary: summary)
        }
    }


    // MARK: - Delete Operations

    /// Deletes a recording and, once the save has landed, tells iCloud.
    ///
    /// `enqueueCloudDeletion` is false when this is *applying* a marker that came
    /// from another device: publishing a fresh outgoing marker there re-affirms a
    /// tombstone the local user never raised, which is churn at best and, if a
    /// third device revived the item by editing past the grace window, undoes
    /// that revival on the next pass.
    func deleteRecording(id: UUID, enqueueCloudDeletion: Bool = true) throws {
        guard let recording = try fetchRecording(id: id) else {
            // Throwing rather than returning quietly: the caller may have queued a
            // deletion marker in advance, and a row we never saw is not something
            // to publish a tombstone for.
            AppLog.shared.coreData("Recording not found for deletion: \(id)", level: .error)
            throw CoreDataDeletionError.recordingNotFound(id)
        }

        // Capture identifiers before the delete. Enqueue the cloud tombstone and
        // remove attachment files only after the save lands: a failed save rolls
        // the row back, and a tombstone queued first would still delete the
        // recording from other devices.
        var effects = DeferredDeletionEffects()
        effects.stage(recording: recording)
        for summary in try summariesForRecording(recording) {
            effects.stage(summary: summary)
        }

        do {
            // Keep the recording row and its outbox rows in the same context
            // transaction. This compound delete deliberately preserves the
            // existing rollback guarantee for a validation failure in either
            // half of the operation.
            context.delete(recording)
            try save(committing: effects, localOnly: !enqueueCloudDeletion)
            AppLog.shared.coreData("Recording deleted: \(id)")
        } catch {
            AppLog.shared.coreData("Error deleting recording: \(error)", level: .error)
            throw error
        }
    }

    /// Every summary row belonging to a recording, not just the linked one — the
    /// duplicates need their attachments removed and their cloud rows tombstoned
    /// too, or they survive as orphans a later restore pulls back down.
    private func summariesForRecording(_ recording: RecordingEntry) throws -> [SummaryEntry] {
        guard let recordingId = recording.id else { return [] }
        return try fetchSummaries(
            matching: NSPredicate(
                format: "recordingId == %@ OR recording.id == %@",
                recordingId as CVarArg,
                recordingId as CVarArg
            )
        )
    }

    /// Moves a recording's content timestamp forward, never back.
    ///
    /// CLAUDE.md makes `lastModified` the value iCloud arbitration compares for a
    /// recording, so writing an older summary's `generatedAt` straight into it —
    /// which a restore or a backdated regeneration will do — makes the local row
    /// look older than the cloud copy and invites a stale copy to overwrite
    /// newer local metadata such as the recording name.
    private func advanceLastModified(_ recording: RecordingEntry, to date: Date?) {
        guard let date else { return }
        guard let current = recording.lastModified else {
            recording.lastModified = date
            return
        }
        recording.lastModified = max(current, date)
    }

    /// Removes attachment folders left behind by summaries that no longer exist.
    ///
    /// Deliberately reconciliation rather than another staged cleanup at each
    /// delete site: a cascade delete never runs our code at all, and the batch
    /// delete behind "clear all data" bypasses relationship callbacks, so no
    /// amount of call-site diligence catches every case.
    @discardableResult
    func pruneOrphanedSummaryAttachments() -> Int? {
        SummaryAttachmentStore.shared.pruneOrphans(against: context)
    }

    func getRecording(forSummaryId summaryId: UUID) throws -> RecordingEntry? {
        try fetchRecordings(
            matching: NSPredicate(
                format: "summaryId == %@ OR summary.id == %@",
                summaryId as CVarArg,
                summaryId as CVarArg
            )
        ).first
    }

    private func fetchRecordings(
        matching predicate: NSPredicate,
        in fetchContext: NSManagedObjectContext? = nil
    ) throws -> [RecordingEntry] {
        let request: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        request.predicate = predicate
        return try fetchCollection(request, operation: "recordings", in: fetchContext)
    }

    private func fetchSummaries(
        matching predicate: NSPredicate,
        in fetchContext: NSManagedObjectContext? = nil
    ) throws -> [SummaryEntry] {
        let request: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        request.predicate = predicate
        request.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
        return try fetchCollection(request, operation: "summaries", in: fetchContext)
    }

    /// Saves a mutation while retaining the caller's pending changes when the
    /// save fails. Operation names are sanitized and are used by focused
    /// failure tests to exercise each persistence boundary deterministically.
    func saveContext(operation: String = "Core Data mutation") throws {
        try save(context, operation: operation)
    }

    private func save(_ saveContext: NSManagedObjectContext, operation: String) throws {
        #if DEBUG
        if let injectedFailure = Self.injectedSaveFailure,
           (Self.injectedSaveOperation == nil || Self.injectedSaveOperation == operation) {
            throw CoreDataSaveError(operation: operation, failure: injectedFailure)
        }
        #endif

        do {
            try saveContext.save()
        } catch let error as CoreDataSaveError {
            throw error
        } catch {
            let wrappedError = CoreDataSaveError(
                operation: operation,
                failure: PersistenceStoreFailure(error: error)
            )
            AppLog.shared.coreData(
                "durable_save_failed operation=\(operation) cause=\(wrappedError.failure.diagnosticDescription)",
                level: .error
            )
            throw wrappedError
        }
    }

    /// Performs a mutation in a sibling context so a failed save cannot roll
    /// back, or a successful save cannot accidentally commit, unrelated edits
    /// staged in the UI context.
    @discardableResult
    func performIsolatedMutation<Result>(
        operation: String,
        _ mutation: (NSManagedObjectContext) throws -> Result
    ) throws -> Result {
        guard let isolatedContext = PendingCloudMutationStore.makeIsolatedContext(basedOn: context) else {
            throw CoreDataMutationError.contextUnavailable
        }

        do {
            let result = try mutation(isolatedContext)
            let insertedObjects = Array(isolatedContext.insertedObjects)
            if !insertedObjects.isEmpty {
                try isolatedContext.obtainPermanentIDs(for: insertedObjects)
            }

            guard isolatedContext.hasChanges else {
                return result
            }

            let changes: [AnyHashable: Any] = [
                NSInsertedObjectsKey: insertedObjects.map(\.objectID),
                NSUpdatedObjectsKey: Array(isolatedContext.updatedObjects).map(\.objectID),
                NSDeletedObjectsKey: Array(isolatedContext.deletedObjects).map(\.objectID)
            ]
            try save(isolatedContext, operation: operation)
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: changes, into: [context])
            return result
        } catch {
            isolatedContext.rollback()
            throw error
        }
    }

    /// Discards every uncommitted change in the context.
    ///
    /// `saveContext()` deliberately leaves a failed save's edits staged, which is
    /// fine for a caller that will retry — but not for one that answers the failure
    /// by withdrawing durable intent elsewhere. Those callers must roll back first,
    /// or a later unrelated `saveContext()` commits the edits they just disowned.
    /// The private `save(committing:)` below does the same thing for delete paths.
    func rollbackContext() {
        context.rollback()
    }

    /// Saves the local mutation and its cloud outbox rows as one transaction,
    /// then runs only irreversible filesystem effects after that transaction
    /// succeeds. Every user deletion path goes through here.
    func save(committing effects: DeferredDeletionEffects, localOnly: Bool = false) throws {
        do {
            if !localOnly {
                try effects.stageCloudMutations(in: context)
            }
            try save(context, operation: localOnly ? "local deletion" : "deletion")
        } catch {
            context.rollback()
            throw error
        }

        if localOnly {
            effects.commitLocalOnly()
        } else {
            effects.commit()
        }
    }

    /// Removes superseded summaries after a replacement has already committed.
    /// The cleanup uses a sibling context so a failed secondary save cannot
    /// undo the replacement or consume unrelated pending edits.
    func deleteSummariesAfterSave(ids: [UUID], effects: DeferredDeletionEffects) throws {
        guard !ids.isEmpty else { return }

        let isolatedEffects = effects
        _ = try performIsolatedMutation(operation: "summary cleanup") { isolatedContext in
            let request: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            let summaries = try fetchCollection(
                request,
                operation: "summary cleanup",
                in: isolatedContext
            )
            for summary in summaries {
                isolatedContext.delete(summary)
            }
            try isolatedEffects.stageCloudMutations(in: isolatedContext)
        }
        isolatedEffects.commit()
    }

    // MARK: - Conversion Helpers

    private func convertToTranscriptData(transcriptEntry: TranscriptEntry, recordingEntry: RecordingEntry) -> TranscriptData? {
        guard let _ = transcriptEntry.id,
              let recordingId = recordingEntry.id else {
            AppLog.shared.coreData("Transcript missing id for recording: \(recordingEntry.id?.uuidString ?? "nil")", level: .error)
            return nil
        }

        // The transcript is valid even when the audio file is gone. Use a
        // stable recording-scoped placeholder when no stored URL remains.
        let url = getAbsoluteURL(for: recordingEntry) ?? preservedContentURL(for: recordingEntry, recordingId: recordingId)

        // Decode segments from JSON
        var segments: [TranscriptSegment] = []
        if let segmentsString = transcriptEntry.segments,
           let segmentsData = segmentsString.data(using: .utf8) {
            segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }

        // Decode speaker mappings from JSON
        var speakerMappings: [String: String] = [:]
        if let mappingsString = transcriptEntry.speakerMappings,
           let mappingsData = mappingsString.data(using: .utf8) {
            speakerMappings = (try? JSONDecoder().decode([String: String].self, from: mappingsData)) ?? [:]
        }

        // Convert engine string to enum
        let engine = transcriptEntry.engine.flatMap { TranscriptionEngine(rawValue: $0) }

        return TranscriptData(
            id: transcriptEntry.id ?? UUID(),
            recordingId: recordingId,
            recordingURL: url,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            segments: segments,
            speakerMappings: speakerMappings,
            engine: engine,
            processingTime: transcriptEntry.processingTime,
            confidence: transcriptEntry.confidence,
            createdAt: transcriptEntry.createdAt,
            lastModified: transcriptEntry.lastModified
        )
    }

    private func convertToEnhancedSummaryData(summaryEntry: SummaryEntry, recordingEntry: RecordingEntry) -> EnhancedSummaryData? {
        guard let _ = summaryEntry.id,
              let recordingId = recordingEntry.id else {
            AppLog.shared.coreData("Missing IDs for summary/recording conversion", level: .error)
            return nil
        }
        // Allow preserved summaries without an audio URL by using a stable
        // recording-scoped placeholder when no stored URL remains.
        let url = getAbsoluteURL(for: recordingEntry) ?? preservedContentURL(for: recordingEntry, recordingId: recordingId)

        // Decode structured data from JSON
        var titles: [TitleItem] = []
        if let titlesString = summaryEntry.titles,
           let titlesData = titlesString.data(using: .utf8) {
            titles = (try? JSONDecoder().decode([TitleItem].self, from: titlesData)) ?? []
        }

        var tasks: [TaskItem] = []
        if let tasksString = summaryEntry.tasks,
           let tasksData = tasksString.data(using: .utf8) {
            tasks = (try? JSONDecoder().decode([TaskItem].self, from: tasksData)) ?? []
        }

        var reminders: [ReminderItem] = []
        if let remindersString = summaryEntry.reminders,
           let remindersData = remindersString.data(using: .utf8) {
            reminders = (try? JSONDecoder().decode([ReminderItem].self, from: remindersData)) ?? []
        }

        // Convert content type string to enum
        let contentType = summaryEntry.contentType.flatMap { ContentType(rawValue: $0) } ?? .general

        let method = summaryEntry.aiMethod ?? ""
        let decodedMetadata = SummaryMetadataCodec.decode(method)
        let engine = decodedMetadata.engine ?? SummaryMetadataCodec.inferredEngine(from: decodedMetadata.model)

        return EnhancedSummaryData(
            id: summaryEntry.id ?? UUID(),
            recordingId: recordingId,
            transcriptId: summaryEntry.transcriptId,
            recordingURL: url,
            recordingName: recordingEntry.recordingName ?? "",
            recordingDate: recordingEntry.recordingDate ?? Date(),
            summary: summaryEntry.summary ?? "",
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiEngine: engine,
            aiModel: decodedMetadata.model,
            originalLength: Int(summaryEntry.originalLength),
            processingTime: summaryEntry.processingTime,
            generatedAt: summaryEntry.generatedAt,
            version: Int(summaryEntry.version),
            wordCount: Int(summaryEntry.wordCount),
            compressionRatio: summaryEntry.compressionRatio,
            confidence: summaryEntry.confidence
        )
    }

    // MARK: - Processing Job Operations

    func getAllProcessingJobs() throws -> [ProcessingJobEntry] {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ProcessingJobEntry.startTime, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "processing jobs")
    }

    /// Throwing counterpart used to decide whether a reviewed audio file is
    /// still owned by an in-flight processing job. A failed fetch must fail
    /// closed instead of looking like a store with no jobs.
    func fetchProcessingJobsForDiagnostics() throws -> [ProcessingJobEntry] {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ProcessingJobEntry.startTime, ascending: false)]
        return try fetchCollection(fetchRequest, operation: "processing jobs")
    }

    func getProcessingJob(id: UUID) -> ProcessingJobEntry? {
        do {
            return try fetchProcessingJob(id: id)
        } catch {
            return nil
        }
    }

    /// Throwing identity lookup for job mutations. A nil result means only
    /// that the row does not exist; a store read failure remains an error.
    func fetchProcessingJob(id: UUID) throws -> ProcessingJobEntry? {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try fetchCollection(fetchRequest, operation: "processing job").first
    }

    func createProcessingJob(
        id: UUID,
        jobType: String,
        engine: String,
        recordingURL: URL,
        recordingName: String,
        modelName: String? = nil
    ) throws -> ProcessingJobEntry {
        // The optional URL lookup cannot distinguish a missing recording from
        // an unavailable store. Resolve it before creating a job so a failed
        // read cannot authorize processing of a different or empty library.
        let recording = try fetchRecording(url: recordingURL)
        if recording?.objectID.isTemporaryID == true {
            throw CoreDataProcessingJobError.temporaryObjectID
        }

        _ = try performIsolatedMutation(operation: "processing job creation") { isolatedContext in
            let job = ProcessingJobEntry(context: isolatedContext)
            job.id = id
            job.jobType = jobType
            job.engine = engine
            job.recordingURL = recordingURL.lastPathComponent
            job.recordingName = recordingName
            job.modelName = modelName
            job.status = "queued"
            job.progress = 0.0
            job.startTime = Date()
            job.completionTime = nil
            job.error = nil

            if let recording {
                guard let isolatedRecording = try isolatedContext.existingObject(with: recording.objectID) as? RecordingEntry else {
                    throw CoreDataProcessingJobError.jobNotFound(id)
                }
                job.recording = isolatedRecording
            }
        }

        guard let job = try fetchProcessingJob(id: id) else {
            throw CoreDataProcessingJobError.jobNotFound(id)
        }
        AppLog.shared.coreData("Created processing job: \(id)")
        return job
    }

    func updateProcessingJob(_ job: ProcessingJobEntry) throws {
        guard let id = job.id else {
            throw CoreDataProcessingJobError.missingIdentity
        }
        guard !job.objectID.isTemporaryID else {
            throw CoreDataProcessingJobError.temporaryObjectID
        }

        do {
            _ = try performIsolatedMutation(operation: "processing job update") { isolatedContext in
                guard let storedJob = try isolatedContext.existingObject(with: job.objectID) as? ProcessingJobEntry else {
                    throw CoreDataProcessingJobError.jobNotFound(id)
                }
                storedJob.status = job.status
                storedJob.progress = job.progress
                storedJob.completionTime = job.completionTime
                storedJob.error = job.error
                storedJob.lastModified = Date()
            }
        } catch {
            // The caller may have prepared the new state on the main-context
            // object. Discard only that object's failed edits; unrelated
            // pending edits remain staged for their owner.
            if !job.isDeleted {
                context.refresh(job, mergeChanges: false)
            }
            throw error
        }
    }

    func deleteProcessingJob(_ job: ProcessingJobEntry) throws {
        guard let id = job.id else {
            throw CoreDataProcessingJobError.missingIdentity
        }
        guard !job.objectID.isTemporaryID else {
            throw CoreDataProcessingJobError.temporaryObjectID
        }

        _ = try performIsolatedMutation(operation: "processing job deletion") { isolatedContext in
            guard let storedJob = try isolatedContext.existingObject(with: job.objectID) as? ProcessingJobEntry else {
                throw CoreDataProcessingJobError.jobNotFound(id)
            }
            isolatedContext.delete(storedJob)
        }
        AppLog.shared.coreData("Deleted processing job: \(id.uuidString)")
    }

    @discardableResult
    func deleteCompletedProcessingJobs() throws -> Int {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "status IN %@", ["completed", "failed"])

        let deletedCount = try performIsolatedMutation(operation: "completed processing job deletion") { isolatedContext in
            let completedJobs = try fetchCollection(
                fetchRequest,
                operation: "completed processing jobs",
                in: isolatedContext
            )
            for job in completedJobs {
                isolatedContext.delete(job)
            }
            return completedJobs.count
        }
        AppLog.shared.coreData("Deleted \(deletedCount) completed processing jobs")
        return deletedCount
    }

    // MARK: - Cleanup Operations

    /// Cleans up orphaned recordings that have no audio file and no meaningful content
    func cleanupOrphanedRecordings() throws -> Int {
        let allRecordings = try getAllRecordings()
        var cleanedCount = 0

        for recording in allRecordings {
            // Check if this is an orphaned recording
            let hasNoURL = recording.recordingURL == nil
            let hasNoTranscript = recording.transcript == nil
            let hasNoSummary = recording.summary == nil

            // Only clean up recordings that have absolutely no content
            if hasNoURL && hasNoTranscript && hasNoSummary {
                AppLog.shared.coreData("Cleaning up orphaned recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
                // Deliberately local-only. A deletion marker records that the *user*
                // deleted something, and this is automatic housekeeping. Restoring a
                // recording-only backup with audio excluded produces exactly this
                // shape — no URL, transcript or summary — so tombstoning here would
                // delete a perfectly good CloudKit recording, and its audio, on every
                // device without anyone asking.
                context.delete(recording)
                cleanedCount += 1
            }
            // For recordings with summaries but no audio, preserve them silently
            // (These are intentionally preserved summaries)
        }

        if cleanedCount > 0 {
            do {
                try context.save()
                AppLog.shared.coreData("Cleaned up \(cleanedCount) orphaned recordings")
            } catch {
                AppLog.shared.coreData("Failed to save cleanup: \(error)", level: .error)
                context.rollback()
                throw error
            }
        }

        return cleanedCount
    }

    /// Fixes recordings that should have been deleted completely but still exist as orphans
    func fixIncompletelyDeletedRecordings() throws -> Int {
        let allRecordings = try getAllRecordings()
        var fixedCount = 0

        for recording in allRecordings {
            // Look for recordings with no URL and no content that appear to be leftover from deletions
            let hasNoURL = recording.recordingURL == nil
            let hasNoTranscript = recording.transcript == nil
            let hasNoSummary = recording.summary == nil

            if hasNoURL && hasNoTranscript && hasNoSummary {
                // Delete this leftover row locally only. A deletion marker
                // means the *user* deleted something; this is automatic
                // housekeeping. Restoring a recording-only backup with audio
                // excluded produces the same empty shape, so tombstoning here
                // would erase a valid CloudKit recording on every device.
                context.delete(recording)
                fixedCount += 1
            }
        }

        if fixedCount > 0 {
            do {
                try context.save()
                AppLog.shared.coreData("Fixed \(fixedCount) incompletely deleted recordings")
            } catch {
                AppLog.shared.coreData("Failed to save fixes: \(error)", level: .error)
                context.rollback()
                throw error
            }
        }

        return fixedCount
    }

    /// Cleans up recordings that reference files that no longer exist
    func cleanupRecordingsWithMissingFiles() throws -> Int {
        let allRecordings = try getAllRecordings()
        var cleanedCount = 0

        for recording in allRecordings {
            // Never touch archived recordings — their audio was intentionally offloaded
            if recording.isArchived {
                continue
            }

            guard let urlString = recording.recordingURL else { continue }

            // Skip if this is a summary-only recording (no URL expected)
            if recording.summary != nil && urlString.isEmpty {
                continue
            }

            // Check if the file actually exists
            if let url = getAbsoluteURL(for: recording) {
                if !FileManager.default.fileExists(atPath: url.path) {
                    AppLog.shared.coreData("Cleaning up recording with missing file: \(url.lastPathComponent)", level: .debug)

                    // Only delete if there's no transcript or summary to preserve
                    let hasTranscript = recording.transcript != nil
                    let hasSummary = recording.summary != nil

                    if !hasTranscript && !hasSummary {
                        // No valuable content to preserve, delete the record.
                        // Local-only, like the orphan cleanup: a missing local file
                        // means this device cannot see the audio, not that the user
                        // deleted the recording. Publishing a tombstone here would
                        // wipe the good CloudKit copy from every other device.
                        context.delete(recording)
                        cleanedCount += 1
                    } else {
                        // Has transcript or summary, just clear the URL
                        AppLog.shared.coreData("Preserving recording with transcript/summary, clearing URL", level: .debug)
                        recording.recordingURL = nil
                        recording.lastModified = Date()
                    }
                }
            } else {
                // Could not resolve URL at all
                AppLog.shared.coreData("Recording with unresolvable URL, ID: \(recording.id?.uuidString ?? "nil")", level: .debug)

                let hasTranscript = recording.transcript != nil
                let hasSummary = recording.summary != nil

                if !hasTranscript && !hasSummary {
                    // Local-only for the same reason as above.
                    context.delete(recording)
                    cleanedCount += 1
                } else {
                    recording.recordingURL = nil
                    recording.lastModified = Date()
                }
            }
        }

        if cleanedCount > 0 {
            do {
                try context.save()
                AppLog.shared.coreData("Cleaned up \(cleanedCount) recordings with missing files")
            } catch {
                AppLog.shared.coreData("Failed to save missing file cleanup: \(error)", level: .error)
                context.rollback()
                throw error
            }
        }

        return cleanedCount
    }

    // MARK: - URL Synchronization

    /// Syncs Core Data recording URLs with actual files on disk
    func syncRecordingURLs() throws {
        let allRecordings = try getAllRecordings()
        var updatedCount = 0

        // Pre-check if any work is needed to avoid unnecessary logging
        let needsWork = allRecordings.contains { recording in
            guard let urlString = recording.recordingURL else { return false }
            // Skip relative paths - these don't need sync
            if !urlString.contains("/") && !urlString.hasPrefix("file://") {
                return false
            }
            guard let oldURL = URL(string: urlString), oldURL.scheme != nil else { return false }
            return !FileManager.default.fileExists(atPath: oldURL.path)
        }

        if needsWork {
            AppLog.shared.coreData("Starting URL synchronization...")
        }

        for recording in allRecordings {
            guard let urlString = recording.recordingURL else { continue }

            // Skip relative paths (just filenames) - these are handled by getAbsoluteURL()
            if !urlString.contains("/") && !urlString.hasPrefix("file://") {
                continue
            }

            guard let oldURL = URL(string: urlString) else { continue }

            // Only process absolute URLs that need fixing
            guard oldURL.scheme != nil else { continue }

            // Check if the file exists at the stored URL
            if !FileManager.default.fileExists(atPath: oldURL.path) {
                // File doesn't exist at stored URL, try to find it by name
                let filename = oldURL.lastPathComponent
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

                // Look for the file with the same name in documents directory
                do {
                    let fileURLs = try FileManager.default.contentsOfDirectory(at: documentsPath, includingPropertiesForKeys: nil, options: [])
                    let matchingFiles = fileURLs.filter { $0.lastPathComponent == filename }

                    if let newURL = matchingFiles.first {
                        AppFileProtection.apply(to: newURL)
                        // Update the Core Data entry with the correct relative path
                        recording.recordingURL = urlToRelativePath(newURL)
                        recording.lastModified = Date()
                        updatedCount += 1
                        // Only log if the filename actually changed or if this is a real path change
                        if oldURL.lastPathComponent != newURL.lastPathComponent {
                            AppLog.shared.coreData("Updated URL for recording ID \(recording.id?.uuidString ?? "nil"): \(oldURL.lastPathComponent) -> \(newURL.lastPathComponent)", level: .debug)
                        } else {
                            AppLog.shared.coreData("Fixed path for recording ID \(recording.id?.uuidString ?? "nil"): \(newURL.lastPathComponent)", level: .debug)
                        }
                    } else {
                        // If no exact filename match, try to find by recording name
                        // This handles cases where the file was renamed but Core Data still has old name
                        let recordingName = recording.recordingName ?? ""
                        if !recordingName.isEmpty {
                            let matchingFilesByName = fileURLs.filter { url in
                                let fileName = url.deletingPathExtension().lastPathComponent
                                return fileName == recordingName
                            }

                            if let newURL = matchingFilesByName.first {
                                AppFileProtection.apply(to: newURL)
                                // Update the Core Data entry with the correct relative path
                                recording.recordingURL = urlToRelativePath(newURL)
                                recording.lastModified = Date()
                                updatedCount += 1
                                AppLog.shared.coreData("Updated URL by name match for recording ID \(recording.id?.uuidString ?? "nil"): \(oldURL.lastPathComponent) -> \(newURL.lastPathComponent)", level: .debug)
                            } else {
                                AppLog.shared.coreData("Could not find file for recording ID \(recording.id?.uuidString ?? "nil"), expected filename: \(filename), available files: \(fileURLs.count)", level: .error)
                            }
                        } else {
                            AppLog.shared.coreData("Could not find file for recording ID \(recording.id?.uuidString ?? "nil")", level: .error)
                        }
                    }
                } catch {
                    AppLog.shared.coreData("Error scanning documents directory: \(error)", level: .error)
                    throw error
                }
            }
        }

        // Save changes if any updates were made
        if updatedCount > 0 {
            do {
                try context.save()
                AppLog.shared.coreData("Saved \(updatedCount) URL updates to Core Data")
            } catch {
                AppLog.shared.coreData("Failed to save URL updates: \(error)", level: .error)
                context.rollback()
                throw error
            }
        } else if needsWork {
            AppLog.shared.coreData("No URL updates needed")
        }
        // If needsWork was false, we don't log anything to reduce console spam
    }

    /// Updates a recording's URL when it's found by filename but the URL is outdated
    func updateRecordingURL(recording: RecordingEntry, newURL: URL) {
        recording.recordingURL = urlToRelativePath(newURL)
        recording.lastModified = Date()

        do {
            try context.save()
            AppLog.shared.coreData("Updated recording URL for ID \(recording.id?.uuidString ?? "nil"): \(newURL.lastPathComponent)")
        } catch {
            AppLog.shared.coreData("Failed to save URL update: \(error)", level: .error)
        }
    }

    func updateRecordingName(for recordingId: UUID, newName: String) throws {
        guard let recording = try fetchRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"])
        }
        let recordingObjectID = recording.objectID

        // Clean any legacy [Watch] tags from the name
        let finalName = newName.replacingOccurrences(of: " [Watch]", with: "")

        _ = try performIsolatedMutation(operation: "recording name update") { isolatedContext in
            guard let recording = try isolatedContext.existingObject(
                with: recordingObjectID
            ) as? RecordingEntry else {
                throw NSError(
                    domain: "CoreDataManager",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"]
                )
            }
            recording.recordingName = finalName
            recording.lastModified = Date()
        }
        AppLog.shared.coreData("Updated recording name for ID: \(recordingId)")
    }

    func updateCloudSyncDisabled(for recordingId: UUID, disabled: Bool) throws {
        guard let recording = try fetchRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"])
        }
        let recordingObjectID = recording.objectID

        _ = try performIsolatedMutation(operation: "iCloud exclusion update") { isolatedContext in
            guard let recording = try isolatedContext.existingObject(with: recordingObjectID) as? RecordingEntry else {
                throw NSError(
                    domain: "CoreDataManager",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"]
                )
            }
            recording.isCloudSyncDisabled = disabled
            recording.lastModified = Date()
            if disabled {
                var effects = DeferredDeletionEffects()
                effects.stageLocalOnlyRemoval(recordingId: recordingId)
                try effects.stageCloudMutations(in: isolatedContext)
            } else {
                try PendingCloudMutationStore.remove(
                    kind: .localOnlyRemoval,
                    targetId: recordingId,
                    from: isolatedContext
                )
            }
        }
        AppLog.shared.coreData("Updated iCloud exclusion for recording ID: \(recordingId)")
    }

    // MARK: - Location File Helpers

    /// Gets the absolute URL for a location file associated with a recording
    func getLocationFileURL(for recording: RecordingEntry) -> URL? {
        guard let recordingURL = getAbsoluteURL(for: recording) else {
            return nil
        }
        return recordingURL.deletingPathExtension().appendingPathExtension("location")
    }

    /// Loads location data for a recording using proper URL resolution
    func loadLocationData(for recording: RecordingEntry) -> LocationData? {
        guard let locationURL = getLocationFileURL(for: recording) else {
            return nil
        }

        guard let data = try? Data(contentsOf: locationURL),
              let locationData = try? JSONDecoder().decode(LocationData.self, from: data) else {
            return nil
        }

        return locationData
    }
}
