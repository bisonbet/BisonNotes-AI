//
//  ReminderExtractor.swift
//  Audio Journal
//
//  Enhanced reminder extraction system with time parsing and urgency classification
//

import Foundation
import NaturalLanguage

// MARK: - Reminder Extractor

class ReminderExtractor {
    
    // MARK: - Configuration
    
    private let config: SummarizationConfig
    private let tagger: NLTagger
    private let dateFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    
    init(config: SummarizationConfig = .default) {
        self.config = config
        self.tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        
        self.dateFormatter = DateFormatter()
        self.dateFormatter.dateStyle = .medium
        self.dateFormatter.timeStyle = .none
        
        self.timeFormatter = DateFormatter()
        self.timeFormatter.dateStyle = .none
        self.timeFormatter.timeStyle = .short
    }
    
    // MARK: - Main Extraction Method
    
    func extractReminders(from text: String) -> [ReminderItem] {
        let sentences = ContentAnalyzer.extractSentences(from: text)
        var allReminders: [ReminderItem] = []
        
        for sentence in sentences {
            let reminders = extractRemindersFromSentence(sentence)
            allReminders.append(contentsOf: reminders)
        }
        
        // Consolidate similar reminders
        let consolidatedReminders = consolidateSimilarReminders(allReminders)
        
        // Sort by urgency and confidence
        let sortedReminders = consolidatedReminders.sorted { reminder1, reminder2 in
            if reminder1.urgency.sortOrder != reminder2.urgency.sortOrder {
                return reminder1.urgency.sortOrder < reminder2.urgency.sortOrder
            }
            return reminder1.confidence > reminder2.confidence
        }
        
        return Array(sortedReminders.prefix(config.maxReminders))
    }
    
    // MARK: - Sentence-Level Reminder Extraction
    
    private func extractRemindersFromSentence(_ sentence: String) -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        
        // Method 1: Explicit reminder indicators
        if let explicitReminder = extractExplicitReminder(sentence) {
            reminders.append(explicitReminder)
        }
        
        // Method 2: Time-based reminders (appointments, deadlines)
        let timeReminders = extractTimeBasedReminders(sentence)
        reminders.append(contentsOf: timeReminders)
        
        // Method 3: Event-based reminders
        let eventReminders = extractEventBasedReminders(sentence)
        reminders.append(contentsOf: eventReminders)
        
        // Method 4: Recurring reminders
        let recurringReminders = extractRecurringReminders(sentence)
        reminders.append(contentsOf: recurringReminders)
        
        // Filter by confidence threshold
        return reminders.filter { $0.confidence >= config.minConfidenceThreshold }
    }
    
    // MARK: - Explicit Reminder Extraction
    
    private func extractExplicitReminder(_ sentence: String) -> ReminderItem? {
        let lowercased = sentence.lowercased()
        
        // Very conservative reminder patterns - only extract explicit reminders
        let reminderIndicators: [(pattern: String, confidenceBoost: Double)] = [
            ("remind me to", 0.95),
            ("remind me about", 0.95),
            ("don't forget to", 0.95),
            ("don't forget about", 0.95),
            ("i need to remember to", 0.9),
            ("i need to remember about", 0.9),
            ("set reminder for", 0.95),
            ("set reminder to", 0.95),
            ("note to self:", 0.9),
            ("mental note:", 0.9)
        ]
        
        for (pattern, confidenceBoost) in reminderIndicators {
            if lowercased.contains(pattern) {
                let cleanedText = cleanReminderText(sentence, pattern: pattern)
                let timeReference = parseAdvancedTimeReference(from: sentence)
                let urgency = determineUrgencyFromTimeReference(timeReference, sentence: sentence)
                let confidence = calculateExplicitReminderConfidence(sentence: sentence, pattern: pattern, baseConfidence: confidenceBoost)
                
                if confidence >= config.minConfidenceThreshold {
                    return ReminderItem(
                        text: cleanedText,
                        timeReference: timeReference,
                        urgency: urgency,
                        confidence: confidence
                    )
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Time-Based Reminder Extraction
    
    private func extractTimeBasedReminders(_ sentence: String) -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        let lowercased = sentence.lowercased()
        
        let timeBasedPatterns: [(pattern: String, urgencyHint: ReminderItem.Urgency)] = [
            ("appointment at", .today),
            ("meeting at", .today),
            ("call at", .today),
            ("deadline", .thisWeek),
            ("due by", .thisWeek),
            ("due on", .thisWeek),
            ("expires", .thisWeek),
            ("ends", .thisWeek),
            ("starts", .today),
            ("begins", .today),
            ("scheduled for", .today),
            ("planned for", .thisWeek)
        ]
        
        for (pattern, urgencyHint) in timeBasedPatterns {
            if lowercased.contains(pattern) {
                let timeReference = parseAdvancedTimeReference(from: sentence)
                
                // Only create reminder if we have a meaningful time reference
                if timeReference.isSpecific || !timeReference.originalText.isEmpty {
                    let cleanedText = cleanTimeBasedReminderText(sentence, pattern: pattern)
                    let urgency = determineUrgencyFromTimeReference(timeReference, sentence: sentence, hint: urgencyHint)
                    let confidence = calculateTimeBasedReminderConfidence(sentence: sentence, pattern: pattern, timeReference: timeReference)
                    
                    if confidence >= config.minConfidenceThreshold {
                        let reminder = ReminderItem(
                            text: cleanedText,
                            timeReference: timeReference,
                            urgency: urgency,
                            confidence: confidence
                        )
                        reminders.append(reminder)
                    }
                }
            }
        }
        
        return reminders
    }
    
    // MARK: - Event-Based Reminder Extraction
    
    private func extractEventBasedReminders(_ sentence: String) -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        let lowercased = sentence.lowercased()
        
        let eventPatterns: [(pattern: String, category: String)] = [
            ("birthday", "Birthday"),
            ("anniversary", "Anniversary"),
            ("vacation", "Vacation"),
            ("holiday", "Holiday"),
            ("conference", "Conference"),
            ("presentation", "Presentation"),
            ("interview", "Interview"),
            ("exam", "Exam"),
            ("test", "Test"),
            ("graduation", "Graduation"),
            ("wedding", "Wedding"),
            ("party", "Party"),
            ("dinner", "Dinner"),
            ("lunch", "Lunch"),
            ("breakfast", "Breakfast")
        ]
        
        for (pattern, category) in eventPatterns {
            if lowercased.contains(pattern) {
                let timeReference = parseAdvancedTimeReference(from: sentence)
                
                // Events should have some time context
                if !timeReference.originalText.isEmpty {
                    let cleanedText = "\(category): \(cleanEventReminderText(sentence))"
                    let urgency = determineUrgencyFromTimeReference(timeReference, sentence: sentence)
                    let confidence = calculateEventReminderConfidence(sentence: sentence, pattern: pattern, timeReference: timeReference)
                    
                    if confidence >= config.minConfidenceThreshold {
                        let reminder = ReminderItem(
                            text: cleanedText,
                            timeReference: timeReference,
                            urgency: urgency,
                            confidence: confidence
                        )
                        reminders.append(reminder)
                    }
                }
            }
        }
        
        return reminders
    }
    
    // MARK: - Recurring Reminder Extraction
    
    private func extractRecurringReminders(_ sentence: String) -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        let lowercased = sentence.lowercased()
        
        let recurringPatterns = [
            "every day", "daily", "every morning", "every evening",
            "every week", "weekly", "every monday", "every friday",
            "every month", "monthly", "every year", "annually",
            "regularly", "periodically", "routinely"
        ]
        
        for pattern in recurringPatterns {
            if lowercased.contains(pattern) {
                let cleanedText = cleanRecurringReminderText(sentence, pattern: pattern)
                let timeReference = ReminderItem.TimeReference(
                    originalText: pattern,
                    relativeTime: "Recurring: \(pattern)"
                )
                let urgency = ReminderItem.Urgency.later // Recurring items are usually lower urgency
                let confidence = calculateRecurringReminderConfidence(sentence: sentence, pattern: pattern)
                
                if confidence >= config.minConfidenceThreshold {
                    let reminder = ReminderItem(
                        text: cleanedText,
                        timeReference: timeReference,
                        urgency: urgency,
                        confidence: confidence
                    )
                    reminders.append(reminder)
                }
            }
        }
        
        return reminders
    }
    
    // MARK: - Advanced Time Reference Parsing
    
    private func parseAdvancedTimeReference(from sentence: String) -> ReminderItem.TimeReference {
        // Try to parse specific dates and times
        if let parsedDate = parseSpecificDateTime(sentence) {
            return ReminderItem.TimeReference(
                originalText: extractTimeString(from: sentence) ?? "Specific time",
                parsedDate: parsedDate,
                relativeTime: formatRelativeTime(from: parsedDate)
            )
        }
        
        // Parse relative time references
        if let relativeTime = parseRelativeTimeReference(sentence) {
            return ReminderItem.TimeReference(
                originalText: relativeTime.original,
                parsedDate: relativeTime.date,
                relativeTime: relativeTime.relative
            )
        }
        
        // Parse day-of-week references
        if let dayReference = parseDayOfWeekReference(sentence) {
            return ReminderItem.TimeReference(
                originalText: dayReference.original,
                parsedDate: dayReference.date,
                relativeTime: dayReference.relative
            )
        }
        
        // Parse time-of-day references
        if let timeOfDay = parseTimeOfDayReference(sentence) {
            return ReminderItem.TimeReference(
                originalText: timeOfDay,
                relativeTime: timeOfDay
            )
        }
        
        // Fallback to basic time pattern matching
        let basicTimeReference = extractBasicTimeReference(from: sentence)
        return ReminderItem.TimeReference(originalText: basicTimeReference ?? "No specific time")
    }
    
    private func parseSpecificDateTime(_ sentence: String) -> Date? {
        let dateDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(location: 0, length: sentence.count)
        
        if let match = dateDetector?.firstMatch(in: sentence, options: [], range: range),
           let date = match.date {
            return date
        }
        
        return nil
    }
    
    private func parseRelativeTimeReference(_ sentence: String) -> (original: String, date: Date?, relative: String)? {
        let lowercased = sentence.lowercased()
        let now = Date()
        let calendar = Calendar.current
        
        let relativePatterns: [(pattern: String, dateCalculation: (Date, Calendar) -> Date?, relative: String)] = [
            ("today", { date, _ in date }, "Today"),
            ("tomorrow", { date, cal in cal.date(byAdding: .day, value: 1, to: date) }, "Tomorrow"),
            ("yesterday", { date, cal in cal.date(byAdding: .day, value: -1, to: date) }, "Yesterday"),
            ("next week", { date, cal in cal.date(byAdding: .weekOfYear, value: 1, to: date) }, "Next week"),
            ("this week", { date, _ in date }, "This week"),
            ("next month", { date, cal in cal.date(byAdding: .month, value: 1, to: date) }, "Next month"),
            ("this month", { date, _ in date }, "This month"),
            ("in an hour", { date, cal in cal.date(byAdding: .hour, value: 1, to: date) }, "In 1 hour"),
            ("in two hours", { date, cal in cal.date(byAdding: .hour, value: 2, to: date) }, "In 2 hours"),
            ("in 30 minutes", { date, cal in cal.date(byAdding: .minute, value: 30, to: date) }, "In 30 minutes")
        ]
        
        for (pattern, calculation, relative) in relativePatterns {
            if lowercased.contains(pattern) {
                let calculatedDate = calculation(now, calendar)
                return (original: pattern, date: calculatedDate, relative: relative)
            }
        }
        
        return nil
    }
    
    private func parseDayOfWeekReference(_ sentence: String) -> (original: String, date: Date?, relative: String)? {
        let lowercased = sentence.lowercased()
        let calendar = Calendar.current
        let now = Date()
        
        let daysOfWeek = [
            ("monday", 2), ("tuesday", 3), ("wednesday", 4), ("thursday", 5),
            ("friday", 6), ("saturday", 7), ("sunday", 1)
        ]
        
        for (dayName, weekday) in daysOfWeek {
            if lowercased.contains(dayName) {
                if let nextDate = calendar.nextDate(after: now, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) {
                    let isThisWeek = calendar.isDate(nextDate, equalTo: now, toGranularity: .weekOfYear)
                    let relative = isThisWeek ? "This \(dayName.capitalized)" : "Next \(dayName.capitalized)"
                    return (original: dayName, date: nextDate, relative: relative)
                }
            }
        }
        
        return nil
    }
    
    private func parseTimeOfDayReference(_ sentence: String) -> String? {
        let lowercased = sentence.lowercased()
        
        let timeOfDayPatterns = [
            "this morning", "this afternoon", "this evening", "tonight",
            "tomorrow morning", "tomorrow afternoon", "tomorrow evening",
            "early morning", "late morning", "early afternoon", "late afternoon",
            "early evening", "late evening", "midnight", "noon"
        ]
        
        for pattern in timeOfDayPatterns {
            if lowercased.contains(pattern) {
                return pattern.capitalized
            }
        }
        
        // Parse specific times like "at 3pm", "by 5:30", etc.
        let timeRegexPatterns = [
            "at \\d{1,2}(:\\d{2})?(am|pm|AM|PM)?",
            "by \\d{1,2}(:\\d{2})?(am|pm|AM|PM)?",
            "\\d{1,2}(:\\d{2})?(am|pm|AM|PM)",
            "\\d{1,2} o'clock"
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
    
    private func extractBasicTimeReference(from sentence: String) -> String? {
        let lowercased = sentence.lowercased()
        
        let basicTimePatterns = [
            "soon", "later", "eventually", "sometime", "when possible",
            "before", "after", "during", "while", "until", "by then"
        ]
        
        for pattern in basicTimePatterns {
            if lowercased.contains(pattern) {
                return pattern.capitalized
            }
        }
        
        return nil
    }
    
    private func extractTimeString(from sentence: String) -> String? {
        // Extract the actual time string that was matched
        return parseTimeOfDayReference(sentence) ?? extractBasicTimeReference(from: sentence)
    }
    
    private func formatRelativeTime(from date: Date) -> String {
        let now = Date()
        let timeInterval = date.timeIntervalSince(now)
        
        if timeInterval < 3600 { // Less than 1 hour
            let minutes = Int(timeInterval / 60)
            return "In \(minutes) minutes"
        } else if timeInterval < 86400 { // Less than 1 day
            let hours = Int(timeInterval / 3600)
            return "In \(hours) hours"
        } else if timeInterval < 604800 { // Less than 1 week
            let days = Int(timeInterval / 86400)
            return "In \(days) days"
        } else {
            return dateFormatter.string(from: date)
        }
    }
    
    // MARK: - Urgency Determination
    
    private func determineUrgencyFromTimeReference(_ timeReference: ReminderItem.TimeReference, sentence: String, hint: ReminderItem.Urgency? = nil) -> ReminderItem.Urgency {
        let lowercased = sentence.lowercased()
        
        // Check for explicit urgency indicators
        if lowercased.contains("urgent") || lowercased.contains("asap") || lowercased.contains("immediately") || lowercased.contains("right now") {
            return .immediate
        }
        
        // Use parsed date for urgency
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
        
        // Use relative time for urgency
        if let relativeTime = timeReference.relativeTime?.lowercased() {
            if relativeTime.contains("today") || relativeTime.contains("this morning") || 
               relativeTime.contains("this afternoon") || relativeTime.contains("tonight") {
                return .today
            } else if relativeTime.contains("tomorrow") || relativeTime.contains("this week") {
                return .thisWeek
            }
        }
        
        // Use original text for urgency
        let originalLower = timeReference.originalText.lowercased()
        if originalLower.contains("today") || originalLower.contains("now") {
            return .today
        } else if originalLower.contains("tomorrow") || originalLower.contains("this week") {
            return .thisWeek
        }
        
        // Use hint if provided
        return hint ?? .later
    }
    
    // MARK: - Text Cleaning Methods
    
    private func cleanReminderText(_ sentence: String, pattern: String) -> String {
        var cleaned = sentence
        
        // Remove reminder prefixes
        let prefixesToRemove = [
            "remind me to", "remind me about", "don't forget to", "don't forget about",
            "remember to", "remember about", "make sure to", "make sure i",
            "note to self", "mental note", "i need to remember", "i should remember",
            "set reminder"
        ]
        
        for prefix in prefixesToRemove {
            if cleaned.lowercased().hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        
        return formatReminderString(cleaned)
    }
    
    private func cleanTimeBasedReminderText(_ sentence: String, pattern: String) -> String {
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatReminderString(cleaned)
    }
    
    private func cleanEventReminderText(_ sentence: String) -> String {
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatReminderString(cleaned)
    }
    
    private func cleanRecurringReminderText(_ sentence: String, pattern: String) -> String {
        var cleaned = sentence
        
        // Remove the recurring pattern from the text to avoid redundancy
        cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return formatReminderString(cleaned)
    }
    
    private func formatReminderString(_ text: String) -> String {
        var formatted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !formatted.isEmpty {
            // Capitalize first letter
            formatted = formatted.prefix(1).uppercased() + formatted.dropFirst()
            
            // Don't add punctuation to reminders as they're often fragments
        }
        
        return formatted
    }
    
    // MARK: - Confidence Calculation Methods
    
    private func calculateExplicitReminderConfidence(sentence: String, pattern: String, baseConfidence: Double) -> Double {
        var confidence = baseConfidence
        
        // Boost for time references
        if parseAdvancedTimeReference(from: sentence).isSpecific {
            confidence += 0.1
        }
        
        // Boost for specific objects
        if sentence.contains("about") || sentence.contains("to") {
            confidence += 0.05
        }
        
        return min(confidence, 1.0)
    }
    
    private func calculateTimeBasedReminderConfidence(sentence: String, pattern: String, timeReference: ReminderItem.TimeReference) -> Double {
        var confidence = 0.7 // Base confidence for time-based reminders
        
        // Boost for specific time references
        if timeReference.isSpecific {
            confidence += 0.2
        }
        
        // Boost for strong time patterns
        let strongPatterns = ["deadline", "due by", "appointment at", "meeting at"]
        if strongPatterns.contains(where: { sentence.lowercased().contains($0) }) {
            confidence += 0.1
        }
        
        return min(confidence, 1.0)
    }
    
    private func calculateEventReminderConfidence(sentence: String, pattern: String, timeReference: ReminderItem.TimeReference) -> Double {
        var confidence = 0.6 // Base confidence for event reminders
        
        // Boost for specific time references
        if timeReference.isSpecific {
            confidence += 0.2
        }
        
        // Boost for important events
        let importantEvents = ["birthday", "anniversary", "wedding", "graduation", "interview"]
        if importantEvents.contains(pattern) {
            confidence += 0.1
        }
        
        return min(confidence, 1.0)
    }
    
    private func calculateRecurringReminderConfidence(sentence: String, pattern: String) -> Double {
        var confidence = 0.5 // Base confidence for recurring reminders
        
        // Boost for strong recurring indicators
        let strongIndicators = ["every day", "daily", "weekly", "monthly"]
        if strongIndicators.contains(pattern) {
            confidence += 0.2
        }
        
        return min(confidence, 1.0)
    }
    
    // MARK: - Reminder Consolidation
    
    private func consolidateSimilarReminders(_ reminders: [ReminderItem]) -> [ReminderItem] {
        var consolidatedReminders: [ReminderItem] = []
        var processedIndices: Set<Int> = []
        
        for i in 0..<reminders.count {
            if processedIndices.contains(i) { continue }
            
            var currentReminder = reminders[i]
            var similarReminders: [ReminderItem] = []
            
            // Find similar reminders
            for j in (i+1)..<reminders.count {
                if processedIndices.contains(j) { continue }
                
                if areRemindersSimilar(currentReminder, reminders[j]) {
                    similarReminders.append(reminders[j])
                    processedIndices.insert(j)
                }
            }
            
            // Consolidate if we found similar reminders
            if !similarReminders.isEmpty {
                currentReminder = consolidateReminderGroup([currentReminder] + similarReminders)
            }
            
            consolidatedReminders.append(currentReminder)
            processedIndices.insert(i)
        }
        
        return consolidatedReminders
    }
    
    private func areRemindersSimilar(_ reminder1: ReminderItem, _ reminder2: ReminderItem) -> Bool {
        // Calculate text similarity
        let words1 = Set(reminder1.text.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(reminder2.text.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        let similarity = Double(intersection.count) / Double(union.count)
        
        // Also check if they refer to the same time
        let sameTimeReference = reminder1.timeReference.originalText.lowercased() == reminder2.timeReference.originalText.lowercased()
        
        return similarity > 0.7 || sameTimeReference
    }
    
    private func consolidateReminderGroup(_ reminders: [ReminderItem]) -> ReminderItem {
        // Use the highest confidence reminder as the base
        let bestReminder = reminders.max { $0.confidence < $1.confidence }!
        
        // Use the most urgent urgency
        let highestUrgency = reminders.min { $0.urgency.sortOrder > $1.urgency.sortOrder }!.urgency
        
        // Use the most specific time reference
        let bestTimeReference = reminders
            .map { $0.timeReference }
            .max { timeRef1, timeRef2 in
                let score1 = timeRef1.isSpecific ? 1 : 0
                let score2 = timeRef2.isSpecific ? 1 : 0
                return score1 < score2
            } ?? bestReminder.timeReference
        
        // Average the confidence
        let averageConfidence = reminders.map { $0.confidence }.reduce(0, +) / Double(reminders.count)
        
        return ReminderItem(
            text: bestReminder.text,
            timeReference: bestTimeReference,
            urgency: highestUrgency,
            confidence: averageConfidence
        )
    }
}