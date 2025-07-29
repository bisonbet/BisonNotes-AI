import Foundation

// MARK: - Engine Availability Status

struct EngineAvailabilityStatus {
    let name: String
    let description: String
    let isAvailable: Bool
    let isComingSoon: Bool
    let requirements: [String]
    let version: String
    let isCurrentEngine: Bool
    
    var statusMessage: String {
        if isCurrentEngine {
            return "Currently Active"
        } else if isAvailable {
            return "Available"
        } else if isComingSoon {
            return "Coming Soon"
        } else {
            return "Not Available"
        }
    }
    
    var statusColor: String {
        if isCurrentEngine {
            return "green"
        } else if isAvailable {
            return "blue"
        } else if isComingSoon {
            return "orange"
        } else {
            return "red"
        }
    }
}

@MainActor
class SummaryManager: ObservableObject {
    @Published var summaries: [SummaryData] = []
    @Published var enhancedSummaries: [EnhancedSummaryData] = []
    
    private let summariesKey = "SavedSummaries"
    private let enhancedSummariesKey = "SavedEnhancedSummaries"
    
    // MARK: - Enhanced Summarization Integration
    
    private var currentEngine: SummarizationEngine?
    private var availableEngines: [String: SummarizationEngine] = [:]
    // Task and Reminder Extractors for enhanced processing
    private let taskExtractor = TaskExtractor()
    private let reminderExtractor = ReminderExtractor()
    private let transcriptManager = TranscriptManager.shared
    
    // MARK: - Error Handling Integration
    
    private let errorHandler = ErrorHandler()
    @Published var currentError: AppError?
    @Published var showingErrorAlert = false
    
    // MARK: - Performance Monitoring Integration
    
    private lazy var performanceMonitor = EnginePerformanceMonitor()
    
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
        print("🔍 SummaryManager: Looking for legacy summary with URL: \(recordingURL)")
        print("🔍 SummaryManager: Total legacy summaries: \(summaries.count)")
        
        let targetFilename = recordingURL.lastPathComponent
        let targetName = recordingURL.deletingPathExtension().lastPathComponent
        
        print("🔍 SummaryManager: Looking for filename: \(targetFilename)")
        print("🔍 SummaryManager: Looking for name: \(targetName)")
        
        for (index, summary) in summaries.enumerated() {
            let summaryFilename = summary.recordingURL.lastPathComponent
            let summaryName = summary.recordingURL.deletingPathExtension().lastPathComponent
            
            print("🔍 SummaryManager: Checking legacy summary \(index): \(summary.recordingName)")
            print("🔍 SummaryManager: Stored filename: \(summaryFilename)")
            print("🔍 SummaryManager: Stored name: \(summaryName)")
            
            // Try multiple comparison methods
            let exactMatch = summary.recordingURL == recordingURL
            let pathMatch = summary.recordingURL.path == recordingURL.path
            let filenameMatch = summaryFilename == targetFilename
            let nameMatch = summaryName == targetName
            let recordingNameMatch = summary.recordingName == targetName
            
            print("🔍 SummaryManager: Exact match: \(exactMatch)")
            print("🔍 SummaryManager: Path match: \(pathMatch)")
            print("🔍 SummaryManager: Filename match: \(filenameMatch)")
            print("🔍 SummaryManager: Name match: \(nameMatch)")
            print("🔍 SummaryManager: Recording name match: \(recordingNameMatch)")
            
            // Match if any of these conditions are true
            if exactMatch || pathMatch || filenameMatch || nameMatch || recordingNameMatch {
                print("✅ SummaryManager: Found matching legacy summary!")
                return summary
            }
        }
        
        print("❌ SummaryManager: No matching legacy summary found")
        return nil
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
            
            // Force a UI update
            self.objectWillChange.send()
            
            // Verify the save operation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                print("🔍 SummaryManager: Can find summary: \(self.hasSummary(for: summary.recordingURL))")
            }
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
        print("🔍 SummaryManager: Looking for enhanced summary with URL: \(recordingURL)")
        print("🔍 SummaryManager: Total enhanced summaries: \(enhancedSummaries.count)")
        
        let targetFilename = recordingURL.lastPathComponent
        let targetName = recordingURL.deletingPathExtension().lastPathComponent
        
        print("🔍 SummaryManager: Looking for filename: \(targetFilename)")
        print("🔍 SummaryManager: Looking for name: \(targetName)")
        
        for (index, summary) in enhancedSummaries.enumerated() {
            let summaryFilename = summary.recordingURL.lastPathComponent
            let summaryName = summary.recordingURL.deletingPathExtension().lastPathComponent
            
            print("🔍 SummaryManager: Checking enhanced summary \(index): \(summary.recordingName)")
            print("🔍 SummaryManager: Stored filename: \(summaryFilename)")
            print("🔍 SummaryManager: Stored name: \(summaryName)")
            
            // Try multiple comparison methods
            let exactMatch = summary.recordingURL == recordingURL
            let pathMatch = summary.recordingURL.path == recordingURL.path
            let filenameMatch = summaryFilename == targetFilename
            let nameMatch = summaryName == targetName
            let recordingNameMatch = summary.recordingName == targetName
            
            print("🔍 SummaryManager: Exact match: \(exactMatch)")
            print("🔍 SummaryManager: Path match: \(pathMatch)")
            print("🔍 SummaryManager: Filename match: \(filenameMatch)")
            print("🔍 SummaryManager: Name match: \(nameMatch)")
            print("🔍 SummaryManager: Recording name match: \(recordingNameMatch)")
            
            // Match if any of these conditions are true
            if exactMatch || pathMatch || filenameMatch || nameMatch || recordingNameMatch {
                print("✅ SummaryManager: Found matching enhanced summary!")
                return summary
            }
        }
        
        print("❌ SummaryManager: No matching enhanced summary found")
        return nil
    }
    
    func hasEnhancedSummary(for recordingURL: URL) -> Bool {
        let result = getEnhancedSummary(for: recordingURL) != nil
        print("🔍 SummaryManager: hasEnhancedSummary for \(recordingURL.lastPathComponent) = \(result)")
        return result
    }
    
    // MARK: - Unified Methods (prefer enhanced, fallback to legacy)
    
    func hasSummary(for recordingURL: URL) -> Bool {
        let hasEnhanced = hasEnhancedSummary(for: recordingURL)
        let hasLegacy = getSummary(for: recordingURL) != nil
        
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
        let titleItems: [TitleItem] = [] // Legacy summaries don't have titles
        
        return EnhancedSummaryData(
            recordingURL: legacy.recordingURL,
            recordingName: legacy.recordingName,
            recordingDate: legacy.recordingDate,
            summary: legacy.summary,
            tasks: taskItems,
            reminders: reminderItems,
            titles: titleItems,
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
        let comingSoonEngineNames = getComingSoonEngines()
        let allEngineNames = AIEngineType.allCases.map { $0.rawValue }
        
        // Get detailed status for each engine
        let engineStatusMap = getEngineAvailabilityStatus()
        let detailedStatus = engineStatusMap.mapValues { status in
            [
                "description": status.description,
                "isAvailable": status.isAvailable,
                "isComingSoon": status.isComingSoon,
                "requirements": status.requirements,
                "version": status.version,
                "isCurrentEngine": status.isCurrentEngine,
                "statusMessage": status.statusMessage,
                "statusColor": status.statusColor
            ]
        }
        
        return [
            "currentEngine": currentEngineName,
            "availableEngines": availableEngineNames,
            "comingSoonEngines": comingSoonEngineNames,
            "allEngines": allEngineNames,
            "totalInitialized": availableEngines.count,
            "totalAvailable": availableEngineNames.count,
            "totalComingSoon": comingSoonEngineNames.count,
            "detailedStatus": detailedStatus,
            "lastUpdated": Date().timeIntervalSince1970
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
        print("🔍 SummaryManager: Checking available engines...")
        
        // Get all engine types and check their real-time availability
        let allEngineTypes = AIEngineFactory.getAllEngines()
        var availableEngines: [String] = []
        
        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)
            
            // Perform real-time availability check
            if engine.isAvailable {
                availableEngines.append(engineType.rawValue)
                print("✅ SummaryManager: \(engineType.rawValue) is available")
            } else {
                print("❌ SummaryManager: \(engineType.rawValue) is not available")
            }
        }
        
        let sortedEngines = availableEngines.sorted()
        print("📋 SummaryManager: Available engines: \(sortedEngines)")
        return sortedEngines
    }
    
    func getComingSoonEngines() -> [String] {
        print("🔍 SummaryManager: Checking coming soon engines...")
        
        // Get all engine types
        let allEngineTypes = AIEngineFactory.getAllEngines()
        let availableEngineNames = Set(getAvailableEnginesOnly())
        
        // Filter out available engines to find coming soon engines
        let comingSoonEngines = allEngineTypes
            .map { $0.rawValue }
            .filter { !availableEngineNames.contains($0) }
            .sorted()
        
        print("🚧 SummaryManager: Coming soon engines: \(comingSoonEngines)")
        return comingSoonEngines
    }
    
    // MARK: - Real-time Availability Checking
    
    func checkEngineAvailability(_ engineName: String) async -> (isAvailable: Bool, errorMessage: String?) {
        print("🔍 SummaryManager: Checking real-time availability for '\(engineName)'")
        
        // Validate engine name first
        let validation = validateEngineAvailability(engineName)
        guard validation.isValid else {
            return (false, validation.errorMessage)
        }
        
        // Get the engine type
        guard let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) else {
            return (false, "Unknown engine type")
        }
        
        // Create engine instance and check availability
        let engine = AIEngineFactory.createEngine(type: engineType)
        
        // Check basic availability first
        let isAvailable = engine.isAvailable
        print("🔍 SummaryManager: \(engineName) basic availability: \(isAvailable)")
        
        if !isAvailable {
            return (false, "Engine not available")
        }
        
        // For engines that support connection testing, perform additional checks
        if engineName.contains("OpenAI") || engineName.contains("Ollama") {
            // Try to perform a connection test if the engine supports it
            if let testableEngine = engine as? (any SummarizationEngine & ConnectionTestable) {
                let isConnected = await testableEngine.testConnection()
                if isConnected {
                    print("✅ SummaryManager: \(engineName) connection test successful")
                    return (true, nil)
                } else {
                    print("❌ SummaryManager: \(engineName) connection test failed")
                    return (false, "Connection test failed")
                }
            } else {
                // Engine doesn't support connection testing, rely on basic availability
                print("⚠️ SummaryManager: \(engineName) doesn't support connection testing")
                return (isAvailable, nil)
            }
        } else {
            // For local engines like Enhanced Apple Intelligence, just check basic availability
            return (isAvailable, nil)
        }
    }
    
    func refreshEngineAvailability() async {
        print("🔄 SummaryManager: Refreshing engine availability...")
        
        // Get all engine types
        let allEngineTypes = AIEngineFactory.getAllEngines()
        
        // Clear existing engines and reinitialize
        availableEngines.removeAll()
        
        var successfullyInitialized = 0
        let totalEngines = allEngineTypes.count
        
        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)
            
            // Perform real-time availability check
            let availability = await checkEngineAvailability(engineType.rawValue)
            
            if availability.isAvailable {
                availableEngines[engine.name] = engine
                successfullyInitialized += 1
                print("✅ SummaryManager: \(engine.name) refreshed and available")
            } else {
                print("❌ SummaryManager: \(engine.name) not available: \(availability.errorMessage ?? "Unknown error")")
            }
        }
        
        // Update current engine if needed
        if let currentEngine = currentEngine {
            let currentAvailability = await checkEngineAvailability(currentEngine.name)
            if !currentAvailability.isAvailable {
                print("⚠️ SummaryManager: Current engine '\(currentEngine.name)' is no longer available")
                
                // Try to find an available fallback engine
                if let fallbackEngine = availableEngines.values.first {
                    self.currentEngine = fallbackEngine
                    UserDefaults.standard.set(fallbackEngine.name, forKey: "selectedAIEngine")
                    print("🔄 SummaryManager: Switched to fallback engine '\(fallbackEngine.name)'")
                }
            }
        }
        
        print("🔄 SummaryManager: Engine availability refresh complete")
        print("✅ Successfully refreshed: \(successfullyInitialized)/\(totalEngines) engines")
        print("📋 Available engines: \(getAvailableEnginesOnly())")
        
        // Notify observers of the refresh
        await MainActor.run {
            self.objectWillChange.send()
        }
    }
    
    func getEngineAvailabilityStatus() -> [String: EngineAvailabilityStatus] {
        print("📊 SummaryManager: Getting engine availability status...")
        
        var statusMap: [String: EngineAvailabilityStatus] = [:]
        let allEngineTypes = AIEngineFactory.getAllEngines()
        
        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)
            let engineName = engineType.rawValue
            
            let status = EngineAvailabilityStatus(
                name: engineName,
                description: engine.description,
                isAvailable: engine.isAvailable,
                isComingSoon: engineType.isComingSoon,
                requirements: engineType.requirements,
                version: engine.version,
                isCurrentEngine: currentEngine?.name == engineName
            )
            
            statusMap[engineName] = status
        }
        
        print("📊 SummaryManager: Engine status map created with \(statusMap.count) engines")
        return statusMap
    }
    
    // MARK: - Engine Monitoring and Auto-Recovery
    
    func startEngineMonitoring() {
        print("🔍 SummaryManager: Starting engine availability monitoring...")
        
        // Set up a timer to periodically check engine availability
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task {
                await self.monitorEngineAvailability()
            }
        }
        
        print("✅ SummaryManager: Engine monitoring started")
    }
    
    private func monitorEngineAvailability() async {
        print("🔍 SummaryManager: Monitoring engine availability...")
        
        guard let currentEngine = currentEngine else {
            print("⚠️ SummaryManager: No current engine to monitor")
            return
        }
        
        // Check if current engine is still available
        let availability = await checkEngineAvailability(currentEngine.name)
        
        if !availability.isAvailable {
            print("⚠️ SummaryManager: Current engine '\(currentEngine.name)' is no longer available")
            print("🔄 SummaryManager: Attempting to switch to available engine...")
            
            // Try to find an available engine
            let availableEngines = getAvailableEnginesOnly()
            
            if let newEngineName = availableEngines.first {
                print("🔄 SummaryManager: Switching to '\(newEngineName)'")
                setEngine(newEngineName)
                
                // Notify observers of the engine change
                await MainActor.run {
                    self.objectWillChange.send()
                }
            } else {
                print("❌ SummaryManager: No available engines found")
            }
        } else {
            print("✅ SummaryManager: Current engine '\(currentEngine.name)' is still available")
        }
    }
    
    func getEngineHealthReport() -> [String: Any] {
        print("🏥 SummaryManager: Generating engine health report...")
        
        let statusMap = getEngineAvailabilityStatus()
        let currentEngineName = getCurrentEngineName()
        
        var healthReport: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "currentEngine": currentEngineName,
            "totalEngines": statusMap.count,
            "availableEngines": 0,
            "unavailableEngines": 0,
            "comingSoonEngines": 0,
            "engineDetails": [:]
        ]
        
        var availableCount = 0
        var unavailableCount = 0
        var comingSoonCount = 0
        var engineDetails: [String: [String: Any]] = [:]
        
        for (engineName, status) in statusMap {
            var details: [String: Any] = [
                "description": status.description,
                "isAvailable": status.isAvailable,
                "isComingSoon": status.isComingSoon,
                "version": status.version,
                "isCurrentEngine": status.isCurrentEngine,
                "statusMessage": status.statusMessage,
                "statusColor": status.statusColor
            ]
            
            if status.isAvailable {
                availableCount += 1
                details["health"] = "healthy"
            } else if status.isComingSoon {
                comingSoonCount += 1
                details["health"] = "coming_soon"
            } else {
                unavailableCount += 1
                details["health"] = "unhealthy"
                details["requirements"] = status.requirements
            }
            
            engineDetails[engineName] = details
        }
        
        healthReport["availableEngines"] = availableCount
        healthReport["unavailableEngines"] = unavailableCount
        healthReport["comingSoonEngines"] = comingSoonCount
        healthReport["engineDetails"] = engineDetails
        
        print("🏥 SummaryManager: Health report generated")
        print("📊 Available: \(availableCount), Unavailable: \(unavailableCount), Coming Soon: \(comingSoonCount)")
        
        return healthReport
    }
    
    // MARK: - Enhanced Summary Generation
    
    func generateEnhancedSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        print("🤖 SummaryManager: Starting enhanced summary generation using \(getCurrentEngineName())")
        
        let startTime = Date()
        
        // Validate input before processing
        let validationResult = errorHandler.validateTranscriptForSummarization(text)
        if !validationResult.isValid {
            let validationError = SummarizationError.insufficientContent
            handleError(validationError, context: "Input Validation", recordingName: recordingName)
            throw validationError
        }
        
        // Ensure we have a working engine
        guard let engine = currentEngine else {
            print("❌ SummaryManager: No AI engine available, falling back to basic processing")
            let fallbackError = SummarizationError.aiServiceUnavailable(service: "No AI engines available")
            handleError(fallbackError, context: "Engine Availability", recordingName: recordingName)
            return try await generateBasicSummary(from: text, for: recordingURL, recordingName: recordingName, recordingDate: recordingDate)
        }
        
        print("🎯 SummaryManager: Using engine: \(engine.name)")
        
        do {
            // Use the AI engine to process the complete text
            let result = try await engine.processComplete(text: text)
            
            let processingTime = Date().timeIntervalSince(startTime)
            
            // Generate intelligent recording name using AI analysis
            let intelligentName = generateIntelligentRecordingName(
                from: text,
                contentType: result.contentType,
                tasks: result.tasks,
                reminders: result.reminders,
                titles: result.titles
            )
            
            // Use the intelligent name if it's better than the original
            let finalRecordingName = intelligentName.isEmpty || intelligentName == "Recording" ? recordingName : intelligentName
            
            let enhancedSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: finalRecordingName,
                recordingDate: recordingDate,
                summary: result.summary,
                tasks: result.tasks,
                reminders: result.reminders,
                titles: result.titles,
                contentType: result.contentType,
                aiMethod: engine.name,
                originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
                processingTime: processingTime
            )
            
            // Validate summary quality
            let qualityReport = errorHandler.validateSummaryQuality(enhancedSummary)
            if qualityReport.qualityLevel == .unacceptable {
                print("⚠️ SummaryManager: Summary quality is unacceptable, attempting recovery")
                handleError(SummarizationError.processingFailed(reason: "Summary quality below threshold"), context: "Summary Quality", recordingName: recordingName)
            }
            
            // Track performance metrics
            performanceMonitor.trackEnhancedSummaryPerformance(enhancedSummary, engineName: engine.name, processingTime: processingTime)
            
            // Save the enhanced summary on the main thread
            await MainActor.run {
                saveEnhancedSummary(enhancedSummary)
            }
            
            // Update the recording name if we generated a better one
            if finalRecordingName != recordingName {
                try await updateRecordingNameWithAI(
                    from: recordingName,
                    recordingURL: recordingURL,
                    transcript: text,
                    contentType: result.contentType,
                    tasks: result.tasks,
                    reminders: result.reminders
                )
            }
            
            print("✅ SummaryManager: Enhanced summary generated successfully")
            print("📊 Summary length: \(result.summary.count) characters")
            print("📋 Tasks extracted: \(result.tasks.count)")
            print("🔔 Reminders extracted: \(result.reminders.count)")
            print("🏷️ Content type: \(result.contentType.rawValue)")
            print("📝 Recording name: '\(finalRecordingName)'")
            print("📊 Quality score: \(qualityReport.formattedScore)")
            
            return enhancedSummary
            
        } catch {
            print("❌ SummaryManager: AI engine failed, falling back to basic processing")
            print("🔍 Error details: \(error)")
            
            // Track engine failure
            performanceMonitor.trackEngineFailure(
                engineName: engine.name,
                processingTime: Date().timeIntervalSince(startTime),
                error: error,
                textLength: text.count,
                wordCount: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            )
            
            // Handle the error and provide recovery options
            handleError(error, context: "Enhanced Summary Generation", recordingName: recordingName)
            
            return try await generateBasicSummary(from: text, for: recordingURL, recordingName: recordingName, recordingDate: recordingDate)
        }
    }
    
    // MARK: - Fallback Basic Summary Generation
    
    private func generateBasicSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date) async throws -> EnhancedSummaryData {
        print("🔄 SummaryManager: Using basic fallback summarization with task/reminder extraction")
        
        let startTime = Date()
        
        // Validate input for basic processing
        let validationResult = errorHandler.validateTranscriptForSummarization(text)
        if !validationResult.isValid {
            let validationError = SummarizationError.insufficientContent
            handleError(validationError, context: "Basic Summary Input Validation", recordingName: recordingName)
            throw validationError
        }
        
        // Use ContentAnalyzer for content classification
        let contentType = ContentAnalyzer.classifyContent(text)
        let summary = createBasicSummary(from: text, contentType: contentType)
        
        // Extract tasks and reminders using dedicated extractors
        let (tasks, reminders) = try await extractTasksAndRemindersFromText(text)
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        // Generate intelligent recording name using AI analysis
        let intelligentName = generateIntelligentRecordingName(
            from: text,
            contentType: contentType,
            tasks: tasks,
            reminders: reminders,
            titles: []
        )
        
        // Use the intelligent name if it's better than the original
        let finalRecordingName = intelligentName.isEmpty || intelligentName == "Recording" ? recordingName : intelligentName
        
        let enhancedSummary = EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: finalRecordingName,
            recordingDate: recordingDate,
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            contentType: contentType,
            aiMethod: "Basic Processing with Task/Reminder Extraction",
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: processingTime
        )
        
        // Validate basic summary quality
        let qualityReport = errorHandler.validateSummaryQuality(enhancedSummary)
        if qualityReport.qualityLevel == SummaryQualityLevel.unacceptable {
            print("⚠️ SummaryManager: Basic summary quality is unacceptable")
            handleError(SummarizationError.processingFailed(reason: "Basic summary quality below threshold"), context: "Basic Summary Quality", recordingName: recordingName)
        }
        
        // Save the enhanced summary on the main thread
        await MainActor.run {
            saveEnhancedSummary(enhancedSummary)
        }
        
        // Update the recording name if we generated a better one
        if finalRecordingName != recordingName {
            try await updateRecordingNameWithAI(
                from: recordingName,
                recordingURL: recordingURL,
                transcript: text,
                contentType: contentType,
                tasks: tasks,
                reminders: reminders
            )
        }
        
        print("✅ SummaryManager: Basic summary with extraction completed")
        print("📋 Tasks extracted: \(tasks.count)")
        print("🔔 Reminders extracted: \(reminders.count)")
        print("📝 Recording name: '\(finalRecordingName)'")
        print("📊 Quality score: \(qualityReport.formattedScore)")
        
        return enhancedSummary
    }
    
    private func createBasicSummary(from text: String, contentType: ContentType) -> String {
        print("📝 Creating content-type optimized summary for: \(contentType.rawValue)")
        
        // Use ContentAnalyzer for better sentence extraction and scoring with content-type optimization
        let sentences = ContentAnalyzer.extractSentences(from: text)
        
        if sentences.isEmpty {
            return "## Summary\n\n*No meaningful content found for summarization.*"
        }
        
        // Score sentences using ContentAnalyzer with content-type specific boosting
        let scoredSentences = sentences.enumerated().map { index, sentence in
            let baseImportance = ContentAnalyzer.calculateSentenceImportance(sentence, in: text)
            var boostedScore = baseImportance
            
            // Apply content-type specific boosting
            switch contentType {
            case .meeting:
                let meetingKeywords = ["decision", "action item", "follow up", "next step", "agreed", "consensus", "deadline", "schedule"]
                for keyword in meetingKeywords {
                    if sentence.lowercased().contains(keyword) {
                        boostedScore += 0.3
                    }
                }
            case .personalJournal:
                let reflectionKeywords = ["i feel", "i think", "i learned", "i realized", "i discovered", "my experience", "i believe"]
                for keyword in reflectionKeywords {
                    if sentence.lowercased().contains(keyword) {
                        boostedScore += 0.3
                    }
                }
            case .technical:
                let technicalKeywords = ["algorithm", "function", "method", "solution", "implementation", "architecture", "system", "code"]
                for keyword in technicalKeywords {
                    if sentence.lowercased().contains(keyword) {
                        boostedScore += 0.2
                    }
                }
            case .general:
                // No additional boosting for general content
                break
            }
            
            return (sentence: sentence, score: boostedScore)
        }
        
        // Select top sentences based on boosted importance score
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(4)
            .map { $0.sentence }
        
        if topSentences.isEmpty {
            return "## Summary\n\n*No meaningful content found for summarization.*"
        }
        
        // Create a markdown-formatted summary with content-type specific headers
        let contentTypeHeader = switch contentType {
        case .meeting: "## Meeting Summary\n\n**Key Decisions & Action Items:**"
        case .personalJournal: "## Personal Reflection\n\n**Key Insights & Experiences:**"
        case .technical: "## Technical Summary\n\n**Key Concepts & Solutions:**"
        case .general: "## Summary\n\n**Main Points:**"
        }
        
        // Format the top sentences as bullet points
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        let summary = "\(contentTypeHeader)\n\n\(bulletPoints)"
        print("✅ Content-type optimized summary created: \(summary.count) characters")
        
        return summary
    }
    
    // MARK: - Task and Reminder Extraction
    
    func extractTasksFromText(_ text: String) async throws -> [TaskItem] {
        print("📋 SummaryManager: Extracting tasks using dedicated TaskExtractor")
        
        // First try to use the current AI engine if available
        if let engine = currentEngine {
            do {
                let tasks = try await engine.extractTasks(from: text)
                print("✅ SummaryManager: AI engine extracted \(tasks.count) tasks")
                return tasks
            } catch {
                print("⚠️ SummaryManager: AI engine task extraction failed, using fallback extractor")
                print("🔍 Error: \(error)")
            }
        }
        
        // Fallback to dedicated TaskExtractor
        let tasks = taskExtractor.extractTasks(from: text)
        print("✅ SummaryManager: TaskExtractor extracted \(tasks.count) tasks")
        return tasks
    }
    
    func extractRemindersFromText(_ text: String) async throws -> [ReminderItem] {
        print("🔔 SummaryManager: Extracting reminders using dedicated ReminderExtractor")
        
        // First try to use the current AI engine if available
        if let engine = currentEngine {
            do {
                let reminders = try await engine.extractReminders(from: text)
                print("✅ SummaryManager: AI engine extracted \(reminders.count) reminders")
                return reminders
            } catch {
                print("⚠️ SummaryManager: AI engine reminder extraction failed, using fallback extractor")
                print("🔍 Error: \(error)")
            }
        }
        
        // Fallback to dedicated ReminderExtractor
        let reminders = reminderExtractor.extractReminders(from: text)
        print("✅ SummaryManager: ReminderExtractor extracted \(reminders.count) reminders")
        return reminders
    }
    
    func extractTitlesFromText(_ text: String) async throws -> [TitleItem] {
        print("📝 SummaryManager: Extracting titles using AI engine")
        
        // First try to use the current AI engine if available
        if let engine = currentEngine {
            do {
                let titles = try await engine.extractTitles(from: text)
                print("✅ SummaryManager: AI engine extracted \(titles.count) titles")
                return titles
            } catch {
                print("⚠️ SummaryManager: AI engine title extraction failed")
                print("🔍 Error: \(error)")
            }
        }
        
        // Fallback: return empty array for now
        print("ℹ️ SummaryManager: No title extraction fallback available")
        return []
    }
    
    func extractTasksAndRemindersFromText(_ text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        print("📋🔔 SummaryManager: Extracting tasks and reminders from text")
        
        async let tasks = extractTasksFromText(text)
        async let reminders = extractRemindersFromText(text)
        
        let (taskResults, reminderResults) = try await (tasks, reminders)
        
        print("✅ SummaryManager: Extracted \(taskResults.count) tasks and \(reminderResults.count) reminders")
        return (taskResults, reminderResults)
    }
    
    func extractTasksRemindersAndTitlesFromText(_ text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        print("📋🔔📝 SummaryManager: Extracting tasks, reminders, and titles from text")
        
        async let tasks = extractTasksFromText(text)
        async let reminders = extractRemindersFromText(text)
        async let titles = extractTitlesFromText(text)
        
        let (taskResults, reminderResults, titleResults) = try await (tasks, reminders, titles)
        
        print("✅ SummaryManager: Extracted \(taskResults.count) tasks, \(reminderResults.count) reminders, and \(titleResults.count) titles")
        return (taskResults, reminderResults, titleResults)
    }
    
    // MARK: - Content Type Influenced Processing
    
    func generateContentTypeOptimizedSummary(from text: String, contentType: ContentType) async throws -> String {
        print("🎯 SummaryManager: Generating content-type optimized summary for \(contentType.rawValue)")
        
        // Use different approaches based on content type
        switch contentType {
        case .meeting:
            return try await generateMeetingSummary(from: text)
        case .personalJournal:
            return try await generateJournalSummary(from: text)
        case .technical:
            return try await generateTechnicalSummary(from: text)
        case .general:
            return try await generateGeneralSummary(from: text)
        }
    }
    
    private func generateMeetingSummary(from text: String) async throws -> String {
        print("📋 SummaryManager: Generating meeting-focused summary")
        
        // Focus on decisions, action items, and key discussion points
        let sentences = ContentAnalyzer.extractSentences(from: text)
        let scoredSentences = sentences.enumerated().map { index, sentence in
            let baseImportance = ContentAnalyzer.calculateSentenceImportance(sentence, in: text)
            
            // Boost sentences with meeting-specific keywords
            let meetingKeywords = ["decision", "action item", "follow up", "next step", "agreed", "consensus", "deadline", "schedule"]
            var boostedScore = baseImportance
            
            for keyword in meetingKeywords {
                if sentence.lowercased().contains(keyword) {
                    boostedScore += 0.5
                }
            }
            
            return (sentence: sentence, score: boostedScore)
        }
        
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(5)
            .map { $0.sentence }
        
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        return "## Meeting Summary\n\n**Key Decisions & Action Items:**\n\n\(bulletPoints)"
    }
    
    private func generateJournalSummary(from text: String) async throws -> String {
        print("📝 SummaryManager: Generating journal-focused summary")
        
        // Focus on emotions, insights, and personal experiences
        let sentences = ContentAnalyzer.extractSentences(from: text)
        let scoredSentences = sentences.enumerated().map { index, sentence in
            let baseImportance = ContentAnalyzer.calculateSentenceImportance(sentence, in: text)
            
            // Boost sentences with personal reflection keywords
            let reflectionKeywords = ["i feel", "i think", "i learned", "i realized", "i discovered", "my experience", "i believe"]
            var boostedScore = baseImportance
            
            for keyword in reflectionKeywords {
                if sentence.lowercased().contains(keyword) {
                    boostedScore += 0.4
                }
            }
            
            return (sentence: sentence, score: boostedScore)
        }
        
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(4)
            .map { $0.sentence }
        
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        return "## Personal Reflection\n\n**Key Insights & Experiences:**\n\n\(bulletPoints)"
    }
    
    private func generateTechnicalSummary(from text: String) async throws -> String {
        print("⚙️ SummaryManager: Generating technical-focused summary")
        
        // Focus on concepts, solutions, and important technical details
        let sentences = ContentAnalyzer.extractSentences(from: text)
        let scoredSentences = sentences.enumerated().map { index, sentence in
            let baseImportance = ContentAnalyzer.calculateSentenceImportance(sentence, in: text)
            
            // Boost sentences with technical keywords
            let technicalKeywords = ["algorithm", "function", "method", "solution", "implementation", "architecture", "system", "code", "debug", "test"]
            var boostedScore = baseImportance
            
            for keyword in technicalKeywords {
                if sentence.lowercased().contains(keyword) {
                    boostedScore += 0.3
                }
            }
            
            return (sentence: sentence, score: boostedScore)
        }
        
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(6)
            .map { $0.sentence }
        
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        return "## Technical Summary\n\n**Key Concepts & Solutions:**\n\n\(bulletPoints)"
    }
    
    private func generateGeneralSummary(from text: String) async throws -> String {
        print("📄 SummaryManager: Generating general summary")
        
        // Use standard sentence importance scoring
        let sentences = ContentAnalyzer.extractSentences(from: text)
        let scoredSentences = sentences.enumerated().map { index, sentence in
            let importance = ContentAnalyzer.calculateSentenceImportance(sentence, in: text)
            return (sentence: sentence, score: importance)
        }
        
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(4)
            .map { $0.sentence }
        
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        return "## Summary\n\n**Main Points:**\n\n\(bulletPoints)"
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
    
    // MARK: - Error Handling and Recovery
    
    func handleError(_ error: Error, context: String = "", recordingName: String = "") {
        print("❌ SummaryManager: Error in \(context): \(error.localizedDescription)")
        
        let appError = AppError.from(error, context: context)
        
        // Log the error
        errorHandler.handle(appError, context: context, showToUser: false)
        
        // Update UI state
        DispatchQueue.main.async {
            self.currentError = appError
            self.showingErrorAlert = true
        }
    }
    
    func clearCurrentError() {
        DispatchQueue.main.async {
            self.currentError = nil
            self.showingErrorAlert = false
        }
    }
    
    func getRecoveryActions(for error: AppError) -> [RecoveryAction] {
        return errorHandler.suggestRecoveryActions(for: error)
    }
    
    func performRecoveryAction(_ action: RecoveryAction, for recordingURL: URL, recordingName: String) async {
        print("🔄 SummaryManager: Performing recovery action: \(action.title)")
        
        switch action {
        case .retryOperation:
            // Retry the last operation
            await retryLastOperation(for: recordingURL, recordingName: recordingName)
        case .tryDifferentEngine:
            // Switch to a different available engine
            await switchToNextAvailableEngine()
        case .retryWithShorterContent:
            // Process with shorter content chunks
            await processWithShorterChunks(for: recordingURL, recordingName: recordingName)
        case .retryLater:
            // Wait and retry
            await retryWithDelay(for: recordingURL, recordingName: recordingName)
        case .checkNetworkConnection:
            // Check network and retry
            await checkNetworkAndRetry(for: recordingURL, recordingName: recordingName)
        case .tryOfflineMode:
            // Switch to offline engine
            await switchToOfflineEngine()
        case .manualSummary:
            // Allow manual summary creation
            await createManualSummary(for: recordingURL, recordingName: recordingName)
        default:
            print("⚠️ SummaryManager: Recovery action not implemented: \(action.title)")
        }
    }
    
    // MARK: - Recovery Action Implementations
    
    private func retryLastOperation(for recordingURL: URL, recordingName: String) async {
        print("🔄 SummaryManager: Retrying last operation")
        
        // Get the transcript and retry summary generation
        if let transcript = transcriptManager.getTranscript(for: recordingURL) {
            do {
                let summary = try await generateEnhancedSummary(
                    from: transcript.fullText,
                    for: recordingURL,
                    recordingName: recordingName,
                    recordingDate: Date()
                )
                saveEnhancedSummary(summary)
                clearCurrentError()
            } catch {
                handleError(error, context: "Retry Operation", recordingName: recordingName)
            }
        }
    }
    
    private func switchToNextAvailableEngine() async {
        print("🔄 SummaryManager: Switching to next available engine")
        
        let availableEngines = getAvailableEnginesOnly()
        let currentEngineName = getCurrentEngineName()
        
        // Find next available engine
        if let currentIndex = availableEngines.firstIndex(of: currentEngineName),
           currentIndex + 1 < availableEngines.count {
            let nextEngine = availableEngines[currentIndex + 1]
            setEngine(nextEngine)
            print("✅ SummaryManager: Switched to engine: \(nextEngine)")
        } else if !availableEngines.isEmpty {
            // Wrap around to first engine
            setEngine(availableEngines[0])
            print("✅ SummaryManager: Switched to first available engine: \(availableEngines[0])")
        }
    }
    
    private func processWithShorterChunks(for recordingURL: URL, recordingName: String) async {
        print("🔄 SummaryManager: Processing with shorter chunks")
        
        if let transcript = transcriptManager.getTranscript(for: recordingURL) {
            // Use TokenManager to split into smaller chunks
            let chunks = TokenManager.chunkText(transcript.fullText, maxTokens: 1000)
            
            var combinedSummary = ""
            var allTasks: [TaskItem] = []
            var allReminders: [ReminderItem] = []
            
            for (index, chunk) in chunks.enumerated() {
                print("📝 SummaryManager: Processing chunk \(index + 1)/\(chunks.count)")
                
                do {
                    let summary = try await generateEnhancedSummary(
                        from: chunk,
                        for: recordingURL,
                        recordingName: "\(recordingName) - Part \(index + 1)",
                        recordingDate: Date()
                    )
                    
                    combinedSummary += "\n\n## Part \(index + 1)\n\n\(summary.summary)"
                    allTasks.append(contentsOf: summary.tasks)
                    allReminders.append(contentsOf: summary.reminders)
                    
                } catch {
                    print("⚠️ SummaryManager: Chunk \(index + 1) failed: \(error.localizedDescription)")
                    // Continue with other chunks
                }
            }
            
            // Create combined enhanced summary
            let contentType = ContentAnalyzer.classifyContent(transcript.fullText)
            let combinedEnhancedSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: recordingName,
                recordingDate: Date(),
                summary: combinedSummary,
                tasks: allTasks,
                reminders: allReminders,
                contentType: contentType,
                aiMethod: "Chunked Processing",
                originalLength: transcript.fullText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
                processingTime: Date().timeIntervalSince(Date())
            )
            
            saveEnhancedSummary(combinedEnhancedSummary)
            clearCurrentError()
        }
    }
    
    private func retryWithDelay(for recordingURL: URL, recordingName: String) async {
        print("⏳ SummaryManager: Waiting before retry")
        
        // Wait for 5 seconds before retrying
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        
        await retryLastOperation(for: recordingURL, recordingName: recordingName)
    }
    
    private func checkNetworkAndRetry(for recordingURL: URL, recordingName: String) async {
        print("🌐 SummaryManager: Checking network connection")
        
        // Simple network check
        let isNetworkAvailable = await checkNetworkAvailability()
        
        if isNetworkAvailable {
            print("✅ SummaryManager: Network is available, retrying")
            await retryLastOperation(for: recordingURL, recordingName: recordingName)
        } else {
            print("❌ SummaryManager: Network is not available")
            handleError(
                SummarizationError.networkError(underlying: NSError(domain: "NetworkError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])),
                context: "Network Check",
                recordingName: recordingName
            )
        }
    }
    
    private func switchToOfflineEngine() async {
        print("🔄 SummaryManager: Switching to offline engine")
        
        // Try to switch to Enhanced Apple Intelligence (offline)
        if getAvailableEnginesOnly().contains("Enhanced Apple Intelligence") {
            setEngine("Enhanced Apple Intelligence")
            print("✅ SummaryManager: Switched to offline engine")
        } else {
            print("❌ SummaryManager: No offline engine available")
            handleError(
                SummarizationError.aiServiceUnavailable(service: "No offline engine available"),
                context: "Offline Engine Switch"
            )
        }
    }
    
    private func createManualSummary(for recordingURL: URL, recordingName: String) async {
        print("📝 SummaryManager: Creating manual summary placeholder")
        
        // Create a basic summary with manual indication
        let contentType = ContentType.general
        let manualSummary = EnhancedSummaryData(
            recordingURL: recordingURL,
            recordingName: recordingName,
            recordingDate: Date(),
            summary: "## Manual Summary Required\n\nThis recording requires manual summarization due to processing errors.\n\n**Recording:** \(recordingName)\n**Date:** \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n\nPlease create a summary manually using the app's editing features.",
            tasks: [],
            reminders: [],
            contentType: contentType,
            aiMethod: "Manual Required",
            originalLength: 0,
            processingTime: 0
        )
        
        saveEnhancedSummary(manualSummary)
        clearCurrentError()
    }
    
    private func checkNetworkAvailability() async -> Bool {
        // Simple network availability check
        guard let url = URL(string: "https://www.apple.com") else { return false }
        
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse {
                return httpResponse.statusCode == 200
            }
            return false
        } catch {
            return false
        }
    }
    
    // MARK: - Recording Name Management
    
    func generateIntelligentRecordingName(from text: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) -> String {
        print("🎯 SummaryManager: Generating intelligent recording name")
        
        // Use the RecordingNameGenerator to create a meaningful name
        let generatedName = RecordingNameGenerator.generateRecordingNameFromTranscript(
            text,
            contentType: contentType,
            tasks: tasks,
            reminders: reminders,
            titles: titles
        )
        
        // Validate and fix the generated name
        let validatedName = RecordingNameGenerator.validateAndFixRecordingName(generatedName, originalName: "Recording")
        
        print("✅ SummaryManager: Generated name: '\(validatedName)'")
        return validatedName
    }
    
    func updateRecordingNameWithAI(from oldName: String, recordingURL: URL, transcript: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem]) async throws {
        print("🤖 SummaryManager: Updating recording name using AI analysis")
        
        // Generate intelligent name using AI analysis
        let newName = generateIntelligentRecordingName(from: transcript, contentType: contentType, tasks: tasks, reminders: reminders, titles: [])
        
        // Only update if the new name is different and meaningful
        if newName != oldName && !newName.isEmpty && newName != "Recording" {
            print("📝 SummaryManager: Updating name from '\(oldName)' to '\(newName)'")
            try await updateRecordingName(from: oldName, to: newName, recordingURL: recordingURL)
            
            // Update the enhanced summary with the new name
            if let existingSummary = getEnhancedSummary(for: recordingURL) {
                let updatedSummary = EnhancedSummaryData(
                    recordingURL: recordingURL,
                    recordingName: newName,
                    recordingDate: existingSummary.recordingDate,
                    summary: existingSummary.summary,
                    tasks: existingSummary.tasks,
                    reminders: existingSummary.reminders,
                    contentType: existingSummary.contentType,
                    aiMethod: existingSummary.aiMethod,
                    originalLength: existingSummary.originalLength,
                    processingTime: existingSummary.processingTime
                )
                saveEnhancedSummary(updatedSummary)
                print("✅ SummaryManager: Updated enhanced summary with new name")
            }
        } else {
            print("ℹ️ SummaryManager: Keeping original name '\(oldName)' (no meaningful improvement found)")
        }
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
    
    // MARK: - Performance Monitoring Methods
    
    func getEnginePerformanceStatistics() -> [String: EnginePerformanceStatistics] {
        return performanceMonitor.engineStatistics
    }
    
    func getRecentPerformanceData() -> [EnginePerformanceData] {
        return performanceMonitor.recentPerformance
    }
    
    func getPerformanceTrends() -> [PerformanceTrend] {
        return performanceMonitor.performanceTrends
    }
    
    func getUsageAnalytics() -> EngineUsageAnalytics? {
        return performanceMonitor.usageAnalytics
    }
    
    func getEngineComparisonData(timeRange: DateInterval? = nil) -> EngineComparisonData {
        return performanceMonitor.getEngineComparisonData(timeRange: timeRange)
    }
    
    func clearPerformanceData() {
        performanceMonitor.clearPerformanceData()
    }
    
    func isPerformanceMonitoringEnabled() -> Bool {
        return performanceMonitor.isMonitoring
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