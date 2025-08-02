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
              let recordingURL = recordingEntry.recordingURL,
              let url = URL(string: recordingURL) else {
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
}