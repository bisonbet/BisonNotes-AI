//
//  OpenAIPromptGenerator.swift
//  Audio Journal
//
//  OpenAI prompt generation with standardized title logic
//

import Foundation

// MARK: - OpenAI Prompt Generator

class OpenAIPromptGenerator {
    
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
        - Use clear, professional language
        - Structure responses logically and coherently
        - Prioritize the most important information first
        """
        
        let contentTypePrompt = createContentTypeSpecificPrompt(contentType)
        
        switch type {
        case .summary:
            return basePrompt + "\n\n" + contentTypePrompt + "\n\n" + createSummaryPrompt()
        case .tasks:
            return basePrompt + "\n\n" + createTasksPrompt()
        case .reminders:
            return basePrompt + "\n\n" + createRemindersPrompt()
        case .titles:
            return basePrompt + "\n\n" + createTitlesPrompt()
        case .complete:
            return basePrompt + "\n\n" + contentTypePrompt + "\n\n" + createCompletePrompt()
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
        - Create a comprehensive summary using Markdown formatting
        - Use **bold** for key points and important information
        - Use *italic* for emphasis and highlights
        - Use ## headers for main sections
        - Use ### subheaders for subsections
        - Use • bullet points for lists and key takeaways
        - Use > blockquotes for important statements or quotes
        - Keep the summary well-structured and informative
        - Focus on the most important content and insights
        - Ensure the summary captures the essence of the conversation
        """
    }
    
    private static func createTasksPrompt() -> String {
        return """
        **Task Extraction Guidelines:**
        - Identify actionable tasks and to-dos
        - Focus on items that require follow-up or action
        - Include specific deadlines or time references when mentioned
        - Categorize tasks appropriately (call, meeting, purchase, research, email, travel, health, general)
        - Assign priority levels (high, medium, low) based on urgency and importance
        - Only include tasks with clear action items
        - Avoid general statements that don't require specific action
        """
    }
    
    private static func createRemindersPrompt() -> String {
        return """
        **Reminder Extraction Guidelines:**
        - Identify time-sensitive items and deadlines
        - Focus on appointments, meetings, and scheduled events
        - Include specific dates, times, or time references
        - Categorize urgency appropriately (immediate, today, thisWeek, later)
        - Only include items that require timely attention
        - Avoid general information that doesn't have a time component
        - Focus on items that would benefit from a reminder
        """
    }
    
    private static func createTitlesPrompt() -> String {
        return """
        **Title Generation Guidelines:**
        - Generate concise, descriptive titles (20-50 characters, 3-8 words)
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
        - Provide a comprehensive analysis in a single response
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
        return """
        Please provide a comprehensive summary of the following content using proper Markdown formatting:

        \(text)
        """
    }
    
    private static func createTasksUserPrompt(_ text: String) -> String {
        return """
        Please extract actionable tasks from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "task description",
                "priority": "high|medium|low",
                "category": "call|meeting|purchase|research|email|travel|health|general",
                "timeReference": "today|tomorrow|this week|next week|specific date or null",
                "confidence": 0.85
            }
        ]

        Content:
        \(text)
        """
    }
    
    private static func createRemindersUserPrompt(_ text: String) -> String {
        return """
        Please extract reminders and time-sensitive items from the following content. Return them as a JSON array of objects with the following structure:
        [
            {
                "text": "reminder description",
                "urgency": "immediate|today|thisWeek|later",
                "timeReference": "specific time or date mentioned",
                "confidence": 0.85
            }
        ]

        Content:
        \(text)
        """
    }
    
    private static func createTitlesUserPrompt(_ text: String) -> String {
        let standardizedPrompt = RecordingNameGenerator.generateStandardizedTitlePrompt(from: text)
        return """
        \(standardizedPrompt)
        
        Return the title in this exact JSON format:
        [
            {
                "text": "generated title",
                "category": "meeting|personal|technical|general",
                "confidence": 0.85
            }
        ]
        """
    }
    
    private static func createCompleteUserPrompt(_ text: String) -> String {
        _ = RecordingNameGenerator.generateStandardizedTitlePrompt(from: text)
        return """
        Please analyze the following content and provide a comprehensive response in VALID JSON format only. Do not include any text before or after the JSON. The response must be a single, well-formed JSON object with this exact structure:

        {
            "summary": "A detailed summary using Markdown formatting with **bold**, *italic*, ## headers, • bullet points, etc.",
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
                    "text": "Generate a concise, descriptive title (20-50 characters, 3-8 words) that captures the main topic, purpose, or key subject. Focus on the most important subject, person, or action mentioned. Use proper capitalization (Title Case) and never end with punctuation marks.",
                    "category": "meeting|personal|technical|general",
                    "confidence": 0.85
                }
            ]
        }

        IMPORTANT: 
        - Return ONLY valid JSON, no additional text or explanations
        - The "summary" field must use Markdown formatting: **bold**, *italic*, ## headers, • bullets, etc.
        - If no tasks are found, use an empty array: "tasks": []
        - If no reminders are found, use an empty array: "reminders": []
        - If no titles are found, use an empty array: "titles": []
        - Ensure all strings are properly quoted and escaped (especially for Markdown characters)
        - Do not include trailing commas
        - Escape special characters in JSON strings (quotes, backslashes, newlines)

        Content to analyze:
        \(text)
        """
    }
} 