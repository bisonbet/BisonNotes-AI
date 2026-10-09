//
//  MLXTranscriptCleanupService.swift
//  BisonNotes AI
//
//  S1-mini inference adapter. This file is deliberately conditional so the
//  app remains compilable for simulator/watch targets that cannot run MLX.
//

import Foundation

#if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
#endif

#if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
private final class TranscriptCleanupInputTransfer: @unchecked Sendable {
    private var value: LMInput?

    init(_ value: LMInput) {
        self.value = value
    }

    func consume() -> LMInput {
        guard let value else {
            preconditionFailure("Transcript cleanup input was consumed more than once")
        }
        self.value = nil
        return value
    }
}

actor MLXTranscriptCleanupService: TranscriptCleanupNormalizing {
    static let shared = MLXTranscriptCleanupService()

    private static let generationTimeoutNanoseconds: UInt64 = 120_000_000_000
    /// MLX's default cache limit scales with host memory and can retain several
    /// GB of reusable Metal buffers during a long cleanup pass. 32 MB — the
    /// summary engine's value, which this used to share — is too small for
    /// S1-mini's per-step temporaries, so buffers were freed and reallocated on
    /// every token. 128 MB keeps reuse working while staying a small fraction
    /// of the ~650 MB model. The previous limit is restored on release.
    private static let memoryCacheLimitBytes = 128 * 1024 * 1024

    private var modelContainer: ModelContainer?
    private var previousCacheLimit: Int?

    var isReady: Bool {
        TranscriptCleanupSettings.availability.isAvailable
            && TranscriptCleanupModelLocator.isComplete
    }

    func renderedRequestTokenCount(for rawText: String) async throws -> Int {
        let container = try await loadContainer()
        let tokenizer = await container.tokenizer
        guard tokenizer.hasChatTemplate else {
            throw TranscriptCleanupNormalizerError.templateUnavailable
        }

        let messages = TranscriptCleanupSettings.messages(for: rawText)
        let tokens = try tokenizer.applyChatTemplate(
            messages: messages,
            chatTemplate: nil,
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        return tokens.count
    }

    func normalize(_ rawText: String) async throws -> TranscriptCleanupGeneration {
        try Task.checkCancellation()
        let container = try await loadContainer()
        let tokenizer = await container.tokenizer
        guard tokenizer.hasChatTemplate else {
            throw TranscriptCleanupNormalizerError.templateUnavailable
        }

        let messages = TranscriptCleanupSettings.messages(for: rawText)
        // `prepare` renders the chat template; its token count is the request
        // size, so the template is rendered once here rather than once to
        // measure and again to prepare.
        let input = try await container.prepare(
            input: UserInput(
                messages: messages,
                additionalContext: ["enable_thinking": false]
            )
        )
        guard input.text.tokens.size <= TranscriptCleanupCoordinator.maxRenderedInputTokens else {
            throw TranscriptCleanupNormalizerError.invalidRequest
        }
        // This deliberately does not call
        // `SummaryThinkingModelCatalog.completionTokenBudget(...)`. That rule
        // sizes a *summary* request whose cap has to cover a model's reasoning
        // pass on top of its answer, derived from a user-configured Max Tokens.
        // Cleanup has neither: S1-mini is a fixed, pinned normalizer requested
        // with `enable_thinking: false`, it emits no reasoning tokens, and its
        // output is bounded by the input rather than by a setting. Truncation
        // is still read from the provider's own signal (`.length` below) and
        // recovered by splitting the input, not by growing the cap — doubling
        // a budget cannot help a request whose answer is a rewrite of a
        // 1,000-token input. Register the model in the catalog if it is ever
        // replaced by one that reasons.
        let parameters = GenerateParameters(
            maxTokens: TranscriptCleanupCoordinator.maxNewOutputTokens,
            temperature: 0,
            topP: 1,
            topK: 0,
            minP: 0,
            repetitionPenalty: nil,
            presencePenalty: nil,
            frequencyPenalty: nil
        )

        let generations = try await generateWithTimeout(
            container: container,
            input: input,
            parameters: parameters
        )
        try Task.checkCancellation()
        var output = ""
        var completionInfo: GenerateCompletionInfo?
        for generation in generations {
            switch generation {
            case .chunk(let chunk):
                output += chunk
            case .info(let info):
                completionInfo = info
            case .toolCall:
                throw TranscriptCleanupNormalizerError.generationFailed
            }
        }

        guard let completionInfo else {
            throw TranscriptCleanupNormalizerError.generationFailed
        }

        return TranscriptCleanupGeneration(
            text: output,
            inputTokenCount: completionInfo.promptTokenCount,
            outputTokenCount: completionInfo.generationTokenCount,
            finishReason: Self.finishReason(completionInfo.stopReason)
        )
    }

    func releaseResources() async {
        let before = Memory.snapshot()
        modelContainer = nil
        Memory.clearCache()
        if let previousCacheLimit {
            Memory.cacheLimit = previousCacheLimit
            self.previousCacheLimit = nil
        }
        let after = Memory.snapshot()
        let beforeTotal = before.activeMemory + before.cacheMemory
        let afterTotal = after.activeMemory + after.cacheMemory
        let freed = beforeTotal >= afterTotal ? beforeTotal - afterTotal : 0
        AppLog.shared.transcription(
            "[TranscriptCleanup] Resources released — freed \(freed / (1024 * 1024))MB "
                + "(active: \(after.activeMemory / (1024 * 1024))MB, "
                + "cache: \(after.cacheMemory / (1024 * 1024))MB)"
        )
    }

    private func loadContainer() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        guard isReady else {
            throw TranscriptCleanupNormalizerError.modelUnavailable
        }

        // This is intentionally the directory overload. It cannot silently
        // fetch a missing model during transcription.
        if previousCacheLimit == nil {
            previousCacheLimit = Memory.cacheLimit
        }
        Memory.cacheLimit = Self.memoryCacheLimitBytes
        Memory.clearCache()
        let beforeLoad = Memory.snapshot()
        AppLog.shared.transcription(
            "[TranscriptCleanup] Memory configured: "
                + "cacheLimit=\(Self.memoryCacheLimitBytes / (1024 * 1024))MB, "
                + "active=\(beforeLoad.activeMemory / (1024 * 1024))MB, "
                + "cache=\(beforeLoad.cacheMemory / (1024 * 1024))MB"
        )
        let container = try await loadModelContainer(
            hub: defaultHubApi,
            directory: TranscriptCleanupModelLocator.directory
        )
        modelContainer = container
        let afterLoad = Memory.snapshot()
        AppLog.shared.transcription(
            "[TranscriptCleanup] Model loaded — "
                + "active=\(afterLoad.activeMemory / (1024 * 1024))MB, "
                + "cache=\(afterLoad.cacheMemory / (1024 * 1024))MB, "
                + "peak=\(afterLoad.peakMemory / (1024 * 1024))MB"
        )
        return container
    }

    private func generateWithTimeout(
        container: ModelContainer,
        input: LMInput,
        parameters: GenerateParameters
    ) async throws -> [Generation] {
        let inputTransfer = TranscriptCleanupInputTransfer(input)
        return try await withThrowingTaskGroup(of: [Generation].self) { group in
            group.addTask { [container, inputTransfer] in
                let stream = try await container.generate(
                    input: inputTransfer.consume(),
                    parameters: parameters
                )
                var values: [Generation] = []
                for await value in stream {
                    try Task.checkCancellation()
                    values.append(value)
                }
                // A cancelled consumer ends the stream without an error;
                // report it as cancellation, not as a failed generation.
                try Task.checkCancellation()
                return values
            }
            group.addTask {
                // Bounds one model call. A piece that hits it keeps its
                // original text and the run continues; the run as a whole is
                // bounded by its piece count, and pauses in the background.
                try await Task.sleep(nanoseconds: Self.generationTimeoutNanoseconds)
                throw TranscriptCleanupNormalizerError.generationFailed
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw TranscriptCleanupNormalizerError.generationFailed
            }
            return result
        }
    }

    private static func finishReason(_ reason: GenerateStopReason) -> TranscriptCleanupFinishReason {
        switch reason {
        case .stop: return .stop
        case .length: return .length
        case .cancelled: return .cancelled
        }
    }
}
#else
actor MLXTranscriptCleanupService: TranscriptCleanupNormalizing {
    static let shared = MLXTranscriptCleanupService()

    var isReady: Bool { false }

    func renderedRequestTokenCount(for rawText: String) async throws -> Int {
        throw TranscriptCleanupNormalizerError.modelUnavailable
    }

    func normalize(_ rawText: String) async throws -> TranscriptCleanupGeneration {
        throw TranscriptCleanupNormalizerError.modelUnavailable
    }

    func releaseResources() async {}
}
#endif
