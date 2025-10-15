import Foundation

enum SummaryExportFormatter {
    // MARK: - Cached Regex Patterns
    
    private static let jsonPrefixRegex = try! NSRegularExpression(pattern: "^\"summary\"\\s*:\\s*\"", options: [])
    private static let jsonContentRegex = try! NSRegularExpression(pattern: "^\"content\"\\s*:\\s*\"", options: [])
    private static let jsonTextRegex = try! NSRegularExpression(pattern: "^\"text\"\\s*:\\s*\"", options: [])
    private static let jsonSuffixRegex = try! NSRegularExpression(pattern: "\"\\s*$", options: [])
    private static let multipleNewlinesRegex = try! NSRegularExpression(pattern: "\n{3,}", options: [])
    private static let headerRegex = try! NSRegularExpression(pattern: "^#{1,6}\\s+", options: [])
    private static let bulletRegex = try! NSRegularExpression(pattern: "^[-*+]\\s+", options: [])
    private static let orderedListRegex = try! NSRegularExpression(pattern: "^\\d+\\.\\s+", options: [])
    private static let orderedListSpaceRegex = try! NSRegularExpression(pattern: "\\s+", options: [])
    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, options: [])
    static func cleanMarkdown(_ text: String) -> String {
        var cleaned = text

        // Replace literal newline sequences
        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\n")

        // Use cached regex patterns for JSON cleanup
        let range = NSRange(location: 0, length: cleaned.utf16.count)
        cleaned = jsonPrefixRegex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        cleaned = jsonContentRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: "")
        cleaned = jsonTextRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: "")
        cleaned = jsonSuffixRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: "")

        // Clean up multiple newlines
        cleaned = multipleNewlinesRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.utf16.count), withTemplate: "\n\n")

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func flattenMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var pendingBlank = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                pendingBlank = !result.isEmpty
                continue
            }

            var line = trimmed

            if line.hasPrefix("![") {
                continue
            }

            // Check for headers using cached regex
            let headerMatches = headerRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
            if let headerMatch = headerMatches.first {
                let headerText = String(line.dropFirst(headerMatch.range.length)).trimmingCharacters(in: .whitespaces)
                if result.last?.isEmpty == false {
                    result.append("")
                }
                result.append(headerText.uppercased())
                result.append("")
                pendingBlank = false
                continue
            }

            if line.hasPrefix(">") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
                line = "“\(line)”"
            }

            // Handle bullet points using cached regex
            let bulletMatches = bulletRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
            if let bulletMatch = bulletMatches.first {
                let range = Range(bulletMatch.range, in: line)!
                line.replaceSubrange(range, with: "• ")
            }

            // Handle ordered lists using cached regex
            let orderedMatches = orderedListRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
            if let orderedMatch = orderedMatches.first {
                let range = Range(orderedMatch.range, in: line)!
                let prefix = String(line[range])
                let normalizedPrefix = orderedListSpaceRegex.stringByReplacingMatches(in: prefix, options: [], range: NSRange(location: 0, length: prefix.utf16.count), withTemplate: " ")
                line.replaceSubrange(range, with: normalizedPrefix)
            }

            line = replaceMarkdownLinks(in: line)

            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")
            line = line.replacingOccurrences(of: "*", with: "")
            line = line.replacingOccurrences(of: "_", with: "")
            line = line.replacingOccurrences(of: "`", with: "")

            if pendingBlank && (result.last?.isEmpty == false) {
                result.append("")
            }

            result.append(line)
            pendingBlank = false
        }

        while result.last?.isEmpty == true {
            result.removeLast()
        }

        return result.joined(separator: "\n")
    }

    private static func replaceMarkdownLinks(in line: String) -> String {
        let matches = markdownLinkRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
        if matches.isEmpty {
            return line
        }

        let mutable = NSMutableString(string: line)
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                  let textRange = Range(match.range(at: 1), in: line),
                  let urlRange = Range(match.range(at: 2), in: line) else {
                continue
            }

            let text = String(line[textRange])
            let url = String(line[urlRange])
            let replacement = "\(text) (\(url))"
            mutable.replaceCharacters(in: match.range, with: replacement)
        }

        return String(mutable)
    }
}
