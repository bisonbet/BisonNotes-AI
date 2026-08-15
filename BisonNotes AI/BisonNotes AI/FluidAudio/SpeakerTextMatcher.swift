import Foundation

struct SpeakerTextTimedCharacter {
    let character: Character
    let segmentIndex: Int
}

struct SpeakerTextMatch {
    let canonicalToTimed: [Int?]
    let unmatchedCanonicalCount: Int
    let unmatchedTimedCount: Int
}

private enum SpeakerTextSkip {
    case canonical(Int)
    case timed(Int)
}

enum SpeakerTextMatcher {
    static func match(
        canonicalContent: [(index: Int, character: Character)],
        timedContent: [SpeakerTextTimedCharacter],
        unmatchedLimit: Int,
        lookaheadLimit: Int
    ) -> SpeakerTextMatch? {
        var canonicalToTimed = [Int?](repeating: nil, count: canonicalContent.count)
        var canonicalIndex = 0
        var timedIndex = 0
        var unmatchedCanonicalCount = 0
        var unmatchedTimedCount = 0

        while canonicalIndex < canonicalContent.count, timedIndex < timedContent.count {
            if canonicalContent[canonicalIndex].character == timedContent[timedIndex].character {
                canonicalToTimed[canonicalIndex] = timedIndex
                canonicalIndex += 1
                timedIndex += 1
                continue
            }

            guard let skip = resynchronizationDecision(
                canonicalContent: canonicalContent,
                timedContent: timedContent,
                canonicalIndex: canonicalIndex,
                timedIndex: timedIndex,
                lookaheadLimit: lookaheadLimit
            ) else {
                return nil
            }

            switch skip {
            case let .canonical(count):
                guard unmatchedCanonicalCount + count <= unmatchedLimit else { return nil }
                unmatchedCanonicalCount += count
                canonicalIndex += count
            case let .timed(count):
                guard unmatchedTimedCount + count <= unmatchedLimit else { return nil }
                unmatchedTimedCount += count
                timedIndex += count
            }
        }

        let trailingCanonicalCount = canonicalContent.count - canonicalIndex
        let trailingTimedCount = timedContent.count - timedIndex
        guard unmatchedCanonicalCount + trailingCanonicalCount <= unmatchedLimit,
              unmatchedTimedCount + trailingTimedCount <= unmatchedLimit else {
            return nil
        }

        return SpeakerTextMatch(
            canonicalToTimed: canonicalToTimed,
            unmatchedCanonicalCount: unmatchedCanonicalCount + trailingCanonicalCount,
            unmatchedTimedCount: unmatchedTimedCount + trailingTimedCount
        )
    }

    private static func resynchronizationDecision(
        canonicalContent: [(index: Int, character: Character)],
        timedContent: [SpeakerTextTimedCharacter],
        canonicalIndex: Int,
        timedIndex: Int,
        lookaheadLimit: Int
    ) -> SpeakerTextSkip? {
        let timedResynchronizationIndex = firstTimedIndex(
            matching: canonicalContent,
            from: canonicalIndex,
            in: timedContent,
            after: timedIndex,
            maximumLookahead: lookaheadLimit
        )
        let canonicalResynchronizationIndex = firstCanonicalIndex(
            matching: timedContent,
            from: timedIndex,
            in: canonicalContent,
            after: canonicalIndex,
            maximumLookahead: lookaheadLimit
        )
        let timedSkipCount = timedResynchronizationIndex.map { $0 - timedIndex }
        let canonicalSkipCount = canonicalResynchronizationIndex.map { $0 - canonicalIndex }

        switch (canonicalSkipCount, timedSkipCount) {
        case let (canonicalSkip?, timedSkip?) where canonicalSkip == timedSkip:
            // An equally short anchor cannot safely tell an insertion from a
            // deletion. Refuse the label pass rather than shifting every
            // subsequent speaker assignment by one character.
            return nil
        case let (canonicalSkip?, timedSkip?) where canonicalSkip < timedSkip:
            return .canonical(canonicalSkip)
        case let (canonicalSkip?, timedSkip?) where canonicalSkip > timedSkip:
            return .timed(timedSkip)
        case (.some, .some):
            return nil
        case let (canonicalSkip?, nil):
            return .canonical(canonicalSkip)
        case let (nil, timedSkip?):
            return .timed(timedSkip)
        case (nil, nil):
            return nil
        }
    }

    private static func firstTimedIndex(
        matching canonicalContent: [(index: Int, character: Character)],
        from canonicalIndex: Int,
        in timedContent: [SpeakerTextTimedCharacter],
        after index: Int,
        maximumLookahead: Int
    ) -> Int? {
        let firstCandidate = index + 1
        guard firstCandidate < timedContent.count else { return nil }
        let lastCandidate = min(timedContent.count - 1, index + maximumLookahead)
        guard firstCandidate <= lastCandidate else { return nil }
        for candidate in firstCandidate...lastCandidate {
            guard timedContent[candidate].character == canonicalContent[canonicalIndex].character else {
                continue
            }
            if hasMatchingContentRun(
                canonicalContent: canonicalContent,
                canonicalIndex: canonicalIndex,
                timedContent: timedContent,
                timedIndex: candidate
            ) {
                return candidate
            }
        }
        return nil
    }

    private static func firstCanonicalIndex(
        matching timedContent: [SpeakerTextTimedCharacter],
        from timedIndex: Int,
        in canonicalContent: [(index: Int, character: Character)],
        after index: Int,
        maximumLookahead: Int
    ) -> Int? {
        let firstCandidate = index + 1
        guard firstCandidate < canonicalContent.count else { return nil }
        let lastCandidate = min(canonicalContent.count - 1, index + maximumLookahead)
        guard firstCandidate <= lastCandidate else { return nil }
        for candidate in firstCandidate...lastCandidate {
            guard canonicalContent[candidate].character == timedContent[timedIndex].character else {
                continue
            }
            if hasMatchingContentRun(
                canonicalContent: canonicalContent,
                canonicalIndex: candidate,
                timedContent: timedContent,
                timedIndex: timedIndex
            ) {
                return candidate
            }
        }
        return nil
    }

    private static func hasMatchingContentRun(
        canonicalContent: [(index: Int, character: Character)],
        canonicalIndex: Int,
        timedContent: [SpeakerTextTimedCharacter],
        timedIndex: Int
    ) -> Bool {
        let availableLength = min(
            canonicalContent.count - canonicalIndex,
            timedContent.count - timedIndex
        )
        let anchorLength = min(4, availableLength)
        guard anchorLength > 0 else { return false }

        for offset in 0..<anchorLength {
            guard canonicalContent[canonicalIndex + offset].character
                    == timedContent[timedIndex + offset].character else {
                return false
            }
        }
        return true
    }
}
