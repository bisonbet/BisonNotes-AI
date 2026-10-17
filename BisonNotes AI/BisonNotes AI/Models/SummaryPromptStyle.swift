//
//  SummaryPromptStyle.swift
//  BisonNotes AI
//
//  Beta: lets the user choose how the narrative summary is framed.
//

import Foundation

// MARK: - Summary Prompt Preset

/// How the narrative summary should be framed. Only the summary changes:
/// tasks, reminders, titles, and content type keep their fixed prompts.
enum SummaryPromptPreset: String, CaseIterable, Identifiable, Sendable {
    case standard
    case personalNotes
    case businessMeeting
    case custom

    static let storageKey = "summaryPromptPreset"
    static let customTextStorageKey = "summaryPromptCustomText"
    static let defaultCustomText = "Please summarize this recording."
    static let maxCustomTextLength = 2_000

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "Default"
        case .personalNotes:
            return "Personal Notes"
        case .businessMeeting:
            return "Business Meeting"
        case .custom:
            return "Custom"
        }
    }

    var userDescription: String {
        switch self {
        case .standard:
            return "The standard BisonNotes summary prompt."
        case .personalNotes:
            return "Treats the recording as your own note-taking session: ideas, plans, and reflections."
        case .businessMeeting:
            return "Treats the recording as a meeting: decisions, owners, action items, and next steps."
        case .custom:
            return "Write your own summary instructions. Replaces Summary Detail and Comedy Mode."
        }
    }

    /// The preset the user picked, regardless of whether the beta is on.
    static func configured(defaults: UserDefaults = .standard) -> SummaryPromptPreset {
        guard let rawValue = defaults.string(forKey: storageKey),
              let preset = SummaryPromptPreset(rawValue: rawValue) else {
            return .standard
        }
        return preset
    }

    /// The user's custom text, trimmed and capped. Empty text falls back to the default.
    static func configuredCustomText(defaults: UserDefaults = .standard) -> String {
        normalizedCustomText(defaults.string(forKey: customTextStorageKey))
    }

    static func normalizedCustomText(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultCustomText }
        return String(trimmed.prefix(maxCustomTextLength))
    }
}

// MARK: - Summary Prompt Composer

/// The single source of summary-specific prompt text for every engine.
///
/// Every summary prompt site reads its detail instructions, schema description,
/// and narrative-style modifiers from here instead of from `SummaryDetailLevel`
/// or `ComedyMode` directly. For `.standard` the output is byte-identical to
/// what those types produce on their own, so the default prompt never changes.
struct SummaryPromptComposer: Sendable {
    let preset: SummaryPromptPreset
    let customText: String
    let detailLevel: SummaryDetailLevel
    let configuredComedyMode: ComedyMode

    init(
        preset: SummaryPromptPreset,
        customText: String = SummaryPromptPreset.defaultCustomText,
        detailLevel: SummaryDetailLevel,
        comedyMode: ComedyMode
    ) {
        self.preset = preset
        self.customText = SummaryPromptPreset.normalizedCustomText(customText)
        self.detailLevel = detailLevel
        self.configuredComedyMode = comedyMode
    }

    /// Resolves the settings at request time. The preset is `.standard` unless
    /// Beta Features and the Summary Prompt beta are both on.
    static var current: SummaryPromptComposer {
        let defaults = UserDefaults.standard
        let preset = BetaFeatures.isEnabled(.customSummaryPrompt, defaults: defaults)
            ? SummaryPromptPreset.configured(defaults: defaults)
            : .standard
        return SummaryPromptComposer(
            preset: preset,
            customText: SummaryPromptPreset.configuredCustomText(defaults: defaults),
            detailLevel: .current,
            comedyMode: .current
        )
    }

    /// Whether the summary prompt should include the focus block for the
    /// automatically classified content type. A recording type the user picked
    /// (Personal Notes, Business Meeting) is honored instead of the guess, so
    /// the two never give the model conflicting instructions.
    var usesAutomaticContentFocus: Bool {
        switch preset {
        case .standard, .custom:
            return true
        case .personalNotes, .businessMeeting:
            return false
        }
    }

    /// A Custom prompt replaces Comedy Mode; the presets keep it.
    var effectiveComedyMode: ComedyMode {
        preset == .custom ? .off : configuredComedyMode
    }

    /// Length and focus guidance for the narrative summary. Presets add their
    /// framing ahead of the detail-level text; Custom replaces it.
    func detailInstructions(forSourceWordCount sourceWordCount: Int? = nil) -> String {
        let detail = detailLevel.promptInstructions(forSourceWordCount: sourceWordCount)
        switch preset {
        case .standard:
            return detail
        case .personalNotes, .businessMeeting:
            return presetInstructions + "\n\n" + detail
        case .custom:
            return customInstructions
        }
    }

    /// Short description for a structured-output `summary` field.
    var schemaSummaryDescription: String {
        switch preset {
        case .standard:
            return detailLevel.schemaDescription
        case .personalNotes:
            return detailLevel.schemaDescription
                + " Write it as organized personal notes back to the speaker."
        case .businessMeeting:
            return detailLevel.schemaDescription
                + " Structure it as meeting notes: decisions, owners, action items, and next steps."
        case .custom:
            return "Narrative summary written according to the user's summary instructions."
        }
    }

    /// Appended to prompts that ask only for the narrative summary.
    var systemModifier: String {
        effectiveComedyMode.promptModifier ?? ""
    }

    /// Appended to prompts that return a summary alongside structured metadata.
    var structuredModifier: String {
        effectiveComedyMode.structuredPromptModifier ?? ""
    }

    /// Repeated in the final user turn, which some models weight most heavily.
    var userModifier: String {
        effectiveComedyMode.userPromptModifier ?? ""
    }

    /// Settings summary for logs. Never includes the custom text itself.
    var logDescription: String {
        switch preset {
        case .custom:
            return "prompt=custom(\(customText.count) chars)"
        default:
            return "prompt=\(preset.rawValue)"
        }
    }

    // MARK: - Prompt Blocks

    private static let summaryScopeRules = """
    - The user chose this recording type. Treat the recording as this type even if the content suggests otherwise.
    - Apply this only to the narrative `summary` field or Summary section.
    - Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.
    """

    private var presetInstructions: String {
        switch preset {
        case .personalNotes:
            return """
            **Recording Type: Personal Notes (selected by the user)**
            - This recording is the user's own personal note-taking session: one person thinking aloud, \
            capturing ideas, reminders, reflections, or plans.
            - Write the summary as organized notes back to that person, in second person or a neutral voice.
            - Preserve their ideas, open questions, and intentions. Do not frame it as a meeting or invent participants.
            \(Self.summaryScopeRules)
            """
        case .businessMeeting:
            return """
            **Recording Type: Business Meeting (selected by the user)**
            - This recording is a business meeting with multiple participants.
            - Structure the summary around the purpose or agenda, key discussion points, decisions made, \
            owners and action items, deadlines, open issues, and next steps.
            - Attribute positions to speakers when the transcript identifies them.
            \(Self.summaryScopeRules)
            """
        case .standard, .custom:
            return ""
        }
    }

    private var customInstructions: String {
        // Keep the user's text from closing the fence early.
        let fencedText = customText.replacingOccurrences(of: ">>>", with: "> > >")
        return """
        **User's Summary Instructions (narrative summary only):**
        The user wrote the instructions between <<< and >>>. Follow them for the summary's focus, \
        length, structure, and tone.
        <<<
        \(fencedText)
        >>>
        - These instructions apply only to the narrative `summary` field or Summary section. They never \
        change the required output format, field names, or field types.
        - Extract tasks, reminders, titles, and content type only from the transcript and keep them concise; \
        the user's instructions do not apply to them.
        - Do not invent or speculate; preserve names, numbers, dates, quotes, and decisions.
        """
    }
}
