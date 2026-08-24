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

/// Core Data manager that provides clean access to recordings, transcripts, and summaries
/// Replaces the legacy registry system with proper Core Data operations
@MainActor
class CoreDataManager: ObservableObject {
    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext

    #if DEBUG
    var contextForTesting: NSManagedObjectContext {
        context
    }
    #endif

    /// The context that backs this manager. Restore and deletion coordination must use
    /// the coordinator's context rather than the process-wide shared persistence store.
    var managedObjectContext: NSManagedObjectContext {
        context
    }

    init(persistenceController: PersistenceController? = nil) {
        let resolvedPersistenceController = persistenceController ?? PersistenceController.shared
        self.persistenceController = resolvedPersistenceController
        self.context = resolvedPersistenceController.container.viewContext
    }

    // MARK: - Context Management

    /// Refreshes all objects in the Core Data context to ensure fresh data
    func refreshContext() {
        context.refreshAllObjects()
    }

    // MARK: - Recording Operations

    func getAllRecordings() -> [RecordingEntry] {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \RecordingEntry.recordingDate, ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            AppLog.shared.coreData("Error fetching recordings: \(error)", level: .error)
            return []
        }
    }

    // MARK: - URL Management Helpers

    /// Migrates all existing absolute URL paths to relative paths for resilience
    func migrateURLsToRelativePaths() {
        let allRecordings = getAllRecordings()
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

        // Decode URL-encoded characters (like %20 for spaces)
        let decodedPath = relativePath.removingPercentEncoding ?? relativePath

        // If it's just a filename, append directly to documents
        if !decodedPath.contains("/") {
            return documentsURL.appendingPathComponent(decodedPath)
        }

        // If it's a relative path, construct the full URL using appendingPathComponent
        // This is more reliable than URL(string:relativeTo:) for file paths
        return documentsURL.appendingPathComponent(decodedPath)
    }

    /// Gets the current absolute URL for a recording, handling container ID changes
    func getAbsoluteURL(for recording: RecordingEntry) -> URL? {
        guard let urlString = recording.recordingURL else {
            // Don't log anything - orphaned records are cleaned up at app startup
            return nil
        }

        // First, try to parse as absolute URL (legacy format)
        if let url = URL(string: urlString), url.scheme != nil {
            // This is an absolute URL, check if file exists
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }

            // File doesn't exist at absolute path, try to find by filename
            if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let filename = url.lastPathComponent
                let newURL = documentsURL.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: newURL.path) {
                    // Update the stored URL to relative path for future resilience
                    recording.recordingURL = urlToRelativePath(newURL)
                    try? context.save()
                    return newURL
                }
            }
        } else {
            // This is a relative path, convert to absolute URL
            if let absoluteURL = relativePathToURL(urlString) {
                if FileManager.default.fileExists(atPath: absoluteURL.path) {
                    return absoluteURL
                }

                AppLog.shared.coreData("File not found at relative path, trying filename search", level: .debug)
                // File doesn't exist, try to find by filename
                if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let filename = absoluteURL.lastPathComponent
                    let newURL = documentsURL.appendingPathComponent(filename)
                    AppLog.shared.coreData("Searching for file: \(newURL.lastPathComponent)", level: .debug)
                    if FileManager.default.fileExists(atPath: newURL.path) {
                        AppLog.shared.coreData("File found by filename, updating stored path")
                        // Update the stored relative path
                        recording.recordingURL = urlToRelativePath(newURL)
                        try? context.save()
                        return newURL
                    }
                }
            } else {
                AppLog.shared.coreData("Failed to convert relative path to absolute URL", level: .error)
            }
        }

        AppLog.shared.coreData("File not found anywhere for recording ID: \(recording.id?.uuidString ?? "nil")", level: .debug)
        return nil
    }

    /// Returns a URL derived from the stored recordingURL string without checking file existence.
    /// Used for archived recordings where the local file may have been intentionally removed.
    func getStoredURL(for recording: RecordingEntry) -> URL? {
        guard let urlString = recording.recordingURL else { return nil }

        if let url = URL(string: urlString), url.scheme != nil {
            return url
        }
        return relativePathToURL(urlString)
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
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            AppLog.shared.coreData("Error fetching recording: \(error)", level: .error)
            return nil
        }
    }

    func getRecording(url: URL) -> RecordingEntry? {
        let filename = url.lastPathComponent
        let normalizedTargetPath = normalizedURLPath(url)

        if let exactMatch = getAllRecordings().first(where: { recording in
            guard let recordingURL = getAbsoluteURL(for: recording) else {
                return false
            }
            return normalizedURLPath(recordingURL) == normalizedTargetPath
        }) {
            return exactMatch
        }

        // If no match found, try legacy URL matching for migration cases
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingURL ENDSWITH %@", filename)

        do {
            let results = try context.fetch(fetchRequest)
            if let recording = results.first {
                // Update to relative path format
                recording.recordingURL = urlToRelativePath(url)
                try? context.save()
                return recording
            }
        } catch {
            AppLog.shared.coreData("Error fetching recording by URL: \(error)", level: .error)
        }

        return nil
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
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        // Sort by lastModified to get the most recent transcript
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.lastModified, ascending: false)]

        do {
            let results = try context.fetch(fetchRequest)
            return results.first
        } catch {
            AppLog.shared.coreData("Error fetching transcript: \(error)", level: .error)
            return nil
        }
    }

    func getTranscript(id: UUID) -> TranscriptEntry? {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            AppLog.shared.coreData("Error fetching transcript \(id): \(error)", level: .error)
            return nil
        }
    }

    func getTranscriptData(for recordingId: UUID) -> TranscriptData? {
        guard let transcriptEntry = getTranscript(for: recordingId),
              let recordingEntry = getRecording(id: recordingId) else {
            return nil
        }

        return convertToTranscriptData(transcriptEntry: transcriptEntry, recordingEntry: recordingEntry)
    }

    func getAllTranscripts() -> [TranscriptEntry] {
        let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.createdAt, ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            AppLog.shared.coreData("Error fetching transcripts: \(error)", level: .error)
            return []
        }
    }

    private func enqueueTranscriptCloudDeletion(_ transcript: TranscriptEntry) {
        guard let transcriptId = transcript.id else { return }
        SummaryManager.shared.getiCloudManager().enqueueTranscriptRemovalFromiCloud(
            transcriptId: transcriptId,
            recordingId: transcript.recordingId ?? transcript.recording?.id
        )
    }

    private func enqueueSummaryCloudDeletion(_ summary: SummaryEntry) {
        guard let summaryId = summary.id else { return }
        enqueueSummaryCloudDeletion(
            summaryId: summaryId,
            recordingId: summary.recordingId ?? summary.recording?.id
        )
    }

    private func enqueueSummaryCloudDeletion(summaryId: UUID, recordingId: UUID?) {
        SummaryManager.shared.getiCloudManager().enqueueSummaryRemovalFromiCloud(
            summaryId: summaryId,
            recordingId: recordingId
        )
    }

    private func enqueueRecordingCloudDeletion(_ recording: RecordingEntry) {
        guard let recordingId = recording.id else { return }
        SummaryManager.shared.getiCloudManager().enqueueRecordingDeletionForiCloud(
            recordingId: recordingId,
            transcriptIds: [recording.transcriptId ?? recording.transcript?.id].compactMap { $0 },
            summaryIds: [recording.summaryId ?? recording.summary?.id].compactMap { $0 }
        )
    }

    func deleteTranscript(id: UUID?) throws {
        guard let id else { return }

        do {
            let fetchRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            let transcripts = try context.fetch(fetchRequest)
            guard !transcripts.isEmpty else {
                AppLog.shared.coreData("No transcript found with ID: \(id)", level: .debug)
                return
            }

            let recordingIds = Set(transcripts.compactMap { $0.recordingId ?? $0.recording?.id })
            let recordings = getAllRecordings().filter { recording in
                recording.transcriptId == id ||
                    recording.id.map { recordingIds.contains($0) } == true ||
                    transcripts.contains { $0.recording === recording }
            }
            for recording in recordings {
                recording.transcript = nil
                recording.transcriptId = nil
                recording.transcriptionStatus = ProcessingStatus.notStarted.rawValue
                recording.lastModified = Date()
            }

            let summaryEntries = getAllSummaries().filter { summary in
                summary.transcriptId == id || summary.transcript?.id == id
            }
            for summary in summaryEntries {
                summary.transcript = nil
                summary.transcriptId = nil
            }

            // Capture before deleting, and enqueue only after the save lands:
            // a rollback below would otherwise leave a queued cloud removal for a
            // transcript that still exists locally, and the next sync would delete
            // the cloud copy and then reconcile the local row away.
            let cloudDeletions = transcripts.compactMap { transcript -> (transcriptId: UUID, recordingId: UUID?)? in
                guard let transcriptId = transcript.id else { return nil }
                return (
                    transcriptId: transcriptId,
                    recordingId: transcript.recordingId ?? transcript.recording?.id
                )
            }

            transcripts.forEach { context.delete($0) }
            try saveContext()

            for deletion in cloudDeletions {
                SummaryManager.shared.getiCloudManager().enqueueTranscriptRemovalFromiCloud(
                    transcriptId: deletion.transcriptId,
                    recordingId: deletion.recordingId
                )
            }
            AppLog.shared.coreData("Deleted transcript with ID: \(id)")
        } catch {
            context.rollback()
            AppLog.shared.coreData("Error deleting transcript: \(error)", level: .error)
            throw error
        }
    }

    // MARK: - Repair Operations

    /// Repairs orphaned summaries by creating missing recording entries
    func repairOrphanedSummaries() -> Int {
        let allSummaries = getAllSummaries()
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

                // Verify the repair worked
                let newRecordingCount = getAllRecordings().count
                let newSummaryCount = getAllSummaries().count
                AppLog.shared.coreData("After repair: \(newRecordingCount) recordings, \(newSummaryCount) summaries", level: .debug)
            } catch {
                AppLog.shared.coreData("Failed to save repaired summaries: \(error)", level: .error)
                return 0
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
    ) -> (transcripts: Int, summaries: Int) {
        guard !transcriptIds.isEmpty || !summaryIds.isEmpty else { return (0, 0) }

        var transcriptsDeleted = 0
        var summariesDeleted = 0

        for transcriptId in transcriptIds {
            guard let transcript = getTranscript(id: transcriptId) else { continue }
            guard isUnreferencedDuplicate(transcript) else { continue }
            context.delete(transcript)
            transcriptsDeleted += 1
        }

        for summaryId in summaryIds {
            guard let summary = getSummary(id: summaryId) else { continue }
            guard isUnreferencedDuplicate(summary) else { continue }
            try? SummaryAttachmentStore.shared.deleteAll(for: summaryId)
            context.delete(summary)
            summariesDeleted += 1
        }

        guard transcriptsDeleted > 0 || summariesDeleted > 0 else { return (0, 0) }

        do {
            try saveContext()
            AppLog.shared.coreData(
                "Removed \(transcriptsDeleted) superseded transcript row(s) and \(summariesDeleted) superseded summary row(s)"
            )
        } catch {
            AppLog.shared.coreData("Failed to remove superseded duplicates: \(error)", level: .error)
            context.rollback()
            return (0, 0)
        }

        return (transcriptsDeleted, summariesDeleted)
    }

    private func isUnreferencedDuplicate(_ transcript: TranscriptEntry) -> Bool {
        guard let transcriptId = transcript.id else { return false }
        guard let recording = transcript.recording
            ?? transcript.recordingId.flatMap({ getRecording(id: $0) }) else {
            // An orphaned row has no recording to supersede it; leave it to cleanupDuplicates.
            return false
        }
        return recording.transcriptId != transcriptId && recording.transcript?.id != transcriptId
    }

    private func isUnreferencedDuplicate(_ summary: SummaryEntry) -> Bool {
        guard let summaryId = summary.id else { return false }
        guard let recording = summary.recording
            ?? (summary.recordingId ?? summary.recording?.id).flatMap({ getRecording(id: $0) }) else {
            return false
        }
        return recording.summaryId != summaryId && recording.summary?.id != summaryId
    }

    func cleanupDuplicates() -> (summaries: Int, transcripts: Int) {
        var summariesDeleted = 0
        var transcriptsDeleted = 0

        // Every side effect that outlives a rollback is deferred until the save
        // succeeds. Attachment files especially: deleting them first and then
        // rolling back returns the summary row pointing at notes the user can no
        // longer open, and nothing can put them back.
        var pendingSummaryDeletions: [(summaryId: UUID, recordingId: UUID?)] = []
        var pendingTranscriptDeletions: [(transcriptId: UUID, recordingId: UUID?)] = []

        func stageSummaryDeletion(_ summary: SummaryEntry) {
            guard let summaryId = summary.id else { return }
            pendingSummaryDeletions.append((summaryId, summary.recordingId ?? summary.recording?.id))
        }

        func stageTranscriptDeletion(_ transcript: TranscriptEntry) {
            guard let transcriptId = transcript.id else { return }
            pendingTranscriptDeletions.append((transcriptId, transcript.recordingId ?? transcript.recording?.id))
        }

        AppLog.shared.coreData("Starting duplicate cleanup...")

        // Get all recordings
        let recordings = getAllRecordings()
        AppLog.shared.coreData("Checking \(recordings.count) recordings for duplicates", level: .debug)

        for recording in recordings {
            guard let recordingId = recording.id else { continue }

            // Check for duplicate summaries
            let summaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
            summaryFetch.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
            summaryFetch.sortDescriptors = [NSSortDescriptor(keyPath: \SummaryEntry.generatedAt, ascending: false)]

            if let summaries = try? context.fetch(summaryFetch), summaries.count > 1 {
                AppLog.shared.coreData("Found \(summaries.count) summaries for recording ID: \(recordingId)", level: .debug)
                // Keep the first (most recent), delete the rest
                for (index, summary) in summaries.enumerated() {
                    if index > 0 {
                        let summaryLength = summary.summary?.count ?? 0
                        AppLog.shared.coreData("Deleting duplicate summary ID: \(summary.id?.uuidString ?? "nil") (length: \(summaryLength) chars)", level: .debug)
                        stageSummaryDeletion(summary)
                        context.delete(summary)
                        summariesDeleted += 1
                    } else {
                        let summaryLength = summary.summary?.count ?? 0
                        AppLog.shared.coreData("Keeping most recent summary ID: \(summary.id?.uuidString ?? "nil") (length: \(summaryLength) chars)", level: .debug)
                    }
                }
            }

            // Check for duplicate transcripts
            let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
            transcriptFetch.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
            transcriptFetch.sortDescriptors = [NSSortDescriptor(keyPath: \TranscriptEntry.createdAt, ascending: false)]

            if let transcripts = try? context.fetch(transcriptFetch), transcripts.count > 1 {
                AppLog.shared.coreData("Found \(transcripts.count) transcripts for recording ID: \(recordingId)", level: .debug)
                // Keep the first (most recent), delete the rest
                for (index, transcript) in transcripts.enumerated() {
                    if index > 0 {
                        let segmentsLength = transcript.segments?.count ?? 0
                        AppLog.shared.coreData("Deleting duplicate transcript ID: \(transcript.id?.uuidString ?? "nil") (segments: \(segmentsLength) chars)", level: .debug)
                        stageTranscriptDeletion(transcript)
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
        let orphanSummaryFetch: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        if let allSummaries = try? context.fetch(orphanSummaryFetch) {
            let recordingIds = Set(recordings.compactMap { $0.id })
            for summary in allSummaries {
                if let summaryRecordingId = summary.recordingId, !recordingIds.contains(summaryRecordingId) {
                    AppLog.shared.coreData("Deleting orphaned summary (no recording): ID \(summary.id?.uuidString ?? "nil")", level: .debug)
                    stageSummaryDeletion(summary)
                    context.delete(summary)
                    summariesDeleted += 1
                }
            }
        }

        // Also check for orphaned transcripts (no matching recording)
        let orphanTranscriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        if let allTranscripts = try? context.fetch(orphanTranscriptFetch) {
            let recordingIds = Set(recordings.compactMap { $0.id })
            for transcript in allTranscripts {
                if let transcriptRecordingId = transcript.recordingId, !recordingIds.contains(transcriptRecordingId) {
                    AppLog.shared.coreData("Deleting orphaned transcript (no recording): ID \(transcript.id?.uuidString ?? "nil")", level: .debug)
                    stageTranscriptDeletion(transcript)
                    context.delete(transcript)
                    transcriptsDeleted += 1
                }
            }
        }

        if summariesDeleted > 0 || transcriptsDeleted > 0 {
            do {
                try saveContext()
                AppLog.shared.coreData("Cleanup complete: deleted \(summariesDeleted) duplicate/orphaned summaries, \(transcriptsDeleted) duplicate/orphaned transcripts")
            } catch {
                AppLog.shared.coreData("Failed to save cleanup changes: \(error)", level: .error)
                context.rollback()
                // Nothing staged has run yet, so the rolled-back rows keep their
                // attachments and no tombstone was published.
                return (0, 0)
            }

            let iCloudManager = SummaryManager.shared.getiCloudManager()
            for deletion in pendingSummaryDeletions {
                iCloudManager.enqueueSummaryRemovalFromiCloud(
                    summaryId: deletion.summaryId,
                    recordingId: deletion.recordingId
                )
                try? SummaryAttachmentStore.shared.deleteAll(for: deletion.summaryId)
            }
            for deletion in pendingTranscriptDeletions {
                iCloudManager.enqueueTranscriptRemovalFromiCloud(
                    transcriptId: deletion.transcriptId,
                    recordingId: deletion.recordingId
                )
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
    func upsertSummary(
        _ summary: EnhancedSummaryData,
        for recordingId: UUID,
        transcriptId: UUID? = nil,
        identityPolicy: SummaryUpsertIdentityPolicy = .preserveExisting
    ) throws -> UUID {
        guard let recordingEntry = getRecording(id: recordingId) else {
            throw SummaryUpsertError.recordingNotFound(recordingId)
        }

        if let embeddedRecordingId = summary.recordingId, embeddedRecordingId != recordingId {
            throw SummaryUpsertError.summaryIDBelongsToAnotherRecording(summary.id)
        }

        let summaryByIDRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        summaryByIDRequest.predicate = NSPredicate(format: "id == %@", summary.id as CVarArg)
        let summaryByID = try context.fetch(summaryByIDRequest).first
        if let summaryByID,
           let existingRecordingId = summaryByID.recordingId ?? summaryByID.recording?.id,
           existingRecordingId != recordingId {
            throw SummaryUpsertError.summaryIDBelongsToAnotherRecording(summary.id)
        }

        let summariesForRecordingRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        summariesForRecordingRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        summariesForRecordingRequest.sortDescriptors = [NSSortDescriptor(key: "generatedAt", ascending: false)]
        let summariesForRecording = try context.fetch(summariesForRecordingRequest)
        let summaryEntry: SummaryEntry
        let previousSummaryId: UUID?
        switch identityPolicy {
        case .preserveExisting:
            summaryEntry = summaryByID ?? summariesForRecording.first ?? SummaryEntry(context: context)
            previousSummaryId = nil
        case .incomingSummary:
            if let summaryByID {
                summaryEntry = summaryByID
                previousSummaryId = nil
            } else if let existingSummary = summariesForRecording.first {
                summaryEntry = existingSummary
                previousSummaryId = existingSummary.id
            } else {
                summaryEntry = SummaryEntry(context: context)
                previousSummaryId = nil
            }
        }

        let summaryId: UUID
        switch identityPolicy {
        case .preserveExisting:
            summaryId = summaryEntry.id ?? summary.id
        case .incomingSummary:
            summaryId = summary.id
        }
        summaryEntry.id = summaryId

        guard let tasksData = try? JSONEncoder().encode(summary.tasks),
              let tasksString = String(data: tasksData, encoding: .utf8),
              let remindersData = try? JSONEncoder().encode(summary.reminders),
              let remindersString = String(data: remindersData, encoding: .utf8),
              let titlesData = try? JSONEncoder().encode(summary.titles),
              let titlesString = String(data: titlesData, encoding: .utf8) else {
            throw SummaryUpsertError.encodingFailed
        }

        summaryEntry.recordingId = recordingId
        summaryEntry.summary = summary.summary
        summaryEntry.tasks = tasksString
        summaryEntry.reminders = remindersString
        summaryEntry.titles = titlesString
        summaryEntry.contentType = summary.contentType.rawValue
        summaryEntry.aiMethod = SummaryMetadataCodec.encode(aiEngine: summary.aiEngine, aiModel: summary.aiModel)
        summaryEntry.generatedAt = summary.generatedAt
        summaryEntry.version = Int32(summary.version)
        summaryEntry.wordCount = Int32(summary.wordCount)
        summaryEntry.originalLength = Int32(summary.originalLength)
        summaryEntry.compressionRatio = summary.compressionRatio
        summaryEntry.confidence = summary.confidence
        summaryEntry.processingTime = summary.processingTime
        summaryEntry.recording = recordingEntry
        recordingEntry.summary = summaryEntry
        recordingEntry.summaryId = summaryId
        recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
        recordingEntry.lastModified = summary.generatedAt

        try linkTranscript(to: summaryEntry, id: transcriptId ?? summary.transcriptId, policy: identityPolicy)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        // Keep one authoritative summary per recording after the save succeeds.
        let duplicateSummaries = summariesForRecording.filter { $0.objectID != summaryEntry.objectID }
        if !duplicateSummaries.isEmpty {
            duplicateSummaries.forEach { summary in
                if let summaryId = summary.id {
                    try? SummaryAttachmentStore.shared.deleteAll(for: summaryId)
                }
                enqueueSummaryCloudDeletion(summary)
                context.delete(summary)
            }
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
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

    private func linkTranscript(
        to summaryEntry: SummaryEntry,
        id transcriptId: UUID?,
        policy identityPolicy: SummaryUpsertIdentityPolicy
    ) throws {
        guard let transcriptId else {
            if identityPolicy == .incomingSummary {
                summaryEntry.transcriptId = nil
                summaryEntry.transcript = nil
            }
            return
        }

        let transcriptRequest: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
        transcriptRequest.predicate = NSPredicate(format: "id == %@", transcriptId as CVarArg)
        let transcript = try context.fetch(transcriptRequest).first
        if transcript != nil || identityPolicy == .incomingSummary {
            summaryEntry.transcriptId = transcriptId
            summaryEntry.transcript = transcript
        }
    }

    /// Persists a cloud summary that has no matching local recording by creating a stable
    /// summary-only recording anchor. Repeated restores return the existing summary instead
    /// of creating another anchor.
    @discardableResult
    func upsertOrphanedSummary(_ summary: EnhancedSummaryData) throws -> UUID {
        if let existingSummary = getSummary(id: summary.id) {
            guard let recordingEntry = existingSummary.recording,
                  let recordingId = recordingEntry.id else {
                throw SummaryUpsertError.recordingIdentityUnavailable
            }

            recordingEntry.recordingName = summary.recordingName
            recordingEntry.recordingDate = summary.recordingDate
            recordingEntry.lastModified = summary.generatedAt
            return try upsertSummary(
                summary,
                for: recordingId,
                transcriptId: summary.transcriptId,
                identityPolicy: .incomingSummary
            )
        }

        let tasksData = try JSONEncoder().encode(summary.tasks)
        let remindersData = try JSONEncoder().encode(summary.reminders)
        let titlesData = try JSONEncoder().encode(summary.titles)
        guard let tasks = String(data: tasksData, encoding: .utf8),
              let reminders = String(data: remindersData, encoding: .utf8),
              let titles = String(data: titlesData, encoding: .utf8) else {
            throw SummaryUpsertError.encodingFailed
        }

        let recordingEntry = RecordingEntry(context: context)
        recordingEntry.id = summary.recordingId ?? UUID()
        recordingEntry.recordingName = summary.recordingName
        recordingEntry.recordingDate = summary.recordingDate
        recordingEntry.recordingURL = nil
        recordingEntry.duration = 0
        recordingEntry.fileSize = 0
        recordingEntry.summaryId = summary.id
        recordingEntry.summaryStatus = ProcessingStatus.completed.rawValue
        recordingEntry.lastModified = summary.generatedAt

        let summaryEntry = SummaryEntry(context: context)
        summaryEntry.id = summary.id
        summaryEntry.recordingId = recordingEntry.id
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

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }

        return summary.id
    }

    func getSummary(for recordingId: UUID) -> SummaryEntry? {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
        // Sort by generatedAt descending to get the most recent summary
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \SummaryEntry.generatedAt, ascending: false)]

        do {
            let summaries = try context.fetch(fetchRequest)
            if summaries.count > 1 {
                AppLog.shared.coreData("Found \(summaries.count) summaries for recording \(recordingId) — auto-cleaning duplicates", level: .debug)
                // Keep the most recent (index 0), delete the rest immediately
                for summary in summaries.dropFirst() {
                    AppLog.shared.coreData("Auto-deleting duplicate summary ID=\(summary.id?.uuidString ?? "nil"), length=\(summary.summary?.count ?? 0)", level: .debug)
                    if let summaryId = summary.id {
                        try? SummaryAttachmentStore.shared.deleteAll(for: summaryId)
                    }
                    enqueueSummaryCloudDeletion(summary)
                    context.delete(summary)
                }
                try? context.save()
            }
            return summaries.first
        } catch {
            AppLog.shared.coreData("Error fetching summary: \(error)", level: .error)
            return nil
        }
    }

    func getSummaryData(for recordingId: UUID) -> EnhancedSummaryData? {
        guard let summaryEntry = getSummary(for: recordingId),
              let recordingEntry = getRecording(id: recordingId) else {
            return nil
        }

        return convertToEnhancedSummaryData(summaryEntry: summaryEntry, recordingEntry: recordingEntry)
    }

    func getAllSummaries() -> [SummaryEntry] {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \SummaryEntry.generatedAt, ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            AppLog.shared.coreData("Error fetching summaries: \(error)", level: .error)
            return []
        }
    }

    /// Returns the complete summary value objects represented by the Core Data store.
    /// SummaryEntry is the authoritative source; this method is the only conversion path
    /// callers should use when they need all summaries for display or cloud backup.
    func getAllSummaryData() -> [EnhancedSummaryData] {
        getAllSummaries().compactMap { summaryEntry in
            guard let recordingId = summaryEntry.recordingId ?? summaryEntry.recording?.id,
                  let recordingEntry = getRecording(id: recordingId) else {
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
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            AppLog.shared.coreData("Error fetching summary \(id): \(error)", level: .error)
            return nil
        }
    }

    func deleteSummary(id: UUID?) throws {
        guard let id = id else {
            AppLog.shared.coreData("Cannot delete summary: ID is nil", level: .error)
            return
        }

        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            let summaries = try context.fetch(fetchRequest)
            if summaries.isEmpty {
                AppLog.shared.coreData("No summary found with ID: \(id)", level: .debug)
                return
            }

            let recordingIds = Set(summaries.compactMap { $0.recordingId ?? $0.recording?.id })
            let recordings = getAllRecordings().filter { recording in
                recording.summaryId == id ||
                    recording.id.map { recordingIds.contains($0) } == true ||
                    summaries.contains { $0.recording === recording }
            }
            for recording in recordings {
                recording.summary = nil
                recording.summaryId = nil
                recording.summaryStatus = ProcessingStatus.notStarted.rawValue
                recording.lastModified = Date()
            }

            let cloudDeletions = summaries.compactMap { summary -> (summaryId: UUID, recordingId: UUID?)? in
                guard let summaryId = summary.id else { return nil }
                return (
                    summaryId: summaryId,
                    recordingId: summary.recordingId ?? summary.recording?.id
                )
            }

            for summary in summaries {
                AppLog.shared.coreData("Deleting summary with ID: \(id)", level: .debug)
                context.delete(summary)
            }

            // Properly handle save errors
            do {
                try saveContext()
                AppLog.shared.coreData("Successfully deleted summary with ID: \(id)")
            } catch {
                AppLog.shared.coreData("Failed to save context after deleting summary: \(error)", level: .error)
                // Rollback the deletion
                context.rollback()
                throw error
            }

            for deletion in cloudDeletions {
                enqueueSummaryCloudDeletion(
                    summaryId: deletion.summaryId,
                    recordingId: deletion.recordingId
                )
            }
        } catch {
            AppLog.shared.coreData("Error deleting summary: \(error)", level: .error)
            throw error
        }
    }

    /// Get all summary IDs for a recording (used to capture IDs before creating new summary)
    func getAllSummaryIds(for recordingId: UUID) -> [UUID] {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)

        do {
            let summaries = try context.fetch(fetchRequest)
            return summaries.compactMap { $0.id }
        } catch {
            AppLog.shared.coreData("Error fetching summary IDs: \(error)", level: .error)
            return []
        }
    }

    /// Delete ALL summaries for a recording (useful for regeneration to clean up orphans)
    func deleteAllSummaries(for recordingId: UUID) throws {
        let fetchRequest: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)

        do {
            let summaries = try context.fetch(fetchRequest)
            if summaries.isEmpty {
                AppLog.shared.coreData("No summaries found for recording: \(recordingId)", level: .debug)
                return
            }

            AppLog.shared.coreData("Deleting \(summaries.count) summary/summaries for recording: \(recordingId)", level: .debug)
            for summary in summaries {
                if let summaryId = summary.id,
                   let recording = getRecording(id: recordingId),
                   recording.summaryId == summaryId {
                    recording.summary = nil
                    recording.summaryId = nil
                    recording.summaryStatus = ProcessingStatus.notStarted.rawValue
                    recording.lastModified = Date()
                }
            }
            for summary in summaries {
                AppLog.shared.coreData("Deleting summary ID: \(summary.id?.uuidString ?? "nil")", level: .debug)
                if let summaryId = summary.id {
                    try? SummaryAttachmentStore.shared.deleteAll(for: summaryId)
                }
                enqueueSummaryCloudDeletion(summary)
                context.delete(summary)
            }

            try saveContext()
            AppLog.shared.coreData("Successfully deleted all summaries for recording: \(recordingId)")
        } catch {
            AppLog.shared.coreData("Error deleting summaries for recording: \(error)", level: .error)
            context.rollback()
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

    func getAllRecordingsWithData() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        let recordings = getAllRecordings()

        return recordings.map { recording in
            let transcript = recording.id.flatMap { getTranscriptData(for: $0) }
            let summary = recording.id.flatMap { getSummaryData(for: $0) }
            return (recording: recording, transcript: transcript, summary: summary)
        }
    }

    func getRecordingsWithTranscripts() -> [(recording: RecordingEntry, transcript: TranscriptData?, summary: EnhancedSummaryData?)] {
        return getAllRecordingsWithData().filter { $0.transcript != nil }
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
        guard let recording = getRecording(id: id) else {
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
        let recordingId = recording.id ?? id
        let transcriptIds = [recording.transcriptId ?? recording.transcript?.id].compactMap { $0 }
        let summaryIds = [recording.summaryId ?? recording.summary?.id].compactMap { $0 }

        context.delete(recording)
        do {
            try saveContext()
            AppLog.shared.coreData("Recording deleted: \(id)")
        } catch {
            AppLog.shared.coreData("Error deleting recording: \(error)", level: .error)
            context.rollback()
            throw error
        }

        if enqueueCloudDeletion {
            SummaryManager.shared.getiCloudManager().enqueueRecordingDeletionForiCloud(
                recordingId: recordingId,
                transcriptIds: transcriptIds,
                summaryIds: summaryIds
            )
        }
        for summaryId in summaryIds {
            try? SummaryAttachmentStore.shared.deleteAll(for: summaryId)
        }
    }

    func saveContext() throws {
        try context.save()
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

    func getAllProcessingJobs() -> [ProcessingJobEntry] {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ProcessingJobEntry.startTime, ascending: false)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            AppLog.shared.coreData("Error fetching processing jobs: \(error)", level: .error)
            return []
        }
    }

    func getProcessingJob(id: UUID) -> ProcessingJobEntry? {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            AppLog.shared.coreData("Error fetching processing job: \(error)", level: .error)
            return nil
        }
    }

    func getActiveProcessingJobs() -> [ProcessingJobEntry] {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "status IN %@", ["queued", "processing"])
        fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \ProcessingJobEntry.startTime, ascending: true)]

        do {
            return try context.fetch(fetchRequest)
        } catch {
            AppLog.shared.coreData("Error fetching active processing jobs: \(error)", level: .error)
            return []
        }
    }

    func createProcessingJob(
        id: UUID,
        jobType: String,
        engine: String,
        recordingURL: URL,
        recordingName: String,
        modelName: String? = nil
    ) -> ProcessingJobEntry {
        let job = ProcessingJobEntry(context: context)
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

        // Link to recording if it exists
        if let recording = getRecording(url: recordingURL) {
            job.recording = recording
        }

        do {
            try saveContext()
            AppLog.shared.coreData("Created processing job: \(id)")
        } catch {
            AppLog.shared.coreData("Error saving processing job: \(error)", level: .error)
        }
        return job
    }

    func updateProcessingJob(_ job: ProcessingJobEntry) {
        job.lastModified = Date()
        try? saveContext()
    }

    func deleteProcessingJob(_ job: ProcessingJobEntry) {
        context.delete(job)
        try? saveContext()
        AppLog.shared.coreData("Deleted processing job: \(job.id?.uuidString ?? "nil")")
    }

    func deleteCompletedProcessingJobs() {
        let fetchRequest: NSFetchRequest<ProcessingJobEntry> = ProcessingJobEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "status IN %@", ["completed", "failed"])

        do {
            let completedJobs = try context.fetch(fetchRequest)
            for job in completedJobs {
                context.delete(job)
            }
            try? saveContext()
            AppLog.shared.coreData("Deleted \(completedJobs.count) completed processing jobs")
        } catch {
            AppLog.shared.coreData("Error deleting completed processing jobs: \(error)", level: .error)
        }
    }

    // MARK: - Cleanup Operations

    /// Cleans up orphaned recordings that have no audio file and no meaningful content
    func cleanupOrphanedRecordings() -> Int {
        let allRecordings = getAllRecordings()
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
            }
        }

        return cleanedCount
    }

    /// Fixes recordings that should have been deleted completely but still exist as orphans
    func fixIncompletelyDeletedRecordings() -> Int {
        let allRecordings = getAllRecordings()
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
            }
        }

        return fixedCount
    }

    /// Cleans up recordings that reference files that no longer exist
    func cleanupRecordingsWithMissingFiles() -> Int {
        let allRecordings = getAllRecordings()
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
                        // No valuable content to preserve, delete the record
                        enqueueRecordingCloudDeletion(recording)
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
                    enqueueRecordingCloudDeletion(recording)
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
            }
        }

        return cleanedCount
    }

    // MARK: - Debug Operations

    func debugDatabaseContents() {
        let recordings = getAllRecordings()
        AppLog.shared.coreData("Core Data contains \(recordings.count) recordings", level: .debug)

        for recording in recordings {
            let hasTranscript = recording.transcript != nil
            let hasSummary = recording.summary != nil
            let hasLocation = getLocationData(for: recording) != nil
            AppLog.shared.coreData("Recording ID: \(recording.id?.uuidString ?? "nil") | transcript: \(hasTranscript) | summary: \(hasSummary) | transcriptionStatus: \(recording.transcriptionStatus ?? "unknown") | summaryStatus: \(recording.summaryStatus ?? "unknown") | location: \(hasLocation)", level: .debug)
        }
    }

    // MARK: - URL Synchronization

    /// Syncs Core Data recording URLs with actual files on disk
    func syncRecordingURLs() {
        let allRecordings = getAllRecordings()
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
        guard let recording = getRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"])
        }

        // Clean any legacy [Watch] tags from the name
        let finalName = newName.replacingOccurrences(of: " [Watch]", with: "")

        recording.recordingName = finalName
        recording.lastModified = Date()

        do {
            try context.save()
            AppLog.shared.coreData("Updated recording name for ID: \(recordingId)")
        } catch {
            AppLog.shared.coreData("Failed to save recording name update: \(error)", level: .error)
            throw error
        }
    }

    func updateCloudSyncDisabled(for recordingId: UUID, disabled: Bool) throws {
        guard let recording = getRecording(id: recordingId) else {
            throw NSError(domain: "CoreDataManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Recording not found with ID: \(recordingId)"])
        }

        recording.isCloudSyncDisabled = disabled
        recording.lastModified = Date()

        do {
            try context.save()
            AppLog.shared.coreData("Updated iCloud exclusion for recording ID: \(recordingId)")
        } catch {
            AppLog.shared.coreData("Failed to save iCloud exclusion update: \(error)", level: .error)
            throw error
        }
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
