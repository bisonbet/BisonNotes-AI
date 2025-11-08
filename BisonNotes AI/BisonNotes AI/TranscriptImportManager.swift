//
//  TranscriptImportManager.swift
//  BisonNotes AI
//
//  Handles importing standalone transcripts with dummy audio files
//

import Foundation
import AVFoundation
import CoreData

@MainActor
class TranscriptImportManager: NSObject, ObservableObject {

    @Published var isImporting = false
    @Published var importProgress: Double = 0.0
    @Published var currentlyImporting: String = ""
    @Published var importResults: TranscriptImportResults?
    @Published var showingImportAlert = false

    private let persistenceController: PersistenceController
    private let context: NSManagedObjectContext
    private let supportedTextExtensions = ["txt", "text", "md", "markdown"]

    override init() {
        self.persistenceController = PersistenceController.shared
        self.context = persistenceController.container.viewContext
        super.init()
    }

    // MARK: - Import Methods

    /// Import transcripts from text files
    func importTranscriptFiles(from urls: [URL]) async {
        guard !isImporting else { return }

        isImporting = true
        importProgress = 0.0
        currentlyImporting = "Preparing..."

        let totalCount = urls.count
        guard totalCount > 0 else {
            completeImport(with: TranscriptImportResults(total: 0, successful: 0, failed: 0, errors: []))
            return
        }

        var successful = 0
        var failed = 0
        var errors: [String] = []

        for (index, sourceURL) in urls.enumerated() {
            currentlyImporting = "Importing \(sourceURL.lastPathComponent)..."
            importProgress = Double(index) / Double(totalCount)

            do {
                try await importTranscriptFile(from: sourceURL)
                successful += 1
            } catch {
                failed += 1
                errors.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }

            // Small delay to show progress
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        importProgress = 1.0
        currentlyImporting = "Complete"

        let results = TranscriptImportResults(
            total: totalCount,
            successful: successful,
            failed: failed,
            errors: errors
        )

        completeImport(with: results)
    }

    /// Import a single transcript from text content
    func importTranscript(text: String, name: String? = nil) async throws -> UUID {
        let transcriptName = name ?? "Imported Transcript \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"

        // Create dummy audio file
        let dummyAudioURL = try await createDummyAudioFile(name: transcriptName)

        // Parse text into transcript segments
        let segments = parseTextIntoSegments(text)

        // Create recording entry
        let recordingId = try await createRecordingEntryForImportedTranscript(
            audioURL: dummyAudioURL,
            name: transcriptName
        )

        // Create transcript entry
        try await createTranscriptEntry(
            for: recordingId,
            segments: segments
        )

        print("✅ Successfully imported transcript: \(transcriptName)")

        return recordingId
    }

    // MARK: - Private Methods

    private func importTranscriptFile(from sourceURL: URL) async throws {
        // Validate file extension
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedTextExtensions.contains(fileExtension) else {
            throw TranscriptImportError.unsupportedFormat(fileExtension)
        }

        // Read file contents
        let text: String
        do {
            text = try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw TranscriptImportError.readFailed("Unable to read file: \(error.localizedDescription)")
        }

        // Use filename (without extension) as the transcript name
        let transcriptName = sourceURL.deletingPathExtension().lastPathComponent

        // Import the transcript
        _ = try await importTranscript(text: text, name: transcriptName)
    }

    /// Creates a minimal dummy audio file (~1KB) for the imported transcript
    private func createDummyAudioFile(name: String) async throws -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // Generate unique filename
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(name)_\(timestamp)_transcript.m4a"
        let fileURL = documentsPath.appendingPathComponent(filename)

        // Create audio settings for minimal file size
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 8000.0,  // Low sample rate
            AVNumberOfChannelsKey: 1,   // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue,
            AVEncoderBitRateKey: 8000   // Very low bitrate
        ]

        // Create a very short audio file (0.1 seconds of silence)
        let audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder.record()

        // Record for 0.1 seconds
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        audioRecorder.stop()

        // Verify file was created
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw TranscriptImportError.dummyAudioCreationFailed("Failed to create dummy audio file")
        }

        // Verify file size is reasonable (should be around 1KB or less)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        print("📝 Created dummy audio file: \(filename) (\(fileSize) bytes)")

        return fileURL
    }

    /// Parse text into transcript segments
    private func parseTextIntoSegments(_ text: String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        let lines = text.components(separatedBy: .newlines)
        var currentTime: TimeInterval = 0

        // Try to detect if text has speaker labels (e.g., "Speaker 1:", "John:", etc.)
        let speakerPattern = #"^([A-Za-z0-9\s]+):\s*(.+)$"#
        let speakerRegex = try? NSRegularExpression(pattern: speakerPattern)

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            var speaker = "Speaker"
            var text = trimmedLine

            // Check if line has speaker label
            if let regex = speakerRegex {
                let range = NSRange(trimmedLine.startIndex..., in: trimmedLine)
                if let match = regex.firstMatch(in: trimmedLine, range: range) {
                    if let speakerRange = Range(match.range(at: 1), in: trimmedLine),
                       let textRange = Range(match.range(at: 2), in: trimmedLine) {
                        speaker = String(trimmedLine[speakerRange]).trimmingCharacters(in: .whitespaces)
                        text = String(trimmedLine[textRange]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }

            // Estimate duration based on word count (average speaking rate: ~150 words/minute)
            let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let estimatedDuration = Double(words.count) / 150.0 * 60.0 // Convert to seconds
            let duration = max(estimatedDuration, 1.0) // Minimum 1 second per segment

            let segment = TranscriptSegment(
                speaker: speaker,
                text: text,
                startTime: currentTime,
                endTime: currentTime + duration
            )

            segments.append(segment)
            currentTime += duration
        }

        // If no segments were created, create a single segment with all text
        if segments.isEmpty {
            let segment = TranscriptSegment(
                speaker: "Speaker",
                text: text,
                startTime: 0,
                endTime: 10
            )
            segments.append(segment)
        }

        return segments
    }

    /// Create a recording entry for the imported transcript
    private func createRecordingEntryForImportedTranscript(audioURL: URL, name: String) async throws -> UUID {
        // Check if recording already exists
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", name)

        do {
            let existingRecordings = try context.fetch(fetchRequest)
            if !existingRecordings.isEmpty {
                print("⏭️ Recording entry already exists: \(name)")
                if let existingId = existingRecordings.first?.id {
                    return existingId
                }
            }
        } catch {
            print("❌ Error checking for existing recording: \(error)")
            throw TranscriptImportError.databaseError("Failed to check existing recordings: \(error.localizedDescription)")
        }

        // Create new recording entry
        let recordingEntry = RecordingEntry(context: context)
        let recordingId = UUID()
        recordingEntry.id = recordingId
        recordingEntry.recordingName = name

        // Store relative path instead of absolute URL
        recordingEntry.recordingURL = urlToRelativePath(audioURL)

        // Get file metadata
        do {
            let resourceValues = try audioURL.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            recordingEntry.recordingDate = resourceValues.creationDate ?? Date()
            recordingEntry.createdAt = resourceValues.creationDate ?? Date()
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = Int64(resourceValues.fileSize ?? 0)

            // Get duration (should be ~0.1 seconds)
            let duration = await getAudioDuration(url: audioURL)
            recordingEntry.duration = duration

        } catch {
            print("❌ Error getting file metadata: \(error)")
            recordingEntry.recordingDate = Date()
            recordingEntry.createdAt = Date()
            recordingEntry.lastModified = Date()
            recordingEntry.fileSize = 0
            recordingEntry.duration = 0.1
        }

        // Set default values
        recordingEntry.audioQuality = "imported"
        recordingEntry.transcriptionStatus = ProcessingStatus.completed.rawValue // Mark as completed since we're importing
        recordingEntry.summaryStatus = ProcessingStatus.notStarted.rawValue

        // Save the context
        do {
            try context.save()
            print("✅ Created Core Data entry for imported transcript: \(name)")
        } catch {
            print("❌ Failed to save Core Data entry: \(error)")
            throw TranscriptImportError.databaseError("Failed to save to database: \(error.localizedDescription)")
        }

        return recordingId
    }

    /// Create a transcript entry for the imported text
    private func createTranscriptEntry(for recordingId: UUID, segments: [TranscriptSegment]) async throws {
        guard let recording = getRecording(id: recordingId) else {
            throw TranscriptImportError.databaseError("Recording not found for ID: \(recordingId)")
        }

        // Create transcript entry
        let transcriptEntry = TranscriptEntry(context: context)
        let transcriptId = UUID()
        transcriptEntry.id = transcriptId
        transcriptEntry.recordingId = recordingId
        transcriptEntry.engine = "imported" // Mark as imported
        transcriptEntry.confidence = 1.0 // Full confidence since it's user-provided
        transcriptEntry.processingTime = 0
        transcriptEntry.createdAt = Date()
        transcriptEntry.lastModified = Date()

        // Encode segments to JSON
        if let segmentsData = try? JSONEncoder().encode(segments),
           let segmentsString = String(data: segmentsData, encoding: .utf8) {
            transcriptEntry.segments = segmentsString
        }

        // No speaker mappings for imported transcripts (users can edit later)
        transcriptEntry.speakerMappings = nil

        // Link to recording
        transcriptEntry.recording = recording
        recording.transcript = transcriptEntry
        recording.transcriptId = transcriptId

        // Save the context
        do {
            try context.save()
            print("✅ Created transcript entry for imported transcript: \(recording.recordingName ?? "unknown")")
        } catch {
            print("❌ Failed to save transcript entry: \(error)")
            throw TranscriptImportError.databaseError("Failed to save transcript: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    private func getRecording(id: UUID) -> RecordingEntry? {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)

        do {
            return try context.fetch(fetchRequest).first
        } catch {
            print("❌ Error fetching recording: \(error)")
            return nil
        }
    }

    private func getAudioDuration(url: URL) async -> TimeInterval {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            return CMTimeGetSeconds(duration)
        } catch {
            print("❌ Error getting audio duration: \(error)")
            return 0.1 // Default to 0.1 seconds for dummy file
        }
    }

    private func urlToRelativePath(_ url: URL) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let urlString = url.absoluteString
        let documentsString = documentsURL.absoluteString

        if urlString.hasPrefix(documentsString) {
            let relativePath = String(urlString.dropFirst(documentsString.count))
            return relativePath.isEmpty ? nil : relativePath
        }

        return url.lastPathComponent
    }

    private func completeImport(with results: TranscriptImportResults) {
        importResults = results
        isImporting = false
        showingImportAlert = true
    }
}

// MARK: - Import Errors

enum TranscriptImportError: LocalizedError {
    case unsupportedFormat(String)
    case readFailed(String)
    case dummyAudioCreationFailed(String)
    case databaseError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported text format: \(format). Supported formats: txt, text, md, markdown"
        case .readFailed(let reason):
            return "Failed to read file: \(reason)"
        case .dummyAudioCreationFailed(let reason):
            return "Failed to create dummy audio file: \(reason)"
        case .databaseError(let reason):
            return "Database error: \(reason)"
        }
    }
}

// MARK: - Supporting Structures

struct TranscriptImportResults {
    let total: Int
    let successful: Int
    let failed: Int
    let errors: [String]

    var successRate: Double {
        return total > 0 ? Double(successful) / Double(total) : 0.0
    }

    var formattedSuccessRate: String {
        return String(format: "%.1f%%", successRate * 100)
    }

    var summary: String {
        if total == 0 {
            return "No files selected for import"
        } else if failed == 0 {
            return "Successfully imported all \(successful) transcripts"
        } else {
            return "Imported \(successful) of \(total) transcripts successfully"
        }
    }
}
