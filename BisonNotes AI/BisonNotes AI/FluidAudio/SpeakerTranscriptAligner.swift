import Foundation

/// Pure alignment of absolute Parakeet word timings to a complete-file
/// diarization timeline. It has no persistence, UI, Core Data, or FluidAudio
/// SDK dependency.
struct SpeakerTranscriptAligner {
    static let defaultMeaningfulSilence: TimeInterval = 0.75

    private let meaningfulSilence: TimeInterval
    private let comparisonEpsilon: TimeInterval = 0.000_001

    init(meaningfulSilence: TimeInterval = SpeakerTranscriptAligner.defaultMeaningfulSilence) {
        self.meaningfulSilence = max(0, meaningfulSilence)
    }

    // swiftlint:disable function_body_length
    /// Convert FluidAudio-style SentencePiece/TDT pieces into app-owned words.
    /// Word-boundary markers are retained as spacing metadata, punctuation is
    /// attached according to its opening/closing role, and only explicit blank
    /// or pad pieces are ignored because they contain no transcript text.
    static func reconstructWords(from tokens: [TimedTranscriptToken]) -> [TimedTranscriptWord] {
        var words: [TimedTranscriptWord] = []
        var currentText = ""
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?
        var currentConfidenceValues: [Double] = []
        var currentHasLeadingSpace = false
        var pendingBoundary = false

        func validTime(_ value: TimeInterval?) -> TimeInterval? {
            guard let value, value.isFinite else { return nil }
            return value
        }

        func updateTiming(with token: TimedTranscriptToken) {
            if let start = validTime(token.startTime) {
                currentStart = min(currentStart ?? start, start)
            }
            if let end = validTime(token.endTime) {
                currentEnd = max(currentEnd ?? end, end)
            }
            if let confidence = token.confidence, confidence.isFinite {
                currentConfidenceValues.append(confidence)
            }
        }

        func flush() {
            guard !currentText.isEmpty else {
                currentStart = nil
                currentEnd = nil
                currentConfidenceValues.removeAll(keepingCapacity: true)
                currentHasLeadingSpace = false
                return
            }

            let confidence: Double?
            if currentConfidenceValues.isEmpty {
                confidence = nil
            } else {
                confidence = currentConfidenceValues.reduce(0, +) / Double(currentConfidenceValues.count)
            }

            words.append(
                TimedTranscriptWord(
                    text: currentText,
                    startTime: currentStart,
                    endTime: currentEnd,
                    confidence: confidence,
                    hasLeadingSpace: currentHasLeadingSpace
                )
            )
            currentText = ""
            currentStart = nil
            currentEnd = nil
            currentConfidenceValues.removeAll(keepingCapacity: true)
            currentHasLeadingSpace = false
            pendingBoundary = false
        }

        for token in tokens {
            guard !token.text.isEmpty, token.text != "<blank>", token.text != "<pad>" else {
                continue
            }

            let hasBoundary = token.text.hasPrefix("▁") || token.text.hasPrefix(" ")
            let piece: String
            if hasBoundary {
                piece = String(token.text.dropFirst())
            } else {
                piece = token.text
            }

            if hasBoundary && piece.isEmpty {
                pendingBoundary = true
                continue
            }

            let startsAtBoundary = hasBoundary || pendingBoundary

            if currentText.isEmpty {
                currentText = piece
                currentHasLeadingSpace = startsAtBoundary
                pendingBoundary = false
                updateTiming(with: token)
                continue
            }

            if startsAtBoundary && !isClosingPunctuationOnly(piece) {
                flush()
                currentText = piece
                currentHasLeadingSpace = true
                updateTiming(with: token)
                continue
            }

            currentText += piece
            pendingBoundary = false
            updateTiming(with: token)
        }

        flush()
        return words
    }
    // swiftlint:enable function_body_length
    /// Align words to normalized speaker intervals. Every non-empty input word
    /// produces exactly one output word contribution; a word with no credible
    /// timing or interval is assigned to `Unknown` rather than inheriting a
    /// prior speaker.
    func align(
        words: [TimedTranscriptWord],
        intervals: [LocalDiarizationInterval],
        audioDuration: TimeInterval? = nil
    ) -> LocalSpeakerLabelingResult {
        let sanitizedDuration = sanitizeDuration(audioDuration)
        let normalizedIntervals = normalizeIntervals(intervals, duration: sanitizedDuration)
        let nonemptyWords = words.filter { !$0.text.isEmpty }

        guard nonemptyWords.isEmpty || !normalizedIntervals.isEmpty else {
            return .unlabeled(warning: .timingUnavailable)
        }

        var segmentBuilders: [SpeakerAlignmentSegmentBuilder] = []
        for word in nonemptyWords {
            let range = sanitizeRange(
                start: word.startTime,
                end: word.endTime,
                duration: sanitizedDuration
            )
            let speakerID = speakerID(for: range, intervals: normalizedIntervals)
            let start = range?.lowerBound ?? 0
            let end = range?.upperBound ?? start

            if let lastIndex = segmentBuilders.indices.last,
               segmentBuilders[lastIndex].canMerge(
                   speakerID: speakerID,
                   startTime: start,
                   meaningfulSilence: meaningfulSilence,
                   epsilon: comparisonEpsilon
               ) {
                segmentBuilders[lastIndex].append(
                    text: word.text,
                    hasLeadingSpace: word.hasLeadingSpace,
                    startTime: start,
                    endTime: end
                )
            } else {
                segmentBuilders.append(
                    SpeakerAlignmentSegmentBuilder(
                        speakerID: speakerID,
                        text: word.text,
                        startTime: start,
                        endTime: end
                    )
                )
            }
        }

        let segments = segmentBuilders.map { $0.build() }
        return LocalSpeakerLabelingResult(
            segments: segments,
            normalizedIntervals: normalizedIntervals
        )
    }

    /// The canonical text used by tests and by integration code when checking
    /// that labels did not rewrite or reorder the ASR content.
    static func plainText(from words: [TimedTranscriptWord]) -> String {
        joinWordText(words.map { ($0.text, $0.hasLeadingSpace) })
    }

    static func normalizedPlainText(from words: [TimedTranscriptWord]) -> String {
        normalizePlainText(plainText(from: words))
    }

    static func normalizedPlainText(from segments: [LocalSpeakerLabeledSegment]) -> String {
        normalizePlainText(segments.map(\.text).joined(separator: " "))
    }

    /// Normalize an existing ASR string with the same punctuation/whitespace
    /// rules used for aligned segment text. Parakeet's decoded text and its
    /// SentencePiece timing reconstruction can differ only in whitespace
    /// around punctuation; comparing them with different normalizers causes a
    /// valid diarization pass to be discarded.
    static func normalizedPlainText(_ text: String) -> String {
        normalizePlainText(text)
    }
}

extension SpeakerTranscriptAligner {
    private func normalizeIntervals(
        _ intervals: [LocalDiarizationInterval],
        duration: TimeInterval?
    ) -> [NormalizedSpeakerInterval] {
        var validIntervals: [SpeakerAlignmentRawInterval] = []

        for (inputOrder, interval) in intervals.enumerated() {
            guard !interval.speakerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  interval.speakerID.lowercased() != "unknown",
                  let range = sanitizeRange(
                      start: interval.startTime,
                      end: interval.endTime,
                      duration: duration
                  ) else {
                continue
            }
            validIntervals.append(
                SpeakerAlignmentRawInterval(
                    inputOrder: inputOrder,
                    raw: interval,
                    range: range
                )
            )
        }

        validIntervals.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            if $0.range.upperBound != $1.range.upperBound {
                return $0.range.upperBound < $1.range.upperBound
            }
            return $0.inputOrder < $1.inputOrder
        }

        var normalizedIDByRawID: [String: String] = [:]
        var nextSpeakerNumber = 1
        return validIntervals.map { item in
            let normalizedID: String
            if let existingID = normalizedIDByRawID[item.raw.speakerID] {
                normalizedID = existingID
            } else {
                normalizedID = "speaker_\(nextSpeakerNumber)"
                normalizedIDByRawID[item.raw.speakerID] = normalizedID
                nextSpeakerNumber += 1
            }

            return NormalizedSpeakerInterval(
                speakerID: normalizedID,
                startTime: item.range.lowerBound,
                endTime: item.range.upperBound,
                confidence: item.raw.confidence
            )
        }
    }

    private func speakerID(
        for wordRange: SpeakerAlignmentRange?,
        intervals: [NormalizedSpeakerInterval]
    ) -> String {
        guard let wordRange else {
            return LocalSpeakerLabeledSegment.unknownSpeakerID
        }

        let indexedIntervals = intervals.enumerated().map {
            SpeakerAlignmentIndexedInterval(stableOrder: $0.offset, interval: $0.element)
        }
        guard !indexedIntervals.isEmpty else {
            return LocalSpeakerLabeledSegment.unknownSpeakerID
        }

        let midpoint = wordRange.lowerBound + (wordRange.duration / 2)
        let overlapValues = indexedIntervals.map { indexedInterval in
            (indexedInterval, overlap(of: wordRange, and: indexedInterval.interval))
        }
        let greatestOverlap = overlapValues.map(\.1).max() ?? 0

        let candidates: [SpeakerAlignmentIndexedInterval]
        if greatestOverlap > comparisonEpsilon {
            candidates = overlapValues
                .filter { abs($0.1 - greatestOverlap) <= comparisonEpsilon }
                .map(\.0)
        } else {
            // Zero-length words are resolved by midpoint containment. For a
            // non-zero word whose only contact is an endpoint, no interval is
            // credible and the word remains Unknown.
            candidates = overlapValues
                .filter { intervalContains($0.0.interval, midpoint: midpoint) }
                .map(\.0)
        }

        guard !candidates.isEmpty else {
            return LocalSpeakerLabeledSegment.unknownSpeakerID
        }

        let midpointCandidates = candidates.filter {
            intervalContains($0.interval, midpoint: midpoint)
        }
        return (midpointCandidates.isEmpty ? candidates : midpointCandidates)
            .min { $0.stableOrder < $1.stableOrder }?
            .interval.speakerID ?? LocalSpeakerLabeledSegment.unknownSpeakerID
    }

    private func overlap(
        of wordRange: SpeakerAlignmentRange,
        and interval: NormalizedSpeakerInterval
    ) -> TimeInterval {
        max(0, min(wordRange.upperBound, interval.endTime) - max(wordRange.lowerBound, interval.startTime))
    }

    private func intervalContains(
        _ interval: NormalizedSpeakerInterval,
        midpoint: TimeInterval
    ) -> Bool {
        midpoint + comparisonEpsilon >= interval.startTime
            && midpoint - comparisonEpsilon <= interval.endTime
    }

    private func sanitizeDuration(_ duration: TimeInterval?) -> TimeInterval? {
        guard let duration, duration.isFinite, duration >= 0 else { return nil }
        return duration
    }

    private func sanitizeRange(
        start: TimeInterval?,
        end: TimeInterval?,
        duration: TimeInterval?
    ) -> SpeakerAlignmentRange? {
        guard let start, let end, start.isFinite, end.isFinite else { return nil }

        let clampedStart = clamp(start, to: duration)
        let clampedEnd = clamp(end, to: duration)
        return SpeakerAlignmentRange(
            lowerBound: min(clampedStart, clampedEnd),
            upperBound: max(clampedStart, clampedEnd)
        )
    }

    private func clamp(_ value: TimeInterval, to duration: TimeInterval?) -> TimeInterval {
        let nonNegative = max(0, value)
        guard let duration else { return nonNegative }
        return min(nonNegative, duration)
    }

    static func joinWordText(_ words: [(text: String, hasLeadingSpace: Bool)]) -> String {
        var result = ""
        for (index, word) in words.enumerated() {
            guard !word.text.isEmpty else { continue }
            if index > 0,
               word.hasLeadingSpace,
               !result.isEmpty,
               !result.lastCharacterIsWhitespace,
               !startsWithoutSpace(word.text),
               !endsWithoutSpace(result) {
                result.append(" ")
            }
            result.append(word.text)
        }
        return result
    }

    private static func normalizePlainText(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return collapsed }

        var result = ""
        for character in collapsed {
            if startsWithoutSpace(String(character)), result.last == " " {
                result.removeLast()
            }
            result.append(character)
        }
        return result
    }
    private static func startsWithoutSpace(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        return closingPunctuationCharacters.contains(scalar)
    }
    private static func endsWithoutSpace(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.last else { return false }
        return openingPunctuationCharacters.contains(scalar)
    }
    private static func isClosingPunctuationOnly(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy(closingPunctuationCharacters.contains)
    }

    private static let openingPunctuationCharacters = CharacterSet(charactersIn: "([{<«‹“‘„‚¿¡「『【〔〖〘〚〈《")
    private static let closingPunctuationCharacters = CharacterSet(
        charactersIn: ")]}>»›”’.,!?;:%…。、，！？；：؟،؛٪）］｝〉》」』】〕〗〙〛"
    )
}

private extension String {
    var lastCharacterIsWhitespace: Bool {
        last?.isWhitespace == true
    }
}
