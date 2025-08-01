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
        print("📝 Transcript text preview: \(transcript.plainText.prefix(100))")
        print("🔢 Number of segments: \(transcript.segments.count)")
        
        // Check for placeholder text in the transcript
        if transcript.plainText.lowercased().contains("loading") {
            print("⚠️ WARNING: Saving transcript with 'loading' text!")
            print("📝 Full transcript text: \(transcript.plainText)")
        }
        
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
    
    func deleteTranscriptWithPlaceholderText(for recordingURL: URL) {
        DispatchQueue.main.async {
            // Find and remove transcripts that contain placeholder text
            self.transcripts.removeAll { transcript in
                transcript.recordingURL == recordingURL && 
                (transcript.plainText.lowercased().contains("loading") ||
                 transcript.plainText.lowercased().contains("error"))
            }
            self.saveTranscriptsToDisk()
            print("🗑️ Removed transcript with placeholder/error text for: \(recordingURL.lastPathComponent)")
        }
    }
    
    func deleteTranscriptWithErrorText(for recordingURL: URL) {
        DispatchQueue.main.async {
            // Find and remove transcripts that contain error text
            self.transcripts.removeAll { transcript in
                transcript.recordingURL == recordingURL && 
                transcript.plainText.lowercased().contains("error")
            }
            self.saveTranscriptsToDisk()
            print("🗑️ Removed transcript with error text for: \(recordingURL.lastPathComponent)")
        }
    }
    
    func clearAllProblematicTranscripts() {
        DispatchQueue.main.async {
            let originalCount = self.transcripts.count
            self.transcripts.removeAll { transcript in
                let text = transcript.plainText.lowercased()
                return text.contains("loading") || 
                       text.contains("error") || 
                       text.contains("failed") ||
                       text.count < 50 // Too short to be meaningful
            }
            let removedCount = originalCount - self.transcripts.count
            self.saveTranscriptsToDisk()
            print("🗑️ Removed \(removedCount) problematic transcripts")
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
        
        // Try to find orphaned transcripts that might match this recording
        // This handles cases where the recording name was updated but transcript wasn't
        if let orphanedMatch = findOrphanedTranscript(for: recordingURL) {
            print("✅ Found orphaned transcript match: \(orphanedMatch.recordingName)")
            return orphanedMatch
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
    
    func reloadTranscripts() {
        print("🔄 TranscriptManager: Reloading transcripts from disk...")
        loadTranscripts()
        print("✅ TranscriptManager: Reloaded \(transcripts.count) transcripts")
    }
    
    // MARK: - Debug Methods
    
    func debugPrintTranscripts() {
        print("📋 TranscriptManager: Current transcripts (\(transcripts.count) total):")
        for (index, transcript) in transcripts.enumerated() {
            print("  \(index): \(transcript.recordingName) - \(transcript.recordingURL.lastPathComponent)")
        }
    }
    
    // MARK: - Orphaned Transcript Handling
    
    private func findOrphanedTranscript(for recordingURL: URL) -> TranscriptData? {
        // Look for transcripts where the recording file doesn't exist but we have a transcript
        // This can happen when recording names are updated but transcripts aren't
        let recordingExists = FileManager.default.fileExists(atPath: recordingURL.path)
        
        if !recordingExists {
            // If the recording doesn't exist, look for any transcript that might be orphaned
            // and could potentially match this recording based on content or metadata
            for transcript in transcripts {
                // Check if this transcript's recording file also doesn't exist
                let transcriptRecordingExists = FileManager.default.fileExists(atPath: transcript.recordingURL.path)
                
                if !transcriptRecordingExists {
                    // Both recordings are missing, this might be a match
                    // We could add more sophisticated matching here based on:
                    // - Similar recording dates
                    // - Similar content patterns
                    // - File size patterns
                    // For now, we'll return the first orphaned transcript as a potential match
                    print("🔍 Found potential orphaned transcript: \(transcript.recordingName)")
                    return transcript
                }
            }
        }
        
        return nil
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