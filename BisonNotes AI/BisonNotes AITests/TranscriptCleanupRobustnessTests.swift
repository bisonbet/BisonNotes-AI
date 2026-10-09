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

        let url = TranscriptCleanupCheckpointStore.url(for: recordingId, in: directory)
        let writer = TranscriptCleanupFileCheckpoint(url: url)
        await writer.record(.cleaned("Done."), forPiece: "a")
        await writer.record(.keptOriginal, forPiece: "b")
        await writer.flush()

        let reader = TranscriptCleanupFileCheckpoint(url: url)
        let a = await reader.outcome(forPiece: "a")
        let b = await reader.outcome(forPiece: "b")
        XCTAssertEqual(a, .cleaned("Done."))
        XCTAssertEqual(b, .keptOriginal)

        await reader.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reader.url.path))
        let afterRemove = await TranscriptCleanupFileCheckpoint(url: url).outcome(forPiece: "a")
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

    /// Writes are batched; a flush makes the rest durable, and the store hands
    /// every caller the same instance so two writers cannot clobber each other.
    func testCheckpointBatchesWritesAndTheStoreSharesOneInstance() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recordingId = UUID()
        let first = TranscriptCleanupCheckpointStore.checkpoint(for: recordingId, in: directory)
        let second = TranscriptCleanupCheckpointStore.checkpoint(for: recordingId, in: directory)
        XCTAssertTrue(first === second)

        for index in 0..<(TranscriptCleanupFileCheckpoint.writeBatchSize * 2 + 3) {
            await first.record(.cleaned("\(index)"), forPiece: "\(index)")
        }
        await first.flush()
        let reread = await TranscriptCleanupFileCheckpoint(url: first.url).recordedPieceCount()
        XCTAssertEqual(reread, TranscriptCleanupFileCheckpoint.writeBatchSize * 2 + 3)

        TranscriptCleanupCheckpointStore.discard(for: recordingId, in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertFalse(TranscriptCleanupCheckpointStore.checkpoint(for: recordingId, in: directory) === first)
    }

    /// A pause that interrupts a generation can surface as an ordinary failed
    /// generation. It must end the run as cancelled and leave the interrupted
    /// passage out of the checkpoint, so the resumed run cleans it.
    @MainActor
    func testInterruptedGenerationIsNeverCheckpointedAsAFailure() async throws {
        let segments = [
            makeSegment(text: "first segment text"),
            makeSegment(text: "second segment text")
        ]
        let normalizer = ScriptedNormalizer(blockingPieces: [1], errorWhenCancelled: .generationFailed)
        let checkpoint = MemoryCheckpoint()
        let coordinator = makeCoordinator(normalizer)
        let configuration = englishConfiguration()

        let run = Task {
            await coordinator.clean(segments: segments, configuration: configuration, checkpoint: checkpoint)
        }
        try await waitUntil { await normalizer.isBlocked }
        run.cancel()
        let result = await run.value

        XCTAssertEqual(result.warning, .cancelled)
        let interrupted = await checkpoint.outcome(
            forPiece: TranscriptCleanupCoordinator.checkpointKey(segmentID: segments[1].id, index: 0, piece: segments[1].text)
        )
        XCTAssertNil(interrupted, "The interrupted passage must be retried on resume")
        let recordedCount = await checkpoint.count
        XCTAssertEqual(recordedCount, 1, "Only the passage that finished is recorded")
    }

    /// A timeout or GPU error is retried on resume; output the model rejected
    /// would be rejected again at temperature 0, so it is remembered.
    func testOnlyRepeatableFailuresAreCheckpointed() async {
        let segments = [
            makeSegment(text: "first segment with several words"),
            makeSegment(text: "second segment with several words"),
            makeSegment(text: "third segment with several words")
        ]
        let normalizer = ScriptedNormalizer(failingPieces: [0], throwingPieces: [1: .generationFailed])
        let checkpoint = MemoryCheckpoint()

        let result = await makeCoordinator(normalizer).clean(
            segments: segments,
            configuration: englishConfiguration(),
            checkpoint: checkpoint
        )

        XCTAssertEqual(result.warning, .partiallyCleaned(2))
        let rejected = await checkpoint.outcome(
            forPiece: TranscriptCleanupCoordinator.checkpointKey(segmentID: segments[0].id, index: 0, piece: segments[0].text)
        )
        let timedOut = await checkpoint.outcome(
            forPiece: TranscriptCleanupCoordinator.checkpointKey(segmentID: segments[1].id, index: 0, piece: segments[1].text)
        )
        XCTAssertEqual(rejected, .keptOriginal)
        XCTAssertNil(timedOut)
    }

    /// Resuming a checkpoint in which every passage was kept original cleans
    /// nothing, and must say so rather than report "Transcript cleaned".
    func testResumedRunThatCleansNothingReportsAFailure() async {
        let segment = makeSegment(text: "the deadline is Friday")
        let checkpoint = MemoryCheckpoint()
        await checkpoint.seed(
            .keptOriginal,
            forPiece: TranscriptCleanupCoordinator.checkpointKey(segmentID: segment.id, index: 0, piece: segment.text)
        )

        let result = await makeCoordinator(ScriptedNormalizer()).clean(
            segments: [segment],
            configuration: englishConfiguration(),
            checkpoint: checkpoint
        )

        XCTAssertEqual(result.warning, .invalidOutput)
        XCTAssertEqual(result.cleanedSegmentCount, 0)
    }

    /// A hesitation-only turn cleaned locally must not turn a run in which the
    /// model failed every real passage into a "partially cleaned" success.
    func testHesitationTurnDoesNotMaskARunThatFailedEveryRealPassage() async {
        let segments = [
            makeSegment(text: "Um."),
            makeSegment(text: "the deadline is Friday")
        ]
        let normalizer = ScriptedNormalizer(failingPieces: [0])

        let result = await makeCoordinator(normalizer).clean(segments: segments, configuration: englishConfiguration())

        XCTAssertEqual(result.warning, .invalidOutput)
        XCTAssertTrue(result.segments.allSatisfy { $0.cleanup == nil })
    }

    /// A queued cleanup's checkpoint survives an age-based prune; only
    /// abandoned checkpoints are removed.
    func testCheckpointPruneKeepsPendingRecordings() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = UUID()
        let abandoned = UUID()
        let old = Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)
        for id in [pending, abandoned] {
            let url = TranscriptCleanupCheckpointStore.url(for: id, in: directory)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }

        TranscriptCleanupCheckpointStore.prune(maximumAge: 7 * 24 * 60 * 60, in: directory, keeping: [pending])

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TranscriptCleanupCheckpointStore.url(for: pending, in: directory).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TranscriptCleanupCheckpointStore.url(for: abandoned, in: directory).path
        ))
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

    /// A job that finishes before the queue is started must not overwrite the
    /// saved queue — the earlier recordings would never be cleaned.
    @MainActor
    func testEnqueueBeforeStartMergesWithTheSavedQueue() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.isForeground = false
        let earlier = UUID()
        let saved = harness.makeQueue()
        saved.start()
        saved.enqueue(recordingId: earlier, source: harness.snapshot(), languageCode: "en")

        let relaunched = harness.makeQueue()
        relaunched.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")

        XCTAssertEqual(Set(relaunched.intents.map(\.recordingId)), [earlier, harness.recordingId])
        let reloaded = harness.makeQueue()
        reloaded.start()
        XCTAssertEqual(Set(reloaded.intents.map(\.recordingId)), [earlier, harness.recordingId])
    }

    @MainActor
    func testTurningCleanupOffDropsQueuedWork() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.isCleanupEnabled = false

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        await harness.queue.waitForCurrentRun()

        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertTrue(harness.queue.intents.isEmpty)
    }

    /// Turning cleanup off must stop a run that is already generating, not
    /// only runs that have not started.
    @MainActor
    func testTurningCleanupOffCancelsTheActiveRun() async throws {
        let normalizer = ScriptedNormalizer(blockingPieces: [1])
        let harness = try QueueHarness(
            segments: [makeSegment(text: "first segment text"), makeSegment(text: "second segment text")],
            normalizer: normalizer
        )
        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        try await waitUntil { await normalizer.isBlocked }

        harness.isCleanupEnabled = false
        harness.queue.cleanupSettingDidChange()
        await harness.queue.waitForCurrentRun()

        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertTrue(harness.queue.intents.isEmpty, "A withdrawn run must not stay queued as if paused")
        harness.queue.kick()
        await harness.queue.waitForCurrentRun()
        let requests = await normalizer.normalizationRequests
        XCTAssertEqual(requests.count, 2, "Nothing runs again while cleanup is off")
    }

    /// If the setting changes by a path the observer misses, a run that
    /// finishes afterwards still must not save cleaned text.
    @MainActor
    func testRunThatFinishesAfterCleanupWasTurnedOffDoesNotSave() async throws {
        let normalizer = ScriptedNormalizer(blockingPieces: [0])
        let harness = try QueueHarness(
            segments: [makeSegment(text: "the deadline is Friday")],
            normalizer: normalizer
        )
        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        try await waitUntil { await normalizer.isBlocked }

        harness.isCleanupEnabled = false
        await normalizer.unblock()
        await harness.queue.waitForCurrentRun()

        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertTrue(harness.queue.intents.isEmpty)
        XCTAssertNil(harness.store.transcript?.segments.first?.cleanup)
    }

    /// A cancellation the queue did not ask for is a failure, not a pause;
    /// keeping the intent would restart it in a loop.
    @MainActor
    func testUnrequestedCancellationEndsTheIntent() async throws {
        let harness = try QueueHarness(
            segments: [makeSegment(text: "the deadline is Friday")],
            normalizer: ScriptedNormalizer(cancellingPieces: [0])
        )

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        await harness.queue.waitForCurrentRun()

        XCTAssertTrue(harness.queue.intents.isEmpty)
        XCTAssertEqual(harness.notifications.count, 1)
        let requests = await harness.normalizer.normalizationRequests
        XCTAssertEqual(requests.count, 1, "Ran once, not in a loop")
    }

    /// A queued run's outcome reaches the user even when no editor is open
    /// for that recording; an open editor shows it itself.
    @MainActor
    func testQueuedOutcomeNotifiesTheUserOnlyWhenNoEditorShowsIt() async throws {
        let segments = [
            makeSegment(text: "first segment with several words"),
            makeSegment(text: "second segment with several words")
        ]
        let harness = try QueueHarness(segments: segments, normalizer: ScriptedNormalizer(failingPieces: [0]))

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        await harness.queue.waitForCurrentRun()
        XCTAssertEqual(harness.notifications, [TranscriptCleanupWarning.partiallyCleaned(1).userVisibleMessage])

        let viewed = try QueueHarness(segments: segments, normalizer: ScriptedNormalizer(failingPieces: [0]))
        viewed.queue.start()
        viewed.queue.beginViewing(recordingId: viewed.recordingId)
        viewed.queue.enqueue(recordingId: viewed.recordingId, source: viewed.snapshot(), languageCode: "en")
        await viewed.queue.waitForCurrentRun()
        XCTAssertTrue(viewed.notifications.isEmpty)
    }

    @MainActor
    func testDeletingARecordingDiscardsItsIntentAndCheckpoint() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.isForeground = false
        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        let checkpoint = TranscriptCleanupCheckpointStore.checkpoint(
            for: harness.recordingId,
            in: harness.directory.appendingPathComponent("checkpoints", isDirectory: true)
        )
        await checkpoint.record(.cleaned("Secret."), forPiece: "a")
        await checkpoint.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.checkpointURL.path))

        harness.queue.discard(recordingId: harness.recordingId)

        XCTAssertTrue(harness.queue.intents.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.checkpointURL.path))
    }

    /// An app left closed past the prune age still resumes its queued cleanup
    /// from the checkpoint instead of redoing every finished passage.
    @MainActor
    func testStartDoesNotPruneAQueuedCleanupsCheckpoint() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.isForeground = false
        let queued = harness.makeQueue()
        queued.start()
        queued.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        try FileManager.default.createDirectory(
            at: harness.checkpointURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: harness.checkpointURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -30 * 24 * 60 * 60)],
            ofItemAtPath: harness.checkpointURL.path
        )

        let relaunched = harness.makeQueue()
        relaunched.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.checkpointURL.path))
    }

    /// A Cancel or pause that lands after the model has finished, but before
    /// the save, must still stop the save. The store's re-read before saving
    /// is where the test lands it.
    @MainActor
    func testCancellationAfterGenerationStillPreventsTheSave() async throws {
        for withdraw in [true, false] {
            let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
            let queue = harness.queue!
            let recordingId = harness.recordingId
            harness.store.onRead = { [weak harness] attempt in
                guard attempt == 2 else { return }
                if withdraw {
                    queue.cancel(recordingId: recordingId)
                } else {
                    // In the app a pause only comes from backgrounding, where
                    // the queue then declines to restart.
                    harness?.isForeground = false
                    queue.pause()
                }
            }

            queue.start()
            queue.enqueue(recordingId: recordingId, source: harness.snapshot(), languageCode: "en")
            await queue.waitForCurrentRun()

            XCTAssertEqual(harness.store.saveCount, 0, withdraw ? "withdrawn" : "paused")
            XCTAssertEqual(queue.intents.count, withdraw ? 0 : 1, "A pause keeps the intent; a withdrawal removes it")
        }
    }

    /// A store read that fails once is retried later rather than dropping the
    /// intent, and the retry does not spin.
    @MainActor
    func testTransientReadFailureKeepsTheIntentAndRetries() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.store.failingReads = 1

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")
        await harness.queue.waitForCurrentRun()
        XCTAssertEqual(harness.queue.intents.count, 1, "A failed read keeps the intent")
        XCTAssertEqual(harness.store.saveCount, 0)
        XCTAssertTrue(harness.notifications.isEmpty)

        try await waitUntil { await MainActor.run { harness.store.saveCount == 1 } }
        XCTAssertTrue(harness.queue.intents.isEmpty)
        XCTAssertEqual(harness.store.readAttempts, 3, "One failed read, then the run's two reads")
    }

    /// A failure that never clears is given up after a bounded number of
    /// tries, and the user is told.
    @MainActor
    func testPersistentReadFailureIsGivenUpAndReported() async throws {
        let harness = try QueueHarness(segments: [makeSegment(text: "the deadline is Friday")])
        harness.store.failingReads = 100

        harness.queue.start()
        harness.queue.enqueue(recordingId: harness.recordingId, source: harness.snapshot(), languageCode: "en")

        try await waitUntil { await MainActor.run { harness.queue.intents.isEmpty } }
        XCTAssertEqual(harness.store.readAttempts, TranscriptCleanupQueue.maximumTransientFailures)
        XCTAssertEqual(harness.notifications, [TranscriptCleanupWarning.resourceFailure.userVisibleMessage])
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
    private let throwingPieces: [Int: TranscriptCleanupNormalizerError]
    /// What a blocked call throws when its task is cancelled. MLX's stream
    /// ends early on cancellation, which the service can report as a failed
    /// generation rather than as cancellation.
    private let errorWhenCancelled: TranscriptCleanupNormalizerError?
    private var released = false
    private(set) var isBlocked = false
    private(set) var normalizationRequests: [String] = []
    private(set) var tokenRequestCount = 0

    init(
        ready: Bool = true,
        tokenScale: Int = 1,
        failingPieces: Set<Int> = [],
        cancellingPieces: Set<Int> = [],
        blockingPieces: Set<Int> = [],
        throwingPieces: [Int: TranscriptCleanupNormalizerError] = [:],
        errorWhenCancelled: TranscriptCleanupNormalizerError? = nil
    ) {
        self.ready = ready
        self.tokenScale = tokenScale
        self.failingPieces = failingPieces
        self.cancellingPieces = cancellingPieces
        self.blockingPieces = blockingPieces
        self.throwingPieces = throwingPieces
        self.errorWhenCancelled = errorWhenCancelled
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
                if Task.isCancelled {
                    if let errorWhenCancelled { throw errorWhenCancelled }
                    throw CancellationError()
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        if cancellingPieces.contains(index) {
            throw CancellationError()
        }
        if let error = throwingPieces[index] {
            throw error
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

    func flush() async {}
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
    private(set) var readAttempts = 0
    /// Reads that throw before reads start succeeding, to simulate a
    /// transient Core Data failure.
    var failingReads = 0
    /// Called with the 1-based attempt number on every read.
    var onRead: ((Int) -> Void)?

    init(transcript: TranscriptData) {
        self.transcript = transcript
    }

    var isAvailable: Bool { true }

    func transcript(for recordingId: UUID) throws -> TranscriptData? {
        readAttempts += 1
        onRead?(readAttempts)
        if failingReads > 0 {
            failingReads -= 1
            throw CocoaError(.fileReadUnknown)
        }
        return transcript?.recordingId == recordingId ? transcript : nil
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
    var isCleanupEnabled = true
    private(set) var notifications: [String] = []
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
            canRunNow: { [weak self] in self?.isForeground ?? false },
            isCleanupEnabled: { [weak self] in self?.isCleanupEnabled ?? false },
            notifyUser: { [weak self] message in self?.notifications.append(message) },
            transientRetryDelay: 0.05,
            observesLifecycle: false
        )
    }
}
