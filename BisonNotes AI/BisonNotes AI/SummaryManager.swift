import Foundation
import UIKit

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
    // MARK: - Shared Instance
    static let shared = SummaryManager()
    
    @Published var enhancedSummaries: [EnhancedSummaryData] = []

    private let enhancedSummariesKey = "SavedEnhancedSummaries"
    
    // MARK: - Enhanced Summarization Integration
    
    private var currentEngine: SummarizationEngine?
    private var availableEngines: [String: SummarizationEngine] = [:]
    // Task and Reminder Extractors for enhanced processing
    private let taskExtractor = TaskExtractor()
    private let reminderExtractor = ReminderExtractor()
    private let transcriptManager = TranscriptManager.shared
    
    // MARK: - Background Task Management

    /// Background task ID for keeping summarization alive when the app is backgrounded.
    /// Cloud AI calls (OpenAI, Bedrock, Gemini) use network requests that iOS will
    /// terminate after ~30s without a background task.
    private var summaryBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Error Handling Integration

    private let errorHandler = ErrorHandler()
    @Published var currentError: AppError?
    @Published var showingErrorAlert = false
    
    // MARK: - iCloud Integration
    
    private let iCloudManager = iCloudStorageManager.shared
    
    private init() {
        loadEnhancedSummariesLegacy()
        initializeEngines()
    }
    
    /// Internal legacy loading for init compatibility
    private func loadEnhancedSummariesLegacy() {
        guard let data = UserDefaults.standard.data(forKey: enhancedSummariesKey) else { 
            return 
        }
        do {
            let legacySummaries = try JSONDecoder().decode([EnhancedSummaryData].self, from: data)
            enhancedSummaries = legacySummaries
            if !legacySummaries.isEmpty {
                AppLog.shared.summarization("Loaded \(legacySummaries.count) legacy summaries from UserDefaults during init")
            }
        } catch {
            AppLog.shared.summarization("Failed to load legacy enhanced summaries during init: \(error)", level: .error)
        }
    }
    
    // MARK: - Enhanced Summary Methods
    
    /// DEPRECATED: Use AppDataCoordinator.addSummary() for proper Core Data persistence
    @available(*, deprecated, message: "Use AppDataCoordinator.addSummary() for Core Data persistence. This method only updates UI state.")
    func saveEnhancedSummary(_ summary: EnhancedSummaryData) {
        DispatchQueue.main.async {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("saveEnhancedSummary() is deprecated - updating UI only", level: .debug)
            }
            
            // Remove any existing enhanced summary for this recording
            self.enhancedSummaries.removeAll { $0.recordingURL == summary.recordingURL }
            self.enhancedSummaries.append(summary)
            // NOTE: Removed saveEnhancedSummariesToDisk() - Core Data is now the source of truth
            
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Enhanced summary saved. Total summaries: \(self.enhancedSummaries.count)", level: .debug)
            }
            
            // Force a UI update
            self.objectWillChange.send()
            
            // Sync to iCloud if enabled
            Task {
                do {
                    try await self.iCloudManager.syncSummary(summary)
                } catch {
                    AppLog.shared.summarization("Failed to sync summary to iCloud: \(error)", level: .error)
                }
            }
            
            // Verify the save operation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Can find summary: \(self.hasSummary(for: summary.recordingURL))", level: .debug)
                }
            }
        }
    }
    
    func updateEnhancedSummary(_ summary: EnhancedSummaryData) {
        DispatchQueue.main.async {
            if let index = self.enhancedSummaries.firstIndex(where: { $0.recordingURL == summary.recordingURL }) {
                self.enhancedSummaries[index] = summary
                // NOTE: Removed saveEnhancedSummariesToDisk() - Core Data is now the source of truth
            } else {
                // Only update UI state, not persistence
                self.enhancedSummaries.append(summary)
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Added summary to UI state", level: .debug)
                }
            }
        }
    }
    
    func getEnhancedSummary(for recordingURL: URL) -> EnhancedSummaryData? {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Looking for enhanced summary with URL: \(recordingURL)", level: .debug)
            AppLog.shared.summarization("Total enhanced summaries: \(enhancedSummaries.count)", level: .debug)
        }
        
        let targetFilename = recordingURL.lastPathComponent
        let targetName = recordingURL.deletingPathExtension().lastPathComponent
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Looking for filename: \(targetFilename)", level: .debug)
            AppLog.shared.summarization("Looking for name: \(targetName)", level: .debug)
        }
        
        for (index, summary) in enhancedSummaries.enumerated() {
            let summaryFilename = summary.recordingURL.lastPathComponent
            let summaryName = summary.recordingURL.deletingPathExtension().lastPathComponent
            
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Checking enhanced summary \(index)", level: .debug)
            }
            
            // Try multiple comparison methods
            let exactMatch = summary.recordingURL == recordingURL
            let pathMatch = summary.recordingURL.path == recordingURL.path
            let filenameMatch = summaryFilename == targetFilename
            let nameMatch = summaryName == targetName
            let recordingNameMatch = summary.recordingName == targetName
            
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Exact match: \(exactMatch)", level: .debug)
                AppLog.shared.summarization("Path match: \(pathMatch)", level: .debug)
                AppLog.shared.summarization("Filename match: \(filenameMatch)", level: .debug)
                AppLog.shared.summarization("Name match: \(nameMatch)", level: .debug)
                AppLog.shared.summarization("Recording name match: \(recordingNameMatch)", level: .debug)
            }
            
            // Match if any of these conditions are true
            if exactMatch || pathMatch || filenameMatch || nameMatch || recordingNameMatch {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Found matching enhanced summary", level: .debug)
                }
                return summary
            }
        }
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("No matching enhanced summary found", level: .debug)
        }
        return nil
    }
    
    func hasEnhancedSummary(for recordingURL: URL) -> Bool {
        let result = getEnhancedSummary(for: recordingURL) != nil
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("hasEnhancedSummary for \(recordingURL.lastPathComponent) = \(result)", level: .debug)
        }
        return result
    }
    
    // MARK: - Unified Methods (prefer enhanced, fallback to legacy)
    
    func hasSummary(for recordingURL: URL) -> Bool {
        return hasEnhancedSummary(for: recordingURL)
    }
    
    func deleteSummary(for recordingURL: URL) {
        DispatchQueue.main.async {
            // Find the enhanced summary to get its ID for iCloud deletion
            let enhancedSummary = self.enhancedSummaries.first { $0.recordingURL == recordingURL }
            
            self.enhancedSummaries.removeAll { $0.recordingURL == recordingURL }
            // NOTE: Core Data is now the source of truth for persistence
            
            // Delete from iCloud if there was an enhanced summary
            if let summary = enhancedSummary {
                Task {
                    do {
                        try await self.iCloudManager.deleteSummaryFromiCloud(summary.id)
                    } catch {
                        AppLog.shared.summarization("Failed to delete summary from iCloud: \(error)", level: .error)
                    }
                }
            }
        }
    }
    
    func getBestAvailableSummary(for recordingURL: URL) -> EnhancedSummaryData? {
        return getEnhancedSummary(for: recordingURL)
    }
    
    // MARK: - iCloud Access Methods
    
    func getiCloudManager() -> iCloudStorageManager {
        return iCloudManager
    }
    
    // MARK: - Clear All Data
    
    func clearAllSummaries() {
        AppLog.shared.summarization("Clearing all summaries...")
        
        let enhancedCount = enhancedSummaries.count

        DispatchQueue.main.async {
            self.enhancedSummaries.removeAll()
            AppLog.shared.summarization("Cleared \(enhancedCount) summaries")
        }
    }
    
    func showUnsupportedDeviceAlert() {
        let error = AppError.system(.configurationError(message: "The selected AI engine is not supported on this device. Please select another AI engine in Settings."))
        handleError(error, context: "Unsupported Device")
    }

    // MARK: - Engine Management
    
    func initializeEngines() {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Initializing AI engines using AIEngineFactory...", level: .debug)
        }
        
        // Clear any existing engines
        availableEngines.removeAll()
        
        // Get all engine types from the factory
        let allEngineTypes = AIEngineFactory.getAllEngines()
        var successfullyInitialized = 0
        
        for engineType in allEngineTypes {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Initializing \(engineType.rawValue)...", level: .debug)
            }

            // Create engine using the factory
            let engine = AIEngineFactory.createEngine(type: engineType)

            // Key by AIEngineType.rawValue to match UserDefaults "SelectedAIEngine" values
            availableEngines[engineType.rawValue] = engine
            
            // Only log successful initialization if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Successfully initialized \(engine.name) (Available: \(engine.isAvailable))", level: .debug)
            }
            successfullyInitialized += 1
            
            // Don't set any engine as current during initialization - wait for UserDefaults restoration
        }
        
        // Log only essential initialization summary
        AppLog.shared.summarization("Engine initialization complete - \(successfullyInitialized)/\(allEngineTypes.count) engines initialized")
        
        // Only log detailed engine lists if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Available engines: \(getAvailableEnginesOnly())", level: .debug)
            AppLog.shared.summarization("Coming soon engines: \(getComingSoonEngines())", level: .debug)
        }
        
        // Now restore the user's selected engine from UserDefaults or set default
        let savedEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine")

        if let savedEngineName = savedEngineName,
           let savedEngine = availableEngines[savedEngineName],
           savedEngine.isAvailable {
            // User has a saved preference and the engine is available
            currentEngine = savedEngine
            AppLog.shared.summarization("Restored previously selected engine: \(savedEngine.name)")
        } else if let savedEngineName = savedEngineName,
                  let savedEngine = availableEngines[savedEngineName],
                  !savedEngine.isAvailable {
            // User has a saved preference but the engine is not available
            // Try to find an available alternative, but don't overwrite their preference
            if let availableEngine = availableEngines.values.first(where: { $0.isAvailable }) {
                currentEngine = availableEngine
                AppLog.shared.summarization("Saved engine '\(savedEngineName)' not available, using '\(availableEngine.name)' temporarily", level: .default)
            }
        } else if savedEngineName == nil {
            // No saved preference, try to set On-Device AI as the default
            if let defaultEngine = availableEngines["On-Device AI"], defaultEngine.isAvailable {
                currentEngine = defaultEngine
                UserDefaults.standard.set(defaultEngine.name, forKey: "SelectedAIEngine")
                AppLog.shared.summarization("No saved preference, set On-Device AI as default engine")
            } else {
                // Try to find any available engine
                if let anyAvailableEngine = availableEngines.values.first(where: { $0.isAvailable && $0.name != "None" }) {
                    currentEngine = anyAvailableEngine
                    UserDefaults.standard.set(anyAvailableEngine.name, forKey: "SelectedAIEngine")
                    AppLog.shared.summarization("On-Device AI not available, using '\(anyAvailableEngine.name)' as default")
                } else {
                    // Last resort: set to None
                    UserDefaults.standard.set("None", forKey: "SelectedAIEngine")
                    AppLog.shared.summarization("No engines available, setting default engine to None")
                }
            }
        }

        // Ensure we have at least one working engine if one is selected
        if let engineName = UserDefaults.standard.string(forKey: "SelectedAIEngine"), engineName != "None" {
            if currentEngine == nil {
                AppLog.shared.summarization("No available engines found, attempting to find any available engine", level: .default)
                if let fallbackEngine = availableEngines.values.first(where: { $0.isAvailable && $0.name != "None" }) {
                    currentEngine = fallbackEngine
                    AppLog.shared.summarization("Set \(fallbackEngine.name) as fallback engine")
                }
            }
        }
        
        AppLog.shared.summarization("Current active engine: \(getCurrentEngineName())")
    }
    
    func setEngine(_ engineName: String) {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Setting engine to '\(engineName)'", level: .debug)
        }
        
        // Validate the engine using the new validation method
        let validation = validateEngineAvailability(engineName)
        
        guard validation.isValid else {
            AppLog.shared.summarization("\(validation.errorMessage ?? "Invalid engine")", level: .default)
            return
        }
        
        guard validation.isAvailable else {
            AppLog.shared.summarization("\(validation.errorMessage ?? "Engine not available")", level: .default)
            return
        }
        
        // Get or create the engine
        var targetEngine: SummarizationEngine?
        
        if let existingEngine = availableEngines[engineName] {
            targetEngine = existingEngine
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Using existing engine '\(engineName)'", level: .debug)
            }
        } else {
            // Create the engine using the factory
            if let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Creating new engine '\(engineName)' using factory", level: .debug)
                }
                let newEngine = AIEngineFactory.createEngine(type: engineType)
                availableEngines[engineType.rawValue] = newEngine
                targetEngine = newEngine
            }
        }
        
        // Set the engine if we have one and it's available
        if let engine = targetEngine, engine.isAvailable {
            currentEngine = engine
            
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Engine set successfully to '\(engine.name)'", level: .debug)
            }
            
            // Save the selected engine to UserDefaults for persistence
            UserDefaults.standard.set(engineName, forKey: "SelectedAIEngine")
            
            // Notify observers of the engine change
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        } else {
            AppLog.shared.summarization("Failed to set engine '\(engineName)' - engine not available", level: .default)
            if let engine = targetEngine {
                AppLog.shared.summarization("Engine details: \(engine.description) (Available: \(engine.isAvailable))", level: .debug)
            }
        }
    }
    
    func updateEngineConfiguration(_ engineName: String) {
        AppLog.shared.summarization("Updating configuration for engine '\(engineName)'", level: .debug)
        
        // Find the engine type for the given name
        guard let engineType = AIEngineType.allCases.first(where: { $0.rawValue == engineName }) else {
            AppLog.shared.summarization("Unknown engine type for '\(engineName)'", level: .error)
            return
        }
        
        // Recreate the engine with updated configuration using the factory
        let updatedEngine = AIEngineFactory.createEngine(type: engineType)
        availableEngines[engineType.rawValue] = updatedEngine
        
        // If this was the current engine, update the reference
        if currentEngine?.name == engineName {
            currentEngine = updatedEngine
            AppLog.shared.summarization("Updated current engine configuration for '\(engineName)'", level: .debug)
        }
        
        AppLog.shared.summarization("Engine configuration updated for '\(engineName)' (Available: \(updatedEngine.isAvailable))")
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
            AppLog.shared.summarization("No current engine set", level: .default)
            return "None"
        }
        
        // Verify the engine is still available
        if !engine.isAvailable {
            AppLog.shared.summarization("Current engine '\(engine.name)' is no longer available", level: .default)
            // Try to find an available fallback engine, but don't overwrite user's preference
            if let fallbackEngine = availableEngines.values.first(where: { $0.isAvailable }) {
                AppLog.shared.summarization("Using fallback engine '\(fallbackEngine.name)' temporarily", level: .debug)
                currentEngine = fallbackEngine
                // Don't overwrite the user's saved preference - they may want to use their selected engine when it becomes available again
                return fallbackEngine.name
            }
        }
        
        return engine.name
    }
    
    private func syncCurrentEngineWithSettings() {
        let selectedEngineName = UserDefaults.standard.string(forKey: "SelectedAIEngine") ?? "On-Device AI"
        
        // If current engine doesn't match the selected engine, update it
        if currentEngine?.name != selectedEngineName {
            if let selectedEngine = availableEngines[selectedEngineName], selectedEngine.isAvailable {
                currentEngine = selectedEngine
                AppLog.shared.summarization("Synced current engine to '\(selectedEngineName)' from settings", level: .debug)
            } else {
                AppLog.shared.summarization("Selected engine '\(selectedEngineName)' not available, keeping current engine", level: .default)
            }
        }
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
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Checking available engines...", level: .debug)
        }
        
        // Get all engine types and check their real-time availability
        let allEngineTypes = AIEngineFactory.getAllEngines()
        var availableEngines: [String] = []
        
        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)
            
            // Perform real-time availability check
            if engine.isAvailable {
                availableEngines.append(engineType.rawValue)
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                    AppLog.shared.summarization("\(engineType.rawValue) is available", level: .debug)
                }
            } else {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
                    AppLog.shared.summarization("\(engineType.rawValue) is not available", level: .debug)
                }
            }
        }
        
        let sortedEngines = availableEngines.sorted()
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Available engines: \(sortedEngines)", level: .debug)
        }
        
        return sortedEngines
    }
    
    func getComingSoonEngines() -> [String] {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Checking coming soon engines...", level: .debug)
        }
        
        // Get all engine types
        let allEngineTypes = AIEngineFactory.getAllEngines()
        let availableEngineNames = Set(getAvailableEnginesOnly())
        
        // Filter out available engines to find coming soon engines
        let comingSoonEngines = allEngineTypes
            .map { $0.rawValue }
            .filter { !availableEngineNames.contains($0) }
            .sorted()
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Coming soon engines: \(comingSoonEngines)", level: .debug)
        }
        
        return comingSoonEngines
    }
    
    // MARK: - Real-time Availability Checking
    
    func checkEngineAvailability(_ engineName: String) async -> (isAvailable: Bool, errorMessage: String?) {
        AppLog.shared.summarization("Checking real-time availability for '\(engineName)'", level: .debug)
        
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
        AppLog.shared.summarization("\(engineName) basic availability: \(isAvailable)", level: .debug)

        if !isAvailable {
            return (false, "Engine not available")
        }

        // For engines that support connection testing, perform additional checks
        if engineName.contains("OpenAI") || engineName.contains("Ollama") {
            // Try to perform a connection test if the engine supports it
            if let testableEngine = engine as? (any SummarizationEngine & ConnectionTestable) {
                let isConnected = await testableEngine.testConnection()
                if isConnected {
                    AppLog.shared.summarization("\(engineName) connection test successful")
                    return (true, nil)
                } else {
                    AppLog.shared.summarization("\(engineName) connection test failed", level: .error)
                    return (false, "Connection test failed")
                }
            } else {
                // Engine doesn't support connection testing, rely on basic availability
                AppLog.shared.summarization("\(engineName) doesn't support connection testing", level: .debug)
                return (isAvailable, nil)
            }
        } else {
            // For local engines like On-Device AI, just check basic availability
            return (isAvailable, nil)
        }
    }
    
    func refreshEngineAvailability() async {
        AppLog.shared.summarization("Refreshing engine availability (basic check only)...")
        
        // Get all engine types
        let allEngineTypes = AIEngineFactory.getAllEngines()
        
        // Clear existing engines and reinitialize
        availableEngines.removeAll()
        
        var successfullyInitialized = 0
        let totalEngines = allEngineTypes.count
        
        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)
            
            // Only check basic availability without connection tests to avoid API costs
            let isAvailable = engine.isAvailable
            AppLog.shared.summarization("\(engineType.rawValue) basic availability: \(isAvailable)", level: .debug)

            if isAvailable {
                availableEngines[engineType.rawValue] = engine
                successfullyInitialized += 1
                AppLog.shared.summarization("\(engineType.rawValue) refreshed and available", level: .debug)
            } else {
                AppLog.shared.summarization("\(engine.name) not available", level: .debug)
            }
        }
        
        // Update current engine if needed
        if let currentEngine = currentEngine {
            let currentEngineType = AIEngineType.allCases.first(where: { $0.rawValue == currentEngine.name })
            let currentEngineInstance = AIEngineFactory.createEngine(type: currentEngineType ?? .onDeviceLLM)
            
            if !currentEngineInstance.isAvailable {
                AppLog.shared.summarization("Current engine '\(currentEngine.name)' is no longer available", level: .default)

                // Try to find an available fallback engine
                if let fallbackEngine = availableEngines.values.first {
                    self.currentEngine = fallbackEngine
                    UserDefaults.standard.set(fallbackEngine.name, forKey: "SelectedAIEngine")
                    AppLog.shared.summarization("Switched to fallback engine '\(fallbackEngine.name)'", level: .debug)
                }
            }
        }
        
        AppLog.shared.summarization("Engine availability refresh complete")
        AppLog.shared.summarization("Successfully refreshed: \(successfullyInitialized)/\(totalEngines) engines")
        AppLog.shared.summarization("Available engines: \(getAvailableEnginesOnly())", level: .debug)
        
        // Notify observers of the refresh
        await MainActor.run {
            self.objectWillChange.send()
        }
    }
    
    // MARK: - Connection Testing (Explicit)
    
    func testEngineConnections() async {
        AppLog.shared.summarization("Testing engine connections (explicit)...")
        
        let allEngineTypes = AIEngineFactory.getAllEngines()
        
        for engineType in allEngineTypes {
            let engine = AIEngineFactory.createEngine(type: engineType)
            let engineName = engineType.rawValue
            
            AppLog.shared.summarization("Testing connection for '\(engineName)'", level: .debug)
            
            // Only test connections for engines that support it
            if engineName.contains("OpenAI") || engineName.contains("Ollama") || engineName.contains("Google") {
                if let testableEngine = engine as? (any SummarizationEngine & ConnectionTestable) {
                    let isConnected = await testableEngine.testConnection()
                    if isConnected {
                        AppLog.shared.summarization("\(engineName) connection test successful")
                    } else {
                        AppLog.shared.summarization("\(engineName) connection test failed", level: .error)
                    }
                } else {
                    AppLog.shared.summarization("\(engineName) doesn't support connection testing", level: .debug)
                }
            } else {
                AppLog.shared.summarization("\(engineName) doesn't require connection testing", level: .debug)
            }
        }
        
        AppLog.shared.summarization("Engine connection testing complete")
    }
    
    func getEngineAvailabilityStatus() -> [String: EngineAvailabilityStatus] {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Getting engine availability status...", level: .debug)
        }
        
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
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineAvailabilityChecks() {
            AppLog.shared.summarization("Engine status map created with \(statusMap.count) engines", level: .debug)
        }
        return statusMap
    }
    
    // MARK: - Engine Monitoring and Auto-Recovery
    
    func startEngineMonitoring() {
        AppLog.shared.summarization("Starting engine availability monitoring...")
        
        // Set up a timer to periodically check engine availability
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            Task {
                await self.monitorEngineAvailability()
            }
        }
        
        AppLog.shared.summarization("Engine monitoring started")
    }
    
    private func monitorEngineAvailability() async {
        AppLog.shared.summarization("Monitoring engine availability...", level: .debug)

        guard let currentEngine = currentEngine else {
            AppLog.shared.summarization("No current engine to monitor", level: .default)
            return
        }
        
        // Check if current engine is still available
        let availability = await checkEngineAvailability(currentEngine.name)
        
        if !availability.isAvailable {
            AppLog.shared.summarization("Current engine '\(currentEngine.name)' is no longer available", level: .default)
            AppLog.shared.summarization("Attempting to switch to available engine...", level: .debug)
            
            // Try to find an available engine
            let availableEngines = getAvailableEnginesOnly()
            
            if let newEngineName = availableEngines.first {
                AppLog.shared.summarization("Switching to '\(newEngineName)'", level: .debug)
                setEngine(newEngineName)
                
                // Notify observers of the engine change
                await MainActor.run {
                    self.objectWillChange.send()
                }
            } else {
                AppLog.shared.summarization("No available engines found", level: .error)
            }
        } else {
            AppLog.shared.summarization("Current engine '\(currentEngine.name)' is still available", level: .debug)
        }
    }
    
    func getEngineHealthReport() -> [String: Any] {
        AppLog.shared.summarization("Generating engine health report...", level: .debug)
        
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
        
        AppLog.shared.summarization("Health report generated", level: .debug)
        AppLog.shared.summarization("Available: \(availableCount), Unavailable: \(unavailableCount), Coming Soon: \(comingSoonCount)", level: .debug)
        
        return healthReport
    }
    
    // MARK: - Enhanced Summary Generation
    
    func generateEnhancedSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date, coordinator: AppDataCoordinator? = nil, engineName: String? = nil) async throws -> EnhancedSummaryData {
        // Sync engine from settings before logging to avoid "No current engine set" warning
        syncCurrentEngineWithSettings()
        AppLog.shared.summarization("Starting enhanced summary generation using \(getCurrentEngineName())")
        
        let startTime = Date()
        
        // Count words in the transcript
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }
        
        // If transcript has 50 words or less, return it as-is as the summary
        if words.count <= 50 {
            AppLog.shared.summarization("Transcript has 50 words or less (\(words.count) words) - returning transcript as-is")

            let shortTranscriptSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: recordingName,
                recordingDate: recordingDate,
                summary: "## Transcript\n\n\(text)",
                tasks: [],
                reminders: [],
                titles: [],
                contentType: .general,
                aiEngine: "Local Processing",
                aiModel: "Short Transcript (Displayed As-Is)",
                originalLength: words.count,
                processingTime: Date().timeIntervalSince(startTime)
            )

            // Update UI state on the main thread
            await MainActor.run {
                // Only update UI state - Core Data persistence should be handled by caller
                if let index = self.enhancedSummaries.firstIndex(where: { $0.recordingURL == shortTranscriptSummary.recordingURL }) {
                    self.enhancedSummaries[index] = shortTranscriptSummary
                } else {
                    self.enhancedSummaries.append(shortTranscriptSummary)
                }
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Updated UI state for short transcript summary", level: .debug)
                }
            }

            AppLog.shared.summarization("Short transcript summary created and saved")
            return shortTranscriptSummary
        }
        
        // Validate input before processing for longer transcripts
        let validationResult = errorHandler.validateTranscriptForSummarization(text)
        if !validationResult.isValid {
            let validationError = SummarizationError.insufficientContent
            handleError(validationError, context: "Input Validation", recordingName: recordingName)
            throw validationError
        }

        // Begin a background task so cloud AI calls (OpenAI, Bedrock, Gemini, etc.)
        // can complete even if the user backgrounds the app during summarization.
        beginSummaryBackgroundTask()
        defer { endSummaryBackgroundTask() }

        let engineToUse: SummarizationEngine?

        if let engineName = engineName, let engine = availableEngines[engineName], engine.isAvailable {
            engineToUse = engine
        } else {
            engineToUse = currentEngine
        }

        // Ensure we have a working engine
        guard let engine = engineToUse else {
            AppLog.shared.summarization("No AI engine available, falling back to basic processing", level: .default)
            let fallbackError = SummarizationError.aiServiceUnavailable(service: "No AI engines available")
            handleError(fallbackError, context: "Engine Availability", recordingName: recordingName)
            return try await generateBasicSummary(from: text, for: recordingURL, recordingName: recordingName, recordingDate: recordingDate, coordinator: coordinator)
        }
        
        AppLog.shared.summarization("Using engine: \(engine.name)")
        
        var result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)
        do {
            // Use the AI engine to process the complete text
            result = try await engine.processComplete(text: text)
        } catch {
            // If the task was cancelled, propagate CancellationError immediately — don't retry
            if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                throw CancellationError()
            }
            // Don't retry content safety blocks — they'll just fail again
            if let sumError = error as? SummarizationError, case .contentSafetyBlock = sumError {
                throw sumError
            }
            // Check for guardrail violations that weren't caught at the engine level
            let errorDesc = String(describing: error)
            if errorDesc.contains("guardrailViolation") || errorDesc.contains("unsafe content") {
                throw SummarizationError.contentSafetyBlock(engine: engine.name)
            }
            AppLog.shared.summarization("AI engine failed: \(error) - retrying once", level: .error)
            do {
                try Task.checkCancellation()
                result = try await engine.processComplete(text: text)
                AppLog.shared.summarization("AI engine retry succeeded")
            } catch {
                // If cancelled during retry, propagate CancellationError
                if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                AppLog.shared.summarization("AI engine retry failed: \(error)", level: .error)

                // Handle the error and provide recovery options
                handleError(error, context: "Enhanced Summary Generation", recordingName: recordingName)

                // If the error is already a well-formed SummarizationError, re-throw it as-is
                // to avoid wrapping it in another layer of error messages
                if let summarizationError = error as? SummarizationError {
                    throw summarizationError
                }

                // Provide more specific error messages for Ollama
                if engine.name.contains("Ollama") {
                    if error.localizedDescription.contains("parsing") || error.localizedDescription.contains("JSON") {
                        throw SummarizationError.processingFailed(reason: "Ollama returned text that couldn't be parsed. Please check your Ollama model configuration or try a different model.")
                    } else if error.localizedDescription.contains("connection") || error.localizedDescription.contains("server") {
                        throw SummarizationError.networkError(underlying: error)
                    }
                }

                // Check for guardrail violations that weren't caught at the engine level
                let retryErrorDesc = String(describing: error)
                if retryErrorDesc.contains("guardrailViolation") || retryErrorDesc.contains("unsafe content") {
                    throw SummarizationError.contentSafetyBlock(engine: engine.name)
                }

                // STOP HERE - Don't fall back to basic summary automatically
                // Let the user decide what to do instead of silently switching engines
                throw SummarizationError.aiServiceUnavailable(service: engine.name)
            }
        }

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
            aiEngine: engine.engineType,
            aiModel: engine.metadataName,
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: processingTime
        )

        // Validate summary quality
        let qualityReport = errorHandler.validateSummaryQuality(enhancedSummary)
        if qualityReport.qualityLevel == .unacceptable {
            AppLog.shared.summarization("Summary quality is unacceptable, attempting recovery", level: .default)
            handleError(SummarizationError.processingFailed(reason: "Summary quality below threshold"), context: "Summary Quality", recordingName: recordingName)
        }

        // Update UI state on the main thread
        await MainActor.run {
            // Only update UI state - Core Data persistence should be handled by caller
            if let index = self.enhancedSummaries.firstIndex(where: { $0.recordingURL == enhancedSummary.recordingURL }) {
                self.enhancedSummaries[index] = enhancedSummary
            } else {
                self.enhancedSummaries.append(enhancedSummary)
            }
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Updated UI state for enhanced summary", level: .debug)
            }
        }

        // Update the recording name if we generated a better one
        if finalRecordingName != recordingName {
            try await updateRecordingNameWithAI(
                from: recordingName,
                recordingURL: recordingURL,
                transcript: text,
                contentType: result.contentType,
                tasks: result.tasks,
                reminders: result.reminders,
                titles: result.titles,
                coordinator: coordinator
            )
        }

        AppLog.shared.summarization("Enhanced summary generated successfully")
        AppLog.shared.summarization("Summary length: \(result.summary.count) characters", level: .debug)
        AppLog.shared.summarization("Tasks extracted: \(result.tasks.count)", level: .debug)
        AppLog.shared.summarization("Reminders extracted: \(result.reminders.count)", level: .debug)
        AppLog.shared.summarization("Content type: \(result.contentType.rawValue)", level: .debug)
        AppLog.shared.summarization("Recording name: '\(finalRecordingName)'", level: .debug)
        AppLog.shared.summarization("Quality score: \(qualityReport.formattedScore)", level: .debug)

        return enhancedSummary
    }
    
    // MARK: - Background Task Helpers

    private func beginSummaryBackgroundTask() {
        guard summaryBackgroundTaskID == .invalid else { return }
        summaryBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AISummarization") { [weak self] in
            // Expiration handler — iOS is about to kill us
            AppLog.shared.summarization("Background task expiring for summarization", level: .default)
            self?.endSummaryBackgroundTask()
        }
        if summaryBackgroundTaskID != .invalid {
            let remaining = UIApplication.shared.backgroundTimeRemaining
            if remaining != Double.greatestFiniteMagnitude {
                AppLog.shared.summarization("Background task started - \(Int(remaining))s remaining", level: .debug)
            } else {
                AppLog.shared.summarization("Background task started - unlimited time (foreground or audio session active)", level: .debug)
            }
        }
    }

    private func endSummaryBackgroundTask() {
        guard summaryBackgroundTaskID != .invalid else { return }
        AppLog.shared.summarization("Ending summarization background task", level: .debug)
        UIApplication.shared.endBackgroundTask(summaryBackgroundTaskID)
        summaryBackgroundTaskID = .invalid
    }

    // MARK: - Fallback Basic Summary Generation
    
    private func generateBasicSummary(from text: String, for recordingURL: URL, recordingName: String, recordingDate: Date, coordinator: AppDataCoordinator?) async throws -> EnhancedSummaryData {
        AppLog.shared.summarization("Using basic fallback summarization with task/reminder extraction")
        
        let startTime = Date()
        
        // Count words in the transcript
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }
        
        // If transcript has 50 words or less, return it as-is as the summary
        if words.count <= 50 {
            AppLog.shared.summarization("Transcript has 50 words or less (\(words.count) words) - returning transcript as-is")

            let shortTranscriptSummary = EnhancedSummaryData(
                recordingURL: recordingURL,
                recordingName: recordingName,
                recordingDate: recordingDate,
                summary: "## Transcript\n\n\(text)",
                tasks: [],
                reminders: [],
                titles: [],
                contentType: .general,
                aiEngine: "Local Processing",
            aiModel: "Short Transcript (Displayed As-Is)",
                originalLength: words.count,
                processingTime: Date().timeIntervalSince(startTime)
            )

            // Update UI state on the main thread
            await MainActor.run {
                // Only update UI state - Core Data persistence should be handled by caller
                if let index = self.enhancedSummaries.firstIndex(where: { $0.recordingURL == shortTranscriptSummary.recordingURL }) {
                    self.enhancedSummaries[index] = shortTranscriptSummary
                } else {
                    self.enhancedSummaries.append(shortTranscriptSummary)
                }
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("Updated UI state for short transcript summary", level: .debug)
                }
            }

            AppLog.shared.summarization("Short transcript summary created and saved")
            return shortTranscriptSummary
        }
        
        // Validate input for basic processing for longer transcripts
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
            aiEngine: "Local Processing",
            aiModel: "Basic Extraction",
            originalLength: text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
            processingTime: processingTime
        )
        
        // Validate basic summary quality
        let qualityReport = errorHandler.validateSummaryQuality(enhancedSummary)
        if qualityReport.qualityLevel == SummaryQualityLevel.unacceptable {
            AppLog.shared.summarization("Basic summary quality is unacceptable", level: .default)
            handleError(SummarizationError.processingFailed(reason: "Basic summary quality below threshold"), context: "Basic Summary Quality", recordingName: recordingName)
        }
        
        // Update UI state on the main thread
        await MainActor.run {
            // Only update UI state - Core Data persistence should be handled by caller
            if let index = self.enhancedSummaries.firstIndex(where: { $0.recordingURL == enhancedSummary.recordingURL }) {
                self.enhancedSummaries[index] = enhancedSummary
            } else {
                self.enhancedSummaries.append(enhancedSummary)
            }
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLog.shared.summarization("Updated UI state for basic enhanced summary", level: .debug)
            }
        }
        
        // Update the recording name if we generated a better one
        if finalRecordingName != recordingName {
            try await updateRecordingNameWithAI(
                from: recordingName,
                recordingURL: recordingURL,
                transcript: text,
                contentType: contentType,
                tasks: tasks,
                reminders: reminders,
                titles: [],
                coordinator: coordinator
            )
        }
        
        AppLog.shared.summarization("Basic summary with extraction completed")
        AppLog.shared.summarization("Tasks extracted: \(tasks.count)", level: .debug)
        AppLog.shared.summarization("Reminders extracted: \(reminders.count)", level: .debug)
        AppLog.shared.summarization("Recording name: '\(finalRecordingName)'", level: .debug)
        AppLog.shared.summarization("Quality score: \(qualityReport.formattedScore)", level: .debug)
        
        return enhancedSummary
    }
    
    private func createBasicSummary(from text: String, contentType: ContentType) -> String {
        AppLog.shared.summarization("Creating content-type optimized summary for: \(contentType.rawValue)", level: .debug)
        
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
        // Note: Removed redundant "Summary" labels since user is already in summary context
        let contentTypeHeader = switch contentType {
        case .meeting: "**Key Decisions & Action Items:**"
        case .personalJournal: "**Key Insights & Experiences:**"
        case .technical: "**Key Concepts & Solutions:**"  
        case .general: "**Main Points:**"
        }
        
        // Format the top sentences as bullet points
        let bulletPoints = topSentences.map { sentence in
            let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            return "• \(cleanSentence)"
        }.joined(separator: "\n")
        
        let summary = "\(contentTypeHeader)\n\n\(bulletPoints)"
        AppLog.shared.summarization("Content-type optimized summary created: \(summary.count) characters", level: .debug)
        
        return summary
    }
    
    // MARK: - Task and Reminder Extraction
    
    func extractTasksFromText(_ text: String) async throws -> [TaskItem] {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Extracting tasks using dedicated TaskExtractor", level: .debug)
        }
        
        // First try to use the current AI engine if available
        if let engine = currentEngine {
            do {
                let tasks = try await engine.extractTasks(from: text)
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("AI engine extracted \(tasks.count) tasks", level: .debug)
                }
                return tasks
            } catch {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("AI engine task extraction failed, using fallback extractor", level: .debug)
                    AppLog.shared.summarization("Task extraction error: \(error)", level: .debug)
                }
            }
        }
        
        // Fallback to dedicated TaskExtractor
        let tasks = taskExtractor.extractTasks(from: text)
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("TaskExtractor extracted \(tasks.count) tasks", level: .debug)
        }
        return tasks
    }
    
    func extractRemindersFromText(_ text: String) async throws -> [ReminderItem] {
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("Extracting reminders using dedicated ReminderExtractor", level: .debug)
        }
        
        // First try to use the current AI engine if available
        if let engine = currentEngine {
            do {
                let reminders = try await engine.extractReminders(from: text)
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("AI engine extracted \(reminders.count) reminders", level: .debug)
                }
                return reminders
            } catch {
                // Only log if verbose logging is enabled
                if PerformanceOptimizer.shouldLogEngineInitialization() {
                    AppLog.shared.summarization("AI engine reminder extraction failed, using fallback extractor", level: .debug)
                    AppLog.shared.summarization("Reminder extraction error: \(error)", level: .debug)
                }
            }
        }
        
        // Fallback to dedicated ReminderExtractor
        let reminders = reminderExtractor.extractReminders(from: text)
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLog.shared.summarization("ReminderExtractor extracted \(reminders.count) reminders", level: .debug)
        }
        return reminders
    }
    
    func extractTitlesFromText(_ text: String) async throws -> [TitleItem] {
        AppLog.shared.summarization("Extracting titles using AI engine", level: .debug)
        
        // First try to use the current AI engine if available
        if let engine = currentEngine {
            do {
                let titles = try await engine.extractTitles(from: text)
                AppLog.shared.summarization("AI engine extracted \(titles.count) titles", level: .debug)
                return titles
            } catch {
                AppLog.shared.summarization("AI engine title extraction failed", level: .default)
                AppLog.shared.summarization("Title extraction error: \(error)", level: .debug)
            }
        }
        
        // Fallback: return empty array for now
        AppLog.shared.summarization("No title extraction fallback available", level: .debug)
        return []
    }
    
    func extractTasksAndRemindersFromText(_ text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        AppLog.shared.summarization("Extracting tasks and reminders from text", level: .debug)
        
        async let tasks = extractTasksFromText(text)
        async let reminders = extractRemindersFromText(text)
        
        let (taskResults, reminderResults) = try await (tasks, reminders)
        
        AppLog.shared.summarization("Extracted \(taskResults.count) tasks and \(reminderResults.count) reminders", level: .debug)
        return (taskResults, reminderResults)
    }
    
    func extractTasksRemindersAndTitlesFromText(_ text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) {
        AppLog.shared.summarization("Extracting tasks, reminders, and titles from text", level: .debug)
        
        async let tasks = extractTasksFromText(text)
        async let reminders = extractRemindersFromText(text)
        async let titles = extractTitlesFromText(text)
        
        let (taskResults, reminderResults, titleResults) = try await (tasks, reminders, titles)
        
        AppLog.shared.summarization("Extracted \(taskResults.count) tasks, \(reminderResults.count) reminders, and \(titleResults.count) titles", level: .debug)
        return (taskResults, reminderResults, titleResults)
    }
    
    // MARK: - Content Type Influenced Processing
    
    func generateContentTypeOptimizedSummary(from text: String, contentType: ContentType) async throws -> String {
        AppLog.shared.summarization("Generating content-type optimized summary for \(contentType.rawValue)", level: .debug)
        
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
        AppLog.shared.summarization("Generating meeting-focused summary", level: .debug)
        
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
        
        return "**Key Decisions & Action Items:**\n\n\(bulletPoints)"
    }
    
    private func generateJournalSummary(from text: String) async throws -> String {
        AppLog.shared.summarization("Generating journal-focused summary", level: .debug)
        
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
        AppLog.shared.summarization("Generating technical-focused summary", level: .debug)
        
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
        AppLog.shared.summarization("Generating general summary", level: .debug)
        
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
                    AppLog.shared.summarization("Regenerated summary for: \(name)")
                } catch {
                    AppLog.shared.summarization("Failed to regenerate summary for \(name): \(error)", level: .error)
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
        AppLog.shared.summarization("Error in \(context): \(error.localizedDescription)", level: .error)
        
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
        AppLog.shared.summarization("Performing recovery action: \(action.title)", level: .debug)
        
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
            AppLog.shared.summarization("Recovery action not implemented: \(action.title)", level: .default)
        }
    }
    
    // MARK: - Recovery Action Implementations
    
    private func retryLastOperation(for recordingURL: URL, recordingName: String) async {
        AppLog.shared.summarization("Retrying last operation", level: .debug)
        
        // Get the transcript and retry summary generation
        if let transcript = transcriptManager.getTranscript(for: recordingURL) {
            do {
                _ = try await generateEnhancedSummary(
                    from: transcript.fullText,
                    for: recordingURL,
                    recordingName: recordingName,
                    recordingDate: Date()
                )
                // UI state updated within generateEnhancedSummary
                clearCurrentError()
            } catch {
                handleError(error, context: "Retry Operation", recordingName: recordingName)
            }
        }
    }
    
    private func switchToNextAvailableEngine() async {
        AppLog.shared.summarization("Switching to next available engine", level: .debug)
        
        let availableEngines = getAvailableEnginesOnly()
        let currentEngineName = getCurrentEngineName()
        
        // Find next available engine
        if let currentIndex = availableEngines.firstIndex(of: currentEngineName),
           currentIndex + 1 < availableEngines.count {
            let nextEngine = availableEngines[currentIndex + 1]
            setEngine(nextEngine)
            AppLog.shared.summarization("Switched to engine: \(nextEngine)")
        } else if !availableEngines.isEmpty {
            // Wrap around to first engine
            setEngine(availableEngines[0])
            AppLog.shared.summarization("Switched to first available engine: \(availableEngines[0])")
        }
    }
    
    private func processWithShorterChunks(for recordingURL: URL, recordingName: String) async {
        AppLog.shared.summarization("Processing with shorter chunks", level: .debug)
        
        if let transcript = transcriptManager.getTranscript(for: recordingURL) {
            // Use TokenManager to split into smaller chunks
            let chunks = TokenManager.chunkText(transcript.fullText, maxTokens: 1000)
            
            var combinedSummary = ""
            var allTasks: [TaskItem] = []
            var allReminders: [ReminderItem] = []
            
            for (index, chunk) in chunks.enumerated() {
                AppLog.shared.summarization("Processing chunk \(index + 1)/\(chunks.count)", level: .debug)
                
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
                    AppLog.shared.summarization("Chunk \(index + 1) failed: \(error.localizedDescription)", level: .error)
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
                aiEngine: "Local Processing",
            aiModel: "Chunked Processing",
                originalLength: transcript.fullText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count,
                processingTime: Date().timeIntervalSince(Date())
            )
            
            // Only update UI state - Core Data persistence should be handled by caller
            if let index = enhancedSummaries.firstIndex(where: { $0.recordingURL == combinedEnhancedSummary.recordingURL }) {
                enhancedSummaries[index] = combinedEnhancedSummary
            } else {
                enhancedSummaries.append(combinedEnhancedSummary)
            }
            clearCurrentError()
        }
    }
    
    private func retryWithDelay(for recordingURL: URL, recordingName: String) async {
        AppLog.shared.summarization("Waiting before retry", level: .debug)
        
        // Wait for 5 seconds before retrying
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        
        await retryLastOperation(for: recordingURL, recordingName: recordingName)
    }
    
    private func checkNetworkAndRetry(for recordingURL: URL, recordingName: String) async {
        AppLog.shared.summarization("Checking network connection", level: .debug)
        
        // Simple network check
        let isNetworkAvailable = await checkNetworkAvailability()
        
        if isNetworkAvailable {
            AppLog.shared.summarization("Network is available, retrying")
            await retryLastOperation(for: recordingURL, recordingName: recordingName)
        } else {
            AppLog.shared.summarization("Network is not available", level: .error)
            handleError(
                SummarizationError.networkError(underlying: NSError(domain: "NetworkError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])),
                context: "Network Check",
                recordingName: recordingName
            )
        }
    }
    
    private func switchToOfflineEngine() async {
        AppLog.shared.summarization("Switching to offline engine", level: .debug)
        
        // Try to switch to On-Device AI (offline)
        if getAvailableEnginesOnly().contains("On-Device AI") {
            setEngine("On-Device AI")
            AppLog.shared.summarization("Switched to offline engine")
        } else {
            AppLog.shared.summarization("No offline engine available", level: .error)
            handleError(
                SummarizationError.aiServiceUnavailable(service: "No offline engine available"),
                context: "Offline Engine Switch"
            )
        }
    }
    
    private func createManualSummary(for recordingURL: URL, recordingName: String) async {
        AppLog.shared.summarization("Creating manual summary placeholder", level: .debug)
        
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
            aiEngine: "Local Processing",
            aiModel: "Manual Required",
            originalLength: 0,
            processingTime: 0
        )
        
        // Only update UI state - Core Data persistence should be handled by caller
        if let index = enhancedSummaries.firstIndex(where: { $0.recordingURL == manualSummary.recordingURL }) {
            enhancedSummaries[index] = manualSummary
        } else {
            enhancedSummaries.append(manualSummary)
        }
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
        AppLog.shared.summarization("Generating intelligent recording name", level: .debug)
        
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
        
        AppLog.shared.summarization("Generated name: '\(validatedName)'", level: .debug)
        return validatedName
    }
    
    func updateRecordingNameWithAI(from oldName: String, recordingURL: URL, transcript: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], coordinator: AppDataCoordinator?) async throws {
        AppLog.shared.summarization("Updating recording name using AI analysis", level: .debug)
        
        // Generate intelligent name using AI analysis
        let newName = generateIntelligentRecordingName(from: transcript, contentType: contentType, tasks: tasks, reminders: reminders, titles: titles)
        
        // Only update if the new name is different and meaningful
        if newName != oldName && !newName.isEmpty && newName != "Recording" {
            AppLog.shared.summarization("Updating name from '\(oldName)' to '\(newName)'", level: .debug)
            if let coordinator = coordinator {
                try await updateRecordingName(from: oldName, to: newName, recordingURL: recordingURL, coordinator: coordinator)
            } else {
                AppLog.shared.summarization("No coordinator provided, skipping Core Data update", level: .default)
            }
            
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
                    aiEngine: existingSummary.aiEngine,
            aiModel: existingSummary.aiModel,
                    originalLength: existingSummary.originalLength,
                    processingTime: existingSummary.processingTime
                )
                // Only update UI state - Core Data persistence should be handled by caller
                if let index = enhancedSummaries.firstIndex(where: { $0.recordingURL == updatedSummary.recordingURL }) {
                    enhancedSummaries[index] = updatedSummary
                } else {
                    enhancedSummaries.append(updatedSummary)
                }
                AppLog.shared.summarization("Updated enhanced summary UI state with new name", level: .debug)
            }
        } else {
            AppLog.shared.summarization("Keeping original name '\(oldName)' (no meaningful improvement found)", level: .debug)
        }
    }
    
    private func updateRecordingName(from oldName: String, to newName: String, recordingURL: URL, coordinator: AppDataCoordinator) async throws {
        AppLog.shared.summarization("Starting file rename process: '\(oldName)' -> '\(newName)'", level: .debug)
        
        // Get the recording from Core Data using the coordinator
        guard let recordingEntry = coordinator.getRecording(url: recordingURL),
              let recordingId = recordingEntry.id else {
            AppLog.shared.summarization("Could not find recording in Core Data for URL: \(recordingURL)", level: .error)
            return
        }
        
        AppLog.shared.summarization("Found recording in Core Data with ID: \(recordingId)", level: .debug)
        
        // Use the Core Data workflow manager to update the recording name
        // This will handle both the Core Data update and file renaming
        coordinator.updateRecordingName(recordingId: recordingId, newName: newName)
        
        AppLog.shared.summarization("Recording name updated using Core Data workflow", level: .debug)
        
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
                aiEngine: existingSummary.aiEngine,
            aiModel: existingSummary.aiModel,
                originalLength: existingSummary.originalLength,
                processingTime: existingSummary.processingTime
            )
            // Only update UI state - Core Data persistence should be handled by caller
            if let index = enhancedSummaries.firstIndex(where: { $0.recordingURL == updatedSummary.recordingURL }) {
                enhancedSummaries[index] = updatedSummary
            } else {
                enhancedSummaries.append(updatedSummary)
            }
            AppLog.shared.summarization("Updated enhanced summary UI state with new name", level: .debug)
        }
        
        // Notify UI to refresh recordings list
        await MainActor.run {
            NotificationCenter.default.post(
                name: NSNotification.Name("RecordingRenamed"),
                object: nil,
                userInfo: [
                    "oldName": oldName,
                    "newName": newName,
                    "oldURL": recordingURL,
                    "newURL": recordingURL // The URL will be updated by the workflow manager
                ]
            )
        }
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
        
        let engineUsage = Dictionary(grouping: enhancedSummaries, by: { $0.aiModel })
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
    
    /// DEPRECATED: UserDefaults storage is legacy - Core Data is now the source of truth
    @available(*, deprecated, message: "Core Data is now the source of truth for summary persistence")
    private func saveEnhancedSummariesToDisk() {
        // This method is deprecated and should not be used
        // Core Data handles all persistence now
        AppLog.shared.summarization("saveEnhancedSummariesToDisk() called - this is deprecated, use Core Data instead", level: .default)
    }
    
    /// DEPRECATED: UserDefaults loading is legacy - Core Data loads summaries now
    @available(*, deprecated, message: "Core Data is now the source of truth for summary loading")
    private func loadEnhancedSummaries() {
        // This method is deprecated - summaries should be loaded from Core Data
        // Keep for potential one-time migration only
        guard let data = UserDefaults.standard.data(forKey: enhancedSummariesKey) else { 
            return 
        }
        do {
            let legacySummaries = try JSONDecoder().decode([EnhancedSummaryData].self, from: data)
            AppLog.shared.summarization("Found \(legacySummaries.count) legacy summaries in UserDefaults - consider migrating to Core Data", level: .default)
        } catch {
            AppLog.shared.summarization("Failed to load legacy enhanced summaries: \(error)", level: .error)
        }
    }
}
