import Foundation

class TranscriptManager: ObservableObject {
    @Published var transcripts: [TranscriptData] = []
    private let transcriptsKey = "SavedTranscripts"
    
    // Singleton instance
    static let shared = TranscriptManager()
    
    init() {
        loadTranscripts()
    }
    
    func saveTranscript(_ transcript: TranscriptData) {
        print("💾 Saving transcript for: \(transcript.recordingName)")
        print("💾 Recording URL: \(transcript.recordingURL)")
        print("💾 Transcript text length: \(transcript.segments.map { $0.text }.joined().count)")
        
        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
                print("💾 Updating existing transcript at index \(index)")
                self.transcripts[index] = transcript
            } else {
                print("💾 Adding new transcript (total: \(self.transcripts.count + 1))")
                self.transcripts.append(transcript)
            }
            self.saveTranscriptsToDisk()
            print("💾 Transcript saved to disk")
        }
    }
    
    func updateTranscript(_ transcript: TranscriptData) {
        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
                var updatedTranscript = transcript
                updatedTranscript = TranscriptData(
                    recordingURL: transcript.recordingURL,
                    recordingName: transcript.recordingName,
                    recordingDate: transcript.recordingDate,
                    segments: transcript.segments,
                    speakerMappings: transcript.speakerMappings
                )
                self.transcripts[index] = updatedTranscript
                self.saveTranscriptsToDisk()
            }
        }
    }
    
    func deleteTranscript(for recordingURL: URL) {
        DispatchQueue.main.async {
            self.transcripts.removeAll { $0.recordingURL == recordingURL }
            self.saveTranscriptsToDisk()
        }
    }
    
    func getTranscript(for recordingURL: URL) -> TranscriptData? {
        print("🔍 TranscriptManager: Looking for transcript with URL: \(recordingURL)")
        print("🔍 TranscriptManager: Total transcripts: \(transcripts.count)")
        
        let targetFilename = recordingURL.lastPathComponent
        let targetName = recordingURL.deletingPathExtension().lastPathComponent
        
        print("🔍 TranscriptManager: Looking for filename: \(targetFilename)")
        print("🔍 TranscriptManager: Looking for name: \(targetName)")
        
        for (index, transcript) in transcripts.enumerated() {
            let transcriptFilename = transcript.recordingURL.lastPathComponent
            let transcriptName = transcript.recordingURL.deletingPathExtension().lastPathComponent
            
            print("🔍 TranscriptManager: Checking transcript \(index): \(transcript.recordingName)")
            print("🔍 TranscriptManager: Stored filename: \(transcriptFilename)")
            print("🔍 TranscriptManager: Stored name: \(transcriptName)")
            
            // Try multiple comparison methods
            let exactMatch = transcript.recordingURL == recordingURL
            let pathMatch = transcript.recordingURL.path == recordingURL.path
            let filenameMatch = transcriptFilename == targetFilename
            let nameMatch = transcriptName == targetName
            let recordingNameMatch = transcript.recordingName == targetName
            
            print("🔍 TranscriptManager: Exact match: \(exactMatch)")
            print("🔍 TranscriptManager: Path match: \(pathMatch)")
            print("🔍 TranscriptManager: Filename match: \(filenameMatch)")
            print("🔍 TranscriptManager: Name match: \(nameMatch)")
            print("🔍 TranscriptManager: Recording name match: \(recordingNameMatch)")
            
            // Match if any of these conditions are true
            if exactMatch || pathMatch || filenameMatch || nameMatch || recordingNameMatch {
                print("✅ TranscriptManager: Found matching transcript!")
                return transcript
            }
        }
        
        print("❌ TranscriptManager: No matching transcript found")
        return nil
    }
    
    func hasTranscript(for recordingURL: URL) -> Bool {
        return transcripts.contains { $0.recordingURL == recordingURL }
    }
    
    func updateRecordingURL(from oldURL: URL, to newURL: URL) {
        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.recordingURL == oldURL }) {
                var updatedTranscript = self.transcripts[index]
                updatedTranscript = TranscriptData(
                    recordingURL: newURL,
                    recordingName: updatedTranscript.recordingName,
                    recordingDate: updatedTranscript.recordingDate,
                    segments: updatedTranscript.segments,
                    speakerMappings: updatedTranscript.speakerMappings
                )
                self.transcripts[index] = updatedTranscript
                self.saveTranscriptsToDisk()
            }
        }
    }
    
    func clearAllTranscripts() {
        print("🧹 TranscriptManager: Clearing all transcripts...")
        let count = transcripts.count
        DispatchQueue.main.async {
            self.transcripts.removeAll()
            self.saveTranscriptsToDisk()
            print("✅ TranscriptManager: Cleared \(count) transcripts")
        }
    }
    
    // MARK: - Private Methods
    
    private func saveTranscriptsToDisk() {
        do {
            let data = try JSONEncoder().encode(transcripts)
            UserDefaults.standard.set(data, forKey: transcriptsKey)
        } catch {
            print("Failed to save transcripts: \(error)")
        }
    }
    
    private func loadTranscripts() {
        guard let data = UserDefaults.standard.data(forKey: transcriptsKey) else { return }
        do {
            transcripts = try JSONDecoder().decode([TranscriptData].self, from: data)
        } catch {
            print("Failed to load transcripts: \(error)")
        }
    }
}