//
//  ContentAnalyzer.swift
//  Audio Journal
//
//  Content analysis and classification system for improved summarization
//

import Foundation
import NaturalLanguage

// MARK: - Content Analyzer

class ContentAnalyzer {
    
    // MARK: - Content Classification
    
    static func classifyContent(_ text: String) -> ContentType {
        let cleanedText = preprocessText(text)
        let lowercased = cleanedText.lowercased()
        
        // Calculate scores for each content type with enhanced algorithms
        let meetingScore = calculateEnhancedMeetingScore(lowercased, originalText: text)
        let journalScore = calculateEnhancedJournalScore(lowercased, originalText: text)
        let technicalScore = calculateEnhancedTechnicalScore(lowercased, originalText: text)
        
        // Log classification scores for debugging
        print("🔍 ContentAnalyzer: Classification scores - Meeting: \(String(format: "%.3f", meetingScore)), Journal: \(String(format: "%.3f", journalScore)), Technical: \(String(format: "%.3f", technicalScore))")
        
        // Determine the highest scoring type with improved confidence thresholds
        let scores = [
            (ContentType.meeting, meetingScore),
            (ContentType.personalJournal, journalScore),
            (ContentType.technical, technicalScore)
        ]
        
        let bestMatch = scores.max { $0.1 < $1.1 }
        
        // Enhanced confidence threshold based on text length and content complexity
        let confidenceThreshold = calculateConfidenceThreshold(for: text)
        
        if let match = bestMatch, match.1 > confidenceThreshold {
            print("✅ ContentAnalyzer: Classified as \(match.0.rawValue) with confidence \(String(format: "%.3f", match.1))")
            return match.0
        }
        
        print("🏷️ ContentAnalyzer: Classified as General (best score: \(String(format: "%.3f", bestMatch?.1 ?? 0.0)) < threshold: \(String(format: "%.3f", confidenceThreshold)))")
        return .general
    }
    
    // MARK: - Enhanced Classification Methods
    
    static func classifyContentWithConfidence(_ text: String) -> (contentType: ContentType, confidence: Double) {
        let cleanedText = preprocessText(text)
        let lowercased = cleanedText.lowercased()
        
        let meetingScore = calculateEnhancedMeetingScore(lowercased, originalText: text)
        let journalScore = calculateEnhancedJournalScore(lowercased, originalText: text)
        let technicalScore = calculateEnhancedTechnicalScore(lowercased, originalText: text)
        
        let scores = [
            (ContentType.meeting, meetingScore),
            (ContentType.personalJournal, journalScore),
            (ContentType.technical, technicalScore)
        ]
        
        let bestMatch = scores.max { $0.1 < $1.1 }
        let confidenceThreshold = calculateConfidenceThreshold(for: text)
        
        if let match = bestMatch, match.1 > confidenceThreshold {
            return (match.0, match.1)
        }
        
        return (.general, bestMatch?.1 ?? 0.0)
    }
    
    static func getContentTypeRecommendations(_ text: String) -> [ContentType] {
        let cleanedText = preprocessText(text)
        let lowercased = cleanedText.lowercased()
        
        let meetingScore = calculateEnhancedMeetingScore(lowercased, originalText: text)
        let journalScore = calculateEnhancedJournalScore(lowercased, originalText: text)
        let technicalScore = calculateEnhancedTechnicalScore(lowercased, originalText: text)
        
        let scores = [
            (ContentType.meeting, meetingScore),
            (ContentType.personalJournal, journalScore),
            (ContentType.technical, technicalScore)
        ]
        
        // Return types ordered by score (descending)
        return scores
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
    
    // MARK: - Text Preprocessing
    
    static func preprocessText(_ text: String) -> String {
        // Remove extra whitespace and normalize
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        
        // Remove filler words and normalize contractions
        return normalized
            .replacingOccurrences(of: "um ", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "uh ", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "like ", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "you know ", with: "", options: .caseInsensitive)
    }
    
    // MARK: - Sentence Importance Scoring
    
    static func calculateSentenceImportance(_ sentence: String, in fullText: String) -> Double {
        let cleanSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSentence.isEmpty else { return 0.0 }
        
        var score: Double = 0.0
        let lowercased = cleanSentence.lowercased()
        
        // Length scoring (prefer medium-length sentences)
        let wordCount = cleanSentence.components(separatedBy: .whitespaces).count
        switch wordCount {
        case 8...25:
            score += 2.0 // Optimal length
        case 5...7, 26...35:
            score += 1.0 // Good length
        case 36...50:
            score += 0.5 // Too long but acceptable
        default:
            score += 0.1 // Too short or too long
        }
        
        // Key term scoring
        score += scoreKeyTerms(lowercased)
        
        // Position scoring (first and last sentences are often important)
        let sentences = fullText.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        
        if let index = sentences.firstIndex(where: { $0.contains(cleanSentence) }) {
            if index == 0 || index == sentences.count - 1 {
                score += 1.5 // First or last sentence bonus
            } else if index < 3 || index >= sentences.count - 3 {
                score += 1.0 // Near beginning or end bonus
            }
        }
        
        // Avoid repetitive content
        if isRepetitive(cleanSentence) {
            score *= 0.5
        }
        
        return score
    }
    
    // MARK: - Semantic Clustering
    
    static func clusterRelatedSentences(_ sentences: [String]) -> [[String]] {
        guard sentences.count > 1 else { return [sentences] }
        
        var clusters: [[String]] = []
        var processed: Set<Int> = []
        
        for i in 0..<sentences.count {
            if processed.contains(i) { continue }
            
            var cluster = [sentences[i]]
            processed.insert(i)
            
            // Find related sentences
            for j in (i+1)..<sentences.count {
                if processed.contains(j) { continue }
                
                if areSentencesRelated(sentences[i], sentences[j]) {
                    cluster.append(sentences[j])
                    processed.insert(j)
                }
            }
            
            clusters.append(cluster)
        }
        
        return clusters
    }
    
    // MARK: - Private Helper Methods
    
    private static func calculateMeetingScore(_ text: String) -> Double {
        var score: Double = 0.0
        
        let meetingKeywords = [
            "meeting", "agenda", "action item", "follow up", "next steps",
            "discuss", "decision", "agree", "disagree", "vote", "consensus",
            "attendees", "participants", "minutes", "schedule", "calendar",
            "presentation", "slides", "demo", "review", "feedback",
            "team", "group", "everyone", "all", "we should", "let's",
            "deadline", "timeline", "milestone", "project", "task assignment"
        ]
        
        let conversationIndicators = [
            "said", "mentioned", "asked", "replied", "responded", "suggested",
            "john said", "mary mentioned", "bob asked", "she said", "he mentioned",
            "speaker 1", "speaker 2", "speaker 3"
        ]
        
        // Score meeting-specific keywords
        for keyword in meetingKeywords {
            if text.contains(keyword) {
                score += 1.0
            }
        }
        
        // Score conversation indicators
        for indicator in conversationIndicators {
            if text.contains(indicator) {
                score += 1.5
            }
        }
        
        // Multiple speaker detection
        let speakerPatterns = ["speaker \\d+", "\\w+ said", "\\w+ mentioned", "\\w+ asked"]
        for pattern in speakerPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let matches = regex?.numberOfMatches(in: text, options: [], range: NSRange(location: 0, length: text.count)) ?? 0
            if matches > 1 {
                score += Double(matches) * 0.5
            }
        }
        
        return min(score / 10.0, 1.0) // Normalize to 0-1
    }
    
    private static func calculateJournalScore(_ text: String) -> Double {
        var score: Double = 0.0
        
        let journalKeywords = [
            "i feel", "i think", "i believe", "i remember", "i realized",
            "today", "yesterday", "this morning", "tonight", "this week",
            "my day", "my life", "my experience", "my thoughts", "my feelings",
            "grateful", "thankful", "blessed", "happy", "sad", "excited",
            "worried", "anxious", "peaceful", "content", "frustrated",
            "learned", "discovered", "noticed", "observed", "reflected"
        ]
        
        let personalPronouns = ["i ", "my ", "me ", "myself "]
        let emotionalWords = [
            "love", "hate", "fear", "hope", "dream", "wish", "want", "need",
            "amazing", "wonderful", "terrible", "awful", "beautiful", "peaceful"
        ]
        
        // Score personal/journal keywords
        for keyword in journalKeywords {
            if text.contains(keyword) {
                score += 1.0
            }
        }
        
        // Score personal pronouns (high frequency indicates personal content)
        for pronoun in personalPronouns {
            let count = text.components(separatedBy: pronoun).count - 1
            score += Double(count) * 0.3
        }
        
        // Score emotional language
        for word in emotionalWords {
            if text.contains(word) {
                score += 0.5
            }
        }
        
        return min(score / 15.0, 1.0) // Normalize to 0-1
    }
    
    private static func calculateTechnicalScore(_ text: String) -> Double {
        var score: Double = 0.0
        
        let technicalKeywords = [
            "algorithm", "function", "method", "class", "object", "variable",
            "database", "server", "client", "api", "endpoint", "request", "response",
            "code", "programming", "development", "software", "hardware",
            "system", "architecture", "framework", "library", "module",
            "bug", "error", "exception", "debug", "test", "unit test",
            "deployment", "production", "staging", "environment",
            "performance", "optimization", "scalability", "security"
        ]
        
        let technicalPatterns = [
            "\\w+\\.\\w+\\(\\)", // method calls like object.method()
            "\\w+\\[\\d+\\]", // array access
            "if\\s+\\w+", "for\\s+\\w+", "while\\s+\\w+", // control structures
            "\\d+\\.\\d+\\.\\d+", // version numbers
            "http[s]?://", // URLs
            "\\w+@\\w+\\.\\w+" // email addresses
        ]
        
        // Score technical keywords
        for keyword in technicalKeywords {
            if text.contains(keyword) {
                score += 1.0
            }
        }
        
        // Score technical patterns
        for pattern in technicalPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let matches = regex?.numberOfMatches(in: text, options: [], range: NSRange(location: 0, length: text.count)) ?? 0
            score += Double(matches) * 0.5
        }
        
        // Score technical jargon density
        let words = text.components(separatedBy: .whitespaces)
        let technicalWordCount = words.filter { word in
            technicalKeywords.contains { word.lowercased().contains($0) }
        }.count
        
        if words.count > 0 {
            let technicalDensity = Double(technicalWordCount) / Double(words.count)
            score += technicalDensity * 5.0
        }
        
        return min(score / 10.0, 1.0) // Normalize to 0-1
    }
    
    private static func scoreKeyTerms(_ text: String) -> Double {
        var score: Double = 0.0
        
        let importantTerms = [
            "important", "critical", "urgent", "priority", "key", "main", "primary",
            "need", "must", "should", "required", "necessary", "essential",
            "remember", "remind", "don't forget", "make sure", "ensure",
            "deadline", "due", "by", "before", "after", "when", "schedule",
            "call", "meet", "visit", "go", "come", "send", "email", "text",
            "buy", "get", "take", "bring", "pick up", "drop off", "return",
            "decision", "conclusion", "result", "outcome", "summary", "key point"
        ]
        
        let timeIndicators = [
            "today", "tomorrow", "yesterday", "next week", "next month",
            "this morning", "this afternoon", "this evening", "tonight",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december"
        ]
        
        // Score important terms
        for term in importantTerms {
            if text.contains(term) {
                score += 1.0
            }
        }
        
        // Score time indicators (often important for context)
        for indicator in timeIndicators {
            if text.contains(indicator) {
                score += 1.5
            }
        }
        
        return score
    }
    
    private static func isRepetitive(_ sentence: String) -> Bool {
        let words = sentence.lowercased().components(separatedBy: .whitespaces)
        let uniqueWords = Set(words)
        
        // If less than 60% of words are unique, consider it repetitive
        return Double(uniqueWords.count) / Double(words.count) < 0.6
    }
    
    private static func areSentencesRelated(_ sentence1: String, _ sentence2: String) -> Bool {
        let words1 = Set(sentence1.lowercased().components(separatedBy: .whitespaces))
        let words2 = Set(sentence2.lowercased().components(separatedBy: .whitespaces))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        // Jaccard similarity: if > 0.3, consider related
        let similarity = Double(intersection.count) / Double(union.count)
        return similarity > 0.3
    }
    
    // MARK: - Enhanced Classification Methods
    
    private static func calculateEnhancedMeetingScore(_ text: String, originalText: String) -> Double {
        var score = calculateMeetingScore(text) // Start with base score
        
        // Enhanced features for meeting detection
        
        // Multi-speaker detection with improved patterns
        let speakerPatterns = [
            "speaker \\d+", "\\w+ said", "\\w+ mentioned", "\\w+ asked", "\\w+ replied",
            "\\w+ suggested", "\\w+ agreed", "\\w+ disagreed", "\\w+ commented"
        ]
        
        var uniqueSpeakers = Set<String>()
        for pattern in speakerPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let matches = regex?.matches(in: originalText, options: [], range: NSRange(location: 0, length: originalText.count)) ?? []
            
            for match in matches {
                let speakerText = String(originalText[Range(match.range, in: originalText)!])
                uniqueSpeakers.insert(speakerText.lowercased())
            }
        }
        
        // Boost score for multiple speakers
        if uniqueSpeakers.count > 1 {
            score += Double(uniqueSpeakers.count) * 0.2
        }
        
        // Meeting structure indicators
        let meetingStructureIndicators = [
            "agenda", "minutes", "action items", "next steps", "follow up",
            "decision", "consensus", "vote", "motion", "seconded",
            "meeting adjourned", "meeting ended", "wrap up", "summary"
        ]
        
        for indicator in meetingStructureIndicators {
            if text.contains(indicator) {
                score += 0.5
            }
        }
        
        // Conversation flow indicators
        let conversationFlow = [
            "what do you think", "do you agree", "any questions", "any concerns",
            "let's discuss", "let's review", "let's go through", "any other business"
        ]
        
        for flow in conversationFlow {
            if text.contains(flow) {
                score += 0.3
            }
        }
        
        // Normalize and return
        return min(score, 1.0)
    }
    
    private static func calculateEnhancedJournalScore(_ text: String, originalText: String) -> Double {
        var score = calculateJournalScore(text) // Start with base score
        
        let wordCount = originalText.components(separatedBy: .whitespaces).count
        
        // Enhanced personal reflection indicators
        let reflectionIndicators = [
            "i realized", "i learned", "i discovered", "i noticed", "i observed",
            "looking back", "in retrospect", "thinking about", "reflecting on",
            "i feel like", "i think that", "i believe", "my experience"
        ]
        
        for indicator in reflectionIndicators {
            if text.contains(indicator) {
                score += 0.4
            }
        }
        
        // Emotional intensity scoring
        let emotionalIntensityWords = [
            "overwhelmed", "ecstatic", "devastated", "thrilled", "heartbroken",
            "elated", "furious", "terrified", "euphoric", "desperate"
        ]
        
        for word in emotionalIntensityWords {
            if text.contains(word) {
                score += 0.3
            }
        }
        
        // Personal pronoun density
        let personalPronouns = ["i ", "my ", "me ", "myself ", "mine "]
        var pronounCount = 0
        for pronoun in personalPronouns {
            pronounCount += originalText.lowercased().components(separatedBy: pronoun).count - 1
        }
        
        if wordCount > 0 {
            let pronounDensity = Double(pronounCount) / Double(wordCount)
            score += pronounDensity * 3.0
        }
        
        // Temporal references (common in journals)
        let temporalReferences = [
            "today", "yesterday", "this morning", "tonight", "this week",
            "last week", "next week", "this month", "this year"
        ]
        
        for reference in temporalReferences {
            if text.contains(reference) {
                score += 0.2
            }
        }
        
        // Normalize and return
        return min(score, 1.0)
    }
    
    private static func calculateEnhancedTechnicalScore(_ text: String, originalText: String) -> Double {
        var score = calculateTechnicalScore(text) // Start with base score
        
        let wordCount = originalText.components(separatedBy: .whitespaces).count
        
        // Enhanced technical pattern detection
        let enhancedTechnicalPatterns = [
            "\\w+\\.\\w+\\(\\)", // method calls
            "\\w+\\[\\d+\\]", // array access
            "if\\s+\\w+", "for\\s+\\w+", "while\\s+\\w+", "switch\\s+\\w+", // control structures
            "\\d+\\.\\d+\\.\\d+", // version numbers
            "http[s]?://[\\w\\-\\.]+", // URLs
            "\\w+@[\\w\\-\\.]+\\.[a-z]{2,}", // email addresses
            "\\w+://[\\w\\-\\.]+", // protocols
            "\\w+\\.\\w+\\.\\w+", // domain patterns
            "\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}", // IP addresses
            "\\w+\\s*=\\s*\\w+", // variable assignments
            "function\\s+\\w+", "def\\s+\\w+", "class\\s+\\w+" // function/class definitions
        ]
        
        for pattern in enhancedTechnicalPatterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            let matches = regex?.numberOfMatches(in: originalText, options: [], range: NSRange(location: 0, length: originalText.count)) ?? 0
            score += Double(matches) * 0.3
        }
        
        // Technical jargon density with expanded vocabulary
        let expandedTechnicalKeywords = [
            "algorithm", "function", "method", "class", "object", "variable", "parameter",
            "database", "server", "client", "api", "endpoint", "request", "response",
            "code", "programming", "development", "software", "hardware", "firmware",
            "system", "architecture", "framework", "library", "module", "package",
            "bug", "error", "exception", "debug", "test", "unit test", "integration test",
            "deployment", "production", "staging", "environment", "configuration",
            "performance", "optimization", "scalability", "security", "authentication",
            "encryption", "compression", "caching", "load balancing", "microservices",
            "container", "docker", "kubernetes", "cloud", "aws", "azure", "gcp"
        ]
        
        let technicalWordCount = originalText.lowercased().components(separatedBy: .whitespaces).filter { word in
            expandedTechnicalKeywords.contains { word.contains($0) }
        }.count
        
        if wordCount > 0 {
            let technicalDensity = Double(technicalWordCount) / Double(wordCount)
            score += technicalDensity * 4.0
        }
        
        // Code block indicators
        let codeBlockIndicators = [
            "```", "code block", "source code", "implementation", "example code"
        ]
        
        for indicator in codeBlockIndicators {
            if text.contains(indicator) {
                score += 0.5
            }
        }
        
        // Normalize and return
        return min(score, 1.0)
    }
    
    private static func calculateConfidenceThreshold(for text: String) -> Double {
        let wordCount = text.components(separatedBy: .whitespaces).count
        let sentences = extractSentences(from: text)
        
        // Base threshold
        var threshold = 0.3
        
        // Adjust based on text length (longer texts need higher confidence)
        if wordCount > 500 {
            threshold += 0.1
        } else if wordCount > 200 {
            threshold += 0.05
        }
        
        // Adjust based on sentence count (more complex content needs higher confidence)
        if sentences.count > 20 {
            threshold += 0.1
        } else if sentences.count > 10 {
            threshold += 0.05
        }
        
        // Adjust based on content complexity (technical content needs higher confidence)
        let technicalDensity = calculateTechnicalDensity(text)
        if technicalDensity > 0.1 {
            threshold += 0.1
        }
        
        return min(threshold, 0.6) // Cap at 0.6 to avoid being too strict
    }
    
    private static func calculateTechnicalDensity(_ text: String) -> Double {
        let technicalKeywords = [
            "algorithm", "function", "method", "class", "object", "variable",
            "database", "server", "client", "api", "endpoint", "code", "programming"
        ]
        
        let words = text.lowercased().components(separatedBy: .whitespaces)
        let technicalWordCount = words.filter { word in
            technicalKeywords.contains { word.contains($0) }
        }.count
        
        return words.count > 0 ? Double(technicalWordCount) / Double(words.count) : 0.0
    }
}

// MARK: - Text Processing Utilities

extension ContentAnalyzer {
    
    static func extractSentences(from text: String) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 } // Filter out very short fragments
        
        return sentences
    }
    
    static func extractKeyPhrases(from text: String, maxPhrases: Int = 10) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass])
        tagger.string = text
        
        var phrases: [String] = []
        let range = text.startIndex..<text.endIndex
        
        // Extract named entities
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
            if let tag = tag, tag != .other {
                let phrase = String(text[tokenRange])
                if phrase.count > 2 {
                    phrases.append(phrase)
                }
            }
            return true
        }
        
        // Extract important nouns and noun phrases
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, tokenRange in
            if tag == .noun {
                let phrase = String(text[tokenRange])
                if phrase.count > 3 && !phrases.contains(phrase) {
                    phrases.append(phrase)
                }
            }
            return true
        }
        
        // Sort by frequency and importance
        let phraseCounts = Dictionary(grouping: phrases, by: { $0 }).mapValues { $0.count }
        let sortedPhrases = phraseCounts.sorted { $0.value > $1.value }.map { $0.key }
        
        return Array(sortedPhrases.prefix(maxPhrases))
    }
    
    static func calculateReadabilityScore(_ text: String) -> Double {
        let sentences = extractSentences(from: text)
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        let syllables = words.reduce(0) { $0 + countSyllables(in: $1) }
        
        guard sentences.count > 0 && words.count > 0 else { return 0.0 }
        
        // Simplified Flesch Reading Ease Score
        let avgSentenceLength = Double(words.count) / Double(sentences.count)
        let avgSyllablesPerWord = Double(syllables) / Double(words.count)
        
        let score = 206.835 - (1.015 * avgSentenceLength) - (84.6 * avgSyllablesPerWord)
        
        // Normalize to 0-1 scale (higher is more readable)
        return max(0.0, min(1.0, score / 100.0))
    }
    
    private static func countSyllables(in word: String) -> Int {
        let vowels = CharacterSet(charactersIn: "aeiouAEIOU")
        let cleanWord = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        
        var syllableCount = 0
        var previousWasVowel = false
        
        for char in cleanWord {
            if let scalar = UnicodeScalar(String(char)) {
                let isVowel = vowels.contains(scalar)
                if isVowel && !previousWasVowel {
                    syllableCount += 1
                }
                previousWasVowel = isVowel
            }
        }
        
        // Handle silent 'e' and ensure minimum of 1 syllable
        if cleanWord.hasSuffix("e") && syllableCount > 1 {
            syllableCount -= 1
        }
        
        return max(1, syllableCount)
    }
}