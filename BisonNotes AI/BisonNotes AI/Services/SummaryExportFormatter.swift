import Foundation
import UIKit

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

    // MARK: - Attributed Summary (structured export with bold, italic, headers)

    /// Export-friendly app name for header/footer branding
    static let exportAppName = "BisonNotes AI"

    /// Builds an attributed string from markdown with headers, bold, and italic preserved.
    /// Uses black/darkGray for export (readable on white).
    static func attributedSummary(
        for markdown: String,
        baseFontSize: CGFloat = 13,
        textColor: UIColor = .black
    ) -> NSAttributedString {
        let cleaned = cleanMarkdown(markdown)
        let lines = cleaned.components(separatedBy: .newlines)
        let result = NSMutableAttributedString()
        let baseFont = UIFont.systemFont(ofSize: baseFontSize)
        let boldFont = UIFont.boldSystemFont(ofSize: baseFontSize)
        let italicFont = UIFont.italicSystemFont(ofSize: baseFontSize)
        let boldItalicFont = UIFont.systemFont(ofSize: baseFontSize, weight: .semibold).with(traits: .traitItalic)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        paragraphStyle.paragraphSpacing = 8

        for (_, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if result.length > 0 {
                    result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: textColor]))
                }
                continue
            }

            // Skip image lines
            if trimmed.hasPrefix("![") { continue }

            // Headers: # ... ## ...
            let headerMatches = headerRegex.matches(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count))
            if let headerMatch = headerMatches.first, headerMatch.range.location == 0 {
                let matchStr = (trimmed as NSString).substring(with: headerMatch.range)
                let level = min(max(matchStr.filter { $0 == "#" }.count, 1), 6)
                let headerText = (trimmed as NSString).substring(from: headerMatch.range.length).trimmingCharacters(in: .whitespaces)
                let headerFontSize = baseFontSize + CGFloat(7 - level)  // 18pt for #, 17 for ##, ...
                let headerFont = UIFont.boldSystemFont(ofSize: headerFontSize)
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n", attributes: [.font: baseFont])) }
                let headerAttr = NSAttributedString(string: headerText + "\n", attributes: [
                    .font: headerFont,
                    .foregroundColor: textColor
                ])
                result.append(headerAttr)
                continue
            }

            // Blockquote
            var line = trimmed
            if line.hasPrefix(">") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                line = "\u{201C}\(line)\u{201D}"  // curly quotes
            }

            // Bullet
            let bulletMatches = bulletRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
            if let bulletMatch = bulletMatches.first, bulletMatch.range.location == 0 {
                let rest = (line as NSString).substring(from: bulletMatch.range.length)
                line = "\u{2022} " + rest  // bullet
            }

            // Ordered list
            let orderedMatches = orderedListRegex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
            if let orderedMatch = orderedMatches.first, orderedMatch.range.location == 0 {
                let prefix = (line as NSString).substring(with: orderedMatch.range)
                let normalized = orderedListSpaceRegex.stringByReplacingMatches(in: prefix, options: [], range: NSRange(location: 0, length: prefix.utf16.count), withTemplate: " ")
                line = normalized + (line as NSString).substring(from: orderedMatch.range.length)
            }

            line = replaceMarkdownLinks(in: line)

            let inline = parseInlineStyles(
                line,
                baseFont: baseFont,
                boldFont: boldFont,
                italicFont: italicFont,
                boldItalicFont: boldItalicFont,
                textColor: textColor
            )
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
            result.append(inline)
        }

        // Apply paragraph style to full result
        result.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func parseInlineStyles(
        _ line: String,
        baseFont: UIFont,
        boldFont: UIFont,
        italicFont: UIFont,
        boldItalicFont: UIFont,
        textColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var i = line.startIndex
        var bold = false
        var italic = false
        var runStart = i

        func flushRun() {
            guard runStart < i else { return }
            let s = String(line[runStart..<i])
            if s.isEmpty { return }
            let font: UIFont
            if bold && italic { font = boldItalicFont }
            else if bold { font = boldFont }
            else if italic { font = italicFont }
            else { font = baseFont }
            result.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: textColor]))
            runStart = i
        }

        while i < line.endIndex {
            let rest = line[i...]
            if rest.hasPrefix("**") {
                flushRun()
                bold.toggle()
                i = line.index(i, offsetBy: 2)
                runStart = i
                continue
            }
            if rest.hasPrefix("__") {
                flushRun()
                bold.toggle()
                i = line.index(i, offsetBy: 2)
                runStart = i
                continue
            }
            if rest.hasPrefix("*") || rest.hasPrefix("_") {
                flushRun()
                italic.toggle()
                i = line.index(after: i)
                runStart = i
                continue
            }
            if rest.hasPrefix("`") {
                flushRun()
                i = line.index(after: i)
                var end = i
                while end < line.endIndex && line[end] != "`" { end = line.index(after: end) }
                if end < line.endIndex {
                    let code = String(line[i..<end])
                    let mono = UIFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                    result.append(NSAttributedString(string: code, attributes: [.font: mono, .foregroundColor: textColor]))
                    i = line.index(after: end)
                    runStart = i
                    continue
                }
            }
            i = line.index(after: i)
        }
        flushRun()
        return result
    }
}

// UIFont trait helper
private extension UIFont {
    func with(traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
