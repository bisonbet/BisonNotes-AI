import XCTest
@testable import BisonNotes_AI

final class LocalDiarizationModelManagerTests: XCTestCase {
    func testInvalidMethodValuesFailClosedAndCachesAreIsolated() {
        XCTAssertFalse(FluidAudioModelInfo.LocalSpeakerLabels.defaultEnabled)
        XCTAssertNil(LocalDiarizationMethod.offlineVBx.maximumSupportedSpeakerCount)
        XCTAssertEqual(LocalDiarizationMethod.experimentalLSEEND.maximumSupportedSpeakerCount, 10)
        XCTAssertEqual(
            FluidAudioModelInfo.LocalSpeakerLabels.normalizedMethodRawValue("corrupt"),
            LocalDiarizationMethod.offlineVBx.rawValue
        )

        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-diarization-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let vbx = FluidAudioModelInfo.localSpeakerModelCacheDirectory(
            methodRawValue: LocalDiarizationMethod.offlineVBx.rawValue,
            appSupportDirectory: appSupport
        )
        let lsEEND = FluidAudioModelInfo.localSpeakerModelCacheDirectory(
            methodRawValue: LocalDiarizationMethod.experimentalLSEEND.rawValue,
            appSupportDirectory: appSupport
        )

        XCTAssertNotNil(vbx)
        XCTAssertNotNil(lsEEND)
        XCTAssertNotEqual(vbx, lsEEND)
        XCTAssertEqual(vbx?.deletingLastPathComponent(), lsEEND?.deletingLastPathComponent())
    }

    func testDiarizationDoesNotPrepareOrDownloadWhenModelIsMissing() async {
        let provider = FakeLocalDiarizationModelProvider()
        let manager = LocalDiarizationManager(provider: provider)
        let audioURL = makeTemporaryAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await manager.diarize(
                audioURL: audioURL,
                method: .offlineVBx,
                audioDuration: 12,
                progress: { _ in }
            )
            XCTFail("Diarization should require an explicitly prepared model")
        } catch let error as LocalDiarizationError {
            XCTAssertEqual(error, .downloadRequired(.offlineVBx))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let prepareCount = await provider.prepareCallCount
        let runnerCount = await provider.makeRunnerCallCount
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(runnerCount, 0)
    }

    func testDiarizationProcessesTheCompleteFileAndCleansRunner() async throws {
        let expected = LocalDiarizationResult(
            intervals: [
                LocalDiarizationInterval(
                    speakerID: "raw-0",
                    startTime: 0,
                    endTime: 2
                )
            ],
            audioDuration: 2
        )
        let runner = FakeLocalDiarizationRunner(result: expected)
        let provider = FakeLocalDiarizationModelProvider(readyMethods: [.offlineVBx], runner: runner)
        let manager = LocalDiarizationManager(provider: provider)
        let audioURL = makeTemporaryAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await manager.diarize(
            audioURL: audioURL,
            method: .offlineVBx,
            audioDuration: 2,
            progress: { _ in }
        )

        XCTAssertEqual(result, expected)
        let makeRunnerCallCount = await provider.makeRunnerCallCount
        let processCallCount = await runner.processCallCount
        let cleanupCallCount = await runner.cleanupCallCount
        XCTAssertEqual(makeRunnerCallCount, 1)
        XCTAssertEqual(processCallCount, 1)
        XCTAssertEqual(cleanupCallCount, 1)
    }

    func testPreparationIsExplicitAndDeletionOnlyTargetsSelectedMethod() async throws {
        let provider = FakeLocalDiarizationModelProvider()
        let manager = LocalDiarizationManager(provider: provider)

        try await manager.prepareModel(for: .experimentalLSEEND, progress: { _ in })

        let status = await manager.modelStatus(for: .experimentalLSEEND)
        XCTAssertEqual(status.state, .ready)
        let prepareCallCount = await provider.prepareCallCount
        XCTAssertEqual(prepareCallCount, 1)

        try await manager.deleteModel(for: .experimentalLSEEND)

        let deleteCallCount = await provider.deleteCallCount
        let deletedMethods = await provider.deletedMethods
        XCTAssertEqual(deleteCallCount, 1)
        XCTAssertEqual(deletedMethods, [.experimentalLSEEND])
        let deletedStatus = await manager.modelStatus(for: .experimentalLSEEND)
        XCTAssertEqual(deletedStatus.state, .downloadRequired)
    }

    func testReadinessSurvivesManagerRecreationAndDeletingOneMethodPreservesTheOther() async throws {
        let provider = FakeLocalDiarizationModelProvider()
        let firstManager = LocalDiarizationManager(provider: provider)

        try await firstManager.prepareModel(for: .offlineVBx, progress: { _ in })
        try await firstManager.prepareModel(for: .experimentalLSEEND, progress: { _ in })

        let relaunchedManager = LocalDiarizationManager(provider: provider)
        let relaunchedVBxStatus = await relaunchedManager.modelStatus(for: .offlineVBx)
        let relaunchedLSEENDStatus = await relaunchedManager.modelStatus(for: .experimentalLSEEND)
        XCTAssertTrue(relaunchedVBxStatus.isReady)
        XCTAssertTrue(relaunchedLSEENDStatus.isReady)

        try await relaunchedManager.deleteModel(for: .offlineVBx)

        let deletedVBxStatus = await relaunchedManager.modelStatus(for: .offlineVBx)
        let preservedLSEENDStatus = await relaunchedManager.modelStatus(for: .experimentalLSEEND)
        XCTAssertFalse(deletedVBxStatus.isReady)
        XCTAssertTrue(preservedLSEENDStatus.isReady)
    }

    func testExperimentalMethodRejectsFilesLongerThanOneHourBeforeCreatingRunner() async {
        let runner = FakeLocalDiarizationRunner(result: LocalDiarizationResult(intervals: []))
        let provider = FakeLocalDiarizationModelProvider(readyMethods: [.experimentalLSEEND], runner: runner)
        let manager = LocalDiarizationManager(provider: provider)
        let audioURL = makeTemporaryAudioPlaceholder()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await manager.diarize(
                audioURL: audioURL,
                method: .experimentalLSEEND,
                audioDuration: 3_601,
                progress: { _ in }
            )
            XCTFail("LS-EEND should reject files longer than one hour")
        } catch let error as LocalDiarizationError {
            XCTAssertEqual(error, .experimentalDurationLimit)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let makeRunnerCallCount = await provider.makeRunnerCallCount
        XCTAssertEqual(makeRunnerCallCount, 0)
    }

    func testModelHubGateSerializesSuspendingOperations() async throws {
        let gate = FluidAudioModelHubGate()
        let probe = ModelHubGateProbe()

        async let first: Void = gate.withExclusiveAccess(mode: .online) {
            await probe.runOperation()
        }
        async let second: Void = gate.withExclusiveAccess(mode: .offline) {
            await probe.runOperation()
        }

        _ = try await (first, second)
        let maximumConcurrentOperations = await probe.maximumConcurrentOperations
        XCTAssertEqual(maximumConcurrentOperations, 1)
    }

    func testCancellationWaitsForPreparationToTerminateWithoutDeletingCache() async throws {
        let provider = FakeLocalDiarizationModelProvider(blockPreparationUntilCancelled: true)
        let manager = LocalDiarizationManager(provider: provider)
        let preparation = Task {
            try await manager.prepareModel(for: .offlineVBx, progress: { _ in })
        }

        await waitUntil { await provider.isPreparing }
        await manager.cancelModelPreparation(for: .offlineVBx)

        do {
            try await preparation.value
            XCTFail("Cancelled preparation should throw")
        } catch is CancellationError {
            // Expected.
        }

        let isPreparing = await provider.isPreparing
        let deleteCallCount = await provider.deleteCallCount
        let status = await manager.modelStatus(for: .offlineVBx)
        XCTAssertFalse(isPreparing)
        XCTAssertEqual(deleteCallCount, 0)
        XCTAssertEqual(status.state, .cancelled)
    }

    func testDeleteWaitsForPreparationBeforeRemovingOnlySelectedCache() async throws {
        let provider = FakeLocalDiarizationModelProvider(
            readyMethods: [.experimentalLSEEND],
            blockPreparationUntilCancelled: true
        )
        let manager = LocalDiarizationManager(provider: provider)
        let preparation = Task {
            try await manager.prepareModel(for: .offlineVBx, progress: { _ in })
        }

        await waitUntil { await provider.isPreparing }
        try await manager.deleteModel(for: .offlineVBx)
        _ = try? await preparation.value

        let snapshot = await provider.lifecycleSnapshot()
        XCTAssertFalse(snapshot.isPreparing)
        XCTAssertFalse(snapshot.deleteObservedDuringPreparation)
        XCTAssertEqual(snapshot.deletedMethods, [.offlineVBx])
        XCTAssertTrue(snapshot.readyMethods.contains(.experimentalLSEEND))
    }

    func testFailedPreparationRetryForceRedownloadSurvivesStatusRefresh() async throws {
        let provider = FakeLocalDiarizationModelProvider(failedPreparationAttempts: 1)
        let manager = LocalDiarizationManager(provider: provider)

        do {
            try await manager.prepareModel(for: .offlineVBx, progress: { _ in })
            XCTFail("The first preparation should fail")
        } catch {
            // Expected.
        }
        _ = await manager.modelStatus(for: .offlineVBx)
        try await manager.prepareModel(for: .offlineVBx, progress: { _ in })

        let forceRedownloadValues = await provider.forceRedownloadValues
        let readyStatus = await manager.modelStatus(for: .offlineVBx)
        XCTAssertEqual(forceRedownloadValues, [false, true])
        XCTAssertTrue(readyStatus.isReady)
    }

    func testPreparationProgressIsReflectedInModelStatus() async throws {
        let provider = FakeLocalDiarizationModelProvider(blockPreparationUntilCancelled: true)
        let manager = LocalDiarizationManager(provider: provider)
        let preparation = Task {
            try await manager.prepareModel(for: .offlineVBx, progress: { _ in })
        }

        await waitUntil {
            await manager.modelStatus(for: .offlineVBx).fractionCompleted == 0.4
        }
        let status = await manager.modelStatus(for: .offlineVBx)
        XCTAssertEqual(status.state, .preparing)
        XCTAssertEqual(status.fractionCompleted, 0.4)

        await manager.cancelModelPreparation(for: .offlineVBx)
        _ = try? await preparation.value
    }

    func testStructuralReadinessRequiresCompleteCompiledModelArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-diarization-assets-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("model.mlmodelc", isDirectory: true)
        let weightsDirectory = model.appendingPathComponent("weights", isDirectory: true)
        let weights = weightsDirectory.appendingPathComponent("weight.bin")
        let modelMIL = model.appendingPathComponent("model.mil")
        let metadata = model.appendingPathComponent("metadata.json")
        let coreMLData = model.appendingPathComponent("coremldata.bin")
        let parameters = root.appendingPathComponent("plda.json")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: weightsDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: weights)
        XCTAssertFalse(LocalDiarizationAssetValidator.compiledModelBundleIsValid(at: model))

        try Data([1]).write(to: modelMIL)
        try Data("[{}]".utf8).write(to: metadata)
        try Data().write(to: coreMLData)
        XCTAssertFalse(LocalDiarizationAssetValidator.compiledModelBundleIsValid(at: model))

        try Data([1]).write(to: coreMLData)
        XCTAssertTrue(LocalDiarizationAssetValidator.compiledModelBundleIsValid(at: model))

        try Data("{}".utf8).write(to: parameters)
        XCTAssertFalse(LocalDiarizationAssetValidator.pldaParametersAreValid(at: parameters))
        let validParameters: [String: Any] = [
            "tensors": [
                "psi": ["data_base64": Data([0, 0, 0, 0]).base64EncodedString()]
            ]
        ]
        try JSONSerialization.data(withJSONObject: validParameters).write(to: parameters)
        XCTAssertTrue(LocalDiarizationAssetValidator.pldaParametersAreValid(at: parameters))
    }

    private func makeTemporaryAudioPlaceholder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-diarization-test-\(UUID().uuidString)")
        try? Data([0]).write(to: url)
        return url
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test condition")
    }
}

private actor ModelHubGateProbe {
    private(set) var maximumConcurrentOperations = 0
    private var activeOperations = 0

    func runOperation() async {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
        try? await Task.sleep(for: .milliseconds(20))
        activeOperations -= 1
    }
}

private actor FakeLocalDiarizationRunner: LocalDiarizationRunner {
    let result: LocalDiarizationResult
    private(set) var processCallCount = 0
    private(set) var cleanupCallCount = 0

    init(result: LocalDiarizationResult) {
        self.result = result
    }

    func process(
        audioURL: URL,
        method: LocalDiarizationMethod,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws -> LocalDiarizationResult {
        processCallCount += 1
        progressHandler(
            LocalDiarizationProgress(
                method: method,
                phase: .processing,
                fractionCompleted: 0.5
            )
        )
        try Task.checkCancellation()
        return result
    }

    func cleanup() async {
        cleanupCallCount += 1
    }
}

private struct FakeLifecycleSnapshot: Sendable {
    let isPreparing: Bool
    let deleteObservedDuringPreparation: Bool
    let deletedMethods: [LocalDiarizationMethod]
    let readyMethods: Set<LocalDiarizationMethod>
}

private actor FakeLocalDiarizationModelProvider: LocalDiarizationModelProvider {
    private var readyMethods: Set<LocalDiarizationMethod>
    private let runner: (any LocalDiarizationRunner)?
    private let blockPreparationUntilCancelled: Bool
    private var remainingFailedPreparationAttempts: Int
    private(set) var prepareCallCount = 0
    private(set) var makeRunnerCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deletedMethods: [LocalDiarizationMethod] = []
    private(set) var forceRedownloadValues: [Bool] = []
    private(set) var isPreparing = false
    private(set) var deleteObservedDuringPreparation = false

    init(
        readyMethods: Set<LocalDiarizationMethod> = [],
        runner: (any LocalDiarizationRunner)? = nil,
        blockPreparationUntilCancelled: Bool = false,
        failedPreparationAttempts: Int = 0
    ) {
        self.readyMethods = readyMethods
        self.runner = runner
        self.blockPreparationUntilCancelled = blockPreparationUntilCancelled
        self.remainingFailedPreparationAttempts = failedPreparationAttempts
    }

    func cacheDirectory(for method: LocalDiarizationMethod) async -> URL? {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-\(method.rawValue)", isDirectory: true)
    }

    func isReady(for method: LocalDiarizationMethod) async -> Bool {
        readyMethods.contains(method)
    }

    func prepare(
        for method: LocalDiarizationMethod,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws {
        prepareCallCount += 1
        forceRedownloadValues.append(forceRedownload)
        if remainingFailedPreparationAttempts > 0 {
            remainingFailedPreparationAttempts -= 1
            throw LocalDiarizationError.modelPreparationFailed(method)
        }
        isPreparing = true
        defer { isPreparing = false }
        progressHandler(
            LocalDiarizationProgress(
                method: method,
                phase: .downloading,
                fractionCompleted: 0.4
            )
        )
        if blockPreparationUntilCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        readyMethods.insert(method)
        progressHandler(
            LocalDiarizationProgress(
                method: method,
                phase: .completed,
                fractionCompleted: 1
            )
        )
    }

    func makeRunner(for method: LocalDiarizationMethod) async throws -> any LocalDiarizationRunner {
        makeRunnerCallCount += 1
        guard let runner else { throw LocalDiarizationError.runnerUnavailable }
        return runner
    }

    func delete(for method: LocalDiarizationMethod) async throws {
        deleteObservedDuringPreparation = deleteObservedDuringPreparation || isPreparing
        deleteCallCount += 1
        deletedMethods.append(method)
        readyMethods.remove(method)
    }

    func lifecycleSnapshot() -> FakeLifecycleSnapshot {
        FakeLifecycleSnapshot(
            isPreparing: isPreparing,
            deleteObservedDuringPreparation: deleteObservedDuringPreparation,
            deletedMethods: deletedMethods,
            readyMethods: readyMethods
        )
    }
}
