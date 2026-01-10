import Foundation

// MARK: - Recording Name Generator

class RecordingNameGenerator {
    
    // MARK: - Public Methods
    
    static func generateRecordingNameFromTranscript(_ transcript: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem]) -> String {
        // Try different strategies to generate a good name from the full transcript
        let minLength = 20  // More flexible minimum length
        let maxLength = 80  // More flexible maximum length
        
        print("🎯 RecordingNameGenerator: Starting name generation with \(titles.count) titles")
        for (index, title) in titles.enumerated() {
            print("📝 RecordingNameGenerator: Title \(index + 1): '\(title.text)' (confidence: \(title.confidence))")
        }
        
        // Strategy 0: Use AI-generated title if available (for Ollama and other AI engines)
        if let aiGeneratedTitle = UserDefaults.standard.string(forKey: "lastGeneratedTitle"),
           !aiGeneratedTitle.isEmpty,
           aiGeneratedTitle != "Untitled Conversation" {
            // Clean up the title and ensure it's within length limits
            let cleanedTitle = cleanAndValidateTitle(aiGeneratedTitle, minLength: minLength, maxLength: maxLength)
            if !cleanedTitle.isEmpty {
                // Clear the stored title after using it
                UserDefaults.standard.removeObject(forKey: "lastGeneratedTitle")
                return cleanedTitle
            }
        }
        
        // Strategy 1: Use the first high-confidence title from the titles array
        if let bestTitle = titles.first(where: { $0.confidence >= 0.8 }) {
            print("🔍 RecordingNameGenerator: Processing high-confidence title: '\(bestTitle.text)' (confidence: \(bestTitle.confidence))")
            let titleName = generateNameFromTitle(bestTitle, minLength: minLength, maxLength: maxLength)
            if !titleName.isEmpty {
                print("✅ RecordingNameGenerator: Generated name from title: '\(titleName)'")
                return titleName
            } else {
                print("⚠️ RecordingNameGenerator: Failed to generate name from title: '\(bestTitle.text)'")
            }
        }
        
        // Strategy 2: Use any title from the titles array (even lower confidence)
        if let anyTitle = titles.first {
            print("🔍 RecordingNameGenerator: Processing any title: '\(anyTitle.text)' (confidence: \(anyTitle.confidence))")
            let titleName = generateNameFromTitle(anyTitle, minLength: minLength, maxLength: maxLength)
            if !titleName.isEmpty {
                print("✅ RecordingNameGenerator: Generated name from any title: '\(titleName)'")
                return titleName
            } else {
                print("⚠️ RecordingNameGenerator: Failed to generate name from any title: '\(anyTitle.text)'")
            }
        }
        
        // Strategy 3: Use the first task if it's high priority
        if let highPriorityTask = tasks.first(where: { $0.priority == .high }) {
            let taskName = generateNameFromTask(highPriorityTask, minLength: minLength, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 4: Use any task
        if let anyTask = tasks.first {
            let taskName = generateNameFromTask(anyTask, minLength: minLength, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 5: Use the first reminder if it's urgent
        if let urgentReminder = reminders.first(where: { $0.urgency == .immediate }) {
            let reminderName = generateNameFromReminder(urgentReminder, minLength: minLength, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 6: Use any reminder
        if let anyReminder = reminders.first {
            let reminderName = generateNameFromReminder(anyReminder, minLength: minLength, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 7: Generate from transcript content
        return generateNameFromTranscript(transcript, contentType: contentType, minLength: minLength, maxLength: maxLength)
    }
    
    static func generateRecordingName(from summary: String, contentType: ContentType, tasks: [TaskItem], reminders: [ReminderItem]) -> String {
        // Try different strategies to generate a good name
        let minLength = 20  // More flexible minimum length
        let maxLength = 80  // More flexible maximum length
        
        // Strategy 1: Use the first task if it's high priority
        if let highPriorityTask = tasks.first(where: { $0.priority == .high }) {
            let taskName = generateNameFromTask(highPriorityTask, minLength: minLength, maxLength: maxLength)
            if !taskName.isEmpty {
                return taskName
            }
        }
        
        // Strategy 2: Use the first urgent reminder
        if let urgentReminder = reminders.first(where: { $0.urgency == .immediate || $0.urgency == .today }) {
            let reminderName = generateNameFromReminder(urgentReminder, minLength: minLength, maxLength: maxLength)
            if !reminderName.isEmpty {
                return reminderName
            }
        }
        
        // Strategy 3: Extract key phrases from summary
        let summaryName = generateNameFromSummary(summary, contentType: contentType, minLength: minLength, maxLength: maxLength)
        if !summaryName.isEmpty {
            return summaryName
        }
        
        // Strategy 4: Use content type with date
        return generateFallbackName(contentType: contentType, minLength: minLength, maxLength: maxLength)
    }
    
    static func validateAndFixRecordingName(_ name: String, originalName: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // List of generic or problematic names to avoid
        let genericNames = ["the", "a", "an", "this", "that", "it", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by"]
        
        // Check if name is too short or generic (more flexible minimum)
        if trimmedName.count < 10 || genericNames.contains(trimmedName.lowercased()) {
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
    
    // MARK: - Standardized Title Generation (Matching Ollama Logic)
    
    static func generateStandardizedTitlePrompt(from text: String) -> String {
        let prompt = """
        Generate a concise, descriptive title for this conversation/transcript. The title should:
        1. Be 40-60 characters long (approximately 6-10 words)
        2. Capture the main topic, purpose, or key subject
        3. Be specific and meaningful - avoid generic terms
        4. Work well as a file name or conversation title
        5. Focus on the most important subject, person, or action mentioned
        6. Be logical and sensical - make it clear what the content is about
        7. Use proper capitalization (Title Case)
        8. Never end with punctuation marks
        9. Never end with weak words like "with", "to", "for", "of", "in", "on", "at", "by", "from", "about", "regarding", "concerning", "pertaining", "related", "involving", "including", "containing", "featuring", "about", "regarding", "concerning", "pertaining", "related", "involving", "including", "containing", "featuring"

        Examples of good titles:
        - "Trump Scotland Visit Planning"
        - "Hong Kong Arrest Warrants Issued" 
        - "Texas Redistricting Debate Continues"
        - "Walmart Stabbing Investigation Update"
        - "Harvard Funding Deal Negotiations"
        - "Project Budget Review Meeting"
        - "Client Presentation Preparation Session"
        - "Team Strategy Meeting Discussion"
        - "Quarterly Sales Report Analysis"
        - "Product Launch Planning Session"
        - "Customer Feedback Analysis Results"
        - "Technical Architecture Review Meeting"

        **IMPORTANT: Return ONLY the title, nothing else. No quotes, no explanation, no markdown formatting, no extra text, no punctuation at the end.**

        Transcript:
        \(text)
        """
        
        return prompt
    }
    
    static func cleanStandardizedTitleResponse(_ response: String) -> String {
        // Apply general AI output cleaning first
        var cleanedTitle = cleanAIOutput(response)
        
        // Remove word count patterns (including character count patterns)
        let wordCountPattern = #"\s*\(\d+[\s-]*(words?|characters?)\)\s*$"#
        cleanedTitle = cleanedTitle.replacingOccurrences(
            of: wordCountPattern,
            with: "",
            options: .regularExpression
        )
        
        // Remove markdown formatting
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "**", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "*", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "#", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "`", with: "")
        
        // Remove ALL punctuation at the end (more comprehensive)
        cleanedTitle = cleanedTitle.replacingOccurrences(of: #"[.!?;:,]+$"#, with: "", options: .regularExpression)
        
        // Trim whitespace and newlines
        cleanedTitle = cleanedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check for weak ending words and fix them
        cleanedTitle = fixWeakEndingWords(cleanedTitle)
        
        // Ensure title is within proper length (20-80 characters)
        if cleanedTitle.count < 20 {
            // Too short, try to expand or use fallback
            if cleanedTitle.count < 10 {
                cleanedTitle = "Untitled Conversation"
            }
        } else if cleanedTitle.count > 80 {
            // Too long, truncate at word boundaries while avoiding weak endings
            let words = cleanedTitle.components(separatedBy: .whitespaces)
            var truncatedTitle = ""
            
            for word in words {
                let testTitle = truncatedTitle.isEmpty ? word : "\(truncatedTitle) \(word)"
                if testTitle.count <= 80 {
                    truncatedTitle = testTitle
                } else {
                    break
                }
            }
            
            // Fix any weak ending words in the truncated title
            truncatedTitle = fixWeakEndingWords(truncatedTitle)
            
            cleanedTitle = truncatedTitle.isEmpty ? String(cleanedTitle.prefix(80)) : truncatedTitle
        }
        
        // Validate that the title makes sense
        let words = cleanedTitle.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.count < 3 || words.count > 10 {
            // If too few or too many words, it might be nonsensical
            cleanedTitle = "Untitled Conversation"
        }
        
        // Check for repeated words or nonsensical patterns
        let uniqueWords = Set(words.map { $0.lowercased() })
        if uniqueWords.count < Int(Double(words.count) * 0.6) { // If more than 40% of words are repeated
            cleanedTitle = "Untitled Conversation"
        }
        
        // Check for generic or meaningless titles
        let genericTitles = ["title", "conversation", "meeting", "discussion", "talk", "chat", "recording", "audio", "transcript"]
        let lowerTitle = cleanedTitle.lowercased()
        if genericTitles.contains(lowerTitle) || genericTitles.contains(where: { lowerTitle.contains($0) && words.count <= 2 }) {
            cleanedTitle = "Untitled Conversation"
        }
        
        // Ensure title is not empty
        if cleanedTitle.isEmpty {
            cleanedTitle = "Untitled Conversation"
        }
        
        return cleanedTitle
    }

    /// Cleans AI-generated output by removing common prefixes, <think> tags, and unwanted "Tag: " labels.
    static func cleanAIOutput(_ text: String) -> String {
        // 1. Remove <think> tags and their content
        let thinkPattern = #"<think>[\s\S]*?</think>"#
        var cleaned = text.replacingOccurrences(
            of: thinkPattern,
            with: "",
            options: .regularExpression
        )
        
        // 2. Remove markdown quotes and formatting from start/end
        cleaned = cleaned.replacingOccurrences(of: "\"", with: "")
        cleaned = cleaned.replacingOccurrences(of: "'", with: "")
        
        // 3. Remove common hardcoded prefixes
        let unwantedPrefixes = [
            "Title:", "Name:", "Generated Title:", "Conversation Title:", 
            "The title is:", "Here's the title:", "Title is:", "AI Title:", 
            "Suggested Title:", "Task:", "Reminder:", "Note:", "Action Item:",
            "TODO:", "Personal:", "Topic:", "Subject:", "Headline:"
        ]
        
        for prefix in unwantedPrefixes {
            if cleaned.lowercased().hasPrefix(prefix.lowercased()) {
                cleaned = String(cleaned.dropFirst(prefix.count))
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        // 4. Remove dynamic "Tag: " or "Tag/Subtag: " prefixes (e.g., "Personal:", "Hulu/Alien Earth:")
        // Matches 1-4 words or path-like tags at start followed by a colon and space
        let dynamicTagPattern = #"^([A-Z][a-zA-Z0-9\s/]{1,30}):\s+"#
        if let range = cleaned.range(of: dynamicTagPattern, options: .regularExpression) {
            // Only strip if the remaining part is substantive
            let remaining = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if remaining.count > 5 {
                cleaned = remaining
            }
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private Helper Methods
    
    private static func cleanAndValidateTitle(_ title: String, minLength: Int, maxLength: Int) -> String {
        var cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Remove punctuation at the end
        cleanedTitle = cleanedTitle.replacingOccurrences(of: #"[.!?;:,]+$"#, with: "", options: .regularExpression)
        
        // Remove quotes and extra formatting
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "\"", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "'", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "**", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "*", with: "")
        cleanedTitle = cleanedTitle.replacingOccurrences(of: "#", with: "")
        
        // Check for weak ending words and fix them
        cleanedTitle = fixWeakEndingWords(cleanedTitle)
        
        // Ensure proper length with more flexible constraints
        if cleanedTitle.count < minLength {
            return "" // Too short, try other strategies
        }
        
        if cleanedTitle.count > maxLength {
            // Try to truncate at word boundaries while avoiding weak endings
            let words = cleanedTitle.components(separatedBy: .whitespaces)
            var truncatedTitle = ""
            
            for word in words {
                let testTitle = truncatedTitle.isEmpty ? word : "\(truncatedTitle) \(word)"
                if testTitle.count <= maxLength {
                    truncatedTitle = testTitle
                } else {
                    break
                }
            }
            
            // Fix any weak ending words in the truncated title
            truncatedTitle = fixWeakEndingWords(truncatedTitle)
            
            cleanedTitle = truncatedTitle.isEmpty ? String(cleanedTitle.prefix(maxLength)) : truncatedTitle
        }
        
        // Validate that the title makes sense with more flexible word count
        let words = cleanedTitle.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.count < 3 || words.count > 10 {
            return "" // Too few or too many words
        }
        
        // Check for repeated words or nonsensical patterns
        let uniqueWords = Set(words.map { $0.lowercased() })
        if uniqueWords.count < Int(Double(words.count) * 0.6) { // If more than 40% of words are repeated
            return ""
        }
        
        return cleanedTitle.isEmpty ? "" : cleanedTitle
    }
    
    private static func generateNameFromTask(_ task: TaskItem, minLength: Int, maxLength: Int) -> String {
        let taskText = task.text.lowercased()
        
        // Extract action and object
        let actionKeywords = ["call", "email", "meet", "buy", "get", "do", "make", "see", "visit", "go", "come", "take", "bring", "send", "schedule", "book", "order", "pick up", "drop off", "return", "check", "review", "update", "prepare", "create", "develop", "implement", "analyze", "research", "present", "discuss", "plan", "organize"]
        
        for action in actionKeywords {
            if taskText.contains(action) {
                // Find the object after the action
                if let actionRange = taskText.range(of: action) {
                    let afterAction = String(taskText[actionRange.upperBound...])
                    let words = afterAction.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    
                    if let firstWord = words.first, let secondWord = words.dropFirst().first {
                        let name = "\(action.capitalized) \(firstWord.capitalized) \(secondWord.capitalized)"
                        if name.count >= minLength && name.count <= maxLength {
                            return name
                        }
                    } else if let firstWord = words.first {
                        let name = "\(action.capitalized) \(firstWord.capitalized)"
                        if name.count >= minLength && name.count <= maxLength {
                            return name
                        }
                    }
                }
            }
        }
        
        // If no action found, use first few meaningful words
        let words = taskText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.count >= 3 {
            let keyWords = words.prefix(3).map { $0.capitalized }
            let name = keyWords.joined(separator: " ")
            if name.count >= minLength && name.count <= maxLength {
                return name
            }
        } else if words.count >= 2 {
            let keyWords = words.prefix(2).map { $0.capitalized }
            let name = keyWords.joined(separator: " ")
            if name.count >= minLength && name.count <= maxLength {
                return name
            }
        }
        
        return ""
    }
    
    private static func generateNameFromReminder(_ reminder: ReminderItem, minLength: Int, maxLength: Int) -> String {
        let reminderText = reminder.text.lowercased()
        
        // Look for appointment, meeting, deadline keywords
        let eventKeywords = ["appointment", "meeting", "deadline", "call", "email", "visit", "check", "review", "presentation", "interview", "consultation", "follow-up", "check-in"]
        
        for event in eventKeywords {
            if reminderText.contains(event) {
                // Try to add context to make it more descriptive
                let words = reminderText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if words.count >= 2 {
                    let keyWords = words.prefix(2).map { $0.capitalized }
                    let name = "\(event.capitalized) \(keyWords.joined(separator: " "))"
                    if name.count >= minLength && name.count <= maxLength {
                        return name
                    }
                } else {
                    let name = event.capitalized
                    if name.count >= minLength && name.count <= maxLength {
                        return name
                    }
                }
            }
        }
        
        // Use first few meaningful words
        let words = reminderText.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if words.count >= 3 {
            let keyWords = words.prefix(3).map { $0.capitalized }
            let name = keyWords.joined(separator: " ")
            if name.count >= minLength && name.count <= maxLength {
                return name
            }
        } else if words.count >= 2 {
            let keyWords = words.prefix(2).map { $0.capitalized }
            let name = keyWords.joined(separator: " ")
            if name.count >= minLength && name.count <= maxLength {
                return name
            }
        }
        
        return ""
    }
    
    private static func generateNameFromTranscript(_ transcript: String, contentType: ContentType, minLength: Int, maxLength: Int) -> String {
        // Use advanced NLP to extract meaningful titles from the full transcript
        let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        guard !sentences.isEmpty else { return "" }
        
        // Strategy 1: Look for meeting/event titles in the first few sentences
        let titleKeywords = ["meeting about", "discussion on", "call about", "talk about", "conversation about", "presentation on", "review of", "planning for", "discussion of", "interview with", "consultation about", "briefing on", "update on", "report on"]
        
        for sentence in sentences.prefix(3) {
            let lowerSentence = sentence.lowercased()
            for keyword in titleKeywords {
                if let range = lowerSentence.range(of: keyword) {
                    let afterKeyword = String(sentence[range.upperBound...])
                    let words = afterKeyword.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    if words.count >= 2 {
                        let keyWords = words.prefix(3).map { $0.capitalized }
                        let title = keyWords.joined(separator: " ")
                        if title.count >= minLength && title.count <= maxLength {
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
            if words.count >= 2 {
                let keyWords = words.prefix(4).map { $0.capitalized }
                let title = keyWords.joined(separator: " ")
                if title.count >= minLength && title.count <= maxLength {
                    return title
                } else if title.count > maxLength {
                    // Try with fewer words
                    let shortTitle = keyWords.prefix(3).joined(separator: " ")
                    if shortTitle.count >= minLength && shortTitle.count <= maxLength {
                        return shortTitle
                    }
                }
            }
        }
        
        // Strategy 3: Use the most important sentence from the transcript
        let scoredSentences = sentences.map { sentence in
            (sentence: sentence, score: calculateSentenceImportance(sentence, in: transcript))
        }
        
        if let bestSentence = scoredSentences.max(by: { $0.score < $1.score }) {
            let words = bestSentence.sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if words.count >= 2 {
                let keyWords = words.prefix(4).map { $0.capitalized }
                let title = keyWords.joined(separator: " ")
                if title.count >= minLength && title.count <= maxLength {
                    return title
                } else if title.count > maxLength {
                    // Try with fewer words
                    let shortTitle = keyWords.prefix(3).joined(separator: " ")
                    if shortTitle.count >= minLength && shortTitle.count <= maxLength {
                        return shortTitle
                    }
                }
            }
        }
        
        return ""
    }
    
    private static func generateNameFromSummary(_ summary: String, contentType: ContentType, minLength: Int, maxLength: Int) -> String {
        let sentences = summary.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        guard let firstSentence = sentences.first else { return "" }
        
        let words = firstSentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        // Try to find key nouns and verbs
        if words.count >= 3 {
            let keyWords = words.prefix(4).map { $0.capitalized }
            let name = keyWords.joined(separator: " ")
            
            if name.count >= minLength && name.count <= maxLength {
                return name
            } else if name.count > maxLength {
                // Try with fewer words
                let shortName = keyWords.prefix(3).joined(separator: " ")
                if shortName.count >= minLength && shortName.count <= maxLength {
                    return shortName
                }
            }
        }
        
        return ""
    }
    
    private static func generateFallbackName(contentType: ContentType, minLength: Int, maxLength: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let dateString = formatter.string(from: Date())
        
        let typeString: String
        switch contentType {
        case .meeting: typeString = "Meeting"
        case .technical: typeString = "Tech"
        case .personalJournal: typeString = "Journal"
        case .general: typeString = "Note"
        }
        
        let name = "\(typeString) \(dateString)"
        // For fallback names, we're more lenient with length constraints
        return name.count >= 10 && name.count <= maxLength ? name : String(name.prefix(maxLength))
    }
    
    // MARK: - Helper Functions for Title Generation
    
    private static func generateNameFromTitle(_ title: TitleItem, minLength: Int, maxLength: Int) -> String {
        let words = title.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        
        print("🔍 RecordingNameGenerator: Processing title '\(title.text)' with \(words.count) words")
        print("🔍 RecordingNameGenerator: Length constraints: min=\(minLength), max=\(maxLength)")
        
        // Check if the original title meets our flexible criteria
        if title.text.count >= minLength && title.text.count <= maxLength && words.count >= 3 && words.count <= 10 {
            print("✅ RecordingNameGenerator: Original title meets criteria, using: '\(title.text)'")
            return title.text
        }
        
        // Take the first few meaningful words
        if words.count >= 2 {
            let keyWords = words.prefix(4).map { $0.capitalized }
            let name = keyWords.joined(separator: " ")
            
            print("🔍 RecordingNameGenerator: Generated name: '\(name)' (length: \(name.count))")
            
            // If the name is within the length constraints, use it
            if name.count >= minLength && name.count <= maxLength {
                print("✅ RecordingNameGenerator: Name within constraints, using: '\(name)'")
                return name
            } else if name.count > maxLength {
                // Try with fewer words
                let shortName = keyWords.prefix(3).joined(separator: " ")
                print("🔍 RecordingNameGenerator: Name too long, trying shorter: '\(shortName)' (length: \(shortName.count))")
                if shortName.count >= minLength && shortName.count <= maxLength {
                    print("✅ RecordingNameGenerator: Shorter name within constraints, using: '\(shortName)'")
                    return shortName
                }
            } else if name.count < minLength {
                print("🔍 RecordingNameGenerator: Name too short, trying longer version")
                // If too short, try with more words or use the original title
                if words.count >= 3 {
                    let longerName = words.prefix(5).map { $0.capitalized }.joined(separator: " ")
                    print("🔍 RecordingNameGenerator: Trying longer name: '\(longerName)' (length: \(longerName.count))")
                    if longerName.count >= minLength && longerName.count <= maxLength {
                        print("✅ RecordingNameGenerator: Longer name within constraints, using: '\(longerName)'")
                        return longerName
                    }
                }
                
                // If still too short, use the original title if it's reasonable
                if title.text.count >= 20 && title.text.count <= maxLength {
                    print("✅ RecordingNameGenerator: Using original title: '\(title.text)' (length: \(title.text.count))")
                    return title.text
                }
            }
        }
        
        print("❌ RecordingNameGenerator: Failed to generate valid name from title: '\(title.text)'")
        return ""
    }
    
    private static func extractKeyPhrasesFromTranscript(_ transcript: String, maxPhrases: Int) -> [String] {
        // Use ContentAnalyzer to extract key phrases
        return ContentAnalyzer.extractKeyPhrases(from: transcript, maxPhrases: maxPhrases)
    }
    
    private static func calculateSentenceImportance(_ sentence: String, in transcript: String) -> Double {
        // Use ContentAnalyzer to calculate sentence importance
        return ContentAnalyzer.calculateSentenceImportance(sentence, in: transcript)
    }
    
    private static func fixWeakEndingWords(_ title: String) -> String {
        let words = title.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard words.count >= 2 else { return title }
        
        // List of weak ending words that should be avoided
        let weakEndingWords = [
            "with", "to", "for", "of", "in", "on", "at", "by", "from", "about", 
            "regarding", "concerning", "pertaining", "related", "involving", 
            "including", "containing", "featuring", "during", "while", "when", 
            "where", "why", "how", "what", "which", "who", "whom", "whose",
            "and", "or", "but", "nor", "yet", "so", "as", "than", "like",
            "such", "very", "quite", "rather", "somewhat", "rather", "fairly",
            "just", "only", "merely", "simply", "actually", "really", "truly",
            "indeed", "certainly", "definitely", "absolutely", "completely",
            "entirely", "totally", "wholly", "fully", "thoroughly", "completely"
        ]
        
        let lastWord = words.last!.lowercased()
        
        // Check if the title ends with a weak word
        if weakEndingWords.contains(lastWord) {
            // Try to find a better ending by looking at the previous word
            if words.count >= 3 {
                // Remove the weak ending word and use the previous word as ending
                let betterWords = Array(words.dropLast())
                let betterTitle = betterWords.joined(separator: " ")
                
                // Check if the new ending is also weak
                let newLastWord = betterWords.last!.lowercased()
                if weakEndingWords.contains(newLastWord) && betterWords.count >= 3 {
                    // Remove another weak word
                    let finalWords = Array(betterWords.dropLast())
                    return finalWords.joined(separator: " ")
                }
                
                return betterTitle
            } else {
                // If we can't remove the weak word, try to add context
                let contextWords = ["Discussion", "Meeting", "Session", "Review", "Analysis", "Planning", "Preparation"]
                if let contextWord = contextWords.first {
                    return "\(title) \(contextWord)"
                }
            }
        }
        
        return title
    }
}