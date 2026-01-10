//
//  OnDeviceLLMExtensions.swift
//  BisonNotes AI
//
//  Extensions for llama.cpp types and helper utilities
//  Adapted from OLMoE.swift project
//

import Foundation
import llama

// MARK: - LLMModel (OpaquePointer) Extensions

extension LLMModel {
    /// Get the vocabulary from this model
    private var vocab: OpaquePointer { llama_model_get_vocab(self)! }

    /// Token representing the end of sequence
    public var endToken: Token { llama_vocab_eos(vocab) }

    /// Token representing a newline character
    public var newLineToken: Token { llama_vocab_nl(vocab) }

    /// Determines whether Beginning-of-Sequence (BOS) token should be added
    public func shouldAddBOS() -> Bool {
        let addBOS = llama_vocab_get_add_bos(vocab)
        guard !addBOS else {
            return llama_vocab_type(vocab) == LLAMA_VOCAB_TYPE_SPM
        }
        return addBOS
    }

    /// Decodes a single token to string without handling multibyte characters
    public func decodeOnly(_ token: Token) -> String {
        var nothing: [CUnsignedChar] = []
        return decode(token, with: &nothing)
    }

    /// Decodes a token to string while handling multibyte characters
    public func decode(_ token: Token, with multibyteCharacter: inout [CUnsignedChar]) -> String {
        var bufferLength = 16
        var buffer: [CChar] = .init(repeating: 0, count: bufferLength)
        let actualLength = Int(llama_token_to_piece(vocab, token, &buffer, Int32(bufferLength), 0, false))
        guard 0 != actualLength else { return "" }
        if actualLength < 0 {
            bufferLength = -actualLength
            buffer = .init(repeating: 0, count: bufferLength)
            llama_token_to_piece(vocab, token, &buffer, Int32(bufferLength), 0, false)
        } else {
            buffer.removeLast(bufferLength - actualLength)
        }
        if multibyteCharacter.isEmpty, let decoded = String(cString: buffer + [0], encoding: .utf8) {
            return decoded
        }
        multibyteCharacter.append(contentsOf: buffer.map { CUnsignedChar(bitPattern: $0) })
        guard let decoded = String(data: .init(multibyteCharacter), encoding: .utf8) else { return "" }
        multibyteCharacter.removeAll(keepingCapacity: true)
        return decoded
    }

    /// Encodes text into model tokens
    public func encode(_ text: borrowing String) -> [Token] {
        let addBOS = true
        let count = Int32(text.cString(using: .utf8)!.count)
        var tokenCount = count + 1
        let cTokens = UnsafeMutablePointer<llama_token>.allocate(capacity: Int(tokenCount))
        defer { cTokens.deallocate() }
        tokenCount = llama_tokenize(vocab, text, count, cTokens, tokenCount, addBOS, false)
        let tokens = (0..<Int(tokenCount)).map { cTokens[$0] }

        if OnDeviceLLMFeatureFlags.verboseLogging {
            print("Encoded tokens: \(tokens)")
        }

        return tokens
    }
}

// MARK: - llama_batch Extensions

extension llama_batch {
    mutating func clear() {
        self.n_tokens = 0
    }

    mutating func add(_ token: Token, _ position: Int32, _ ids: [Int], _ logit: Bool) {
        let i = Int(self.n_tokens)
        self.token[i] = token
        self.pos[i] = position
        self.n_seq_id[i] = Int32(ids.count)
        if let seq_id = self.seq_id[i] {
            for (j, id) in ids.enumerated() {
                seq_id[j] = Int32(id)
            }
        }
        self.logits[i] = logit ? 1 : 0
        self.n_tokens += 1
    }
}

// MARK: - Text Sanitization Extensions

extension String {
    /// Sanitizes text from LLM output by fixing encoding issues and normalizing characters.
    /// Handles Unicode replacement characters, smart quotes, dashes, and other problematic characters.
    func sanitizedForDisplay() -> String {
        var result = self

        // Step 1: Remove Unicode replacement characters (U+FFFD) - these appear as ���
        // Try to infer what they should be based on context
        result = result.replacingOccurrences(of: "\u{FFFD}\u{FFFD}\u{FFFD}", with: "'") // Often corrupted apostrophe
        result = result.replacingOccurrences(of: "\u{FFFD}\u{FFFD}", with: "'")
        result = result.replacingOccurrences(of: "\u{FFFD}", with: "'") // Single replacement char often an apostrophe

        // Step 2: Normalize smart quotes and curly apostrophes to ASCII
        // Left/right single quotes → straight apostrophe
        result = result.replacingOccurrences(of: "\u{2018}", with: "'") // Left single quote '
        result = result.replacingOccurrences(of: "\u{2019}", with: "'") // Right single quote '
        result = result.replacingOccurrences(of: "\u{201A}", with: "'") // Single low-9 quote ‚
        result = result.replacingOccurrences(of: "\u{201B}", with: "'") // Single high-reversed-9 quote ‛

        // Left/right double quotes → straight double quote
        result = result.replacingOccurrences(of: "\u{201C}", with: "\"") // Left double quote "
        result = result.replacingOccurrences(of: "\u{201D}", with: "\"") // Right double quote "
        result = result.replacingOccurrences(of: "\u{201E}", with: "\"") // Double low-9 quote „
        result = result.replacingOccurrences(of: "\u{201F}", with: "\"") // Double high-reversed-9 quote ‟

        // Step 3: Normalize dashes
        result = result.replacingOccurrences(of: "\u{2014}", with: "-") // Em dash —
        result = result.replacingOccurrences(of: "\u{2013}", with: "-") // En dash –
        result = result.replacingOccurrences(of: "\u{2012}", with: "-") // Figure dash ‒
        result = result.replacingOccurrences(of: "\u{2010}", with: "-") // Hyphen ‐
        result = result.replacingOccurrences(of: "\u{2011}", with: "-") // Non-breaking hyphen ‑

        // Step 4: Normalize ellipsis and other punctuation
        result = result.replacingOccurrences(of: "\u{2026}", with: "...") // Ellipsis …
        result = result.replacingOccurrences(of: "\u{2022}", with: "-") // Bullet •
        result = result.replacingOccurrences(of: "\u{2023}", with: ">") // Triangular bullet ‣

        // Step 5: Normalize spaces
        result = result.replacingOccurrences(of: "\u{00A0}", with: " ") // Non-breaking space
        result = result.replacingOccurrences(of: "\u{2003}", with: " ") // Em space
        result = result.replacingOccurrences(of: "\u{2002}", with: " ") // En space
        result = result.replacingOccurrences(of: "\u{2009}", with: " ") // Thin space

        // Step 6: Remove any remaining control characters (except newlines and tabs)
        result = result.unicodeScalars.filter { scalar in
            // Keep printable characters, newlines, tabs, and carriage returns
            scalar.value >= 32 || scalar.value == 9 || scalar.value == 10 || scalar.value == 13
        }.map { String($0) }.joined()

        return result
    }

    /// Strips markdown formatting from text, returning plain text.
    /// Useful for displaying in contexts where markdown rendering isn't available.
    func strippingMarkdown() -> String {
        var result = self

        // Remove bold markers
        result = result.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "__(.+?)__", with: "$1", options: .regularExpression)

        // Remove italic markers
        result = result.replacingOccurrences(of: "\\*(.+?)\\*", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "_(.+?)_", with: "$1", options: .regularExpression)

        // Remove inline code
        result = result.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)

        // Remove link syntax [text](url) → text
        result = result.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)

        // Remove headers (# at start of line)
        result = result.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)

        return result
    }

    /// Sanitizes and strips markdown in one pass for plain text display
    func sanitizedPlainText() -> String {
        return self.sanitizedForDisplay().strippingMarkdown()
    }

    /// Removes wrapping double quotes from a string while preserving internal quotes.
    /// `"My Title"` → `My Title`
    /// `The "Thing" in question` → `The "Thing" in question` (unchanged)
    /// `Jim's stuff` → `Jim's stuff` (unchanged)
    func strippingWrappingQuotes() -> String {
        var result = self.trimmingCharacters(in: .whitespaces)

        // Check for wrapping double quotes
        if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count > 2 {
            result = String(result.dropFirst().dropLast())
        }

        // Also handle single quotes wrapping the whole string
        if result.hasPrefix("'") && result.hasSuffix("'") && result.count > 2 {
            // Only strip if it looks like wrapping quotes, not a contraction
            // Check if there are no other apostrophes inside (which would suggest it's not wrapping)
            let inner = String(result.dropFirst().dropLast())
            if !inner.contains("'") {
                result = inner
            }
        }

        return result
    }

    /// Full sanitization for title display: encoding fixes, markdown stripping, and quote removal
    func sanitizedForTitle() -> String {
        return self.sanitizedForDisplay().strippingMarkdown().strippingWrappingQuotes()
    }
}

// MARK: - String Regex Extensions

extension String {
    func matches(in content: String) throws -> [String] {
        let pattern = try NSRegularExpression(pattern: self)
        let range = NSRange(location: 0, length: content.utf16.count)
        let matches = pattern.matches(in: content, range: range)
        return matches.map { match in String(content[Range(match.range, in: content)!]) }
    }

    func hasMatch(in content: String) throws -> Bool {
        let pattern = try NSRegularExpression(pattern: self)
        let range = NSRange(location: 0, length: content.utf16.count)
        return pattern.firstMatch(in: content, range: range) != nil
    }

    func firstMatch(in content: String) throws -> String? {
        let pattern = try NSRegularExpression(pattern: self)
        let range = NSRange(location: 0, length: content.utf16.count)
        guard let match = pattern.firstMatch(in: content, range: range) else { return nil }
        return String(content[Range(match.range, in: content)!])
    }
}

// MARK: - URL Extensions for Model Storage

extension URL {
    /// Directory for storing downloaded LLM models
    /// Located in Application Support, excluded from iCloud backup
    public static var onDeviceLLMModelsDirectory: URL {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let url = paths[0].appendingPathComponent("OnDeviceLLMModels")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        // Exclude from iCloud backup
        do {
            var mutableURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            print("Error excluding from backup: \(error)")
        }

        return url
    }

    /// Check if file exists at this URL
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Get file size in bytes
    public var fileSize: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }
}
