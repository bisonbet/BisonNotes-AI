import SwiftUI

/// Renders markdown text from various AI services in a consistent way.
/// Cleans up common inconsistencies in LLM output before handing it to Apple's
/// markdown parser so headings, lists and emphasis render correctly.
@ViewBuilder
func unifiedRobustMarkdownText(_ text: String, aiService: String) -> some View {
    // Pre-process: replace escaped newlines, standardize bullets and remove code fences/JSON artefacts
    var cleaned = text
        .replacingOccurrences(of: "\\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "```", with: "")
        .replacingOccurrences(of: "\u2022", with: "*") // unicode bullet
        .replacingOccurrences(of: "•", with: "*")
        .replacingOccurrences(of: "\n- ", with: "\n* ")
        .replacingOccurrences(of: "\n• ", with: "\n* ")
        .replacingOccurrences(of: "\"summary\":", with: "")
        .replacingOccurrences(of: "\"summary\" :", with: "")
        .replacingOccurrences(of: "\"summary\"", with: "")

    // Some providers return leading "- " without newline
    if cleaned.hasPrefix("- ") { cleaned = "* " + cleaned.dropFirst(2) }
    if cleaned.hasPrefix("• ") { cleaned = "* " + cleaned.dropFirst(2) }

    // Try to create an AttributedString from markdown; fall back to plain Text if parsing fails
    if let attributed = try? AttributedString(
        markdown: cleaned,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
    ) {
        Text(attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
    } else {
        Text(cleaned)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
