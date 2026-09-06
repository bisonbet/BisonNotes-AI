//
//  TranscriptCleanupCoordinator.swift
//  BisonNotes AI
//
//  Pure orchestration around the optional S1-mini normalizer. The coordinator
//  owns language policy, token budgeting, validation, and all-or-nothing
//  assembly; the MLX service only owns model I/O.
//

import CryptoKit
import Foundation
import NaturalLanguage

struct TranscriptCleanupSourceSnapshot: Equatable, Sendable {
    let transcriptId: UUID?
    let lastModified: Date?
    let sourceFingerprint: String?

    init(transcript: TranscriptData?) {
        guard let transcript else {
            self.transcriptId = nil
            self.lastModified = nil
            self.sourceFingerprint = nil
            return
        }

        self.transcriptId = transcript.id
        self.lastModified = transcript.lastModified
        self.sourceFingerprint = Self.fingerprint(for: transcript)
    }

    func matches(_ transcript: TranscriptData?) -> Bool {
        guard let transcriptId else { return transcript == nil }
        guard let transcript,
              transcript.id == transcriptId,
              transcript.lastModified == lastModified else {
            return false
        }
        return Self.fingerprint(for: transcript) == sourceFingerprint
    }

    private static func fingerprint(for transcript: TranscriptData) -> String {
        var source = transcript.speakerMappings
            .sorted { $0.key < $1.key }
            .map { "mapping:\($0.key)=\($0.value)" }
            .joined(separator: "\u{1f}")

        for segment in transcript.segments {
            source += "\u{1e}\(segment.id.uuidString)\u{1f}"
            source += "\(segment.speaker)\u{1f}\(segment.text)\u{1f}"
            source += "\(segment.startTime)\u{1f}\(segment.endTime)\u{1f}"
            source += "\(segment.hasLeadingSpace)"
        }

        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct TranscriptCleanupCoordinator: Sendable {
    static let shared = TranscriptCleanupCoordinator()

    static let maxRenderedInputTokens = 1_000
    static let maxNewOutputTokens = 1_024
    /// Ceiling for one whole cleanup pass, however many segments it covers.
    static let maximumRunDuration: TimeInterval = 10 * 60
    private static let englishConfidenceThreshold = 0.9

    let normalizer: any TranscriptCleanupNormalizing
    private let availabilityProvider: @Sendable () -> TranscriptCleanupAvailability

    init(
        normalizer: any TranscriptCleanupNormalizing = MLXTranscriptCleanupService.shared,
        availabilityProvider: @escaping @Sendable () -> TranscriptCleanupAvailability = {
            TranscriptCleanupSettings.availability
        }
    ) {
        self.normalizer = normalizer
        self.availabilityProvider = availabilityProvider
    }

    /// Cleans all segments in memory and returns either a completely assembled
    /// result or the untouched input. No caller should persist individual
    /// segments returned from an in-flight operation.
    func clean(
        segments: [TranscriptSegment],
        configuration: TranscriptCleanupConfiguration
    ) async -> TranscriptCleanupResult {
        guard configuration.enabled else {
            return TranscriptCleanupResult(segments: segments, warning: nil, cleanedSegmentCount: 0)
        }

        guard !segments.isEmpty else {
            return TranscriptCleanupResult(segments: segments, warning: nil, cleanedSegmentCount: 0)
        }

        let availability = availabilityProvider()
        guard availability.isAvailable else {
            return TranscriptCleanupResult(
                segments: segments,
                warning: .unsupportedPlatform(
                    availability.explanation
                        ?? "Transcript cleanup is unavailable on this device."
                ),
                cleanedSegmentCount: 0
            )
        }

        let language = languageEligibility(
            segments: segments,
            trustedLanguageCode: configuration.languageCode,
            mode: configuration.mode
        )
        guard language.isEligible else {
            return TranscriptCleanupResult(
                segments: segments,
                warning: language.warning,
                cleanedSegmentCount: 0
            )
        }

        guard await normalizer.isReady else {
            return TranscriptCleanupResult(segments: segments, warning: .missingModel, cleanedSegmentCount: 0)
        }

        do {
            return try await MLXModelResourceCoordinator.shared.withExclusive {
                do {
                    let result = try await self.cleanEligibleSegments(segments)
                    await self.normalizer.releaseResources()
                    return result
                } catch {
                    await self.normalizer.releaseResources()
                    throw error
                }
            }
        } catch {
            return TranscriptCleanupResult(
                segments: segments,
                warning: Self.warning(for: error),
                cleanedSegmentCount: 0
            )
        }
    }

    /// A failed run always keeps the original segments untouched; only the
    /// reported warning differs. Keeping the mapping here rather than in a
    /// catch clause per case is what lets the permit and the normalizer be
    /// released in exactly one place.
    private static func warning(for error: Error) -> TranscriptCleanupWarning {
        if error is CancellationError { return .cancelled }
        switch error as? TranscriptCleanupNormalizerError {
        case .cancelled: return .cancelled
        case .modelUnavailable: return .missingModel
        case .templateUnavailable, .generationFailed, .invalidRequest: return .resourceFailure
        case .invalidOutput, .none: return .invalidOutput
        }
    }

    private func cleanEligibleSegments(
        _ segments: [TranscriptSegment]
    ) async throws -> TranscriptCleanupResult {
        var cleanedSegments: [TranscriptSegment] = []
        cleanedSegments.reserveCapacity(segments.count)
        var cleanedSegmentCount = 0

        // The per-generation watchdog in the service bounds one model call, not
        // the run. A long recording is hundreds of segments, and the whole run
        // holds the process-wide MLX permit and, on iOS, a finite background
        // task — so the run gets its own deadline and degrades to a resource
        // failure, which keeps the original transcript.
        let deadline = Date().addingTimeInterval(Self.maximumRunDuration)

        for segment in segments {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw TranscriptCleanupNormalizerError.generationFailed
            }

            let rawText = segment.text
            guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Empty turns retain their existing derived value. They are
                // never removed from the segment list, because that would
                // erase a speaker turn from the cleaned representation.
                cleanedSegments.append(segment)
                continue
            }

            let inputPieces = try await inputPieces(for: rawText)
            var normalizedPieces: [String] = []
            normalizedPieces.reserveCapacity(inputPieces.count)

            for piece in inputPieces {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    throw TranscriptCleanupNormalizerError.generationFailed
                }
                normalizedPieces.append(try await normalizedText(for: piece))
            }

            let normalizedText = normalizedPieces.joined(separator: " ")
            let cleanup = TranscriptSegmentCleanup(normalizedText: normalizedText)
            cleanedSegments.append(segment.withCleanup(cleanup))
            cleanedSegmentCount += 1
        }

        try Task.checkCancellation()

        return TranscriptCleanupResult(
            segments: cleanedSegments,
            warning: nil,
            cleanedSegmentCount: cleanedSegmentCount
        )
    }

    private func inputPieces(for rawText: String) async throws -> [String] {
        let fullRequestTokenCount = try await normalizer.renderedRequestTokenCount(for: rawText)
        guard fullRequestTokenCount > Self.maxRenderedInputTokens else {
            return [rawText]
        }

        // Each sentence and word is rendered exactly once and the fixed
        // chat-template overhead is measured once and added back. Re-rendering
        // the whole growing prefix per sentence made this quadratic in the
        // length of a single unpunctuated turn.
        let overhead = try await normalizer.renderedRequestTokenCount(for: "")
        let budget = Self.maxRenderedInputTokens - overhead
        guard budget > 0 else {
            throw TranscriptCleanupNormalizerError.invalidRequest
        }

        var pieces: [String] = []
        var pending: [String] = []
        var pendingCount = 0

        for sentence in sentenceParts(in: rawText) {
            let sentenceCount = try await unitTokenCount(sentence, overhead: overhead)
            if sentenceCount > budget {
                if !pending.isEmpty {
                    pieces.append(pending.joined(separator: " "))
                    pending = []
                    pendingCount = 0
                }
                pieces.append(
                    contentsOf: try await whitespacePieces(for: sentence, budget: budget, overhead: overhead)
                )
                continue
            }

            if pendingCount + sentenceCount > budget, !pending.isEmpty {
                pieces.append(pending.joined(separator: " "))
                pending = []
                pendingCount = 0
            }
            pending.append(sentence)
            pendingCount += sentenceCount
        }

        if !pending.isEmpty {
            pieces.append(pending.joined(separator: " "))
        }

        guard !pieces.isEmpty else {
            throw TranscriptCleanupNormalizerError.invalidRequest
        }
        return try await verifiedPieces(pieces, budget: budget, overhead: overhead)
    }

    /// Summed per-unit counts can undercount when the tokenizer merges across a
    /// join, and `normalize` rejects an over-budget request outright. Each
    /// assembled piece is therefore measured once against the real renderer,
    /// which stays linear in the number of pieces.
    private func verifiedPieces(
        _ pieces: [String],
        budget: Int,
        overhead: Int
    ) async throws -> [String] {
        var verified: [String] = []
        verified.reserveCapacity(pieces.count)
        for piece in pieces {
            if try await normalizer.renderedRequestTokenCount(for: piece) <= Self.maxRenderedInputTokens {
                verified.append(piece)
            } else {
                verified.append(
                    contentsOf: try await whitespacePieces(for: piece, budget: budget, overhead: overhead)
                )
            }
        }
        return verified
    }

    private func unitTokenCount(_ text: String, overhead: Int) async throws -> Int {
        max(try await normalizer.renderedRequestTokenCount(for: text) - overhead, 1)
    }

    private func whitespacePieces(
        for text: String,
        budget: Int,
        overhead: Int
    ) async throws -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        var pieces: [String] = []
        var pending: [String] = []
        var pendingCount = 0
        for word in words {
            let wordCount = try await unitTokenCount(word, overhead: overhead)
            guard wordCount <= budget else {
                throw TranscriptCleanupNormalizerError.invalidRequest
            }

            if pendingCount + wordCount > budget, !pending.isEmpty {
                pieces.append(pending.joined(separator: " "))
                pending = []
                pendingCount = 0
            }
            pending.append(word)
            pendingCount += wordCount
        }

        if !pending.isEmpty {
            pieces.append(pending.joined(separator: " "))
        }
        return pieces
    }

    /// Returns the validated, trimmed cleaned text for one input piece.
    ///
    /// Every generation is validated against the piece that produced it, so the
    /// absolute per-generation output cap is never applied to a concatenated
    /// total — a split retry whose halves each finished normally used to be
    /// rejected as invalid output once their token counts were summed.
    private func normalizedText(for piece: String) async throws -> String {
        let generation = try await normalizer.normalize(piece)
        try Task.checkCancellation()
        if generation.finishReason != .length {
            try validate(generation, originalText: piece)
            return generation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let retryPieces = try await whitespacePiecesForRetry(piece)
        guard retryPieces.count > 1 else {
            throw TranscriptCleanupNormalizerError.generationFailed
        }

        var parts: [String] = []
        for retryPiece in retryPieces {
            try Task.checkCancellation()
            let retry = try await normalizer.normalize(retryPiece)
            try Task.checkCancellation()
            try validate(retry, originalText: retryPiece)
            let text = retry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

    private func whitespacePiecesForRetry(_ text: String) async throws -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [text] }
        let midpoint = max(1, words.count / 2)
        let first = words[..<midpoint].joined(separator: " ")
        let second = words[midpoint...].joined(separator: " ")
        let pieces = [first, second]
        for piece in pieces {
            guard try await normalizer.renderedRequestTokenCount(for: piece) <= Self.maxRenderedInputTokens else {
                throw TranscriptCleanupNormalizerError.invalidRequest
            }
        }
        return pieces
    }

    private func validate(
        _ generation: TranscriptCleanupGeneration,
        originalText: String
    ) throws {
        guard generation.finishReason == .stop else {
            if generation.finishReason == .cancelled {
                throw TranscriptCleanupNormalizerError.cancelled
            }
            throw TranscriptCleanupNormalizerError.generationFailed
        }

        let normalizedText = generation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containsGeneratedControlToken(normalizedText),
              !containsGeneratedSpeakerLabel(normalizedText) else {
            throw TranscriptCleanupNormalizerError.invalidOutput
        }

        if normalizedText.isEmpty {
            guard isFillerOnly(originalText) else {
                throw TranscriptCleanupNormalizerError.invalidOutput
            }
        }

        let inputTokens = max(generation.inputTokenCount, 1)
        guard generation.outputTokenCount <= Self.maxNewOutputTokens else {
            throw TranscriptCleanupNormalizerError.invalidOutput
        }
        guard generation.outputTokenCount <= inputTokens * 2 + 32 else {
            throw TranscriptCleanupNormalizerError.invalidOutput
        }
    }

    private func containsGeneratedControlToken(_ text: String) -> Bool {
        text.range(
            of: #"(?is)<\|[^>]+\>|</?(?:think|assistant|system|user|s|bos|eos)\s*>|\[/?(?:INST|SYS)\]"#,
            options: .regularExpression
        ) != nil
    }

    private func containsGeneratedSpeakerLabel(_ text: String) -> Bool {
        text.range(
            of: #"(?im)^\s*(?:speaker(?:\s*[_-]?\s*\d+)?|unknown)\s*:\s+"#,
            options: .regularExpression
        ) != nil
    }

    private func isFillerOnly(_ text: String) -> Bool {
        let allowlist: Set<String> = ["um", "uh", "erm", "er", "hmm", "mm", "mhm", "like", "well", "you", "know"]
        let words = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { word in
                word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            }
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy { allowlist.contains($0) }
    }

    private func sentenceParts(in text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let sentence = String(text[substringRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { result.append(sentence) }
        }
        return result.isEmpty ? [text] : result
    }

    private struct LanguageEligibility {
        let isEligible: Bool
        let warning: TranscriptCleanupWarning?
    }

    private func languageEligibility(
        segments: [TranscriptSegment],
        trustedLanguageCode: String?,
        mode: TranscriptCleanupMode
    ) -> LanguageEligibility {
        // A positive assertion outranks any guess: the engine's own language
        // metadata, or the user explicitly asking for English cleanup. Both
        // short-circuit before the probes below, so one Latin clause or a run
        // of proper nouns can no longer veto a transcript the caller has
        // already identified as English.
        if let trustedLanguageCode {
            let normalizedCode = trustedLanguageCode
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
                .split(separator: "-")
                .first
                .map(String.init)
            if normalizedCode != "en" {
                return LanguageEligibility(isEligible: false, warning: .nonEnglish)
            }
            return LanguageEligibility(isEligible: true, warning: nil)
        }

        if case .manual(let confirmedEnglish) = mode, confirmedEnglish {
            return LanguageEligibility(isEligible: true, warning: nil)
        }

        // A whole-transcript language guess can hide a short foreign-language
        // turn inside an otherwise English transcript. Reject only segments
        // with enough signal for NaturalLanguage to make a high-confidence
        // determination, so names and short interjections do not block a
        // cleanup operation.
        guard !hasClearlyNonEnglishSegment(in: segments) else {
            return LanguageEligibility(isEligible: false, warning: .nonEnglish)
        }

        let text = segments.map(\.text).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let englishConfidence = hypotheses[.english] ?? 0
        let best = hypotheses.max { $0.value < $1.value }
        let nonEnglishConfidence = hypotheses
            .filter { $0.key != .english }
            .map(\.value)
            .max() ?? 0

        if englishConfidence >= Self.englishConfidenceThreshold,
           nonEnglishConfidence < (1 - Self.englishConfidenceThreshold) {
            return LanguageEligibility(isEligible: true, warning: nil)
        }

        if let best, best.key != .english, best.value >= Self.englishConfidenceThreshold {
            return LanguageEligibility(isEligible: false, warning: .nonEnglish)
        }

        return LanguageEligibility(isEligible: false, warning: .uncertainLanguage)
    }

    private func hasClearlyNonEnglishSegment(in segments: [TranscriptSegment]) -> Bool {
        segments.contains { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
            guard text.count >= 20, wordCount >= 4 else { return false }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
            guard let best = hypotheses.max(by: { $0.value < $1.value }) else { return false }
            return best.key != .english && best.value >= Self.englishConfidenceThreshold
        }
    }
}
