//
//  MLXSwiftEngine.swift
//  BisonNotes AI
//
//  Experimental MLX Swift summarization engine.
//

import Foundation

// MARK: - Settings Keys

enum MLXSwiftSettingsKeys {
    static let enabled = "mlxSwiftExperimentalEnabled"
    static let modelId = "mlxSwiftModelId"
    static let maxTokens = "mlxSwiftMaxTokens"
    static let contextTokens = "mlxSwiftContextTokens"
    static let temperature = "mlxSwiftTemperature"
    static let topK = "mlxSwiftTopK"
    static let topP = "mlxSwiftTopP"
    static let repetitionPenalty = "mlxSwiftRepeatPenalty"

    static let defaultModelId = "prism-ml/Ternary-Bonsai-4B-mlx-2bit"
    static let defaultMaxTokens = 2700
    static let defaultTemperature: Double = 0.7
    static let defaultTopK = 40
    static let defaultTopP: Double = 0.95
    static let defaultRepetitionPenalty: Double = 1.1
}

// MARK: - Download Manager

@MainActor
final class MLXSwiftDownloadManager: ObservableObject {
    static let shared = MLXSwiftDownloadManager()

    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var downloadError: String?
    @Published private(set) var isModelDownloaded = false

    private var downloadTask: Task<Void, Never>?

    var modelId: String {
        UserDefaults.standard.string(forKey: MLXSwiftSettingsKeys.modelId)
            ?? MLXSwiftSettingsKeys.defaultModelId
    }

    var modelDisplayName: String {
        modelId.components(separatedBy: "/").last ?? modelId
    }

    init() {
        refreshModelStatus()
    }

    func refreshModelStatus() {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        isModelDownloaded = checkModelExists()
        #else
        isModelDownloaded = false
        #endif
    }

    func startDownload() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadError = nil
        downloadProgress = 0

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                #if canImport(MLXLLM) && canImport(MLXLMCommon)
                try await self.performDownload()
                #else
                throw NSError(domain: "MLXSwift", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "MLX libraries not available"])
                #endif
                self.isDownloading = false
                self.isModelDownloaded = true
                AppLog.shared.summarization("[MLXSwift] Model pre-download complete: \(self.modelId)")
            } catch {
                if !Task.isCancelled {
                    self.downloadError = error.localizedDescription
                    self.isDownloading = false
                    AppLog.shared.summarization("[MLXSwift] Download failed: \(error.localizedDescription)", level: .error)
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
    }

    func deleteModel() {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        do {
            try removeModelFiles()
            isModelDownloaded = false
            AppLog.shared.summarization("[MLXSwift] Model deleted: \(modelId)")
        } catch {
            downloadError = "Failed to delete: \(error.localizedDescription)"
            AppLog.shared.summarization("[MLXSwift] Delete failed: \(error.localizedDescription)", level: .error)
        }
        #endif
    }
}

// MARK: - Engine

final class MLXSwiftEngine: SummarizationEngine, ConnectionTestable {
    var name: String { "MLX Swift" }
    var engineType: String { "MLX Swift" }
    var description: String {
        "Experimental on-device summarization with MLX Swift."
    }
    let version = "Experimental"

    var metadataName: String {
        UserDefaults.standard.string(forKey: MLXSwiftSettingsKeys.modelId)
            ?? MLXSwiftSettingsKeys.defaultModelId
    }

    var isAvailable: Bool {
        guard UserDefaults.standard.bool(forKey: MLXSwiftSettingsKeys.enabled) else {
            return false
        }

        #if targetEnvironment(simulator)
        return true
        #else
        return DeviceCapabilities.supportsOnDeviceLLM
        #endif
    }

    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private let service = MLXSwiftService()
    #endif

    func testConnection() async -> Bool {
        isAvailable
    }

    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let result = try await processComplete(text: text)
        return result.summary
    }

    func extractTasks(from text: String) async throws -> [TaskItem] {
        let result = try await processComplete(text: text)
        return result.tasks
    }

    func extractReminders(from text: String) async throws -> [ReminderItem] {
        let result = try await processComplete(text: text)
        return result.reminders
    }

    func extractTitles(from text: String) async throws -> [TitleItem] {
        let result = try await processComplete(text: text)
        return result.titles
    }

    func classifyContent(_ text: String) async throws -> ContentType {
        ContentAnalyzer.classifyContent(text)
    }

    func processComplete(text: String) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        guard isAvailable else {
            throw SummarizationError.configurationRequired(
                message: "MLX Swift is not enabled. Enable it in AI Settings before using it."
            )
        }

        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        return try await service.processComplete(text: text)
        #else
        throw SummarizationError.configurationRequired(
            message: "MLX Swift libraries are not linked. Add the mlx-swift-lm package and link MLXLLM/MLXLMCommon."
        )
        #endif
    }
}

// MARK: - Conditional MLXLLM Implementation

#if canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLX
import MLXLMCommon
import UIKit
import os

// MARK: MLX Memory Configuration for iOS

/// Configure MLX's Metal buffer cache for iOS jetsam constraints.
/// Must be called before any model loading.
private func configureMLXMemoryForIOS() {
    // The default cache limit scales with device RAM and can grow to several GB
    // during inference as intermediate buffers accumulate. On iOS this competes
    // with the jetsam budget. Apple's own docs recommend small cache sizes
    // (as low as 2 MB) for memory-constrained environments.
    //
    // 32 MB allows meaningful buffer reuse during token generation (where
    // intermediate sizes repeat) without letting the cache eat into headroom.
    let cacheLimit = 32 * 1024 * 1024 // 32 MB
    Memory.cacheLimit = cacheLimit

    let snapshot = Memory.snapshot()
    AppLog.shared.summarization(
        "[MLXSwift] Memory config: cacheLimit=\(cacheLimit / (1024*1024))MB, "
        + "active=\(snapshot.activeMemory / (1024*1024))MB, "
        + "cache=\(snapshot.cacheMemory / (1024*1024))MB"
    )
}

// MARK: Download Manager Hub Integration

extension MLXSwiftDownloadManager {
    func performDownload() async throws {
        let id = modelId
        let config = ModelConfiguration(id: id)
        _ = try await downloadModel(hub: defaultHubApi, configuration: config) { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
    }

    func checkModelExists() -> Bool {
        checkModelExists(modelId: modelId)
    }

    func checkModelExists(modelId: String) -> Bool {
        let config = ModelConfiguration(id: modelId)
        let dir = config.modelDirectory(hub: defaultHubApi)
        let configFile = dir.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configFile.path)
    }

    func removeModelFiles() throws {
        let config = ModelConfiguration(id: modelId)
        let dir = config.modelDirectory(hub: defaultHubApi)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}

// MARK: MLX Service Actor

private actor MLXSwiftService {
    private var modelContainer: ModelContainer?
    private var loadedModelId: String?
    private var memoryObserver: NSObjectProtocol?
    private var receivedMemoryWarning = false

    /// Maximum input tokens per chunk for MLX inference. With the Metal buffer
    /// cache capped, memory growth during inference stays bounded. This limit
    /// prevents extremely long single prompts from exceeding KV cache capacity.
    private static let mlxMaxInputTokens = 12288

    init() {}

    private func ensureMemoryObserver() {
        guard memoryObserver == nil else { return }

        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleMemoryWarning() }
        }
        self.memoryObserver = observer
    }

    deinit {
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    private func handleMemoryWarning() {
        AppLog.shared.summarization("[MLXSwift] Memory warning received", level: .error)
        receivedMemoryWarning = true
        // Don't nil modelContainer here — if inference is running, the ChatSession
        // holds its own reference so it wouldn't free anything. Instead, we check
        // receivedMemoryWarning between chunks and after inference completes.
    }

    /// Unloads the model and clears the Metal buffer cache. Called after inference
    /// completes to return memory to the system.
    func unloadModel() {
        if modelContainer != nil {
            let before = Memory.snapshot()
            modelContainer = nil
            loadedModelId = nil
            Memory.clearCache()
            let after = Memory.snapshot()
            AppLog.shared.summarization(
                "[MLXSwift] Model unloaded — freed "
                + "\((before.activeMemory + before.cacheMemory - after.activeMemory - after.cacheMemory) / (1024*1024))MB "
                + "(active: \(after.activeMemory / (1024*1024))MB, cache: \(after.cacheMemory / (1024*1024))MB)"
            )
        }
        receivedMemoryWarning = false
    }

    /// Check memory state and throw if we received a warning during processing.
    private func checkMemoryPressure() throws {
        guard !receivedMemoryWarning else {
            AppLog.shared.summarization("[MLXSwift] Aborting due to memory pressure", level: .error)
            throw SummarizationError.configurationRequired(
                message: "The device is running low on memory. Close other apps and try again, or use a cloud AI engine for large transcripts."
            )
        }
    }

    func processComplete(text: String) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        ensureMemoryObserver()
        receivedMemoryWarning = false

        let tokenCount = TokenManager.getTokenCount(text)
        // Use a hard cap well below the device context window to keep peak memory
        // manageable. MLX loads the full model into Metal buffers (no mmap), so
        // every token of KV cache and activation memory is additive.
        let inputLimit = min(Self.mlxMaxInputTokens, max(1500, configuredContextTokens - configuredMaxTokens - 700))

        AppLog.shared.summarization("[MLXSwift] Transcript: \(tokenCount) tokens, input limit: \(inputLimit) tokens/chunk")

        let result: (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType)
        if tokenCount > inputLimit {
            AppLog.shared.summarization("[MLXSwift] Chunking transcript into ~\(inputLimit)-token pieces", level: .debug)
            result = try await processChunked(text: text, maxTokens: inputLimit)
        } else {
            result = try await runCompletePrompt(transcript: text, contentHint: ContentAnalyzer.classifyContent(text))
        }

        // Unload model after processing to free Metal memory for the rest of the app.
        // Next summarization will reload it.
        unloadModel()
        return result
    }

    private func processChunked(text: String, maxTokens: Int) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let chunks = TokenManager.chunkText(text, maxTokens: maxTokens)
        var chunkResults: [MLXSwiftStructuredResponse] = []

        for (index, chunk) in chunks.enumerated() {
            // Bail out if iOS has signaled memory pressure between chunks
            try checkMemoryPressure()

            AppLog.shared.summarization("[MLXSwift] Processing chunk \(index + 1)/\(chunks.count)", level: .debug)
            let result = try await runCompletePrompt(
                transcript: chunk,
                contentHint: ContentAnalyzer.classifyContent(chunk)
            )
            chunkResults.append(
                MLXSwiftStructuredResponse(
                    summary: result.summary,
                    tasks: result.tasks,
                    reminders: result.reminders,
                    titles: result.titles,
                    contentType: result.contentType
                )
            )
        }

        return try await consolidate(chunkResults: chunkResults, originalContentType: ContentAnalyzer.classifyContent(text))
    }

    private func runCompletePrompt(transcript: String, contentHint: ContentType) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let wordCount = transcript.split(separator: " ").count
        let targetWords = max(200, Int(Double(wordCount) * 0.15))

        let prompt = """
        Analyze the following transcript and extract the actual content discussed. \
        Base your response ONLY on what is actually mentioned in the transcript.

        1. A STRUCTURED OUTLINE SUMMARY
           - CRITICAL: The summary must be approximately \(targetWords) words long.
           - Use sections: Overview, Key Facts, Important Notes, Conclusions.
           - Expand on details using nested bullet points.
           - Write about what was ACTUALLY discussed in the transcript, not generic examples.
        2. A list of actionable tasks (personal items only) - ONLY include tasks that are actually mentioned
        3. Time-sensitive reminders and deadlines - ONLY include reminders that are actually mentioned
        4. 3-5 suggested titles - Based on the ACTUAL topics discussed

        IMPORTANT FORMATTING RULES:
        - For tasks, reminders, and titles: Start each line with "- " followed directly by the text
        - Do NOT use prefixes like [Task 1], [Reminder 1], or [Title 1]
        - Do NOT include placeholder or example text - only extract what is actually in the transcript
        - If no tasks are mentioned, leave the Tasks section empty
        - If no reminders are mentioned, leave the Reminders section empty

        Format your response with clear sections:

        ## Summary
        ### 1. Overview
        [Write a detailed overview based on what was actually discussed]

        ### 2. Key Facts & Details
        - [Extract specific facts, numbers, dates, and names that were mentioned]

        ### 3. Important Notes
        - [Extract important context or observations from the transcript]

        ### 4. Conclusions
        [Summarize conclusions or decisions that were actually made]

        ## Tasks
        [Only include tasks that are explicitly mentioned in the transcript. If none, leave empty.]

        ## Reminders
        [Only include reminders with dates/times that are explicitly mentioned. If none, leave empty.]

        ## Suggested Titles
        [Generate titles based on the actual main topics discussed in the transcript]

        Transcript:
        \(transcript)
        """

        let rawResponse = try await generate(prompt: prompt)
        return MLXSwiftResponseParser.parseMarkdown(rawResponse, fallbackText: transcript)
    }

    private func consolidate(
        chunkResults: [MLXSwiftStructuredResponse],
        originalContentType: ContentType
    ) async throws -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let encodedChunks = chunkResults.enumerated().map { index, result in
            """
            Chunk \(index + 1):
            Summary:
            \(result.summary)

            Tasks:
            \(result.tasks.map { "- \($0.text)" }.joined(separator: "\n"))

            Reminders:
            \(result.reminders.map { "- \($0.text)" }.joined(separator: "\n"))

            Titles:
            \(result.titles.map { "- \($0.text)" }.joined(separator: "\n"))
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Merge these partial transcript analyses into one cohesive final result.

        Rules:
        - Combine the summaries into one unified summary preserving all key details.
        - Deduplicate tasks and reminders across chunks.
        - Keep the best 3-5 titles.
        - Write about what was ACTUALLY discussed, not generic examples.

        Use this format:

        ## Summary
        ### 1. Overview
        [Combined overview]

        ### 2. Key Facts & Details
        - [Merged facts from all chunks]

        ### 3. Important Notes
        - [Merged notes]

        ### 4. Conclusions
        [Combined conclusions]

        ## Tasks
        [Deduplicated tasks, or empty if none]

        ## Reminders
        [Deduplicated reminders, or empty if none]

        ## Suggested Titles
        [Best 3-5 titles]

        Partial analyses:
        \(encodedChunks)
        """

        let rawResponse = try await generate(prompt: prompt)
        return MLXSwiftResponseParser.parseMarkdown(rawResponse, fallbackText: encodedChunks)
    }

    private static let systemInstruction = """
    You are an AI assistant specialized in processing audio transcripts. \
    Analyze the ACTUAL CONTENT of the transcript and extract only what is explicitly mentioned.

    CRITICAL:
    - Extract ONLY information that appears in the transcript itself
    - Do NOT generate placeholder text, examples, or generic content
    - Do NOT include tasks, reminders, or titles unless they are actually mentioned
    - If no tasks are mentioned, return an empty tasks section
    - If no reminders are mentioned, return an empty reminders section
    - Base titles on the ACTUAL topics discussed, not generic examples

    Provide:
    1. A comprehensive summary using Markdown formatting based on what was actually discussed
    2. Actionable tasks (personal items only) - ONLY if explicitly mentioned in the transcript
    3. Time-sensitive reminders (personal appointments and deadlines) - ONLY if explicitly mentioned
    4. Suggested titles based on the ACTUAL main topics discussed

    Be thorough but concise. Focus on information that is personally relevant to the speaker \
    and actually appears in the transcript.
    """

    private func generate(prompt: String) async throws -> String {
        let container = try await loadContainer()
        let parameters = GenerateParameters(
            maxTokens: configuredMaxTokens,
            maxKVSize: configuredContextTokens,
            kvBits: 4,
            kvGroupSize: 64,
            temperature: configuredTemperature,
            topP: configuredTopP,
            topK: configuredTopK,
            repetitionPenalty: configuredRepetitionPenalty,
            prefillStepSize: 256
        )
        let session = ChatSession(
            container,
            instructions: Self.systemInstruction,
            generateParameters: parameters
        )

        let response = try await session.respond(to: prompt)
        return MLXSwiftResponseParser.stripThinking(from: response)
    }

    /// Minimum available memory (in bytes) required before attempting to load the model.
    /// The 2-bit 8B model is ~2.3 GB on disk. With the Metal buffer cache capped at
    /// 32 MB and 4-bit KV quantization, total overhead stays modest. 2.5 GB gives
    /// the model weights room to load with buffer for inference overhead.
    private static let minimumAvailableMemory: UInt64 = 2_500_000_000

    private func loadContainer() async throws -> ModelContainer {
        let modelId = UserDefaults.standard.string(forKey: MLXSwiftSettingsKeys.modelId)
            ?? MLXSwiftSettingsKeys.defaultModelId

        if let modelContainer, loadedModelId == modelId {
            return modelContainer
        }

        // Configure MLX's Metal buffer cache for iOS before first load
        configureMLXMemoryForIOS()

        // Clear any stale cached buffers from a previous load
        Memory.clearCache()

        // Check available memory before loading to avoid jetsam (OOM) kills
        let available = os_proc_available_memory()
        AppLog.shared.summarization("[MLXSwift] Available memory before load: \(available / 1_000_000) MB")
        guard available >= Self.minimumAvailableMemory else {
            let availableMB = available / 1_000_000
            let requiredMB = Self.minimumAvailableMemory / 1_000_000
            AppLog.shared.summarization("[MLXSwift] Insufficient memory: \(availableMB) MB available, \(requiredMB) MB required", level: .error)
            throw SummarizationError.configurationRequired(
                message: "Not enough free memory to load the MLX model. Close other apps and try again. (\(availableMB) MB available, \(requiredMB) MB needed)"
            )
        }

        AppLog.shared.summarization("[MLXSwift] Loading model: \(modelId)")
        let container = try await loadModelContainer(id: modelId) { progress in
            if progress.totalUnitCount > 0 {
                let percent = Int((Double(progress.completedUnitCount) / Double(progress.totalUnitCount)) * 100)
                AppLog.shared.summarization("[MLXSwift] Model download/load progress: \(percent)%", level: .debug)
            }
        }

        modelContainer = container
        loadedModelId = modelId

        let postLoad = Memory.snapshot()
        AppLog.shared.summarization(
            "[MLXSwift] Model loaded: \(modelId) — "
            + "active=\(postLoad.activeMemory / (1024*1024))MB, "
            + "cache=\(postLoad.cacheMemory / (1024*1024))MB, "
            + "peak=\(postLoad.peakMemory / (1024*1024))MB"
        )
        return container
    }

    // MARK: Configured Parameters

    private var configuredMaxTokens: Int {
        if UserDefaults.standard.object(forKey: MLXSwiftSettingsKeys.maxTokens) != nil {
            return UserDefaults.standard.integer(forKey: MLXSwiftSettingsKeys.maxTokens)
        }
        return MLXSwiftSettingsKeys.defaultMaxTokens
    }

    private var configuredContextTokens: Int {
        if UserDefaults.standard.object(forKey: MLXSwiftSettingsKeys.contextTokens) != nil {
            return UserDefaults.standard.integer(forKey: MLXSwiftSettingsKeys.contextTokens)
        }
        return DeviceCapabilities.onDeviceLLMContextSize
    }

    private var configuredTemperature: Float {
        if UserDefaults.standard.object(forKey: MLXSwiftSettingsKeys.temperature) != nil {
            return Float(UserDefaults.standard.double(forKey: MLXSwiftSettingsKeys.temperature))
        }
        return Float(MLXSwiftSettingsKeys.defaultTemperature)
    }

    private var configuredTopK: Int {
        if UserDefaults.standard.object(forKey: MLXSwiftSettingsKeys.topK) != nil {
            return UserDefaults.standard.integer(forKey: MLXSwiftSettingsKeys.topK)
        }
        return MLXSwiftSettingsKeys.defaultTopK
    }

    private var configuredTopP: Float {
        if UserDefaults.standard.object(forKey: MLXSwiftSettingsKeys.topP) != nil {
            return Float(UserDefaults.standard.double(forKey: MLXSwiftSettingsKeys.topP))
        }
        return Float(MLXSwiftSettingsKeys.defaultTopP)
    }

    private var configuredRepetitionPenalty: Float {
        if UserDefaults.standard.object(forKey: MLXSwiftSettingsKeys.repetitionPenalty) != nil {
            return Float(UserDefaults.standard.double(forKey: MLXSwiftSettingsKeys.repetitionPenalty))
        }
        return Float(MLXSwiftSettingsKeys.defaultRepetitionPenalty)
    }
}

// MARK: Response Types

private struct MLXSwiftStructuredResponse {
    let summary: String
    let tasks: [TaskItem]
    let reminders: [ReminderItem]
    let titles: [TitleItem]
    let contentType: ContentType
}

private enum MLXSwiftResponseParser {
    static func parse(
        _ rawResponse: String,
        fallbackText: String
    ) -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let cleaned = stripThinking(from: rawResponse)
        if let data = extractJSONObject(from: cleaned).data(using: .utf8),
           let decoded = try? JSONDecoder().decode(CompleteResponse.self, from: data) {
            return decoded.toSummaryResult(fallbackText: fallbackText)
        }

        AppLog.shared.summarization("[MLXSwift] Could not parse structured JSON, using raw response as summary", level: .error)
        let fallbackSummary = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            summary: fallbackSummary.isEmpty ? "## Summary\n\nNo summary was generated." : fallbackSummary,
            tasks: [],
            reminders: [],
            titles: [],
            contentType: ContentAnalyzer.classifyContent(fallbackText)
        )
    }

    /// Parse Markdown-formatted response with ## sections into structured result.
    /// Falls back to JSON parsing, then raw text.
    static func parseMarkdown(
        _ rawResponse: String,
        fallbackText: String
    ) -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let cleaned = stripThinking(from: rawResponse)
        let contentType = ContentAnalyzer.classifyContent(fallbackText)

        // Split into sections by ## headers
        let sections = extractMarkdownSections(from: cleaned)

        // Extract summary: everything under "## Summary" (or the whole text if no sections found)
        let summary = sections["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract tasks: bullet lines under "## Tasks"
        let tasks: [TaskItem] = extractBulletItems(from: sections["tasks"]).map { text in
            TaskItem(
                text: text,
                priority: .medium,
                timeReference: nil,
                category: .general,
                confidence: 0.7
            )
        }

        // Extract reminders: bullet lines under "## Reminders"
        let reminders: [ReminderItem] = extractBulletItems(from: sections["reminders"]).map { text in
            let timeRef = ReminderItem.TimeReference.fromReminderText(text)
            return ReminderItem(
                text: text,
                timeReference: timeRef,
                urgency: .later,
                confidence: 0.7
            )
        }

        // Extract titles: bullet lines under "## Suggested Titles"
        let titles: [TitleItem] = extractBulletItems(from: sections["titles"]).map { text in
            // Strip bold markers and quotes from title text
            let cleanTitle = text
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TitleItem(
                text: cleanTitle,
                confidence: 0.8,
                category: .general
            )
        }

        if summary.isEmpty {
            // No Markdown sections found — try JSON fallback
            return parse(cleaned, fallbackText: fallbackText)
        }

        return (
            summary: summary,
            tasks: tasks,
            reminders: reminders,
            titles: titles,
            contentType: contentType
        )
    }

    /// Split Markdown text into named sections by ## headers.
    /// Returns lowercased section names mapped to their content.
    private static func extractMarkdownSections(from text: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentKey: String?
        var currentContent: [String] = []

        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                // Save previous section
                if let key = currentKey {
                    sections[key] = currentContent.joined(separator: "\n")
                }
                let header = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                // Normalize header names
                if header.contains("summary") {
                    currentKey = "summary"
                } else if header.contains("task") {
                    currentKey = "tasks"
                } else if header.contains("reminder") {
                    currentKey = "reminders"
                } else if header.contains("title") {
                    currentKey = "titles"
                } else {
                    currentKey = header
                }
                currentContent = []
            } else {
                currentContent.append(line)
            }
        }
        // Save last section
        if let key = currentKey {
            sections[key] = currentContent.joined(separator: "\n")
        }

        return sections
    }

    /// Extract bullet-pointed items (lines starting with "- ") from a section.
    private static func extractBulletItems(from section: String?) -> [String] {
        guard let section, !section.isEmpty else { return [] }
        return section
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func stripThinking(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONObject(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = cleaned.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)

        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}"),
              start <= end else {
            return cleaned
        }

        return String(cleaned[start...end])
    }
}

private struct CompleteResponse: Decodable {
    var summary: String?
    var tasks: [TaskDTO]?
    var reminders: [ReminderDTO]?
    var titles: [TitleDTO]?
    var contentType: String?

    func toSummaryResult(fallbackText: String) -> (
        summary: String,
        tasks: [TaskItem],
        reminders: [ReminderItem],
        titles: [TitleItem],
        contentType: ContentType
    ) {
        let parsedContentType = ContentType(rawValue: contentType ?? "")
            ?? ContentAnalyzer.classifyContent(fallbackText)
        let parsedTasks = (tasks ?? []).compactMap { $0.toTaskItem() }
        let parsedReminders = (reminders ?? []).compactMap { $0.toReminderItem() }
        let parsedTitles = (titles ?? []).compactMap { $0.toTitleItem() }
        let trimmedSummary = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            summary: trimmedSummary.isEmpty ? "## Summary\n\nNo summary was generated." : trimmedSummary,
            tasks: parsedTasks,
            reminders: parsedReminders,
            titles: parsedTitles,
            contentType: parsedContentType
        )
    }
}

private struct TaskDTO: Decodable {
    var text: String?
    var priority: String?
    var timeReference: String?
    var category: String?
    var confidence: Double?

    func toTaskItem() -> TaskItem? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        return TaskItem(
            text: text,
            priority: TaskItem.Priority(rawValue: priority ?? "") ?? .medium,
            timeReference: timeReference?.nilIfBlank,
            category: TaskItem.TaskCategory(rawValue: category ?? "") ?? .general,
            confidence: confidence ?? 0.7
        )
    }
}

private struct ReminderDTO: Decodable {
    var text: String?
    var timeReference: String?
    var urgency: String?
    var confidence: Double?

    func toReminderItem() -> ReminderItem? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let timeText = timeReference?.nilIfBlank ?? ReminderItem.TimeReference.fromReminderText(text).displayText
        return ReminderItem(
            text: text,
            timeReference: ReminderItem.TimeReference.fromReminderText(timeText),
            urgency: ReminderItem.Urgency(rawValue: urgency ?? "") ?? .later,
            confidence: confidence ?? 0.7
        )
    }
}

private struct TitleDTO: Decodable {
    var text: String?
    var confidence: Double?
    var category: String?

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let titleText = try? singleValue.decode(String.self) {
            self.text = titleText
            self.confidence = 0.7
            self.category = TitleItem.TitleCategory.general.rawValue
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        self.category = try container.decodeIfPresent(String.self, forKey: .category)
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case confidence
        case category
    }

    func toTitleItem() -> TitleItem? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        return TitleItem(
            text: text,
            confidence: confidence ?? 0.7,
            category: TitleItem.TitleCategory(rawValue: category ?? "") ?? .general
        )
    }
}

#endif

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
