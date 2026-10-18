//
//  SummaryPromptStyle.swift
//  BisonNotes AI
//
//  Beta: lets the user choose how the narrative summary is framed.
//

import Foundation

// MARK: - Summary Prompt Kind

/// What kind of prompt a `SummaryPrompt` is. Only the summary changes:
/// tasks, reminders, titles, and content type keep their fixed prompts.
enum SummaryPromptPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case personalNotes
    case businessMeeting
    case custom

    /// Settings from before prompts were editable, read once by
    /// `SummaryPromptLibrary.migrateLegacySettingsIfNeeded`.
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

    static func normalizedCustomText(_ text: String?) -> String {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultCustomText }
        return String(trimmed.prefix(maxCustomTextLength))
    }
}

// MARK: - Recording Type

/// The recording type a custom prompt declares. Auto-detect keeps the
/// automatic guess; Meeting and Personal Notes replace it, like the built-ins.
enum SummaryRecordingType: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case meeting
    case personalNotes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto-detect"
        case .meeting:
            return "Meeting"
        case .personalNotes:
            return "Personal Notes"
        }
    }

    var contentType: ContentType? {
        switch self {
        case .auto:
            return nil
        case .meeting:
            return .meeting
        case .personalNotes:
            return .personalJournal
        }
    }
}

// MARK: - Summary Prompt

/// One prompt in the user's library: Default (fixed), Business Meeting and
/// Personal Notes (wording editable, name fixed), or up to five custom prompts.
struct SummaryPrompt: Codable, Identifiable, Equatable, Sendable {
    static let defaultID = "default"
    static let businessMeetingID = "business-meeting"
    static let personalNotesID = "personal-notes"
    /// The custom prompt migrated from the single Custom prompt of earlier builds.
    static let legacyCustomID = "legacy-custom"
    static let maxNameLength = 40

    let id: String
    let kind: SummaryPromptPreset
    var name: String
    /// For built-ins, the editable description of the recording type; for a
    /// custom prompt, the user's instructions. Unused for Default.
    var text: String
    /// Only meaningful for custom prompts.
    var recordingType: SummaryRecordingType

    static let standard = SummaryPrompt(
        id: defaultID, kind: .standard, name: "Default", text: "", recordingType: .auto
    )

    static let originalBusinessMeeting = SummaryPrompt(
        id: businessMeetingID,
        kind: .businessMeeting,
        name: "Business Meeting",
        text: """
        - This recording is a business meeting with multiple participants.
        - Structure the summary around the purpose or agenda, key discussion points, decisions made, \
        owners and action items, deadlines, open issues, and next steps.
        - Attribute positions to speakers when the transcript identifies them.
        """,
        recordingType: .meeting
    )

    static let originalPersonalNotes = SummaryPrompt(
        id: personalNotesID,
        kind: .personalNotes,
        name: "Personal Notes",
        text: """
        - This recording is the user's own personal note-taking session: one person thinking aloud, \
        capturing ideas, reminders, reflections, or plans.
        - Write the summary as organized notes back to that person, in second person or a neutral voice.
        - Preserve their ideas, open questions, and intentions. Do not frame it as a meeting or invent participants.
        """,
        recordingType: .personalNotes
    )

    static func newCustom(number: Int, id: String = UUID().uuidString) -> SummaryPrompt {
        SummaryPrompt(
            id: id,
            kind: .custom,
            name: "Custom \(number)",
            text: SummaryPromptPreset.defaultCustomText,
            recordingType: .auto
        )
    }

    var isBuiltIn: Bool { kind != .custom }
    var isEditable: Bool { kind != .standard }

    /// The built-in this prompt started as, for Restore Original.
    var original: SummaryPrompt? {
        switch kind {
        case .businessMeeting: return .originalBusinessMeeting
        case .personalNotes: return .originalPersonalNotes
        case .standard: return .standard
        case .custom: return nil
        }
    }

    /// True when a built-in's wording differs from its original.
    var isEdited: Bool {
        guard let original, kind != .standard else { return false }
        return text != original.text
    }

    /// The recording type this prompt declares; nil keeps the automatic guess.
    var declaredContentType: ContentType? {
        switch kind {
        case .standard: return nil
        case .businessMeeting: return .meeting
        case .personalNotes: return .personalJournal
        case .custom: return recordingType.contentType
        }
    }

    var userDescription: String {
        switch kind {
        case .standard:
            return "The standard BisonNotes summary prompt."
        case .personalNotes:
            return "Treats the recording as your own note-taking session: ideas, plans, and reflections."
        case .businessMeeting:
            return "Treats the recording as a meeting: decisions, owners, action items, and next steps."
        case .custom:
            return "Your own instructions. Replaces Summary Detail and Comedy Mode."
        }
    }

    /// Trims and caps user input. Built-ins keep their fixed names and fall
    /// back to their original wording when cleared.
    func normalized() -> SummaryPrompt {
        var result = self
        switch kind {
        case .standard:
            return .standard
        case .businessMeeting, .personalNotes:
            let original = self.original ?? self
            result.name = original.name
            result.recordingType = original.recordingType
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.text = trimmed.isEmpty
                ? original.text
                : String(trimmed.prefix(SummaryPromptPreset.maxCustomTextLength))
        case .custom:
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.name = trimmedName.isEmpty ? "Custom" : String(trimmedName.prefix(Self.maxNameLength))
            result.text = SummaryPromptPreset.normalizedCustomText(text)
        }
        return result
    }
}

// MARK: - Prompt Library

/// The user's prompts and which one new summaries use. Stored as one JSON
/// value in settings, so it syncs through iCloud settings backup.
enum SummaryPromptLibrary {
    static let storageKey = "summaryPromptLibrary"
    static let defaultPromptIDKey = "summaryPromptDefaultID"
    static let legacyMigrationKey = "summaryPromptLibraryMigrated"
    static let maxCustomPrompts = 5

    private struct Stored: Codable {
        /// Edited wording for Business Meeting and Personal Notes, by ID.
        var builtInText: [String: String] = [:]
        var customs: [SummaryPrompt] = []
    }

    private static func load(_ defaults: UserDefaults) -> Stored {
        guard let json = defaults.string(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(json.utf8)) else {
            return Stored()
        }
        return stored
    }

    private static func store(_ stored: Stored, _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(stored),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: storageKey)
    }

    /// Default, Business Meeting, Personal Notes, then the custom prompts.
    static func prompts(defaults: UserDefaults = .standard) -> [SummaryPrompt] {
        let stored = load(defaults)
        var business = SummaryPrompt.originalBusinessMeeting
        var personal = SummaryPrompt.originalPersonalNotes
        if let text = stored.builtInText[business.id] { business.text = text }
        if let text = stored.builtInText[personal.id] { personal.text = text }
        let customs = stored.customs
            .filter { $0.kind == .custom }
            .prefix(maxCustomPrompts)
            .map { $0.normalized() }
        return [.standard, business.normalized(), personal.normalized()] + customs
    }

    static func prompt(id: String, defaults: UserDefaults = .standard) -> SummaryPrompt? {
        prompts(defaults: defaults).first { $0.id == id }
    }

    static func customCount(defaults: UserDefaults = .standard) -> Int {
        prompts(defaults: defaults).filter { $0.kind == .custom }.count
    }

    /// Saves an edited prompt. Built-ins store only their wording, and only
    /// while it differs from the original. Returns false when nothing was
    /// saved: Default, or a new custom prompt when five already exist (another
    /// device or a settings restore can fill the library while an editor is
    /// open).
    @discardableResult
    static func save(_ prompt: SummaryPrompt, defaults: UserDefaults = .standard) -> Bool {
        let prompt = prompt.normalized()
        var stored = load(defaults)
        switch prompt.kind {
        case .standard:
            return false
        case .businessMeeting, .personalNotes:
            if prompt.isEdited {
                stored.builtInText[prompt.id] = prompt.text
            } else {
                stored.builtInText.removeValue(forKey: prompt.id)
            }
        case .custom:
            if let index = stored.customs.firstIndex(where: { $0.id == prompt.id }) {
                stored.customs[index] = prompt
            } else {
                guard stored.customs.count < maxCustomPrompts else { return false }
                stored.customs.append(prompt)
            }
        }
        store(stored, defaults)
        return true
    }

    /// A new, unsaved custom prompt with the next free "Custom N" name, or
    /// nil when there are already five. It is kept only once it is saved.
    static func makeCustomDraft(defaults: UserDefaults = .standard) -> SummaryPrompt? {
        let stored = load(defaults)
        guard stored.customs.count < maxCustomPrompts else { return nil }
        let usedNames = Set(stored.customs.map(\.name))
        var number = stored.customs.count + 1
        while usedNames.contains("Custom \(number)") { number += 1 }
        return SummaryPrompt.newCustom(number: number)
    }

    /// Adds a new custom prompt, or returns nil when there are already five.
    @discardableResult
    static func addCustom(defaults: UserDefaults = .standard) -> SummaryPrompt? {
        guard let prompt = makeCustomDraft(defaults: defaults),
              save(prompt, defaults: defaults) else { return nil }
        return prompt
    }

    /// Deletes a custom prompt. Built-ins cannot be deleted. If it was the
    /// default for new summaries, Default takes over.
    static func delete(id: String, defaults: UserDefaults = .standard) {
        var stored = load(defaults)
        stored.customs.removeAll { $0.id == id }
        store(stored, defaults)
        if defaults.string(forKey: defaultPromptIDKey) == id {
            defaults.set(SummaryPrompt.defaultID, forKey: defaultPromptIDKey)
        }
    }

    static func restoreOriginal(id: String, defaults: UserDefaults = .standard) {
        var stored = load(defaults)
        stored.builtInText.removeValue(forKey: id)
        store(stored, defaults)
    }

    /// The prompt new summaries use. A missing or deleted choice is Default.
    static func defaultPrompt(defaults: UserDefaults = .standard) -> SummaryPrompt {
        let id = defaults.string(forKey: defaultPromptIDKey) ?? SummaryPrompt.defaultID
        return prompt(id: id, defaults: defaults) ?? .standard
    }

    static func setDefaultPrompt(id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: defaultPromptIDKey)
    }

    /// Earlier builds had one preset choice and one custom text. Their custom
    /// text becomes "Custom 1" and their choice becomes the default prompt.
    static func migrateLegacySettingsIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: legacyMigrationKey) else { return }
        defer { defaults.set(true, forKey: legacyMigrationKey) }

        let legacyPreset = defaults.string(forKey: SummaryPromptPreset.storageKey)
            .flatMap(SummaryPromptPreset.init(rawValue:))
        let legacyText = defaults.string(forKey: SummaryPromptPreset.customTextStorageKey)
        let hasCustomText = legacyText.map {
            SummaryPromptPreset.normalizedCustomText($0) != SummaryPromptPreset.defaultCustomText
        } ?? false

        if legacyPreset == .custom || hasCustomText,
           prompt(id: SummaryPrompt.legacyCustomID, defaults: defaults) == nil {
            var custom = SummaryPrompt.newCustom(number: 1, id: SummaryPrompt.legacyCustomID)
            custom.text = SummaryPromptPreset.normalizedCustomText(legacyText)
            save(custom, defaults: defaults)
        }

        if defaults.string(forKey: defaultPromptIDKey) == nil, let legacyPreset {
            setDefaultPrompt(id: SummaryPromptTemplate.promptID(forLegacyPreset: legacyPreset), defaults: defaults)
        }

        defaults.removeObject(forKey: SummaryPromptPreset.storageKey)
        defaults.removeObject(forKey: SummaryPromptPreset.customTextStorageKey)
    }
}

// MARK: - Summary Prompt Template

/// Which prompt one summary was, or should be, generated with. Stored on the
/// summary (inside its metadata) and on a queued summary job. It names the
/// prompt rather than copying its text, so regenerating always uses the
/// prompt's current wording; a deleted prompt regenerates with Default.
struct SummaryPromptTemplate: Codable, Equatable, Sendable {
    let id: String
    /// The prompt's name when the summary was made, shown if it is later deleted.
    let name: String
    /// The recording type the prompt declared, for the Content Type label.
    let declaredContentType: ContentType?

    init(id: String, name: String, declaredContentType: ContentType? = nil) {
        self.id = id
        self.name = name
        self.declaredContentType = declaredContentType
    }

    init(prompt: SummaryPrompt) {
        self.init(id: prompt.id, name: prompt.name, declaredContentType: prompt.declaredContentType)
    }

    static let standard = SummaryPromptTemplate(prompt: .standard)

    var isStandard: Bool { id == SummaryPrompt.defaultID }

    /// What a summary records about how it was made. Default is recorded as
    /// nil, so summaries made without the beta keep their metadata unchanged.
    var recordedValue: SummaryPromptTemplate? {
        isStandard ? nil : self
    }

    var displayName: String { name }

    static func promptID(forLegacyPreset preset: SummaryPromptPreset) -> String {
        switch preset {
        case .standard: return SummaryPrompt.defaultID
        case .businessMeeting: return SummaryPrompt.businessMeetingID
        case .personalNotes: return SummaryPrompt.personalNotesID
        case .custom: return SummaryPrompt.legacyCustomID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, declaredContentType
        // Earlier builds stored the preset and its custom text.
        case preset, customText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = id
            self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
            self.declaredContentType = try container.decodeIfPresent(ContentType.self, forKey: .declaredContentType)
            return
        }
        let preset = try container.decode(SummaryPromptPreset.self, forKey: .preset)
        self.id = Self.promptID(forLegacyPreset: preset)
        self.name = preset.displayName
        switch preset {
        case .businessMeeting: self.declaredContentType = .meeting
        case .personalNotes: self.declaredContentType = .personalJournal
        case .standard, .custom: self.declaredContentType = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(declaredContentType, forKey: .declaredContentType)
    }
}

// MARK: - Summary Prompt Composer

/// The single source of summary-specific prompt text for every engine.
///
/// Every summary prompt site reads its detail instructions, schema description,
/// and narrative-style modifiers from here instead of from `SummaryDetailLevel`
/// or `ComedyMode` directly. For Default the output is byte-identical to
/// what those types produce on their own, so the default prompt never changes.
struct SummaryPromptComposer: Sendable {
    let prompt: SummaryPrompt
    let detailLevel: SummaryDetailLevel
    let configuredComedyMode: ComedyMode

    init(prompt: SummaryPrompt, detailLevel: SummaryDetailLevel, comedyMode: ComedyMode) {
        self.prompt = prompt.normalized()
        self.detailLevel = detailLevel
        self.configuredComedyMode = comedyMode
    }

    /// Builds a composer from a kind: built-ins use their original wording;
    /// custom uses `customText` and `recordingType`.
    init(
        preset: SummaryPromptPreset,
        customText: String = SummaryPromptPreset.defaultCustomText,
        recordingType: SummaryRecordingType = .auto,
        detailLevel: SummaryDetailLevel,
        comedyMode: ComedyMode
    ) {
        let prompt: SummaryPrompt
        switch preset {
        case .standard: prompt = .standard
        case .businessMeeting: prompt = .originalBusinessMeeting
        case .personalNotes: prompt = .originalPersonalNotes
        case .custom:
            var custom = SummaryPrompt.newCustom(number: 1, id: "composer-custom")
            custom.text = customText
            custom.recordingType = recordingType
            prompt = custom
        }
        self.init(prompt: prompt, detailLevel: detailLevel, comedyMode: comedyMode)
    }

    /// The prompt chosen for one request (regenerating a summary with its own
    /// prompt, or one the user picked). Set it around the whole summary
    /// generation with `SummaryPromptComposer.$requestTemplate.withValue`;
    /// every prompt built inside that scope uses it. Engines need no changes.
    @TaskLocal static var requestTemplate: SummaryPromptTemplate?

    /// The prompt in effect: Default unless Beta Features and the Summary
    /// Prompt beta are both on; otherwise the request's prompt in its current
    /// wording (Default if it was deleted), or the default for new summaries.
    static func effectivePrompt(defaults: UserDefaults = .standard) -> SummaryPrompt {
        guard BetaFeatures.isEnabled(.customSummaryPrompt, defaults: defaults) else {
            return .standard
        }
        if let requestTemplate {
            return SummaryPromptLibrary.prompt(id: requestTemplate.id, defaults: defaults) ?? .standard
        }
        return SummaryPromptLibrary.defaultPrompt(defaults: defaults)
    }

    /// The composer resolved once when a summary generation starts. Set by
    /// `withRequestSnapshot`, so a long or queued generation keeps one prompt,
    /// detail level and comedy mode for every chunk even if settings change
    /// mid-run, and the summary records the prompt that actually produced it.
    @TaskLocal static var requestSnapshot: SummaryPromptComposer?

    /// The request's snapshot when one is installed; otherwise resolves the
    /// settings at request time.
    static var current: SummaryPromptComposer {
        requestSnapshot ?? resolveSettings()
    }

    private static func resolveSettings() -> SummaryPromptComposer {
        SummaryPromptComposer(prompt: effectivePrompt(), detailLevel: .current, comedyMode: .current)
    }

    /// The template to record on a new summary job when the caller chose none:
    /// the default for new summaries as of now, so a queued job keeps it even
    /// if the default changes or the app relaunches before the job runs. Nil
    /// while the beta is off, which keeps today's behavior.
    static func templateForNewSummary(defaults: UserDefaults = .standard) -> SummaryPromptTemplate? {
        guard BetaFeatures.isEnabled(.customSummaryPrompt, defaults: defaults) else {
            return nil
        }
        return SummaryPromptTemplate(prompt: SummaryPromptLibrary.defaultPrompt(defaults: defaults))
    }

    /// Resolves the composer once for `template` (nil keeps an enclosing
    /// request's snapshot or template, else the default for new summaries)
    /// and runs `operation` with it installed as `requestSnapshot`.
    ///
    /// `nonisolated(nonsending)`: the operation runs on the caller's actor
    /// (SummaryManager is `@MainActor`), so the closure is never sent across
    /// isolation, and the task-local scopes use the matching `withValue`.
    nonisolated(nonsending) static func withRequestSnapshot<R>(
        template: SummaryPromptTemplate?,
        operation: nonisolated(nonsending) () async throws -> R
    ) async rethrows -> R {
        let snapshot: SummaryPromptComposer
        if let template {
            snapshot = $requestTemplate.withValue(template) { resolveSettings() }
        } else {
            snapshot = current
        }
        return try await $requestTemplate.withValue(template ?? requestTemplate) {
            try await $requestSnapshot.withValue(snapshot) {
                try await operation()
            }
        }
    }

    var preset: SummaryPromptPreset { prompt.kind }
    var customText: String { prompt.text }

    /// The prompt this composer represents, for recording on a summary.
    var template: SummaryPromptTemplate { SummaryPromptTemplate(prompt: prompt) }

    /// The recording type the prompt declares; nil keeps the automatic guess.
    var declaredContentType: ContentType? { prompt.declaredContentType }

    /// Whether the summary prompt should include the focus block for the
    /// automatically classified content type. A recording type the user chose
    /// is honored instead of the guess, so the two never conflict.
    var usesAutomaticContentFocus: Bool { declaredContentType == nil }

    /// A custom prompt replaces Comedy Mode; the built-ins keep it.
    var effectiveComedyMode: ComedyMode {
        preset == .custom ? .off : configuredComedyMode
    }

    /// Length and focus guidance for the narrative summary. Built-ins add their
    /// framing ahead of the detail-level text; a custom prompt replaces it.
    func detailInstructions(forSourceWordCount sourceWordCount: Int? = nil) -> String {
        let detail = detailLevel.promptInstructions(forSourceWordCount: sourceWordCount)
        switch preset {
        case .standard:
            return detail
        case .personalNotes, .businessMeeting:
            return recordingTypeBlock(name: prompt.name, description: prompt.text) + "\n\n" + detail
        case .custom:
            guard let typeName = prompt.recordingType == .auto ? nil : prompt.recordingType.displayName else {
                return customInstructions
            }
            return recordingTypeBlock(name: typeName, description: nil) + "\n\n" + customInstructions
        }
    }

    /// Whether the prompt's own instructions set the narrative summary's
    /// structure, format, length and focus (a custom prompt). Engines then drop
    /// their fixed summary guidance rather than contradict the user.
    var ownsSummaryFormat: Bool { preset == .custom }

    /// How engine prompts refer to the user's text when it owns the summary.
    static let customInstructions = "the user's summary instructions"

    /// The line engines put in place of fixed formatting rules for a custom
    /// prompt. Callers add their own list marker or closing punctuation.
    static let customFormatInstruction = "Follow \(customInstructions) for the summary's structure and formatting"

    /// Formatting or section guidance an engine adds for the narrative
    /// summary. When the prompt owns the summary's format the guidance is
    /// dropped (or replaced by `customReplacement`) instead of contradicting
    /// the user's instructions.
    func summaryFormatting(_ guidance: String, customReplacement: String = "") -> String {
        ownsSummaryFormat ? customReplacement : guidance
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

    /// Settings summary for logs. Never includes a prompt's name or text.
    var logDescription: String {
        switch preset {
        case .custom:
            return "prompt=custom(\(customText.count) chars, type=\(prompt.recordingType.rawValue))"
        case .businessMeeting, .personalNotes:
            return "prompt=\(preset.rawValue)\(prompt.isEdited ? "(edited)" : "")"
        case .standard:
            return "prompt=\(preset.rawValue)"
        }
    }

    // MARK: - Prompt Blocks

    private static let recordingTypeRules = """
    - The user chose this recording type. Treat the recording as this type even if the content suggests otherwise.
    - Apply this only to the narrative `summary` field or Summary section.
    - Extract tasks, reminders, titles, and content type only from the transcript and keep them concise.
    """

    /// The user's editable description sits between a fixed header and fixed
    /// rules, so rewording a built-in can never drop the recording type or
    /// the scope that keeps tasks, reminders, and titles unchanged.
    private func recordingTypeBlock(name: String, description: String?) -> String {
        var lines = ["**Recording Type: \(name) (selected by the user)**"]
        if let description, !description.isEmpty {
            lines.append(description)
        }
        lines.append(Self.recordingTypeRules)
        return lines.joined(separator: "\n")
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
