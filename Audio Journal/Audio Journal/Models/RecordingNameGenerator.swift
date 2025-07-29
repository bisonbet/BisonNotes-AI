import Foundation

// MARK: - Recording Name Generator

class RecordingNameGenerator {
    
    // MARK: - Public Methods
    
    static func generateRecordingNameFromTranscript(_ transcript: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem]) -> String {
        // Try different strategies to generate a good name from the full transcript
        let maxLength = 35
        
        // Strategy 0: Use AI-generated title if available (for Ollama and other AI engines)
        if let aiGeneratedTitle = UserDefaults.standard.string(forKey: "lastGeneratedTitle"),
           !aiGeneratedTitle.isEmpty,
           aiGeneratedTitle != "Untitled Conversation" {
            // Clean up the title and ensure it's within length limits
            let cleanedTitle = aiGeneratedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedTitle.count <= maxLength {
                // Clear the stored title after using it
                UserDefaults.standard.removeObject(forKey: "lastGeneratedTitle")
                return cleanedTitle
            } else {
                // Truncate if too long
                let truncatedTitle = String(cleanedTitle.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
                UserDefaults.standard.removeObject(forKey: "lastGeneratedTitle")
                return truncatedTitle
            }
        }
        
        // Strategy 1: Use the first task if it's high priority
        if let highPriorityTask = tasks.first(where: { $0.priority == .high }) {
            let taskName = generateNameFromTask(highPriorityTask, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 2: Use the first urgent reminder
        if let urgentReminder = reminders.first(where: { $0.urgency == .immediate || $0.urgency == .today }) {
            let reminderName = generateNameFromReminder(urgentReminder, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 3: Extract key phrases from the full transcript
        let transcriptName = generateNameFromTranscript(transcript, contentType: contentType, maxLength: maxLength)
        if !transcriptName.isEmpty {
            return transcriptName
        }
        
        // Strategy 4: Use content type with date
        return generateFallbackName(contentType: contentType, maxLength: maxLength)
    }
    
    static func generateRecordingName(from summary: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem]) -> String {
        // Try different strategies to generate a good name
        let maxLength = 35
        
        // Strategy 1: Use the first task if it's high priority
        if let highPriorityTask = tasks.first(where: { $0.priority == .high }) {
            let taskName = generateNameFromTask(highPriorityTask, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 2: Use the first urgent reminder
        if let urgentReminder = reminders.first(where: { $0.urgency == .immediate || $0.urgency == .today }) {
            let reminderName = generateNameFromReminder(urgentReminder, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 3: Extract key phrases from summary
        let summaryName = generateNameFromSummary(summary, contentType: contentType, maxLength: maxLength)
        if !summaryName.isEmpty {
            return summaryName
        }
        
        // Strategy 4: Use content type with date
        return generateFallbackName(contentType: contentType, maxLength: maxLength)
    }
    
    static func validateAndFixRecordingName(_ name: String, originalName: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // List of generic or problematic names to avoid
        let genericNames = ["the", "a", "an", "this", "that", "it", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by"]
        
        // Check if name is too short or generic
        if trimmedName.count < 3 || genericNames.contains(trimmedName.lowercased()) {
            print("⚠️ Generated name '\(trimmedName)' is too generic, using fallback")
            
            // Try to extract a better name from the original filename
            let cleanedOriginal = originalName
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty && !$0.contains("2025") && !$0.contains("2024") }
                .prefix(3)
                .joined(separator: " ")
            
            if !cleanedOriginal.isEmpty && cleanedOriginal.count > 3 {
                return cleanedOriginal
            }
            
            // Final fallback: use content type with timestamp
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            return "Recording \(formatter.string(from: Date()))"
        }
        
        // Check for common file extensions and remove them
        let extensionsToRemove = [".mp3", ".m4a", ".wav", ".aac"]
        var cleanedName = trimmedName
        for ext in extensionsToRemove {
            if cleanedName.lowercased().hasSuffix(ext) {
                cleanedName = String(cleanedName.dropLast(ext.count))
            }
        }
        
        return cleanedName.isEmpty ? originalName : cleanedName
    }
    
    // MARK: - Private Helper Methods
    
    private static func generateNameFromTask(_ task: TaskItem, maxLength: Int) -> String {
        let taskText = task.text.lowercased()
        
        // Extract action and object
        let actionKeywords = ["call", "email", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come", "take", "bring", "send", "schedule", "book", "order", "pick up", "drop off", "return", "check", "review", "update"]
        
        for action in actionKeywords {
            if taskText.contains(action) {
                // Find the object after the action
                if let actionRange = taskText.range(of: action) {
                    let afterAction = String(taskText[actionRange.upperBound...])
                    let words = afterAction.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    
                    if let firstWord = words.first {
                        let name = "\(action.capitalized) \(firstWord.capitalized)"
                        return name.count <= maxLength ? name : String(name.prefix(maxLength))
                    } else {
                        let name = action.capitalized
                        return name.count <= maxLength ? name : String(name.prefix(maxLength))
                    }
                }
            }
        }
        
        // If no action found, use first few words
        let words = taskText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if let firstWord = words.first, let secondWord = words.dropFirst().first {
            let name = "\(firstWord.capitalized) \(secondWord.capitalized)"
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        } else if let firstWord = words.first {
            let name = firstWord.capitalized
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        }
        
        return ""
    }
    
    private static func generateNameFromReminder(_ reminder: ReminderItem, maxLength: Int) -> String {
        let reminderText = reminder.text.lowercased()
        
        // Look for appointment, meeting, deadline keywords
        let eventKeywords = ["appointment", "meeting", "deadline", "call", "email", "visit", "check"]
        
        for event in eventKeywords {
            if reminderText.contains(event) {
                let name = event.capitalized
                return name.count <= maxLength ? name : String(name.prefix(maxLength))
            }
        }
        
        // Use first few words
        let words = reminderText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if let firstWord = words.first, let secondWord = words.dropFirst().first {
            let name = "\(firstWord.capitalized) \(secondWord.capitalized)"
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        } else if let firstWord = words.first {
            let name = firstWord.capitalized
            return name.count <= maxLength ? name : String(name.prefix(maxLength))
        }
        
        return ""
    }
    
    private static func generateNameFromTranscript(_ transcript: String, contentType: ContentType, maxLength: Int) -> String {
        // Use advanced NLP to extract meaningful titles from the full transcript
        let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !sentences.isEmpty else { return "" }
        
        // Strategy 1: Look for meeting/event titles in the first few sentences
        let titleKeywords = ["meeting about", "discussion on", "call about", "talk about", "conversation about", "presentation on", "review of", "planning for", "discussion of"]
        
        for sentence in sentences.prefix(3) {
            let lowerSentence = sentence.lowercased()
            for keyword in titleKeywords {
                if let range = lowerSentence.range(of: keyword) {
                    let afterKeyword = String(sentence[range.upperBound...])
                    let words = afterKeyword.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if let firstWord = words.first, let secondWord = words.dropFirst().first {
                        let title = "\(firstWord.capitalized) \(secondWord.capitalized)"
                        if title.count <= maxLength {
                            return title
                        }
                    }
                }
            }
        }
        
        // Strategy 2: Extract key phrases using NLP techniques
        let keyPhrases = extractKeyPhrasesFromTranscript(transcript, maxPhrases: 3)
        if let bestPhrase = keyPhrases.first {
            let words = bestPhrase.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let keyWords = words.prefix(3).map { $0.capitalized }
            let title = keyWords.joined(separator: " ")
            if title.count <= maxLength {
                return title
            } else {
                let shortTitle = keyWords.prefix(2).joined(separator: " ")
                return shortTitle.count <= maxLength ? shortTitle : String(shortTitle.prefix(maxLength))
            }
        }
        
        // Strategy 3: Use the most important sentence from the transcript
        let scoredSentences = sentences.map { sentence in
            (sentence: sentence, score: calculateSentenceImportance(sentence, in: transcript))
        }
        
        if let bestSentence = scoredSentences.max(by: { $0.score < $1.score }) {
            let words = bestSentence.sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let keyWords = words.prefix(3).map { $0.capitalized }
            let title = keyWords.joined(separator: " ")
            if title.count <= maxLength {
                return title
            } else {
                let shortTitle = keyWords.prefix(2).joined(separator: " ")
                return shortTitle.count <= maxLength ? shortTitle : String(shortTitle.prefix(maxLength))
            }
        }
        
        return ""
    }
    
    private static func generateNameFromSummary(_ summary: String, contentType: ContentType, maxLength: Int) -> String {
        let sentences = summary.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        guard let firstSentence = sentences.first else { return "" }
        
        let words = firstSentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // Try to find key nouns and verbs
        let keyWords = words.prefix(4).map { $0.capitalized }
        let name = keyWords.joined(separator: " ")
        
        if name.count <= maxLength {
            return name
        } else {
            // Try with fewer words
            let shortName = keyWords.prefix(2).joined(separator: " ")
            return shortName.count <= maxLength ? shortName : String(shortName.prefix(maxLength))
        }
    }
    
    private static func generateFallbackName(contentType: ContentType, maxLength: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let dateString = formatter.string(from: Date())
        
        let typeString: String
        switch contentType {
        case .meeting: typeString = "Meeting"
        case .personalJournal: typeString = "Journal"
        case .technical: typeString = "Tech"
        case .general: typeString = "Note"
        }
        
        let name = "\(typeString) \(dateString)"
        return name.count <= maxLength ? name : String(name.prefix(maxLength))
    }
    
    // MARK: - Helper Functions for Title Generation
    
    private static func extractKeyPhrasesFromTranscript(_ transcript: String, maxPhrases: Int) -> [String] {
        // Use ContentAnalyzer to extract key phrases
        return ContentAnalyzer.extractKeyPhrases(from: transcript, maxPhrases: maxPhrases)
    }
    
    private static func calculateSentenceImportance(_ sentence: String, in transcript: String) -> Double {
        // Use ContentAnalyzer to calculate sentence importance
        return ContentAnalyzer.calculateSentenceImportance(sentence, in: transcript)
    }
}