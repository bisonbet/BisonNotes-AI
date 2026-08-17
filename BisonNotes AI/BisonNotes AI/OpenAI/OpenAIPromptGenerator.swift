//
//  ChatCompletionPromptGenerator.swift
//  Audio Journal
//
//  Chat-completion prompt generation with standardized title logic
//

import Foundation

// MARK: - Comedy Mode

enum ComedyMode: String {
    case off = "off"
    case snarky = "snarky"
    case funny = "funny"

    struct SettingsKeys {
        static let enabled = "comedyModeEnabled"
        static let style = "comedyModeStyle"
    }

    /// Returns the current comedy mode based on UserDefaults
    static var current: ComedyMode {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.enabled) else {
            return .off
        }
        let style = UserDefaults.standard.string(forKey: SettingsKeys.style) ?? "snarky"
        return ComedyMode(rawValue: style) ?? .snarky
    }

    /// Returns prompt modifier text to append to narrative summary prompts, or nil if comedy mode is off.
    var promptModifier: String? {
        switch self {
        case .off:
            return nil
        case .snarky:
            return """

            **Snarky Comedy Mode — REQUIRED summary voice only:**
            - Comedy is required in the summary. Do not return a neutral, clinical, or purely professional summary.
            - Use a clearly recognizable dry/snarky voice with at least one light witty aside
              or wry observation in every summary; use several in longer summaries.
            - Put the humor in the prose, not only in a heading or formatting.
              Ground it in details already present in the transcript.
            - Keep every fact, name, number, date, quote, medical detail, and decision accurate and complete.
            - Jokes must not become new claims.
              Never invent, speculate, sexualize, or exaggerate a person, diagnosis, event, motive, task, or reminder.
            - For sensitive material, aim humor at relatable situations or the process—not at a person,
              health concern, trauma, grief, disability, or abuse.
            - Keep it PG and family-friendly with no profanity, crude humor, or sexual jokes.
            """
        case .funny:
            return """

            **Funny Comedy Mode — REQUIRED summary voice only:**
            - Comedy is required in the summary. Do not return a neutral, clinical, or purely professional summary.
            - Use a clearly recognizable lively, goofy voice with at least one playful metaphor
              or light absurd comparison in every summary; use several in longer summaries.
            - Put the humor in the prose, not only in a heading or formatting.
              Ground it in details already present in the transcript.
            - Keep every fact, name, number, date, quote, medical detail, and decision accurate and complete.
            - Playful language must not become new claims.
              Never invent, speculate, sexualize, or exaggerate a person, diagnosis, event, motive, task, or reminder.
            - For sensitive material, aim humor at relatable situations or the process—not at a person,
              health concern, trauma, grief, disability, or abuse.
            - Keep it PG and family-friendly with no profanity, crude humor, or sexual jokes.
            """
        }
    }

    /// Returns a comedy modifier for responses that contain structured metadata.
    /// Humor is explicitly limited to the narrative summary so it cannot corrupt
    /// tasks, reminders, titles, or the required response format.
    var structuredPromptModifier: String? {
        let style: String
        switch self {
        case .off:
            return nil
        case .snarky:
            style = "dry, lightly snarky wit"
        case .funny:
            style = "playful, goofy humor"
        }

        return """

        **COMEDY REQUIRED — \(style), summary field only:**
        - Make the `summary` recognizably comedic; do not return a neutral summary.
        - Include at least one clearly witty aside, wry observation, playful metaphor, or light
          absurd comparison in every `summary`; use several in longer summaries.
        - Put the comedy in the summary prose, not only in a heading or formatting.
        - This overrides the generic professional-language instruction for the summary narrative only.
        - Treat `tasks`, `reminders`, `titles`, and `contentType` as factual metadata.
          Keep them literal, concise, professional, and grounded only in the transcript.
        - Never invent or embellish a task or reminder. If the transcript does not explicitly
          contain one, return an empty array or leave the section empty.
        - Titles must describe the actual discussion in Title Case, use 4-6 words when possible,
          and contain no Markdown or ending punctuation.
        - For sensitive material, aim humor at relatable situations or the process—not at a person,
          health concern, trauma, grief, disability, or abuse.
        - Do not let comedy change names, numbers, dates, medical details, quoted language,
          decisions, urgency, or task/reminder meaning.
        - Preserve the exact requested output format, section/field names, and field types.
          Do not add commentary outside the requested response.
        """
    }
}

// MARK: - Chat Completion Prompt Generator

class ChatCompletionPromptGenerator {

    // MARK: - Prompt Types

    enum PromptType {
        case summary
        case tasks
        case reminders
        case titles
        case complete
    }

    // MARK: - System Prompt Generation

    static func createSystemPrompt(for type: PromptType, contentType: ContentType) -> String {
        let basePrompt = """
        You are an AI assistant specialized in analyzing and summarizing audio transcripts and conversations. Your role is to provide clear, actionable insights from the content provided.

        **Key Guidelines:**
        - Focus on extracting meaningful, actionable information
        - Maintain accuracy and relevance to the source material
        - Use clear language and follow any later mode-specific narrative style; keep facts and metadata professional
        - Structure responses logically and coherently
        - Prioritize the most important information first
        """

        let contentTypePrompt = createContentTypeSpecificPrompt(contentType)

        switch type {
        case .summary:
            let comedyModifier = ComedyMode.current.promptModifier ?? ""
            return basePrompt + "\n\n" + contentTypePrompt + "\n\n" + createSummaryPrompt() + comedyModifier
        case .tasks:
            return basePrompt + "\n\n" + createTasksPrompt()
        case .reminders:
            return basePrompt + "\n\n" + createRemindersPrompt()
        case .titles:
            return basePrompt + "\n\n" + createTitlesPrompt()
        case .complete:
            let comedyModifier = ComedyMode.current.structuredPromptModifier ?? ""
            return basePrompt + "\n\n" + contentTypePrompt + "\n\n" + createCompletePrompt() + comedyModifier
        }
    }

    // MARK: - Content Type Specific Prompts

    private static func createContentTypeSpecificPrompt(_ contentType: ContentType) -> String {
        switch contentType {
        case .meeting:
            return """
            **Meeting Analysis Focus:**
            - Identify key decisions and action items
            - Note important deadlines and commitments
            - Highlight participant responsibilities
            - Capture meeting outcomes and next steps
            - Focus on business-relevant information
            """
        case .personalJournal:
            return """
            **Personal Journal Analysis Focus:**
            - Identify personal insights and reflections
            - Note emotional states and personal growth
            - Highlight personal goals and aspirations
            - Capture meaningful life events and experiences
            - Focus on personal development and self-awareness
            """
        case .technical:
            return """
            **Technical Analysis Focus:**
            - Identify technical problems and solutions
            - Note implementation details and requirements
            - Highlight technical decisions and trade-offs
            - Capture technical specifications and constraints
            - Focus on technical accuracy and precision
            """
        case .general:
            return """
            **General Analysis Focus:**
            - Identify main topics and themes
            - Note important information and insights
            - Highlight key points and takeaways
            - Capture relevant details and context
            - Focus on clarity and comprehensiveness
            """
        }
    }

    // MARK: - Specific Prompt Generators

    private static func createSummaryPrompt() -> String {
        return """
        **Summary Generation Guidelines:**
        - Create a summary using Markdown formatting at the selected detail level.
        \(SummaryDetailLevel.current.promptInstructions())
        - Use **bold** for key points and important information
        - Use *italic* for emphasis and highlights
        - Use ## headers for main sections
        - Use ### subheaders for subsections
        - Use • bullet points for lists and key takeaways
        - Use 1. numbered lists for sequential items
        - Use > blockquotes for important quotes or statements
        - Keep the summary well-structured and informative
        """
    }

    private static func createTasksPrompt() -> String {
        return """
        **Task Extraction Guidelines:**
        - Extract ONLY personal, actionable tasks mentioned by or relevant to the speaker
        - Focus on items that require the speaker's direct follow-up or action
        - Include specific deadlines or time references when mentioned
        - Categorize tasks appropriately (call, meeting, purchase, research, email, travel, health, general)
        - Assign priority levels (high, medium, low) based on urgency and importance
        - Only include tasks with clear, specific action items
        - AVOID extracting tasks related to:
          • National or international news events
          • Public figures, celebrities, or politicians
          • General world events or politics
          • Events that don't directly affect the speaker
        - If NO personal action items are mentioned, return an empty array
        """
    }

    private static func createRemindersPrompt() -> String {
        return """
        **Reminder Extraction Guidelines:**
        - Extract ONLY personal, time-sensitive items relevant to the speaker
        - Focus on personal appointments, deadlines, or time-sensitive commitments
        - Include specific dates, times, or time references when mentioned
        - Categorize urgency appropriately (immediate, today, thisWeek, later)
        - Only include items that require timely attention from the speaker
        - AVOID extracting reminders related to:
          • National or international news events or dates
          • Public events, elections, or general world happenings
          • Events that don't directly affect the speaker personally
        - If NO personal time-sensitive items are mentioned, return an empty array
        """
    }

    private static func createTitlesPrompt() -> String {
        return """
        **Title Generation Guidelines:**
        - Generate concise, descriptive titles (40-60 characters, 4-6 words)
        - Capture the main topic, purpose, or key subject
        - Be specific and meaningful - avoid generic terms
        - Focus on the most important subject, person, or action mentioned
        - Use proper capitalization (Title Case)
        - Never end with punctuation marks
        - Make titles work well as file names or conversation titles
        - Be logical and sensical - make it clear what the content is about

        **Examples of good titles:**
        - "Trump Scotland Visit"
        - "Hong Kong Arrest Warrants"
        - "Texas Redistricting Debate"
        - "Project Budget Review"
        - "Client Presentation Prep"
        - "Team Strategy Meeting"
        - "Quarterly Sales Report"
        - "Product Launch Planning"
        """
    }

    private static func createCompletePrompt() -> String {
        return """
        **Complete Analysis Guidelines:**
        - Provide a complete analysis in a single response.
        \(SummaryDetailLevel.current.promptInstructions())
        - Include summary, tasks, reminders, and titles
        - Use the standardized title generation logic
        - Ensure all components are properly formatted
        - Focus on actionable insights and meaningful information
        - Maintain consistency across all extracted elements
        """
    }

    // MARK: - User Prompt Generation

    static func createUserPrompt(for type: PromptType, text: String) -> String {
        switch type {
        case .summary:
            return createSummaryUserPrompt(text)
        case .tasks:
            return createTasksUserPrompt(text)
        case .reminders:
            return createRemindersUserPrompt(text)
        case .titles:
            return createTitlesUserPrompt(text)
        case .complete:
            return createCompleteUserPrompt(text)
        }
    }

    private static func createSummaryUserPrompt(_ text: String) -> String {
        let detailInstructions = SummaryDetailLevel.current.promptInstructions(
            forSourceWordCount: wordCount(of: text)
        )

        return """
        Please provide a summary of the following content using proper Markdown formatting.

        \(detailInstructions)

        \(text)
        """
    }

    private static func createTasksUserPrompt(_ text: String) -> String {
        return """
        Extract personal, actionable tasks from the following content. Focus only on tasks that are personal to the speaker or require their direct action. Avoid tasks related to national news, public figures, or general world events.

        Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "task description",
                "priority": "high|medium|low",
                "category": "call|meeting|purchase|research|email|travel|health|general",
                "timeReference": "today|tomorrow|this week|next week|specific date or null",
                "confidence": 0.85
            }
        ]

        IMPORTANT: If no personal action items are found, return an empty array: []

        Content:
        \(text)
        """
    }

    private static func createRemindersUserPrompt(_ text: String) -> String {
        return """
        Extract personal, time-sensitive reminders from the following content. Focus only on personal appointments, deadlines, or commitments that directly affect the speaker. Avoid reminders about national news, public events, or general world happenings.

        Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "reminder description",
                "urgency": "immediate|today|thisWeek|later",
                "timeReference": "specific time or date mentioned",
                "confidence": 0.85
            }
        ]

        IMPORTANT: If no personal time-sensitive items are found, return an empty array: []

        Content:
        \(text)
        """
    }

    private static func createTitlesUserPrompt(_ text: String) -> String {
        return """
        Analyze the following transcript and extract 4 high-quality titles or headlines. Focus on:
        - Main topics or themes discussed
        - Key decisions or outcomes
        - Important events or milestones
        - Central questions or problems addressed

        **Return the results in this exact JSON format (no markdown, just pure JSON):**
        {
          "titles": [
            {
              "text": "title text",
              "category": "Meeting|Personal|Technical|General",
              "confidence": 0.85
            }
          ]
        }

        Requirements:
        - Generate exactly 4 titles with 85% or higher confidence
        - Each title should be 40-60 characters and 4-6 words
        - Focus on the most important and specific topics
        - Avoid generic or vague titles
        - If no suitable titles are found, return empty array

        Transcript:
        \(text)
        """
    }

    private static func createCompleteUserPrompt(_ text: String) -> String {
        let detailInstructions = SummaryDetailLevel.current.promptInstructions(
            forSourceWordCount: wordCount(of: text)
        )

        return """
        Please analyze the following content and provide a comprehensive response in VALID JSON format only. Do not include any text before or after the JSON. The response must be a single, well-formed JSON object with this exact structure:

        {
            "summary": "\(SummaryDetailLevel.current.schemaDescription) Use Markdown formatting with **bold**, *italic*, ## headers, • bullet points, and > blockquotes.",
            "tasks": [
                {
                    "text": "task description",
                    "priority": "high|medium|low",
                    "category": "call|meeting|purchase|research|email|travel|health|general",
                    "timeReference": "today|tomorrow|this week|next week|specific date or null",
                    "confidence": 0.85
                }
            ],
            "reminders": [
                {
                    "text": "reminder description",
                    "urgency": "immediate|today|thisWeek|later",
                    "timeReference": "specific time or date mentioned",
                    "confidence": 0.85
                }
            ],
            "titles": [
                {
                    "text": "title text (40-60 characters, 4-6 words)",
                    "category": "meeting|personal|technical|general",
                    "confidence": 0.85
                }
            ]
        }

        IMPORTANT:
        - Return ONLY valid JSON, no additional text or explanations
        - The "summary" field must use Markdown formatting: **bold**, *italic*, ## headers, • bullets, etc.
        - Tasks must be PERSONAL and ACTIONABLE to the speaker — do NOT include tasks about news, public figures, or world events
        - Reminders must be PERSONAL and TIME-SENSITIVE to the speaker — do NOT include reminders about news events or public happenings
        - If no personal tasks are found, use an empty array: "tasks": []
        - If no personal reminders are found, use an empty array: "reminders": []
        - Generate exactly 4 high-quality titles using Title Case, never ending with punctuation
        - Return valid JSON with quoted/escaped strings, valid `\\n` paragraph breaks, and no trailing commas
        - Never put a backslash before an ordinary letter
        - This is machine-parsed output: do not return a Markdown fence, explanation, or partially formed JSON.

        \(detailInstructions)

        Content to analyze:
        \(text)
        """
    }

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
