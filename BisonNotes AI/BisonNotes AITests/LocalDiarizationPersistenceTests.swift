import XCTest
@testable import BisonNotes_AI

@MainActor
final class LocalDiarizationPersistenceTests: XCTestCase {
    private var persistenceController: PersistenceController!
    private var appCoordinator: AppDataCoordinator!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        persistenceController = PersistenceController(inMemory: true)
        appCoordinator = AppDataCoordinator(persistenceController: persistenceController)
        tempDirectory = try TestHelpers.createTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? TestHelpers.cleanupTemporaryDirectory(tempDirectory)
        }
        tempDirectory = nil
        appCoordinator = nil
        persistenceController = nil
    }

    func testLabeledTranscriptPersistsSpeakerMappingsAndSummaryText() throws {
        let recordingID = try makeRecording(named: "Labeled Recording")
        let audioURL = tempDirectory.appendingPathComponent("labeled-recording.m4a")
        let transcriptData = TranscriptData(
            recordingId: recordingID,
            recordingURL: audioURL,
            recordingName: "Labeled Recording",
            recordingDate: Date(),
            segments: [
                TranscriptSegment(speaker: "speaker_1", text: "Hello there", startTime: 0, endTime: 1),
                TranscriptSegment(speaker: "speaker_2", text: "General Kenobi", startTime: 1, endTime: 2)
            ],
            speakerMappings: ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"],
            engine: .fluidAudio
        )

        _ = try persistBackgroundTranscript(transcriptData, using: appCoordinator)

        let persisted = try XCTUnwrap(appCoordinator.getTranscriptData(for: recordingID))
        XCTAssertEqual(persisted.plainText, "Hello there General Kenobi")
        XCTAssertEqual(persisted.speakerMappings, transcriptData.speakerMappings)
        XCTAssertTrue(persisted.textForSummarization.contains("Speaker 1: Hello there"))
        XCTAssertTrue(persisted.textForSummarization.contains("Speaker 2: General Kenobi"))
    }

    func testSpeakerBoundarySpacingSurvivesPersistence() throws {
        let recordingID = try makeRecording(named: "Boundary Spacing")
        let audioURL = tempDirectory.appendingPathComponent("boundary-spacing.m4a")
        let transcriptData = TranscriptData(
            recordingId: recordingID,
            recordingURL: audioURL,
            recordingName: "Boundary Spacing",
            recordingDate: Date(),
            segments: [
                TranscriptSegment(
                    speaker: "speaker_1",
                    text: "hello",
                    startTime: 0,
                    endTime: 0.4,
                    hasLeadingSpace: false
                ),
                TranscriptSegment(
                    speaker: "speaker_2",
                    text: "(world)",
                    startTime: 0.4,
                    endTime: 1,
                    hasLeadingSpace: false
                )
            ],
            speakerMappings: ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"],
            engine: .fluidAudio
        )

        XCTAssertEqual(transcriptData.plainText, "hello(world)")
        _ = try persistBackgroundTranscript(transcriptData, using: appCoordinator)

        let persisted = try XCTUnwrap(appCoordinator.getTranscriptData(for: recordingID))
        XCTAssertEqual(persisted.plainText, "hello(world)")
        XCTAssertEqual(persisted.segments.map(\.hasLeadingSpace), [false, false])
    }

    func testRetryAndRerunReplaceLabelStateWithoutDuplicatingTranscript() throws {
        let recordingID = try makeRecording(named: "Rerun Recording")
        let audioURL = tempDirectory.appendingPathComponent("rerun-recording.m4a")
        let first = TranscriptData(
            recordingId: recordingID,
            recordingURL: audioURL,
            recordingName: "Rerun Recording",
            recordingDate: Date(),
            segments: [TranscriptSegment(speaker: "speaker_1", text: "First labels", startTime: 0, endTime: 1)],
            speakerMappings: ["speaker_1": "Speaker 1"],
            engine: .fluidAudio
        )
        let second = TranscriptData(
            recordingId: recordingID,
            recordingURL: audioURL,
            recordingName: "Rerun Recording",
            recordingDate: Date(),
            segments: [
                TranscriptSegment(speaker: "speaker_1", text: "Replacement one", startTime: 0, endTime: 1),
                TranscriptSegment(speaker: "speaker_2", text: "Replacement two", startTime: 1, endTime: 2)
            ],
            speakerMappings: ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"],
            engine: .fluidAudio
        )

        let firstID = try persistBackgroundTranscript(first, using: appCoordinator)
        let secondID = try persistBackgroundTranscript(second, using: appCoordinator)

        XCTAssertEqual(firstID, secondID)
        XCTAssertEqual(appCoordinator.getAllTranscripts().count, 1)
        XCTAssertEqual(
            appCoordinator.getTranscriptData(for: recordingID)?.segments.map(\.text),
            ["Replacement one", "Replacement two"]
        )
        XCTAssertEqual(
            appCoordinator.getTranscriptData(for: recordingID)?.speakerMappings,
            second.speakerMappings
        )
    }

    func testCancellationDoesNotPersistPartialLabels() async throws {
        let recordingID = try makeRecording(named: "Cancelled Recording")
        let fake = PersistenceFakeLocalDiarizationService()
        let labelingCoordinator = LocalSpeakerLabelingCoordinator(modelManager: fake, diarizer: fake)
        let base = TranscriptionResult(
            fullText: "Complete",
            segments: [TranscriptSegment(speaker: "", text: "Complete", startTime: 0, endTime: 2)],
            processingTime: 0,
            chunkCount: 1,
            success: true,
            error: nil,
            timedWords: [TimedTranscriptWord(text: "Complete", startTime: 0, endTime: 1, hasLeadingSpace: false)]
        )

        do {
            let labeled = try await labelingCoordinator.apply(
                to: base,
                configuration: LocalSpeakerLabelsConfiguration(isEnabled: true),
                sourceAudioURL: URL(fileURLWithPath: "/complete-source.m4a"),
                audioDuration: 2
            )
            let data = TranscriptData(
                recordingId: recordingID,
                recordingURL: tempDirectory.appendingPathComponent("cancelled.m4a"),
                recordingName: "Cancelled Recording",
                recordingDate: Date(),
                segments: labeled.segments,
                speakerMappings: labeled.speakerMappings ?? [:]
            )
            _ = try persistBackgroundTranscript(data, using: appCoordinator)
            XCTFail("A cancellation must not reach transcript persistence")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertNil(appCoordinator.getTranscriptData(for: recordingID))
        let snapshot = await fake.snapshot()
        XCTAssertEqual(snapshot.unloadCallCount, 1)
    }

    func testICloudSettingsAllowlistContainsOnlySpeakerChoiceKeysForFeature() {
        let keys = Set(iCloudStorageManager.backedUpSettingsKeys)
        let speakerKeys = Set(keys.filter { $0.lowercased().contains("localspeaker") })

        XCTAssertEqual(
            speakerKeys,
            Set([
                FluidAudioModelInfo.SettingsKeys.localSpeakerLabelsEnabled,
                FluidAudioModelInfo.SettingsKeys.selectedLocalSpeakerLabelMethod
            ])
        )
        XCTAssertFalse(keys.contains(FluidAudioModelInfo.SettingsKeys.modelDownloaded))
        XCTAssertFalse(keys.contains(FluidAudioModelInfo.SettingsKeys.downloadedModelVersion))
        XCTAssertFalse(keys.contains("localSpeakerLabelsModelReady"))
        XCTAssertFalse(keys.contains("localSpeakerLabelsCachePath"))
        XCTAssertFalse(keys.contains("localSpeakerLabelsBinary"))
    }

    func testProcessingJobSnapshotSurvivesCodableStatusProgressAndRelaunchEnvelope() throws {
        let configuration = LocalSpeakerLabelsConfiguration(
            isEnabled: true,
            method: .experimentalLSEEND
        )
        let job = ProcessingJob(
            type: .transcription(engine: .fluidAudio),
            recordingURL: tempDirectory.appendingPathComponent("snapshot.m4a"),
            recordingName: "Snapshot",
            modelName: "parakeet-v3",
            localSpeakerLabelsConfiguration: configuration
        )

        let decoded = try JSONDecoder().decode(
            ProcessingJob.self,
            from: JSONEncoder().encode(job)
        )
        XCTAssertEqual(decoded.localSpeakerLabelsConfiguration, configuration)
        XCTAssertEqual(job.withStatus(.processing).localSpeakerLabelsConfiguration, configuration)
        XCTAssertEqual(job.withProgress(0.5).localSpeakerLabelsConfiguration, configuration)

        let restored = ProcessingJob.restoredPersistenceValues(
            from: job.persistedModelNameValue
        )
        XCTAssertEqual(restored.modelName, "parakeet-v3")
        XCTAssertEqual(restored.configuration, configuration)
    }

    func testBackwardCorruptAndNonFluidJobsFailSpeakerLabelsClosed() throws {
        let enabled = ProcessingJob(
            type: .transcription(engine: .fluidAudio),
            recordingURL: tempDirectory.appendingPathComponent("legacy.m4a"),
            recordingName: "Legacy",
            localSpeakerLabelsConfiguration: LocalSpeakerLabelsConfiguration(
                isEnabled: true,
                method: .experimentalLSEEND
            )
        )
        let encoded = try JSONEncoder().encode(enabled)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "localSpeakerLabelsConfiguration")
        let backwardDecoded = try JSONDecoder().decode(
            ProcessingJob.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(backwardDecoded.localSpeakerLabelsConfiguration, LocalSpeakerLabelsConfiguration())

        object["localSpeakerLabelsConfiguration"] = [
            "isEnabled": true,
            "method": "unknown-method"
        ]
        let corruptDecoded = try JSONDecoder().decode(
            ProcessingJob.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(corruptDecoded.localSpeakerLabelsConfiguration, LocalSpeakerLabelsConfiguration())

        let nonFluid = ProcessingJob(
            type: .transcription(engine: .whisper),
            recordingURL: tempDirectory.appendingPathComponent("non-fluid.m4a"),
            recordingName: "Non Fluid",
            localSpeakerLabelsConfiguration: LocalSpeakerLabelsConfiguration(isEnabled: true)
        )
        XCTAssertEqual(nonFluid.localSpeakerLabelsConfiguration, LocalSpeakerLabelsConfiguration())

        let legacyPersistence = ProcessingJob.restoredPersistenceValues(from: "legacy-model")
        XCTAssertEqual(legacyPersistence.modelName, "legacy-model")
        XCTAssertEqual(legacyPersistence.configuration, LocalSpeakerLabelsConfiguration())
    }

    func testCancellationImmediatelyBeforePersistenceWritesNoPartialLabels() async throws {
        let recordingID = try makeRecording(named: "Late Cancellation")
        let transcriptData = TranscriptData(
            recordingId: recordingID,
            recordingURL: tempDirectory.appendingPathComponent("late-cancel.m4a"),
            recordingName: "Late Cancellation",
            recordingDate: Date(),
            segments: [
                TranscriptSegment(speaker: "speaker_1", text: "Do not save", startTime: 0, endTime: 1)
            ],
            speakerMappings: ["speaker_1": "Speaker 1"],
            engine: .fluidAudio
        )

        let saveTask = Task { @MainActor in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try persistBackgroundTranscript(transcriptData, using: appCoordinator)
        }

        do {
            _ = try await saveTask.value
            XCTFail("A cancellation immediately before persistence must not save labels")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertNil(appCoordinator.getTranscriptData(for: recordingID))
    }

    func testDirectRerunReplacementCarriesMappingsEngineAndVisibleWarning() {
        let result = TranscriptionResult(
            fullText: "Hello world",
            segments: [
                TranscriptSegment(speaker: "speaker_1", text: "Hello world", startTime: 0, endTime: 1)
            ],
            processingTime: 1,
            chunkCount: 1,
            success: true,
            error: nil,
            speakerMappings: ["speaker_1": "Speaker 1"],
            speakerLabelWarning: .timingUnavailable
        )

        let replacement = TranscriptRerunReplacement(result: result, engine: .fluidAudio)

        XCTAssertEqual(replacement.segments.map(\.speaker), ["speaker_1"])
        XCTAssertEqual(replacement.speakerMappings, ["speaker_1": "Speaker 1"])
        XCTAssertEqual(replacement.engine, .fluidAudio)
        XCTAssertEqual(replacement.speakerLabelWarning, .timingUnavailable)
        XCTAssertFalse(replacement.speakerLabelWarning?.userVisibleMessage.isEmpty ?? true)
    }

    private func makeRecording(named name: String) throws -> UUID {
        let audioURL = tempDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        try TestHelpers.createMockAudioFile(at: audioURL)
        return appCoordinator.addRecording(
            url: audioURL,
            name: name,
            date: Date(),
            fileSize: 1_024,
            duration: 30,
            quality: .whisperOptimized
        )
    }
}

private actor PersistenceFakeLocalDiarizationService: LocalDiarizationModelManaging, LocalDiarizing {
    private(set) var unloadCallCount = 0

    func modelStatus(for method: LocalDiarizationMethod) async -> LocalDiarizationModelStatus {
        LocalDiarizationModelStatus(method: method, state: .ready, fractionCompleted: 1)
    }

    func prepareModel(
        for method: LocalDiarizationMethod,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws {}

    func cancelModelPreparation(for method: LocalDiarizationMethod) async {}

    func unloadModel(for method: LocalDiarizationMethod) async {
        unloadCallCount += 1
    }

    func deleteModel(for method: LocalDiarizationMethod) async throws {}

    func diarize(
        audioURL: URL,
        method: LocalDiarizationMethod,
        audioDuration: TimeInterval?,
        progress: @escaping @Sendable (LocalDiarizationProgress) -> Void
    ) async throws -> LocalDiarizationResult {
        throw CancellationError()
    }

    func snapshot() -> Snapshot {
        Snapshot(unloadCallCount: unloadCallCount)
    }

    struct Snapshot {
        let unloadCallCount: Int
    }
}
