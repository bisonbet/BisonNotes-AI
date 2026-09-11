import Foundation

enum LibrarySettingsTargetPlatform: String, CaseIterable, Equatable, Sendable {
    case macOS
    case iOS
}

/// Capabilities and fallback policy supplied by the app that will own the
/// migrated settings. The runtime package must not import UIKit, DeviceCapabilities,
/// or provider implementations just to normalize a source snapshot.
struct LibrarySettingsNormalizationContext: Equatable, Sendable {
    let targetPlatform: LibrarySettingsTargetPlatform
    let supportsMLX: Bool
    let supportedMLXModelIDs: Set<String>
    let preferredMLXModelID: String?
    let fallbackAIEngine: String
    let fallbackTranscriptionEngine: String

    init(
        targetPlatform: LibrarySettingsTargetPlatform,
        supportsMLX: Bool,
        supportedMLXModelIDs: Set<String> = [],
        preferredMLXModelID: String? = nil,
        fallbackAIEngine: String = "None",
        fallbackTranscriptionEngine: String = "Not Configured"
    ) {
        self.targetPlatform = targetPlatform
        self.supportsMLX = supportsMLX
        self.supportedMLXModelIDs = supportedMLXModelIDs
        self.preferredMLXModelID = preferredMLXModelID
        self.fallbackAIEngine = fallbackAIEngine
        self.fallbackTranscriptionEngine = fallbackTranscriptionEngine
    }
}

enum LibrarySettingsNormalizationError: LocalizedError, Equatable, Sendable {
    case invalidFallbackAIEngine(String)
    case invalidFallbackTranscriptionEngine(String)
    case invalidPreferredMLXModelID(String)

    var errorDescription: String? {
        switch self {
        case .invalidFallbackAIEngine(let value):
            return "The settings normalization fallback AI engine is invalid: \(value)"
        case .invalidFallbackTranscriptionEngine(let value):
            return "The settings normalization fallback transcription engine is invalid: \(value)"
        case .invalidPreferredMLXModelID(let value):
            return "The preferred MLX model is not in the supported model set: \(value)"
        }
    }
}

struct LibrarySettingsNormalizationResult: Equatable, Sendable {
    let snapshot: LibrarySettingsSnapshot
    let changedKeys: [String]
    let omittedKeys: [String]
}

/// Canonicalizes source settings before the migration catalog validates them.
///
/// This is intentionally a pure, storage-neutral boundary. It does not inspect
/// hardware, query Keychain, choose a configured provider, or write UserDefaults.
/// A future startup caller supplies the target device facts and persists the
/// resulting snapshot only through the migration coordinator.
enum LibrarySettingsNormalizer {
    private struct State {
        var values: [String: LibrarySettingValue]
        var changedKeys: Set<String> = []
        var omittedKeys: Set<String> = []

        mutating func replace(_ key: String, with value: LibrarySettingValue) {
            guard values[key] != value else { return }
            values[key] = value
            changedKeys.insert(key)
        }

        mutating func omit(_ key: String) {
            guard values.removeValue(forKey: key) != nil else { return }
            omittedKeys.insert(key)
        }
    }

    private static let ollamaKeys: Set<String> = [
        "ollamaServerURL",
        "ollamaPort",
        "ollamaModelName",
        "ollamaMaxTokens",
        "ollamaTemperature",
        "ollamaContextTokens",
        "enableOllama"
    ]

    private static let endpointKeys: Set<String> = [
        "openAICompatibleBaseURL",
        "mistralBaseURL",
        "ollamaServerURL",
        "whisperServerURL"
    ]

    static func normalize(
        _ snapshot: LibrarySettingsSnapshot,
        for context: LibrarySettingsNormalizationContext
    ) throws -> LibrarySettingsNormalizationResult {
        try validate(context: context)

        var state = State(values: snapshot.values)
        for key in state.values.keys.sorted() {
            normalizeValue(key, in: &state, context: context)
        }

        if context.targetPlatform == .iOS {
            for key in ollamaKeys {
                state.omit(key)
            }
        }

        normalizeMLXState(in: &state, context: context)

        let normalizedSnapshot = LibrarySettingsSnapshot(values: state.values)
        try LibrarySettingsCatalog.validateMigratableSnapshot(normalizedSnapshot)

        return LibrarySettingsNormalizationResult(
            snapshot: normalizedSnapshot,
            changedKeys: state.changedKeys.sorted(),
            omittedKeys: state.omittedKeys.sorted()
        )
    }

    private static func normalizeValue(
        _ key: String,
        in state: inout State,
        context: LibrarySettingsNormalizationContext
    ) {
        guard let value = state.values[key], case .string(let rawValue) = value else {
            return
        }

        switch key {
        case "SelectedAIEngine":
            state.replace(
                key,
                with: .string(normalizeAIEngine(rawValue, context: context))
            )
        case "selectedTranscriptionEngine":
            state.replace(
                key,
                with: .string(normalizeTranscriptionEngine(rawValue, context: context))
            )
        default:
            guard endpointKeys.contains(key) else { return }
            state.replace(key, with: .string(normalizeEndpoint(rawValue)))
        }
    }

    private static func normalizeMLXState(
        in state: inout State,
        context: LibrarySettingsNormalizationContext
    ) {
        guard context.supportsMLX else {
            state.omit("mlxSwiftModelId")
            if state.values["mlxSwiftExperimentalEnabled"] != nil {
                state.replace("mlxSwiftExperimentalEnabled", with: .bool(false))
            }
            return
        }

        guard let modelValue = state.values["mlxSwiftModelId"],
              case .string(let rawModelID) = modelValue else {
            return
        }

        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            state.omit("mlxSwiftModelId")
            return
        }

        guard !context.supportedMLXModelIDs.isEmpty,
              !context.supportedMLXModelIDs.contains(modelID) else {
            state.replace("mlxSwiftModelId", with: .string(modelID))
            return
        }

        if let preferredMLXModelID = context.preferredMLXModelID {
            state.replace("mlxSwiftModelId", with: .string(preferredMLXModelID))
        } else {
            state.omit("mlxSwiftModelId")
        }
    }

    private static func validate(context: LibrarySettingsNormalizationContext) throws {
        if context.targetPlatform == .iOS && context.fallbackAIEngine == "Ollama"
            || !context.supportsMLX && context.fallbackAIEngine == "MLX Swift" {
            throw LibrarySettingsNormalizationError.invalidFallbackAIEngine(
                context.fallbackAIEngine
            )
        }

        do {
            try LibrarySettingsCatalog.validateMigratableSnapshot(
                LibrarySettingsSnapshot(values: [
                    "SelectedAIEngine": .string(context.fallbackAIEngine)
                ])
            )
        } catch {
            throw LibrarySettingsNormalizationError.invalidFallbackAIEngine(
                context.fallbackAIEngine
            )
        }

        do {
            try LibrarySettingsCatalog.validateMigratableSnapshot(
                LibrarySettingsSnapshot(values: [
                    "selectedTranscriptionEngine": .string(context.fallbackTranscriptionEngine)
                ])
            )
        } catch {
            throw LibrarySettingsNormalizationError.invalidFallbackTranscriptionEngine(
                context.fallbackTranscriptionEngine
            )
        }

        if let preferredMLXModelID = context.preferredMLXModelID,
           !context.supportsMLX || !context.supportedMLXModelIDs.contains(preferredMLXModelID) {
            throw LibrarySettingsNormalizationError.invalidPreferredMLXModelID(
                preferredMLXModelID
            )
        }
    }

    private static func normalizeAIEngine(
        _ rawValue: String,
        context: LibrarySettingsNormalizationContext
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "compatible api", "openai-compatible", "openai":
            return "OpenAI API Compatible"
        case "apple intelligence", "enhanced apple intelligence", "enhancedappleintelligence",
             "on-device ai", "on device ai", "on-device llm", "on device llm",
             "on-device ai (legacy)", "on device ai (legacy)", "on-device ai legacy", "on device ai legacy":
            return context.supportsMLX ? "MLX Swift" : context.fallbackAIEngine
        case "aws bedrock", "aws transcribe", "not configured":
            return context.fallbackAIEngine
        case "ollama":
            return context.targetPlatform == .macOS ? "Ollama" : context.fallbackAIEngine
        case "mlx swift":
            return context.supportsMLX ? "MLX Swift" : context.fallbackAIEngine
        case "none":
            return "None"
        default:
            return value
        }
    }

    private static func normalizeTranscriptionEngine(
        _ rawValue: String,
        context: LibrarySettingsNormalizationContext
    ) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "on device (whisperkit)", "whisperkit", "on-device", "on device",
             "apple transcription", "fluid audio", "fluidaudio":
            return "On Device"
        case "openai", "openai api compatible":
            return context.fallbackTranscriptionEngine
        case "not configured":
            return "Not Configured"
        default:
            return value
        }
    }

    private static func normalizeEndpoint(_ rawValue: String) -> String {
        var normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
