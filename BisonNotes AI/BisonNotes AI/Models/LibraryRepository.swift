import Foundation

/// Storage-neutral recording values returned by the first repository boundary.
///
/// The snapshot deliberately contains values that can be copied out of either
/// Core Data or SQLite. It does not expose managed objects, GRDB rows, or
/// mutable relationships to callers.
struct LibraryRecordingSnapshot: Equatable, Sendable {
    let storageID: String
    let legacyID: String?
    let name: String?
    let recordingDate: Date?
    let locationAccuracy: Double?
    let locationAddress: String?
    let locationLatitude: Double?
    let locationLongitude: Double?
    let locationTimestamp: Date?
    let duration: Double?
    let fileSize: Int64?
    let recordingURL: String?
    let isArchived: Bool?
    let archivedAt: Date?
    let archiveNote: String?
    let isCloudSyncDisabled: Bool?
    let lastModified: Date?

    static func stableOrder(
        _ lhs: LibraryRecordingSnapshot,
        _ rhs: LibraryRecordingSnapshot
    ) -> Bool {
        switch (lhs.recordingDate, rhs.recordingDate) {
        case let (leftDate?, rightDate?) where leftDate != rightDate:
            return leftDate < rightDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.storageID < rhs.storageID
        }
    }
}

/// Storage-neutral location values attached to a recording.
///
/// This mirrors the persisted Core Data/SQLite scalar fields instead of
/// depending on `LocationData`, which is also used by the Watch wire format.
struct LibraryRecordingLocationSnapshot: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let accuracy: Double?
    let address: String?
}

/// Stable identifiers used by repository commands.
///
/// Existing Core Data rows are addressed by their legacy UUID, while the
/// app-owned SQLite generation also has an independent storage ID. Commands
/// may carry either or both so adapters can resolve the same operation without
/// exposing managed objects or database rows to callers.
struct LibraryRecordingReference: Equatable, Sendable {
    let storageID: String?
    let legacyID: String?

    init(storageID: String? = nil, legacyID: String? = nil) {
        self.storageID = storageID
        self.legacyID = legacyID
    }

    var displayValue: String {
        storageID ?? legacyID ?? "<missing recording identity>"
    }
}

enum LibraryImportedAudioFileStoreError: LocalizedError {
    case invalidStoredURL
    case documentsDirectoryUnavailable
    case fileStillExists(URL)

    var errorDescription: String? {
        switch self {
        case .invalidStoredURL:
            return "The imported audio URL is empty or could not be resolved."
        case .documentsDirectoryUnavailable:
            return "The Documents directory is unavailable."
        case .fileStillExists(let url):
            return "Imported audio still exists after removal: \(url.path)"
        }
    }
}

/// Resolves and removes recording-owned imported audio without depending on a
/// persistence adapter. The stored URL remains in metadata until the caller's
/// repository transaction commits, so a failed removal is retryable.
enum LibraryImportedAudioFileStore {
    static let permittedSidecarExtensions = ["location", "recordingmeta"]

    /// Returns the stored path and the Documents-relative filename fallback
    /// used when an app container path changed between launches.
    static func storedURLCandidates(
        _ storedURL: String,
        documentsURL: URL?
    ) -> [URL] {
        guard !storedURL.isEmpty else { return [] }

        let primaryURL: URL?
        if storedURL.hasPrefix("/") {
            primaryURL = URL(fileURLWithPath: storedURL)
        } else if let parsed = URL(string: storedURL), parsed.isFileURL {
            primaryURL = parsed
        } else {
            guard let documentsURL else { return [] }
            let decoded = storedURL.removingPercentEncoding ?? storedURL
            primaryURL = documentsURL.appendingPathComponent(decoded)
        }

        guard let primaryURL else { return [] }
        guard let documentsURL else { return [primaryURL] }
        let fallbackURL = documentsURL.appendingPathComponent(primaryURL.lastPathComponent)
        return fallbackURL == primaryURL ? [primaryURL] : [primaryURL, fallbackURL]
    }

    /// Removes every known representation of the main file and best-effort
    /// sidecars. The main file is the retry gate; a sidecar failure must not keep
    /// a valid metadata tombstone from completing.
    @discardableResult
    static func remove(
        storedURL: String,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let documentsURL = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        let candidates = storedURLCandidates(storedURL, documentsURL: documentsURL)
        guard !candidates.isEmpty else {
            throw documentsURL == nil
                ? LibraryImportedAudioFileStoreError.documentsDirectoryUnavailable
                : LibraryImportedAudioFileStoreError.invalidStoredURL
        }

        var removedMainFile = false
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
                removedMainFile = true
            } catch {
                // A concurrent cleanup can win between the existence check and
                // removeItem. Only a file that is still present is a failure.
                if fileManager.fileExists(atPath: url.path) {
                    throw error
                }
            }
        }

        if let remainingURL = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path)
        }) {
            throw LibraryImportedAudioFileStoreError.fileStillExists(remainingURL)
        }

        for url in candidates {
            for sidecarExtension in permittedSidecarExtensions {
                let sidecarURL = url.deletingPathExtension()
                    .appendingPathExtension(sidecarExtension)
                guard fileManager.fileExists(atPath: sidecarURL.path) else { continue }
                do {
                    try fileManager.removeItem(at: sidecarURL)
                } catch {
                    // The main file is the durable retry gate. A stale sidecar
                    // should not strand the recording URL forever.
                }
            }
        }

        return removedMainFile
    }
}

/// Creates the metadata row for an audio recording whose file is already owned
/// by the caller. Audio copying, file naming and source retention are separate
/// journaled operations; this command only commits recording metadata.
struct LibraryRecordingCreateCommand: Equatable, Sendable {
    let id: UUID
    let recordingURL: String
    let name: String?
    let recordingDate: Date
    let createdAt: Date
    let duration: Double
    let fileSize: Int64
    let audioQuality: String?
    let locationAccuracy: Double?
    let locationAddress: String?
    let locationLatitude: Double?
    let locationLongitude: Double?
    let locationTimestamp: Date?
    let transcriptionStatus: String
    let summaryStatus: String
    let isCloudSyncDisabled: Bool
    let modifiedAt: Date

    init(
        id: UUID = UUID(),
        recordingURL: String,
        name: String?,
        recordingDate: Date,
        createdAt: Date = Date(),
        duration: Double,
        fileSize: Int64,
        audioQuality: String? = nil,
        locationAccuracy: Double? = nil,
        locationAddress: String? = nil,
        locationLatitude: Double? = nil,
        locationLongitude: Double? = nil,
        locationTimestamp: Date? = nil,
        transcriptionStatus: String = "Not Started",
        summaryStatus: String = "Not Started",
        isCloudSyncDisabled: Bool = false,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.recordingURL = recordingURL
        self.name = name
        self.recordingDate = recordingDate
        self.createdAt = createdAt
        self.duration = duration
        self.fileSize = fileSize
        self.audioQuality = audioQuality
        self.locationAccuracy = locationAccuracy
        self.locationAddress = locationAddress
        self.locationLatitude = locationLatitude
        self.locationLongitude = locationLongitude
        self.locationTimestamp = locationTimestamp
        self.transcriptionStatus = transcriptionStatus
        self.summaryStatus = summaryStatus
        self.isCloudSyncDisabled = isCloudSyncDisabled
        self.modifiedAt = modifiedAt ?? createdAt
    }
}

extension LibraryRecordingCreateCommand {
    func validate() throws {
        guard !recordingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "recording URL must not be empty"
            )
        }
        guard duration.isFinite, duration >= 0 else {
            throw LibraryRepositoryError.invalidCommand(
                "recording duration must be finite and nonnegative"
            )
        }
        guard fileSize >= 0 else {
            throw LibraryRepositoryError.invalidCommand(
                "recording file size must be nonnegative"
            )
        }

        let dates = [recordingDate, createdAt, modifiedAt, locationTimestamp]
            .compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "recording dates must be finite"
            )
        }

        for (value, field) in [
            (transcriptionStatus, "transcription status"),
            (summaryStatus, "summary status")
        ] where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LibraryRepositoryError.invalidCommand(
                "recording \(field) must not be empty"
            )
        }

        if let locationAccuracy {
            guard locationAccuracy.isFinite, locationAccuracy >= 0 else {
                throw LibraryRepositoryError.invalidCommand(
                    "recording location accuracy must be finite and nonnegative"
                )
            }
        }
        if let locationLatitude {
            guard locationLatitude.isFinite, (-90.0...90.0).contains(locationLatitude) else {
                throw LibraryRepositoryError.invalidCommand(
                    "recording latitude must be finite and between -90 and 90"
                )
            }
        }
        if let locationLongitude {
            guard locationLongitude.isFinite, (-180.0...180.0).contains(locationLongitude) else {
                throw LibraryRepositoryError.invalidCommand(
                    "recording longitude must be finite and between -180 and 180"
                )
            }
        }
    }
}

/// Removes a newly-created recording when a multi-step import cannot finish.
///
/// This is intentionally narrower than user deletion: it refuses to remove a
/// recording with dependent metadata and does not enqueue a CloudKit tombstone.
/// User deletion needs a separate command that carries the existing outbox and
/// attachment-cleanup semantics.
struct LibraryRecordingDiscardCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let expectedLastModified: Date?
    let discardedAt: Date

    init(
        reference: LibraryRecordingReference,
        expectedLastModified: Date? = nil,
        discardedAt: Date = Date()
    ) {
        self.reference = reference
        self.expectedLastModified = expectedLastModified
        self.discardedAt = discardedAt
    }
}

extension LibraryRecordingDiscardCommand {
    func validate() throws {
        let dates = [discardedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "discard dates must be finite"
            )
        }
    }
}

/// Deletes a recording and its locally owned metadata.
///
/// A user delete is deliberately broader than `LibraryRecordingDiscardCommand`:
/// it preserves the existing CloudKit outbox contract, including the child
/// identities needed to remove the cloud content. Applying a tombstone received
/// from another device sets `enqueueCloudDeletion` to false so the local delete
/// does not publish the same intent again.
struct LibraryRecordingDeleteCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let expectedLastModified: Date?
    let requestedAt: Date
    let enqueueCloudDeletion: Bool

    init(
        reference: LibraryRecordingReference,
        expectedLastModified: Date? = nil,
        requestedAt: Date = Date(),
        enqueueCloudDeletion: Bool = true
    ) {
        self.reference = reference
        self.expectedLastModified = expectedLastModified
        self.requestedAt = requestedAt
        self.enqueueCloudDeletion = enqueueCloudDeletion
    }
}

extension LibraryRecordingDeleteCommand {
    func validate() throws {
        let dates = [requestedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "delete dates must be finite"
            )
        }
    }
}

/// Removes a recording's audio and transcript while retaining its summary
/// anchor and summary content.
///
/// `transcriptIds` carries stale imported identities that may no longer have a
/// local row. Adapters also discover every locally linked transcript so a
/// retry cannot leave an older duplicate available for restore.
struct LibraryRecordingPreserveSummaryDeleteCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let transcriptIds: [UUID]
    let expectedLastModified: Date?
    let requestedAt: Date
    let enqueueCloudDeletion: Bool

    init(
        reference: LibraryRecordingReference,
        transcriptIds: [UUID] = [],
        expectedLastModified: Date? = nil,
        requestedAt: Date = Date(),
        enqueueCloudDeletion: Bool = true
    ) {
        self.reference = reference
        self.transcriptIds = Array(Set(transcriptIds)).sorted {
            $0.uuidString < $1.uuidString
        }
        self.expectedLastModified = expectedLastModified
        self.requestedAt = requestedAt
        self.enqueueCloudDeletion = enqueueCloudDeletion
    }
}

extension LibraryRecordingPreserveSummaryDeleteCommand {
    func validate() throws {
        let dates = [requestedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "preserve-summary delete dates must be finite"
            )
        }
    }
}

/// The first write command shared by the Core Data and SQLite adapters.
///
/// `expectedLastModified` is an optimistic-concurrency guard. A nil value
/// means the caller intentionally accepts the current revision. The timestamp
/// is supplied by the caller so tests and future coordinators can make the
/// commit deterministic without creating time-dependent work inside a write
/// transaction.
struct LibraryRecordingRenameCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let name: String
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryRecordingReference,
        name: String,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.name = name
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }

    /// Preserve the existing Watch-import cleanup rule at the domain boundary
    /// so both backends apply the same behavior.
    var normalizedName: String {
        name.replacingOccurrences(of: " [Watch]", with: "")
    }
}

/// Changes only the user-visible recording date while retaining all other
/// recording metadata. The optional revision guard prevents a delayed detail
/// view from overwriting a newer CloudKit, Watch, or background update.
struct LibraryRecordingDateUpdateCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let recordingDate: Date
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryRecordingReference,
        recordingDate: Date,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.recordingDate = recordingDate
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }
}

extension LibraryRecordingDateUpdateCommand {
    func validate() throws {
        let dates = [recordingDate, modifiedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "recording date update dates must be finite"
            )
        }
    }
}

/// Sets or clears the location metadata for one recording. A nil location
/// clears all five persisted location fields atomically.
struct LibraryRecordingLocationUpdateCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let location: LibraryRecordingLocationSnapshot?
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryRecordingReference,
        location: LibraryRecordingLocationSnapshot?,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.location = location
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }
}

extension LibraryRecordingLocationUpdateCommand {
    func validate() throws {
        let dates = [location?.timestamp, modifiedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "recording location update dates must be finite"
            )
        }
        guard let location else { return }
        guard location.latitude.isFinite, (-90.0...90.0).contains(location.latitude) else {
            throw LibraryRepositoryError.invalidCommand(
                "recording latitude must be finite and between -90 and 90"
            )
        }
        guard location.longitude.isFinite, (-180.0...180.0).contains(location.longitude) else {
            throw LibraryRepositoryError.invalidCommand(
                "recording longitude must be finite and between -180 and 180"
            )
        }
        if let accuracy = location.accuracy {
            guard accuracy.isFinite, accuracy >= 0 else {
                throw LibraryRepositoryError.invalidCommand(
                    "recording location accuracy must be finite and nonnegative"
                )
            }
        }
    }
}

/// Changes whether a recording participates in iCloud sync.
///
/// The command includes the pending local-only removal intent because those
/// two values must commit together. A caller may supply an expected source
/// revision when it is editing a snapshot that could have become stale.
struct LibraryRecordingCloudSyncCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let disabled: Bool
    let expectedLastModified: Date?
    let modifiedAt: Date
    let requestedAt: Date

    init(
        reference: LibraryRecordingReference,
        disabled: Bool,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date(),
        requestedAt: Date? = nil
    ) {
        self.reference = reference
        self.disabled = disabled
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
        self.requestedAt = requestedAt ?? modifiedAt
    }
}

/// Changes archive metadata after an external archive destination has been
/// verified. File-provider copies, bookmarks and local source removal remain
/// outside this command; this boundary only commits the recording state.
struct LibraryRecordingArchiveCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let archived: Bool
    let archivedAt: Date?
    let archiveNote: String?
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryRecordingReference,
        archived: Bool,
        archivedAt: Date? = nil,
        archiveNote: String? = nil,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.archived = archived
        self.archivedAt = archivedAt
        self.archiveNote = archiveNote
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }

    var persistedArchivedAt: Date? {
        archived ? (archivedAt ?? modifiedAt) : nil
    }

    var persistedArchiveNote: String? {
        archived ? archiveNote : nil
    }
}

extension LibraryRecordingArchiveCommand {
    func validate() throws {
        let dates = [modifiedAt, archivedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "archive dates must be finite"
            )
        }
        if !archived {
            guard archivedAt == nil, archiveNote == nil else {
                throw LibraryRepositoryError.invalidCommand(
                    "unarchiving must clear archive metadata"
                )
            }
        }
    }
}

/// Relinks an archived recording to audio that has already been copied and
/// validated by the caller. The URL, optional file size and archive flags are
/// committed together so a retry cannot expose a restored file as archived or
/// expose archive metadata with a stale local URL.
struct LibraryRecordingAudioRestoreCommand: Equatable, Sendable {
    let reference: LibraryRecordingReference
    let recordingURL: String
    let fileSize: Int64?
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryRecordingReference,
        recordingURL: String,
        fileSize: Int64? = nil,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.recordingURL = recordingURL
        self.fileSize = fileSize
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }
}

extension LibraryRecordingAudioRestoreCommand {
    func validate() throws {
        guard !recordingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "restored recording URL must not be empty"
            )
        }
        if let fileSize, fileSize < 0 {
            throw LibraryRepositoryError.invalidCommand(
                "restored recording file size must not be negative"
            )
        }
        let dates = [modifiedAt, expectedLastModified].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "restore dates must be finite"
            )
        }
    }
}

/// Records one already-verified external archive location without performing
/// any file-provider work. A stable `id` makes a lost acknowledgement safe to
/// retry; an existing row for the same recording and destination is also
/// reused so legacy callers cannot create duplicate location records.
struct LibraryArchiveLocationUpsertCommand: Equatable, Sendable {
    let id: UUID
    let recordingReference: LibraryRecordingReference
    let bookmarkData: Data?
    let destinationURLString: String?
    let displayName: String?
    let exportedAt: Date?
    let exportedFilename: String
    let fileSize: Int64?
    let lastVerifiedAt: Date?
    let providerDisplayName: String?
    let status: String
    let modifiedAt: Date

    init(
        id: UUID,
        recordingReference: LibraryRecordingReference,
        bookmarkData: Data? = nil,
        destinationURLString: String? = nil,
        displayName: String? = nil,
        exportedAt: Date? = nil,
        exportedFilename: String,
        fileSize: Int64? = nil,
        lastVerifiedAt: Date? = nil,
        providerDisplayName: String? = nil,
        status: String = "available",
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.recordingReference = recordingReference
        self.bookmarkData = bookmarkData
        self.destinationURLString = destinationURLString
        self.displayName = displayName
        self.exportedAt = exportedAt
        self.exportedFilename = exportedFilename
        self.fileSize = fileSize
        self.lastVerifiedAt = lastVerifiedAt
        self.providerDisplayName = providerDisplayName
        self.status = status
        self.modifiedAt = modifiedAt
    }
}

extension LibraryArchiveLocationUpsertCommand {
    func validate() throws {
        let requiredText: [(String, String)] = [
            (exportedFilename, "archive filename"),
            (status, "archive status")
        ]
        for (value, field) in requiredText {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryRepositoryError.invalidCommand(
                    "\(field) must not be empty"
                )
            }
        }

        let recordingStorageID = recordingReference.storageID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let recordingLegacyID = recordingReference.legacyID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard recordingStorageID?.isEmpty == false || recordingLegacyID?.isEmpty == false else {
            throw LibraryRepositoryError.invalidCommand(
                "archive location requires a recording identity"
            )
        }

        if let destinationURLString {
            guard !destinationURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  URL(string: destinationURLString) != nil else {
                throw LibraryRepositoryError.invalidCommand(
                    "archive destination URL must be valid"
                )
            }
        }
        guard bookmarkData != nil || destinationURLString != nil else {
            throw LibraryRepositoryError.invalidCommand(
                "archive location requires a bookmark or destination URL"
            )
        }
        if let bookmarkData {
            guard !bookmarkData.isEmpty else {
                throw LibraryRepositoryError.invalidCommand(
                    "archive bookmark data must not be empty"
                )
            }
        }
        if let fileSize {
            guard fileSize >= 0 else {
                throw LibraryRepositoryError.invalidCommand(
                    "archive file size must be non-negative"
                )
            }
        }

        let dates = [modifiedAt, exportedAt, lastVerifiedAt].compactMap { $0 }
        guard dates.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw LibraryRepositoryError.invalidCommand(
                "archive location dates must be finite"
            )
        }
    }
}

/// Creates or replaces the transcript attached to one recording.
///
/// The command carries the already-encoded payloads used by both Core Data and
/// SQLite. An adapter preserves the existing transcript identity when the
/// recording already has one; `id` is the requested identity only for a new
/// transcript. This makes a lost acknowledgement safe to retry without
/// creating a second transcript for the recording.
struct LibraryTranscriptUpsertCommand: Equatable, Sendable {
    let id: UUID
    let recordingReference: LibraryRecordingReference
    let createdAt: Date
    let segments: String
    let speakerMappings: String?
    let engine: String?
    let processingTime: Double
    let confidence: Double
    let modifiedAt: Date

    init(
        id: UUID,
        recordingReference: LibraryRecordingReference,
        createdAt: Date = Date(),
        segments: String,
        speakerMappings: String? = nil,
        engine: String? = nil,
        processingTime: Double = 0,
        confidence: Double = 0.5,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.recordingReference = recordingReference
        self.createdAt = createdAt
        self.segments = segments
        self.speakerMappings = speakerMappings
        self.engine = engine
        self.processingTime = processingTime
        self.confidence = confidence
        self.modifiedAt = modifiedAt
    }
}

extension LibraryTranscriptUpsertCommand {
    func validate() throws {
        guard !segments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "transcript segments must not be empty"
            )
        }
        guard processingTime.isFinite, processingTime >= 0 else {
            throw LibraryRepositoryError.invalidCommand(
                "transcript processing time must be finite and non-negative"
            )
        }
        guard confidence.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "transcript confidence must be finite"
            )
        }
        guard [createdAt, modifiedAt].allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "transcript dates must be finite"
            )
        }
    }
}

/// Deletes one transcript while retaining its recording and summary rows.
///
/// The local delete and its optional CloudKit tombstone are committed together
/// by each adapter. Applying a marker received from another device sets
/// `enqueueCloudDeletion` to false so replay never raises a second marker.
struct LibraryTranscriptDeleteCommand: Equatable, Sendable {
    let id: UUID
    let requestedAt: Date
    let enqueueCloudDeletion: Bool

    init(
        id: UUID,
        requestedAt: Date = Date(),
        enqueueCloudDeletion: Bool = true
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.enqueueCloudDeletion = enqueueCloudDeletion
    }
}

extension LibraryTranscriptDeleteCommand {
    func validate() throws {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "transcript delete date must be finite"
            )
        }
    }
}

/// Deletes one summary while retaining its recording and transcript rows.
///
/// Supplemental notes and attachments are owned by the application file store,
/// so the coordinator removes them only after the adapter commits the metadata
/// transaction. Applying a marker received from another device sets
/// `enqueueCloudDeletion` to false so replay never raises a second marker.
struct LibrarySummaryDeleteCommand: Equatable, Sendable {
    let id: UUID
    let requestedAt: Date
    let enqueueCloudDeletion: Bool

    init(
        id: UUID,
        requestedAt: Date = Date(),
        enqueueCloudDeletion: Bool = true
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.enqueueCloudDeletion = enqueueCloudDeletion
    }
}

extension LibrarySummaryDeleteCommand {
    func validate() throws {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "summary delete date must be finite"
            )
        }
    }
}

/// Removes only a recording's imported-audio link while retaining the recording
/// and all metadata rows. The file operation is performed by the coordinator
/// before this metadata transaction; the repository owns the link and optional
/// durable CloudKit intent.
struct LibraryImportedAudioRemovalCommand: Equatable, Sendable {
    let id: UUID
    let requestedAt: Date
    let enqueueCloudDeletion: Bool

    init(
        id: UUID,
        requestedAt: Date = Date(),
        enqueueCloudDeletion: Bool = true
    ) {
        self.id = id
        self.requestedAt = requestedAt
        self.enqueueCloudDeletion = enqueueCloudDeletion
    }
}

extension LibraryImportedAudioRemovalCommand {
    func validate() throws {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "imported audio removal date must be finite"
            )
        }
    }
}

/// Controls which summary identity wins when a summary is written.
enum LibrarySummaryUpsertIdentityPolicy: Equatable, Sendable {
    /// Keep the existing summary row identity when the recording already has
    /// a summary. This is the normal local-generation/edit behavior.
    case preserveExisting

    /// Treat the incoming summary ID as authoritative. Cloud restore uses
    /// this when another device's summary must replace a local row while
    /// retaining the existing row's storage identity where possible.
    case incomingSummary
}

/// Creates or replaces the summary attached to one recording.
///
/// Structured task/reminder/title values are carried in their encoded form so
/// the repository boundary stays independent of the app's richer summary
/// models. The existing summary identity is preserved when the recording has
/// one unless `identityPolicy` explicitly accepts the incoming identity.
struct LibrarySummaryUpsertCommand: Equatable, Sendable {
    let id: UUID
    let recordingReference: LibraryRecordingReference
    let identityPolicy: LibrarySummaryUpsertIdentityPolicy
    let transcriptID: UUID?
    let summary: String
    let tasks: String
    let reminders: String
    let titles: String
    let contentType: String
    let aiMethod: String
    let generatedAt: Date
    let version: Int64
    let wordCount: Int64
    let originalLength: Int64
    let compressionRatio: Double
    let confidence: Double
    let processingTime: Double

    init(
        id: UUID,
        recordingReference: LibraryRecordingReference,
        identityPolicy: LibrarySummaryUpsertIdentityPolicy = .preserveExisting,
        transcriptID: UUID? = nil,
        summary: String,
        tasks: String = "[]",
        reminders: String = "[]",
        titles: String = "[]",
        contentType: String = "general",
        aiMethod: String,
        generatedAt: Date = Date(),
        version: Int64 = 1,
        wordCount: Int64,
        originalLength: Int64,
        compressionRatio: Double = 0,
        confidence: Double = 0.5,
        processingTime: Double = 0
    ) {
        self.id = id
        self.recordingReference = recordingReference
        self.identityPolicy = identityPolicy
        self.transcriptID = transcriptID
        self.summary = summary
        self.tasks = tasks
        self.reminders = reminders
        self.titles = titles
        self.contentType = contentType
        self.aiMethod = aiMethod
        self.generatedAt = generatedAt
        self.version = version
        self.wordCount = wordCount
        self.originalLength = originalLength
        self.compressionRatio = compressionRatio
        self.confidence = confidence
        self.processingTime = processingTime
    }
}

/// Creates or replaces a cloud summary together with its summary-only
/// recording anchor. The anchor intentionally has no audio URL; audio and any
/// later file restore remain separate media operations.
struct LibrarySummaryAnchorUpsertCommand: Equatable, Sendable {
    let recordingID: UUID
    let recordingName: String?
    let recordingDate: Date
    let summary: LibrarySummaryUpsertCommand

    init(
        recordingID: UUID,
        recordingName: String?,
        recordingDate: Date,
        id: UUID,
        transcriptID: UUID? = nil,
        summary: String,
        tasks: String = "[]",
        reminders: String = "[]",
        titles: String = "[]",
        contentType: String = "general",
        aiMethod: String,
        generatedAt: Date = Date(),
        version: Int64 = 1,
        wordCount: Int64,
        originalLength: Int64,
        compressionRatio: Double = 0,
        confidence: Double = 0.5,
        processingTime: Double = 0
    ) {
        self.recordingID = recordingID
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = LibrarySummaryUpsertCommand(
            id: id,
            recordingReference: LibraryRecordingReference(
                legacyID: recordingID.uuidString
            ),
            identityPolicy: .incomingSummary,
            transcriptID: transcriptID,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType,
            aiMethod: aiMethod,
            generatedAt: generatedAt,
            version: version,
            wordCount: wordCount,
            originalLength: originalLength,
            compressionRatio: compressionRatio,
            confidence: confidence,
            processingTime: processingTime
        )
    }
}

extension LibrarySummaryAnchorUpsertCommand {
    func validate() throws {
        try summary.validate()
        guard recordingDate.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "summary anchor recording date must be finite"
            )
        }
    }
}

extension LibrarySummaryUpsertCommand {
    func validate() throws {
        guard summary.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30 else {
            throw LibraryRepositoryError.invalidCommand(
                "summary must contain at least 30 non-whitespace characters"
            )
        }
        guard !tasks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reminders.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !titles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "summary structured payloads must not be empty"
            )
        }
        guard !contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "summary content type must not be empty"
            )
        }
        guard version >= 0, wordCount >= 0, originalLength >= 0 else {
            throw LibraryRepositoryError.invalidCommand(
                "summary integer metadata must be non-negative"
            )
        }
        guard compressionRatio.isFinite, compressionRatio >= 0 else {
            throw LibraryRepositoryError.invalidCommand(
                "summary compression ratio must be finite and non-negative"
            )
        }
        guard confidence.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "summary confidence must be finite"
            )
        }
        guard processingTime.isFinite, processingTime >= 0 else {
            throw LibraryRepositoryError.invalidCommand(
                "summary processing time must be finite and non-negative"
            )
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "summary generated date must be finite"
            )
        }
    }
}

/// Stable identifiers used by processing-job commands.
struct LibraryProcessingJobReference: Equatable, Sendable {
    let storageID: String?
    let legacyID: String?

    init(storageID: String? = nil, legacyID: String? = nil) {
        self.storageID = storageID
        self.legacyID = legacyID
    }

    var displayValue: String {
        storageID ?? legacyID ?? "<missing processing-job identity>"
    }
}

/// Creates one processing job without exposing a managed object or SQLite
/// row to the caller. The optional recording reference is explicit: a job may
/// be created without a relationship for legacy/external callers, but a
/// supplied reference must resolve to exactly one recording.
struct LibraryProcessingJobCreateCommand: Equatable, Sendable {
    let id: UUID
    let jobType: String
    let engine: String
    let recordingURL: String
    let recordingName: String
    let modelName: String?
    let status: String
    let progress: Double
    let startTime: Date
    let completionTime: Date?
    let error: String?
    let recordingReference: LibraryRecordingReference?
    let modifiedAt: Date

    init(
        id: UUID,
        jobType: String,
        engine: String,
        recordingURL: String,
        recordingName: String,
        modelName: String? = nil,
        status: String,
        progress: Double,
        startTime: Date,
        completionTime: Date? = nil,
        error: String? = nil,
        recordingReference: LibraryRecordingReference? = nil,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.jobType = jobType
        self.engine = engine
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.modelName = modelName
        self.status = status
        self.progress = progress
        self.startTime = startTime
        self.completionTime = completionTime
        self.error = error
        self.recordingReference = recordingReference
        self.modifiedAt = modifiedAt
    }
}

extension LibraryProcessingJobCreateCommand {
    func validate() throws {
        let requiredText: [(String, String)] = [
            (jobType, "job type"),
            (engine, "engine"),
            (recordingURL, "recording URL"),
            (recordingName, "recording name"),
            (status, "status")
        ]
        for (value, field) in requiredText {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LibraryRepositoryError.invalidCommand(
                    "processing-job \(field) must not be empty"
                )
            }
        }

        guard progress.isFinite, (0...1).contains(progress) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job progress must be finite and between 0 and 1"
            )
        }

        let dates = [
            startTime,
            completionTime,
            modifiedAt
        ]
        guard dates.compactMap({ $0 }).allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job dates must be finite"
            )
        }
    }
}

/// Describes how a processing-job error is changed by an update command.
enum LibraryProcessingJobErrorUpdate: Equatable, Sendable {
    case preserve
    case set(String?)
}

/// Describes how a processing-job completion timestamp is changed by an update
/// command. The explicit cases distinguish preserving an existing timestamp
/// from intentionally clearing one.
enum LibraryProcessingJobCompletionTimeUpdate: Equatable, Sendable {
    case preserve
    case set(Date?)
}

/// Updates the mutable state of a persisted processing job without exposing a
/// managed object or SQLite row to the caller.
struct LibraryProcessingJobUpdateCommand: Equatable, Sendable {
    let reference: LibraryProcessingJobReference
    let status: String
    let progress: Double
    let error: LibraryProcessingJobErrorUpdate
    let completionTime: LibraryProcessingJobCompletionTimeUpdate
    let expectedLastModified: Date?
    let modifiedAt: Date

    init(
        reference: LibraryProcessingJobReference,
        status: String,
        progress: Double,
        error: LibraryProcessingJobErrorUpdate = .preserve,
        completionTime: LibraryProcessingJobCompletionTimeUpdate = .preserve,
        expectedLastModified: Date? = nil,
        modifiedAt: Date = Date()
    ) {
        self.reference = reference
        self.status = status
        self.progress = progress
        self.error = error
        self.completionTime = completionTime
        self.expectedLastModified = expectedLastModified
        self.modifiedAt = modifiedAt
    }
}

/// Deletes one persisted processing job through its stable identity. The
/// optional revision guard prevents a cleanup pass from deleting a job that a
/// newer writer has already changed.
struct LibraryProcessingJobDeleteCommand: Equatable, Sendable {
    let reference: LibraryProcessingJobReference
    let expectedLastModified: Date?
    let deletedAt: Date

    init(
        reference: LibraryProcessingJobReference,
        expectedLastModified: Date? = nil,
        deletedAt: Date = Date()
    ) {
        self.reference = reference
        self.expectedLastModified = expectedLastModified
        self.deletedAt = deletedAt
    }
}

/// Deletes persisted processing jobs whose status is terminal. Status matching
/// is case-insensitive and whitespace-insensitive because legacy Core Data
/// rows use both lowercase and display-name values.
struct LibraryProcessingJobTerminalCleanupCommand: Equatable, Sendable {
    let statuses: [String]
    let deletedAt: Date

    init(
        statuses: [String] = ["completed", "failed", "cancelled"],
        deletedAt: Date = Date()
    ) {
        self.statuses = statuses
        self.deletedAt = deletedAt
    }
}

/// Marks a known set of jobs as failed after an app crash. Missing rows are
/// ignored so a retry is safe, while terminal rows are preserved if another
/// writer already completed or cancelled them.
struct LibraryProcessingJobCrashRecoveryCommand: Equatable, Sendable {
    let references: [LibraryProcessingJobReference]
    let failureMessage: String
    let modifiedAt: Date

    init(
        references: [LibraryProcessingJobReference],
        failureMessage: String,
        modifiedAt: Date = Date()
    ) {
        self.references = references
        self.failureMessage = failureMessage
        self.modifiedAt = modifiedAt
    }

    var status: String {
        "Failed"
    }
}

extension LibraryProcessingJobUpdateCommand {
    func validate() throws {
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job status must not be empty"
            )
        }
        guard progress.isFinite, (0...1).contains(progress) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job progress must be finite and between 0 and 1"
            )
        }

        let dates = [
            modifiedAt,
            expectedLastModified,
            completionDate(from: completionTime)
        ]
        guard dates.compactMap({ $0 }).allSatisfy({
            $0.timeIntervalSinceReferenceDate.isFinite
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job dates must be finite"
            )
        }
    }

    private func completionDate(
        from update: LibraryProcessingJobCompletionTimeUpdate
    ) -> Date? {
        guard case .set(let date) = update else { return nil }
        return date
    }
}

extension LibraryProcessingJobTerminalCleanupCommand {
    var normalizedStatuses: [String] {
        Array(
            Set(
                statuses.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
            )
        )
        .sorted()
    }

    func validate() throws {
        guard !statuses.isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job terminal cleanup requires at least one status"
            )
        }
        guard statuses.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job terminal cleanup statuses must not be empty"
            )
        }
        guard deletedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job terminal cleanup date must be finite"
            )
        }
    }
}

extension LibraryProcessingJobCrashRecoveryCommand {
    func validate() throws {
        guard !failureMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job crash recovery requires a failure message"
            )
        }
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LibraryRepositoryError.invalidCommand(
                "processing-job crash recovery date must be finite"
            )
        }
        for reference in references {
            let storageID = reference.storageID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyID = reference.legacyID?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard storageID?.isEmpty == false || legacyID?.isEmpty == false else {
                throw LibraryRepositoryError.invalidCommand(
                    "processing-job crash recovery references must contain an ID"
                )
            }
        }
    }
}

struct LibraryTranscriptSnapshot: Equatable, Sendable {
    let storageID: String
    let legacyID: String?
    let confidence: Double?
    let createdAt: Date?
    let engine: String?
    let lastModified: Date?
    let processingTime: Double?
    let recordingStorageID: String?
    let recordingLegacyID: String?
    let segments: String?
    let speakerMappings: String?
}

struct LibrarySummarySnapshot: Equatable, Sendable {
    let storageID: String
    let aiMethod: String?
    let compressionRatio: Double?
    let confidence: Double?
    let contentType: String?
    let generatedAt: Date?
    let legacyID: String?
    let originalLength: Int64?
    let processingTime: Double?
    let recordingStorageID: String?
    let recordingLegacyID: String?
    let reminders: String?
    let summary: String?
    let tasks: String?
    let titles: String?
    let transcriptStorageID: String?
    let transcriptLegacyID: String?
    let version: Int64?
    let wordCount: Int64?
}

struct LibraryProcessingJobSnapshot: Equatable, Sendable {
    let storageID: String
    let completionTime: Date?
    let engine: String?
    let error: String?
    let legacyID: String?
    let jobType: String?
    let lastModified: Date?
    let modelName: String?
    let progress: Double?
    let recordingName: String?
    let recordingURL: String?
    let recordingStorageID: String?
    let startTime: Date?
    let status: String?
}

struct LibraryArchiveLocationSnapshot: Equatable, Sendable {
    let storageID: String
    let bookmarkData: Data?
    let destinationURLString: String?
    let displayName: String?
    let exportedAt: Date?
    let exportedFilename: String?
    let fileSize: Int64?
    let legacyID: String?
    let lastVerifiedAt: Date?
    let providerDisplayName: String?
    let recordingLegacyID: String?
    let status: String?
}

struct LibraryPendingCloudMutationSnapshot: Equatable, Sendable {
    let storageID: String
    let kind: String?
    let payload: Data?
    let recordingLegacyID: String?
    let requestedAt: Date?
    let targetID: String?
    let version: Int64?
}

/// The storage-neutral contract used while the migration is being introduced.
/// Existing Core Data callers remain authoritative until a later checkpoint
/// wires the complete capability set into application startup.
protocol LibraryRepository: Sendable {
    func fetchRecordingSummaries() async throws -> [LibraryRecordingSnapshot]
    func fetchTranscriptSnapshots() async throws -> [LibraryTranscriptSnapshot]
    func fetchSummarySnapshots() async throws -> [LibrarySummarySnapshot]
    func fetchProcessingJobSnapshots() async throws -> [LibraryProcessingJobSnapshot]
    func fetchArchiveLocationSnapshots() async throws -> [LibraryArchiveLocationSnapshot]
    func fetchPendingCloudMutationSnapshots() async throws -> [LibraryPendingCloudMutationSnapshot]
    func createRecording(
        _ command: LibraryRecordingCreateCommand
    ) async throws -> LibraryRecordingSnapshot
    func discardRecording(
        _ command: LibraryRecordingDiscardCommand
    ) async throws
    func deleteRecording(
        _ command: LibraryRecordingDeleteCommand
    ) async throws
    func deleteRecordingPreservingSummary(
        _ command: LibraryRecordingPreserveSummaryDeleteCommand
    ) async throws
    @discardableResult
    func deleteTranscript(
        _ command: LibraryTranscriptDeleteCommand
    ) async throws -> Bool
    @discardableResult
    func deleteSummary(
        _ command: LibrarySummaryDeleteCommand
    ) async throws -> Bool
    @discardableResult
    func removeImportedAudio(
        _ command: LibraryImportedAudioRemovalCommand
    ) async throws -> Bool
    func renameRecording(_ command: LibraryRecordingRenameCommand) async throws -> LibraryRecordingSnapshot
    func updateRecordingDate(
        _ command: LibraryRecordingDateUpdateCommand
    ) async throws -> LibraryRecordingSnapshot
    func updateRecordingLocation(
        _ command: LibraryRecordingLocationUpdateCommand
    ) async throws -> LibraryRecordingSnapshot
    func setCloudSyncDisabled(
        _ command: LibraryRecordingCloudSyncCommand
    ) async throws -> LibraryRecordingSnapshot
    func setArchiveState(
        _ command: LibraryRecordingArchiveCommand
    ) async throws -> LibraryRecordingSnapshot
    func restoreRecordingAudio(
        _ command: LibraryRecordingAudioRestoreCommand
    ) async throws -> LibraryRecordingSnapshot
    func upsertArchiveLocation(
        _ command: LibraryArchiveLocationUpsertCommand
    ) async throws -> LibraryArchiveLocationSnapshot
    func upsertTranscript(
        _ command: LibraryTranscriptUpsertCommand
    ) async throws -> LibraryTranscriptSnapshot
    func upsertSummary(
        _ command: LibrarySummaryUpsertCommand
    ) async throws -> LibrarySummarySnapshot
    func upsertOrphanedSummary(
        _ command: LibrarySummaryAnchorUpsertCommand
    ) async throws -> LibrarySummarySnapshot
    func createProcessingJob(
        _ command: LibraryProcessingJobCreateCommand
    ) async throws -> LibraryProcessingJobSnapshot
    func updateProcessingJob(
        _ command: LibraryProcessingJobUpdateCommand
    ) async throws -> LibraryProcessingJobSnapshot
    func deleteProcessingJob(
        _ command: LibraryProcessingJobDeleteCommand
    ) async throws -> LibraryProcessingJobSnapshot
    func deleteTerminalProcessingJobs(
        _ command: LibraryProcessingJobTerminalCleanupCommand
    ) async throws -> [LibraryProcessingJobSnapshot]
    func recoverProcessingJobsAfterCrash(
        _ command: LibraryProcessingJobCrashRecoveryCommand
    ) async throws -> [LibraryProcessingJobSnapshot]
}

enum LibraryRepositoryError: LocalizedError, Equatable {
    case invalidRecord(entity: String, field: String)
    case invalidCommand(String)
    case recordingAlreadyExists(reference: String)
    case recordingHasDependents(reference: String)
    case recordingNotFound(reference: String)
    case recordingSummaryNotFound(reference: String)
    case ambiguousRecording(reference: String)
    case staleRecording(reference: String, expected: Date?, actual: Date?)
    case transcriptAlreadyExists(reference: String)
    case ambiguousTranscript(reference: String)
    case summaryAlreadyExists(reference: String)
    case ambiguousSummary(reference: String)
    case transcriptNotFound(reference: String)
    case archiveLocationAlreadyExists(reference: String)
    case ambiguousArchiveLocation(reference: String)
    case processingJobAlreadyExists(reference: String)
    case processingJobNotFound(reference: String)
    case ambiguousProcessingJob(reference: String)
    case staleProcessingJob(reference: String, expected: Date?, actual: Date?)
    case writeFailed(operation: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let entity, let field):
            return "The \(entity) record has an invalid \(field) value."
        case .invalidCommand(let detail):
            return "The library command is invalid: \(detail)"
        case .recordingAlreadyExists(let reference):
            return "The recording already exists: \(reference)"
        case .recordingHasDependents(let reference):
            return "The recording has dependent metadata and cannot be discarded: \(reference)"
        case .recordingNotFound(let reference):
            return "The recording could not be found: \(reference)"
        case .recordingSummaryNotFound(let reference):
            return "The recording has no summary to preserve: \(reference)"
        case .ambiguousRecording(let reference):
            return "The recording identity is ambiguous: \(reference)"
        case .staleRecording(let reference, let expected, let actual):
            return "The recording changed before it could be updated (\(reference)); "
                + "expected last modified \(String(describing: expected)), "
                + "found \(String(describing: actual))."
        case .transcriptAlreadyExists(let reference):
            return "The transcript already exists: \(reference)"
        case .ambiguousTranscript(let reference):
            return "The transcript identity is ambiguous: \(reference)"
        case .summaryAlreadyExists(let reference):
            return "The summary already exists: \(reference)"
        case .ambiguousSummary(let reference):
            return "The summary identity is ambiguous: \(reference)"
        case .transcriptNotFound(let reference):
            return "The transcript could not be found: \(reference)"
        case .archiveLocationAlreadyExists(let reference):
            return "The archive location already exists: \(reference)"
        case .ambiguousArchiveLocation(let reference):
            return "The archive location identity is ambiguous: \(reference)"
        case .processingJobAlreadyExists(let reference):
            return "The processing job already exists: \(reference)"
        case .processingJobNotFound(let reference):
            return "The processing job could not be found: \(reference)"
        case .ambiguousProcessingJob(let reference):
            return "The processing-job identity is ambiguous: \(reference)"
        case .staleProcessingJob(let reference, let expected, let actual):
            return "The processing job changed before it could be updated (\(reference)); "
                + "expected last modified \(String(describing: expected)), "
                + "found \(String(describing: actual))."
        case .writeFailed(let operation, let reason):
            return "The library could not complete \(operation): \(reason)"
        }
    }
}
