import Foundation

class SummaryManager: ObservableObject {
    @Published var summaries: [SummaryData] = []
    @Published var enhancedSummaries: [EnhancedSummaryData] = []
    
    private let summariesKey = "SavedSummaries"
    private let enhancedSummariesKey = "SavedEnhancedSummaries"
    
    // MARK: - Enhanced Summarization Integration
    
    private var currentEngine: SummarizationEngine?
    private var availableEngines: [String: SummarizationEngine] = [:]
    // TODO: Implement when extractors are available
    // private let taskExtractor = TaskExtractor()
    // private let reminderExtractor = ReminderExtractor()
    private let transcriptManager = TranscriptManager.shared
    
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
        DispatchQueue.main.async {
            print("💾 SummaryManager: Saving enhanced summary for \(summary.recordingName)")
            
            // Remove any existing enhanced summary for this recording
            self.enhancedSummaries.removeAll { $0.recordingURL == summary.recordingURL }
            self.enhancedSummaries.append(summary)
            self.saveEnhancedSummariesToDisk()
            
            print("💾 SummaryManager: Enhanced summary saved. Total summaries: \(self.enhancedSummaries.count)")
            print("🔍 SummaryManager: Can find summary: \(self.hasSummary(for: summary.recordingURL))")
            
            // Force a UI update
            self.objectWillChange.send()
        }
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
        let result = enhancedSummaries.contains { $0.recordingURL == recordingURL }
        print("🔍 SummaryManager: hasEnhancedSummary for \(recordingURL) = \(result)")
        return result
    }
    
    // MARK: - Unified Methods (prefer enhanced, fallback to legacy)
    
    func hasSummary(for recordingURL: URL) -> Bool {
        let hasEnhanced = hasEnhancedSummary(for: recordingURL)
        let hasLegacy = summaries.contains { $0.recordingURL == recordingURL }
        
        let result = hasEnhanced || hasLegacy
        print("🔍 SummaryManager: hasSummary for \(recordingURL.lastPathComponent) = \(result) (enhanced: \(hasEnhanced), legacy: \(hasLegacy))")
        
        return result
    }
    
    func deleteSummary(for recordingURL: URL) {
        DispatchQueue.main.async {
            self.summaries.removeAll { $0.recordingURL == recordingURL }
            self.enhancedSummaries.removeAll { $0.recordingURL == recordingURL }
            self.saveSummariesToDisk()
            self.saveEnhancedSummariesToDisk()
        }
    }
    
    func getBestAvailableSummary(for recordingURL: URL) -> EnhancedSummaryData? {
        // First try to get enhanced summary
        if let enhanced = getEnhancedSummary(for: recordingURL) {
            return enhanced
        }
        
        // Fallback to converting legacy summary
        if let legacy = getSummary(for: recordingURL) {
            return convertLegacyToEnhanced(legacy)
        }
        
        return nil
    }
    
    // MARK: - Migration Methods
    
    func migrateLegacySummary(for recordingURL: URL, contentType: ContentType = .general, aiMethod: String = "Legacy", originalLength: Int = 0) {
        guard let legacy = getSummary(for: recordingURL),
              !hasEnhancedSummary(for: recordingURL) else { return }
        
        let enhanced = convertLegacyToEnhanced(legacy, contentType: contentType, aiMethod: aiMethod, originalLength: originalLength)
        DispatchQueue.main.async {
            self.saveEnhancedSummary(enhanced)
        }
    }
    
    // MARK: - Legacy Conversion
    
    func convertLegacyToEnhanced(_ legacy: SummaryData, contentType: ContentType = .general, aiMethod: String = "Legacy", originalLength: Int = 0) -> EnhancedSummaryData {
        let taskItems = legacy.tasks.map { TaskItem(text: $0) }
        let reminderItems = legacy.reminders.map { 
            ReminderItem(text: $0, timeReference: ReminderItem.TimeReference(originalText: "No time specified"))
        }
        
        return EnhancedSummaryData(
            recordingURL: legacy.recordingURL,
            recordingName: legacy.recordingName,
            recordingDate: legacy.recordingDate,
            summary: legacy.summary,
            tasks: taskItems,
            reminders: reminderItems,
            contentType: contentType,
            aiMethod: aiMethod,
            originalLength: originalLength > 0 ? originalLength : legacy.summary.components(separatedBy: .whitespacesAndNewlines).count * 5 // Estimate
        )
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
        
        DispatchQueue.main.async {
            self.enhancedSummaries.removeAll()
            self.summaries.removeAll()
            
            self.saveEnhancedSummariesToDisk()
            self.saveSummariesToDisk()
            
            print("✅ SummaryManager: Cleared \(enhancedCount) enhanced summaries and \(legacyCount) legacy summaries")
        }
    }
    
    // MARK: - Engine Management
    
    func initializeEngines() {
        print("🔧 SummaryManager: Initializing AI engines using AIEngineFactory...")
        
        // Clear any existing engines
        availableEngines.removeAll()
        
        // Get all engine types from the factory
        let allEngineTypes = AIEngineFactory.getAllEngines()
        var successfullyInitialized = 0
        
        for engineType in allEngineTypes {
            print("🔧 SummaryManager: Initializing \(engineType.rawValue)...")
            
            // Create engine using the factory
            let engine = AIEngineFactory.createEngine(type: engineType)
            
            availableEngines[engine.name] = engine
            
            print("✅ SummaryManager: Successfully initialized \(engine.name) (Available: \(engine.isAvailable))")
            successfullyInitialized += 1
            
            // Set the first available engine as the current engine
            if currentEngine == nil && engine.isAvailable {
                currentEngine = engine
                print("🎯 SummaryManager: Set \(engine.name) as default engine")
            }
        }
        
        // Log initialization summary
        print("🔧 SummaryManager: Engine initialization complete")
        print("✅ Successfully initialized: \(successfullyInitialized)/\(allEngineTypes.count) engines")
        print("📋 Available engines: \(getAvailableEnginesOnly())")
        print("🚧 Coming soon engines: \(getComingSoonEngines())")
        
        // Try to restore the previously selected engine from UserDefaults
        if let savedEngineName = UserDefaults.standard.string(forKey: "selectedAIEngine"),
           let savedEngine = availableEngines[savedEngineName],
           savedEngine.isAvailable {
            currentEngine = savedEngine
            print("🔄 SummaryManager: Restored previously selected engine: \(savedEngine.name)")
        }
        
        // Ensure we have at least one working engine
        if currentEngine == nil {
            print("⚠️ SummaryManager: No available engines found, falling back to Enhanced Apple Intelligence")
            // Force create Enhanced Apple Intelligence as fallback using factory
            let fallbackEngine = AIEngineFactory.createEngine(type: .enhancedAppleIntelligence)
            availableEngines[fallbackEngine.name] = fallbackEngine
            currentEngine = fallbackEngine
            print("🎯 SummaryManager: Set \(fallbackEngine.name) as fallback engine")
        }
        
        print("🎯 SummaryManager: Current active engine: \(getCurrentEngineName())")
    }
    
    func setEngine(_ engineName: String) {
        print("🔧 SummaryManager: Setting engine to '\(engineName)'")
        
        // Validate the engine using the new validation method
        let validation = validateEngineAvailability(engineName)
        
        guard validation.isValid else {
            print("❌ SummaryManager: \(validation.errorMessage ?? "Invalid engine")")
            return
        }
        
        guard validation.isAvailable else {
            print("❌ SummaryManager: \(validation.errorMessage ?? "Engine not available")")
            return
        }
        
        // Get or create the engine
        var targetEngine: SummarizationEngine?
        
        if let existingEngine = availableEngines[engineName] {
            targetEngine = existingEngine
            print("🔍 SummaryManager: Using existing engine '\(engineName)'")
        } else {
            // Create the engine using the factory
            if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) {
                print("🔧 SummaryManager: Creating new engine '\(engineName)' using factory")
                let newEngine = AIEngineFactory.createEngine(type: engineType)
                availableEngines[newEngine.name] = newEngine
                targetEngine = newEngine
            }
        }
        
        // Set the engine if we have one and it's available
        if let engine = targetEngine, engine.isAvailable {
            currentEngine = engine
            print("✅ SummaryManager: Engine set successfully to '\(engine.name)'")
            
            // Save the selected engine to UserDefaults for persistence
            UserDefaults.standard.set(engineName, forKey: "selectedAIEngine")
            
            // Notify observers of the engine change
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } else {
            print("❌ SummaryManager: Failed to set engine '\(engineName)' - engine not available")
            if let engine = targetEngine {
                print("🔍 Engine details: \(engine.description) (Available: \(engine.isAvailable))")
            }
        }
    }
    
    func updateEngineConfiguration(_ engineName: String) {
        print("🔧 SummaryManager: Updating configuration for engine '\(engineName)'")
        
        // Find the engine type for the given name
        guard let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) else {
            print("❌ SummaryManager: Unknown engine type for '\(engineName)'")
            return
        }
        
        // Recreate the engine with updated configuration using the factory
        let updatedEngine = AIEngineFactory.createEngine(type: engineType)
        availableEngines[updatedEngine.name] = updatedEngine
        
        // If this was the current engine, update the reference
        if currentEngine?.name == engineName {
            currentEngine = updatedEngine
            print("🎯 SummaryManager: Updated current engine configuration for '\(engineName)'")
        }
        
        print("✅ SummaryManager: Engine configuration updated for '\(engineName)' (Available: \(updatedEngine.isAvailable))")
    }
    
    func getAvailableEngines() -> [String] {
        return Array(availableEngines.keys).sorted()
    }
    
    // MARK: - Engine Validation and Status
    
    func validateEngineAvailability(_ engineName: String) -> (isValid: Bool, isAvailable: Bool, errorMessage: String?) {
        // Check if engine name is valid
        guard !engineName.isEmpty else {
            return (false, false, "Engine name cannot be empty")
        }
        
        // Check if engine type exists
        guard AIEngineType.allCases.contains(where: { $0.rawValue == engineName }) else {
            let validEngines = AIEngineType.allCases.map { $0.rawValue }.sorted().joined(separator: ", ")
            return (false, false, "Unknown engine type '\(engineName)'. Valid engines: \(validEngines)")
        }
        
        // Check if engine is initialized
        if let engine = availableEngines[engineName] {
            if engine.isAvailable {
                return (true, true, nil)
            } else {
                let engineType = AIEngineType.allCases.first { $0.rawValue == engineName }
                let requirements = engineType?.requirements.joined(separator: ", ") ?? "Unknown requirements"
                return (true, false, "Engine '\(engineName)' is not available. Requirements: \(requirements)")
            }
        } else {
            // Engine not initialized, try to create it
            if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) {
                let testEngine = AIEngineFactory.createEngine(type: engineType)
                if testEngine.isAvailable {
                    return (true, true, nil)
                } else {
                    let requirements = engineType.requirements.joined(separator: ", ")
                    return (true, false, "Engine '\(engineName)' is not available. Requirements: \(requirements)")
                }
            }
        }
        
        return (false, false, "Unknown error validating engine '\(engineName)'")
    }
    
    func getEngineStatus() -> [String: Any] {
        let currentEngineName = getCurrentEngineName()
        let availableEngineNames = getAvailableEnginesOnly()
        let allEngineNames = AIEngineType.allCases.map { $0.rawValue }
        
        return [
            "currentEngine": currentEngineName,
            "availableEngines": availableEngineNames,
            "allEngines": allEngineNames,
            "totalInitialized": availableEngines.count,
            "totalAvailable": availableEngineNames.count
        ]
    }
    
    // MARK: - Engine Type Management
    
    func getAllEngineTypes() -> [AIEngineType] {
        return AIEngineFactory.getAllEngines()
    }
    
    func getAvailableEngineTypes() -> [AIEngineType] {
        return AIEngineFactory.getAvailableEngines()
    }
    
    func getEngineTypeInfo(for engineType: AIEngineType) -> (description: String, requirements: [String], isComingSoon: Bool) {
        return (engineType.description, engineType.requirements, engineType.isComingSoon)
    }
    
    func isEngineTypeAvailable(_ engineType: AIEngineType) -> Bool {
        let engine = AIEngineFactory.createEngine(type: engineType)
        return engine.isAvailable
    }
    
    func getCurrentEngineName() -> String {
        guard let engine = currentEngine else {
            print("⚠️ SummaryManager: No current engine set")
            return "None"
        }
        
        // Verify the engine is still available
        if !engine.isAvailable {
            print("⚠️ SummaryManager: Current engine '\(engine.name)' is no longer available")
            // Try to find an available fallback engine
            if let fallbackEngine = availableEngines.values.first(where: { $0.isAvailable }) {
                print("🔄 SummaryManager: Switching to fallback engine '\(fallbackEngine.name)'")
                currentEngine = fallbackEngine
                UserDefaults.standard.set(fallbackEngine.name, forKey: "selectedAIEngine")
                return fallbackEngine.name
            }
        }
        
        return engine.name
    }
    
    func getEngineInfo(for engineName: String) -> (description: String, isAvailable: Bool, version: String)? {
        // First try to get from initialized engines
        if let engine = availableEngines[engineName] {
            return (engine.description, engine.isAvailable, engine.version)
        }
        
        // If not found, try to create using factory to get info
        if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) {
            let engine = AIEngineFactory.createEngine(type: engineType)
            return (engine.description, engine.isAvailable, engine.version)
        }
        
        return nil
    }
    
    func getAvailableEnginesOnly() -> [String] {
        // Use factory to get available engines and filter by actual availability
        return AIEngineFactory.getAvailableEngines()
            .map { $0.rawValue }
            .sorted()
    }
    
    func getComingSoonEngines() -> [String] {
        // Get all engines and filter out the available ones to find coming soon engines
        let availableEngineNames = Set(getAvailableEnginesOnly())
        return AIEngineFactory.getAllEngines()
            .map { $0.rawValue }
            .filter { !availableEngineNames.contains($0) }
            .sorted()
    }
    
    // MARK: - Enhanced Summary Generation
    
    func generateEnhancedSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        print("🤖 SummaryManager: Using basic summarization (engine system not fully implemented)")
        
        let startTime = Date()
        
        // Use basic processing for now
        let contentType = ContentType.general
        let summary = createBasicSummary(from: text, contentType: contentType)
        let tasks: [TaskItem] = []
        let reminders: [ReminderItem] = []
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        let enhancedSummary = EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            contentType: contentType,
            aiMethod: "Basic Processing",
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: processingTime
        )
        
        // Save the enhanced summary on the main thread
        await MainActor.run {
            saveEnhancedSummary(enhancedSummary)
        }
        
        return enhancedSummary
    }
    

    
    private func createBasicSummary(from text: String, contentType: ContentType) -> String {
        // TODO: Implement ContentAnalyzer when available
        // For now, use basic sentence extraction
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 }
        
        let topSentences = Array(sentences.prefix(3))
        
        if topSentences.isEmpty {
            return "## Summary\n\n*No meaningful content found for summarization.*"
        }
        
        // Create a markdown-formatted summary
        let contentTypeHeader = switch contentType {
        case .meeting: "## Meeting Summary"
        case .personalJournal: "## Journal Entry"
        case .technical: "## Technical Summary"
        case .general: "## Summary"
        }
        
        // Format the top sentences as bullet points
        let bulletPoints = topSentences.enumerated().map { index, sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        return "\(contentTypeHeader)\n\n\(bulletPoints)"
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
    
    // MARK: - Recording Name Management
    
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
            // Check if target file already exists and generate unique name if needed
            var finalNewURL = newURL
            var counter = 1
            let baseNewName = newName
            let fileExtension = newURL.pathExtension
            
            while fileManager.fileExists(atPath: finalNewURL.path) {
                let uniqueName = "\(baseNewName) (\(counter))"
                finalNewURL = documentsPath.appendingPathComponent("\(uniqueName).\(fileExtension)")
                counter += 1
                
                // Prevent infinite loop
                if counter > 100 {
                    print("⚠️ Could not find unique filename after 100 attempts, using timestamp")
                    let timestamp = Int(Date().timeIntervalSince1970)
                    let timestampName = "\(baseNewName)_\(timestamp)"
                    finalNewURL = documentsPath.appendingPathComponent("\(timestampName).\(fileExtension)")
                    break
                }
            }
            
            print("📁 Renaming audio file: \(oldURL.lastPathComponent) → \(finalNewURL.lastPathComponent)")
            try fileManager.moveItem(at: oldURL, to: finalNewURL)
            print("✅ Audio file renamed successfully")
            
            // Update the newRecordingURL for other file updates
            newRecordingURL = finalNewURL
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
        TranscriptManager.shared.updateRecordingURL(from: oldURL, to: newURL)
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
    
    // MARK: - Statistics
    
    struct SummaryStatistics {
        let totalSummaries: Int
        let averageConfidence: Double
        let averageCompressionRatio: Double
        let totalTasks: Int
        let totalReminders: Int
        let engineUsage: [String: Int]
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
        guard let data = UserDefaults.standard.data(forKey: enhancedSummariesKey) else { 
            return 
        }
        do {
            enhancedSummaries = try JSONDecoder().decode([EnhancedSummaryData].self, from: data)
        } catch {
            print("Failed to load enhanced summaries: \(error)")
        }
    }
}