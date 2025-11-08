//
//  TranscriptImportManager.swift
//  BisonNotes AI
//
//  Handles importing standalone transcripts with dummy audio files
//

import Foundation
import AVFoundation
import CoreData
import PDFKit
import UniformTypeIdentifiers
import Compression
import zlib

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
    private let supportedDocumentExtensions = ["pdf", "doc", "docx"]

    var supportedExtensions: [String] {
        return supportedTextExtensions + supportedDocumentExtensions
    }

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
        let baseName = name ?? "Imported Transcript \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"

        // Generate unique name if duplicates exist (appends " (2)", " (3)", etc.)
        let transcriptName = try await generateUniqueRecordingName(baseName: baseName)

        // Create dummy audio file with unique name
        let dummyAudioURL = try await createDummyAudioFile(name: transcriptName)

        // Parse text into transcript segments
        let segments = parseTextIntoSegments(text)

        // Create recording entry
        let recordingId = try await createRecordingEntryForImportedTranscript(
            audioURL: dummyAudioURL,
            name: transcriptName
        )

        // Create transcript entry with cleanup on failure
        do {
            try await createTranscriptEntry(
                for: recordingId,
                segments: segments
            )
        } catch {
            // Clean up orphaned data if transcript creation fails
            print("❌ Transcript creation failed, cleaning up orphaned data...")

            // Delete the recording entry from Core Data
            if let recording = getRecording(id: recordingId) {
                context.delete(recording)
                try? context.save()
            }

            // Delete the dummy audio file from disk
            try? FileManager.default.removeItem(at: dummyAudioURL)

            // Rethrow the original error
            throw error
        }

        if transcriptName != baseName {
            print("✅ Successfully imported transcript with unique name: \(transcriptName) (original: \(baseName))")
        } else {
            print("✅ Successfully imported transcript: \(transcriptName)")
        }

        return recordingId
    }

    // MARK: - Private Methods

    /// Generate a unique recording name by appending " (2)", " (3)", etc. if duplicates exist
    private func generateUniqueRecordingName(baseName: String) async throws -> String {
        var uniqueName = baseName
        var counter = 2

        // Keep checking until we find a unique name
        while try await recordingExists(name: uniqueName) {
            uniqueName = "\(baseName) (\(counter))"
            counter += 1
        }

        return uniqueName
    }

    /// Check if a recording with the given name already exists
    private func recordingExists(name: String) async throws -> Bool {
        let fetchRequest: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "recordingName == %@", name)

        do {
            let count = try context.count(for: fetchRequest)
            return count > 0
        } catch {
            print("❌ Error checking for existing recording: \(error)")
            throw TranscriptImportError.databaseError("Failed to check existing recordings: \(error.localizedDescription)")
        }
    }

    private func importTranscriptFile(from sourceURL: URL) async throws {
        // Validate file extension
        let fileExtension = sourceURL.pathExtension.lowercased()
        guard supportedExtensions.contains(fileExtension) else {
            throw TranscriptImportError.unsupportedFormat(fileExtension)
        }

        // Extract text based on file type
        let text: String
        do {
            if supportedTextExtensions.contains(fileExtension) {
                // Plain text files
                text = try String(contentsOf: sourceURL, encoding: .utf8)
            } else if fileExtension == "pdf" {
                // PDF files
                text = try await extractTextFromPDF(url: sourceURL)
            } else if fileExtension == "docx" {
                // Word DOCX files
                text = try await extractTextFromDOCX(url: sourceURL)
            } else if fileExtension == "doc" {
                // Legacy DOC files - limited support
                throw TranscriptImportError.unsupportedFormat("Legacy .doc format is not supported. Please convert to .docx, .pdf, or .txt")
            } else {
                throw TranscriptImportError.unsupportedFormat(fileExtension)
            }
        } catch let error as TranscriptImportError {
            throw error
        } catch {
            throw TranscriptImportError.readFailed("Unable to read file: \(error.localizedDescription)")
        }

        // Use filename (without extension) as the transcript name
        let transcriptName = sourceURL.deletingPathExtension().lastPathComponent

        // Import the transcript
        _ = try await importTranscript(text: text, name: transcriptName)
    }

    // MARK: - Document Text Extraction

    /// Extract text from a PDF file
    private func extractTextFromPDF(url: URL) async throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw TranscriptImportError.readFailed("Unable to open PDF document")
        }

        var extractedText = ""
        let pageCount = document.pageCount

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            if let pageText = page.string {
                extractedText += pageText
                // Add spacing between pages
                if pageIndex < pageCount - 1 {
                    extractedText += "\n\n"
                }
            }
        }

        if extractedText.isEmpty {
            throw TranscriptImportError.readFailed("PDF contains no readable text")
        }

        return extractedText
    }

    /// Extract text from a DOCX file
    private func extractTextFromDOCX(url: URL) async throws -> String {
        // DOCX is a ZIP archive containing XML files
        // We'll use Apple's built-in Archive API (available from Foundation)
        let fileManager = FileManager.default

        // Read the DOCX file as data
        let docxData = try Data(contentsOf: url)

        // Create a temporary directory for extraction
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Ensure cleanup happens on ALL exit paths (success or error)
        defer {
            try? fileManager.removeItem(at: tempDir)
        }

        do {
            // Write the data to a temporary zip file
            let zipURL = tempDir.appendingPathComponent("document.zip")
            try docxData.write(to: zipURL)

            // Use FileManager to unzip (iOS 15+)
            // Note: For iOS < 15, we could use a third-party library or manual ZIP parsing
            if #available(iOS 15.0, *) {
                // Try to extract using FileManager.unzipItem if available
                // For now, we'll read the zip manually using ZipArchive approach
                try await extractDOCXManually(from: zipURL, to: tempDir)
            } else {
                try await extractDOCXManually(from: zipURL, to: tempDir)
            }

            // Read the document.xml file
            let documentXMLPath = tempDir.appendingPathComponent("word/document.xml")
            guard fileManager.fileExists(atPath: documentXMLPath.path) else {
                throw TranscriptImportError.readFailed("Invalid DOCX structure: document.xml not found")
            }

            let xmlData = try Data(contentsOf: documentXMLPath)
            let xmlString = String(data: xmlData, encoding: .utf8) ?? ""

            // Extract text from XML
            let text = extractTextFromWordXML(xmlString)

            if text.isEmpty {
                throw TranscriptImportError.readFailed("DOCX contains no readable text")
            }

            return text

        } catch let error as TranscriptImportError {
            throw error
        } catch {
            throw TranscriptImportError.readFailed("Failed to extract text from DOCX: \(error.localizedDescription)")
        }
    }

    /// Manually extract DOCX ZIP file using basic ZIP parsing
    /// Note: This is a basic implementation. For production use with complex DOCX files,
    /// consider adding ZIPFoundation or similar library to handle all compression methods.
    private func extractDOCXManually(from zipURL: URL, to destURL: URL) async throws {
        // Read the ZIP file
        let zipData = try Data(contentsOf: zipURL)

        // Parse ZIP structure to find document.xml
        // ZIP file format: local file headers followed by central directory

        // ZIP local file header signature (0x04034b50)
        let signature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

        var offset = 0
        let bytes = [UInt8](zipData)

        while offset < bytes.count - 30 {
            // Check for local file header signature
            if bytes[offset] == signature[0] &&
               bytes[offset + 1] == signature[1] &&
               bytes[offset + 2] == signature[2] &&
               bytes[offset + 3] == signature[3] {

                // Read compression method (offset + 8, 2 bytes)
                let compressionMethod = Int(bytes[offset + 8]) + Int(bytes[offset + 9]) * 256

                // Parse the header
                let fileNameLength = Int(bytes[offset + 26]) + Int(bytes[offset + 27]) * 256
                let extraFieldLength = Int(bytes[offset + 28]) + Int(bytes[offset + 29]) * 256
                let compressedSize = Int(bytes[offset + 18]) + Int(bytes[offset + 19]) * 256 +
                                   Int(bytes[offset + 20]) * 65536 + Int(bytes[offset + 21]) * 16777216

                // Get filename
                let fileNameStart = offset + 30
                let fileNameEnd = fileNameStart + fileNameLength
                if fileNameEnd <= bytes.count {
                    let fileNameData = Data(bytes[fileNameStart..<fileNameEnd])
                    if let fileName = String(data: fileNameData, encoding: .utf8) {
                        // Check if this is the document.xml file
                        if fileName == "word/document.xml" {
                            // Extract the file content
                            let dataStart = fileNameEnd + extraFieldLength

                            // Validate dataStart to prevent crash from corrupted headers
                            guard dataStart <= bytes.count else {
                                throw TranscriptImportError.readFailed("Corrupted DOCX file: invalid header field length. Try converting to PDF or TXT first.")
                            }

                            let dataEnd = min(dataStart + compressedSize, bytes.count)

                            // Validate the range is valid (dataStart < dataEnd)
                            if dataEnd <= bytes.count && dataStart < dataEnd {
                                var fileData = Data(bytes[dataStart..<dataEnd])

                                // Handle compression
                                if compressionMethod == 8 {
                                    // DEFLATE compression - use Compression framework
                                    if let decompressed = decompressZlibData(fileData) {
                                        fileData = decompressed
                                    } else {
                                        throw TranscriptImportError.readFailed("Failed to decompress DOCX content. Try converting to PDF or TXT first.")
                                    }
                                } else if compressionMethod != 0 {
                                    // Unsupported compression method
                                    throw TranscriptImportError.readFailed("Unsupported DOCX compression. Try converting to PDF or TXT first.")
                                }

                                // Create directory structure
                                let wordDir = destURL.appendingPathComponent("word")
                                try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)

                                // Write the extracted file
                                let outputURL = destURL.appendingPathComponent(fileName)
                                try fileData.write(to: outputURL)

                                // Successfully extracted document.xml
                                return
                            }
                        }
                    }
                }

                // Move to next entry
                offset += 30 + fileNameLength + extraFieldLength + compressedSize
            } else {
                offset += 1
            }
        }

        throw TranscriptImportError.readFailed("Could not find document.xml in DOCX file. Try converting to PDF or TXT first.")
    }

    /// Decompress zlib/DEFLATE compressed data
    private func decompressZlibData(_ data: Data) -> Data? {
        let bufferSize = 1024 * 64  // 64KB buffer
        var decompressed = Data()

        data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Void in
            guard let baseAddress = sourcePtr.baseAddress else { return }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uint(data.count)

            // Initialize for DEFLATE decompression with automatic header detection
            var status = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

            guard status == Z_OK else { return }

            defer {
                inflateEnd(&stream)
            }

            repeat {
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                stream.next_out = UnsafeMutablePointer<Bytef>(&buffer)
                stream.avail_out = uint(bufferSize)

                status = inflate(&stream, Z_NO_FLUSH)

                let bytesDecompressed = bufferSize - Int(stream.avail_out)
                if bytesDecompressed > 0 {
                    decompressed.append(buffer, count: bytesDecompressed)
                }

            } while status == Z_OK

            if status != Z_STREAM_END {
                decompressed.removeAll()
            }
        }

        return decompressed.isEmpty ? nil : decompressed
    }

    /// Extract text from Word XML content
    private func extractTextFromWordXML(_ xmlString: String) -> String {
        var text = ""

        // Use XMLParser to extract text from <w:t> tags
        let parser = WordXMLParser()
        if let data = xmlString.data(using: .utf8) {
            let xmlParser = XMLParser(data: data)
            xmlParser.delegate = parser
            xmlParser.parse()
            text = parser.extractedText
        }

        // Clean up excessive whitespace and newlines
        let lines = text.components(separatedBy: .newlines)
        let cleanedLines = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return cleanedLines.joined(separator: "\n")
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
    /// Note: Duplicate check should be done before calling this function to avoid orphaned audio files
    private func createRecordingEntryForImportedTranscript(audioURL: URL, name: String) async throws -> UUID {
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

        // Encode segments to JSON with proper error handling
        do {
            let segmentsData = try JSONEncoder().encode(segments)
            guard let segmentsString = String(data: segmentsData, encoding: .utf8) else {
                throw TranscriptImportError.databaseError("Failed to encode segments to UTF-8 string")
            }
            transcriptEntry.segments = segmentsString
        } catch let encodingError {
            throw TranscriptImportError.databaseError("Failed to encode transcript segments: \(encodingError.localizedDescription)")
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
            return "Unsupported format: \(format). Supported formats: txt, md, markdown, pdf, docx"
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

// MARK: - Word XML Parser

/// XML parser for extracting text from Word DOCX files
class WordXMLParser: NSObject, XMLParserDelegate {
    var extractedText = ""
    private var currentElement = ""
    private var isInTextElement = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        // Check if we're entering a text element (w:t in Word XML)
        if elementName == "w:t" {
            isInTextElement = true
        }
        // Check for paragraph breaks (w:p)
        else if elementName == "w:p" {
            // Add newline for new paragraph (if not the first one)
            if !extractedText.isEmpty {
                extractedText += "\n"
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTextElement {
            extractedText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" {
            isInTextElement = false
        }
    }
}
