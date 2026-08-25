import Foundation

struct SpeakerTextReconciliationResult {
    let segments: [LocalSpeakerLabeledSegment]
    let unmatchedCanonicalContentCharacters: Int
    let unmatchedTimedContentCharacters: Int
}

extension SpeakerTranscriptAligner {
    /// Compare transcript representations without treating decoder-boundary
    /// whitespace as a content change. FluidAudio's decoded text can retain a
    /// space between a prefix symbol and its word (for example, "$ 100"),
    /// while token timing reconstruction correctly keeps the token as "$100".
    /// Ordinary word boundaries remain significant.
    static func contentEquivalent(_ lhs: String, _ rhs: String) -> Bool {
        contentForComparison(lhs) == contentForComparison(rhs)
    }

    static func contentCharacterCount(_ text: String) -> Int {
        contentForComparison(text).filter { !$0.isWhitespace }.count
    }

    /// Reconcile speaker-labeled timing text back onto the canonical ASR
    /// transcript. The timed stream is allowed to have a bounded number of
    /// inserted or missing non-whitespace characters, but substitutions are
    /// rejected. This keeps the transcript text authoritative while allowing
    /// token-timing reconstruction to lose or add a small decoder fragment.
    static func reconcileCanonicalText(
        canonicalText: String,
        with labeledSegments: [LocalSpeakerLabeledSegment],
        maximumUnmatchedContentCharacters: Int = 64,
        maximumLookahead: Int = 64
    ) -> SpeakerTextReconciliationResult? {
        let canonicalCharacters = Array(canonicalText)
        let canonicalContent = canonicalCharacters.enumerated().compactMap { index, character in
            character.isWhitespace ? nil : (index: index, character: character)
        }
        let timedContent = labeledSegments.enumerated().flatMap { segmentIndex, segment in
            segment.text.compactMap { character in
                character.isWhitespace
                    ? nil
                    : SpeakerTextTimedCharacter(character: character, segmentIndex: segmentIndex)
            }
        }

        let unmatchedLimit = max(0, maximumUnmatchedContentCharacters)
        let lookaheadLimit = max(1, maximumLookahead)
        guard !canonicalContent.isEmpty, !timedContent.isEmpty else {
            return emptyReconciliation(
                canonicalContentCount: canonicalContent.count,
                timedContentCount: timedContent.count
            )
        }

        guard let match = SpeakerTextMatcher.match(
            canonicalContent: canonicalContent,
            timedContent: timedContent,
            unmatchedLimit: unmatchedLimit,
            lookaheadLimit: lookaheadLimit
        ) else {
            return nil
        }

        let canonicalLabels = canonicalLabels(
            for: match.canonicalToTimed,
            canonicalContent: canonicalContent,
            timedContent: timedContent
        )
        guard let canonicalLabels else { return nil }

        guard let segments = buildCanonicalSegments(
            canonicalCharacters: canonicalCharacters,
            canonicalContent: canonicalContent,
            canonicalLabels: canonicalLabels,
            labeledSegments: labeledSegments
        ) else {
            return nil
        }

        let reconciledText = joinWordText(
            segments.map { (text: $0.text, hasLeadingSpace: $0.hasLeadingSpace) }
        )
        guard contentEquivalent(canonicalText, reconciledText) else { return nil }

        return SpeakerTextReconciliationResult(
            segments: segments,
            unmatchedCanonicalContentCharacters: match.unmatchedCanonicalCount,
            unmatchedTimedContentCharacters: match.unmatchedTimedCount
        )
    }

    private static func emptyReconciliation(
        canonicalContentCount: Int,
        timedContentCount: Int
    ) -> SpeakerTextReconciliationResult? {
        guard canonicalContentCount == 0, timedContentCount == 0 else { return nil }
        return SpeakerTextReconciliationResult(
            segments: [],
            unmatchedCanonicalContentCharacters: 0,
            unmatchedTimedContentCharacters: 0
        )
    }

    private static func contentForComparison(_ text: String) -> String {
        var result = ""
        var pendingWhitespace = false
        var previousCharacter: Character?

        for character in text {
            if character.isWhitespace {
                pendingWhitespace = true
                continue
            }

            if pendingWhitespace,
               !result.isEmpty,
               !shouldOmitWhitespace(between: previousCharacter, and: character) {
                result.append(" ")
            }
            result.append(character)
            previousCharacter = character
            pendingWhitespace = false
        }

        return result
    }

    private static func canonicalLabels(
        for canonicalToTimed: [Int?],
        canonicalContent: [(index: Int, character: Character)],
        timedContent: [SpeakerTextTimedCharacter]
    ) -> [Int]? {
        guard !canonicalToTimed.isEmpty else { return [] }

        var labels = canonicalToTimed.map { timedIndex in
            timedIndex.map { timedContent[$0].segmentIndex }
        }
        var nextLabel: Int?
        var nextLabels = [Int?](repeating: nil, count: labels.count)
        for index in labels.indices.reversed() {
            if let label = labels[index] {
                nextLabel = label
            }
            nextLabels[index] = nextLabel
        }

        var previousLabel: Int?
        for index in labels.indices {
            if let label = labels[index] {
                previousLabel = label
            } else {
                labels[index] = previousLabel ?? nextLabels[index]
            }
        }

        guard labels.allSatisfy({ $0 != nil }) else { return nil }
        let resolvedLabels = labels.compactMap { $0 }
        guard resolvedLabels.count == canonicalContent.count else { return nil }
        return resolvedLabels
    }

    private static func buildCanonicalSegments(
        canonicalCharacters: [Character],
        canonicalContent: [(index: Int, character: Character)],
        canonicalLabels: [Int],
        labeledSegments: [LocalSpeakerLabeledSegment]
    ) -> [LocalSpeakerLabeledSegment]? {
        guard canonicalContent.count == canonicalLabels.count,
              !canonicalLabels.isEmpty else {
            return canonicalLabels.isEmpty ? [] : nil
        }

        var runs: [ReconciliationCanonicalRun] = []
        for (contentIndex, label) in canonicalLabels.enumerated() {
            let characterIndex = canonicalContent[contentIndex].index
            if let lastIndex = runs.indices.last,
               runs[lastIndex].segmentIndex == label {
                runs[lastIndex].endCharacterIndex = characterIndex
            } else {
                runs.append(
                    ReconciliationCanonicalRun(
                        segmentIndex: label,
                        startCharacterIndex: characterIndex,
                        endCharacterIndex: characterIndex
                    )
                )
            }
        }

        var result: [LocalSpeakerLabeledSegment] = []
        result.reserveCapacity(runs.count)
        var previousEndCharacterIndex: Int?
        for run in runs {
            guard labeledSegments.indices.contains(run.segmentIndex) else { return nil }
            let sourceSegment = labeledSegments[run.segmentIndex]
            let text = String(canonicalCharacters[run.startCharacterIndex...run.endCharacterIndex])
            guard !text.isEmpty else { return nil }

            let hasLeadingSpace: Bool
            if let previousEndCharacterIndex {
                let boundary = canonicalCharacters[(previousEndCharacterIndex + 1)..<run.startCharacterIndex]
                hasLeadingSpace = boundary.contains { $0.isWhitespace }
            } else {
                hasLeadingSpace = false
            }

            result.append(
                LocalSpeakerLabeledSegment(
                    speakerID: sourceSegment.speakerID,
                    text: text,
                    startTime: sourceSegment.startTime,
                    endTime: sourceSegment.endTime,
                    hasLeadingSpace: hasLeadingSpace
                )
            )
            previousEndCharacterIndex = run.endCharacterIndex
        }
        return result
    }

    private struct ReconciliationCanonicalRun {
        let segmentIndex: Int
        let startCharacterIndex: Int
        var endCharacterIndex: Int
    }

    private static func shouldOmitWhitespace(
        between previousCharacter: Character?,
        and nextCharacter: Character
    ) -> Bool {
        guard let previousCharacter else { return false }

        return contains(comparisonClosingPunctuationCharacters, nextCharacter)
            || contains(comparisonOpeningPunctuationCharacters, previousCharacter)
            || contains(comparisonPrefixSymbolCharacters, previousCharacter)
    }

    private static func contains(_ set: CharacterSet, _ character: Character) -> Bool {
        character.unicodeScalars.contains { set.contains($0) }
    }

    private static let comparisonOpeningPunctuationCharacters = CharacterSet(
        charactersIn: "([{<«‹“‘„‚\"'¿¡「『【〔〖〘〚〈《"
    )
    private static let comparisonClosingPunctuationCharacters = CharacterSet(
        charactersIn: ")]}>»›”’.,!?;:%…。、，！？；：؟،؛٪）］｝〉》」』】〕〗〙〛\"'-‐‑‒–—―"
    )
    private static let comparisonPrefixSymbolCharacters = CharacterSet(
        charactersIn: "$€£¥₹₽¢₩₪₫₴₦₲₵₡₸₺₼₾-‐‑‒–—―"
    )
}
