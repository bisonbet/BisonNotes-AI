import Foundation

enum SummaryExportFormatter {
    static func cleanMarkdown(_ text: String) -> String {
        var cleaned = text

        cleaned = cleaned.replacingOccurrences(of: "\\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\\r", with: "\n")

        cleaned = cleaned.replacingOccurrences(of: "^\"summary\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"content\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^\"text\"\\s*:\\s*\"", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\"\\s*$", with: "", options: .regularExpression)

        cleaned = cleaned.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

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

            if let headerRange = line.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let headerText = line[headerRange.upperBound...].trimmingCharacters(in: .whitespaces)
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

            if let bulletRange = line.range(of: "^[-*+]\\s+", options: .regularExpression) {
                line.replaceSubrange(bulletRange, with: "• ")
            }

            if let orderedRange = line.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                let prefix = String(line[orderedRange])
                let normalizedPrefix = prefix.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                line.replaceSubrange(orderedRange, with: normalizedPrefix)
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
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, options: []) else {
            return line
        }

        let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count))
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
