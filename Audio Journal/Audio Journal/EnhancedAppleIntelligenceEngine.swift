//
//  EnhancedAppleIntelligenceEngine.swift
//  Audio Journal
//
//  Enhanced Apple Intelligence summarization engine with advanced NLTagger processing
//

import Foundation
import NaturalLanguage

// MARK: - Enhanced Apple Intelligence Engine

class EnhancedAppleIntelligenceEngine: SummarizationEngine {
    
    // MARK: - SummarizationEngine Protocol
    
    var name: String { "Enhanced Apple Intelligence" }
    var description: String { "Advanced natural language processing using Apple's NLTagger with semantic analysis" }
    var isAvailable: Bool { true }
    var version: String { "2.0" }
    
    // MARK: - Configuration
    
    private let config: SummarizationConfig
    
    init(config: SummarizationConfig = .default) {
        self.config = config
    }
    
    // MARK: - Main Processing Methods
    
    func generateSummary(from text: String, contentType: ContentType) async throws -> String {
        let startTime = Date()
        
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.invalidInput
        }
        
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        guard wordCount >= 50 else {
            throw SummarizationError.transcriptTooShort
        }
        
        guard wordCount <= 10000 else {
            throw SummarizationError.transcriptTooLong(maxLength: 10000)
        }
        
        // Check for timeout
        let processingTime = Date().timeIntervalSince(startTime)
        guard processingTime < config.timeoutInterval else {
            throw SummarizationError.processingTimeout
        }
        
        return try await performAdvancedSummarization(text: text, contentType: contentType)
    }
    
    func extractTasks(from text: String) async throws -> [TaskItem] {
        return try await performAdvancedTaskExtraction(from: text)
    }
    
    func extractReminders(from text: String) async throws -> [ReminderItem] {
        return try await performAdvancedReminderExtraction(from: text)
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        return ContentAnalyzer.classifyContent(text)
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], contentType: ContentType) {
        let contentType = try await classifyContent(text)
        
        if config.enableParallelProcessing {
            // Process all components in parallel
            async let summaryTask = generateSummary(from: text, contentType: contentType)
            async let tasksTask = extractTasks(from: text)
            async let remindersTask = extractReminders(from: text)
            
            let summary = try await summaryTask
            let tasks = try await tasksTask
            let reminders = try await remindersTask
            
            return (summary, tasks, reminders, contentType)
        } else {
            // Process sequentially
            let summary = try await generateSummary(from: text, contentType: contentType)
            let tasks = try await extractTasks(from: text)
            let reminders = try await extractReminders(from: text)
            
            return (summary, tasks, reminders, contentType)
        }
    }
    
    // MARK: - Advanced Summarization
    
    private func performAdvancedSummarization(text: String, contentType: ContentType) async throws -> String {
        let preprocessedText = ContentAnalyzer.preprocessText(text)
        let sentences = ContentAnalyzer.extractSentences(from: preprocessedText)
        
        guard !sentences.isEmpty else {
            throw SummarizationError.insufficientContent
        }
        
        // Score sentences based on importance
        let scoredSentences = sentences.map { sentence in
            (sentence: sentence, score: ContentAnalyzer.calculateSentenceImportance(sentence, in: preprocessedText))
        }
        
        // Cluster related sentences
        let clusters = ContentAnalyzer.clusterRelatedSentences(sentences)
        
        // Select best sentences from each cluster
        var selectedSentences: [String] = []
        let targetSentenceCount = min(max(sentences.count / 4, 2), 6) // 25% of sentences, min 2, max 6
        
        for cluster in clusters {
            if selectedSentences.count >= targetSentenceCount { break }
            
            // Find the best sentence in this cluster
            let clusterScores = cluster.map { sentence in
                (sentence: sentence, score: ContentAnalyzer.calculateSentenceImportance(sentence, in: preprocessedText))
            }
            
            if let bestInCluster = clusterScores.max(by: { $0.score < $1.score }) {
                selectedSentences.append(bestInCluster.sentence)
            }
        }
        
        // If we don't have enough sentences, add more from the highest scored
        if selectedSentences.count < targetSentenceCount {
            let remainingNeeded = targetSentenceCount - selectedSentences.count
            let additionalSentences = scoredSentences
                .filter { !selectedSentences.contains($0.sentence) }
                .sorted { $0.score > $1.score }
                .prefix(remainingNeeded)
                .map { $0.sentence }
            
            selectedSentences.append(contentsOf: additionalSentences)
        }
        
        // Create context-aware summary based on content type
        return createContextAwareSummary(sentences: selectedSentences, contentType: contentType, originalText: text)
    }
    
    private func createContextAwareSummary(sentences: [String], contentType: ContentType, originalText: String) -> String {
        let keyPhrases = ContentAnalyzer.extractKeyPhrases(from: originalText, maxPhrases: 5)
        
        var summary = ""
        
        switch contentType {
        case .meeting:
            summary = createMeetingSummary(sentences: sentences, keyPhrases: keyPhrases)
        case .personalJournal:
            summary = createJournalSummary(sentences: sentences, keyPhrases: keyPhrases)
        case .technical:
            summary = createTechnicalSummary(sentences: sentences, keyPhrases: keyPhrases)
        case .general:
            summary = createGeneralSummary(sentences: sentences, keyPhrases: keyPhrases)
        }
        
        // Ensure summary doesn't exceed max length
        if summary.count > config.maxSummaryLength {
            let truncated = String(summary.prefix(config.maxSummaryLength))
            if let lastSentenceEnd = truncated.lastIndex(of: ".") {
                summary = String(truncated[...lastSentenceEnd])
            } else {
                summary = truncated + "..."
            }
        }
        
        return summary
    }
    
    // MARK: - Content-Type Specific Summaries
    
    private func createMeetingSummary(sentences: [String], keyPhrases: [String]) -> String {
        var summary = "Meeting Summary: "
        
        // Look for key meeting elements
        let decisionSentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return lower.contains("decided") || lower.contains("agreed") || lower.contains("concluded")
        }
        
        let actionSentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return lower.contains("action") || lower.contains("next step") || lower.contains("follow up")
        }
        
        // Prioritize decisions and actions
        var prioritizedSentences: [String] = []
        prioritizedSentences.append(contentsOf: decisionSentences.prefix(2))
        prioritizedSentences.append(contentsOf: actionSentences.prefix(2))
        
        // Add remaining sentences
        let remainingSentences = sentences.filter { !prioritizedSentences.contains($0) }
        prioritizedSentences.append(contentsOf: remainingSentences.prefix(3))
        
        summary += prioritizedSentences.joined(separator: " ")
        
        if !keyPhrases.isEmpty {
            summary += " Key topics discussed: " + keyPhrases.prefix(3).joined(separator: ", ") + "."
        }
        
        return summary
    }
    
    private func createJournalSummary(sentences: [String], keyPhrases: [String]) -> String {
        var summary = "Personal Reflection: "
        
        // Look for emotional and reflective content
        let emotionalSentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return lower.contains("feel") || lower.contains("think") || lower.contains("realize") || 
                   lower.contains("grateful") || lower.contains("happy") || lower.contains("sad")
        }
        
        let insightSentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return lower.contains("learned") || lower.contains("discovered") || lower.contains("understand")
        }
        
        // Prioritize emotional and insight content
        var prioritizedSentences: [String] = []
        prioritizedSentences.append(contentsOf: emotionalSentences.prefix(2))
        prioritizedSentences.append(contentsOf: insightSentences.prefix(2))
        
        // Add remaining sentences
        let remainingSentences = sentences.filter { !prioritizedSentences.contains($0) }
        prioritizedSentences.append(contentsOf: remainingSentences.prefix(2))
        
        summary += prioritizedSentences.joined(separator: " ")
        
        return summary
    }
    
    private func createTechnicalSummary(sentences: [String], keyPhrases: [String]) -> String {
        var summary = "Technical Discussion: "
        
        // Look for technical concepts and solutions
        let conceptSentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return lower.contains("system") || lower.contains("algorithm") || lower.contains("method") ||
                   lower.contains("implementation") || lower.contains("architecture")
        }
        
        let problemSolutionSentences = sentences.filter { sentence in
            let lower = sentence.lowercased()
            return lower.contains("problem") || lower.contains("solution") || lower.contains("fix") ||
                   lower.contains("issue") || lower.contains("resolve")
        }
        
        // Prioritize concepts and solutions
        var prioritizedSentences: [String] = []
        prioritizedSentences.append(contentsOf: conceptSentences.prefix(2))
        prioritizedSentences.append(contentsOf: problemSolutionSentences.prefix(2))
        
        // Add remaining sentences
        let remainingSentences = sentences.filter { !prioritizedSentences.contains($0) }
        prioritizedSentences.append(contentsOf: remainingSentences.prefix(2))
        
        summary += prioritizedSentences.joined(separator: " ")
        
        if !keyPhrases.isEmpty {
            summary += " Key technical terms: " + keyPhrases.prefix(4).joined(separator: ", ") + "."
        }
        
        return summary
    }
    
    private func createGeneralSummary(sentences: [String], keyPhrases: [String]) -> String {
        var summary = "Summary: "
        
        // Use the highest-scored sentences
        summary += sentences.prefix(4).joined(separator: " ")
        
        if !keyPhrases.isEmpty {
            summary += " Main topics: " + keyPhrases.prefix(3).joined(separator: ", ") + "."
        }
        
        return summary
    }
    
    // MARK: - Advanced Task Extraction
    
    private func performAdvancedTaskExtraction(from text: String) async throws -> [TaskItem] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        
        var tasks: [TaskItem] = []
        let sentences = ContentAnalyzer.extractSentences(from: text)
        
        for sentence in sentences {
            if let task = extractTaskFromSentence(sentence, using: tagger) {
                tasks.append(task)
            }
        }
        
        // Deduplicate and sort by priority
        let uniqueTasks = Array(Set(tasks)).sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        
        return Array(uniqueTasks.prefix(config.maxTasks))
    }
    
    private func extractTaskFromSentence(_ sentence: String, using tagger: NLTagger) -> TaskItem? {
        let lowercased = sentence.lowercased()
        
        // Task indicators with their patterns
        let taskPatterns: [(pattern: String, category: TaskItem.TaskCategory, priority: TaskItem.Priority)] = [
            ("need to call", .call, .medium),
            ("have to call", .call, .high),
            ("must call", .call, .high),
            ("call", .call, .medium),
            ("phone", .call, .medium),
            
            ("need to meet", .meeting, .medium),
            ("schedule meeting", .meeting, .medium),
            ("meeting with", .meeting, .medium),
            ("appointment", .meeting, .medium),
            
            ("need to buy", .purchase, .medium),
            ("have to buy", .purchase, .medium),
            ("purchase", .purchase, .medium),
            ("order", .purchase, .low),
            
            ("need to email", .email, .medium),
            ("send email", .email, .medium),
            ("email", .email, .low),
            ("message", .email, .low),
            
            ("need to research", .research, .low),
            ("look into", .research, .low),
            ("investigate", .research, .medium),
            ("find out", .research, .low),
            
            ("need to go", .travel, .medium),
            ("have to go", .travel, .medium),
            ("visit", .travel, .medium),
            ("travel to", .travel, .medium),
            
            ("doctor", .health, .medium),
            ("appointment", .health, .medium),
            ("medical", .health, .high),
            ("health", .health, .medium)
        ]
        
        for (pattern, category, basePriority) in taskPatterns {
            if lowercased.contains(pattern) {
                // Extract the task text
                let taskText = cleanTaskText(sentence, pattern: pattern)
                
                // Extract time reference
                let timeReference = extractTimeReference(from: sentence)
                
                // Adjust priority based on urgency indicators
                let priority = adjustPriorityForUrgency(basePriority, in: sentence)
                
                // Calculate confidence based on pattern strength and context
                let confidence = calculateTaskConfidence(sentence: sentence, pattern: pattern)
                
                guard confidence >= config.minConfidenceThreshold else { continue }
                
                return TaskItem(
                    text: taskText,
                    priority: priority,
                    timeReference: timeReference,
                    category: category,
                    confidence: confidence
                )
            }
        }
        
        return nil
    }
    
    private func cleanTaskText(_ sentence: String, pattern: String) -> String {
        var cleaned = sentence
        
        // Remove common prefixes
        let prefixesToRemove = ["i need to", "i have to", "i must", "we need to", "we have to", "we must"]
        for prefix in prefixesToRemove {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        
        // Capitalize first letter
        if !cleaned.isEmpty {
            cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        
        // Ensure it ends with proper punctuation
        if !cleaned.hasSuffix(".") && !cleaned.hasSuffix("!") && !cleaned.hasSuffix("?") {
            cleaned += "."
        }
        
        return cleaned
    }
    
    private func adjustPriorityForUrgency(_ basePriority: TaskItem.Priority, in sentence: String) -> TaskItem.Priority {
        let lowercased = sentence.lowercased()
        
        let urgentIndicators = ["urgent", "asap", "immediately", "right away", "today", "now"]
        let highIndicators = ["important", "critical", "must", "have to", "tomorrow"]
        let lowIndicators = ["maybe", "eventually", "sometime", "when possible"]
        
        if urgentIndicators.contains(where: { lowercased.contains($0) }) {
            return .high
        } else if highIndicators.contains(where: { lowercased.contains($0) }) {
            return basePriority == .low ? .medium : .high
        } else if lowIndicators.contains(where: { lowercased.contains($0) }) {
            return .low
        }
        
        return basePriority
    }
    
    private func calculateTaskConfidence(sentence: String, pattern: String) -> Double {
        var confidence = 0.5 // Base confidence
        
        let lowercased = sentence.lowercased()
        
        // Boost confidence for strong action verbs
        let strongVerbs = ["must", "need", "have to", "should", "will"]
        if strongVerbs.contains(where: { lowercased.contains($0) }) {
            confidence += 0.2
        }
        
        // Boost confidence for specific objects/targets
        if lowercased.contains("with") || lowercased.contains("about") || lowercased.contains("for") {
            confidence += 0.1
        }
        
        // Boost confidence for time references
        if extractTimeReference(from: sentence) != nil {
            confidence += 0.2
        }
        
        return min(confidence, 1.0)
    }
    
    // MARK: - Advanced Reminder Extraction
    
    private func performAdvancedReminderExtraction(from text: String) async throws -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        let sentences = ContentAnalyzer.extractSentences(from: text)
        
        for sentence in sentences {
            if let reminder = extractReminderFromSentence(sentence) {
                reminders.append(reminder)
            }
        }
        
        // Deduplicate and sort by urgency
        let uniqueReminders = Array(Set(reminders)).sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        
        return Array(uniqueReminders.prefix(config.maxReminders))
    }
    
    private func extractReminderFromSentence(_ sentence: String) -> ReminderItem? {
        let lowercased = sentence.lowercased()
        
        let reminderIndicators = [
            "remind me", "don't forget", "remember to", "make sure to",
            "deadline", "due", "appointment", "meeting at", "call at"
        ]
        
        let hasReminderIndicator = reminderIndicators.contains { lowercased.contains($0) }
        let timeRef = extractTimeReference(from: sentence)
        
        // Must have either a reminder indicator or a time reference
        guard hasReminderIndicator || timeRef != nil else { return nil }
        
        let timeReference = timeRef != nil ? 
            ReminderItem.TimeReference(originalText: timeRef!) : 
            ReminderItem.TimeReference(originalText: "No specific time")
        let urgency = determineUrgency(from: sentence, timeReference: timeReference)
        let confidence = calculateReminderConfidence(sentence: sentence, hasIndicator: hasReminderIndicator, hasTime: timeRef != nil)
        
        guard confidence >= config.minConfidenceThreshold else { return nil }
        
        let cleanedText = cleanReminderText(sentence)
        
        return ReminderItem(
            text: cleanedText,
            timeReference: timeReference,
            urgency: urgency,
            confidence: confidence
        )
    }
    
    private func cleanReminderText(_ sentence: String) -> String {
        var cleaned = sentence
        
        // Remove reminder prefixes
        let prefixesToRemove = ["remind me to", "don't forget to", "remember to", "make sure to"]
        for prefix in prefixesToRemove {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        
        // Capitalize first letter
        if !cleaned.isEmpty {
            cleaned = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        }
        
        return cleaned
    }
    
    private func determineUrgency(from sentence: String, timeReference: ReminderItem.TimeReference) -> ReminderItem.Urgency {
        let lowercased = sentence.lowercased()
        
        // Check for immediate urgency indicators
        if lowercased.contains("now") || lowercased.contains("immediately") || lowercased.contains("asap") {
            return .immediate
        }
        
        // Check for today indicators
        if lowercased.contains("today") || lowercased.contains("this morning") || 
           lowercased.contains("this afternoon") || lowercased.contains("tonight") {
            return .today
        }
        
        // Check for this week indicators
        if lowercased.contains("this week") || lowercased.contains("tomorrow") ||
           lowercased.contains("monday") || lowercased.contains("tuesday") ||
           lowercased.contains("wednesday") || lowercased.contains("thursday") ||
           lowercased.contains("friday") {
            return .thisWeek
        }
        
        // Check parsed date
        if let date = timeReference.parsedDate {
            let now = Date()
            let timeInterval = date.timeIntervalSince(now)
            
            if timeInterval < 3600 { // Within 1 hour
                return .immediate
            } else if timeInterval < 86400 { // Within 24 hours
                return .today
            } else if timeInterval < 604800 { // Within 1 week
                return .thisWeek
            }
        }
        
        return .later
    }
    
    private func calculateReminderConfidence(sentence: String, hasIndicator: Bool, hasTime: Bool) -> Double {
        var confidence = 0.3 // Base confidence
        
        if hasIndicator {
            confidence += 0.3
        }
        
        if hasTime {
            confidence += 0.4
        }
        
        // Boost for specific reminder words
        let lowercased = sentence.lowercased()
        let strongIndicators = ["deadline", "due", "appointment", "meeting", "call"]
        if strongIndicators.contains(where: { lowercased.contains($0) }) {
            confidence += 0.2
        }
        
        return min(confidence, 1.0)
    }
    
    // MARK: - Time Reference Extraction
    
    private func extractTimeReference(from sentence: String) -> String? {
        let lowercased = sentence.lowercased()
        
        let timePatterns = [
            "today", "tomorrow", "tonight", "this morning", "this afternoon", "this evening",
            "next week", "next month", "next year", "later today", "later this week",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        
        // Look for specific time patterns
        for pattern in timePatterns {
            if lowercased.contains(pattern) {
                return pattern.capitalized
            }
        }
        
        // Look for time patterns like "at 3pm", "by 5:00", etc.
        let timeRegexPatterns = [
            "at \\d{1,2}(:\\d{2})?(am|pm)?",
            "by \\d{1,2}(:\\d{2})?(am|pm)?",
            "\\d{1,2}(:\\d{2})?(am|pm)",
            "in \\d+ (hour|hours|minute|minutes|day|days)"
        ]
        
        for pattern in timeRegexPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            if let match = regex?.firstMatch(in: sentence, options: [], range: NSRange(location: 0, length: sentence.count)) {
                let matchedString = String(sentence[Range(match.range, in: sentence)!])
                return matchedString
            }
        }
        
        return nil
    }
}