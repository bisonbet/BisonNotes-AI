//
//  RecordingArchiveService.swift
//  BisonNotes AI
//
//  Service for archiving audio recordings to iCloud Drive.
//  Manages export, local file cleanup, and restore from re-import.
//

import Foundation
import CoreData
import AVFoundation

@MainActor
class RecordingArchiveService: ObservableObject {

    static let shared = RecordingArchiveService()

    @Published var isArchiving = false

    private static let archiveLocationEntityName = "RecordingArchiveLocationEntry"
    private static let statusAvailable = "available"
    private static let statusStaleBookmark = "staleBookmark"
    private static let statusMissing = "missing"
    /// A restore succeeded but its external source outlived the cleanup.
    static let statusCleanupPending = "cleanupPending"

    private lazy var coreDataManager = CoreDataManager(persistenceController: PersistenceController.shared)
    private let mediaRecoveryStore: MediaOperationRecoveryStore?

    init(mediaRecoveryStore: MediaOperationRecoveryStore? = nil) {
        self.mediaRecoveryStore = mediaRecoveryStore ?? MediaOperationRecoveryStore.live()
    }

    private var viewContext: NSManagedObjectContext {
        coreDataManager.managedObjectContext
    }

    // MARK: - Archive Recordings

    /// Mark recordings as archived and optionally remove local audio files.
    /// Call this AFTER the document export picker completes successfully.
    /// New archive destinations are limited to iCloud Drive; older saved
    /// locations from previous builds can still be restored.
    @discardableResult
    func archiveRecordings(_ recordings: [RecordingEntry], removeLocal: Bool, exportedURLs: [URL] = []) throws -> Int {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateString = formatter.string(from: now)
        var archivedCount = 0

        let recordingObjectIDs = recordings.map(\.objectID).filter { !$0.isTemporaryID }
        var archivedRecordingIDs = Set<UUID>()
        try coreDataManager.performIsolatedMutation(operation: "archive recordings") { isolatedContext in
            let isolatedRecordings = try recordingObjectIDs.compactMap {
                try isolatedContext.existingObject(with: $0) as? RecordingEntry
            }
            let savedLocations = try recordArchiveLocations(
                for: isolatedRecordings,
                exportedURLs: exportedURLs,
                exportedAt: now,
                in: isolatedContext
            )
            let savedByRecordingId = Dictionary(grouping: savedLocations, by: \.recordingId)

            for recording in isolatedRecordings {
                guard let recordingId = recording.id,
                      let locations = savedByRecordingId[recordingId],
                      !locations.isEmpty else {
                    AppLog.shared.recording(
                        "Archive: not marking \(recording.recordingName ?? "unknown") archived because no destination URL was saved",
                        level: .error
                    )
                    continue
                }

                recording.isArchived = true
                recording.archivedAt = now
                let firstLocation = locations[0]
                let locationCount = locations.count
                if locationCount > 1 {
                    recording.archiveNote = "Exported to \(locationCount) locations on \(dateString)"
                } else {
                    recording.archiveNote = "Exported to \(firstLocation.providerDisplayName) on \(dateString)"
                }
                recording.lastModified = now
                archivedRecordingIDs.insert(recordingId)
                archivedCount += 1
            }
        }

        // The archive metadata and location rows are the durable commitment.
        // Only after that save succeeds may the owned local source be removed.
        guard removeLocal else {
            AppLog.shared.recording("Archived \(archivedCount) of \(recordings.count) recording(s), removeLocal=false")
            return archivedCount
        }

        var localRemovalFailures: [String] = []
        for recording in recordings {
            guard let recordingId = recording.id,
                  archivedRecordingIDs.contains(recordingId) else {
                continue
            }
            guard let urlString = recording.recordingURL,
                  let url = Self.resolveLocalURL(from: urlString),
                  FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                AppLog.shared.recording("Archived: removed local audio \(url.lastPathComponent)")
            } catch {
                // Continue to the remaining recordings, as the sidecar cleanup
                // below already does. Every selected row was marked archived
                // before this loop, so throwing here left each later recording
                // archived with its local audio still present — and the caller
                // clears the archive selection rather than retaining a retry, so
                // that offload could not be resumed without exporting again. The
                // failures are still reported once the loop has done all the work
                // it can.
                AppLog.shared.recording(
                    "Archived metadata committed, but local audio removal failed for "
                        + "\(url.lastPathComponent): \(error.localizedDescription)",
                    level: .error
                )
                localRemovalFailures.append(url.lastPathComponent)
                continue
            }
            // Sidecars are cleanup only; failure to remove one must not erase
            // the durable archive state or the recoverable archive destination.
            for ext in ["location", "recordingmeta"] {
                let sidecarURL = url.deletingPathExtension().appendingPathExtension(ext)
                do {
                    try FileManager.default.removeItem(at: sidecarURL)
                } catch where !FileManager.default.fileExists(atPath: sidecarURL.path) {
                    // It disappeared concurrently; the cleanup is complete.
                } catch {
                    AppLog.shared.recording(
                        "Archived metadata committed, but sidecar cleanup failed: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
        }

        AppLog.shared.recording("Archived \(archivedCount) of \(recordings.count) recording(s), removeLocal=true")

        // Report once, after every recording that could be cleaned up has been.
        // The archive metadata is committed either way, so this tells the caller
        // which local sources survived rather than hiding it behind the first
        // failure.
        guard localRemovalFailures.isEmpty else {
            throw RecordingArchiveError.deleteFailed(
                "Archived \(archivedCount) recording(s), but local audio could not be removed for "
                    + "\(localRemovalFailures.count): \(localRemovalFailures.joined(separator: ", "))"
            )
        }
        return archivedCount
    }

    // MARK: - Query

    /// Fetch non-archived recordings older than a given number of days.
    func recordingsOlderThan(days: Int) throws -> [RecordingEntry] {
        try fetchRecordingsOlderThan(days: days)
    }

    /// Throwing lookup for archive actions. A failed fetch must not authorize
    /// the caller to continue with an empty archive selection.
    func fetchRecordingsOlderThan(days: Int) throws -> [RecordingEntry] {
        let ctx = viewContext
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let request: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "recordingDate < %@", cutoff as NSDate),
            NSPredicate(format: "isArchived == NO OR isArchived == nil"),
            NSPredicate(format: "recordingURL != nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "recordingDate", ascending: true)]

        return try ctx.fetch(request)
    }

    // MARK: - Restore

    /// Clear archive flags when a user re-imports audio for an archived recording.
    func restoreRecording(_ recording: RecordingEntry, newAudioURL: URL) throws {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let relativePath: String
        if let docs = documentsPath, newAudioURL.path.hasPrefix(docs.path) {
            relativePath = String(newAudioURL.path.dropFirst(docs.path.count + 1))
        } else {
            relativePath = newAudioURL.lastPathComponent
        }

        // Update file size from restored file
        let fileSize: Int64?
        do {
            fileSize = try FileManager.default.attributesOfItem(atPath: newAudioURL.path)[.size] as? Int64
        } catch {
            fileSize = nil
        }
        let recordingObjectID = recording.objectID
        try coreDataManager.performIsolatedMutation(operation: "archive recording restore") { isolatedContext in
            guard let isolatedRecording = try isolatedContext.existingObject(with: recordingObjectID) as? RecordingEntry else {
                throw RecordingArchiveError.locationNotFound
            }
            isolatedRecording.recordingURL = relativePath
            isolatedRecording.isArchived = false
            isolatedRecording.archivedAt = nil
            isolatedRecording.archiveNote = nil
            isolatedRecording.lastModified = Date()
            if let fileSize {
                isolatedRecording.fileSize = fileSize
            }
        }
        AppLog.shared.recording("Restored archived recording: \(recording.recordingName ?? "unknown")")
    }

    /// Clear archive flags on a recording whose local audio is already present.
    /// Used when the user archived without removing local audio, then re-imports
    /// the exported copy — no file copy needed, just flip the flags.
    func clearArchiveFlags(for recording: RecordingEntry) throws {
        let recordingObjectID = recording.objectID
        try coreDataManager.performIsolatedMutation(operation: "archive flags update") { isolatedContext in
            guard let isolatedRecording = try isolatedContext.existingObject(with: recordingObjectID) as? RecordingEntry else {
                throw RecordingArchiveError.locationNotFound
            }
            isolatedRecording.isArchived = false
            isolatedRecording.archivedAt = nil
            isolatedRecording.archiveNote = nil
            isolatedRecording.lastModified = Date()
        }
        AppLog.shared.recording("Cleared archive flags (local audio intact): \(recording.recordingName ?? "unknown")")
    }

    // MARK: - Archive Locations

    func archiveLocations(for recordingId: UUID?) throws -> [RecordingArchiveLocationInfo] {
        guard let recordingId else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "exportedAt", ascending: false)]

        return try viewContext.fetch(request).compactMap(Self.locationInfo(from:))
    }

    func primaryArchiveLocation(for recordingId: UUID?) throws -> RecordingArchiveLocationInfo? {
        try archiveLocations(for: recordingId).first
    }

    @discardableResult
    private func restoreLocation(for recording: RecordingEntry, locationId: UUID?) throws -> NSManagedObject {
        let locationObject: NSManagedObject
        if let locationId {
            guard let fetched = try archiveLocationObject(id: locationId, in: viewContext) else {
                throw RecordingArchiveError.locationNotFound
            }
            locationObject = fetched
        } else {
            guard let recordingId = recording.id,
                  let first = try archiveLocationObject(forRecordingId: recordingId, in: viewContext) else {
                throw RecordingArchiveError.noArchiveLocation
            }
            locationObject = first
        }

        return locationObject
    }

    /// The result of restoring an archived recording.
    ///
    /// Carries a third outcome beside success and failure: restored, but the
    /// external archived copy outlived the cleanup. The recording is healthy in
    /// that case, so it is not an error — but the copy sits in the user's own
    /// archive location and only they can retire it, which means they have to be
    /// told it is still there.
    struct RecordingArchiveRestoreOutcome {
        let restoredURL: URL
        let retainedArchiveSource: String?
    }

    @discardableResult
    func restoreArchivedRecording(
        _ recording: RecordingEntry,
        from locationId: UUID? = nil
    ) throws -> RecordingArchiveRestoreOutcome {
        var retainedArchiveSource: String?
        let locationObject = try restoreLocation(for: recording, locationId: locationId)

        let sourceURL = try resolvedArchiveURL(from: locationObject)
        let sourceName = sourceURL.lastPathComponent
        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            let locationObjectID = locationObject.objectID
            do {
                try coreDataManager.performIsolatedMutation(operation: "archive location status update") { isolatedContext in
                    let isolatedLocation = try isolatedContext.existingObject(with: locationObjectID)
                    isolatedLocation.setValue(Self.statusMissing, forKey: "status")
                    isolatedLocation.setValue(Date(), forKey: "lastVerifiedAt")
                }
            } catch {
                AppLog.shared.recording(
                    "Could not persist missing archive-location status: \(error.localizedDescription)",
                    level: .error
                )
            }
            throw RecordingArchiveError.sourceMissing(sourceName)
        }

        let destinationURL = try localRestoreDestination(for: recording, sourceURL: sourceURL)
        guard let mediaRecoveryStore else {
            throw RecordingArchiveError.copyFailed("Media recovery storage is unavailable.")
        }

        // Identify the source so a restore interrupted after publication can be
        // matched again. Without a size and fingerprint on the receipt, nothing
        // could resume it: localRestoreDestination(for:sourceURL:) hands back the
        // recording's original URL only while that file is absent, so a retry
        // found the published copy already there, fell through to a fresh unique
        // name, and published a second copy — while reconciliation could not
        // commit the first because the recording still pointed at its old URL.
        let sourceIdentity = try mediaRecoveryStore.artifactIdentity(for: sourceURL)

        if let pending = try mediaRecoveryStore.pendingOperation(
            kind: .archiveRestore,
            sourceName: sourceName,
            sourceFileSize: sourceIdentity.fileSize,
            sourceFingerprint: sourceIdentity.fingerprint,
            recordingID: recording.id
        ) {
            let resumed = try resumePendingArchiveRestore(
                pending,
                recording: recording,
                sourceURL: sourceURL,
                locationObject: locationObject,
                mediaRecoveryStore: mediaRecoveryStore
            )
            AppLog.shared.recording(
                "Resumed an interrupted archive restore for \(recording.recordingName ?? "unknown")"
            )
            return resumed
        }

        var operation: MediaOperation?
        do {
            operation = try mediaRecoveryStore.begin(
                kind: .archiveRestore,
                sourceName: sourceName,
                destinationURL: destinationURL,
                fileExtension: sourceURL.pathExtension,
                recordingID: recording.id,
                sourceFileSize: sourceIdentity.fileSize,
                sourceFingerprint: sourceIdentity.fingerprint
            )
            guard let prepared = operation else {
                throw MediaOperationRecoveryError.unavailable
            }

            try copyArchiveSource(sourceURL, to: prepared.stagingURL)

            operation = try mediaRecoveryStore.markStaged(prepared)
            guard let staged = operation else {
                throw MediaOperationRecoveryError.missingStagingArtifact
            }
            try validateAudioFile(at: staged.stagingURL)
            operation = try mediaRecoveryStore.publish(staged)
            guard let published = operation else {
                throw MediaOperationRecoveryError.unavailable
            }
            operation = try mediaRecoveryStore.markMetadataPending(published)

            // Commit the local metadata before removing the external source. The
            // downloaded copy remains recoverable if either later cleanup step
            // fails.
            try restoreRecording(recording, newAudioURL: destinationURL)
            if let committed = operation {
                operation = try mediaRecoveryStore.markMetadataCommitted(
                    committed,
                    recordingID: recording.id
                )
            }

            retainedArchiveSource = retireArchiveSource(
                at: sourceURL,
                locationObject: locationObject,
                operation: operation,
                mediaRecoveryStore: mediaRecoveryStore
            )
        } catch {
            if let operation,
               FileManager.default.fileExists(atPath: operation.publishedURL.path) {
                AppLog.shared.recording(
                    "Archive restore retained published audio after failure: \(error.localizedDescription)",
                    level: .error
                )
            } else if let operation {
                do {
                    try mediaRecoveryStore.abortBeforePublish(operation)
                } catch {
                    AppLog.shared.recording(
                        "Could not remove failed archive restore staging: \(error.localizedDescription)",
                        level: .error
                    )
                }
            }
            if let archiveError = error as? RecordingArchiveError {
                throw archiveError
            }
            if error is MediaOperationRecoveryError {
                throw RecordingArchiveError.copyFailed(error.localizedDescription)
            }
            throw error
        }
        return RecordingArchiveRestoreOutcome(
            restoredURL: destinationURL,
            retainedArchiveSource: retainedArchiveSource
        )
    }

    /// Finishes an archive restore whose publication already succeeded. The
    /// published file is app-owned, so this re-points the recording at it and
    /// completes the source/location cleanup rather than publishing a second copy.
    private func resumePendingArchiveRestore(
        _ pending: MediaOperation,
        recording: RecordingEntry,
        sourceURL: URL,
        locationObject: NSManagedObject,
        mediaRecoveryStore: MediaOperationRecoveryStore
    ) throws -> RecordingArchiveRestoreOutcome {
        var operation = pending
        let wasMetadataCommitted = operation.receipt.phase == .metadataCommitted
        if operation.receipt.phase == .staged,
           !FileManager.default.fileExists(atPath: operation.publishedURL.path) {
            try validateAudioFile(at: operation.stagingURL)
            operation = try mediaRecoveryStore.publish(operation)
        }
        try validateAudioFile(at: operation.publishedURL)
        operation = try mediaRecoveryStore.markMetadataPending(operation, recordingID: recording.id)

        let alreadyReferenced = Self.resolveLocalURL(from: recording.recordingURL ?? "")?
            .standardizedFileURL.path == operation.publishedURL.standardizedFileURL.path
        if !alreadyReferenced {
            guard !wasMetadataCommitted else {
                throw RecordingArchiveError.copyFailed(
                    "A committed archive-restore receipt has no matching recording reference."
                )
            }
            try restoreRecording(recording, newAudioURL: operation.publishedURL)
        }
        operation = try mediaRecoveryStore.markMetadataCommitted(operation, recordingID: recording.id)

        let retained = retireArchiveSource(
            at: sourceURL,
            locationObject: locationObject,
            operation: operation,
            mediaRecoveryStore: mediaRecoveryStore
        )
        return RecordingArchiveRestoreOutcome(
            restoredURL: operation.publishedURL,
            retainedArchiveSource: retained
        )
    }

    /// Retires the external archived copy and its bookkeeping once a restore has
    /// committed. Returns a description of the copy when it could not be
    /// removed.
    ///
    /// Best-effort by design. The recording is already back with its audio, so
    /// failing the restore over bookkeeping would report a healthy result as
    /// broken — and the restore action is not offered again once the recording
    /// is unarchived. The leftover is the user's own file in the archive
    /// location they chose, so naming it is what lets them finish the job; there
    /// is nothing here for the app to reclaim on their behalf.
    private func retireArchiveSource(
        at sourceURL: URL,
        locationObject: NSManagedObject,
        operation: MediaOperation?,
        mediaRecoveryStore: MediaOperationRecoveryStore
    ) -> String? {
        do {
            try deleteArchivedSource(at: sourceURL)
            let locationObjectID = locationObject.objectID
            try coreDataManager.performIsolatedMutation(operation: "archive location removal") { isolatedContext in
                let isolatedLocation = try isolatedContext.existingObject(with: locationObjectID)
                isolatedContext.delete(isolatedLocation)
            }
            if let operation {
                try mediaRecoveryStore.finish(operation)
            }
            return nil
        } catch {
            markArchiveLocationCleanupPending(locationObject, reason: error)
            return "\(Self.displayName(for: sourceURL)) in \(Self.providerDisplayName(for: sourceURL))"
        }
    }

    /// Records that a restore completed but its external source could not be
    /// retired. The recording itself is healthy; this marks the bookkeeping that
    /// still needs attention so it is visible rather than an archive row that
    /// claims to be available.
    private func markArchiveLocationCleanupPending(_ locationObject: NSManagedObject, reason: Error) {
        AppLog.shared.recording(
            "Archive restore completed, but the external source was not retired: "
                + "\(reason.localizedDescription)",
            level: .fault
        )
        let locationObjectID = locationObject.objectID
        do {
            try coreDataManager.performIsolatedMutation(operation: "archive location cleanup status") { isolatedContext in
                let isolatedLocation = try isolatedContext.existingObject(with: locationObjectID)
                isolatedLocation.setValue(Self.statusCleanupPending, forKey: "status")
                isolatedLocation.setValue(Date(), forKey: "lastVerifiedAt")
            }
        } catch {
            AppLog.shared.recording(
                "Could not mark the archive location for cleanup: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    private func deleteArchivedSource(at sourceURL: URL) throws {
        var coordinatorError: NSError?
        var operationError: Error?
        var didDelete = false
        let coordinator = NSFileCoordinator(filePresenter: nil)

        coordinator.coordinate(writingItemAt: sourceURL, options: .forDeleting, error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.removeItem(at: coordinatedURL)
                didDelete = true
            } catch {
                operationError = error
            }
        }

        if let operationError {
            throw RecordingArchiveError.deleteFailed(operationError.localizedDescription)
        }
        if let coordinatorError {
            throw RecordingArchiveError.deleteFailed(coordinatorError.localizedDescription)
        }
        if !didDelete && FileManager.default.fileExists(atPath: sourceURL.path) {
            throw RecordingArchiveError.deleteFailed("The file provider did not confirm deletion.")
        }
    }

    private func recordArchiveLocations(
        for recordings: [RecordingEntry],
        exportedURLs: [URL],
        exportedAt: Date,
        in context: NSManagedObjectContext
    ) throws -> [RecordingArchiveLocationInfo] {
        guard !exportedURLs.isEmpty else { return [] }

        let exportCandidates = expandedExportedURLs(for: recordings, exportedURLs: exportedURLs)
        let recordingsByToken: [String: RecordingEntry] = Dictionary(
            uniqueKeysWithValues: recordings.compactMap { recording in
                guard let token = Self.archiveToken(for: recording) else { return nil }
                return (token, recording)
            }
        )

        var saved: [RecordingArchiveLocationInfo] = []
        for url in exportCandidates {
            guard let parsed = Self.parseArchiveToken(fromFilename: url.lastPathComponent),
                  let recording = recordingsByToken[parsed.token],
                  let recordingId = recording.id else {
                AppLog.shared.recording("Archive: exported URL did not match a staged recording: \(url.lastPathComponent)", level: .debug)
                continue
            }

            let startedAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if startedAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard Self.isSupportedArchiveDestination(url) else {
                AppLog.shared.recording("Archive: rejected non-iCloud destination \(url.path)", level: .error)
                continue
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RecordingArchiveError.copyFailed(
                    "The selected archive destination did not produce \(url.lastPathComponent)."
                )
            }
            let exportedSize: Int64
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = attributes[.size] as? Int64, size > 0 else {
                    throw RecordingArchiveError.copyFailed("The exported archive file is empty.")
                }
                exportedSize = size
            } catch let error as RecordingArchiveError {
                throw error
            } catch {
                throw RecordingArchiveError.copyFailed(
                    "Could not verify the exported archive file: \(error.localizedDescription)"
                )
            }
            try validateAudioFile(at: url)

            let existingObject = try archiveLocationObject(
                recordingId: recordingId,
                destinationURL: url,
                in: context
            )
            let locationObject = existingObject
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.archiveLocationEntityName, into: context)

            locationObject.setValue((locationObject.value(forKey: "id") as? UUID) ?? UUID(), forKey: "id")
            locationObject.setValue(recordingId, forKey: "recordingId")
            locationObject.setValue(Self.providerDisplayName(for: url), forKey: "providerDisplayName")
            locationObject.setValue(Self.displayName(for: url), forKey: "displayName")
            locationObject.setValue(url.lastPathComponent, forKey: "exportedFilename")
            locationObject.setValue(url.absoluteString, forKey: "destinationURLString")
            locationObject.setValue(exportedAt, forKey: "exportedAt")
            locationObject.setValue(exportedAt, forKey: "lastVerifiedAt")
            locationObject.setValue(Self.statusAvailable, forKey: "status")

            // Persist a security-scoped bookmark so sandbox access survives
            // app launches. Native macOS requires the
            // explicit option; on iOS the picker-granted scope is retained.
            let bookmarkOptions: URL.BookmarkCreationOptions = {
                #if os(macOS)
                return [.withSecurityScope]
                #else
                return []
                #endif
            }()
            let bookmarkData = try? url.bookmarkData(
                options: bookmarkOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            if bookmarkData == nil && !FileManager.default.fileExists(atPath: url.path) {
                if existingObject == nil {
                    context.delete(locationObject)
                }
                AppLog.shared.recording("Archive: skipped untrackable destination URL \(url.lastPathComponent)", level: .error)
                continue
            }
            locationObject.setValue(bookmarkData, forKey: "bookmarkData")

            locationObject.setValue(exportedSize, forKey: "fileSize")

            if let info = Self.locationInfo(from: locationObject) {
                saved.append(info)
            }
        }

        return saved
    }

    private func expandedExportedURLs(for recordings: [RecordingEntry], exportedURLs: [URL]) -> [URL] {
        let directlyMatched = exportedURLs.filter { Self.parseArchiveToken(fromFilename: $0.lastPathComponent) != nil }
        if !directlyMatched.isEmpty {
            return directlyMatched
        }

        // Some providers return the selected destination folder for multi-file
        // exports instead of one URL per file. In that case, reconstruct the
        // expected exported file URLs from the staged filenames.
        guard exportedURLs.count == 1,
              let destinationFolder = exportedURLs.first else {
            return exportedURLs
        }

        let expectedFilenames = expectedStagedFilenames(for: recordings)
        guard !expectedFilenames.isEmpty else {
            return exportedURLs
        }

        return expectedFilenames.map { destinationFolder.appendingPathComponent($0) }
    }

    private func expectedStagedFilenames(for recordings: [RecordingEntry]) -> [String] {
        var usedNames = Set<String>()
        return recordings.compactMap { recording in
            guard let urlString = recording.recordingURL,
                  let sourceURL = Self.resolveLocalURL(from: urlString),
                  FileManager.default.fileExists(atPath: sourceURL.path) else {
                return nil
            }
            return Self.uniqueStagedFilename(for: recording, source: sourceURL, claimed: &usedNames)
        }
    }

    private func archiveLocationObject(
        forRecordingId recordingId: UUID,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "exportedAt", ascending: false)]
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func archiveLocationObject(id: UUID, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func archiveLocationObject(
        recordingId: UUID,
        destinationURL: URL,
        in context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "recordingId == %@", recordingId as CVarArg),
            NSPredicate(format: "destinationURLString == %@", destinationURL.absoluteString)
        ])
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func resolvedArchiveURL(from locationObject: NSManagedObject) throws -> URL {
        if let bookmarkData = locationObject.value(forKey: "bookmarkData") as? Data {
            var isStale = false
            // Mac builds store security-scoped bookmarks; resolution must pass
            // the matching option so access can be restored after relaunch.
            let resolutionOptions: URL.BookmarkResolutionOptions = {
                #if os(macOS)
                return [.withoutUI, .withSecurityScope]
                #else
                return [.withoutUI]
                #endif
            }()
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: resolutionOptions,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    // URL resolution is a read. Do not mutate the shared
                    // context or silently save a stale-bookmark marker while
                    // deciding whether a restore may proceed.
                    AppLog.shared.recording(
                        "Archive: resolved a stale bookmark; restore will continue with the verified URL",
                        level: .error
                    )
                }
                return url
            } catch {
                AppLog.shared.recording("Archive: failed to resolve bookmark: \(error.localizedDescription)", level: .error)
            }
        }

        if let urlString = locationObject.value(forKey: "destinationURLString") as? String,
           let url = URL(string: urlString) {
            return url
        }

        throw RecordingArchiveError.unableToResolveLocation
    }

    private func localRestoreDestination(for recording: RecordingEntry, sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default

        if let urlString = recording.recordingURL,
           let originalURL = Self.resolveLocalURL(from: urlString),
           !fileManager.fileExists(atPath: originalURL.path) {
            try fileManager.createDirectory(
                at: originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return originalURL
        }

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw RecordingArchiveError.copyFailed("Documents directory is unavailable.")
        }

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let base = sourceURL.deletingPathExtension().lastPathComponent
        var candidate = documentsURL.appendingPathComponent("\(base).\(ext)")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = documentsURL.appendingPathComponent("\(base)_\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func validateAudioFile(at url: URL) throws {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            if player.duration <= 0 {
                throw RecordingArchiveError.invalidAudio("File has no audio content.")
            }
        } catch let archiveError as RecordingArchiveError {
            throw archiveError
        } catch {
            throw RecordingArchiveError.invalidAudio(error.localizedDescription)
        }
    }

    private static func locationInfo(from object: NSManagedObject) -> RecordingArchiveLocationInfo? {
        guard let id = object.value(forKey: "id") as? UUID,
              let recordingId = object.value(forKey: "recordingId") as? UUID else {
            return nil
        }

        return RecordingArchiveLocationInfo(
            id: id,
            recordingId: recordingId,
            providerDisplayName: object.value(forKey: "providerDisplayName") as? String ?? "External Storage",
            displayName: object.value(forKey: "displayName") as? String ?? object.value(forKey: "exportedFilename") as? String ?? "Archived audio",
            exportedFilename: object.value(forKey: "exportedFilename") as? String ?? "",
            destinationURLString: object.value(forKey: "destinationURLString") as? String,
            exportedAt: object.value(forKey: "exportedAt") as? Date,
            fileSize: object.value(forKey: "fileSize") as? Int64 ?? 0,
            status: object.value(forKey: "status") as? String ?? Self.statusAvailable
        )
    }

    private static func providerDisplayName(for url: URL) -> String {
        if isSupportedArchiveDestination(url) {
            return "iCloud Drive"
        }
        let path = url.path.lowercased()
        if path.contains("dropbox") {
            return "Dropbox"
        }
        if path.contains("google drive") || path.contains("googledrive") {
            return "Google Drive"
        }
        if path.contains("proton drive") || path.contains("protondrive") {
            return "Proton Drive"
        }
        return "External Storage"
    }

    private static func isSupportedArchiveDestination(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }

        let searchableURLText = [
            url.path,
            url.absoluteString,
            url.deletingLastPathComponent().path
        ]
        .joined(separator: " ")
        .lowercased()

        return searchableURLText.contains("mobile documents") ||
            searchableURLText.contains("icloud")
    }

    private static func displayName(for url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : parent
    }

    // MARK: - Export Staging

    /// Stage audio files for a plain user export. Unlike archive staging, these
    /// filenames do not include restore tokens because exporting should not
    /// change archive state or create an import/restore marker.
    func prepareAudioExportURLs(for recordings: [RecordingFile]) -> [URL] {
        guard let stagingDir = Self.audioExportStagingDirectory else {
            AppLog.shared.recording("Audio export: no Library dir available for staging", level: .error)
            // Never fall back to live recording URLs: they feed .fileMover, which moves
            // the file out of the app and orphans its Core Data entry. Fail the export.
            return []
        }

        try? FileManager.default.removeItem(at: stagingDir)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            AppLog.shared.recording("Audio export: failed to create staging dir: \(error.localizedDescription)", level: .error)
            // See above: staging failure must not expose live recording files to the mover.
            return []
        }

        var stagedURLs: [URL] = []
        var usedNames = Set<String>()
        for recording in recordings {
            guard let stagedURL = stageAudioExport(
                sourceURL: recording.url,
                title: recording.name,
                recordingDate: recording.date,
                stagingDir: stagingDir,
                claimed: &usedNames
            ) else { continue }
            stagedURLs.append(stagedURL)
        }

        return stagedURLs
    }

    func prepareAudioExportURL(sourceURL: URL, title: String, recordingDate: Date?) -> URL? {
        guard let stagingDir = Self.audioExportStagingDirectory else {
            AppLog.shared.recording("Audio export: no Library dir available for staging", level: .error)
            return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
        }

        try? FileManager.default.removeItem(at: stagingDir)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            AppLog.shared.recording("Audio export: failed to create staging dir: \(error.localizedDescription)", level: .error)
            return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
        }

        var usedNames = Set<String>()
        return stageAudioExport(
            sourceURL: sourceURL,
            title: title,
            recordingDate: recordingDate,
            stagingDir: stagingDir,
            claimed: &usedNames
        )
    }

    func cleanupAudioExportStaging() {
        guard let dir = Self.audioExportStagingDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    private func stageAudioExport(sourceURL: URL,
                                  title: String,
                                  recordingDate: Date?,
                                  stagingDir: URL,
                                  claimed: inout Set<String>) -> URL? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        let stagedName = Self.uniqueAudioExportFilename(title: title, source: sourceURL, claimed: &claimed)
        let destURL = stagingDir.appendingPathComponent(stagedName)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            if let recordingDate {
                try? FileManager.default.setAttributes(
                    [.modificationDate: recordingDate],
                    ofItemAtPath: destURL.path
                )
            }
            return destURL
        } catch {
            AppLog.shared.recording("Audio export: failed to stage \(sourceURL.lastPathComponent): \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    /// Stage audio files for export with recognizable filenames of the form
    /// `<SanitizedRecordingName>-<TOKEN>.<ext>`, where TOKEN is the first 8 hex
    /// characters of the recording's UUID. Re-imports use this token to match
    /// the original recording and restore instead of creating a duplicate.
    ///
    /// Copies into a subdirectory of Library/Application Support, then stamps
    /// the staged file's modification date with the original recording date so
    /// timestamps survive an iCloud round-trip.
    func prepareArchiveExportURLs(for recordings: [RecordingEntry]) -> [URL] {
        guard let stagingDir = Self.archiveStagingDirectory else {
            AppLog.shared.recording("Archive: no Library dir available for staging", level: .error)
            // Never fall back to live recording URLs: they feed .fileMover, which moves
            // the file out of the app and orphans its Core Data entry. Fail the export.
            return []
        }
        // Clear any leftovers from a prior crashed run before staging.
        try? FileManager.default.removeItem(at: stagingDir)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            AppLog.shared.recording("Archive: failed to create staging dir: \(error.localizedDescription)", level: .error)
            // See above: staging failure must not expose live recording files to the mover.
            return []
        }

        var stagedURLs: [URL] = []
        var usedNames = Set<String>()
        for recording in recordings {
            guard let urlString = recording.recordingURL,
                  let sourceURL = Self.resolveLocalURL(from: urlString),
                  FileManager.default.fileExists(atPath: sourceURL.path) else { continue }

            let stagedName = Self.uniqueStagedFilename(for: recording, source: sourceURL, claimed: &usedNames)
            let destURL = stagingDir.appendingPathComponent(stagedName)
            // Copy (not hardlink): the iCloud Drive File Provider extension reads
            // the file via XPC from this sandbox location, and hardlinks share
            // xattrs with the Documents source — which can cause "permission
            // denied" surfacing in the picker. A fresh copy has clean attributes.
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch {
                AppLog.shared.recording("Archive: failed to stage \(sourceURL.lastPathComponent): \(error.localizedDescription)", level: .error)
                continue
            }

            // Stamp the staged copy's modification date with the original recording
            // date so it survives an iCloud round-trip (iCloud preserves mtime but
            // resets creation time to upload time). On fallback-path imports we
            // read mtime to restore the recording's original timestamp.
            if let recordingDate = recording.recordingDate {
                try? FileManager.default.setAttributes(
                    [.modificationDate: recordingDate],
                    ofItemAtPath: destURL.path
                )
            }

            stagedURLs.append(destURL)
        }
        return stagedURLs
    }

    /// Remove the archive staging directory. Safe to call even if nothing was staged.
    func cleanupArchiveStaging() {
        guard let dir = Self.archiveStagingDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Directory used to stage exported files with renamed, tokenized filenames.
    /// Lives under `Library/Application Support` so it is outside Documents (not
    /// surfaced in the Files app) while still readable by export providers via XPC.
    static var archiveStagingDirectory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("ArchiveStaging", isDirectory: true)
    }

    static var audioExportStagingDirectory: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return support.appendingPathComponent("AudioExportStaging", isDirectory: true)
    }

    /// First 8 hex chars of the recording's UUID, lowercased. Returns nil if the
    /// recording has no id (should not happen for persisted entries).
    static func archiveToken(for recording: RecordingEntry) -> String? {
        guard let uuid = recording.id?.uuidString else { return nil }
        let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
        return hex.count >= 8 ? String(hex.prefix(8)) : nil
    }

    /// Build a filesystem-safe base name from the recording's display name.
    /// Falls back through the stored URL's filename and finally a literal "recording".
    static func sanitizedFilenameBase(for recording: RecordingEntry) -> String {
        if let name = recording.recordingName {
            let sanitized = sanitizeForFilename(name)
            if !sanitized.isEmpty { return sanitized }
        }
        if let urlString = recording.recordingURL,
           let url = resolveLocalURL(from: urlString) {
            let base = url.deletingPathExtension().lastPathComponent
            let sanitized = sanitizeForFilename(base)
            if !sanitized.isEmpty { return sanitized }
        }
        return "recording"
    }

    /// Strip filesystem-reserved characters, collapse whitespace, and truncate so
    /// the final `<base>-<TOKEN>.<ext>` comfortably fits under APFS's 255-byte
    /// filename ceiling.
    private static func sanitizeForFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let stripped = raw.components(separatedBy: invalid).joined(separator: "_")
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return String(trimmed.prefix(200))
    }

    /// Build a unique staged filename for a recording, accounting for an unlikely
    /// duplicate base name within the same batch.
    private static func uniqueStagedFilename(for recording: RecordingEntry,
                                             source: URL,
                                             claimed: inout Set<String>) -> String {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let base = sanitizedFilenameBase(for: recording)
        let token = archiveToken(for: recording) ?? "00000000"
        var candidate = "\(base)-\(token).\(ext)"
        var counter = 2
        while claimed.contains(candidate) {
            candidate = "\(base)-\(token)_\(counter).\(ext)"
            counter += 1
        }
        claimed.insert(candidate)
        return candidate
    }

    private static func uniqueAudioExportFilename(title: String,
                                                  source: URL,
                                                  claimed: inout Set<String>) -> String {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let sanitizedTitle = sanitizeForFilename(title)
        let base = sanitizedTitle.isEmpty ? "recording" : sanitizedTitle
        var candidate = "\(base).\(ext)"
        var counter = 2
        while claimed.contains(candidate) {
            candidate = "\(base) \(counter).\(ext)"
            counter += 1
        }
        claimed.insert(candidate)
        return candidate
    }

    /// Parse an imported filename for a trailing `-<8hex>.<ext>` archive token.
    /// Returns (token, baseName) when present. Name and token are lowercased for
    /// stable comparison against `recording.id.uuidString`.
    static func parseArchiveToken(fromFilename filename: String) -> (token: String, baseName: String)? {
        let name = (filename as NSString).deletingPathExtension
        guard name.count > 9 else { return nil }
        let tokenStart = name.index(name.endIndex, offsetBy: -8)
        let delimiterIndex = name.index(before: tokenStart)
        guard name[delimiterIndex] == "-" else { return nil }
        let tokenSubstring = name[tokenStart...]
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard tokenSubstring.unicodeScalars.allSatisfy(hexChars.contains) else { return nil }
        let baseName = String(name[..<delimiterIndex])
        guard !baseName.isEmpty else { return nil }
        return (token: String(tokenSubstring).lowercased(), baseName: baseName)
    }

    // MARK: - Helpers

    /// Get absolute file URLs for recordings that still have local audio files.
    func audioURLs(for recordings: [RecordingEntry]) -> [URL] {
        return recordings.compactMap { recording -> URL? in
            guard let urlString = recording.recordingURL,
                  let url = Self.resolveLocalURL(from: urlString) else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Resolve a stored recordingURL string to a local file URL.
    /// Handles absolute POSIX paths, file:// URLs (legacy format), and
    /// Documents-relative paths with percent-encoding (e.g. "My%20Recording.m4a").


    /// Calculate total file size for a set of recordings.

}
