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
        print("🍎 EnhancedAppleIntelligenceEngine: Starting reminder extraction")
        
        let sentences = ContentAnalyzer.extractSentences(from: text)
        var allReminders: [ReminderItem] = []
        
        for sentence in sentences {
            if let reminder = extractReminderFromSentence(sentence) {
                allReminders.append(reminder)
            }
        }
        
        // Remove duplicates and sort by urgency
        let uniqueReminders = Array(Set(allReminders)).sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        
        print("🔔 Final reminder count: \(uniqueReminders.count)")
        
        return Array(uniqueReminders.prefix(config.maxReminders))
    }
    
    func extractTitles(from text: String) async throws -> [TitleItem] {
        print("🍎 EnhancedAppleIntelligenceEngine: Starting title extraction")
        
        let sentences = ContentAnalyzer.extractSentences(from: text)
        var allTitles: [TitleItem] = []
        
        for sentence in sentences {
            if let title = extractTitleFromSentence(sentence) {
                allTitles.append(title)
            }
        }
        
        // Remove duplicates and sort by confidence
        let uniqueTitles = Array(Set(allTitles)).sorted { $0.confidence > $1.confidence }
        
        print("📝 Final title count: \(uniqueTitles.count)")
        
        return Array(uniqueTitles.prefix(5)) // Limit to 5 titles
    }
    
    func classifyContent(_ text: String) async throws -> ContentType {
        print("🍎 EnhancedAppleIntelligenceEngine: Starting content classification")
        
        let sentences = ContentAnalyzer.extractSentences(from: text)
        
        // Analyze content patterns
        var meetingScore = 0
        var personalScore = 0
        var technicalScore = 0
        
        for sentence in sentences {
            let lowercased = sentence.lowercased()
            
            // Meeting indicators
            if lowercased.contains("meeting") || lowercased.contains("discussion") || 
               lowercased.contains("team") || lowercased.contains("agenda") ||
               lowercased.contains("presentation") || lowercased.contains("call") {
                meetingScore += 1
            }
            
            // Personal indicators
            if lowercased.contains("i feel") || lowercased.contains("my") || 
               lowercased.contains("personal") || lowercased.contains("experience") ||
               lowercased.contains("thought") || lowercased.contains("reflection") {
                personalScore += 1
            }
            
            // Technical indicators
            if lowercased.contains("code") || lowercased.contains("system") || 
               lowercased.contains("technical") || lowercased.contains("implementation") ||
               lowercased.contains("architecture") || lowercased.contains("development") {
                technicalScore += 1
            }
        }
        
        // Determine content type based on scores
        let totalSentences = sentences.count
        let meetingRatio = Double(meetingScore) / Double(totalSentences)
        let personalRatio = Double(personalScore) / Double(totalSentences)
        let technicalRatio = Double(technicalScore) / Double(totalSentences)
        
        print("📊 Content classification scores - Meeting: \(meetingRatio), Personal: \(personalRatio), Technical: \(technicalRatio)")
        
        if meetingRatio > 0.3 {
            return .meeting
        } else if personalRatio > 0.3 {
            return .personalJournal
        } else if technicalRatio > 0.3 {
            return .technical
        } else {
            return .general
        }
    }
    
    func processComplete(text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        print("🍎 EnhancedAppleIntelligenceEngine: Starting complete processing")
        
        // Check if we need to process in chunks
        let tokenCount = TokenManager.getTokenCount(text)
        
        if tokenCount > config.maxTokens {
            print("📦 Processing large text in chunks (\(tokenCount) tokens)")
            return try await processChunkedText(text)
        } else {
            print("📝 Processing single chunk (\(tokenCount) tokens)")
            return try await processSingleChunk(text)
        }
    }
    
    private func processSingleChunk(_ text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        // Always process sequentially: Summary first, then extract tasks/reminders/titles
        // This ensures the AI has full context when generating the summary
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Step 1: Generating contextual summary...", category: "EnhancedAppleIntelligenceEngine")
        }
        
        let summary = try await generateSummary(from: text, contentType: .general)
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Summary generated: \(summary.count) characters", category: "EnhancedAppleIntelligenceEngine")
        }
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Step 2: Extracting tasks from full transcript...", category: "EnhancedAppleIntelligenceEngine")
        }
        
        let tasks = try await extractTasks(from: text)
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Found \(tasks.count) tasks", category: "EnhancedAppleIntelligenceEngine")
        }
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Step 3: Extracting reminders from full transcript...", category: "EnhancedAppleIntelligenceEngine")
        }
        
        let reminders = try await extractReminders(from: text)
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Found \(reminders.count) reminders", category: "EnhancedAppleIntelligenceEngine")
        }
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Step 4: Extracting titles from full transcript...", category: "EnhancedAppleIntelligenceEngine")
        }
        
        let titles = try await extractTitles(from: text)
        
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Found \(titles.count) titles", category: "EnhancedAppleIntelligenceEngine")
        }
        
        let contentType = try await classifyContent(text)
        
        return (summary, tasks, reminders, titles, contentType)
    }
    
    private func processChunkedText(_ text: String) async throws -> (summary: String, tasks: [TaskItem], reminders: [ReminderItem], titles: [TitleItem], contentType: ContentType) {
        let startTime = Date()
        
        // Split text into chunks
        let chunks = TokenManager.chunkText(text)
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Split text into \(chunks.count) chunks", category: "EnhancedAppleIntelligenceEngine")
        }
        
        // Process each chunk
        var allSummaries: [String] = []
        var allTasks: [TaskItem] = []
        var allReminders: [ReminderItem] = []
        var allTitles: [TitleItem] = []
        var contentType: ContentType = .general
        
        for (index, chunk) in chunks.enumerated() {
            // Only log if verbose logging is enabled
            if PerformanceOptimizer.shouldLogEngineInitialization() {
                AppLogger.shared.verbose("Processing chunk \(index + 1) of \(chunks.count) (\(TokenManager.getTokenCount(chunk)) tokens)", category: "EnhancedAppleIntelligenceEngine")
            }
            
            do {
                let chunkResult = try await processSingleChunk(chunk)
                allSummaries.append(chunkResult.summary)
                allTasks.append(contentsOf: chunkResult.tasks)
                allReminders.append(contentsOf: chunkResult.reminders)
                allTitles.append(contentsOf: chunkResult.titles)
                
                // Use the first chunk's content type
                if index == 0 {
                    contentType = chunkResult.contentType
                }
                
            } catch {
                AppLogger.shared.error("Failed to process chunk \(index + 1): \(error)", category: "EnhancedAppleIntelligenceEngine")
                throw error
            }
        }
        
        // Combine results
        let combinedSummary = TokenManager.combineSummaries(allSummaries, contentType: contentType)
        
        // Deduplicate tasks, reminders, and titles
        let uniqueTasks = deduplicateTasks(allTasks)
        let uniqueReminders = deduplicateReminders(allReminders)
        let uniqueTitles = deduplicateTitles(allTitles)
        
        let processingTime = Date().timeIntervalSince(startTime)
        
        // Only log if verbose logging is enabled
        if PerformanceOptimizer.shouldLogEngineInitialization() {
            AppLogger.shared.verbose("Chunked processing completed in \(String(format: "%.2f", processingTime))s", category: "EnhancedAppleIntelligenceEngine")
            AppLogger.shared.verbose("Final summary: \(combinedSummary.count) characters", category: "EnhancedAppleIntelligenceEngine")
            AppLogger.shared.verbose("Final tasks: \(uniqueTasks.count)", category: "EnhancedAppleIntelligenceEngine")
            AppLogger.shared.verbose("Final reminders: \(uniqueReminders.count)", category: "EnhancedAppleIntelligenceEngine")
            AppLogger.shared.verbose("Final titles: \(uniqueTitles.count)", category: "EnhancedAppleIntelligenceEngine")
        }
        
        return (combinedSummary, uniqueTasks, uniqueReminders, uniqueTitles, contentType)
    }
    
    private func deduplicateTasks(_ tasks: [TaskItem]) -> [TaskItem] {
        var uniqueTasks: [TaskItem] = []
        
        for task in tasks {
            let isDuplicate = uniqueTasks.contains { existingTask in
                let similarity = calculateTextSimilarity(task.text, existingTask.text)
                return similarity > 0.8
            }
            
            if !isDuplicate {
                uniqueTasks.append(task)
            }
        }
        
        return Array(uniqueTasks.prefix(15)) // Limit to 15 tasks
    }
    
    private func deduplicateReminders(_ reminders: [ReminderItem]) -> [ReminderItem] {
        var uniqueReminders: [ReminderItem] = []
        
        for reminder in reminders {
            let isDuplicate = uniqueReminders.contains { existingReminder in
                let similarity = calculateTextSimilarity(reminder.text, existingReminder.text)
                return similarity > 0.8
            }
            
            if !isDuplicate {
                uniqueReminders.append(reminder)
            }
        }
        
        return Array(uniqueReminders.prefix(15)) // Limit to 15 reminders
    }
    
    private func deduplicateTitles(_ titles: [TitleItem]) -> [TitleItem] {
        var uniqueTitles: [TitleItem] = []
        
        for title in titles {
            let isDuplicate = uniqueTitles.contains { existingTitle in
                let similarity = calculateTextSimilarity(title.text, existingTitle.text)
                return similarity > 0.8
            }
            
            if !isDuplicate {
                uniqueTitles.append(title)
            }
        }
        
        return Array(uniqueTitles.prefix(5)) // Limit to 5 titles
    }
    
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
    
    private func isValidTranscriptContent(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check minimum length
        guard trimmed.count >= 50 else {
            print("⚠️ Transcript too short: \(trimmed.count) characters")
            return false
        }
        
        // Check for placeholder patterns
        let lowercased = trimmed.lowercased()
        let placeholderPatterns = [
            "transcription in progress",
            "processing audio",
            "please wait",
            "transcribing",
            "loading",
            "error",
            "failed to transcribe",
            "no audio detected",
            "silence detected",
            "aws transcription coming soon",
            "whisper-based transcription coming soon"
        ]
        
        for pattern in placeholderPatterns {
            if lowercased.contains(pattern) {
                print("⚠️ Transcript contains placeholder: \(pattern)")
                return false
            }
        }
        
        // Check word count
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0.count > 1 }
        
        guard words.count >= 10 else {
            print("⚠️ Insufficient word count: \(words.count) words")
            return false
        }
        
        print("✅ Transcript validated: \(words.count) words")
        return true
    }
    
    // MARK: - Advanced Summarization
    
    private func performAdvancedSummarization(text: String, contentType: ContentType) async throws -> String {
        print("🧠 Starting advanced summarization with full context analysis...")
        print("📝 Full transcript length: \(text.count) characters")
        
        // Work directly with the full transcript for better context
        let cleanedText = ContentAnalyzer.preprocessText(text)
        let wordCount = cleanedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        
        print("📊 Word count: \(wordCount) words")
        print("🏷️ Content type: \(contentType.rawValue)")
        
        // Create a comprehensive summary based on the full transcript
        let summary = createFullContextSummary(fullText: cleanedText, contentType: contentType, wordCount: wordCount)
        
        print("✅ Advanced summary generated: \(summary.count) characters")
        print("📄 Summary preview: \(summary.prefix(100))...")
        
        return summary
    }
    
    private func createFullContextSummary(fullText: String, contentType: ContentType, wordCount: Int) -> String {
        // Extract meaningful sentences from the full text
        let sentences = fullText.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 20 } // Only meaningful sentences
        
        print("📝 Found \(sentences.count) meaningful sentences")
        
        // Check if the first few sentences are ads and skip them
        let adStartPatterns = [
            "this message comes from", "sponsored by", "brought to you by", 
            "advertisement", "commercial", "capital one", "earn unlimited"
        ]
        
        var startIndex = 0
        for (index, sentence) in sentences.prefix(3).enumerated() {
            let lowercased = sentence.lowercased()
            if adStartPatterns.contains(where: { lowercased.contains($0) }) {
                startIndex = index + 1
                print("🚫 Skipping ad content at beginning, starting from sentence \(startIndex + 1)")
            }
        }
        
        let relevantSentences = Array(sentences.dropFirst(startIndex))
        print("📝 Using \(relevantSentences.count) sentences after filtering ads")
        
        // Determine summary approach based on content length and type
        if wordCount < 100 {
            return createVeryShortSummary(sentences: relevantSentences, fullText: fullText)
        } else if wordCount < 500 {
            return createShortSummary(sentences: relevantSentences, fullText: fullText, contentType: contentType)
        } else if wordCount < 2000 {
            return createMediumSummary(sentences: relevantSentences, fullText: fullText, contentType: contentType)
        } else {
            return createLongSummary(sentences: relevantSentences, fullText: fullText, contentType: contentType)
        }
    }
    
    private func createVeryShortSummary(sentences: [String], fullText: String) -> String {
        // For very short content, just clean up and present the main point
        if let firstSentence = sentences.first {
            return "## Summary\n\n*\(firstSentence)*"
        } else {
            // Fallback: take first 100 characters
            let preview = String(fullText.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "## Summary\n\n*\(preview)...*"
        }
    }
    
    private func createShortSummary(sentences: [String], fullText: String, contentType: ContentType) -> String {
        let topSentences = sentences.prefix(2)
        let summaryText = topSentences.joined(separator: "\n\n")
        
        switch contentType {
        case .meeting:
            return "## Meeting Summary\n\n\(summaryText)"
        case .personalJournal:
            return "## Personal Reflection\n\n\(summaryText)"
        case .technical:
            return "## Technical Discussion\n\n\(summaryText)"
        case .general:
            return "## Summary\n\n\(summaryText)"
        }
    }
    
    private func createMediumSummary(sentences: [String], fullText: String, contentType: ContentType) -> String {
        print("🎯 Creating medium summary from \(sentences.count) sentences")
        
        // Filter out likely ads, intros, and irrelevant content first
        let filteredSentences = filterRelevantSentences(sentences)
        print("📝 After filtering: \(filteredSentences.count) relevant sentences")
        
        guard !filteredSentences.isEmpty else {
            print("⚠️ No relevant sentences found after filtering")
            return "**Summary:** Unable to extract meaningful content from the transcript."
        }
        
        // Score sentences based on content relevance, not position
        let scoredSentences = filteredSentences.enumerated().map { index, sentence in
            var score = 1.0
            let lowercased = sentence.lowercased()
            
            // Boost sentences with substantive content indicators
            let substantiveWords = ["explains", "discusses", "describes", "analyzes", "explores", "examines", "reveals", "shows", "demonstrates", "argues", "suggests", "proposes", "concludes", "finds", "discovers"]
            for word in substantiveWords {
                if lowercased.contains(word) {
                    score += 2.0
                }
            }
            
            // Boost sentences with technical/content-specific terms
            let technicalWords = ["research", "study", "data", "analysis", "system", "process", "method", "approach", "technology", "development", "innovation", "solution"]
            for word in technicalWords {
                if lowercased.contains(word) {
                    score += 1.5
                }
            }
            
            // Boost sentences with key transition words that indicate important content
            let transitionWords = ["however", "therefore", "furthermore", "moreover", "additionally", "consequently", "meanwhile", "nevertheless"]
            for word in transitionWords {
                if lowercased.contains(word) {
                    score += 1.0
                }
            }
            
            // Penalize very short sentences (likely fragments)
            if sentence.components(separatedBy: .whitespaces).count < 8 {
                score *= 0.5
            }
            
            // Boost sentences from the middle portion (skip intro/outro)
            let totalSentences = filteredSentences.count
            let position = Double(index) / Double(totalSentences)
            if position > 0.2 && position < 0.8 {
                score += 1.0 // Middle content is often more substantive
            }
            
            return (sentence: sentence, score: score)
        }
        
        // Select top sentences based on score
        let targetCount = min(4, max(2, filteredSentences.count / 3))
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(targetCount)
            .map { $0.sentence }
        
        print("🎯 Selected \(topSentences.count) sentences for summary")
        for (index, sentence) in topSentences.enumerated() {
            print("📄 Sentence \(index + 1): \(sentence.prefix(100))...")
        }
        
        // Format summary with proper markdown bullet points for better readability
        let bulletPoints = topSentences.map { "• \($0)" }.joined(separator: "\n")
        
        let summary: String
        switch contentType {
        case .meeting:
            summary = "## Meeting Summary\n\n\(bulletPoints)"
        case .personalJournal:
            summary = "## Personal Reflection\n\n\(bulletPoints)"
        case .technical:
            summary = "## Technical Discussion\n\n\(bulletPoints)"
        case .general:
            summary = "## Summary\n\n\(bulletPoints)"
        }
        
        print("📄 Generated summary markdown:")
        print(summary)
        
        return summary
    }
    
    private func filterRelevantSentences(_ sentences: [String]) -> [String] {
        return sentences.filter { sentence in
            let lowercased = sentence.lowercased()
            
            // Filter out obvious ads and promotional content with more comprehensive patterns
            let adKeywords = [
                "capital one", "saver card", "earn unlimited", "cash back", "credit card", 
                "sponsored by", "brought to you by", "advertisement", "commercial", 
                "promo code", "discount", "offer expires", "terms and conditions", 
                "visit our website", "apply now", "limited time", "special offer",
                "call now", "act now", "don't miss out", "exclusive offer",
                "free trial", "no obligation", "money back guarantee", "satisfaction guaranteed",
                "best rates", "lowest prices", "save money", "earn rewards",
                "this message comes from", "this is a paid advertisement"
            ]
            
            for keyword in adKeywords {
                if lowercased.contains(keyword) {
                    print("🚫 Filtering out ad content: \(sentence.prefix(80))...")
                    return false
                }
            }
            
            // Filter out common intro/outro phrases with more patterns
            let introOutroKeywords = [
                "this is npr", "i'm your host", "thanks for listening", "that's all for today", 
                "coming up next", "stay tuned", "we'll be right back", "this program was made possible",
                "welcome to", "good morning", "good afternoon", "good evening",
                "today we're talking about", "in this episode", "on today's show",
                "that concludes", "thanks for joining us", "see you next time",
                "tune in next time", "don't forget to subscribe", "follow us on"
            ]
            
            for keyword in introOutroKeywords {
                if lowercased.contains(keyword) {
                    print("🚫 Filtering out intro/outro: \(sentence.prefix(80))...")
                    return false
                }
            }
            
            // Filter out very short sentences (likely fragments)
            if sentence.components(separatedBy: .whitespaces).count < 5 {
                print("🚫 Filtering out short sentence: \(sentence)")
                return false
            }
            
            // Filter out sentences that are mostly punctuation or numbers
            let meaningfulWords = sentence.components(separatedBy: .whitespaces)
                .filter { word in
                    let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                    return cleaned.count > 2 && !cleaned.isEmpty
                }
            
            if meaningfulWords.count < 3 {
                print("🚫 Filtering out low-content sentence: \(sentence)")
                return false
            }
            
            return true
        }
    }
    
    private func createLongSummary(sentences: [String], fullText: String, contentType: ContentType) -> String {
        // For long content, create a more structured summary
        let totalSentences = sentences.count
        let summaryLength = min(6, max(3, totalSentences / 5)) // 20% of sentences, min 3, max 6
        
        // Score sentences more comprehensively
        let scoredSentences = sentences.enumerated().map { index, sentence in
            var score = 1.0
            let position = Double(index) / Double(totalSentences)
            
            // Position scoring (beginning and end are important)
            if position < 0.2 || position > 0.8 {
                score += 2.0
            } else if position > 0.4 && position < 0.6 {
                score += 1.0 // Middle content
            }
            
            // Content scoring
            let lowercased = sentence.lowercased()
            let keyWords = ["important", "key", "main", "significant", "decided", "concluded", "learned", "realized", "summary", "overall", "finally", "in conclusion"]
            for word in keyWords {
                if lowercased.contains(word) {
                    score += 1.5
                }
            }
            
            // Length scoring (prefer medium-length sentences)
            let wordCount = sentence.components(separatedBy: .whitespaces).count
            if wordCount >= 8 && wordCount <= 25 {
                score += 1.0
            }
            
            return (sentence: sentence, score: score)
        }
        
        // Select top sentences
        let topSentences = scoredSentences
            .sorted { $0.score > $1.score }
            .prefix(summaryLength)
            .map { $0.sentence }
        
        // Format summary with proper markdown bullet points for better readability
        let bulletPoints = topSentences.map { "• \($0)" }.joined(separator: "\n")
        
        let summary: String
        switch contentType {
        case .meeting:
            summary = "## Meeting Summary\n\n\(bulletPoints)"
        case .personalJournal:
            summary = "## Personal Reflection\n\n\(bulletPoints)"
        case .technical:
            summary = "## Technical Discussion\n\n\(bulletPoints)"
        case .general:
            summary = "## Summary\n\n\(bulletPoints)"
        }
        
        print("📄 Generated long summary markdown:")
        print(summary)
        
        return summary
    }
    

    

    

    
    // MARK: - Advanced Task Extraction
    
    private func performAdvancedTaskExtraction(from text: String) async throws -> [TaskItem] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = text
        
        var tasks: [TaskItem] = []
        let sentences = ContentAnalyzer.extractSentences(from: text)
        
        print("🔍 Analyzing \(sentences.count) sentences for tasks...")
        
        for sentence in sentences {
            if let task = extractTaskFromSentence(sentence, using: tagger) {
                print("✅ Found task \(tasks.count + 1): \(task.text.prefix(80))... (confidence: \(String(format: "%.2f", task.confidence)))")
                tasks.append(task)
            }
        }
        
        // Deduplicate and sort by priority
        let uniqueTasks = Array(Set(tasks)).sorted { $0.priority.sortOrder < $1.priority.sortOrder }
        
        print("📋 Final task count: \(uniqueTasks.count)")
        
        return Array(uniqueTasks.prefix(config.maxTasks))
    }
    
    private func extractTaskFromSentence(_ sentence: String, using tagger: NLTagger) -> TaskItem? {
        let lowercased = sentence.lowercased()
        
        // First, filter out sentences that are clearly not task-related
        let nonTaskIndicators = [
            "this is", "that was", "we discussed", "we talked about", "the topic was",
            "according to", "research shows", "studies indicate", "experts say",
            "it's important to note", "it's worth mentioning", "interestingly",
            "this message comes from", "sponsored by", "advertisement"
        ]
        
        for indicator in nonTaskIndicators {
            if lowercased.contains(indicator) {
                return nil
            }
        }
        
        // Task indicators with their patterns - more specific and contextual
        let taskPatterns: [(pattern: String, category: TaskItem.TaskCategory, priority: TaskItem.Priority, confidence: Double)] = [
            // High confidence patterns
            ("need to call", .call, .medium, 0.9),
            ("have to call", .call, .high, 0.9),
            ("must call", .call, .high, 0.9),
            ("should call", .call, .medium, 0.8),
            ("will call", .call, .medium, 0.8),
            
            ("need to meet", .meeting, .medium, 0.9),
            ("have to meet", .meeting, .high, 0.9),
            ("schedule meeting", .meeting, .medium, 0.9),
            ("meeting with", .meeting, .medium, 0.8),
            ("appointment with", .meeting, .medium, 0.8),
            
            ("need to buy", .purchase, .medium, 0.9),
            ("have to buy", .purchase, .high, 0.9),
            ("must purchase", .purchase, .high, 0.9),
            ("should order", .purchase, .medium, 0.8),
            
            ("need to email", .email, .medium, 0.9),
            ("have to email", .email, .high, 0.9),
            ("send email", .email, .medium, 0.9),
            ("email to", .email, .medium, 0.8),
            ("message to", .email, .low, 0.7),
            
            ("need to research", .research, .medium, 0.9),
            ("have to investigate", .research, .high, 0.9),
            ("look into", .research, .medium, 0.8),
            ("find out about", .research, .medium, 0.8),
            ("study", .research, .low, 0.7),
            
            ("need to go", .travel, .medium, 0.9),
            ("have to visit", .travel, .medium, 0.9),
            ("travel to", .travel, .medium, 0.8),
            ("visit", .travel, .medium, 0.8),
            
            ("doctor appointment", .health, .high, 0.9),
            ("medical appointment", .health, .high, 0.9),
            ("see the doctor", .health, .high, 0.9),
            ("health check", .health, .medium, 0.8),
            
            // Medium confidence patterns
            ("call", .call, .medium, 0.6),
            ("phone", .call, .medium, 0.6),
            ("meeting", .meeting, .medium, 0.6),
            ("appointment", .meeting, .medium, 0.6),
            ("purchase", .purchase, .medium, 0.6),
            ("order", .purchase, .low, 0.6),
            ("email", .email, .low, 0.6),
            ("message", .email, .low, 0.6),
            ("research", .research, .low, 0.6),
            ("investigate", .research, .medium, 0.6),
            ("travel", .travel, .medium, 0.6),
            ("visit", .travel, .medium, 0.6),
            ("health", .health, .medium, 0.6)
        ]
        
        var bestTask: (task: TaskItem, confidence: Double)? = nil
        
        for (pattern, category, basePriority, baseConfidence) in taskPatterns {
            if lowercased.contains(pattern) {
                // Extract the task text
                let taskText = cleanTaskText(sentence, pattern: pattern)
                
                // Skip if task text is too short or generic
                if taskText.count < 10 || taskText.lowercased().contains("this") || taskText.lowercased().contains("that") {
                    continue
                }
                
                // Extract time reference
                let timeReference = extractTimeReference(from: sentence)
                
                // Adjust priority based on urgency indicators
                let priority = adjustPriorityForUrgency(basePriority, in: sentence)
                
                // Calculate confidence based on pattern strength and context
                let confidence = calculateTaskConfidence(sentence: sentence, pattern: pattern, baseConfidence: baseConfidence)
                
                // Only consider tasks with reasonable confidence
                guard confidence >= 0.8 else { continue }
                
                let task = TaskItem(
                    text: taskText,
                    priority: priority,
                    timeReference: timeReference,
                    category: category,
                    confidence: confidence
                )
                
                // Keep the task with highest confidence
                if bestTask == nil || confidence > bestTask!.confidence {
                    bestTask = (task, confidence)
                }
            }
        }
        
        return bestTask?.task
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
    
    private func calculateTaskConfidence(sentence: String, pattern: String, baseConfidence: Double) -> Double {
        var confidence = baseConfidence
        let lowercased = sentence.lowercased()
        
        // Boost confidence for strong action verbs
        let strongVerbs = ["must", "need", "have to", "should", "will", "going to"]
        for verb in strongVerbs {
            if lowercased.contains(verb) {
                confidence += 0.1
                break // Only count the strongest verb once
            }
        }
        
        // Boost confidence for specific objects/targets
        let specificIndicators = ["with", "about", "for", "to", "regarding", "concerning"]
        for indicator in specificIndicators {
            if lowercased.contains(indicator) {
                confidence += 0.05
                break
            }
        }
        
        // Boost confidence for time references
        if extractTimeReference(from: sentence) != nil {
            confidence += 0.1
        }
        
        // Boost confidence for specific names or entities
        let namePatterns = ["mr.", "mrs.", "dr.", "professor", "director", "manager", "ceo"]
        for pattern in namePatterns {
            if lowercased.contains(pattern) {
                confidence += 0.1
                break
            }
        }
        
        // Penalize for generic or vague content
        let vagueWords = ["something", "anything", "everything", "nothing", "this", "that", "it", "thing"]
        for word in vagueWords {
            if lowercased.contains(word) {
                confidence -= 0.1
                break
            }
        }
        
        // Penalize for very short task descriptions
        if sentence.components(separatedBy: .whitespaces).count < 8 {
            confidence -= 0.2
        }
        
        // Penalize for sentences that are too long (likely not actionable)
        if sentence.components(separatedBy: .whitespaces).count > 30 {
            confidence -= 0.2
        }
        
        return max(0.0, min(confidence, 1.0))
    }
    
    // MARK: - Advanced Reminder Extraction
    
    private func performAdvancedReminderExtraction(from text: String) async throws -> [ReminderItem] {
        var reminders: [ReminderItem] = []
        let sentences = ContentAnalyzer.extractSentences(from: text)
        
        print("🔍 Analyzing \(sentences.count) sentences for reminders...")
        
        for sentence in sentences {
            if let reminder = extractReminderFromSentence(sentence) {
                print("✅ Found reminder \(reminders.count + 1): \(reminder.text.prefix(80))... (confidence: \(String(format: "%.2f", reminder.confidence)))")
                reminders.append(reminder)
            }
        }
        
        // Deduplicate and sort by urgency
        let uniqueReminders = Array(Set(reminders)).sorted { $0.urgency.sortOrder < $1.urgency.sortOrder }
        
        print("🔔 Final reminder count: \(uniqueReminders.count)")
        
        return Array(uniqueReminders.prefix(config.maxReminders))
    }
    
    private func extractReminderFromSentence(_ sentence: String) -> ReminderItem? {
        let lowercased = sentence.lowercased()
        
        // First, filter out sentences that are clearly not reminder-related
        let nonReminderIndicators = [
            "this is", "that was", "we discussed", "we talked about", "the topic was",
            "according to", "research shows", "studies indicate", "experts say",
            "it's important to note", "it's worth mentioning", "interestingly",
            "this message comes from", "sponsored by", "advertisement"
        ]
        
        for indicator in nonReminderIndicators {
            if lowercased.contains(indicator) {
                return nil
            }
        }
        
        let reminderIndicators = [
            "remind me", "don't forget", "remember to", "make sure to",
            "deadline", "due", "appointment", "meeting at", "call at",
            "schedule", "book", "reserve", "set up", "arrange"
        ]
        
        let hasReminderIndicator = reminderIndicators.contains { lowercased.contains($0) }
        let timeRef = extractTimeReference(from: sentence)
        
        // Must have either a reminder indicator or a specific time reference
        guard hasReminderIndicator || (timeRef != nil && timeRef != "No specific time") else { 
            return nil 
        }
        
        let timeReference = timeRef != nil ? 
            ReminderItem.TimeReference(originalText: timeRef!) : 
            ReminderItem.TimeReference(originalText: "No specific time")
        let urgency = determineUrgency(from: sentence, timeReference: timeReference)
        let confidence = calculateReminderConfidence(sentence: sentence, hasIndicator: hasReminderIndicator, hasTime: timeRef != nil)
        
        // Only return reminders with good confidence
        guard confidence >= 0.8 else { return nil }
        
        let cleanedText = cleanReminderText(sentence)
        
        // Skip if reminder text is too short or generic
        guard cleanedText.count >= 5 && 
              !cleanedText.lowercased().contains("reminder") && // Avoid meta references
              !cleanedText.lowercased().contains("task") else {
            return nil
        }
        
        return ReminderItem(
            text: cleanedText,
            timeReference: timeReference,
            urgency: urgency,
            confidence: confidence
        )
    }
    
    private func extractTitleFromSentence(_ sentence: String) -> TitleItem? {
        let lowercased = sentence.lowercased()
        
        // First, filter out sentences that are clearly not title-related
        let nonTitleIndicators = [
            "this is", "that was", "we discussed", "we talked about", "the topic was",
            "according to", "research shows", "studies indicate", "experts say",
            "it's important to note", "it's worth mentioning", "interestingly",
            "this message comes from", "sponsored by", "advertisement"
        ]
        
        for indicator in nonTitleIndicators {
            if lowercased.contains(indicator) {
                return nil
            }
        }
        
        let titleIndicators = [
            "main topic", "key theme", "primary focus", "central issue",
            "main point", "key decision", "important outcome", "major milestone",
            "primary question", "central problem", "main objective"
        ]
        
        let hasTitleIndicator = titleIndicators.contains { lowercased.contains($0) }
        let sentenceLength = sentence.count
        let hasGoodLength = sentenceLength >= 10 && sentenceLength <= 100
        
        // Must have either a title indicator or be a good candidate sentence
        guard hasTitleIndicator || (hasGoodLength && sentenceLength > 20) else { 
            return nil 
        }
        
        let category = determineTitleCategory(from: sentence)
        let confidence = calculateTitleConfidence(sentence: sentence, hasIndicator: hasTitleIndicator, hasGoodLength: hasGoodLength)
        
        // Only return titles with good confidence
        guard confidence >= 0.7 else { return nil }
        
        let cleanedText = cleanTitleText(sentence)
        
        // Skip if title text is too short or generic
        guard cleanedText.count >= 5 && 
              !cleanedText.lowercased().contains("title") && // Avoid meta references
              !cleanedText.lowercased().contains("reminder") &&
              !cleanedText.lowercased().contains("task") else {
            return nil
        }
        
        return TitleItem(
            text: cleanedText,
            confidence: confidence,
            category: category
        )
    }
    
    private func determineTitleCategory(from sentence: String) -> TitleItem.TitleCategory {
        let lowercased = sentence.lowercased()
        
        if lowercased.contains("meeting") || lowercased.contains("discussion") || 
           lowercased.contains("team") || lowercased.contains("agenda") {
            return .meeting
        } else if lowercased.contains("i feel") || lowercased.contains("my") || 
                  lowercased.contains("personal") || lowercased.contains("experience") {
            return .personal
        } else if lowercased.contains("code") || lowercased.contains("system") || 
                  lowercased.contains("technical") || lowercased.contains("implementation") {
            return .technical
        } else {
            return .general
        }
    }
    
    private func calculateTitleConfidence(sentence: String, hasIndicator: Bool, hasGoodLength: Bool) -> Double {
        var confidence = 0.5
        
        if hasIndicator {
            confidence += 0.3
        }
        
        if hasGoodLength {
            confidence += 0.2
        }
        
        // Bonus for sentences that start with key words
        let keyStartWords = ["the", "a", "an", "key", "main", "primary", "important"]
        let firstWord = sentence.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        if keyStartWords.contains(firstWord) {
            confidence += 0.1
        }
        
        return min(confidence, 1.0)
    }
    
    private func cleanTitleText(_ text: String) -> String {
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Main topic:", with: "")
            .replacingOccurrences(of: "Key theme:", with: "")
            .replacingOccurrences(of: "Primary focus:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            confidence += 0.3
        }
        
        let lowercased = sentence.lowercased()
        
        // Boost for specific reminder words
        let strongIndicators = ["deadline", "due", "appointment", "meeting", "call", "schedule", "book"]
        for indicator in strongIndicators {
            if lowercased.contains(indicator) {
                confidence += 0.2
                break
            }
        }
        
        // Boost for specific time references
        let specificTimeWords = ["today", "tomorrow", "tonight", "this morning", "this afternoon", "this evening", "next week"]
        for timeWord in specificTimeWords {
            if lowercased.contains(timeWord) {
                confidence += 0.1
                break
            }
        }
        
        // Boost for specific names or entities
        let namePatterns = ["mr.", "mrs.", "dr.", "professor", "director", "manager", "ceo"]
        for pattern in namePatterns {
            if lowercased.contains(pattern) {
                confidence += 0.1
                break
            }
        }
        
        // Penalize for generic or vague content
        let vagueWords = ["something", "anything", "everything", "nothing", "this", "that", "it", "thing"]
        for word in vagueWords {
            if lowercased.contains(word) {
                confidence -= 0.1
                break
            }
        }
        
        // Penalize for very short descriptions
        if sentence.components(separatedBy: .whitespaces).count < 8 {
            confidence -= 0.2
        }
        
        // Penalize for sentences that are too long (likely not actionable)
        if sentence.components(separatedBy: .whitespaces).count > 30 {
            confidence -= 0.2
        }
        
        return max(0.0, min(confidence, 1.0))
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