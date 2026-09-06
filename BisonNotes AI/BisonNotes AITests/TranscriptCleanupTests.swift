import XCTest
@testable import BisonNotes_AI

final class TranscriptCleanupTests: XCTestCase {

    @MainActor
    func testCleanupSettingsAreOffByDefaultAndUseTheFixedPromptContract() {
        let defaults = UserDefaults(suiteName: "TranscriptCleanupTests")!
        defaults.removePersistentDomain(forName: "TranscriptCleanupTests")
        defer { defaults.removePersistentDomain(forName: "TranscriptCleanupTests") }

        XCTAssertFalse(TranscriptCleanupSettings.isEnabled(in: defaults))
        XCTAssertEqual(TranscriptCleanupSettings.modelId, "mlx-community/S1-mini-MLX-8bit")
        XCTAssertEqual(
            TranscriptCleanupSettings.modelRevision,
            "f0d7fe6b2f57e53f454f7da2110412f9820c490e"
        )
        XCTAssertEqual(TranscriptCleanupSettings.modelAttribution, "S1-mini by Superwhisper")
        XCTAssertFalse(
            iCloudStorageManager.backedUpSettingsKeys.contains(TranscriptCleanupSettings.Keys.enabled)
        )
        XCTAssertEqual(
            TranscriptCleanupSettings.systemPrompt,
            "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
        )
        XCTAssertEqual(
            TranscriptCleanupSettings.userMessage(for: "um, hello"),
            "[Styling: semi-formal] [Structure: prose] [Context: general]\num, hello"
        )

        defaults.set(true, forKey: TranscriptCleanupSettings.Keys.enabled)
        XCTAssertTrue(TranscriptCleanupSettings.isEnabled(in: defaults))
        TranscriptCleanupSettings.reset(in: defaults)
        XCTAssertFalse(TranscriptCleanupSettings.isEnabled(in: defaults))
    }

    func testDisabledCleanupDoesNotAskTheNormalizerToLoadOrTokenize() async {
        let normalizer = FakeTranscriptNormalizer(ready: false)
        let coordinator = TranscriptCleanupCoordinator(
            normalizer: normalizer,
            availabilityProvider: { .available }
        )
        let segment = makeSegment(text: "hello")

        let result = await coordinator.clean(
            segments: [segment],
            configuration: TranscriptCleanupConfiguration(
                enabled: false,
                mode: .automatic,
                languageCode: "en"
            )
        )

        let stats = await normalizer.stats()
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.segments.map(\.id), [segment.id])
        XCTAssertEqual(stats.readinessChecks, 0)
        XCTAssertEqual(stats.tokenRequests, [])
        XCTAssertEqual(stats.normalizationRequests, [])
        XCTAssertEqual(stats.releaseCount, 0)
    }

    func testCleanupPreservesIdentityMappingsRawTextAndSummaryInput() throws {
        let createdAt = Date(timeIntervalSince1970: 123)
        let first = makeSegment(
            speaker: "Speaker 1",
            text: "we need to uh ship it",
            hasLeadingSpace: false,
            cleanup: TranscriptSegmentCleanup(
                normalizedText: "We need to ship it.",
                createdAt: createdAt
            )
        )
        let second = makeSegment(
            speaker: "Speaker 2",
            text: "by Friday",
            hasLeadingSpace: true,
            cleanup: TranscriptSegmentCleanup(
                normalizedText: "by Friday.",
                createdAt: createdAt
            )
        )
        let transcript = TranscriptData(
            id: UUID(),
            recordingId: UUID(),
            recordingURL: URL(fileURLWithPath: "/tmp/cleanup.m4a"),
            recordingName: "Cleanup",
            recordingDate: createdAt,
            segments: [first, second],
            speakerMappings: ["Speaker 1": "Alice", "Speaker 2": "Bob"]
        )

        XCTAssertEqual(transcript.plainText, "we need to uh ship it by Friday")
        XCTAssertEqual(transcript.fullText, "Alice: we need to uh ship it\nBob: by Friday")
        XCTAssertEqual(
            transcript.plainText(for: .cleaned),
            "We need to ship it. by Friday."
        )
        XCTAssertEqual(
            transcript.fullText(for: .cleaned),
            "Alice: We need to ship it.\nBob: by Friday."
        )
        XCTAssertEqual(
            transcript.textForSummarization,
            "Alice: we need to uh ship it\nBob: by Friday"
        )

        let preserved = transcript.preservingIdentity(
            segments: transcript.segments,
            speakerMappings: ["Speaker 1": "Alicia", "Speaker 2": "Bob"],
            lastModified: createdAt.addingTimeInterval(1)
        )
        XCTAssertEqual(preserved.id, transcript.id)
        XCTAssertEqual(preserved.recordingId, transcript.recordingId)
        XCTAssertEqual(preserved.segments.map(\.id), transcript.segments.map(\.id))
        XCTAssertEqual(preserved.segments.map(\.cleanup), transcript.segments.map(\.cleanup))
        XCTAssertEqual(preserved.fullText(for: .cleaned), "Alicia: We need to ship it.\nBob: by Friday.")

        let edited = first.withOriginalText("we will ship it")
        XCTAssertEqual(edited.id, first.id)
        XCTAssertEqual(edited.speaker, first.speaker)
        XCTAssertEqual(edited.startTime, first.startTime)
        XCTAssertNil(edited.cleanup)

        let encoded = try JSONEncoder().encode(transcript)
        let decoded = try JSONDecoder().decode(TranscriptData.self, from: encoded)
        XCTAssertEqual(decoded.id, transcript.id)
        XCTAssertEqual(decoded.segments.map(\.id), transcript.segments.map(\.id))
        XCTAssertEqual(decoded.segments.map(\.cleanup), transcript.segments.map(\.cleanup))

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var legacySegments = try XCTUnwrap(legacyObject["segments"] as? [[String: Any]])
        for index in legacySegments.indices {
            legacySegments[index].removeValue(forKey: "cleanup")
        }
        legacyObject["segments"] = legacySegments
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(TranscriptData.self, from: legacyData)
        XCTAssertTrue(legacyDecoded.segments.allSatisfy { $0.cleanup == nil })
        XCTAssertEqual(legacyDecoded.plainText, transcript.plainText)
    }

    func testCleanupIsAtomicAndDoesNotOverwritePriorCleanedValuesOnFailure() async {
        let firstCleanup = TranscriptSegmentCleanup(normalizedText: "Old first")
        let first = makeSegment(text: "first", cleanup: firstCleanup)
        let second = makeSegment(text: "second")
        let normalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [
                .success(generation(text: "New first", inputTokens: 5, outputTokens: 2)),
                .success(generation(text: "", inputTokens: 5, outputTokens: 0))
            ]
        )
        let coordinator = makeCoordinator(normalizer)

        let result = await coordinator.clean(
            segments: [first, second],
            configuration: enabledEnglishConfiguration()
        )

        let stats = await normalizer.stats()
        XCTAssertEqual(result.warning, .invalidOutput)
        XCTAssertEqual(result.segments.map(\.id), [first.id, second.id])
        XCTAssertEqual(result.segments.map(\.text), [first.text, second.text])
        XCTAssertEqual(result.segments.first?.cleanup, firstCleanup)
        XCTAssertNil(result.segments.last?.cleanup)
        XCTAssertEqual(stats.releaseCount, 1)
    }

    func testLongSegmentSplitsWithinItsOwnBoundaryWithoutCrossingTurns() async {
        let words = (1...12).map { "word\($0)" }
        let first = makeSegment(speaker: "Speaker 1", text: words.joined(separator: " "))
        let second = makeSegment(speaker: "Speaker 2", text: "separate turn")
        let normalizer = FakeTranscriptNormalizer(ready: true, tokenScale: 100)
        let coordinator = makeCoordinator(normalizer)

        let result = await coordinator.clean(
            segments: [first, second],
            configuration: enabledEnglishConfiguration()
        )

        let stats = await normalizer.stats()
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments.map(\.id), [first.id, second.id])
        XCTAssertEqual(result.segments.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result.segments[0].cleanup?.normalizedText, first.text)
        XCTAssertEqual(result.segments[1].cleanup?.normalizedText, second.text)
        XCTAssertEqual(stats.normalizationRequests.count, 3)
        XCTAssertTrue(stats.normalizationRequests.allSatisfy { $0.split(whereSeparator: { $0.isWhitespace }).count <= 10 })
        XCTAssertFalse(stats.normalizationRequests.contains { $0.contains("separate") && $0.contains("word1") })
    }

    func testFillerMayNormalizeToEmptyButSubstantiveEmptyOutputFails() async {
        let filler = makeSegment(text: "um, uh")
        let fillerNormalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [.success(generation(text: "", inputTokens: 4, outputTokens: 0))]
        )
        let fillerResult = await makeCoordinator(fillerNormalizer).clean(
            segments: [filler],
            configuration: enabledEnglishConfiguration()
        )
        XCTAssertNil(fillerResult.warning)
        XCTAssertEqual(fillerResult.segments.first?.cleanup?.normalizedText, "")

        let substantive = makeSegment(text: "the deadline is Friday")
        let substantiveNormalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [.success(generation(text: "", inputTokens: 8, outputTokens: 0))]
        )
        let substantiveResult = await makeCoordinator(substantiveNormalizer).clean(
            segments: [substantive],
            configuration: enabledEnglishConfiguration()
        )
        XCTAssertEqual(substantiveResult.warning, .invalidOutput)
        XCTAssertNil(substantiveResult.segments.first?.cleanup)
    }

    func testShortSubstantiveEmptyOutputRetainsTheOriginalFragment() async {
        let segment = makeSegment(text: "in.")
        let normalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [.success(generation(text: "", inputTokens: 80, outputTokens: 0))]
        )

        let result = await makeCoordinator(normalizer).clean(
            segments: [segment],
            configuration: enabledEnglishConfiguration()
        )

        XCTAssertNil(result.warning)
        XCTAssertEqual(result.segments.first?.cleanup?.normalizedText, "in.")
    }

    func testGeneratedSpeakerLabelsAreRejectedAsNonPlainOutput() async {
        let segment = makeSegment(text: "the deadline is Friday")
        let normalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [
                .success(generation(text: "Speaker 1: the deadline is Friday", inputTokens: 8, outputTokens: 7))
            ]
        )

        let result = await makeCoordinator(normalizer).clean(
            segments: [segment],
            configuration: enabledEnglishConfiguration()
        )

        XCTAssertEqual(result.warning, .invalidOutput)
        XCTAssertNil(result.segments.first?.cleanup)
    }

    func testGeneratedSpecialTokensAreRejectedAsNonPlainOutput() async {
        let segment = makeSegment(text: "the deadline is Friday")
        let normalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [
                .success(generation(text: "The deadline is Friday.</s>", inputTokens: 8, outputTokens: 5))
            ]
        )

        let result = await makeCoordinator(normalizer).clean(
            segments: [segment],
            configuration: enabledEnglishConfiguration()
        )

        XCTAssertEqual(result.warning, .invalidOutput)
        XCTAssertNil(result.segments.first?.cleanup)
    }

    func testLengthTerminationGetsOneBoundedSplitRetryThenFailsAtomically() async {
        let segment = makeSegment(text: "one two three four")
        let length = generation(text: "partial", inputTokens: 20, outputTokens: 20, finishReason: .length)
        let normalizer = FakeTranscriptNormalizer(
            ready: true,
            generations: [.success(length), .success(length), .success(length)]
        )

        let result = await makeCoordinator(normalizer).clean(
            segments: [segment],
            configuration: enabledEnglishConfiguration()
        )

        let stats = await normalizer.stats()
        XCTAssertEqual(result.warning, .resourceFailure)
        XCTAssertNil(result.segments.first?.cleanup)
        // The first retry piece is itself length-terminated, so the
        // coordinator fails immediately rather than issuing the second retry
        // piece. The bounded retry still results in exactly two model calls.
        XCTAssertEqual(stats.normalizationRequests.count, 2)
    }

    func testKnownNonEnglishMetadataSkipsTheNormalizer() async {
        let normalizer = FakeTranscriptNormalizer(ready: true)
        let result = await makeCoordinator(normalizer).clean(
            segments: [makeSegment(text: "bonjour tout le monde")],
            configuration: TranscriptCleanupConfiguration(
                enabled: true,
                mode: .automatic,
                languageCode: "fr-FR"
            )
        )

        let stats = await normalizer.stats()
        XCTAssertEqual(result.warning, .nonEnglish)
        XCTAssertEqual(stats.readinessChecks, 0)
        XCTAssertEqual(stats.normalizationRequests, [])
        XCTAssertEqual(stats.releaseCount, 0)
    }

    func testSourceSnapshotDetectsRawEditsButIgnoresDerivedCleanup() {
        let transcript = makeTranscript(
            segments: [makeSegment(text: "original", cleanup: TranscriptSegmentCleanup(normalizedText: "Original."))]
        )
        let snapshot = TranscriptCleanupSourceSnapshot(transcript: transcript)
        let newCleanup = transcript.segments[0].withCleanup(
            TranscriptSegmentCleanup(normalizedText: "Original!", createdAt: Date(timeIntervalSince1970: 99))
        )
        let derivedOnlyChange = transcript.preservingIdentity(
            segments: [newCleanup],
            lastModified: transcript.lastModified
        )
        let rawEdit = transcript.preservingIdentity(
            segments: [transcript.segments[0].withOriginalText("changed")],
            lastModified: transcript.lastModified
        )

        XCTAssertTrue(snapshot.matches(derivedOnlyChange))
        XCTAssertFalse(snapshot.matches(rawEdit))
        XCTAssertFalse(snapshot.matches(nil))
    }

    #if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
    func testCleanupModelLocatorUsesTheMLXMaterializedCache() {
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let expectedDirectory = cachesDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("mlx-community", isDirectory: true)
            .appendingPathComponent("S1-mini-MLX-8bit", isDirectory: true)

        XCTAssertEqual(
            TranscriptCleanupModelLocator.directory.standardizedFileURL,
            expectedDirectory.standardizedFileURL
        )
    }
    #endif
}

private extension TranscriptCleanupTests {
    struct FakeStats: Sendable {
        let readinessChecks: Int
        let tokenRequests: [String]
        let normalizationRequests: [String]
        let releaseCount: Int
    }

    actor FakeTranscriptNormalizer: TranscriptCleanupNormalizing {
        let ready: Bool
        let tokenScale: Int
        var generations: [Result<TranscriptCleanupGeneration, TranscriptCleanupNormalizerError>]
        private(set) var readinessChecks = 0
        private(set) var tokenRequests: [String] = []
        private(set) var normalizationRequests: [String] = []
        private(set) var releaseCount = 0

        init(
            ready: Bool,
            generations: [Result<TranscriptCleanupGeneration, TranscriptCleanupNormalizerError>] = [],
            tokenScale: Int = 1
        ) {
            self.ready = ready
            self.generations = generations
            self.tokenScale = tokenScale
        }

        var isReady: Bool {
            get async {
                readinessChecks += 1
                return ready
            }
        }

        func renderedRequestTokenCount(for rawText: String) async throws -> Int {
            tokenRequests.append(rawText)
            return max(1, rawText.split(whereSeparator: { $0.isWhitespace }).count * tokenScale)
        }

        func normalize(_ rawText: String) async throws -> TranscriptCleanupGeneration {
            normalizationRequests.append(rawText)
            guard !generations.isEmpty else {
                return TranscriptCleanupGeneration(
                    text: rawText,
                    inputTokenCount: max(1, rawText.split(whereSeparator: { $0.isWhitespace }).count * tokenScale),
                    outputTokenCount: 1,
                    finishReason: .stop
                )
            }
            switch generations.removeFirst() {
            case .success(let generation):
                return generation
            case .failure(let error):
                throw error
            }
        }

        func releaseResources() async {
            releaseCount += 1
        }

        func stats() -> FakeStats {
            FakeStats(
                readinessChecks: readinessChecks,
                tokenRequests: tokenRequests,
                normalizationRequests: normalizationRequests,
                releaseCount: releaseCount
            )
        }
    }

    func makeCoordinator(_ normalizer: FakeTranscriptNormalizer) -> TranscriptCleanupCoordinator {
        // The fake availability keeps these orchestration tests independent of
        // whether they are running on a simulator or a supported device.
        return TranscriptCleanupCoordinator(
            normalizer: normalizer,
            availabilityProvider: { .available }
        )
    }

    func enabledEnglishConfiguration() -> TranscriptCleanupConfiguration {
        TranscriptCleanupConfiguration(enabled: true, mode: .automatic, languageCode: "en")
    }

    func makeSegment(
        speaker: String = "Speaker",
        text: String,
        hasLeadingSpace: Bool = true,
        cleanup: TranscriptSegmentCleanup? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            speaker: speaker,
            text: text,
            startTime: 1,
            endTime: 2,
            hasLeadingSpace: hasLeadingSpace,
            cleanup: cleanup
        )
    }

    func makeTranscript(segments: [TranscriptSegment]) -> TranscriptData {
        TranscriptData(
            id: UUID(),
            recordingId: UUID(),
            recordingURL: URL(fileURLWithPath: "/tmp/cleanup.m4a"),
            recordingName: "Cleanup",
            recordingDate: Date(timeIntervalSince1970: 1),
            segments: segments
        )
    }

    func generation(
        text: String,
        inputTokens: Int,
        outputTokens: Int,
        finishReason: TranscriptCleanupFinishReason = .stop
    ) -> TranscriptCleanupGeneration {
        TranscriptCleanupGeneration(
            text: text,
            inputTokenCount: inputTokens,
            outputTokenCount: outputTokens,
            finishReason: finishReason
        )
    }
}
