//
//  TextSanitization.swift
//  BisonNotes AI
//
//  Shared display helpers for model and user-authored text.
//

import Foundation

extension String {
    /// Normalizes common encoding and punctuation artifacts before display.
    func sanitizedForDisplay() -> String {
        var result = self

        result = result.replacingOccurrences(of: "\u{FFFD}\u{FFFD}\u{FFFD}", with: "'")
        result = result.replacingOccurrences(of: "\u{FFFD}\u{FFFD}", with: "'")
        result = result.replacingOccurrences(of: "\u{FFFD}", with: "'")

        let quoteReplacements: [String: String] = [
            "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
            "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\""
        ]
        for (source, replacement) in quoteReplacements {
            result = result.replacingOccurrences(of: source, with: replacement)
        }

        let punctuationReplacements: [String: String] = [
            "\u{2014}": "-", "\u{2013}": "-", "\u{2012}": "-", "\u{2010}": "-", "\u{2011}": "-",
            "\u{2026}": "...", "\u{2022}": "-", "\u{2023}": ">",
            "\u{00A0}": " ", "\u{2003}": " ", "\u{2002}": " ", "\u{2009}": " "
        ]
        for (source, replacement) in punctuationReplacements {
            result = result.replacingOccurrences(of: source, with: replacement)
        }

        return result.unicodeScalars
            .filter { scalar in
                scalar.value >= 32 || scalar.value == 9 || scalar.value == 10 || scalar.value == 13
            }
            .map(String.init)
            .joined()
    }

    /// Strips common Markdown formatting when rich text rendering is unavailable.
    func strippingMarkdown() -> String {
        var result = self
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        // CommonMark does not treat an underscore inside a word as emphasis, so
        // these require a non-word character on both sides. Without that,
        // get_user_name loses its underscores and reads as getusername — and
        // transcripts of technical discussions are full of such identifiers.
        result = result.replacingOccurrences(
            of: "(?<![A-Za-z0-9_])__(.+?)__(?![A-Za-z0-9_])",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "(?<![A-Za-z0-9_])_(.+?)_(?![A-Za-z0-9_])",
            with: "$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
        return result.replacingOccurrences(of: "(?m)^#{1,6}\\s*", with: "", options: .regularExpression)
    }

    /// Normalizes text and strips Markdown in one pass for plain display.
    func sanitizedPlainText() -> String {
        sanitizedForDisplay().strippingMarkdown()
    }

    /// Removes matching quote characters around an entire string.
    func strippingWrappingQuotes() -> String {
        var result = trimmingCharacters(in: .whitespaces)

        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        if result.hasPrefix("'") && result.hasSuffix("'") && result.count > 2 {
            let inner = String(result.dropFirst().dropLast())
            if !inner.contains("'") {
                result = inner
            }
        }

        return result
    }

    /// Normalizes display text, removes Markdown, and strips wrapping quotes.
    func sanitizedForTitle() -> String {
        sanitizedForDisplay().strippingMarkdown().strippingWrappingQuotes()
    }
}
