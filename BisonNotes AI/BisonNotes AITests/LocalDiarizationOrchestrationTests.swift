import XCTest
@testable import BisonNotes_AI

final class LocalDiarizationOrchestrationTests: XCTestCase {
    func testLabelsOffPreservesResultAndMakesNoDiarizerCall() async throws {
        let fake = OrchestrationFakeLocalDiarizationService()
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let base = makeResult()

        let result = try await coordinator.apply(
            to: base,
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: false, method: .offlineVBx),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 2
        )

        XCTAssertEqual(result.fullText, base.fullText)
        XCTAssertEqual(result.segments.map(\.text), base.segments.map(\.text))
        XCTAssertNil(result.speakerLabelWarning)
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.diarizeCallCount, 0)
        XCTAssertEqual(snapshot.modelStatusCallCount, 0)
    }

    func testEnabledMethodsRouteToTheSelectedDiarizerMethod() async throws {
        for method in LocalDiarizationMethod.allCases {
            let fake = OrchestrationFakeLocalDiarizationService()
            let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)

            _ = try await coordinator.apply(
                to: makeResult(),
                configuration: LocalSpeakerLabelsConfiguration(isEnabled: true, method: method),
                sourceAudioURL: URL(fileURLWithPath: "/complete-source-\(method.rawValue).m4a"),
                audioDuration: 2
            )

            let snapshot = await fake.snapshot()
            XCTAssertEqual(snapshot.diarizeCallCount, 1)
            XCTAssertEqual(snapshot.methods, [method])
            XCTAssertEqual(snapshot.unloadCallCount, 1)
        }
    }

    @MainActor
    func testReassemblyOffsetsAndDeduplicatesWordsBeforeOneCompleteFilePass() async throws {
        let reassembly = try await makeTimedReassembly()
        XCTAssertEqual(reassembly.timedWords?.map(\.text), ["hello", "world"])
        XCTAssertEqual(reassembly.timedWords?.map(\.startTime), [1, 10.5])
        XCTAssertEqual(reassembly.timedWords?.map(\.endTime), [2, 11.5])

        let sourceURL = URL(fileURLWithPath: "/complete-source.m4a")
        let fake = OrchestrationFakeLocalDiarizationService()
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let base = TranscriptionResult(
            fullText: "hello world",
            segments: reassembly.transcriptData.segments,
            processingTime: 0,
            chunkCount: 2,
            success: true,
            error: nil,
            timedWords: reassembly.timedWords,
            speakerMappings: reassembly.transcriptData.speakerMappings
        )
        let labeled = try await coordinator.apply(
            to: base,
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true, method: .offlineVBx),
            sourceAudioURL: sourceURL,
            audioDuration: 12
        )

        XCTAssertEqual(labeled.fullText, "hello world")
        XCTAssertEqual(labeled.segments.map(\.text), ["hello", "world"])
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.diarizeCallCount, 1)
        XCTAssertEqual(snapshot.urls, [sourceURL])
    }

    @MainActor
    private func makeTimedReassembly() async throws -> ReassemblyResult {
        let service = AudioFileChunkingService()
        let firstAudioChunk = AudioChunk(
            originalURL: URL(fileURLWithPath: "/complete-source.m4a"),
            chunkURL: URL(fileURLWithPath: "/chunk-0.m4a"),
            sequenceNumber: 0,
            startTime: 0,
            endTime: 10,
            fileSize: 1
        )
        let secondAudioChunk = AudioChunk(
            originalURL: URL(fileURLWithPath: "/complete-source.m4a"),
            chunkURL: URL(fileURLWithPath: "/chunk-1.m4a"),
            sequenceNumber: 1,
            startTime: 10,
            endTime: 12,
            fileSize: 1
        )
        let first = service.createTranscriptChunk(
            from: "hello",
            audioChunk: firstAudioChunk,
            segments: [TranscriptSegment(speaker: "", text: "hello", startTime: 1, endTime: 2)],
            timedWords: [TimedTranscriptWord(text: "hello", startTime: 1, endTime: 2, hasLeadingSpace: false)]
        )
        let second = service.createTranscriptChunk(
            from: "world world",
            audioChunk: secondAudioChunk,
            segments: [TranscriptSegment(speaker: "", text: "world world", startTime: 0.5, endTime: 1.5)],
            timedWords: [
                TimedTranscriptWord(text: "world", startTime: 0.5, endTime: 1.5),
                TimedTranscriptWord(text: "world", startTime: 0.5, endTime: 1.5, hasLeadingSpace: false)
            ]
        )

        return try await service.reassembleTranscript(
            from: [second, first],
            originalURL: firstAudioChunk.originalURL,
            recordingName: "Complete Source",
            recordingDate: Date(),
            recordingId: UUID()
        )
    }

    func testMissingTimingModelAndDiarizerFailurePreserveUnlabeledTranscriptWithWarning() async throws {
        let sourceURL = URL(fileURLWithPath: "/complete-source.m4a")

        let missingTimingFake = OrchestrationFakeLocalDiarizationService()
        let missingTimingCoordinator = LocalSpeakerLabelingCoordinator(
            modelManager: missingTimingFake,
            diarizer: missingTimingFake
        )
        let missingTiming = try await missingTimingCoordinator.apply(
            to: makeResult(timedWords: nil),
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: sourceURL,
            audioDuration: 2
        )
        XCTAssertEqual(missingTiming.speakerLabelWarning, .timingUnavailable)
        XCTAssertEqual(missingTiming.fullText, "hello world")
        XCTAssertEqual(missingTiming.segments.map(\.text), ["hello world"])
        let missingTimingSnapshot = await missingTimingFake.snapshot()
        XCTAssertEqual(missingTimingSnapshot.diarizeCallCount, 0)

        let missingModelFake = OrchestrationFakeLocalDiarizationService(isReady: false)
        let missingModelCoordinator = LocalSpeakerLabelingCoordinator(
            modelManager: missingModelFake,
            diarizer: missingModelFake
        )
        let missingModel = try await missingModelCoordinator.apply(
            to: makeResult(),
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: sourceURL,
            audioDuration: 2
        )
        XCTAssertEqual(missingModel.speakerLabelWarning, .modelNotReady(method: .offlineVBx))
        XCTAssertEqual(missingModel.segments.map(\.text), ["hello world"])
        let missingModelSnapshot = await missingModelFake.snapshot()
        XCTAssertEqual(missingModelSnapshot.diarizeCallCount, 0)

        let failureFake = OrchestrationFakeLocalDiarizationService(shouldFail: true)
        let failureCoordinator = LocalSpeakerLabelingCoordinator(modelManager: failureFake, diarizer: failureFake)
        let failed = try await failureCoordinator.apply(
            to: makeResult(),
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: sourceURL,
            audioDuration: 2
        )
        XCTAssertEqual(failed.speakerLabelWarning, .diarizationFailed(method: .offlineVBx))
        XCTAssertEqual(failed.fullText, "hello world")
        XCTAssertEqual(failed.segments.map(\.speaker), [""])
        let failureSnapshot = await failureFake.snapshot()
        XCTAssertEqual(failureSnapshot.diarizeCallCount, 1)
        XCTAssertEqual(failureSnapshot.unloadCallCount, 1)

    }

    func testLSEENDOverOneHourIsGuardedWithoutInvokingRunner() async throws {
        let fake = OrchestrationFakeLocalDiarizationService()
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)

        let result = try await coordinator.apply(
            to: makeResult(),
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true, method: .experimentalLSEEND),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 3_601
        )

        XCTAssertEqual(
            result.speakerLabelWarning,
            .experimentalDurationLimit(duration: 3_601, maximumDuration: 3_600)
        )
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.diarizeCallCount, 0)
        XCTAssertEqual(snapshot.modelStatusCallCount, 0)
    }

    func testCancellationPropagatesAndUnloadsDiarizerResources() async throws {
        let fake = OrchestrationFakeLocalDiarizationService(shouldCancel: true)
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)

        do {
            _ = try await coordinator.apply(
                to: makeResult(),
                configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
                sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
                audioDuration: 2
            )
            XCTFail("Cancellation must propagate instead of becoming a warning")
        } catch is CancellationError {
            // Expected: callers do not persist the partially labeled result.
        }

        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.diarizeCallCount, 1)
        XCTAssertEqual(snapshot.unloadCallCount, 1)
    }

    func testRetryIsIdempotentAndDoesNotAppendLabeledSegments() async throws {
        let fake = OrchestrationFakeLocalDiarizationService()
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let configuration = LocalSpeakerLabelsConfiguration(isEnabled: true, method: .offlineVBx)

        let first = try await coordinator.apply(
            to: makeResult(),
            configuration: configuration,
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 2
        )
        let retry = try await coordinator.apply(
            to: first,
            configuration: configuration,
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 2
        )

        XCTAssertEqual(retry.fullText, first.fullText)
        XCTAssertEqual(retry.segments.map(\.text), first.segments.map(\.text))
        XCTAssertEqual(retry.segments.map(\.speaker), first.segments.map(\.speaker))
        XCTAssertEqual(retry.speakerMappings, first.speakerMappings)
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.diarizeCallCount, 2)
        XCTAssertEqual(snapshot.unloadCallCount, 2)
    }

    func testChoiceSnapshotIsStableAfterDefaultsChange() {
        let suiteName = "LocalDiarizationOrchestrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled)
        defaults.set(
            LocalDiarizationMethod.experimentalLSEEND.rawValue,
            forKey: FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod
        )
        let snapshot = LocalSpeakerLabelsConfiguration.currentUserChoice(from: defaults)

        defaults.set(false, forKey: FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled)
        defaults.set(
            LocalDiarizationMethod.offlineVBx.rawValue,
            forKey: FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod
        )

        XCTAssertEqual(snapshot, LocalSpeakerLabelsConfiguration(isEnabled: true, method: .experimentalLSEEND))
    }

    private func makeResult(
        timedWords: [TimedTranscriptWord]? = [
            TimedTranscriptWord(text: "hello", startTime: 0, endTime: 0.5, hasLeadingSpace: false),
            TimedTranscriptWord(text: "world", startTime: 0.6, endTime: 1, hasLeadingSpace: true)
        ]
    ) -> TranscriptionResult {
        TranscriptionResult(
            fullText: "hello world",
            segments: [TranscriptSegment(speaker: "", text: "hello world", startTime: 0, endTime: 1)],
            processingTime: 0,
            chunkCount: 1,
            success: true,
            error: nil,
            timedWords: timedWords
        )
    }
}

extension LocalDiarizationOrchestrationTests {
    func testASRCompletesAndUnloadsBeforeDiarizerStatusAndCompleteFileRun() async throws {
        let fake = OrchestrationFakeLocalDiarizationService()
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        await fake.recordEvent("asrComplete")
        _ = try await coordinator.apply(
            to: makeResult(),
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 2,
            unloadASRBeforeDiarization: { await fake.recordEvent("unloadASR") }
        )
        let recordedEvents = await fake.snapshot().events
        XCTAssertEqual(recordedEvents, ["asrComplete", "unloadASR", "modelStatus", "diarize", "unloadDiarizer"])
    }

    func testInvalidTimelineReturnsBaseTranscriptWithTimingWarning() async throws {
        let invalidInterval = LocalDiarizationInterval(
            speakerID: "raw-speaker",
            startTime: .nan,
            endTime: .infinity
        )
        let fake = OrchestrationFakeLocalDiarizationService(intervals: [invalidInterval])
        let coordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let result = try await coordinator.apply(
            to: makeResult(),
            configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
            sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
            audioDuration: 2
        )
        XCTAssertEqual(result.speakerLabelWarning, .timingUnavailable)
        XCTAssertEqual(result.segments.map(\.speaker), [""])
        XCTAssertEqual(result.fullText, "hello world")
    }
}

private actor OrchestrationFakeLocalDiarizationService: LocalDiarizationModelManaging, LocalDiarizing {
    private let isReady: Bool
    private let shouldFail: Bool
    private let shouldCancel: Bool
    private let intervals: [LocalDiarizationInterval]
    private(set) var diarizeCallCount = 0
    private(set) var modelStatusCallCount = 0
    private(set) var unloadCallCount = 0
    private(set) var methods: [LocalDiarizationMethod] = []
    private(set) var urls: [URL] = []
    private(set) var events: [String] = []

    init(
        isReady: Bool = true,
        shouldFail: Bool = false,
        shouldCancel: Bool = false,
        intervals: [LocalDiarizationInterval] = [
            LocalDiarizationInterval(speakerID: "raw-speaker", startTime: 0, endTime: 2)
        ]
    ) {
        self.isReady = isReady
        self.shouldFail = shouldFail
        self.shouldCancel = shouldCancel
        self.intervals = intervals
    }

    func modelStatus(for method: LocalDiarizationMethod) async -> LocalDiarizationModelStatus {
        modelStatusCallCount += 1
        events.append("modelStatus")
        return LocalDiarizationModelStatus(
            method: method,
            state: isReady ? .ready : .downloadRequired,
            fractionCompleted: isReady ? 1 : nil
        )
    }

    func prepareModel(
        for method: LocalDiarizationMethod,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws {
        progress(LocalDiarizationProgress(method: method, phase: .completed, fractionCompleted: 1))
    }

    func cancelModelPreparation(for method: LocalDiarizationMethod) async {}

    func unloadModel(for method: LocalDiarizationMethod) async {
        unloadCallCount += 1
        events.append("unloadDiarizer")
    }

    func deleteModel(for method: LocalDiarizationMethod) async throws {}

    func diarize(
        audioURL: URL,
        method: LocalDiarizationMethod,
        audioDuration: TimeInterval?,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws -> LocalDiarizationResult {
        diarizeCallCount += 1
        methods.append(method)
        urls.append(audioURL)
        events.append("diarize")
        if shouldCancel { throw CancellationError() }
        if shouldFail { throw FakeDiarizerError.failed }
        progress(LocalDiarizationProgress(method: method, phase: .completed, fractionCompleted: 1))
        return LocalDiarizationResult(
            intervals: intervals,
            audioDuration: audioDuration
        )
    }

    func snapshot() -> Snapshot {
        Snapshot(
            diarizeCallCount: diarizeCallCount,
            modelStatusCallCount: modelStatusCallCount,
            unloadCallCount: unloadCallCount,
            methods: methods,
            urls: urls,
            events: events
        )
    }

    func recordEvent(_ event: String) {
        events.append(event)
    }

    struct Snapshot {
        let diarizeCallCount: Int
        let modelStatusCallCount: Int
        let unloadCallCount: Int
        let methods: [LocalDiarizationMethod]
        let urls: [URL]
        let events: [String]
    }
}

private enum FakeDiarizerError: Error, Sendable {
    case failed
}
