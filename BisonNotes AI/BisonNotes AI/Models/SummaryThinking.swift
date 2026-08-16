import Foundation

// MARK: - Summary Thinking Preference

/// The only user-selectable thinking level for summaries.
///
/// `.none` deliberately means that the request contains no thinking-related
/// field. This lets each provider keep its own default behavior and avoids
/// turning thinking on for models that do not support it.
public enum SummaryThinkingLevel: Int, CaseIterable, Identifiable, Equatable, Sendable {
    case none = 0
    case light = 1

    static let storageKey = "summaryThinkingLevel"
    static let defaultLevel: SummaryThinkingLevel = .none

    public var id: Int { rawValue }

    static var current: SummaryThinkingLevel {
        guard let storedValue = UserDefaults.standard.object(forKey: storageKey) as? Int,
              let level = SummaryThinkingLevel(rawValue: storedValue) else {
            return defaultLevel
        }
        return level
    }

    var displayName: String {
        switch self {
        case .none:
            return "Off"
        case .light:
            return "Light"
        }
    }

    var userDescription: String {
        switch self {
        case .none:
            return "Use the model's normal response mode. No thinking override is sent."
        case .light:
            return "Ask supported models for a short reasoning pass, not heavy or maximum thinking."
        }
    }
}

// MARK: - Model Capability Catalog

enum SummaryThinkingTransport: Equatable, Sendable {
    case openAIReasoningEffort
    case mistralReasoningEffort
    case qwenHosted
    case qwenChatTemplate
    case gemmaChatTemplate
    case geminiThinkingLevel
    case geminiThinkingBudget
    case ollama
    case mlx
    case onDeviceQwenTemplate
}

enum SummaryThinkingSupport: Equatable, Sendable {
    case unsupported
    case controllable(SummaryThinkingTransport)
    case thinkingOnly

    var isControllable: Bool {
        if case .controllable = self {
            return true
        }
        return false
    }
}

struct SummaryThinkingProfile: Equatable, Sendable {
    let modelName: String
    let support: SummaryThinkingSupport
}

/// Provider-neutral request fields produced by the capability catalog.
/// Providers only encode the fields their transport understands.
struct SummaryThinkingRequestOptions: Equatable, Sendable {
    let reasoningEffort: String?
    let enableThinking: Bool?
    let thinkingBudget: Int?
    let thinkingLevel: String?
    let chatTemplateKwargs: [String: Bool]?
    let ollamaThinkLevel: String?

    static let none = SummaryThinkingRequestOptions(
        reasoningEffort: nil,
        enableThinking: nil,
        thinkingBudget: nil,
        thinkingLevel: nil,
        chatTemplateKwargs: nil,
        ollamaThinkLevel: nil
    )

    var isEmpty: Bool {
        reasoningEffort == nil
            && enableThinking == nil
            && thinkingBudget == nil
            && thinkingLevel == nil
            && chatTemplateKwargs == nil
            && ollamaThinkLevel == nil
    }
}

/// Removes reasoning-channel markup when a provider returns it inline instead
/// of using a separate response field or content block.
enum SummaryThinkingResponseCleaner {
    private static let reasoningTags = ["think", "analysis", "reasoning"]

    static func stripDelimitedThinking(from text: String) -> String {
        var cleaned = text

        for tag in reasoningTags {
            cleaned = cleaned.replacingOccurrences(
                of: "(?is)<\(tag)>.*?</\(tag)>",
                with: "",
                options: .regularExpression
            )

            // A response can hit its output limit before closing the reasoning
            // tag; never expose a partial reasoning trace as the summary.
            if let openTag = cleaned.range(of: "<\(tag)>", options: .caseInsensitive) {
                cleaned.removeSubrange(openTag.lowerBound...)
            }
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
