//
//  RecordingArchiveService.swift
//  BisonNotes AI
//
//  Service for archiving audio recordings to external storage.
//  Manages export, local file cleanup, and restore from re-import.
//

import Foundation
import CoreData

@MainActor
class RecordingArchiveService: ObservableObject {

    static let shared = RecordingArchiveService()

    @Published var isArchiving = false

    private var viewContext: NSManagedObjectContext {
        PersistenceController.shared.container.viewContext
    }

    // MARK: - Archive Recordings

    /// Mark recordings as archived and optionally remove local audio files.
    /// Call this AFTER the document export picker completes successfully.
    func archiveRecordings(_ recordings: [RecordingEntry], removeLocal: Bool) {
        let context = viewContext
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let dateString = formatter.string(from: now)

        for recording in recordings {
            recording.isArchived = true
            recording.archivedAt = now
            recording.archiveNote = "Exported to Files on \(dateString)"
            recording.lastModified = now

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
            AppLog.shared.recording("Archived \(recordings.count) recording(s), removeLocal=\(removeLocal)")
        } catch {
            AppLog.shared.recording("Failed to save archive state: \(error.localizedDescription)", level: .error)
        }
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
