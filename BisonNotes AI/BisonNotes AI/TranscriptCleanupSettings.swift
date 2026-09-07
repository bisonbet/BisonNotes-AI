//
//  TranscriptCleanupSettings.swift
//  BisonNotes AI
//
//  Fixed, device-local configuration for the optional English transcript
//  cleanup feature.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum TranscriptCleanupSettings {
    static let modelId = "mlx-community/S1-mini-MLX-8bit"
    static let modelRevision = "f0d7fe6b2f57e53f454f7da2110412f9820c490e"
    static let promptVersion = "s1-mini-normalizer-v1"
    static let modelAttribution = "S1-mini by Superwhisper"
    static let defaultEnabled = false

    static let systemPrompt =
        "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    static let controlLine = "[Styling: semi-formal] [Structure: prose] [Context: general]"

    enum Keys {
        static let enabled = "transcriptCleanupEnabled"
    }

    static func userMessage(for rawText: String) -> String {
        "\(controlLine)\n\(rawText)"
    }

    static func messages(for rawText: String) -> [[String: any Sendable]] {
        [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userMessage(for: rawText)]
        ]
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: Keys.enabled) as? Bool else {
            return defaultEnabled
        }
        return value
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.enabled)
    }

    static var availability: TranscriptCleanupAvailability {
        #if os(watchOS)
        return .unsupported("Transcript cleanup is unavailable on Apple Watch.")
        #elseif targetEnvironment(simulator)
        return .unsupported("Transcript cleanup is unavailable in the simulator.")
        #elseif os(macOS)
        #if arch(arm64)
        return DeviceCapabilities.supportsMLX
            ? .available
            : .unsupported("This Mac does not have enough memory for on-device cleanup.")
        #else
        return .unsupported("Transcript cleanup requires Apple silicon on macOS.")
        #endif
        #else
        #if canImport(UIKit)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return .unsupported("Transcript cleanup is unavailable in the iOS app running on Mac.")
        }
        #endif
        return DeviceCapabilities.supportsMLX
            ? .available
            : .unsupported("This device does not have enough memory for on-device cleanup.")
        #endif
    }
}

enum TranscriptCleanupAvailability: Equatable, Sendable {
    case available
    case unsupported(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var explanation: String? {
        if case .unsupported(let explanation) = self { return explanation }
        return nil
    }
}

enum TranscriptCleanupMode: Sendable, Equatable {
    case automatic
    case manual(confirmedEnglish: Bool)
}

struct TranscriptCleanupConfiguration: Sendable, Equatable {
    let enabled: Bool
    let mode: TranscriptCleanupMode
    let languageCode: String?

    static func automatic(
        defaults: UserDefaults = .standard,
        languageCode: String? = nil
    ) -> TranscriptCleanupConfiguration {
        TranscriptCleanupConfiguration(
            enabled: TranscriptCleanupSettings.isEnabled(in: defaults),
            mode: .automatic,
            languageCode: languageCode
        )
    }

    static func manual(
        languageCode: String? = nil,
        confirmedEnglish: Bool = false
    ) -> TranscriptCleanupConfiguration {
        TranscriptCleanupConfiguration(
            enabled: true,
            mode: .manual(confirmedEnglish: confirmedEnglish),
            languageCode: languageCode
        )
    }
}

enum TranscriptCleanupWarning: Equatable, Sendable, LocalizedError {
    case missingModel
    case unsupportedPlatform(String)
    case nonEnglish
    case uncertainLanguage
    case resourceFailure
    case invalidOutput
    case staleResult
    case cancelled

    var errorDescription: String? { userVisibleMessage }

    var userVisibleMessage: String {
        switch self {
        case .missingModel:
            return "Transcript saved. Download S1-mini to clean up English text."
        case .unsupportedPlatform(let reason):
            return reason
        case .nonEnglish:
            return "Transcript cleanup is available for English text only. The original transcript was kept."
        case .uncertainLanguage:
            return "The language could not be confirmed as English, so the original transcript was kept."
        case .resourceFailure:
            return "Transcript cleanup could not run because the on-device model was unavailable. The original transcript was kept."
        case .invalidOutput:
            return "Transcript cleanup returned an invalid result. The original transcript was kept."
        case .staleResult:
            return "Transcript cleanup finished after the transcript changed. Its result was discarded."
        case .cancelled:
            return "Transcript cleanup was cancelled. The original transcript was kept."
        }
    }

    var logCategory: String {
        switch self {
        case .missingModel: return "missing-model"
        case .unsupportedPlatform: return "unsupported-platform"
        case .nonEnglish: return "non-english"
        case .uncertainLanguage: return "uncertain-language"
        case .resourceFailure: return "resource-failure"
        case .invalidOutput: return "invalid-output"
        case .staleResult: return "stale-result"
        case .cancelled: return "cancelled"
        }
    }
}

enum TranscriptCleanupFinishReason: Sendable, Equatable {
    case stop
    case length
    case cancelled
}

struct TranscriptCleanupGeneration: Sendable, Equatable {
    let text: String
    let inputTokenCount: Int
    let outputTokenCount: Int
    let finishReason: TranscriptCleanupFinishReason
}

enum TranscriptCleanupNormalizerError: Error, Equatable, Sendable {
    case modelUnavailable
    case templateUnavailable
    case generationFailed
    case invalidRequest
    case invalidOutput
    case cancelled
}

/// Normalization is injected so all chunking, validation, stale-result, and
/// preservation behavior can be tested without downloading a model.
protocol TranscriptCleanupNormalizing: Sendable {
    var isReady: Bool { get async }
    func renderedRequestTokenCount(for rawText: String) async throws -> Int
    func normalize(_ rawText: String) async throws -> TranscriptCleanupGeneration
    func releaseResources() async
}

struct TranscriptCleanupResult: Sendable {
    let segments: [TranscriptSegment]
    let warning: TranscriptCleanupWarning?
    let cleanedSegmentCount: Int

    var didClean: Bool { warning == nil && cleanedSegmentCount > 0 }
}

/// A process-local permit shared by cleanup and the existing MLX summary
/// engine. Model containers are still owned by their respective actors, but
/// generation ownership is explicit across those actors.
actor MLXModelResourceCoordinator {
    static let shared = MLXModelResourceCoordinator()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isOccupied = false
    private var waiters: [Waiter] = []

    /// Returns false when the caller was cancelled while waiting. A plain
    /// continuation would leave a cancelled cleanup request queued behind a
    /// long summary generation, making the editor's Cancel action appear stuck.
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !isOccupied {
            isOccupied = true
            return true
        }

        let id = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id: id) }
        })
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.continuation.resume(returning: true)
        } else {
            isOccupied = false
        }
    }

    func withExclusive<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        guard await acquire() else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}
