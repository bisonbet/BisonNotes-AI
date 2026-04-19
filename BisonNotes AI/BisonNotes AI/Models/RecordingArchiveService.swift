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
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                let fileURL: URL?

                if urlString.hasPrefix("/") {
                    fileURL = URL(fileURLWithPath: urlString)
                } else if let docs = documentsPath {
                    fileURL = docs.appendingPathComponent(urlString)
                } else {
                    fileURL = nil
                }

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

    // MARK: - Helpers

    /// Get absolute file URLs for recordings that still have local audio files.
    func audioURLs(for recordings: [RecordingEntry]) -> [URL] {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return recordings.compactMap { recording -> URL? in
            guard let urlString = recording.recordingURL else { return nil }
            let url: URL
            if urlString.hasPrefix("/") {
                url = URL(fileURLWithPath: urlString)
            } else if let docs = documentsPath {
                url = docs.appendingPathComponent(urlString)
            } else {
                return nil
            }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
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
