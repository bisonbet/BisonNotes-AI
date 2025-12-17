//
//  MLXService.swift
//  BisonNotes AI
//
//  Service for on-device LLM inference using MLX Swift
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXAudio
import AVFoundation

// MARK: - MLX Configuration

struct MLXConfig {
    let modelName: String
    let huggingFaceRepoId: String
    let maxTokens: Int
    let temperature: Float
    let topP: Float

    var cacheDirectory: URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesDirectory.appendingPathComponent("mlx-models").appendingPathComponent(modelName)
    }

    static let `default` = MLXConfig(
        modelName: "Qwen3-1.7B-4bit",
        huggingFaceRepoId: "mlx-community/Qwen3-1.7B-4bit",
        maxTokens: 1024, // Reduced from 2048 to lower memory pressure during generation
        temperature: 0.1,
        topP: 0.9
    )
}

// MARK: - Predefined Models

enum MLXModel: String, CaseIterable {
    case qwen317B4bit = "Qwen3-1.7B-4bit"
    case gemma34B4bitDWQ = "gemma-3-4b-it-4bit-DWQ"
    case qwen34B4bit2507 = "Qwen3-4B-Instruct-2507-4bit"
    case qwen38B4bit = "Qwen3-8B-4bit"

    var modelType: MLXModelType {
        return .summarization
    }

    /// Returns available models based on device RAM
    /// - 4GB-6GB RAM: Qwen 3 1.7B only (ultra-compact)
    /// - 6GB-8GB RAM: Qwen 3 1.7B, Gemma 3 4B and Qwen 3 4B models
    /// - 8GB+ RAM: All models including Qwen 3 8B
    static var availableModels: [MLXModel] {
        if DeviceCapabilities.supports8GBModels {
            // 8GB+ RAM: All models available
            return allCases
        } else if DeviceCapabilities.supportsOnDeviceLLM {
            // 6GB-8GB RAM: All models except 8B
            return [.qwen317B4bit, .gemma34B4bitDWQ, .qwen34B4bit2507]
        } else {
            // 4GB-6GB RAM: Only ultra-compact 1.7B model
            return [.qwen317B4bit]
        }
    }
}

// MARK: - Whisper Models for Transcription

enum MLXWhisperModel: String, CaseIterable {
    case whisperLargeV3Turbo4bit = "whisper-large-v3-turbo-4bit"
    case whisperMedium4bit = "whisper-medium-4bit"
    case whisperBase4bit = "whisper-base-4bit"

    var huggingFaceRepoId: String {
        switch self {
        case .whisperLargeV3Turbo4bit:
            return "mlx-community/whisper-large-v3-turbo-4bit"
        case .whisperMedium4bit:
            return "mlx-community/whisper-medium-4bit"
        case .whisperBase4bit:
            return "mlx-community/whisper-base-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .whisperLargeV3Turbo4bit:
            return "Whisper Large v3 Turbo (4-bit)"
        case .whisperMedium4bit:
            return "Whisper Medium (4-bit)"
        case .whisperBase4bit:
            return "Whisper Base (4-bit)"
        }
    }

    var description: String {
        switch self {
        case .whisperLargeV3Turbo4bit:
            return "Best quality, fastest large model - OpenAI's Whisper Large v3 Turbo optimized for speed (~1.6GB)"
        case .whisperMedium4bit:
            return "Balanced quality and speed - Good for most recordings (~800MB)"
        case .whisperBase4bit:
            return "Fast and compact - Quick transcription for shorter recordings (~150MB)"
        }
    }

    var estimatedSize: String {
        switch self {
        case .whisperLargeV3Turbo4bit:
            return "~1.6 GB"
        case .whisperMedium4bit:
            return "~800 MB"
        case .whisperBase4bit:
            return "~150 MB"
        }
    }

    var modelType: MLXModelType {
        return .transcription
    }

    /// Returns available Whisper models based on device RAM
    /// - 4GB-6GB RAM: Base and Medium models only
    /// - 6GB+ RAM: All models including Large v3 Turbo
    static var availableModels: [MLXWhisperModel] {
        if DeviceCapabilities.supportsWhisperLarge {
            // 6GB+ RAM: All models available
            return allCases
        } else if DeviceCapabilities.supportsWhisperBasic {
            // 4GB-6GB RAM: Only base and medium
            return [.whisperBase4bit, .whisperMedium4bit]
        } else {
            // Less than 4GB RAM: No models available
            return []
        }
    }
}

// MARK: - Model Type

enum MLXModelType {
    case summarization
    case transcription
}

extension MLXModel {
    var huggingFaceRepoId: String {
        switch self {
        case .qwen317B4bit:
            return "mlx-community/Qwen3-1.7B-4bit"
        case .gemma34B4bitDWQ:
            return "mlx-community/gemma-3-4b-it-4bit-DWQ"
        case .qwen34B4bit2507:
            return "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        case .qwen38B4bit:
            return "mlx-community/Qwen3-8B-4bit"
        }
    }

    var displayName: String {
        switch self {
        case .qwen317B4bit:
            return "Qwen 3 1.7B (4-bit)"
        case .gemma34B4bitDWQ:
            return "Gemma 3 4B (4-bit DWQ)"
        case .qwen34B4bit2507:
            return "Qwen 3 4B (4-bit)"
        case .qwen38B4bit:
            return "Qwen 3 8B (4-bit)"
        }
    }

    var description: String {
        switch self {
        case .qwen317B4bit:
            return "Ultra-compact model - Fastest processing with minimal memory use, great for devices with limited RAM (~1.1GB)"
        case .gemma34B4bitDWQ:
            return "Reasoning model - Best quality, will take longer but provides better analysis (~2.5GB)"
        case .qwen34B4bit2507:
            return "Faster processing - Quick and efficient for most tasks (~2.4GB)"
        case .qwen38B4bit:
            return "Highest quality - 8B model for superior results, requires 8GB+ RAM (~4.8GB)"
        }
    }

    var estimatedSize: String {
        switch self {
        case .qwen317B4bit:
            return "~1.1 GB"
        case .gemma34B4bitDWQ:
            return "~2.5 GB"
        case .qwen34B4bit2507:
            return "~2.4 GB"
        case .qwen38B4bit:
            return "~4.8 GB"
        }
    }
}

// MARK: - Download Progress

enum MLXDownloadState {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case error(String)
}

// MARK: - MLX Service

class MLXService: ObservableObject {
    private var config: MLXConfig
    @Published var downloadState: MLXDownloadState = .notDownloaded
    @Published var isModelLoaded = false
    @Published var memoryWarningActive = false

    private var chatSession: ChatSession?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(config: MLXConfig = .default) {
        self.config = config
        setupMemoryPressureMonitoring()
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    // MARK: - Memory Pressure Monitoring

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data

            if event.contains(.critical) {
                print("🚨 CRITICAL MEMORY PRESSURE - Unloading MLX model immediately")
                Task { @MainActor in
                    self.memoryWarningActive = true
                    self.unloadModel()
                }
            } else if event.contains(.warning) {
                print("⚠️ MEMORY PRESSURE WARNING - Consider unloading model after completion")
                Task { @MainActor in
                    self.memoryWarningActive = true
                }
            }
        }

        source.resume()
        memoryPressureSource = source
    }

    private func checkMemoryAvailability() -> Bool {
        let (free, used, total) = getMemoryInfo()
        let availableGB = free

        // Need at least 1GB free for generation safety margin
        if availableGB < 1.0 {
            print("⚠️ Low memory: \(String(format: "%.2f", availableGB))GB available")
            print("   Consider freeing memory before generation")
            return false
        }

        // Warn if we're using more than 70% of total memory
        let usagePercent = (used / total) * 100
        if usagePercent > 70 {
            print("⚠️ High memory usage: \(String(format: "%.1f", usagePercent))%")
        }

        return true
    }

    // MARK: - Memory Monitoring

    private func getMemoryInfo() -> (free: Double, used: Double, total: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let usedGB = Double(info.resident_size) / 1_073_741_824.0
            let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            let freeGB = totalGB - usedGB
            return (freeGB, usedGB, totalGB)
        }

        return (0, 0, 0)
    }

    private func logMemory(label: String) {
        let (free, used, total) = getMemoryInfo()
        print("💾 \(label): Used: \(String(format: "%.2f", used))GB / Free: \(String(format: "%.2f", free))GB / Total: \(String(format: "%.2f", total))GB")
    }

    // MARK: - Model Management

    func isModelDownloaded() -> Bool {
        // Check UserDefaults first (reliable indicator that model was successfully loaded before)
        let userDefaultsKey = "mlx_model_downloaded_\(config.modelName)"
        let markedAsDownloaded = UserDefaults.standard.bool(forKey: userDefaultsKey)

        print("🔍 Checking if model '\(config.modelName)' is downloaded")
        print("   UserDefaults says: \(markedAsDownloaded)")

        if markedAsDownloaded {
            return true
        }

        // Fallback: Check if our custom cache directory exists
        let modelPath = config.cacheDirectory
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: modelPath.path, isDirectory: &isDirectory)

        print("   Checking path: \(modelPath.path)")
        print("   Directory exists: \(exists), Is directory: \(isDirectory.boolValue)")

        if exists && isDirectory.boolValue {
            let configPath = modelPath.appendingPathComponent("config.json")
            let configExists = FileManager.default.fileExists(atPath: configPath.path)
            print("   config.json exists: \(configExists)")

            if configExists {
                // Found it via file check, mark in UserDefaults for future
                UserDefaults.standard.set(true, forKey: userDefaultsKey)
                return true
            }
        }

        return false
    }

    @MainActor
    func downloadModel(huggingFaceRepoId: String? = nil) async throws {
        let repoId = huggingFaceRepoId ?? config.huggingFaceRepoId

        print("🔽 MLXService: Starting model download from \(repoId)")
        logMemory(label: "Before download")
        downloadState = .downloading(progress: 0.0)

        do {
            // Download and load the model using modern MLXLLM API
            // This will automatically download from Hugging Face if not cached
            // MLX handles its own caching internally
            let loadedModel = try await MLXLMCommon.loadModel(id: repoId)
            chatSession = ChatSession(loadedModel)
            isModelLoaded = true

            // Mark as downloaded in UserDefaults since MLX handles its own cache
            UserDefaults.standard.set(true, forKey: "mlx_model_downloaded_\(config.modelName)")
            print("   Marked model as downloaded in UserDefaults")

            downloadState = .downloaded
            logMemory(label: "After download & load")
            print("✅ MLXService: Model downloaded and loaded successfully")

        } catch {
            print("❌ MLXService: Model download failed: \(error)")
            downloadState = .error(error.localizedDescription)
            throw error
        }
    }

    @MainActor
    func loadModel() async throws {
        guard isModelDownloaded() else {
            print("⚠️ MLXService: Model not downloaded, initiating download")
            try await downloadModel()
            return
        }

        print("📦 MLXService: Loading model from cache")
        logMemory(label: "Before load")

        do {
            // Load the model using modern MLXLLM API
            let loadedModel = try await MLXLMCommon.loadModel(id: config.huggingFaceRepoId)
            chatSession = ChatSession(loadedModel)
            isModelLoaded = true

            // Mark as downloaded since we successfully loaded it
            UserDefaults.standard.set(true, forKey: "mlx_model_downloaded_\(config.modelName)")

            logMemory(label: "After load")
            print("✅ MLXService: Model loaded successfully")

        } catch {
            print("❌ MLXService: Model loading failed: \(error)")
            isModelLoaded = false
            throw error
        }
    }

    func unloadModel() {
        logMemory(label: "Before unload")
        chatSession = nil
        isModelLoaded = false
        logMemory(label: "After unload")
        print("🗑️ MLXService: Model unloaded")
    }

    func deleteModel() throws {
        guard isModelDownloaded() else {
            print("⚠️ MLXService: Model not downloaded, nothing to delete")
            return
        }

        print("🗑️ MLXService: Deleting model from cache")

        do {
            try FileManager.default.removeItem(at: config.cacheDirectory)
            downloadState = .notDownloaded
            unloadModel()
            print("✅ MLXService: Model deleted successfully")

        } catch {
            print("❌ MLXService: Model deletion failed: \(error)")
            throw error
        }
    }

    // MARK: - Text Generation

    func generateSummary(from text: String) async throws -> String {
        // Check memory availability before generation
        if !checkMemoryAvailability() {
            print("⚠️ Low memory detected, attempting to free resources")
            // Try to free memory by clearing the session if we can reload it
            if isModelLoaded {
                print("   Reloading model to clear memory")
                unloadModel()
            }
        }

        guard let session = chatSession else {
            if !isModelLoaded {
                try await loadModel()
            }
            guard let session = chatSession else {
                throw MLXError.modelNotLoaded
            }
            return try await performGeneration(with: session, text: text, type: .summary)
        }

        return try await performGeneration(with: session, text: text, type: .summary)
    }

    func extractTasksAndReminders(from text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        guard let session = chatSession else {
            if !isModelLoaded {
                try await loadModel()
            }
            guard let session = chatSession else {
                throw MLXError.modelNotLoaded
            }
            return try await performExtractionGeneration(with: session, text: text)
        }

        return try await performExtractionGeneration(with: session, text: text)
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        guard let session = chatSession else {
            if !isModelLoaded {
                try await loadModel()
            }
            guard let session = chatSession else {
                throw MLXError.modelNotLoaded
            }
            return try await performTitleGeneration(with: session, text: text)
        }

        return try await performTitleGeneration(with: session, text: text)
    }

    func processComplete(from text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        guard let session = chatSession else {
            if !isModelLoaded {
                try await loadModel()
            }
            guard let session = chatSession else {
                throw MLXError.modelNotLoaded
            }
            return try await performCompleteGeneration(with: session, text: text)
        }

        return try await performCompleteGeneration(with: session, text: text)
    }

    // MARK: - Private Generation Methods

    private enum PromptType {
        case summary
        case extraction
        case titles
        case complete
    }

    private func performGeneration(with session: ChatSession, text: String, type: PromptType) async throws -> String {
        let prompt = createPrompt(for: type, text: text)

        print("🤖 MLXService: Generating response for \(type)")
        logMemory(label: "Before generation")

        // Start continuous memory monitoring during generation
        let monitoringTask = Task {
            var peakUsed: Double = 0
            var iteration = 0
            while !Task.isCancelled {
                autoreleasepool {
                    let (_, used, _) = getMemoryInfo()
                    if used > peakUsed {
                        peakUsed = used
                    }
                    iteration += 1
                    if iteration % 10 == 0 { // Log every 10th check (every ~0.5 seconds)
                        logMemory(label: "During generation (iteration \(iteration))")
                        print("   📊 Peak so far: \(String(format: "%.2f", peakUsed))GB")
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // Check every 50ms
            }
        }

        do {
            // Use modern ChatSession API - respond() method handles the generation
            // Note: autoreleasepool works automatically in async contexts for autoreleased objects
            let response = try await session.respond(to: prompt)

            // Stop monitoring
            monitoringTask.cancel()

            // Wrap cleanup in autoreleasepool to immediately release temporary string objects
            let trimmedResponse = autoreleasepool {
                response.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            logMemory(label: "After generation")
            print("✅ MLXService: Generation complete (\(trimmedResponse.count) characters)")
            return trimmedResponse

        } catch {
            // Stop monitoring on error
            monitoringTask.cancel()

            print("❌ MLXService: Generation failed: \(error)")
            throw MLXError.generationFailed(error.localizedDescription)
        }
    }

    private func performExtractionGeneration(with session: ChatSession, text: String) async throws -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        let response = try await performGeneration(with: session, text: text, type: .extraction)
        return parseTasksAndReminders(from: response)
    }

    private func performTitleGeneration(with session: ChatSession, text: String) async throws -> [TitleItem] {
        let response = try await performGeneration(with: session, text: text, type: .titles)
        return parseTitles(from: response)
    }

    private func performCompleteGeneration(with session: ChatSession, text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let response = try await performGeneration(with: session, text: text, type: .complete)
        return parseCompleteResponse(from: response, originalText: text)
    }

    // MARK: - Prompt Creation

    private func createPrompt(for type: PromptType, text: String) -> String {
        switch type {
        case .summary:
            return """
            Please provide a comprehensive summary of the following text using proper Markdown formatting:

            Use the following Markdown elements as appropriate:
            - **Bold text** for key points and important information
            - *Italic text* for emphasis
            - ## Headers for main sections
            - ### Subheaders for subsections
            - • Bullet points for lists
            - 1. Numbered lists for sequential items

            Content to summarize:
            \(text)

            Focus on the key points and main ideas. Keep the summary clear, informative, and well-structured with proper markdown formatting.
            """

        case .extraction:
            return """
            Extract personal and relevant actionable tasks and reminders from the following text:

            \(text)

            IMPORTANT GUIDELINES:
            - Focus ONLY on tasks and reminders that are personal to the speaker or their immediate context
            - Avoid tasks related to national news, public figures, celebrities, or general world events
            - Include specific action items, appointments, deadlines, or time-sensitive commitments

            Format your response as:
            TASKS:
            • [task 1]
            • [task 2]

            REMINDERS:
            • [reminder 1]
            • [reminder 2]
            """

        case .titles:
            return """
            Suggest 3-5 appropriate titles for the following content:

            \(text)

            Provide concise, descriptive titles that capture the main topic or theme.
            Format as a bulleted list:
            • [title 1]
            • [title 2]
            """

        case .complete:
            return """
            Analyze the following transcript and provide a comprehensive analysis:

            \(text)

            Please provide:
            1. A detailed summary using proper Markdown formatting (with **bold**, *italic*, headers, etc.)
            2. Personal and relevant actionable tasks (not general news or public events)
            3. Personal and relevant reminders with dates/times (not general world events)
            4. 3-5 suggested titles

            Format your response as:
            SUMMARY:
            [detailed markdown-formatted summary]

            TASKS:
            • [task 1]
            • [task 2]

            REMINDERS:
            • [reminder 1]
            • [reminder 2]

            TITLES:
            • [title 1]
            • [title 2]
            """
        }
    }

    // MARK: - Response Parsing

    private func parseTasksAndReminders(from response: String) -> (tasks: [TaskItem], reminders: [ReminderItem]) {
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []

        let lines = response.components(separatedBy: .newlines)
        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("TASKS:") {
                currentSection = "tasks"
                continue
            } else if trimmed.hasPrefix("REMINDERS:") {
                currentSection = "reminders"
                continue
            }

            if trimmed.isEmpty { continue }

            if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    if currentSection == "tasks" {
                        tasks.append(TaskItem(text: content, priority: .medium, confidence: 0.8))
                    } else if currentSection == "reminders" {
                        let timeRef = ReminderItem.TimeReference(originalText: content)
                        reminders.append(ReminderItem(text: content, timeReference: timeRef, urgency: .later, confidence: 0.8))
                    }
                }
            }
        }

        return (tasks, reminders)
    }

    private func parseTitles(from response: String) -> [TitleItem] {
        var titles: [TitleItem] = []

        let lines = response.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    titles.append(TitleItem(text: content, confidence: 0.8))
                }
            }
        }

        return titles
    }

    private func parseCompleteResponse(from response: String, originalText: String) -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        var summary = ""
        var tasks: [TaskItem] = []
        var reminders: [ReminderItem] = []
        var titles: [TitleItem] = []

        let lines = response.components(separatedBy: .newlines)
        var currentSection = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("SUMMARY:") {
                currentSection = "summary"
                continue
            } else if trimmed.hasPrefix("TASKS:") {
                currentSection = "tasks"
                continue
            } else if trimmed.hasPrefix("REMINDERS:") {
                currentSection = "reminders"
                continue
            } else if trimmed.hasPrefix("TITLES:") {
                currentSection = "titles"
                continue
            }

            switch currentSection {
            case "summary":
                if !trimmed.isEmpty {
                    summary += (summary.isEmpty ? "" : "\n") + trimmed
                }
            case "tasks":
                if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                    let content = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        tasks.append(TaskItem(text: content, priority: .medium, confidence: 0.8))
                    }
                }
            case "reminders":
                if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                    let content = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        let timeRef = ReminderItem.TimeReference(originalText: content)
                        reminders.append(ReminderItem(text: content, timeReference: timeRef, urgency: .later, confidence: 0.8))
                    }
                }
            case "titles":
                if trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                    let content = trimmed.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        titles.append(TitleItem(text: content, confidence: 0.8))
                    }
                }
            default:
                break
            }
        }

        // Classify content type using the original text
        let contentType = ContentAnalyzer.classifyContent(originalText)

        return (summary, tasks, reminders, titles, contentType)
    }

    // MARK: - Connection Testing

    func testConnection() async -> Bool {
        // For local models, "connection" means checking if model is available
        return isModelDownloaded() || isModelLoaded
    }
}

// MARK: - MLX Errors

enum MLXError: LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case downloadFailed(String)
    case generationFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded. Please load the model first."
        case .modelNotDownloaded:
            return "Model is not downloaded. Please download the model first."
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        case .generationFailed(let message):
            return "Text generation failed: \(message)"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

// MARK: - MLX Whisper Configuration

struct MLXWhisperConfig {
    let modelName: String
    let huggingFaceRepoId: String

    var cacheDirectory: URL {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cachesDirectory.appendingPathComponent("mlx-models").appendingPathComponent(modelName)
    }
}

// MARK: - MLX Whisper Transcription Result

struct MLXWhisperResult {
    let text: String
    let segments: [TranscriptSegment]
    let processingTime: TimeInterval
}

// MARK: - MLX Whisper Service

class MLXWhisperService {
    private var config: MLXWhisperConfig
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(config: MLXWhisperConfig) {
        self.config = config
        setupMemoryPressureMonitoring()
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    // MARK: - Memory Pressure Monitoring

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = source.data

            if event.contains(.critical) {
                print("🚨 CRITICAL MEMORY PRESSURE during Whisper transcription")
                // Whisper transcription can't be easily interrupted, but we log the warning
            } else if event.contains(.warning) {
                print("⚠️ MEMORY PRESSURE WARNING during Whisper transcription")
            }
        }

        source.resume()
        memoryPressureSource = source
    }

    private func checkMemoryAvailability() -> Bool {
        let (free, used, total) = getMemoryInfo()
        let availableGB = free

        // Need at least 1.5GB free for Whisper transcription (model + audio processing)
        if availableGB < 1.5 {
            print("⚠️ Low memory: \(String(format: "%.2f", availableGB))GB available")
            print("   Whisper transcription may fail or cause memory issues")
            return false
        }

        // Warn if we're using more than 70% of total memory
        let usagePercent = (used / total) * 100
        if usagePercent > 70 {
            print("⚠️ High memory usage: \(String(format: "%.1f", usagePercent))%")
        }

        return true
    }

    private func getMemoryInfo() -> (free: Double, used: Double, total: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4

        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }

        if kerr == KERN_SUCCESS {
            let usedGB = Double(info.resident_size) / 1_073_741_824.0
            let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
            let freeGB = totalGB - usedGB
            return (freeGB, usedGB, totalGB)
        }

        return (0, 0, 0)
    }

    private func logMemory(label: String) {
        let (free, used, total) = getMemoryInfo()
        print("💾 \(label): Used: \(String(format: "%.2f", used))GB / Free: \(String(format: "%.2f", free))GB / Total: \(String(format: "%.2f", total))GB")
    }

    func isModelDownloaded() -> Bool {
        // Check UserDefaults first (reliable indicator that model was successfully used before)
        let userDefaultsKey = "mlx_whisper_downloaded_\(config.modelName)"
        let markedAsDownloaded = UserDefaults.standard.bool(forKey: userDefaultsKey)

        print("🔍 Checking if Whisper model '\(config.modelName)' is downloaded")
        print("   UserDefaults says: \(markedAsDownloaded)")

        if markedAsDownloaded {
            return true
        }

        // Fallback: Check if custom cache directory exists
        let modelPath = config.cacheDirectory
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: modelPath.path, isDirectory: &isDirectory)

        print("   Checking path: \(modelPath.path)")
        print("   Directory exists: \(exists)")

        if exists && isDirectory.boolValue {
            let configPath = modelPath.appendingPathComponent("config.json")
            let configExists = FileManager.default.fileExists(atPath: configPath.path)

            if configExists {
                // Found it, mark in UserDefaults for future
                UserDefaults.standard.set(true, forKey: userDefaultsKey)
                return true
            }
        }

        return false
    }

    @MainActor
    func downloadModel() async throws {
        print("🔽 MLXWhisperService: Starting Whisper model download from \(config.huggingFaceRepoId)")

        do {
            // Map model name to MLXAudio Whisper model type
            let whisperModel: WhisperEngine
            switch config.modelName {
            case "whisper-large-v3-turbo-4bit":
                whisperModel = STT.whisper(model: .largeTurbo)
                print("📦 Downloading Whisper Large v3 Turbo (~1.6GB)")
            case "whisper-medium-4bit":
                whisperModel = STT.whisper(model: .medium)
                print("📦 Downloading Whisper Medium (~800MB)")
            case "whisper-base-4bit":
                whisperModel = STT.whisper(model: .base)
                print("📦 Downloading Whisper Base (~150MB)")
            default:
                whisperModel = STT.whisper(model: .base)
                print("📦 Downloading Whisper Base (default) (~150MB)")
            }

            // Actually download the model by calling load()
            print("📥 Downloading model from Hugging Face (this may take a few minutes)...")
            try await whisperModel.load()

            // Mark as downloaded
            UserDefaults.standard.set(true, forKey: "mlx_whisper_downloaded_\(config.modelName)")
            print("✅ MLXWhisperService: Whisper model downloaded and cached successfully")

        } catch {
            print("❌ MLXWhisperService: Model download failed: \(error)")
            throw error
        }
    }

    func transcribeAudio(_ audioURL: URL) async throws -> MLXWhisperResult {
        let startTime = Date()

        print("🎤 MLXWhisperService: Starting transcription for \(audioURL.lastPathComponent)")

        // Check memory availability before transcription
        logMemory(label: "Before transcription")
        if !checkMemoryAvailability() {
            print("⚠️ Low memory detected - transcription may fail")
            // Continue anyway but user has been warned
        }
        // Map our model names to MLXAudio Whisper model types and create WhisperEngine instance
        // Must be created on MainActor since STT.whisper() is MainActor-isolated
        let whisper = await MainActor.run {
            let engine: WhisperEngine
            switch config.modelName {
            case "whisper-large-v3-turbo-4bit":
                engine = STT.whisper(model: .largeTurbo)
                print("📦 Using Whisper Large v3 Turbo (best quality, fastest large model)")
            case "whisper-medium-4bit":
                engine = STT.whisper(model: .medium)
                print("📦 Using Whisper Medium (balanced quality and speed)")
            case "whisper-base-4bit":
                engine = STT.whisper(model: .base)
                print("📦 Using Whisper Base (fast and compact)")
            default:
                engine = STT.whisper(model: .base)
                print("⚠️ Unknown model '\(config.modelName)', defaulting to Whisper Base")
            }
            return engine
        }

        // Start continuous memory monitoring during transcription
        let monitoringTask = Task {
            var peakUsed: Double = 0
            var iteration = 0
            while !Task.isCancelled {
                autoreleasepool {
                    let (_, used, _) = getMemoryInfo()
                    if used > peakUsed {
                        peakUsed = used
                    }
                    iteration += 1
                    if iteration % 20 == 0 { // Log every 20th check (every ~1 second)
                        logMemory(label: "During transcription (iteration \(iteration))")
                        print("   📊 Peak so far: \(String(format: "%.2f", peakUsed))GB")
                    }
                }
                try? await Task.sleep(nanoseconds: 50_000_000) // Check every 50ms
            }
        }

        do {
            // Load the Whisper model
            print("🔽 Loading Whisper model (will download from Hugging Face if needed)...")
            logMemory(label: "Before model load")
            try await whisper.load()
            logMemory(label: "After model load")
            print("✅ Whisper model loaded successfully")

            // Mark as downloaded since we successfully loaded it
            UserDefaults.standard.set(true, forKey: "mlx_whisper_downloaded_\(config.modelName)")
            print("   Marked Whisper model as downloaded in UserDefaults")

            // Transcribe the audio file (language auto-detected)
            print("🎙️ Transcribing audio...")
            let result = try await whisper.transcribe(audioURL)

            // Stop monitoring
            monitoringTask.cancel()

            let processingTime = Date().timeIntervalSince(startTime)
            logMemory(label: "After transcription")
            print("✅ Transcription completed in \(String(format: "%.2f", processingTime))s")
            print("📝 Transcript: \(result.text.prefix(100))...")

            // Convert MLXAudio result to our format with autoreleasepool for memory efficiency
            let segments: [TranscriptSegment] = autoreleasepool {
                result.segments.map { segment in
                    TranscriptSegment(
                        speaker: "Speaker",
                        text: segment.text,
                        startTime: segment.start,
                        endTime: segment.end
                    )
                }
            }

            return MLXWhisperResult(
                text: result.text,
                segments: segments,
                processingTime: processingTime
            )

        } catch {
            // Stop monitoring on error
            monitoringTask.cancel()

            logMemory(label: "After transcription error")
            print("❌ MLXWhisperService: Transcription failed: \(error)")
            throw MLXError.transcriptionFailed(error.localizedDescription)
        }
    }
}
