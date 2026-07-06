//
//  TranscriptCaptionTextCleaner.swift
//  BisonNotes AI
//
//  Converts caption formats into plain transcript text.
//

import Foundation

struct TranscriptCaptionTextCleaner {
    static func plainText(from captionText: String) -> String {
        if captionText.contains("<transcript") {
            let parser = YouTubeTranscriptTextParser()
            if let data = captionText.data(using: .utf8) {
                let xmlParser = XMLParser(data: data)
                xmlParser.delegate = parser
                xmlParser.shouldResolveExternalEntities = false
                if xmlParser.parse(), !parser.lines.isEmpty {
                    return parser.lines.joined(separator: "\n")
                }
            }
        }

        return plainTextFromCueLines(captionText.components(separatedBy: .newlines))
    }

    static func decodeHTMLEntities(in text: String) -> String {
        var decoded = text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        decodeNumericEntities(in: &decoded)
        return decoded
    }

    private static func plainTextFromCueLines(_ lines: [String]) -> String {
        var output: [String] = []
        var previousLine = ""

        for line in lines.map(cleanCaptionLine) {
            guard !line.isEmpty,
                  !isCaptionMetadataLine(line),
                  !line.contains("-->"),
                  !isTimestampOnlyLine(line),
                  Int(line) == nil else {
                continue
            }

            let transcriptLine = removingLeadingTimestamp(from: line)
            guard !transcriptLine.isEmpty else { continue }

            if transcriptLine != previousLine {
                output.append(transcriptLine)
                previousLine = transcriptLine
            }
        }

        return output.joined(separator: "\n")
    }

    private static func cleanCaptionLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTags = trimmed.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        return decodeHTMLEntities(in: withoutTags)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCaptionMetadataLine(_ line: String) -> Bool {
        line == "WEBVTT"
            || line.hasPrefix("Kind:")
            || line.hasPrefix("Language:")
            || line.hasPrefix("STYLE")
            || line.hasPrefix("REGION")
            || line.hasPrefix("NOTE")
    }

    private static func isTimestampOnlyLine(_ line: String) -> Bool {
        line.range(
            of: #"^(\d{1,2}:)?\d{1,2}:\d{2}([.,]\d{1,3})?$"#,
            options: .regularExpression
        ) != nil
    }

    private static func removingLeadingTimestamp(from line: String) -> String {
        line.replacingOccurrences(
            of: #"^(\d{1,2}:)?\d{1,2}:\d{2}([.,]\d{1,3})?\s+"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(in decoded: inout String) {
        let numericPattern = #"&#(x?[0-9A-Fa-f]+);"#
        guard let regex = try? NSRegularExpression(pattern: numericPattern) else {
            return
        }

        let range = NSRange(decoded.startIndex..., in: decoded)
        let matches = regex.matches(in: decoded, range: range).reversed()

        for match in matches {
            replaceNumericEntity(match, in: &decoded)
        }
    }

    private static func replaceNumericEntity(
        _ match: NSTextCheckingResult,
        in decoded: inout String
    ) {
        guard let fullRange = Range(match.range(at: 0), in: decoded),
              let valueRange = Range(match.range(at: 1), in: decoded) else {
            return
        }

        let value = String(decoded[valueRange])
        let scalarValue: UInt32?
        if value.lowercased().hasPrefix("x") {
            scalarValue = UInt32(value.dropFirst(), radix: 16)
        } else {
            scalarValue = UInt32(value, radix: 10)
        }

        if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
            decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
    }
}

final class YouTubeTranscriptTextParser: NSObject, XMLParserDelegate {
    private(set) var lines: [String] = []
    private var currentText = ""
    private var isInTextElement = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "text" {
            currentText = ""
            isInTextElement = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTextElement {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "text" else { return }
        let cleaned = TranscriptCaptionTextCleaner.decodeHTMLEntities(in: currentText)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            lines.append(cleaned)
        }
        currentText = ""
        isInTextElement = false
    }
}
