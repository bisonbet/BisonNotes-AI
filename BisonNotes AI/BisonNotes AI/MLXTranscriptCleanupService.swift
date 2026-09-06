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
        precondition(value != nil, "Transcript cleanup input was consumed more than once")
        return value!
    }
}

actor MLXTranscriptCleanupService: TranscriptCleanupNormalizing {
    static let shared = MLXTranscriptCleanupService()

    private var modelContainer: ModelContainer?

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
        let promptTokens = try tokenizer.applyChatTemplate(
            messages: messages,
            chatTemplate: nil,
            addGenerationPrompt: true,
            truncation: false,
            maxLength: nil,
            tools: nil,
            additionalContext: ["enable_thinking": false]
        )
        guard promptTokens.count <= TranscriptCleanupCoordinator.maxRenderedInputTokens else {
            throw TranscriptCleanupNormalizerError.invalidRequest
        }

        let input = try await container.prepare(
            input: UserInput(
                messages: messages,
                additionalContext: ["enable_thinking": false]
            )
        )
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
        guard modelContainer != nil else { return }
        modelContainer = nil
        Memory.clearCache()
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
        Memory.clearCache()
        let container = try await loadModelContainer(
            hub: defaultHubApi,
            directory: TranscriptCleanupModelLocator.directory
        )
        modelContainer = container
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
                return values
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 120_000_000_000)
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
