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

    private func makeTemporaryAudioPlaceholder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-diarization-test-\(UUID().uuidString)")
        try? Data([0]).write(to: url)
        return url
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

private actor FakeLocalDiarizationModelProvider: LocalDiarizationModelProvider {
    private var readyMethods: Set<LocalDiarizationMethod>
    private let runner: (any LocalDiarizationRunner)?
    private(set) var prepareCallCount = 0
    private(set) var makeRunnerCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deletedMethods: [LocalDiarizationMethod] = []

    init(
        readyMethods: Set<LocalDiarizationMethod> = [],
        runner: (any LocalDiarizationRunner)? = nil
    ) {
        self.readyMethods = readyMethods
        self.runner = runner
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
        deleteCallCount += 1
        deletedMethods.append(method)
        readyMethods.remove(method)
    }
}
