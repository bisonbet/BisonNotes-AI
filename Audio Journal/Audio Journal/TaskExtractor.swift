//
//  TaskExtractor.swift
//  Audio Journal
//
//  Advanced task extraction system with action verb detection and categorization
//

import Foundation
import NaturalLanguage

// MARK: - Task Extractor

class TaskExtractor {
    
    // MARK: - Configuration
    
    private let config: SummarizationConfig
    private let tagger: NLTagger
    
    init(config: SummarizationConfig = .default) {
        self.config = config
        self.tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType, .lemma])
    }
    
    // MARK: - Main Extraction Method
    
    func extractTasks(from text: String) -> [TaskItem] {
        let sentences = ContentAnalyzer.extractSentences(from: text)
        var allTasks: [TaskItem] = []
        
        for sentence in sentences {
            let tasks = extractTasksFromSentence(sentence)
            allTasks.append(contentsOf: tasks)
        }
        
        // Deduplicate and consolidate similar tasks
        let consolidatedTasks = consolidateSimilarTasks(allTasks)
        
        // Sort by priority and confidence
        let sortedTasks = consolidatedTasks.sorted { task1, task2 in
            if task1.priority.sortOrder != task2.priority.sortOrder {
                return task1.priority.sortOrder < task2.priority.sortOrder
            }
            return task1.confidence > task2.confidence
        }
        
        return Array(sortedTasks.prefix(config.maxTasks))
    }
    
    // MARK: - Sentence-Level Task Extraction
    
    private func extractTasksFromSentence(_ sentence: String) -> [TaskItem] {
        var tasks: [TaskItem] = []
        
        // Method 1: Pattern-based extraction
        if let patternTask = extractTaskUsingPatterns(sentence) {
            tasks.append(patternTask)
        }
        
        // Method 2: Action verb detection
        let verbTasks = extractTasksUsingActionVerbs(sentence)
        tasks.append(contentsOf: verbTasks)
        
        // Method 3: Imperative sentence detection
        if let imperativeTask = extractImperativeTask(sentence) {
            tasks.append(imperativeTask)
        }
        
        // Method 4: Context-based extraction (meetings, emails, etc.)
        let contextTasks = extractContextBasedTasks(sentence)
        tasks.append(contentsOf: contextTasks)
        
        // Filter by confidence threshold
        return tasks.filter { $0.confidence >= config.minConfidenceThreshold }
    }
    
    // MARK: - Pattern-Based Extraction
    
    private func extractTaskUsingPatterns(_ sentence: String) -> TaskItem? {
        let lowercased = sentence.lowercased()
        
        // Enhanced task patterns with more specific matching
        let taskPatterns: [(pattern: String, category: TaskItem.TaskCategory, basePriority: TaskItem.Priority, confidenceBoost: Double)] = [
            // Communication tasks
            ("need to call", .call, .medium, 0.8),
            ("have to call", .call, .high, 0.9),
            ("must call", .call, .high, 0.9),
            ("should call", .call, .medium, 0.7),
            ("call back", .call, .medium, 0.8),
            ("phone", .call, .medium, 0.6),
            ("reach out to", .call, .medium, 0.7),
            
            // Email tasks
            ("need to email", .email, .medium, 0.8),
            ("have to email", .email, .medium, 0.8),
            ("send email", .email, .medium, 0.8),
            ("email", .email, .low, 0.5),
            ("send message", .email, .medium, 0.7),
            ("message", .email, .low, 0.4),
            ("reply to", .email, .medium, 0.7),
            ("respond to", .email, .medium, 0.7),
            
            // Meeting tasks
            ("need to meet", .meeting, .medium, 0.8),
            ("have to meet", .meeting, .medium, 0.8),
            ("schedule meeting", .meeting, .medium, 0.9),
            ("set up meeting", .meeting, .medium, 0.9),
            ("meeting with", .meeting, .medium, 0.7),
            ("appointment with", .meeting, .medium, 0.8),
            ("book appointment", .meeting, .medium, 0.8),
            ("arrange meeting", .meeting, .medium, 0.8),
            
            // Purchase tasks
            ("need to buy", .purchase, .medium, 0.8),
            ("have to buy", .purchase, .medium, 0.8),
            ("must buy", .purchase, .high, 0.9),
            ("should buy", .purchase, .medium, 0.7),
            ("purchase", .purchase, .medium, 0.7),
            ("order", .purchase, .medium, 0.6),
            ("get", .purchase, .low, 0.4),
            ("pick up", .purchase, .medium, 0.6),
            
            // Research tasks
            ("need to research", .research, .low, 0.8),
            ("have to research", .research, .medium, 0.8),
            ("look into", .research, .low, 0.7),
            ("investigate", .research, .medium, 0.8),
            ("find out", .research, .low, 0.6),
            ("check on", .research, .medium, 0.7),
            ("look up", .research, .low, 0.6),
            ("study", .research, .medium, 0.7),
            
            // Travel tasks
            ("need to go", .travel, .medium, 0.7),
            ("have to go", .travel, .medium, 0.7),
            ("must go", .travel, .high, 0.8),
            ("visit", .travel, .medium, 0.6),
            ("travel to", .travel, .medium, 0.8),
            ("drive to", .travel, .medium, 0.7),
            ("fly to", .travel, .medium, 0.8),
            
            // Health tasks
            ("doctor appointment", .health, .medium, 0.9),
            ("medical appointment", .health, .high, 0.9),
            ("dentist appointment", .health, .medium, 0.9),
            ("see doctor", .health, .medium, 0.8),
            ("health checkup", .health, .medium, 0.8),
            ("prescription", .health, .medium, 0.7),
            ("pharmacy", .health, .medium, 0.6)
        ]
        
        for (pattern, category, basePriority, confidenceBoost) in taskPatterns {
            if lowercased.contains(pattern) {
                let taskText = formatTaskText(sentence, pattern: pattern)
                let timeReference = extractTimeReference(from: sentence)
                let priority = adjustPriorityForUrgency(basePriority, in: sentence)
                let confidence = calculatePatternConfidence(sentence: sentence, pattern: pattern, baseConfidence: confidenceBoost)
                
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
    
    // MARK: - Action Verb Detection
    
    private func extractTasksUsingActionVerbs(_ sentence: String) -> [TaskItem] {
        tagger.string = sentence
        var tasks: [TaskItem] = []
        
        let actionVerbs = [
            "complete", "finish", "submit", "deliver", "prepare", "create", "write",
            "review", "update", "fix", "repair", "install", "configure", "setup",
            "organize", "plan", "schedule", "book", "reserve", "confirm", "cancel",
            "send", "receive", "download", "upload", "backup", "restore", "delete",
            "clean", "wash", "cook", "prepare", "pack", "unpack", "move", "relocate"
        ]
        
        let range = sentence.startIndex..<sentence.endIndex
        
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
            if tag == .verb {
                let verb = String(sentence[tokenRange]).lowercased()
                
                if actionVerbs.contains(verb) {
                    // Look for the object of the verb
                    let remainingText = String(sentence[tokenRange.upperBound...])
                    if !remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let taskText = formatActionVerbTask(verb: verb, object: remainingText)
                        let category = categorizeActionVerb(verb)
                        let priority = determinePriorityFromContext(sentence)
                        let timeReference = extractTimeReference(from: sentence)
                        let confidence = calculateActionVerbConfidence(verb: verb, sentence: sentence)
                        
                        if confidence >= config.minConfidenceThreshold {
                            let task = TaskItem(
                                text: taskText,
                                priority: priority,
                                timeReference: timeReference,
                                category: category,
                                confidence: confidence
                            )
                            tasks.append(task)
                        }
                    }
                }
            }
            return true
        }
        
        return tasks
    }
    
    // MARK: - Imperative Sentence Detection
    
    private func extractImperativeTask(_ sentence: String) -> TaskItem? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if sentence starts with an imperative verb
        let imperativeStarters = [
            "remember", "don't forget", "make sure", "ensure", "verify", "check",
            "confirm", "validate", "test", "review", "examine", "inspect"
        ]
        
        let lowercased = trimmed.lowercased()
        
        for starter in imperativeStarters {
            if lowercased.hasPrefix(starter) {
                let taskText = formatImperativeTask(trimmed)
                let category = categorizeImperativeTask(starter)
                let priority = determinePriorityFromContext(sentence)
                let timeReference = extractTimeReference(from: sentence)
                let confidence = calculateImperativeConfidence(starter: starter, sentence: sentence)
                
                if confidence >= config.minConfidenceThreshold {
                    return TaskItem(
                        text: taskText,
                        priority: priority,
                        timeReference: timeReference,
                        category: category,
                        confidence: confidence
                    )
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Context-Based Extraction
    
    private func extractContextBasedTasks(_ sentence: String) -> [TaskItem] {
        var tasks: [TaskItem] = []
        let lowercased = sentence.lowercased()
        
        // Meeting context
        if lowercased.contains("action item") || lowercased.contains("follow up") || lowercased.contains("next step") {
            if let task = extractMeetingActionItem(sentence) {
                tasks.append(task)
            }
        }
        
        // Project context
        if lowercased.contains("deadline") || lowercased.contains("due") || lowercased.contains("milestone") {
            if let task = extractProjectTask(sentence) {
                tasks.append(task)
            }
        }
        
        // Shopping context
        if lowercased.contains("shopping list") || lowercased.contains("grocery") || lowercased.contains("store") {
            if let task = extractShoppingTask(sentence) {
                tasks.append(task)
            }
        }
        
        return tasks
    }
    
    // MARK: - Task Consolidation
    
    private func consolidateSimilarTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        var consolidatedTasks: [TaskItem] = []
        var processedIndices: Set<Int> = []
        
        for i in 0..<tasks.count {
            if processedIndices.contains(i) { continue }
            
            var currentTask = tasks[i]
            var similarTasks: [TaskItem] = []
            
            // Find similar tasks
            for j in (i+1)..<tasks.count {
                if processedIndices.contains(j) { continue }
                
                if areTasksSimilar(currentTask, tasks[j]) {
                    similarTasks.append(tasks[j])
                    processedIndices.insert(j)
                }
            }
            
            // Consolidate if we found similar tasks
            if !similarTasks.isEmpty {
                currentTask = consolidateTaskGroup([currentTask] + similarTasks)
            }
            
            consolidatedTasks.append(currentTask)
            processedIndices.insert(i)
        }
        
        return consolidatedTasks
    }
    
    private func areTasksSimilar(_ task1: TaskItem, _ task2: TaskItem) -> Bool {
        // Same category is a strong indicator
        guard task1.category == task2.category else { return false }
        
        // Calculate text similarity
        let words1 = Set(task1.text.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(task2.text.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        let similarity = Double(intersection.count) / Double(union.count)
        return similarity > 0.6 // 60% word overlap
    }
    
    private func consolidateTaskGroup(_ tasks: [TaskItem]) -> TaskItem {
        // Use the highest confidence task as the base
        let bestTask = tasks.max { $0.confidence < $1.confidence }!
        
        // Combine unique information from all tasks
        let allTexts = tasks.map { $0.text }
        let consolidatedText = createConsolidatedTaskText(allTexts)
        
        // Use the highest priority
        let highestPriority = tasks.min { $0.priority.sortOrder > $1.priority.sortOrder }!.priority
        
        // Average the confidence
        let averageConfidence = tasks.map { $0.confidence }.reduce(0, +) / Double(tasks.count)
        
        // Prefer specific time references
        let timeReference = tasks.compactMap { $0.timeReference }.first
        
        return TaskItem(
            text: consolidatedText,
            priority: highestPriority,
            timeReference: timeReference,
            category: bestTask.category,
            confidence: averageConfidence
        )
    }
    
    // MARK: - Helper Methods
    
    private func formatTaskText(_ sentence: String, pattern: String) -> String {
        var cleaned = sentence
        
        // Remove common task prefixes
        let prefixesToRemove = [
            "i need to", "i have to", "i must", "i should", "we need to", "we have to", 
            "we must", "we should", "let's", "let me", "i'll", "we'll"
        ]
        
        for prefix in prefixesToRemove {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        
        // Capitalize first letter and ensure proper punctuation
        return formatTaskString(cleaned)
    }
    
    private func formatActionVerbTask(verb: String, object: String) -> String {
        let cleanObject = object.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskText = "\(verb.capitalized) \(cleanObject)"
        return formatTaskString(taskText)
    }
    
    private func formatImperativeTask(_ sentence: String) -> String {
        return formatTaskString(sentence)
    }
    
    private func formatTaskString(_ text: String) -> String {
        var formatted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !formatted.isEmpty {
            // Capitalize first letter
            formatted = formatted.prefix(1).uppercased() + formatted.dropFirst()
            
            // Ensure proper punctuation
            if !formatted.hasSuffix(".") && !formatted.hasSuffix("!") && !formatted.hasSuffix("?") {
                formatted += "."
            }
        }
        
        return formatted
    }
    
    private func createConsolidatedTaskText(_ texts: [String]) -> String {
        // Find the most comprehensive text
        let longestText = texts.max { $0.count < $1.count } ?? texts.first ?? ""
        return formatTaskString(longestText)
    }
    
    private func categorizeActionVerb(_ verb: String) -> TaskItem.TaskCategory {
        switch verb.lowercased() {
        case "call", "phone", "contact":
            return .call
        case "email", "message", "send", "reply", "respond":
            return .email
        case "meet", "schedule", "book", "reserve":
            return .meeting
        case "buy", "purchase", "order", "get":
            return .purchase
        case "research", "investigate", "study", "review", "examine":
            return .research
        case "go", "visit", "travel", "drive", "fly":
            return .travel
        case "doctor", "medical", "health", "prescription":
            return .health
        default:
            return .general
        }
    }
    
    private func categorizeImperativeTask(_ starter: String) -> TaskItem.TaskCategory {
        switch starter.lowercased() {
        case "remember", "don't forget":
            return .general
        case "check", "verify", "confirm", "validate":
            return .research
        case "test", "review", "examine", "inspect":
            return .research
        default:
            return .general
        }
    }
    
    private func adjustPriorityForUrgency(_ basePriority: TaskItem.Priority, in sentence: String) -> TaskItem.Priority {
        let lowercased = sentence.lowercased()
        
        let urgentIndicators = ["urgent", "asap", "immediately", "right away", "critical", "emergency"]
        let highIndicators = ["important", "must", "have to", "today", "tomorrow", "deadline"]
        let lowIndicators = ["maybe", "eventually", "sometime", "when possible", "if time permits"]
        
        if urgentIndicators.contains(where: { lowercased.contains($0) }) {
            return .high
        } else if highIndicators.contains(where: { lowercased.contains($0) }) {
            return basePriority == .low ? .medium : .high
        } else if lowIndicators.contains(where: { lowercased.contains($0) }) {
            return .low
        }
        
        return basePriority
    }
    
    private func determinePriorityFromContext(_ sentence: String) -> TaskItem.Priority {
        return adjustPriorityForUrgency(.medium, in: sentence)
    }
    
    private func calculatePatternConfidence(sentence: String, pattern: String, baseConfidence: Double) -> Double {
        var confidence = baseConfidence
        
        // Boost for strong modal verbs
        let strongModals = ["must", "need", "have to", "required"]
        if strongModals.contains(where: { sentence.lowercased().contains($0) }) {
            confidence += 0.1
        }
        
        // Boost for specific objects/targets
        if sentence.contains("with") || sentence.contains("about") || sentence.contains("for") {
            confidence += 0.1
        }
        
        // Boost for time references
        if extractTimeReference(from: sentence) != nil {
            confidence += 0.1
        }
        
        return min(confidence, 1.0)
    }
    
    private func calculateActionVerbConfidence(verb: String, sentence: String) -> Double {
        var confidence = 0.6 // Base confidence for action verbs
        
        // Boost for strong action verbs
        let strongVerbs = ["complete", "finish", "submit", "deliver", "create", "fix"]
        if strongVerbs.contains(verb.lowercased()) {
            confidence += 0.2
        }
        
        // Boost for context
        if sentence.lowercased().contains("need") || sentence.lowercased().contains("must") {
            confidence += 0.1
        }
        
        return min(confidence, 1.0)
    }
    
    private func calculateImperativeConfidence(starter: String, sentence: String) -> Double {
        var confidence = 0.7 // Base confidence for imperatives
        
        // Boost for strong imperatives
        let strongImperatives = ["remember", "don't forget", "make sure"]
        if strongImperatives.contains(starter.lowercased()) {
            confidence += 0.2
        }
        
        return min(confidence, 1.0)
    }
    
    private func extractMeetingActionItem(_ sentence: String) -> TaskItem? {
        let taskText = formatTaskString(sentence)
        let timeReference = extractTimeReference(from: sentence)
        let priority = determinePriorityFromContext(sentence)
        
        return TaskItem(
            text: taskText,
            priority: priority,
            timeReference: timeReference,
            category: .meeting,
            confidence: 0.8
        )
    }
    
    private func extractProjectTask(_ sentence: String) -> TaskItem? {
        let taskText = formatTaskString(sentence)
        let timeReference = extractTimeReference(from: sentence)
        let priority: TaskItem.Priority = sentence.lowercased().contains("deadline") ? .high : .medium
        
        return TaskItem(
            text: taskText,
            priority: priority,
            timeReference: timeReference,
            category: .general,
            confidence: 0.7
        )
    }
    
    private func extractShoppingTask(_ sentence: String) -> TaskItem? {
        let taskText = formatTaskString(sentence)
        let timeReference = extractTimeReference(from: sentence)
        
        return TaskItem(
            text: taskText,
            priority: .low,
            timeReference: timeReference,
            category: .purchase,
            confidence: 0.6
        )
    }
    
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