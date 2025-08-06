import Foundation
import CoreData

class TranscriptManager: ObservableObject {
    // Singleton instance
    static let shared = TranscriptManager()
    
    init() {
        // No initialization needed for Core Data only
    }
    
    func getTranscript(for recordingURL: URL) -> TranscriptData? {
        // Try Core Data lookup only
        if let transcriptData = getCoreDataTranscript(for: recordingURL) {
            return transcriptData
        }
        
        return nil
    }
    
    func hasTranscript(for recordingURL: URL) -> Bool {
        return getTranscript(for: recordingURL) != nil
    }
    

    

    
    // MARK: - Core Data Integration
    
    private func getCoreDataTranscript(for recordingURL: URL) -> TranscriptData? {
        // Access Core Data directly to avoid @MainActor issues
        let context = PersistenceController.shared.container.viewContext
        
        // Find recording by URL - first try exact match
        let recordingFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
        recordingFetch.predicate = NSPredicate(format: "recordingURL == %@", recordingURL.absoluteString)
        
        do {
            var recording = try context.fetch(recordingFetch).first
            
            // If no exact match, try filename-based lookup
            if recording == nil {
                let filename = recordingURL.lastPathComponent
                let filenameFetch: NSFetchRequest<RecordingEntry> = RecordingEntry.fetchRequest()
                filenameFetch.predicate = NSPredicate(format: "recordingURL ENDSWITH %@", filename)
                
                recording = try context.fetch(filenameFetch).first
            }
            
            guard let recording = recording,
                  let recordingId = recording.id else {
                return nil
            }
            
            // Find transcript by recording ID
            let transcriptFetch: NSFetchRequest<TranscriptEntry> = TranscriptEntry.fetchRequest()
            transcriptFetch.predicate = NSPredicate(format: "recordingId == %@", recordingId as CVarArg)
            
            guard let transcriptEntry = try context.fetch(transcriptFetch).first else {
                return nil
            }
            
            // Convert to TranscriptData
            return convertCoreDataToTranscriptData(transcriptEntry: transcriptEntry, recordingEntry: recording)
            
        } catch {
            return nil
        }
    }
    
    private func convertCoreDataToTranscriptData(transcriptEntry: TranscriptEntry, recordingEntry: RecordingEntry) -> TranscriptData? {
        guard let recordingId = recordingEntry.id,
              let recordingURLString = recordingEntry.recordingURL else {
            return nil
        }
        
        // Get absolute URL using local logic to avoid main actor issues
        guard let url = getAbsoluteURL(from: recordingURLString) else {
            print("❌ Could not resolve URL for recording: \(recordingEntry.recordingName ?? "unknown")")
            return nil
        }
        
        // Decode segments from JSON
        var segments: [TranscriptSegment] = []
        if let segmentsString = transcriptEntry.segments,
           let segmentsData = segmentsString.data(using: .utf8) {
            segments = (try? JSONDecoder().decode([TranscriptSegment].self, from: segmentsData)) ?? []
        }
        
        // Decode speaker mappings from JSON
        var speakerMappings: [String: String] = [:]
        if let speakerString = transcriptEntry.speakerMappings,
           let speakerData = speakerString.data(using: .utf8) {
            speakerMappings = (try? JSONDecoder().decode([String: String].self, from: speakerData)) ?? [:]
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
    
    // MARK: - Helper Methods
    
    private func getAbsoluteURL(from urlString: String) -> URL? {
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
                    return newURL
                }
            }
        } else {
            // This is a relative path, convert to absolute URL
            if let absoluteURL = relativePathToURL(urlString) {
                if FileManager.default.fileExists(atPath: absoluteURL.path) {
                    return absoluteURL
                }
                
                // File doesn't exist, try to find by filename
                if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let filename = URL(fileURLWithPath: urlString).lastPathComponent
                    let searchURL = documentsURL.appendingPathComponent(filename)
                    if FileManager.default.fileExists(atPath: searchURL.path) {
                        return searchURL
                    }
                }
            }
        }
        
        return nil
    }
    
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
}