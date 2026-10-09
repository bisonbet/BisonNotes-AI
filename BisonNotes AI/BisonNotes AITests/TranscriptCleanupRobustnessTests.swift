import XCTest
@testable import BisonNotes_AI

/// Partial progress, checkpoint/resume, progress reporting, and the save-first
/// queue for S1-mini transcript cleanup. Every test scripts the normalizer;
/// none loads a model.
final class TranscriptCleanupRobustnessTests: XCTestCase {

    // MARK: - Coordinator

    /// One passage that fails inside a long segment keeps its own original
    /// text; the passages around it are still cleaned and the run goes on.
    func testFailedPieceInsideALongSegmentKeepsOnlyThatPieceOriginal() async {
        let words = (1...25).map { "word\($0)" }
        let segment = makeSegment(text: words.joined(separator: " "))
        // 100 tokens a word against a 1,000-token budget: pieces of 10, 10, 5.
        let normalizer = ScriptedNormalizer(tokenScale: 100, failingPieces: [1])

        let result = await makeCoordinator(normalizer).clean(
            segments: [segment],
            configuration: englishConfiguration()
        )

        let requests = await normalizer.normalizationRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(result.warning, .partiallyCleaned(1))
        XCTAssertEqual(result.cleanedSegmentCount, 1)
        let cleaned = result.segments.first?.cleanup?.normalizedText
        XCTAssertEqual(
            cleaned,
            [ScriptedNormalizer.cleaned(requests[0]), requests[1], ScriptedNormalizer.cleaned(requests[2])]
                .joined(separator: " "),
            "Only the failed passage keeps its original text"
        )
    }

    /// A run in which nothing at all could be cleaned still keeps the original
    /// transcript untouched and reports why, as before.
    func testRunThatCleansNothingReportsTheFailureAndKeepsTheOriginal() async {
        let segments = [
            makeSegment(text: "first segment with several words"),
            makeSegment(text: "second segment with several words")
        ]
        let normalizer = ScriptedNormalizer(failingPieces: [0, 1])

        let result = await makeCoordinator(normalizer).clean(
            segments: segments,
            configuration: englishConfiguration()
        )

        XCTAssertEqual(result.warning, .invalidOutput)
        XCTAssertEqual(result.cleanedSegmentCount, 0)
        XCTAssertTrue(result.segments.allSatisfy { $0.cleanup == nil })
    }

    func testProgressCountsEveryPlannedPassageInOrder() async {
        let segments = [
            makeSegment(text: (1...15).map { "a\($0)" }.joined(separator: " ")),
            makeSegment(text: "short turn"),
            makeSegment(text: "um, uh")
        ]
        let normalizer = ScriptedNormalizer(tokenScale: 100)
        let recorder = ProgressRecorder()

        _ = await makeCoordinator(normalizer).clean(
            segments: segments,
            configuration: englishConfiguration(),
            progress: { update in recorder.append(update) }
        )

        let updates = recorder.values
        // Two passages for the long turn, one for the short turn; the
        // hesitation-only turn needs no model call and is not a passage.
        XCTAssertEqual(updates.first, TranscriptCleanupProgress(completedPieces: 0, totalPieces: 3))
        XCTAssertEqual(updates.last, TranscriptCleanupProgress(completedPieces: 3, totalPieces: 3))
        XCTAssertEqual(updates.map(\.completedPieces), [0, 1, 2, 3])
    }

    /// A resumed run skips passages the checkpoint already holds — including
    /// one recorded as kept-original, which a temperature-0 retry would only
    /// fail again — and records the ones it generates.
    func testCheckpointSkipsFinishedPassagesAndRecordsNewOnes() async {
        let first = makeSegment(text: "first segment text")
        let second = makeSegment(text: "second segment text")
        let third = makeSegment(text: "third segment text")
        let checkpoint = MemoryCheckpoint()
        await checkpoint.seed(
            .cleaned("First, from before."),
            forPiece: TranscriptCleanupCoordinator.checkpointKey(segmentID: first.id, index: 0, piece: first.text)
        )
        await checkpoint.seed(
            .keptOriginal,
            forPiece: TranscriptCleanupCoordinator.checkpointKey(segmentID: second.id, index: 0, piece: second.text)
        )
        let normalizer = ScriptedNormalizer()

        let result = await makeCoordinator(normalizer).clean(
            segments: [first, second, third],
            configuration: englishConfiguration(),
            checkpoint: checkpoint
        )

        let requests = await normalizer.normalizationRequests
        XCTAssertEqual(requests, [third.text], "Only the unfinished passage is generated")
        XCTAssertEqual(result.segments[0].cleanup?.normalizedText, "First, from before.")
        XCTAssertNil(result.segments[1].cleanup, "A kept-original passage is not retried")
        XCTAssertEqual(result.segments[2].cleanup?.normalizedText, ScriptedNormalizer.cleaned(third.text))
        XCTAssertEqual(result.warning, .partiallyCleaned(1))
        let recordedCount = await checkpoint.count
        XCTAssertEqual(recordedCount, 3)
    }

    /// An edited segment's text hashes differently, so a checkpoint entry for
    /// the old text is never applied to it.
    func testCheckpointKeyChangesWithThePassageText() {
        let id = UUID()
        XCTAssertNotEqual(
            TranscriptCleanupCoordinator.checkpointKey(segmentID: id, index: 0, piece: "the deadline is Friday"),
            TranscriptCleanupCoordinator.checkpointKey(segmentID: id, index: 0, piece: "the deadline is Monday")
        )
        XCTAssertEqual(
            TranscriptCleanupCoordinator.checkpointKey(segmentID: id, index: 2, piece: "same"),
            TranscriptCleanupCoordinator.checkpointKey(segmentID: id, index: 2, piece: "same")
        )
    }

    /// Hesitation-only turns clean to empty text without a model call. Short
    /// turns of words that can be a complete answer still go to the model.
    func testHesitationOnlyTurnsSkipTheModelButShortAnswersDoNot() async {
        let hesitation = makeSegment(text: "Um... uh, hmm.")
        let answer = makeSegment(text: "You know.")
        let normalizer = ScriptedNormalizer()

        let result = await makeCoordinator(normalizer).clean(
            segments: [hesitation, answer],
            configuration: englishConfiguration()
        )

        let requests = await normalizer.normalizationRequests
        XCTAssertEqual(requests, [answer.text])
        XCTAssertEqual(result.segments[0].cleanup?.normalizedText, "")
        XCTAssertNil(result.warning)
    }

    func testCancellationEndsTheRunWithoutAPartialResult() async {
        let segments = [
            makeSegment(text: "first segment text"),
            makeSegment(text: "second segment text")
        ]
        let normalizer = ScriptedNormalizer(cancellingPieces: [1])

        let result = await makeCoordinator(normalizer).clean(
            segments: segments,
            configuration: englishConfiguration()
        )

        XCTAssertEqual(result.warning, .cancelled)
        XCTAssertTrue(result.segments.allSatisfy { $0.cleanup == nil })
    }

    func testPreflightReportsBlockingConditionsWithoutLoadingTheModel() async {
        let segment = makeSegment(text: "the deadline is Friday")
        let notReady = ScriptedNormalizer(ready: false)
        let disabled = TranscriptCleanupConfiguration(enabled: false, mode: .automatic, languageCode: "en")

        let offResult = await makeCoordinator(notReady).preflight(segments: [segment], configuration: disabled)
        XCTAssertEqual(offResult, .notNeeded)
        let missingResult = await makeCoordinator(notReady).preflight(segments: [segment], configuration: englishConfiguration())
        XCTAssertEqual(missingResult, .blocked(.missingModel))

        let french = TranscriptCleanupConfiguration(enabled: true, mode: .automatic, languageCode: "fr")
        let frenchResult = await makeCoordinator(ScriptedNormalizer()).preflight(segments: [segment], configuration: french)
        XCTAssertEqual(frenchResult, .blocked(.nonEnglish))

        let unsupported = TranscriptCleanupCoordinator(
            normalizer: ScriptedNormalizer(),
            availabilityProvider: { .unsupported("Not here.") }
        )
        let unsupportedResult = await unsupported.preflight(segments: [segment], configuration: englishConfiguration())
        XCTAssertEqual(unsupportedResult, .blocked(.unsupportedPlatform("Not here.")))

        let readyResult = await makeCoordinator(ScriptedNormalizer()).preflight(segments: [segment], configuration: englishConfiguration())
        XCTAssertEqual(readyResult, .ready)
        let tokenRequests = await notReady.tokenRequestCount
        XCTAssertEqual(tokenRequests, 0)
    }

    func testPartialAndPausedWarningsTellTheUserWhatWasKept() {
        XCTAssertTrue(TranscriptCleanupWarning.partiallyCleaned(2).keepsCleanedResult)
        XCTAssertFalse(TranscriptCleanupWarning.invalidOutput.keepsCleanedResult)
        XCTAssertFalse(TranscriptCleanupWarning.paused.keepsCleanedResult)
        XCTAssertTrue(TranscriptCleanupWarning.partiallyCleaned(1).userVisibleMessage.contains("1 passage "))
        XCTAssertTrue(TranscriptCleanupWarning.partiallyCleaned(3).userVisibleMessage.contains("3 passages"))
        XCTAssertTrue(TranscriptCleanupWarning.paused.userVisibleMessage.contains("Finished passages are kept"))
    }

    // MARK: - File checkpoint

    func testFileCheckpointSurvivesANewInstanceAndRemoveClearsIt() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingId = UUID()

        let writer = TranscriptCleanupFileCheckpoint(recordingId: recordingId, directory: directory)
        await writer.record(.cleaned("Done."), forPiece: "a")
        await writer.record(.keptOriginal, forPiece: "b")

        let reader = TranscriptCleanupFileCheckpoint(recordingId: recordingId, directory: directory)
        let a = await reader.outcome(forPiece: "a")
        let b = await reader.outcome(forPiece: "b")
        XCTAssertEqual(a, .cleaned("Done."))
        XCTAssertEqual(b, .keptOriginal)

        await reader.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.url.path))
        let afterRemove = await TranscriptCleanupFileCheckpoint(recordingId: recordingId, directory: directory)
            .outcome(forPiece: "a")
        XCTAssertNil(afterRemove)
    }

    /// A checkpoint from another model revision or prompt would mix outputs of
    /// two different normalizers in one transcript.
    func testFileCheckpointFromAnotherModelRevisionIsIgnored() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stale.json")
        let stale = """
        {"modelRevision":"old-revision","promptVersion":"\(TranscriptCleanupSettings.promptVersion)",
         "updatedAt":0,"pieces":{"a":{"cleaned":{"_0":"From the old model."}}}}
        """
        try Data(stale.utf8).write(to: url)

        let outcome = await TranscriptCleanupFileCheckpoint(url: url).outcome(forPiece: "a")
        XCTAssertNil(outcome)
    }

    func testCheckpointPruneRemovesOnlyOldFiles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.json")
        let fresh = directory.appendingPathComponent("fresh.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -10 * 24 * 60 * 60)],
            ofItemAtPath: old.path
        )

        TranscriptCleanupCheckpointStore.prune(maximumAge: 7 * 24 * 60 * 60, in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - Queue

    @MainActor
    func testQueueCleansTheSavedTranscriptThenDropsItsIntentAndCheckpoint() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        let finished = expectation(forNotification: TranscriptCleanupQueue.didFinishNotification, object: nil) { note in
            note.userInfo?["cleaned"] as? Bool == true
        }

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        await harness.queue.waitForCurrentRun()

        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(harness.store.saveCount, 1)
        XCTAssertEqual(
            harness.store.transcript?.segments.first?.cleanup?.normalizedText,
            ScriptedNormalizer.cleaned("the deadline is Friday")
        )
        XCTAssertTrue(harness.queue.intents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.checkpointURL.path))
    }

    /// An intent whose transcript was edited after it was queued would save a
    /// cleanup of text that no longer exists, so it is dropped unrun.
    @MainActor
    func testQueueDropsAnIntentWhoseTranscriptChanged() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        let source = harness.snapshot()
        harness.store.replaceText(with: "the deadline is Monday")

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: source, languageCode: "en")
        await harness.queue.waitForCurrentRun()

        XCTAssertEqual(harness.store.saveCount, 0)
        let requests = await harness.normalizer.normalizationRequests
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(harness.queue.intents.isEmpty)
    }

    /// Queued work waits while the app may not use the GPU, survives a new
    /// queue instance (a relaunch), and runs once it is allowed to.
    @MainActor
    func testQueueWaitsInTheBackgroundAndSurvivesARelaunch() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.isForeground = false

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        await harness.queue.waitForCurrentRun()
        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertEqual(harness.queue.intents.count, 1)

        let relaunched = harness.makeQueue()
        relaunched.start()
        XCTAssertEqual(relaunched.intents.map(\.recordingId), [harness.recordingId])

        harness.isForeground = true
        relaunched.kick()
        await relaunched.waitForCurrentRun()
        XCTAssertEqual(harness.store.saveCount, 1)
        XCTAssertTrue(relaunched.intents.isEmpty)
    }

    /// Pausing mid-run keeps the intent and the passages already finished; the
    /// resumed run generates only what is left.
    @MainActor
    func testPausedRunResumesFromItsCheckpoint() async throws {
        let segments = [
            makeSegment(text: "first segment text"),
            makeSegment(text: "second segment text"),
            makeSegment(text: "third segment text")
        ]
        let normalizer = ScriptedNormalizer(blockingPieces: [1])
        let harness = try QueueHarness(segments: segments, normalizer: normalizer)

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        // Let the run finish passage 0 and block inside passage 1.
        try await waitUntil { await normalizer.isBlocked }
        harness.queue.pause()
        await harness.queue.waitForCurrentRun()

        XCTAssertEqual(harness.store.saveCount, 0, "A paused run saves nothing")
        XCTAssertEqual(harness.queue.intents.count, 1, "A paused run keeps its intent")

        await normalizer.unblock()
        harness.queue.kick()
        await harness.queue.waitForCurrentRun()

        let requests = await normalizer.normalizationRequests
        XCTAssertEqual(
            requests,
            [segments[0].text, segments[1].text, segments[1].text, segments[2].text],
            "Passage 0 came from the checkpoint; only the interrupted and remaining passages ran again"
        )
        XCTAssertEqual(harness.store.saveCount, 1)
        XCTAssertTrue(harness.store.transcript?.segments.allSatisfy { $0.cleanup != nil } == true)
    }

    // MARK: - Helpers

    private func makeCoordinator(_ normalizer: ScriptedNormalizer) -> TranscriptCleanupCoordinator {
        TranscriptCleanupCoordinator(normalizer: normalizer, availabilityProvider: { .available })
    }

    private func englishConfiguration() -> TranscriptCleanupConfiguration {
        TranscriptCleanupConfiguration(enabled: true, mode: .automatic, languageCode: "en")
    }

    private func makeSegment(text: String, cleanup: TranscriptSegmentCleanup? = nil) -> TranscriptSegment {
        TranscriptSegment(speaker: "Speaker", text: text, startTime: 0, endTime: 1, cleanup: cleanup)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-robustness-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

// MARK: - Fakes

/// Echoes each passage back in a recognisable cleaned form, failing, cancelling
/// or blocking on the passages it is told to, counted in call order.
private actor ScriptedNormalizer: TranscriptCleanupNormalizing {
    private let ready: Bool
    private let tokenScale: Int
    private let failingPieces: Set<Int>
    private let cancellingPieces: Set<Int>
    private let blockingPieces: Set<Int>
    private var released = false
    private(set) var isBlocked = false
    private(set) var normalizationRequests: [String] = []
    private(set) var tokenRequestCount = 0

    init(
        ready: Bool = true,
        tokenScale: Int = 1,
        failingPieces: Set<Int> = [],
        cancellingPieces: Set<Int> = [],
        blockingPieces: Set<Int> = []
    ) {
        self.ready = ready
        self.tokenScale = tokenScale
        self.failingPieces = failingPieces
        self.cancellingPieces = cancellingPieces
        self.blockingPieces = blockingPieces
    }

    static func cleaned(_ text: String) -> String { "Clean(\(text))" }

    var isReady: Bool { ready }

    func renderedRequestTokenCount(for rawText: String) async throws -> Int {
        tokenRequestCount += 1
        return max(1, rawText.split(whereSeparator: \.isWhitespace).count * tokenScale)
    }

    func normalize(_ rawText: String) async throws -> TranscriptCleanupGeneration {
        let index = normalizationRequests.count
        normalizationRequests.append(rawText)
        if blockingPieces.contains(index), !released {
            isBlocked = true
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        if cancellingPieces.contains(index) {
            throw CancellationError()
        }
        let words = rawText.split(whereSeparator: \.isWhitespace).count
        if failingPieces.contains(index) {
            return TranscriptCleanupGeneration(
                text: "",
                inputTokenCount: max(1, words * tokenScale),
                outputTokenCount: 0,
                finishReason: .stop
            )
        }
        return TranscriptCleanupGeneration(
            text: Self.cleaned(rawText),
            inputTokenCount: max(1, words * tokenScale),
            outputTokenCount: 1,
            finishReason: .stop
        )
    }

    func unblock() {
        released = true
        isBlocked = false
    }

    func releaseResources() async {}
}

private actor MemoryCheckpoint: TranscriptCleanupCheckpointing {
    private var pieces: [String: TranscriptCleanupPieceOutcome] = [:]

    var count: Int { pieces.count }

    func seed(_ outcome: TranscriptCleanupPieceOutcome, forPiece key: String) {
        pieces[key] = outcome
    }

    func outcome(forPiece key: String) async -> TranscriptCleanupPieceOutcome? {
        pieces[key]
    }

    func record(_ outcome: TranscriptCleanupPieceOutcome, forPiece key: String) async {
        pieces[key] = outcome
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TranscriptCleanupProgress] = []

    func append(_ update: TranscriptCleanupProgress) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    var values: [TranscriptCleanupProgress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

@MainActor
private final class MemoryQueueStore: TranscriptCleanupQueueStore {
    private(set) var transcript: TranscriptData?
    private(set) var saveCount = 0

    init(transcript: TranscriptData) {
        self.transcript = transcript
    }

    var isAvailable: Bool { true }

    func transcript(for recordingId: UUID) throws -> TranscriptData? {
        transcript?.recordingId == recordingId ? transcript : nil
    }

    func saveCleanedSegments(_ segments: [TranscriptSegment], for transcript: TranscriptData, recordingId: UUID) throws {
        saveCount += 1
        self.transcript = transcript.preservingIdentity(segments: segments)
    }

    /// Simulates the user editing the saved transcript.
    func replaceText(with text: String) {
        guard let transcript else { return }
        self.transcript = transcript.preservingIdentity(
            segments: transcript.segments.map { $0.withOriginalText(text) },
            lastModified: Date(timeIntervalSinceNow: 60)
        )
    }
}

@MainActor
private final class QueueHarness {
    let recordingId = UUID()
    let directory: URL
    let store: MemoryQueueStore
    let normalizer: ScriptedNormalizer
    var isForeground = true
    private(set) var queue: TranscriptCleanupQueue!

    init(segments: [TranscriptSegment], normalizer: ScriptedNormalizer = ScriptedNormalizer()) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanup-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.normalizer = normalizer
        store = MemoryQueueStore(
            transcript: TranscriptData(
                id: UUID(),
                recordingId: recordingId,
                recordingURL: URL(fileURLWithPath: "/tmp/queue.m4a"),
                recordingName: "Queue",
                recordingDate: Date(timeIntervalSince1970: 1),
                segments: segments,
                lastModified: Date(timeIntervalSince1970: 10)
            )
        )
        queue = makeQueue()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var checkpointURL: URL {
        directory.appendingPathComponent("checkpoints/\(recordingId.uuidString).json")
    }

    func snapshot() -> TranscriptCleanupSourceSnapshot {
        TranscriptCleanupSourceSnapshot(transcript: store.transcript)
    }

    func makeQueue() -> TranscriptCleanupQueue {
        TranscriptCleanupQueue(
            coordinator: TranscriptCleanupCoordinator(normalizer: normalizer, availabilityProvider: { .available }),
            store: store,
            queueFileURL: directory.appendingPathComponent("queue.json"),
            checkpointDirectory: directory.appendingPathComponent("checkpoints", isDirectory: true),
            canRunNow: { [unowned self] in self.isForeground },
            observesLifecycle: false
        )
    }
}
