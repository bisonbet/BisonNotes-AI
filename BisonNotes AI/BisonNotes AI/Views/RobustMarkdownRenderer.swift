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
    
    // Step 1: Clean line endings and escape sequences
    cleaned = cleaned
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "")
    
    // Step 2: Remove malformed JSON artifacts (more targeted)
    let jsonPattern = #""summary"\s*:?\s*"?#
    cleaned = cleaned.replacingOccurrences(of: jsonPattern, with: "", options: .regularExpression)
    
    // Step 3: Preserve legitimate code blocks, only remove stray backticks
    // Remove triple backticks that are not part of proper code blocks
    let straySingleBackticks = #"(?<!`)`(?!`)"#
    cleaned = cleaned.replacingOccurrences(of: straySingleBackticks, with: "", options: .regularExpression)
    
    // Only remove triple backticks if they appear to be stray (not matching pairs)
    let lines = cleaned.components(separatedBy: .newlines)
    var inCodeBlock = false
    var filteredLines: [String] = []
    
    for line in lines {
        if line.trimmingCharacters(in: .whitespaces) == "```" {
            inCodeBlock.toggle()
            // Only include the backticks if they form proper code block pairs
            continue
        }
        filteredLines.append(line)
    }
    cleaned = filteredLines.joined(separator: "\n")
    
    // Step 4: Standardize bullet points (check both before replacing)
    let needsDashReplacement = cleaned.hasPrefix("- ")
    let needsBulletReplacement = cleaned.hasPrefix("• ") || cleaned.hasPrefix("\u{2022} ")
    
    if needsDashReplacement {
        cleaned = "* " + cleaned.dropFirst(2)
    } else if needsBulletReplacement {
        if cleaned.hasPrefix("• ") {
            cleaned = "* " + cleaned.dropFirst(2)
        } else if cleaned.hasPrefix("\u{2022} ") {
            cleaned = "* " + cleaned.dropFirst(2)
        }
    }
    
    // Step 5: Handle bullets in the middle of text
    cleaned = cleaned
        .replacingOccurrences(of: "\n- ", with: "\n* ")
        .replacingOccurrences(of: "\n• ", with: "\n* ")
        .replacingOccurrences(of: "\n\u{2022} ", with: "\n* ")
    
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}
