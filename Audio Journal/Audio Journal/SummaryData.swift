import Foundation
import CoreLocation

// MARK: - Recording File Structure

struct RecordingFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let date: Date
    let duration: TimeInterval
    let locationData: LocationData?
    
    var dateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var durationString: String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Transcript Data Structures

struct TranscriptSegment: Codable, Identifiable {
    let id: UUID
    let speaker: String
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    
    init(speaker: String, text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

struct TranscriptData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    let segments: [TranscriptSegment]
    let speakerMappings: [String: String] // Maps "Speaker 1" -> "John Doe"
    let createdAt: Date
    let lastModified: Date
    
    init(recordingURL: URL, recordingName: String, recordingDate: Date, segments: [TranscriptSegment], speakerMappings: [String: String] = [:]) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.segments = segments
        self.speakerMappings = speakerMappings
        self.createdAt = Date()
        self.lastModified = Date()
    }
    
    var fullText: String {
        return segments.map { segment in
            let speakerName = speakerMappings[segment.speaker] ?? segment.speaker
            return "\(speakerName): \(segment.text)"
        }.joined(separator: "\n")
    }
    
    var plainText: String {
        return segments.map { $0.text }.joined(separator: " ")
    }
    
    func updatedTranscript(segments: [TranscriptSegment], speakerMappings: [String: String]) -> TranscriptData {
        return TranscriptData(
            recordingURL: self.recordingURL,
            recordingName: self.recordingName,
            recordingDate: self.recordingDate,
            segments: segments,
            speakerMappings: speakerMappings
        )
    }
}

class TranscriptManager: ObservableObject {
    @Published var transcripts: [TranscriptData] = []
    private let transcriptsKey = "SavedTranscripts"
    
    init() {
        loadTranscripts()
    }
    
    func saveTranscript(_ transcript: TranscriptData) {
        print("💾 Saving transcript for: \(transcript.recordingName)")
        print("💾 Recording URL: \(transcript.recordingURL)")
        print("💾 Transcript text length: \(transcript.segments.map { $0.text }.joined().count)")
        
        if let index = transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
            print("💾 Updating existing transcript at index \(index)")
            transcripts[index] = transcript
        } else {
            print("💾 Adding new transcript (total: \(transcripts.count + 1))")
            transcripts.append(transcript)
        }
        saveTranscriptsToDisk()
        print("💾 Transcript saved to disk")
    }
    
    func updateTranscript(_ transcript: TranscriptData) {
        if let index = transcripts.firstIndex(where: { $0.recordingURL == transcript.recordingURL }) {
            var updatedTranscript = transcript
            updatedTranscript = TranscriptData(
                recordingURL: transcript.recordingURL,
                recordingName: transcript.recordingName,
                recordingDate: transcript.recordingDate,
                segments: transcript.segments,
                speakerMappings: transcript.speakerMappings
            )
            transcripts[index] = updatedTranscript
            saveTranscriptsToDisk()
        }
    }
    
    func deleteTranscript(for recordingURL: URL) {
        transcripts.removeAll { $0.recordingURL == recordingURL }
        saveTranscriptsToDisk()
    }
    
    func getTranscript(for recordingURL: URL) -> TranscriptData? {
        return transcripts.first { $0.recordingURL == recordingURL }
    }
    
    func hasTranscript(for recordingURL: URL) -> Bool {
        return transcripts.contains { $0.recordingURL == recordingURL }
    }
    
    func updateRecordingURL(from oldURL: URL, to newURL: URL) {
        if let index = transcripts.firstIndex(where: { $0.recordingURL == oldURL }) {
            var updatedTranscript = transcripts[index]
            updatedTranscript = TranscriptData(
                recordingURL: newURL,
                recordingName: updatedTranscript.recordingName,
                recordingDate: updatedTranscript.recordingDate,
                segments: updatedTranscript.segments,
                speakerMappings: updatedTranscript.speakerMappings
            )
            transcripts[index] = updatedTranscript
            saveTranscriptsToDisk()
        }
    }
    
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
    
    func clearAllTranscripts() {
        print("🧹 TranscriptManager: Clearing all transcripts...")
        let count = transcripts.count
        transcripts.removeAll()
        saveTranscriptsToDisk()
        print("✅ TranscriptManager: Cleared \(count) transcripts")
    }
}

// MARK: - Legacy Summary Data (for backward compatibility)

struct SummaryData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    let summary: String
    let tasks: [String]
    let reminders: [String]
    let createdAt: Date
    
    init(recordingURL: URL, recordingName: String, recordingDate: Date, summary: String, tasks: [String], reminders: [String]) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = summary
        self.tasks = tasks
        self.reminders = reminders
        self.createdAt = Date()
    }
    
    // Convert legacy data to enhanced format
    func toEnhanced(contentType: ContentType = .general, aiMethod: String = "Legacy", originalLength: Int = 0) -> EnhancedSummaryData {
        let taskItems = tasks.map { TaskItem(text: $0) }
        let reminderItems = reminders.map { 
            ReminderItem(text: $0, timeReference: ReminderItem.TimeReference(originalText: "No time specified"))
        }
        
        return EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: taskItems,
            reminders: reminderItems,
            contentType: contentType,
            aiMethod: aiMethod,
            originalLength: originalLength > 0 ? originalLength : summary.components(separatedBy: .whitespacesAndNewlines).count * 5 // Estimate
        )
    }
}

class SummaryManager: ObservableObject {
    @Published var summaries: [SummaryData] = []
    @Published var enhancedSummaries: [EnhancedSummaryData] = []
    
    private let summariesKey = "SavedSummaries"
    private let enhancedSummariesKey = "SavedEnhancedSummaries"
    
    init() {
        loadSummaries()
        loadEnhancedSummaries()
        initializeEngines()
    }
    
    // MARK: - Legacy Summary Methods (for backward compatibility)
    
    func saveSummary(_ summary: SummaryData) {
        DispatchQueue.main.async {
            self.summaries.append(summary)
            self.saveSummariesToDisk()
        }
    }
    
    func updateSummary(_ summary: SummaryData) {
        DispatchQueue.main.async {
            if let index = self.summaries.firstIndex(where: { $0.recordingURL == summary.recordingURL }) {
                self.summaries[index] = summary
                self.saveSummariesToDisk()
            }
        }
    }
    
    func getSummary(for recordingURL: URL) -> SummaryData? {
        return summaries.first { $0.recordingURL == recordingURL }
    }
    
    // MARK: - Enhanced Summary Methods
    
    func saveEnhancedSummary(_ summary: EnhancedSummaryData) {
        // Remove any existing enhanced summary for this recording
        enhancedSummaries.removeAll { $0.recordingURL == summary.recordingURL }
        enhancedSummaries.append(summary)
        saveEnhancedSummariesToDisk()
    }
    
    func updateEnhancedSummary(_ summary: EnhancedSummaryData) {
        DispatchQueue.main.async {
            if let index = self.enhancedSummaries.firstIndex(where: { $0.recordingURL == summary.recordingURL }) {
                self.enhancedSummaries[index] = summary
                self.saveEnhancedSummariesToDisk()
            } else {
                self.saveEnhancedSummary(summary)
            }
        }
    }
    
    func getEnhancedSummary(for recordingURL: URL) -> EnhancedSummaryData? {
        return enhancedSummaries.first { $0.recordingURL == recordingURL }
    }
    
    func hasEnhancedSummary(for recordingURL: URL) -> Bool {
        return enhancedSummaries.contains { $0.recordingURL == recordingURL }
    }
    
    // MARK: - Unified Methods (prefer enhanced, fallback to legacy)
    
    func hasSummary(for recordingURL: URL) -> Bool {
        return hasEnhancedSummary(for: recordingURL) || summaries.contains { $0.recordingURL == recordingURL }
    }
    
    func deleteSummary(for recordingURL: URL) {
        summaries.removeAll { $0.recordingURL == recordingURL }
        enhancedSummaries.removeAll { $0.recordingURL == recordingURL }
        saveSummariesToDisk()
        saveEnhancedSummariesToDisk()
    }
    
    func getBestAvailableSummary(for recordingURL: URL) -> EnhancedSummaryData? {
        // First try to get enhanced summary
        if let enhanced = getEnhancedSummary(for: recordingURL) {
            return enhanced
        }
        
        // Fallback to converting legacy summary
        if let legacy = getSummary(for: recordingURL) {
            return legacy.toEnhanced()
        }
        
        return nil
    }
    
    // MARK: - Migration Methods
    
    func migrateLegacySummary(for recordingURL: URL, contentType: ContentType = .general, aiMethod: String = "Legacy", originalLength: Int = 0) {
        guard let legacy = getSummary(for: recordingURL),
              !hasEnhancedSummary(for: recordingURL) else { return }
        
        let enhanced = legacy.toEnhanced(contentType: contentType, aiMethod: aiMethod, originalLength: originalLength)
        DispatchQueue.main.async {
            self.saveEnhancedSummary(enhanced)
        }
    }
    
    func migrateAllLegacySummaries() {
        for legacy in summaries {
            if !hasEnhancedSummary(for: legacy.recordingURL) {
                migrateLegacySummary(for: legacy.recordingURL)
            }
        }
    }
    
    // MARK: - Clear All Data
    
    func clearAllSummaries() {
        print("🧹 SummaryManager: Clearing all summaries...")
        
        let enhancedCount = enhancedSummaries.count
        let legacyCount = summaries.count
        
        enhancedSummaries.removeAll()
        summaries.removeAll()
        
        saveEnhancedSummariesToDisk()
        saveSummariesToDisk()
        
        print("✅ SummaryManager: Cleared \(enhancedCount) enhanced summaries and \(legacyCount) legacy summaries")
    }
    
    // MARK: - Enhanced Summarization Integration
    
    private var currentEngine: SummarizationEngine?
    private var availableEngines: [String: SummarizationEngine] = [:]
    private let taskExtractor = TaskExtractor()
    private let reminderExtractor = ReminderExtractor()
    private let transcriptManager = TranscriptManager()
    
    func initializeEngines() {
        // Initialize all engines using the factory
        for engineType in AIEngineType.allCases {
            let engine = AIEngineFactory.createEngine(type: engineType)
            availableEngines[engine.name] = engine
        }
        
        // Set default engine to Enhanced Apple Intelligence
        currentEngine = availableEngines["Enhanced Apple Intelligence"]
    }
    
    func setEngine(_ engineName: String) {
        if let engine = availableEngines[engineName] {
            currentEngine = engine
        }
    }
    
    func getAvailableEngines() -> [String] {
        return Array(availableEngines.keys).sorted()
    }
    
    func getCurrentEngineName() -> String {
        return currentEngine?.name ?? "None"
    }
    
    func getEngineInfo(for engineName: String) -> (description: String, isAvailable: Bool, version: String)? {
        guard let engine = availableEngines[engineName] else { return nil }
        return (engine.description, engine.isAvailable, engine.version)
    }
    
    func getAvailableEnginesOnly() -> [String] {
        return availableEngines.values
            .filter { $0.isAvailable }
            .map { $0.name }
            .sorted()
    }
    
    func getComingSoonEngines() -> [String] {
        return availableEngines.values
            .filter { !$0.isAvailable }
            .map { $0.name }
            .sorted()
    }
    
    // MARK: - Enhanced Summary Generation
    
    func generateEnhancedSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        guard let engine = currentEngine else {
            throw SummarizationError.aiServiceUnavailable(service: "No engine selected")
        }
        
        let startTime = Date()
        
        do {
            // Use the engine's complete processing method for efficiency
            let result = try await engine.processComplete(text: text)
            
            let processingTime = Date().timeIntervalSince(startTime)
            
            // Generate a descriptive name for the recording from the full transcript
            let generatedName = generateRecordingNameFromTranscript(text, contentType: result.contentType, tasks: result.tasks, reminders: result.reminders)
            
            // Update the recording file name if it's different
            if generatedName != recordingName {
                print("🏷️ Renaming recording from '\(recordingName)' to '\(generatedName)'")
                try await updateRecordingName(from: recordingName, to: generatedName, recordingURL: recordingURL)
                print("✅ Recording renamed successfully")
            }
            
            let enhancedSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: generatedName,
                recordingDate: recordingDate,
                summary: result.summary,
                tasks: result.tasks,
                reminders: result.reminders,
                contentType: result.contentType,
                aiMethod: engine.name,
                originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
                processingTime: processingTime
            )
            
            // Save the enhanced summary on the main thread
            await MainActor.run {
                saveEnhancedSummary(enhancedSummary)
            }
            
            return enhancedSummary
            
        } catch {
            // Fallback to basic processing if engine fails
            return try await generateFallbackSummary(from: text, for: recordingURL, recordingName: recordingName, recordingDate: recordingDate, originalError: error)
        }
    }
    
    private func generateFallbackSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date, originalError: Error) async throws -> EnhancedSummaryData {
        print("Primary engine failed, using fallback: \(originalError)")
        
        // Use basic processing as fallback
        let contentType = ContentAnalyzer.classifyContent(text)
        let summary = createBasicSummary(from: text, contentType: contentType)
        let tasks = taskExtractor.extractTasks(from: text)
        let reminders = reminderExtractor.extractReminders(from: text)
        
        // Generate a descriptive name for the recording from the full transcript
        let generatedName = generateRecordingNameFromTranscript(text, contentType: contentType, tasks: tasks, reminders: reminders)
        
        // Update the recording file name if it's different
        if generatedName != recordingName {
            print("🏷️ Fallback: Renaming recording from '\(recordingName)' to '\(generatedName)'")
            try await updateRecordingName(from: recordingName, to: generatedName, recordingURL: recordingURL)
            print("✅ Fallback: Recording renamed successfully")
        }
        
        let enhancedSummary = EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: generatedName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            contentType: contentType,
            aiMethod: "Fallback Processing",
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        )
        
        await MainActor.run {
            saveEnhancedSummary(enhancedSummary)
        }
        return enhancedSummary
    }
    
    private func createBasicSummary(from text: String, contentType: ContentType) -> String {
        let sentences = ContentAnalyzer.extractSentences(from: text)
        let scoredSentences = sentences.map { sentence in
            (sentence: sentence, score: ContentAnalyzer.calculateSentenceImportance(sentence, in: text))
        }
        
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { $0.sentence }
        
        let summary = topSentences.joined(separator: " ")
        return summary.isEmpty ? "No meaningful content found for summarization." : summary
    }
    
    // MARK: - Batch Processing
    
    func regenerateAllSummaries() async {
        let recordingsToProcess = enhancedSummaries.map { ($0.recordingURL, $0.recordingName, $0.recordingDate) }
        
        for (url, name, date) in recordingsToProcess {
            // Load transcript for this recording
            if let transcriptText = loadTranscriptText(for: url) {
                do {
                    _ = try await generateEnhancedSummary(from: transcriptText, for: url, recordingName: name, recordingDate: date)
                    print("Regenerated summary for: \(name)")
                } catch {
                    print("Failed to regenerate summary for \(name): \(error)")
                }
            }
        }
    }
    
    private func loadTranscriptText(for recordingURL: URL) -> String? {
        // This would need to integrate with TranscriptManager
        // For now, return nil as placeholder
        return nil
    }
    
    // MARK: - Recording Name Generation and Management
    
    private func generateRecordingNameFromTranscript(_ transcript: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem]) -> String {
        // Try different strategies to generate a good name from the full transcript
        let maxLength = 35
        
        // Strategy 1: Use the first task if it's high priority
        if let highPriorityTask = tasks.first(where: { $0.priority == .high }) {
            let taskName = generateNameFromTask(highPriorityTask, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 2: Use the first urgent reminder
        if let urgentReminder = reminders.first(where: { $0.urgency == .immediate || $0.urgency == .today }) {
            let reminderName = generateNameFromReminder(urgentReminder, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 3: Extract key phrases from the full transcript
        let transcriptName = generateNameFromTranscript(transcript, contentType: contentType, maxLength: maxLength)
        if !transcriptName.isEmpty {
            return transcriptName
        }
        
        // Strategy 4: Use content type with date
        return generateFallbackName(contentType: contentType, maxLength: maxLength)
    }
    
    private func generateRecordingName(from summary: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem]) -> String {
        // Try different strategies to generate a good name
        let maxLength = 35
        
        // Strategy 1: Use the first task if it's high priority
        if let highPriorityTask = tasks.first(where: { $0.priority == .high }) {
            let taskName = generateNameFromTask(highPriorityTask, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 2: Use the first urgent reminder
        if let urgentReminder = reminders.first(where: { $0.urgency == .immediate || $0.urgency == .today }) {
            let reminderName = generateNameFromReminder(urgentReminder, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 3: Extract key phrases from summary
        let summaryName = generateNameFromSummary(summary, contentType: contentType, maxLength: maxLength)
        if !summaryName.isEmpty {
            return summaryName
        }
        
        // Strategy 4: Use content type with date
        return generateFallbackName(contentType: contentType, maxLength: maxLength)
    }
    
    private func generateNameFromTask(_ task: TaskItem, maxLength: Int) -> String {
        let taskText = task.text.lowercased()
        
        // Extract action and object
        let actionKeywords = ["call", "email", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come", "take", "bring", "send", "schedule", "book", "order", "pick up", "drop off", "return", "check", "review", "update"]
        
        for action in actionKeywords {
            if taskText.contains(action) {
                // Find the object after the action
                if let actionRange = taskText.range(of: action) {
                    let afterAction = String(taskText[actionRange.upperBound...])
                    let words = afterAction.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    
                    if let firstWord = words.first {
                        let name = "\(action.capitalized) \(firstWord.capitalized)"
                        return name.count <= maxLength ? name : String(name.prefix(maxLength))
                    } else {
                        let name = action.capitalized
                        return name.count <= maxLength ? name : String(name.prefix(maxLength))
                    }
                }
            }
        }
        
        // If no action found, use first few words
        let words = taskText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if let firstWord = words.first, let secondWord = words.dropFirst().first {
            let name = "\(firstWord.capitalized) \(secondWord.capitalized)"
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        } else if let firstWord = words.first {
            let name = firstWord.capitalized
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        }
        
        return ""
    }
    
    private func generateNameFromReminder(_ reminder: ReminderItem, maxLength: Int) -> String {
        let reminderText = reminder.text.lowercased()
        
        // Look for appointment, meeting, deadline keywords
        let eventKeywords = ["appointment", "meeting", "deadline", "call", "email", "visit", "check"]
        
        for event in eventKeywords {
            if reminderText.contains(event) {
                let name = event.capitalized
                return name.count <= maxLength ? name : String(name.prefix(maxLength))
            }
        }
        
        // Use first few words
        let words = reminderText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if let firstWord = words.first, let secondWord = words.dropFirst().first {
            let name = "\(firstWord.capitalized) \(secondWord.capitalized)"
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        } else if let firstWord = words.first {
            let name = firstWord.capitalized
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        }
        
        return ""
    }
    
    private func generateNameFromTranscript(_ transcript: String, contentType: ContentType, maxLength: Int) -> String {
        // Use advanced NLP to extract meaningful titles from the full transcript
        let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !sentences.isEmpty else { return "" }
        
        // Strategy 1: Look for meeting/event titles in the first few sentences
        let titleKeywords = ["meeting about", "discussion on", "call about", "talk about", "conversation about", "presentation on", "review of", "planning for", "discussion of"]
        
        for sentence in sentences.prefix(3) {
            let lowerSentence = sentence.lowercased()
            for keyword in titleKeywords {
                if let range = lowerSentence.range(of: keyword) {
                    let afterKeyword = String(sentence[range.upperBound...])
                    let words = afterKeyword.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let firstWord = words.first, let secondWord = words.dropFirst().first {
                        let title = "\(firstWord.capitalized) \(secondWord.capitalized)"
                        if title.count <= maxLength {
                            return title
                        }
                    }
                }
            }
        }
        
        // Strategy 2: Extract key phrases using NLP techniques
        let keyPhrases = extractKeyPhrasesFromTranscript(transcript, maxPhrases: 3)
        if let bestPhrase = keyPhrases.first {
            let words = bestPhrase.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let keyWords = words.prefix(3).map { $0.capitalized }
            let title = keyWords.joined(separator: " ")
            if title.count <= maxLength {
                return title
            } else {
                let shortTitle = keyWords.prefix(2).joined(separator: " ")
                return shortTitle.count <= maxLength ? shortTitle : String(shortTitle.prefix(maxLength))
            }
        }
        
        // Strategy 3: Use the most important sentence from the transcript
        let scoredSentences = sentences.map { sentence in
            (sentence: sentence, score: calculateSentenceImportance(sentence, in: transcript))
        }
        
        if let bestSentence = scoredSentences.max(by: { $0.score < $1.score }) {
            let words = bestSentence.sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let keyWords = words.prefix(3).map { $0.capitalized }
            let title = keyWords.joined(separator: " ")
            if title.count <= maxLength {
                return title
            } else {
                let shortTitle = keyWords.prefix(2).joined(separator: " ")
                return shortTitle.count <= maxLength ? shortTitle : String(shortTitle.prefix(maxLength))
            }
        }
        
        return ""
    }
    
    private func generateNameFromSummary(_ summary: String, contentType: ContentType, maxLength: Int) -> String {
        let sentences = summary.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        guard let firstSentence = sentences.first else { return "" }
        
        let words = firstSentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // Try to find key nouns and verbs
        let keyWords = words.prefix(4).map { $0.capitalized }
        let name = keyWords.joined(separator: " ")
        
        if name.count <= maxLength {
            return name
        } else {
            // Try with fewer words
            let shortName = keyWords.prefix(2).joined(separator: " ")
            return shortName.count <= maxLength ? shortName : String(shortName.prefix(maxLength))
        }
    }
    
    // MARK: - Helper Functions for Title Generation
    
    private func extractKeyPhrasesFromTranscript(_ transcript: String, maxPhrases: Int) -> [String] {
        // Use ContentAnalyzer to extract key phrases
        return ContentAnalyzer.extractKeyPhrases(from: transcript, maxPhrases: maxPhrases)
    }
    
    private func calculateSentenceImportance(_ sentence: String, in transcript: String) -> Double {
        // Use ContentAnalyzer to calculate sentence importance
        return ContentAnalyzer.calculateSentenceImportance(sentence, in: transcript)
    }
    
    private func generateFallbackName(contentType: ContentType, maxLength: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let dateString = formatter.string(from: Date())
        
        let typeString: String
        switch contentType {
        case .meeting: typeString = "Meeting"
        case .personalJournal: typeString = "Journal"
        case .technical: typeString = "Tech"
        case .general: typeString = "Note"
        }
        
        let name = "\(typeString) \(dateString)"
        return name.count <= maxLength ? name : String(name.prefix(maxLength))
    }
    
    private func updateRecordingName(from oldName: String, to newName: String, recordingURL: URL) async throws {
        print("📁 Starting file rename process:")
        print("📁 Old name: \(oldName)")
        print("📁 New name: \(newName)")
        print("📁 Recording URL: \(recordingURL)")
        
        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        // Update the main recording file - check for different audio formats
        let audioExtensions = ["m4a", "mp3", "wav"]
        var oldRecordingURL: URL?
        var newRecordingURL: URL?
        
        for ext in audioExtensions {
            let testURL = documentsPath.appendingPathComponent("\(oldName).\(ext)")
            if fileManager.fileExists(atPath: testURL.path) {
                oldRecordingURL = testURL
                newRecordingURL = documentsPath.appendingPathComponent("\(newName).\(ext)")
                break
            }
        }
        
        if let oldURL = oldRecordingURL, let newURL = newRecordingURL, fileManager.fileExists(atPath: oldURL.path) {
            print("📁 Renaming audio file: \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
            try fileManager.moveItem(at: oldURL, to: newURL)
            print("✅ Audio file renamed successfully")
        }
        
        // Update location file if it exists
        let oldLocationURL = documentsPath.appendingPathComponent("\(oldName).location")
        let newLocationURL = documentsPath.appendingPathComponent("\(newName).location")
        
        if fileManager.fileExists(atPath: oldLocationURL.path) {
            try fileManager.moveItem(at: oldLocationURL, to: newLocationURL)
        }
        
        // Update transcript file if it exists
        let oldTranscriptURL = documentsPath.appendingPathComponent("\(oldName).transcript")
        let newTranscriptURL = documentsPath.appendingPathComponent("\(newName).transcript")
        
        if fileManager.fileExists(atPath: oldTranscriptURL.path) {
            try fileManager.moveItem(at: oldTranscriptURL, to: newTranscriptURL)
        }
        
        // Update summary file if it exists
        let oldSummaryURL = documentsPath.appendingPathComponent("\(oldName).summary")
        let newSummaryURL = documentsPath.appendingPathComponent("\(newName).summary")
        
        if fileManager.fileExists(atPath: oldSummaryURL.path) {
            try fileManager.moveItem(at: oldSummaryURL, to: newSummaryURL)
        }
        
        // Update transcript manager if needed
        if let newURL = newRecordingURL {
            await updateTranscriptManagerURL(from: recordingURL, to: newURL)
            // Also update pending transcription jobs
            await updatePendingTranscriptionJobs(from: recordingURL, to: newURL, newName: newName)
        }
    }
    
    private func updateTranscriptManagerURL(from oldURL: URL, to newURL: URL) async {
        // Update transcript manager with new URL
        transcriptManager.updateRecordingURL(from: oldURL, to: newURL)
    }
    
    private func updatePendingTranscriptionJobs(from oldURL: URL, to newURL: URL, newName: String) async {
        // Update any pending transcription jobs with the new URL and name
        // For now, we'll use a notification approach, but this could be improved
        // by injecting the transcription manager as a dependency
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("UpdatePendingTranscriptionJobs"),
                object: nil,
                userInfo: [
                    "oldURL": oldURL,
                    "newURL": newURL,
                    "newName": newName
                ]
            )
        }
    }
    
    // MARK: - Error Handling and Recovery
    
    func validateSummary(_ summary: EnhancedSummaryData) -> [String] {
        var issues: [String] = []
        
        if summary.summary.isEmpty {
            issues.append("Summary is empty")
        }
        
        if summary.summary.count < 50 {
            issues.append("Summary is very short (less than 50 characters)")
        }
        
        if summary.confidence < 0.3 {
            issues.append("Low confidence score (\(String(format: "%.1f", summary.confidence * 100))%)")
        }
        
        if summary.tasks.isEmpty && summary.reminders.isEmpty {
            issues.append("No tasks or reminders extracted")
        }
        
        return issues
    }
    
    func getSummaryStatistics() -> SummaryStatistics {
        let totalSummaries = enhancedSummaries.count
        let averageConfidence = enhancedSummaries.isEmpty ? 0.0 : enhancedSummaries.map { $0.confidence }.reduce(0, +) / Double(totalSummaries)
        let averageCompressionRatio = enhancedSummaries.isEmpty ? 0.0 : enhancedSummaries.map { $0.compressionRatio }.reduce(0, +) / Double(totalSummaries)
        let totalTasks = enhancedSummaries.reduce(0) { $0 + $1.tasks.count }
        let totalReminders = enhancedSummaries.reduce(0) { $0 + $1.reminders.count }
        
        let engineUsage = Dictionary(grouping: enhancedSummaries, by: { $0.aiMethod })
            .mapValues { $0.count }
        
        return SummaryStatistics(
            totalSummaries: totalSummaries,
            averageConfidence: averageConfidence,
            averageCompressionRatio: averageCompressionRatio,
            totalTasks: totalTasks,
            totalReminders: totalReminders,
            engineUsage: engineUsage
        )
    }
    
    // MARK: - Persistence
    
    private func saveSummariesToDisk() {
        do {
            let data = try JSONEncoder().encode(summaries)
            UserDefaults.standard.set(data, forKey: summariesKey)
        } catch {
            print("Failed to save summaries: \(error)")
        }
    }
    
    private func loadSummaries() {
        guard let data = UserDefaults.standard.data(forKey: summariesKey) else { return }
        do {
            summaries = try JSONDecoder().decode([SummaryData].self, from: data)
        } catch {
            print("Failed to load summaries: \(error)")
        }
    }
    
    private func saveEnhancedSummariesToDisk() {
        do {
            let data = try JSONEncoder().encode(enhancedSummaries)
            UserDefaults.standard.set(data, forKey: enhancedSummariesKey)
        } catch {
            print("Failed to save enhanced summaries: \(error)")
        }
    }
    
    private func loadEnhancedSummaries() {
        guard let data = UserDefaults.standard.data(forKey: enhancedSummariesKey) else { return }
        do {
            enhancedSummaries = try JSONDecoder().decode([EnhancedSummaryData].self, from: data)
        } catch {
            print("Failed to load enhanced summaries: \(error)")
        }
    }
} 

// MARK: - Enhanced Summarization Models (from SummarizationModels.swift)

enum ContentType: String, CaseIterable, Codable {
    case meeting = "Meeting"
    case personalJournal = "Personal Journal"
    case technical = "Technical"
    case general = "General"
    
    var description: String {
        switch self {
        case .meeting:
            return "Meeting or conversation with multiple participants"
        case .personalJournal:
            return "Personal thoughts, experiences, and reflections"
        case .technical:
            return "Technical discussions, documentation, or instructions"
        case .general:
            return "General content that doesn't fit other categories"
        }
    }
}

struct TaskItem: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let text: String
    let priority: Priority
    let timeReference: String?
    let category: TaskCategory
    let confidence: Double
    
    init(text: String, priority: Priority = .medium, timeReference: String? = nil, category: TaskCategory = .general, confidence: Double = 0.5) {
        self.id = UUID()
        self.text = text
        self.priority = priority
        self.timeReference = timeReference
        self.category = category
        self.confidence = confidence
    }
    
    enum Priority: String, CaseIterable, Codable {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
        
        var color: String {
            switch self {
            case .high: return "red"
            case .medium: return "orange"
            case .low: return "green"
            }
        }
        
        var sortOrder: Int {
            switch self {
            case .high: return 0
            case .medium: return 1
            case .low: return 2
            }
        }
    }
    
    enum TaskCategory: String, CaseIterable, Codable {
        case call = "Call"
        case meeting = "Meeting"
        case purchase = "Purchase"
        case research = "Research"
        case email = "Email"
        case travel = "Travel"
        case health = "Health"
        case general = "General"
        
        var icon: String {
            switch self {
            case .call: return "phone"
            case .meeting: return "calendar"
            case .purchase: return "cart"
            case .research: return "magnifyingglass"
            case .email: return "envelope"
            case .travel: return "airplane"
            case .health: return "heart"
            case .general: return "checkmark.circle"
            }
        }
    }
    
    var displayText: String {
        if let timeRef = timeReference {
            return "\(text) (\(timeRef))"
        }
        return text
    }
}

struct ReminderItem: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let text: String
    let timeReference: TimeReference
    let urgency: Urgency
    let confidence: Double
    
    init(text: String, timeReference: TimeReference, urgency: Urgency = .later, confidence: Double = 0.5) {
        self.id = UUID()
        self.text = text
        self.timeReference = timeReference
        self.urgency = urgency
        self.confidence = confidence
    }
    
    struct TimeReference: Codable, Equatable, Hashable {
        let originalText: String
        let parsedDate: Date?
        let relativeTime: String?
        let isSpecific: Bool
        
        init(originalText: String, parsedDate: Date? = nil, relativeTime: String? = nil) {
            self.originalText = originalText
            self.parsedDate = parsedDate
            self.relativeTime = relativeTime
            self.isSpecific = parsedDate != nil
        }
        
        var displayText: String {
            if let relative = relativeTime {
                return relative
            }
            if let date = parsedDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return formatter.string(from: date)
            }
            return originalText
        }
    }
    
    enum Urgency: String, CaseIterable, Codable {
        case immediate = "Immediate"
        case today = "Today"
        case thisWeek = "This Week"
        case later = "Later"
        
        var color: String {
            switch self {
            case .immediate: return "red"
            case .today: return "orange"
            case .thisWeek: return "yellow"
            case .later: return "blue"
            }
        }
        
        var sortOrder: Int {
            switch self {
            case .immediate: return 0
            case .today: return 1
            case .thisWeek: return 2
            case .later: return 3
            }
        }
        
        var icon: String {
            switch self {
            case .immediate: return "exclamationmark.triangle.fill"
            case .today: return "clock.fill"
            case .thisWeek: return "calendar"
            case .later: return "clock"
            }
        }
    }
    
    var displayText: String {
        return "\(text) - \(timeReference.displayText)"
    }
}

struct EnhancedSummaryData: Codable, Identifiable {
    let id: UUID
    let recordingURL: URL
    let recordingName: String
    let recordingDate: Date
    
    // Core content
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    
    // Metadata
    let contentType: ContentType
    let aiMethod: String
    let generatedAt: Date
    let version: Int
    let wordCount: Int
    let originalLength: Int
    let compressionRatio: Double
    
    // Quality metrics
    let confidence: Double
    let processingTime: TimeInterval
    
    init(recordingURL: URL, recordingName: String, recordingDate: Date, summary: String, tasks: [TaskItem] = [], reminders: [ReminderItem] = [], contentType: ContentType = .general, aiMethod: String, originalLength: Int, processingTime: TimeInterval = 0) {
        self.id = UUID()
        self.recordingURL = recordingURL
        self.recordingName = recordingName
        self.recordingDate = recordingDate
        self.summary = summary
        self.tasks = tasks.sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        self.reminders = reminders.sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        self.contentType = contentType
        self.aiMethod = aiMethod
        self.generatedAt = Date()
        self.version = 1
        self.wordCount = summary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        self.originalLength = originalLength
        self.compressionRatio = originalLength > 0 ? Double(self.wordCount) / Double(originalLength) : 0.0
        self.processingTime = processingTime
        
        // Calculate confidence after all properties are initialized
        let taskConfidence = tasks.isEmpty ? 0.5 : tasks.map { $0.confidence }.reduce(0, +) / Double(tasks.count)
        let reminderConfidence = reminders.isEmpty ? 0.5 : reminders.map { $0.confidence }.reduce(0, +) / Double(reminders.count)
        self.confidence = (taskConfidence + reminderConfidence) / 2.0
    }
    

    
    var formattedCompressionRatio: String {
        return String(format: "%.1f%%", compressionRatio * 100)
    }
    
    var formattedProcessingTime: String {
        return String(format: "%.1fs", processingTime)
    }
    
    var qualityDescription: String {
        switch confidence {
        case 0.8...1.0: return "High Quality"
        case 0.6..<0.8: return "Good Quality"
        case 0.4..<0.6: return "Fair Quality"
        default: return "Low Quality"
        }
    }
}

// MARK: - Summarization Engine Protocol

protocol SummarizationEngine {
    var name: String { get }
    var description: String { get }
    var isAvailable: Bool { get }
    var version: String { get }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String
    func extractTasks(from text: String) async throws -> [TaskItem]
    func extractReminders(from text: String) async throws -> [ReminderItem]
    func classifyContent(_ text: String) async throws -> ContentType
    
    // Optional: Full processing in one call for efficiency
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType)
}

// MARK: - Summarization Errors

enum SummarizationError: Error, LocalizedError {
    case transcriptTooShort
    case transcriptTooLong(maxLength: Int)
    case aiServiceUnavailable(service: String)
    case processingTimeout
    case insufficientContent
    case networkError(underlying: Error)
    case quotaExceeded
    case invalidInput
    case processingFailed(reason: String)
    
    var errorDescription: String? {
        switch self {
        case .transcriptTooShort:
            return "Transcript is too short to summarize effectively (minimum 50 words required)"
        case .transcriptTooLong(let maxLength):
            return "Transcript exceeds maximum length of \(maxLength) words for processing"
        case .aiServiceUnavailable(let service):
            return "\(service) is currently unavailable. Please try again later."
        case .processingTimeout:
            return "Summarization took too long and was cancelled. Try with a shorter recording."
        case .insufficientContent:
            return "Not enough meaningful content found for summarization"
        case .networkError(let underlying):
            return "Network error occurred: \(underlying.localizedDescription)"
        case .quotaExceeded:
            return "AI service quota exceeded. Please try again later."
        case .invalidInput:
            return "Invalid input provided for summarization"
        case .processingFailed(let reason):
            return "Summarization failed: \(reason)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .transcriptTooShort:
            return "Try recording a longer audio clip with more content."
        case .transcriptTooLong:
            return "Try breaking the recording into smaller segments."
        case .aiServiceUnavailable:
            return "Switch to a different AI method in settings or try again later."
        case .processingTimeout:
            return "Try with a shorter recording or check your internet connection."
        case .insufficientContent:
            return "Ensure your recording contains clear speech with actionable content."
        case .networkError:
            return "Check your internet connection and try again."
        case .quotaExceeded:
            return "Wait a few minutes before trying again, or switch to a different AI method."
        case .invalidInput:
            return "Please ensure the recording was transcribed properly."
        case .processingFailed:
            return "Try regenerating the summary or switch to a different AI method."
        }
    }
}

// MARK: - Processing Configuration

struct SummarizationConfig {
    let maxSummaryLength: Int
    let maxTasks: Int
    let maxReminders: Int
    let minConfidenceThreshold: Double
    let timeoutInterval: TimeInterval
    let enableParallelProcessing: Bool
    
    static let `default` = SummarizationConfig(
        maxSummaryLength: 500,
        maxTasks: 5,
        maxReminders: 5,
        minConfidenceThreshold: 0.7,
        timeoutInterval: 30.0,
        enableParallelProcessing: true
    )
    
    static let conservative = SummarizationConfig(
        maxSummaryLength: 300,
        maxTasks: 5,
        maxReminders: 5,
        minConfidenceThreshold: 0.5,
        timeoutInterval: 15.0,
        enableParallelProcessing: false
    )
}
// MARK: - Supporting Structures

struct SummaryStatistics {
    let totalSummaries: Int
    let averageConfidence: Double
    let averageCompressionRatio: Double
    let totalTasks: Int
    let totalReminders: Int
    let engineUsage: [String: Int]
    
    var formattedAverageConfidence: String {
        return String(format: "%.1f%%", averageConfidence * 100)
    }
    
    var formattedAverageCompressionRatio: String {
        return String(format: "%.1f%%", averageCompressionRatio * 100)
    }
}

// MARK: - Placeholder Engine for Future Implementation

class PlaceholderEngine: SummarizationEngine {
    let name: String
    let description: String
    let isAvailable: Bool = false
    let version: String = "1.0"
    
    init(name: String, description: String) {
        self.name = name
        self.description = description
    }
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        throw SummarizationError.aiServiceUnavailable(service: name)
    }
}