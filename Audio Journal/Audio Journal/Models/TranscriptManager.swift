import Foundation

class TranscriptManager: ObservableObject {
    @Published var transcripts: [TranscriptData] = []
    private let transcriptsKey = "SavedTranscripts"
    
    // Singleton instance
    static let shared = TranscriptManager()
    
    init() {
        loadTranscripts()
        fixMismatchedRecordingNames()
    }
    
    func saveTranscript(_ transcript: TranscriptData) {
        print("💾 Saving transcript for: \(transcript.recordingName)")
        
        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
                self.transcripts[index] = transcript
            } else {
                self.transcripts.append(transcript)
            }
            self.saveTranscriptsToDisk()
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
        let targetFilename = recordingURL.lastPathComponent
        let targetName = recordingURL.deletingPathExtension().lastPathComponent
        
        print("🔍 TranscriptManager: Looking for transcript for '\(targetName)'")
        print("🔍 Target filename: \(targetFilename)")
        print("🔍 Available transcripts: \(transcripts.count)")
        
        // Try exact URL match first (most reliable)
        if let exactMatch = transcripts.first(where: { $0.recordingURL == recordingURL }) {
            print("✅ Found exact URL match: \(exactMatch.recordingName)")
            return exactMatch
        }
        
        // Try filename match
        if let filenameMatch = transcripts.first(where: { $0.recordingURL.lastPathComponent == targetFilename }) {
            print("✅ Found filename match: \(filenameMatch.recordingName)")
            return filenameMatch
        }
        
        // Try name match (without extension)
        if let nameMatch = transcripts.first(where: { 
            $0.recordingURL.deletingPathExtension().lastPathComponent == targetName ||
            $0.recordingName == targetName
        }) {
            print("✅ Found name match: \(nameMatch.recordingName)")
            return nameMatch
        }
        
        // Debug: Only log if no match found and we have transcripts
        if !transcripts.isEmpty {
            print("❌ TranscriptManager: No match found for '\(targetName)' (total transcripts: \(transcripts.count))")
            print("❌ Available transcript names:")
            for (index, transcript) in transcripts.enumerated() {
                print("❌   \(index): '\(transcript.recordingName)' - \(transcript.recordingURL.lastPathComponent)")
            }
            // Add detailed debug info if needed
            if UserDefaults.standard.bool(forKey: "debugTranscriptLookup") {
                debugPrintTranscripts()
            }
        }
        
        return nil
    }
    
    func hasTranscript(for recordingURL: URL) -> Bool {
        return getTranscript(for: recordingURL) != nil
    }
    
    func updateRecordingURL(from oldURL: URL, to newURL: URL) {
        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.recordingURL == oldURL }) {
                var updatedTranscript = self.transcripts[index]
                // Update both URL and recording name to match the new filename
                let newRecordingName = newURL.deletingPathExtension().lastPathComponent
                updatedTranscript = TranscriptData(
                    recordingURL: newURL,
                    recordingName: newRecordingName,
                    recordingDate: updatedTranscript.recordingDate,
                    segments: updatedTranscript.segments,
                    speakerMappings: updatedTranscript.speakerMappings
                )
                self.transcripts[index] = updatedTranscript
                self.saveTranscriptsToDisk()
                print("✅ TranscriptManager: Updated transcript for renamed recording")
                print("✅ Old URL: \(oldURL.lastPathComponent)")
                print("✅ New URL: \(newURL.lastPathComponent)")
                print("✅ New name: \(newRecordingName)")
            }
        }
    }
    
    func updateRecordingName(from oldName: String, to newName: String, recordingURL: URL) {
        DispatchQueue.main.async {
            if let index = self.transcripts.firstIndex(where: { $0.recordingURL == recordingURL }) {
                var updatedTranscript = self.transcripts[index]
                updatedTranscript = TranscriptData(
                    recordingURL: updatedTranscript.recordingURL,
                    recordingName: newName,
                    recordingDate: updatedTranscript.recordingDate,
                    segments: updatedTranscript.segments,
                    speakerMappings: updatedTranscript.speakerMappings
                )
                self.transcripts[index] = updatedTranscript
                self.saveTranscriptsToDisk()
                print("✅ TranscriptManager: Updated recording name from '\(oldName)' to '\(newName)'")
            }
        }
    }
    
    func fixMismatchedRecordingNames() {
        print("🔧 TranscriptManager: Checking for mismatched recording names...")
        var fixedCount = 0
        
        for (index, transcript) in transcripts.enumerated() {
            let expectedName = transcript.recordingURL.deletingPathExtension().lastPathComponent
            if transcript.recordingName != expectedName {
                print("🔧 Fixing mismatched name: '\(transcript.recordingName)' → '\(expectedName)'")
                var updatedTranscript = transcript
                updatedTranscript = TranscriptData(
                    recordingURL: transcript.recordingURL,
                    recordingName: expectedName,
                    recordingDate: transcript.recordingDate,
                    segments: transcript.segments,
                    speakerMappings: transcript.speakerMappings
                )
                transcripts[index] = updatedTranscript
                fixedCount += 1
            }
        }
        
        if fixedCount > 0 {
            saveTranscriptsToDisk()
            print("✅ TranscriptManager: Fixed \(fixedCount) mismatched recording names")
        } else {
            print("ℹ️ TranscriptManager: No mismatched recording names found")
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
    
    // MARK: - Debug Methods
    
    func debugPrintTranscripts() {
        print("📋 TranscriptManager: Current transcripts (\(transcripts.count) total):")
        for (index, transcript) in transcripts.enumerated() {
            print("  \(index): \(transcript.recordingName) - \(transcript.recordingURL.lastPathComponent)")
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