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

struct TranscriptCleanupSourceSnapshot: Codable, Equatable, Sendable {
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
    /// S1-mini can drop an isolated ASR fragment even when it is not filler.
    /// Retaining a short source fragment is safer than rejecting the entire
    /// cleanup pass; longer substantive empty output remains invalid.
    private static let maxConservativeFallbackWords = 3
    private static let englishConfidenceThreshold = 0.9
    /// How long one run may hold the process-wide MLX permit. A run that
    /// reaches it stops with `.timeLimitReached`, keeping its checkpoint, so a
    /// waiting summary gets the permit; the next run resumes where it stopped.
    static let maximumRunDuration: TimeInterval = 10 * 60
    /// Pure hesitation sounds. A segment made only of these cleans to empty
    /// text without a model call — the outcome the model is already allowed to
    /// produce for them. Deliberately narrower than `isFillerOnly`'s list:
    /// words like "you", "well" or "like" — and "mhm", "mm" or "hmm", which
    /// are often a yes — can be a complete spoken answer.
    private static let hesitationWords: Set<String> = ["um", "uh", "erm", "er", "umm", "uhm"]

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

    /// The checks that need no model: whether cleanup is wanted, possible on
    /// this device, downloaded, and applicable to this transcript's language.
    /// Callers that save the raw transcript first use this to report a
    /// blocking warning immediately and to queue only runnable work.
    func preflight(
        segments: [TranscriptSegment],
        configuration: TranscriptCleanupConfiguration
    ) async -> TranscriptCleanupPreflight {
        guard configuration.enabled, !segments.isEmpty else { return .notNeeded }

        let availability = availabilityProvider()
        guard availability.isAvailable else {
            return .blocked(
                .unsupportedPlatform(
                    availability.explanation ?? "Transcript cleanup is unavailable on this device."
                )
            )
        }

        let language = languageEligibility(
            segments: segments,
            trustedLanguageCode: configuration.languageCode,
            mode: configuration.mode
        )
        guard language.isEligible else {
            return .blocked(language.warning ?? .uncertainLanguage)
        }

        guard await normalizer.isReady else { return .blocked(.missingModel) }
        return .ready
    }

    /// Cleans every segment it can and returns the assembled result.
    ///
    /// A piece the model cannot clean keeps its original text and the run
    /// continues; only a run that cleaned nothing reports the original
    /// transcript untouched. Finished pieces are written to `checkpoint` as
    /// they complete, so an interrupted run resumes instead of starting over.
    /// No caller should persist individual segments from an in-flight run.
    func clean(
        segments: [TranscriptSegment],
        configuration: TranscriptCleanupConfiguration,
        checkpoint: (any TranscriptCleanupCheckpointing)? = nil,
        progress: (@Sendable (TranscriptCleanupProgress) -> Void)? = nil
    ) async -> TranscriptCleanupResult {
        switch await preflight(segments: segments, configuration: configuration) {
        case .notNeeded:
            return TranscriptCleanupResult(segments: segments, warning: nil, cleanedSegmentCount: 0)
        case .blocked(let warning):
            return TranscriptCleanupResult(segments: segments, warning: warning, cleanedSegmentCount: 0)
        case .ready:
            break
        }

        let report = RunReport(segmentCount: segments.count)
        do {
            let result = try await MLXModelResourceCoordinator.shared.withExclusive {
                do {
                    let result = try await self.cleanEligibleSegments(
                        segments,
                        checkpoint: checkpoint,
                        progress: progress,
                        report: report
                    )
                    await checkpoint?.flush()
                    await self.normalizer.releaseResources()
                    return result
                } catch {
                    // A paused or failed run keeps everything it finished.
                    await checkpoint?.flush()
                    await self.normalizer.releaseResources()
                    throw error
                }
            }
            report.log(outcome: result.warning?.logCategory ?? "cleaned")
            return result
        } catch {
            let warning = Self.warning(for: error)
            report.log(outcome: warning.logCategory)
            return TranscriptCleanupResult(segments: segments, warning: warning, cleanedSegmentCount: 0)
        }
    }

    /// Thrown when a run reaches `maximumRunDuration`.
    private struct RunTimeLimitReached: Error {}

    /// Maps a run- or piece-ending error to the warning the user sees.
    private static func warning(for error: Error) -> TranscriptCleanupWarning {
        if error is CancellationError { return .cancelled }
        if error is RunTimeLimitReached { return .timeLimitReached }
        switch error as? TranscriptCleanupNormalizerError {
        case .cancelled: return .cancelled
        case .modelUnavailable: return .missingModel
        case .templateUnavailable, .generationFailed, .invalidRequest, .outputTruncated: return .resourceFailure
        case .invalidOutput, .none: return .invalidOutput
        }
    }

    /// Failures the same model would produce again for the same passage:
    /// output it rejected, output that ran to the token cap at temperature 0,
    /// or a request that cannot be built. Timeouts and generation errors are
    /// transient.
    private static func isDeterministic(_ error: Error) -> Bool {
        switch error as? TranscriptCleanupNormalizerError {
        case .invalidOutput, .invalidRequest, .outputTruncated: return true
        default: return false
        }
    }

    /// Errors that end the whole run rather than one piece: cancellation, and
    /// a model or chat template that is unusable for every piece alike.
    private static func endsRun(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? TranscriptCleanupNormalizerError {
        case .cancelled, .modelUnavailable, .templateUnavailable: return true
        default: return false
        }
    }

    /// One planned model request, or text kept exactly as written.
    ///
    /// A single whitespace-free run longer than the whole request budget — a
    /// long URL, a pasted identifier — cannot be sent to the model, and there
    /// is nothing for a normalizer to fix in it anyway. It passes through
    /// unchanged; it used to abort planning, and with it every passage in the
    /// transcript.
    private struct PlannedPiece: Equatable {
        let text: String
        let passthrough: Bool

        static func model(_ text: String) -> PlannedPiece { PlannedPiece(text: text, passthrough: false) }
        static func verbatim(_ text: String) -> PlannedPiece { PlannedPiece(text: text, passthrough: true) }
    }

    private struct SegmentPlan {
        enum Kind {
            /// Whitespace-only: retains its existing value, never removed.
            case empty
            /// Only hesitation sounds: cleans to empty text with no model call.
            case hesitationOnly
            case pieces([PlannedPiece])
        }
        let segment: TranscriptSegment
        let kind: Kind
    }

    private func cleanEligibleSegments(
        _ segments: [TranscriptSegment],
        checkpoint: (any TranscriptCleanupCheckpointing)?,
        progress: (@Sendable (TranscriptCleanupProgress) -> Void)?,
        report: RunReport
    ) async throws -> TranscriptCleanupResult {
        let deadline = Date().addingTimeInterval(Self.maximumRunDuration)
        let counter = TokenCounter(normalizer: normalizer)
        // The system prompt, control line and chat-template markup are a fixed
        // cost on every rendered request. Measuring it once lets both the
        // chunking budget and the expansion check below talk about the
        // segment's own tokens rather than the prompt's.
        let overhead = try await counter.count("")

        // Plan every piece up front so progress has a real total.
        var plans: [SegmentPlan] = []
        plans.reserveCapacity(segments.count)
        for segment in segments {
            try Task.checkCancellation()
            let rawText = segment.text
            if rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plans.append(SegmentPlan(segment: segment, kind: .empty))
            } else if isHesitationOnly(rawText) {
                plans.append(SegmentPlan(segment: segment, kind: .hesitationOnly))
            } else {
                let pieces = try await inputPieces(for: rawText, overhead: overhead, counter: counter)
                plans.append(SegmentPlan(segment: segment, kind: .pieces(pieces)))
            }
        }

        let totalPieces = plans.reduce(0) { total, plan in
            if case .pieces(let pieces) = plan.kind { return total + pieces.count }
            return total
        }
        report.piecesPlanned = totalPieces
        var completedPieces = 0
        progress?(TranscriptCleanupProgress(completedPieces: 0, totalPieces: totalPieces))

        var cleanedSegments: [TranscriptSegment] = []
        cleanedSegments.reserveCapacity(segments.count)
        var cleanedSegmentCount = 0
        var cleanedPieceCount = 0
        var keptOriginalPieceCount = 0
        var firstPieceFailure: Error?

        for plan in plans {
            switch plan.kind {
            case .empty:
                cleanedSegments.append(plan.segment)
                continue
            case .hesitationOnly:
                report.hesitationShortcuts += 1
                cleanedSegments.append(plan.segment.withCleanup(TranscriptSegmentCleanup(normalizedText: "")))
                cleanedSegmentCount += 1
                continue
            case .pieces(let pieces):
                var parts: [String] = []
                var segmentCleanedPieces = 0
                for (index, planned) in pieces.enumerated() {
                    try Task.checkCancellation()
                    let piece = planned.text
                    if planned.passthrough {
                        // Kept as written; neither cleaned nor a failure.
                        report.passthroughPieces += 1
                        parts.append(piece)
                        completedPieces += 1
                        progress?(TranscriptCleanupProgress(completedPieces: completedPieces, totalPieces: totalPieces))
                        continue
                    }
                    let key = Self.checkpointKey(segmentID: plan.segment.id, index: index, piece: piece)

                    let outcome: TranscriptCleanupPieceOutcome
                    var failureIsDeterministic = false
                    if let saved = await checkpoint?.outcome(forPiece: key) {
                        outcome = saved
                        report.piecesResumed += 1
                    } else {
                        // Resumed passages cost nothing; only new model work
                        // is bounded. Finished passages are already in the
                        // checkpoint, so the next run continues from here.
                        guard Date() < deadline else { throw RunTimeLimitReached() }
                        do {
                            outcome = .cleaned(
                                try await normalizedText(for: piece, overhead: overhead, counter: counter, report: report)
                            )
                        } catch let error where !Self.endsRun(error) {
                            // A generation interrupted by a pause or cancel
                            // can surface as an ordinary failure — MLX's
                            // stream simply ends early. That is not a verdict
                            // on the passage and must never reach the
                            // checkpoint, or the passage is never retried.
                            if Task.isCancelled { throw CancellationError() }
                            // One piece the model cannot clean keeps its
                            // original text; the rest of the run continues.
                            AppLog.shared.transcription(
                                "[TranscriptCleanup] Kept original text for one passage: "
                                    + Self.warning(for: error).logCategory,
                                level: .default
                            )
                            firstPieceFailure = firstPieceFailure ?? error
                            outcome = .keptOriginal
                            failureIsDeterministic = Self.isDeterministic(error)
                        }
                        // Only outcomes that would repeat are worth resuming:
                        // a cleaned passage, or output the temperature-0 model
                        // would reject again. A timeout or GPU error is retried.
                        if outcome != .keptOriginal || failureIsDeterministic {
                            await checkpoint?.record(outcome, forPiece: key)
                        }
                    }

                    switch outcome {
                    case .cleaned(let text):
                        segmentCleanedPieces += 1
                        if !text.isEmpty { parts.append(text) }
                    case .keptOriginal:
                        keptOriginalPieceCount += 1
                        parts.append(piece)
                    }
                    completedPieces += 1
                    progress?(TranscriptCleanupProgress(completedPieces: completedPieces, totalPieces: totalPieces))
                }

                if segmentCleanedPieces == 0 {
                    // Nothing in this segment was cleaned: leave it exactly as
                    // it was, including any earlier cleaned value.
                    cleanedSegments.append(plan.segment)
                } else {
                    cleanedPieceCount += segmentCleanedPieces
                    cleanedSegmentCount += 1
                    cleanedSegments.append(
                        plan.segment.withCleanup(TranscriptSegmentCleanup(normalizedText: parts.joined(separator: " ")))
                    )
                }
            }
        }

        try Task.checkCancellation()
        report.piecesKeptOriginal = keptOriginalPieceCount

        // A run that could not clean a single passage keeps the original
        // transcript untouched and says why, exactly as before. Hesitation-only
        // turns do not count as cleaning, and a passage resumed as kept-original
        // is still a failure, even though this run did not produce it.
        if cleanedPieceCount == 0, keptOriginalPieceCount > 0 {
            throw firstPieceFailure ?? TranscriptCleanupNormalizerError.invalidOutput
        }

        return TranscriptCleanupResult(
            segments: cleanedSegments,
            warning: keptOriginalPieceCount > 0 ? .partiallyCleaned(keptOriginalPieceCount) : nil,
            cleanedSegmentCount: cleanedSegmentCount
        )
    }

    /// Identifies one piece of one segment's text. The text hash means an
    /// edited segment never reuses a stale result; the model revision and
    /// prompt version are checked by the checkpoint store itself.
    static func checkpointKey(segmentID: UUID, index: Int, piece: String) -> String {
        let digest = SHA256.hash(data: Data(piece.utf8))
        let hash = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(segmentID.uuidString)#\(index)#\(hash)"
    }

    private func isHesitationOnly(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { !$0.isEmpty }
        return !words.isEmpty && words.allSatisfy { Self.hesitationWords.contains($0) }
    }

    private func inputPieces(
        for rawText: String,
        overhead: Int,
        counter: TokenCounter
    ) async throws -> [PlannedPiece] {
        let fullRequestTokenCount = try await counter.count(rawText)
        guard fullRequestTokenCount > Self.maxRenderedInputTokens else {
            return [.model(rawText)]
        }

        // Each sentence and word is rendered exactly once and the fixed
        // chat-template overhead is added back. Re-rendering the whole growing
        // prefix per sentence made this quadratic in the length of a single
        // unpunctuated turn.
        let budget = Self.maxRenderedInputTokens - overhead
        guard budget > 0 else {
            throw TranscriptCleanupNormalizerError.invalidRequest
        }

        var pieces: [PlannedPiece] = []
        var pending: [String] = []
        var pendingCount = 0

        for sentence in sentenceParts(in: rawText) {
            let sentenceCount = try await unitTokenCount(sentence, overhead: overhead, counter: counter)
            if sentenceCount > budget {
                if !pending.isEmpty {
                    pieces.append(.model(pending.joined(separator: " ")))
                    pending = []
                    pendingCount = 0
                }
                pieces.append(
                    contentsOf: try await whitespacePieces(
                        for: sentence, budget: budget, overhead: overhead, counter: counter
                    )
                )
                continue
            }

            if pendingCount + sentenceCount > budget, !pending.isEmpty {
                pieces.append(.model(pending.joined(separator: " ")))
                pending = []
                pendingCount = 0
            }
            pending.append(sentence)
            pendingCount += sentenceCount
        }

        if !pending.isEmpty {
            pieces.append(.model(pending.joined(separator: " ")))
        }

        guard !pieces.isEmpty else {
            throw TranscriptCleanupNormalizerError.invalidRequest
        }
        return try await verifiedPieces(pieces, budget: budget, overhead: overhead, counter: counter)
    }

    /// Summed per-unit counts can undercount when the tokenizer merges across a
    /// join, and `normalize` rejects an over-budget request outright. Each
    /// assembled piece is therefore measured once against the real renderer,
    /// which stays linear in the number of pieces.
    private func verifiedPieces(
        _ pieces: [PlannedPiece],
        budget: Int,
        overhead: Int,
        counter: TokenCounter
    ) async throws -> [PlannedPiece] {
        var verified: [PlannedPiece] = []
        verified.reserveCapacity(pieces.count)
        for piece in pieces {
            if piece.passthrough {
                verified.append(piece)
                continue
            }
            if try await counter.count(piece.text) <= Self.maxRenderedInputTokens {
                verified.append(piece)
            } else {
                verified.append(
                    contentsOf: try await whitespacePieces(
                        for: piece.text, budget: budget, overhead: overhead, counter: counter
                    )
                )
            }
        }
        return verified
    }

    private func unitTokenCount(_ text: String, overhead: Int, counter: TokenCounter) async throws -> Int {
        max(try await counter.count(text) - overhead, 1)
    }

    private func whitespacePieces(
        for text: String,
        budget: Int,
        overhead: Int,
        counter: TokenCounter
    ) async throws -> [PlannedPiece] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }

        var pieces: [PlannedPiece] = []
        var pending: [String] = []
        var pendingCount = 0
        for word in words {
            let wordCount = try await unitTokenCount(word, overhead: overhead, counter: counter)
            guard wordCount <= budget else {
                // Too long to send even alone: keep it as written, between
                // the passages on either side of it.
                if !pending.isEmpty {
                    pieces.append(.model(pending.joined(separator: " ")))
                    pending = []
                    pendingCount = 0
                }
                pieces.append(.verbatim(word))
                continue
            }

            if pendingCount + wordCount > budget, !pending.isEmpty {
                pieces.append(.model(pending.joined(separator: " ")))
                pending = []
                pendingCount = 0
            }
            pending.append(word)
            pendingCount += wordCount
        }

        if !pending.isEmpty {
            pieces.append(.model(pending.joined(separator: " ")))
        }
        return pieces
    }

    /// Returns the validated, trimmed cleaned text for one input piece.
    ///
    /// Every generation is validated against the piece that produced it, so the
    /// absolute per-generation output cap is never applied to a concatenated
    /// total — a split retry whose halves each finished normally used to be
    /// rejected as invalid output once their token counts were summed.
    private func normalizedText(
        for piece: String,
        overhead: Int,
        counter: TokenCounter,
        report: RunReport
    ) async throws -> String {
        let generation = try await timedNormalize(piece, report: report)
        try Task.checkCancellation()
        if generation.finishReason != .length {
            return try validatedText(generation, originalText: piece, overhead: overhead)
        }

        let retryPieces = try await whitespacePiecesForRetry(piece, counter: counter)
        guard retryPieces.count > 1 else {
            throw TranscriptCleanupNormalizerError.outputTruncated
        }

        report.splitRetries += 1
        var parts: [String] = []
        for retryPiece in retryPieces {
            try Task.checkCancellation()
            let retry = try await timedNormalize(retryPiece, report: report)
            try Task.checkCancellation()
            let text = try validatedText(retry, originalText: retryPiece, overhead: overhead)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: " ")
    }

    /// One model call, measured. A generation that throws (the per-call
    /// watchdog, a failed generation) is still counted and timed.
    private func timedNormalize(_ piece: String, report: RunReport) async throws -> TranscriptCleanupGeneration {
        let start = Date()
        do {
            let generation = try await normalizer.normalize(piece)
            report.recordGeneration(
                seconds: Date().timeIntervalSince(start),
                inputTokens: generation.inputTokenCount,
                outputTokens: generation.outputTokenCount,
                finishReason: "\(generation.finishReason)"
            )
            return generation
        } catch {
            report.recordGeneration(
                seconds: Date().timeIntervalSince(start),
                inputTokens: 0,
                outputTokens: 0,
                finishReason: "error"
            )
            throw error
        }
    }

    private func whitespacePiecesForRetry(_ text: String, counter: TokenCounter) async throws -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return [text] }
        let midpoint = max(1, words.count / 2)
        let first = words[..<midpoint].joined(separator: " ")
        let second = words[midpoint...].joined(separator: " ")
        let pieces = [first, second]
        for piece in pieces {
            guard try await counter.count(piece) <= Self.maxRenderedInputTokens else {
                throw TranscriptCleanupNormalizerError.invalidRequest
            }
        }
        return pieces
    }

    private func validatedText(
        _ generation: TranscriptCleanupGeneration,
        originalText: String,
        overhead: Int
    ) throws -> String {
        guard generation.finishReason == .stop else {
            if generation.finishReason == .cancelled {
                throw TranscriptCleanupNormalizerError.cancelled
            }
            if generation.finishReason == .length {
                throw TranscriptCleanupNormalizerError.outputTruncated
            }
            throw TranscriptCleanupNormalizerError.generationFailed
        }

        let normalizedText = generation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containsGeneratedControlToken(normalizedText),
              !containsGeneratedSpeakerLabel(normalizedText) else {
            throw TranscriptCleanupNormalizerError.invalidOutput
        }

        // `inputTokenCount` is the provider's prompt token count, which
        // includes the system prompt, control line and template markup. Left
        // in, that fixed cost inflates the expansion ceiling by hundreds of
        // tokens for a short segment and lets a long hallucinated rewrite pass.
        let inputTokens = max(generation.inputTokenCount - overhead, 1)
        guard generation.outputTokenCount <= Self.maxNewOutputTokens else {
            throw TranscriptCleanupNormalizerError.invalidOutput
        }
        guard generation.outputTokenCount <= inputTokens * 2 + 32 else {
            throw TranscriptCleanupNormalizerError.invalidOutput
        }

        guard normalizedText.isEmpty else { return normalizedText }
        guard isFillerOnly(originalText) else {
            let sourceWordCount = originalText.split(whereSeparator: \.isWhitespace).count
            guard sourceWordCount <= Self.maxConservativeFallbackWords else {
                throw TranscriptCleanupNormalizerError.invalidOutput
            }
            // Short fragments are often split from a larger spoken sentence by
            // ASR. If the normalizer drops one, keep the source rather than
            // dropping words or invalidating every other cleaned segment.
            return originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
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
        // Language metadata the ASR engine itself reported is a measurement,
        // not a guess, so it outranks the text probes below: one Latin clause
        // or a run of proper nouns cannot veto a transcript Whisper already
        // identified as English.
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

        // Manual confirmation is deliberately *not* checked here. The editor's
        // action passes `confirmedEnglish: true` unconditionally, so it carries
        // no user judgement about the language — it only means "cleanup was
        // asked for directly". It may override an uncertain result at the
        // bottom of this method, never a confident non-English determination,
        // because sending clearly French or Spanish text to an English-only
        // normalizer can translate or corrupt the stored cleaned text.

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

        // Nothing above could confirm or rule out English. Only here does a
        // directly requested cleanup proceed anyway.
        if case .manual(let confirmedEnglish) = mode, confirmedEnglish {
            return LanguageEligibility(isEligible: true, warning: nil)
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

/// Memoizes rendered-request token counts for one run. Planning measures each
/// sentence, each assembled piece, and the empty overhead; the same strings
/// recur, and each count is a full chat-template render plus tokenization.
private final class TokenCounter {
    private let normalizer: any TranscriptCleanupNormalizing
    private var cache: [String: Int] = [:]

    init(normalizer: any TranscriptCleanupNormalizing) {
        self.normalizer = normalizer
    }

    func count(_ text: String) async throws -> Int {
        if let cached = cache[text] { return cached }
        let value = try await normalizer.renderedRequestTokenCount(for: text)
        cache[text] = value
        return value
    }
}

/// What one cleanup run did, logged once when it ends however it ends. Without
/// it a slow or failed run left no record of how much work it attempted, how
/// fast the model ran, or which condition stopped it.
final class RunReport: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date()
    private let segmentCount: Int
    private var _piecesPlanned = 0
    private var _piecesResumed = 0
    private var _piecesKeptOriginal = 0
    private var _hesitationShortcuts = 0
    private var _splitRetries = 0
    private var _passthroughPieces = 0
    private var generations = 0
    private var generationSeconds: TimeInterval = 0
    private var outputTokens = 0

    init(segmentCount: Int) {
        self.segmentCount = segmentCount
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var piecesPlanned: Int {
        get { locked { _piecesPlanned } }
        set { locked { _piecesPlanned = newValue } }
    }
    var piecesResumed: Int {
        get { locked { _piecesResumed } }
        set { locked { _piecesResumed = newValue } }
    }
    var piecesKeptOriginal: Int {
        get { locked { _piecesKeptOriginal } }
        set { locked { _piecesKeptOriginal = newValue } }
    }
    var hesitationShortcuts: Int {
        get { locked { _hesitationShortcuts } }
        set { locked { _hesitationShortcuts = newValue } }
    }
    var splitRetries: Int {
        get { locked { _splitRetries } }
        set { locked { _splitRetries = newValue } }
    }
    var passthroughPieces: Int {
        get { locked { _passthroughPieces } }
        set { locked { _passthroughPieces = newValue } }
    }

    func recordGeneration(seconds: TimeInterval, inputTokens: Int, outputTokens: Int, finishReason: String) {
        locked {
            generations += 1
            generationSeconds += seconds
            self.outputTokens += outputTokens
        }
        let rate = seconds > 0 ? Double(outputTokens) / seconds : 0
        AppLog.shared.transcription(
            "[TranscriptCleanup] Generation: "
                + String(format: "%.2fs", seconds)
                + ", in=\(inputTokens) out=\(outputTokens) tok, "
                + String(format: "%.1f tok/s", rate)
                + ", finish=\(finishReason)",
            level: .debug
        )
    }

    func log(outcome: String) {
        let line = locked { () -> String in
            let elapsed = Date().timeIntervalSince(start)
            let rate = generationSeconds > 0 ? Double(outputTokens) / generationSeconds : 0
            return "[TranscriptCleanup] Run finished: outcome=\(outcome), "
                + "segments=\(segmentCount), pieces=\(_piecesPlanned), "
                + "resumed=\(_piecesResumed), generated=\(generations), "
                + "retries=\(_splitRetries), keptOriginal=\(_piecesKeptOriginal), "
                + "hesitationOnly=\(_hesitationShortcuts), verbatim=\(_passthroughPieces), "
                + String(format: "generation=%.1fs, total=%.1fs, ", generationSeconds, elapsed)
                + String(format: "%.1f tok/s", rate)
        }
        AppLog.shared.transcription(line)
    }
}
