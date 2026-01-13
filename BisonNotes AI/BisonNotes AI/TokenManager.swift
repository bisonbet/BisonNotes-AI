//
//  TokenManager.swift
//  Audio Journal
//
//  Token counting and chunking utilities for large transcript processing
//

import Foundation
import NaturalLanguage

// MARK: - Token Manager

class TokenManager {
    
    // MARK: - Configuration
    
    /// Default maximum tokens per chunk. This can be overridden when calling
    /// chunking functions for models with different context sizes.
    static let maxTokensPerChunk = 2048 // Legacy default for older models
    static let maxTokensForFinalSummary = 4096
    
    /// GPT-4.1 series context window (leaving 20% buffer for response)
    static let gpt41ContextWindow = Int(1_047_576 * 0.8) // ~838K tokens for all GPT-4.1 models
    
    /// Google AI Studio (Gemini) context window (leaving 20% buffer for response)
    static let googleAIStudioContextWindow = Int(1_000_000 * 0.8) // ~800K tokens for Gemini models
    
    static let estimatedTokensPerWord = 1.3 // Conservative estimate for English text
    
    // MARK: - Token Counting
    
    /// Estimate token count for a given text
    /// This is an approximation since we don't have access to the actual tokenizer
    static func estimateTokenCount(for text: String) -> Int {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        // Count tokens more accurately by considering punctuation and special characters
        var tokenCount = 0
        
        for word in words {
            // Base word token
            tokenCount += 1
            
            // Add tokens for punctuation and special characters
            let punctuationCount = word.filter { ".,!?;:'\"()[]{}".contains($0) }.count
            tokenCount += punctuationCount
            
            // Add tokens for numbers and special characters
            let specialCharCount = word.filter { "0123456789@#$%^&*+=<>/\\|".contains($0) }.count
            tokenCount += specialCharCount
        }
        
        // Add tokens for sentence boundaries and formatting
        let sentenceCount = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).count
        tokenCount += sentenceCount
        
        return max(tokenCount, 1) // Ensure at least 1 token
    }
    
    /// Get token count for text
    static func getTokenCount(_ text: String) -> Int {
        return estimateTokenCount(for: text)
    }
    
    // MARK: - Chunking
    
    /// Split text into chunks based on token count
    static func chunkText(_ text: String, maxTokens: Int = maxTokensPerChunk) -> [String] {
        return chunkTextWithOverlap(text, maxTokens: maxTokens, overlapTokens: 0, tokenizer: nil)
    }
    
    /// Split text into chunks with optional overlap and accurate tokenization
    /// - Parameters:
    ///   - text: The text to chunk
    ///   - maxTokens: Maximum tokens per chunk (excluding overlap)
    ///   - overlapTokens: Number of tokens to overlap between chunks (default: 100)
    ///   - tokenizer: Optional function to get accurate token count. If nil, uses estimation.
    /// - Returns: Array of text chunks with overlap preserved
    static func chunkTextWithOverlap(
        _ text: String,
        maxTokens: Int,
        overlapTokens: Int = 100,
        tokenizer: ((String) -> Int)? = nil
    ) -> [String] {
        // Use provided tokenizer or fall back to estimation
        let getTokenCount: (String) -> Int = tokenizer ?? { estimateTokenCount(for: $0) }
        
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var chunks: [String] = []
        var currentChunk: [String] = []
        var currentTokenCount = 0
        var overlapBuffer: [String] = [] // Sentences to include in overlap
        var overlapTokenCount = 0
        
        for sentence in sentences {
            let sentenceTokenCount = getTokenCount(sentence)
            
            // If adding this sentence would exceed the limit, start a new chunk
            if currentTokenCount + sentenceTokenCount > maxTokens && !currentChunk.isEmpty {
                // Finalize current chunk (including overlap from previous chunk)
                let chunkText = currentChunk.joined(separator: ". ") + "."
                chunks.append(chunkText)
                
                // Start new chunk with overlap from previous chunk
                // The overlap buffer contains the last N sentences that fit within overlapTokens
                currentChunk = overlapBuffer
                currentTokenCount = overlapTokenCount
                
                // Reset overlap buffer and start building new one
                overlapBuffer = []
                overlapTokenCount = 0
            }
            
            // Add sentence to current chunk
            currentChunk.append(sentence)
            currentTokenCount += sentenceTokenCount
            
            // Build overlap buffer: keep last sentences that fit within overlapTokens
            if overlapTokens > 0 {
                overlapBuffer.append(sentence)
                overlapTokenCount += sentenceTokenCount
                
                // Trim overlap buffer if it exceeds overlapTokens
                while overlapTokenCount > overlapTokens && overlapBuffer.count > 1 {
                    let removed = overlapBuffer.removeFirst()
                    overlapTokenCount -= getTokenCount(removed)
                }
            }
        }
        
        // Add remaining chunk
        if !currentChunk.isEmpty {
            let chunkText = currentChunk.joined(separator: ". ") + "."
            chunks.append(chunkText)
        }
        
        return chunks
    }
    
    /// Check if text needs chunking
    static func needsChunking(_ text: String, maxTokens: Int = maxTokensPerChunk) -> Bool {
        let tokenCount = estimateTokenCount(for: text)
        return tokenCount > maxTokens
    }
    
    // MARK: - Chunk Processing
    
    /// Process chunks and combine results
    static func processChunks<T>(
        _ chunks: [String],
        processor: @escaping (String) async throws -> T
    ) async throws -> [T] {
        var results: [T] = []
        
        for (index, chunk) in chunks.enumerated() {
            print("🔄 Processing chunk \(index + 1) of \(chunks.count) (\(getTokenCount(chunk)) tokens)")
            
            do {
                let result = try await processor(chunk)
                results.append(result)
            } catch {
                print("❌ Failed to process chunk \(index + 1): \(error)")
                throw error
            }
        }
        
        return results
    }
    
    /// Combine multiple summaries into a cohesive meta-summary using Ollama
    static func combineSummaries(
        _ summaries: [String],
        contentType: ContentType,
        service: OllamaService
    ) async throws -> String {
        guard !summaries.isEmpty else { return "" }

        // Join all summaries into one text block
        let combinedText = summaries.joined(separator: " ")

        // Generate meta-summary ensuring context limits are respected
        let metaSummary = try await generateMetaSummary(from: combinedText, service: service)

        // Note: Removed redundant labels since user is already in summary context
        return metaSummary
    }

    /// Recursively generate a meta-summary that fits within the model's context window
    private static func generateMetaSummary(from text: String, service: OllamaService) async throws -> String {
        let maxTokens = service.maxContextTokens

        // If text fits within context window, summarize directly
        if getTokenCount(text) <= maxTokens {
            return try await service.generateSummary(from: text)
        }

        // Otherwise, chunk the text and summarize each piece
        let chunks = chunkText(text, maxTokens: maxTokens)
        var intermediateSummaries: [String] = []

        for (index, chunk) in chunks.enumerated() {
            print("🔄 TokenManager: Processing meta-summary chunk \(index + 1) of \(chunks.count)")
            let summary = try await service.generateSummary(from: chunk)
            intermediateSummaries.append(summary)
            
            // Small delay between requests to prevent overwhelming the server
            if index < chunks.count - 1 {
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }

        // Recursively summarize the combined intermediate summaries
        let reducedText = intermediateSummaries.joined(separator: " ")
        return try await generateMetaSummary(from: reducedText, service: service)
    }
}

// MARK: - Chunked Processing Result

struct ChunkedProcessingResult {
    let summaries: [String]
    let allTasks: [TaskItem]
    let allReminders: [ReminderItem]
    let contentType: ContentType
    let totalChunks: Int
    let processingTime: TimeInterval

    func combinedSummary(using service: OllamaService) async throws -> String {
        return try await TokenManager.combineSummaries(summaries, contentType: contentType, service: service)
    }
    
    var deduplicatedTasks: [TaskItem] {
        // Remove duplicate tasks based on text similarity
        var uniqueTasks: [TaskItem] = []
        
        for task in allTasks {
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
    
    var deduplicatedReminders: [ReminderItem] {
        // Remove duplicate reminders based on text similarity
        var uniqueReminders: [ReminderItem] = []
        
        for reminder in allReminders {
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
    
    private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
        let words2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = words1.intersection(words2)
        let union = words1.union(words2)
        
        return union.isEmpty ? 0.0 : Double(intersection.count) / Double(union.count)
    }
} 