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

struct RecordingArchiveLocationInfo: Identifiable, Equatable {
    let id: UUID
    let recordingId: UUID
    let providerDisplayName: String
    let displayName: String
    let exportedFilename: String
    let destinationURLString: String?
    let exportedAt: Date?
    let fileSize: Int64
    let status: String

    var exportedAtString: String? {
        guard let exportedAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: exportedAt)
    }
}

enum RecordingArchiveError: LocalizedError {
    case noArchiveLocation
    case locationNotFound
    case unableToResolveLocation
    case sourceMissing(String)
    case copyFailed(String)
    case deleteFailed(String)
    case invalidAudio(String)

    var errorDescription: String? {
        switch self {
        case .noArchiveLocation:
            return "No archive location is saved for this recording."
        case .locationNotFound:
            return "The saved archive location could not be found."
        case .unableToResolveLocation:
            return "The saved archive location is no longer accessible."
        case .sourceMissing(let name):
            return "The archived audio file could not be found: \(name)"
        case .copyFailed(let reason):
            return "Could not download archived audio: \(reason)"
        case .deleteFailed(let reason):
            return "Downloaded audio, but could not remove the archived copy: \(reason)"
        case .invalidAudio(let reason):
            return "Downloaded file is not valid audio: \(reason)"
        }
    }
}

@MainActor
class RecordingArchiveService: ObservableObject {

    static let shared = RecordingArchiveService()

    @Published var isArchiving = false

    private static let archiveLocationEntityName = "RecordingArchiveLocationEntry"
    private static let statusAvailable = "available"
    private static let statusStaleBookmark = "staleBookmark"
    private static let statusMissing = "missing"

    private var viewContext: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    // MARK: - Archive Recordings

    /// Mark recordings as archived and optionally remove local audio files.
    /// Call this AFTER the document export picker completes successfully.
    /// New archive destinations are limited to iCloud Drive; older saved
    /// locations from previous builds can still be restored.
    @discardableResult
    func archiveRecordings(_ recordings: [RecordingEntry], removeLocal: Bool, exportedURLs: [URL] = []) -> Int {
        let context = viewContext
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateString = formatter.string(from: now)
        let savedLocations = recordArchiveLocations(for: recordings, exportedURLs: exportedURLs, exportedAt: now)
        let savedByRecordingId = Dictionary(grouping: savedLocations, by: \.recordingId)

        var archivedCount = 0
        for recording in recordings {
            guard let recordingId = recording.id,
                  let locations = savedByRecordingId[recordingId],
                  !locations.isEmpty else {
                recording.lastModified = now
                AppLog.shared.recording("Archive: not marking \(recording.recordingName ?? "unknown") archived because no destination URL was saved", level: .error)
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
            archivedCount += 1

            if removeLocal, let urlString = recording.recordingURL {
                let fileURL = Self.resolveLocalURL(from: urlString)

                if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        AppLog.shared.recording("Archived: removed local audio \(url.lastPathComponent)")
                    } catch {
                        AppLog.shared.recording("Archived: failed to remove local audio: \(error.localizedDescription)", level: .error)
                    }
                }
            }
        }

        do {
            try context.save()
            AppLog.shared.recording("Archived \(archivedCount) of \(recordings.count) recording(s), removeLocal=\(removeLocal)")
        } catch {
            AppLog.shared.recording("Failed to save archive state: \(error.localizedDescription)", level: .error)
        }

        return archivedCount
    }

    // MARK: - Query

    /// Fetch non-archived recordings older than a given number of days.
    func recordingsOlderThan(days: Int) -> [RecordingEntry] {
        let ctx = viewContext
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let request: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "recordingDate < %@", cutoff as NSDate),
            NSPredicate(format: "isArchived == NO OR isArchived == nil"),
            NSPredicate(format: "recordingURL != nil")
        ])
        request.sortDescriptors = [NSSortDescriptor(key: "recordingDate", ascending: true)]

        do {
            return try ctx.fetch(request)
        } catch {
            AppLog.shared.recording("Failed to query recordings older than \(days) days: \(error.localizedDescription)", level: .error)
            return []
        }
    }

    // MARK: - Restore

    /// Clear archive flags when a user re-imports audio for an archived recording.
    func restoreRecording(_ recording: RecordingEntry, newAudioURL: URL) {
        let context = viewContext

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let relativePath: String
        if let docs = documentsPath, newAudioURL.path.hasPrefix(docs.path) {
            relativePath = String(newAudioURL.path.dropFirst(docs.path.count + 1))
        } else {
            relativePath = newAudioURL.lastPathComponent
        }

        recording.recordingURL = relativePath
        recording.isArchived = false
        recording.archivedAt = nil
        recording.archiveNote = nil
        recording.lastModified = Date()

        // Update file size from restored file
        if let attrs = try? FileManager.default.attributesOfItem(atPath: newAudioURL.path),
           let size = attrs[.size] as? Int64 {
            recording.fileSize = size
        }

        do {
            try context.save()
            AppLog.shared.recording("Restored archived recording: \(recording.recordingName ?? "unknown")")
        } catch {
            AppLog.shared.recording("Failed to restore recording: \(error.localizedDescription)", level: .error)
        }
    }

    /// Clear archive flags on a recording whose local audio is already present.
    /// Used when the user archived without removing local audio, then re-imports
    /// the exported copy — no file copy needed, just flip the flags.
    func clearArchiveFlags(for recording: RecordingEntry) {
        let context = viewContext
        recording.isArchived = false
        recording.archivedAt = nil
        recording.archiveNote = nil
        recording.lastModified = Date()

        do {
            try context.save()
            AppLog.shared.recording("Cleared archive flags (local audio intact): \(recording.recordingName ?? "unknown")")
        } catch {
            AppLog.shared.recording("Failed to clear archive flags: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Archive Locations

    func archiveLocations(for recordingId: UUID?) -> [RecordingArchiveLocationInfo] {
        guard let recordingId else { return [] }

        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "exportedAt", ascending: false)]

        do {
            return try viewContext.fetch(request).compactMap(Self.locationInfo(from:))
        } catch {
            AppLog.shared.recording("Archive: failed to fetch archive locations: \(error.localizedDescription)", level: .error)
            return []
        }
    }

    func primaryArchiveLocation(for recordingId: UUID?) -> RecordingArchiveLocationInfo? {
        archiveLocations(for: recordingId).first
    }

    @discardableResult
    func restoreArchivedRecording(_ recording: RecordingEntry, from locationId: UUID? = nil) throws -> URL {
        let locationObject: NSManagedObject
        if let locationId {
            guard let fetched = archiveLocationObject(id: locationId) else {
                throw RecordingArchiveError.locationNotFound
            }
            locationObject = fetched
        } else {
            guard let recordingId = recording.id,
                  let first = archiveLocationObject(forRecordingId: recordingId) else {
                throw RecordingArchiveError.noArchiveLocation
            }
            locationObject = first
        }

        let sourceURL = try resolvedArchiveURL(from: locationObject)
        let sourceName = sourceURL.lastPathComponent
        let startedAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if startedAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            locationObject.setValue(Self.statusMissing, forKey: "status")
            locationObject.setValue(Date(), forKey: "lastVerifiedAt")
            try? viewContext.save()
            throw RecordingArchiveError.sourceMissing(sourceName)
        }

        let destinationURL = try localRestoreDestination(for: recording, sourceURL: sourceURL)
        var coordinatorError: NSError?
        var operationError: Error?
        var didCopy = false
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedURL in
            do {
                try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
                didCopy = true
            } catch {
                operationError = error
            }
        }

        if let operationError {
            throw RecordingArchiveError.copyFailed(operationError.localizedDescription)
        }
        if let coordinatorError {
            throw RecordingArchiveError.copyFailed(coordinatorError.localizedDescription)
        }
        guard didCopy else {
            throw RecordingArchiveError.copyFailed("The file provider did not return a readable file.")
        }

        do {
            try validateAudioFile(at: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        do {
            try deleteArchivedSource(at: sourceURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }

        restoreRecording(recording, newAudioURL: destinationURL)
        viewContext.delete(locationObject)
        try viewContext.save()
        return destinationURL
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

    private func recordArchiveLocations(for recordings: [RecordingEntry], exportedURLs: [URL], exportedAt: Date) -> [RecordingArchiveLocationInfo] {
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

            let existingObject = archiveLocationObject(recordingId: recordingId, destinationURL: url)
            let locationObject = existingObject
                ?? NSEntityDescription.insertNewObject(forEntityName: Self.archiveLocationEntityName, into: viewContext)

            locationObject.setValue((locationObject.value(forKey: "id") as? UUID) ?? UUID(), forKey: "id")
            locationObject.setValue(recordingId, forKey: "recordingId")
            locationObject.setValue(Self.providerDisplayName(for: url), forKey: "providerDisplayName")
            locationObject.setValue(Self.displayName(for: url), forKey: "displayName")
            locationObject.setValue(url.lastPathComponent, forKey: "exportedFilename")
            locationObject.setValue(url.absoluteString, forKey: "destinationURLString")
            locationObject.setValue(exportedAt, forKey: "exportedAt")
            locationObject.setValue(exportedAt, forKey: "lastVerifiedAt")
            locationObject.setValue(Self.statusAvailable, forKey: "status")

            let bookmarkData = try? url.bookmarkData(
                options: [.minimalBookmark],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            if bookmarkData == nil && !FileManager.default.fileExists(atPath: url.path) {
                if existingObject == nil {
                    viewContext.delete(locationObject)
                }
                AppLog.shared.recording("Archive: skipped untrackable destination URL \(url.lastPathComponent)", level: .error)
                continue
            }
            locationObject.setValue(bookmarkData, forKey: "bookmarkData")

            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64)
                ?? recording.fileSize
            locationObject.setValue(size, forKey: "fileSize")

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

    private func archiveLocationObject(forRecordingId recordingId: UUID) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(key: "exportedAt", ascending: false)]
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }

    private func archiveLocationObject(id: UUID) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }

    private func archiveLocationObject(recordingId: UUID, destinationURL: URL) -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.archiveLocationEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "recordingId == %@", recordingId as CVarArg),
            NSPredicate(format: "destinationURLString == %@", destinationURL.absoluteString)
        ])
        request.fetchLimit = 1
        return try? viewContext.fetch(request).first
    }

    private func resolvedArchiveURL(from locationObject: NSManagedObject) throws -> URL {
        if let bookmarkData = locationObject.value(forKey: "bookmarkData") as? Data {
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    locationObject.setValue(Self.statusStaleBookmark, forKey: "status")
                    locationObject.setValue(Date(), forKey: "lastVerifiedAt")
                    try? viewContext.save()
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
            return audioURLs(for: recordings)
        }
        // Clear any leftovers from a prior crashed run before staging.
        try? FileManager.default.removeItem(at: stagingDir)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            AppLog.shared.recording("Archive: failed to create staging dir: \(error.localizedDescription)", level: .error)
            return audioURLs(for: recordings)
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
    static func resolveLocalURL(from urlString: String) -> URL? {
        if urlString.hasPrefix("/") {
            return URL(fileURLWithPath: urlString)
        }
        if let parsed = URL(string: urlString), parsed.scheme != nil {
            return parsed.isFileURL ? parsed : nil
        }
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let decoded = urlString.removingPercentEncoding ?? urlString
        return docs.appendingPathComponent(decoded)
    }

    /// Calculate total file size for a set of recordings.
    func totalFileSize(for recordings: [RecordingEntry]) -> Int64 {
        let urls = audioURLs(for: recordings)
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            return total + size
        }
    }
}
