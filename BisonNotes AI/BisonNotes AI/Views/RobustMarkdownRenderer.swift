import SwiftUI
import Foundation

/// Renders markdown text from various AI services in a consistent way.
/// Cleans up common inconsistencies in LLM output before handing it to Apple's
/// markdown parser so headings, lists and emphasis render correctly.
@ViewBuilder
func unifiedRobustMarkdownText(_ text: String) -> some View {
    // Input validation: limit size to prevent memory issues
    let maxInputSize = 50_000 // 50KB limit
    let inputText = text.count > maxInputSize ? String(text.prefix(maxInputSize)) : text
    
    // Guard against empty input
    guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        Text("")
    }
    
    // Optimized cleaning using single regex replacements
    let cleaned = cleanMarkdownText(inputText)
    
    // Try to create an AttributedString from markdown; fall back to plain Text if parsing fails
    let resultView: some View = {
        if let attributed = try? AttributedString(
            markdown: cleaned,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attributed)
        } else {
            return Text(cleaned)
        }
    }()
    
    resultView.frame(maxWidth: .infinity, alignment: .leading)
}

/// Optimized text cleaning with improved logic and performance
private func cleanMarkdownText(_ text: String) -> String {
    var cleaned = text
    
    // Step 1: Normalize line endings and escape sequences with single combined regex
    let lineEndingPattern = #"(\\n|\\r|\r\n?)"#
    cleaned = cleaned.replacingOccurrences(of: lineEndingPattern, with: "\n", options: .regularExpression)
    
    // Step 2: Remove malformed JSON artifacts using more specific pattern
    // Matches various JSON summary patterns including nested quotes
    let jsonPattern = #""summary"\s*:?\s*"?([^"]*")?#
    cleaned = cleaned.replacingOccurrences(of: jsonPattern, with: "", options: .regularExpression)
    
    // Step 3: Preserve legitimate code blocks - only remove unpaired backticks
    cleaned = preserveCodeBlocks(cleaned)
    
    // Step 4: Standardize bullet points using single pass with regex (performance optimization)
    // Replace all bullet types with markdown * in a single operation
    let bulletPattern = #"\n([•\u{2022}-]) "#
    cleaned = cleaned.replacingOccurrences(of: bulletPattern, with: "\n* ", options: .regularExpression)
    
    // Handle leading bullets (start of text)
    if cleaned.hasPrefix("- ") || cleaned.hasPrefix("• ") || cleaned.hasPrefix("\u{2022} ") {
        // Find the prefix length (2 for most, could be different for unicode)
        let prefixLength = cleaned.hasPrefix("- ") ? 2 : 2
        cleaned = "* " + cleaned.dropFirst(prefixLength)
    }
    
    // Step 5: Remove isolated stray backticks (not part of code blocks)
    let strayBackticksPattern = #"(?<!\n```)\n?`{1,2}(?!\n|\w|`)"#
    cleaned = cleaned.replacingOccurrences(of: strayBackticksPattern, with: "", options: .regularExpression)
    
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Handles code block preservation more intelligently
private func preserveCodeBlocks(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var processedLines: [String] = []
    var codeBlockCount = 0
    var lastCodeBlockIndex: Int?
    
    // First pass: count and track code blocks
    for (index, line) in lines.enumerated() {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine == "```" || trimmedLine.hasPrefix("```") {
            codeBlockCount += 1
            lastCodeBlockIndex = index
        }
        processedLines.append(line)
    }
    
    // If we have an odd number of code block markers, remove the last unpaired one
    if codeBlockCount % 2 != 0, let lastIndex = lastCodeBlockIndex {
        let lastLine = processedLines[lastIndex]
        let trimmedLastLine = lastLine.trimmingCharacters(in: .whitespaces)
        
        // Only remove if it's a standalone ``` (not part of ```language syntax)
        if trimmedLastLine == "```" {
            processedLines.remove(at: lastIndex)
        }
    }
    
    return processedLines.joined(separator: "\n")
}
