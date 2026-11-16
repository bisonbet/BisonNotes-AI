import XCTest
import Synchronization
@preconcurrency import AVFoundation
@testable import BisonNotes_AI

private final class StartupEvents: Sendable {
    struct State { var recordedOnMain = false; var starts = 0; var stops = 0 }
    private let state = Mutex(State())
    func started() { state.withLock { $0.recordedOnMain = Thread.isMainThread; $0.starts += 1 } }
    func stopped() { state.withLock { $0.stops += 1 } }
    var snapshot: State { state.withLock { $0 } }
}

private final class StartupProbe: RecorderStartable {
    let events: StartupEvents
    let succeeds: Bool
    init(events: StartupEvents, succeeds: Bool) { self.events = events; self.succeeds = succeeds }
    func record() -> Bool { events.started(); return succeeds }
    func stop() { events.stopped() }
}

private actor StartupGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

#if os(iOS)
@MainActor
private final class StartupSessionController: AudioSessionControlling {
    var category: AVAudioSession.Category = .playAndRecord
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var availableInputs: [AVAudioSessionPortDescription] = []
    var preferredInput: AVAudioSessionPortDescription?
    var currentInput: AVAudioSessionPortDescription?
    var currentOutputTypes: [String] = []
    var activeCalls: [Bool] = []
    func setCategoryOffMainThread(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                                  options: AVAudioSession.CategoryOptions) async throws {}
    func setPreferredSampleRate(_ sampleRate: Double) throws {}
    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}
    func setPreferredInput(_ input: AVAudioSessionPortDescription?) throws {}
    func setActiveOffMainThread(_ active: Bool, options: AVAudioSession.SetActiveOptions) async throws {
        activeCalls.append(active)
    }
}

private final class StartupStubRecorder: AVAudioRecorder {
    private var running = false
    let events: StartupEvents
    init(url: URL, events: StartupEvents) throws {
        self.events = events
        try super.init(url: url, settings: AudioQuality.whisperOptimized.settings)
    }
    override var isRecording: Bool { running }
    override func record() -> Bool {
        events.started()
        running = true
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        return true
    }
    override func stop() { events.stopped(); running = false }
}
#endif

@MainActor
final class RecorderStartupTests: XCTestCase {
    func testBlockingStartRunsOffMainActorAndTransfersOwnershipBack() async throws {
        let events = StartupEvents()
        let recorder = try await RecorderStartup.start {
            StartupProbe(events: events, succeeds: true)
        }
        XCTAssertFalse(events.snapshot.recordedOnMain)
        XCTAssertEqual(events.snapshot.starts, 1)
        XCTAssertEqual(events.snapshot.stops, 0)
        recorder.stop()
        XCTAssertEqual(events.snapshot.stops, 1)
    }

    func testFalseStartStopsRecorderAndThrowsInsteadOfReportingSuccess() async {
        let events = StartupEvents()
        do {
            _ = try await RecorderStartup.start { StartupProbe(events: events, succeeds: false) }
            XCTFail("A false record() result must fail startup")
        } catch {
            XCTAssertTrue(error is RecorderStartupError)
        }
        XCTAssertFalse(events.snapshot.recordedOnMain)
        XCTAssertEqual(events.snapshot.starts, 1)
        XCTAssertEqual(events.snapshot.stops, 1)
    }

    #if os(iOS)
    func testSuccessfulStartupPublishesOnlyAfterWorkerCompletes() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = StartupGate()
        let events = StartupEvents()
        installStart(on: model, gate: gate, events: events)
        model.beginAVAudioRecorderStartup(at: url)
        let task = try XCTUnwrap(model.recorderStartupTask)
        await gate.waitUntilEntered()
        XCTAssertTrue(model.isStartingRecording)
        XCTAssertFalse(model.isRecording)
        XCTAssertNil(model.audioRecorder)
        await gate.release()
        await task.value
        XCTAssertTrue(model.isRecording)
        XCTAssertFalse(model.isStartingRecording)
        XCTAssertNotNil(model.audioRecorder?.delegate)
        model.audioRecorder?.stop()
        model.stopRecordingTimer()
    }

    func testStopDuringStartupDoesNotRestartOrLeaveAnEmptyArtifact() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let controller = fixture.controller
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = StartupGate()
        let events = StartupEvents()
        installStart(on: model, gate: gate, events: events)
        model.beginAVAudioRecorderStartup(at: url)
        let task = try XCTUnwrap(model.recorderStartupTask)
        await gate.waitUntilEntered()
        model.stopRecording()
        XCTAssertTrue(controller.activeCalls.isEmpty, "Do not deactivate while the worker still owns I/O")
        await gate.release()
        await task.value
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isStartingRecording)
        XCTAssertNil(model.audioRecorder)
        XCTAssertEqual(events.snapshot.stops, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSupersededStartCannotReplaceNewerState() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let controller = fixture.controller
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = StartupGate()
        let events = StartupEvents()
        installStart(on: model, gate: gate, events: events)
        model.beginAVAudioRecorderStartup(at: url)
        let task = try XCTUnwrap(model.recorderStartupTask)
        await gate.waitUntilEntered()
        model.recordingStartupGeneration += 1
        let newURL = url.deletingLastPathComponent().appendingPathComponent("new.caf")
        model.recordingURL = newURL
        model.recordingSessionID = UUID()
        model.errorMessage = "new request owns this state"
        await gate.release()
        await task.value
        XCTAssertTrue(model.isStartingRecording)
        XCTAssertFalse(model.isRecording)
        XCTAssertEqual(model.recordingURL, newURL)
        XCTAssertEqual(model.errorMessage, "new request owns this state")
        XCTAssertTrue(controller.activeCalls.isEmpty)
        XCTAssertEqual(events.snapshot.stops, 1)
    }

    func testInterruptionDuringStartupKeepsRecoveryStateAndSealsWorker() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = StartupGate()
        let events = StartupEvents()
        installStart(on: model, gate: gate, events: events)
        model.beginAVAudioRecorderStartup(at: url)
        let task = try XCTUnwrap(model.recorderStartupTask)
        await gate.waitUntilEntered()
        model.isInInterruption = true
        model.recordingState = .interrupted(reason: .phoneCall, startedAt: Date())
        await gate.release()
        await task.value
        XCTAssertTrue(model.isInInterruption)
        XCTAssertTrue(model.recordingIntentActive)
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isStartingRecording)
        XCTAssertEqual(events.snapshot.stops, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStopDuringStartupRetainsUsableShortAudioForRecovery() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = StartupGate()
        let events = StartupEvents()
        installStart(on: model, gate: gate, events: events)
        model.beginAVAudioRecorderStartup(at: url)
        let task = try XCTUnwrap(model.recorderStartupTask)
        await gate.waitUntilEntered()
        try writeShortAudio(to: url)
        model.stopRecording()
        await gate.release()
        await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let result = await RecordingFinalizationPolicy.inspect(url: url, delegateSucceeded: true)
        XCTAssertTrue(result.isUsable)
        XCTAssertFalse(model.isRecording)
    }

    func testSupersededFailureCannotClearNewerStartupOrError() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let controller = fixture.controller
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = StartupGate()
        model.recorderStartForTesting = { _ in
            await gate.pause()
            throw RecorderStartupError.didNotStart
        }
        model.beginAVAudioRecorderStartup(at: url)
        let task = try XCTUnwrap(model.recorderStartupTask)
        await gate.waitUntilEntered()
        model.recordingStartupGeneration += 1
        model.errorMessage = "new request error"
        await gate.release()
        await task.value
        XCTAssertTrue(model.isStartingRecording)
        XCTAssertTrue(model.recordingIntentActive)
        XCTAssertEqual(model.errorMessage, "new request error")
        XCTAssertTrue(controller.activeCalls.isEmpty)
    }

    private func writeShortAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testStartupFailureClearsIntentAndReportsError() async throws {
        let fixture = try makeModel()
        let model = fixture.model
        let controller = fixture.controller
        let url = fixture.url
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        model.recorderStartForTesting = { _ in throw RecorderStartupError.didNotStart }
        model.beginAVAudioRecorderStartup(at: url)
        await model.recorderStartupTask?.value
        XCTAssertFalse(model.isRecording)
        XCTAssertFalse(model.isStartingRecording)
        XCTAssertFalse(model.recordingIntentActive)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(controller.activeCalls, [false])
    }

    private struct Fixture {
        let model: AudioRecorderViewModel
        let controller: StartupSessionController
        let url: URL
    }

    private func makeModel() throws -> Fixture {
        let controller = StartupSessionController()
        let manager = EnhancedAudioSessionManager(audioSessionController: controller)
        let model = AudioRecorderViewModel(audioSessionManager: manager)
        let directory = try TestHelpers.createTemporaryDirectory()
        let url = directory.appendingPathComponent("startup.caf")
        model.recordingStartupGeneration = 1
        model.isStartingRecording = true
        model.recordingIntentActive = true
        model.recordingSessionID = UUID()
        model.recoveryCoordinator.beginRecordingSession(try XCTUnwrap(model.recordingSessionID))
        model.recordingURL = url
        model.recordingSegments = [url]
        model.mainRecordingURL = url
        model.registerRecordingAttemptArtifact(at: url)
        return Fixture(model: model, controller: controller, url: url)
    }

    private func installStart(on model: AudioRecorderViewModel, gate: StartupGate, events: StartupEvents) {
        model.recorderStartForTesting = { url in
            let recorder = try await RecorderStartup.start { try StartupStubRecorder(url: url, events: events) }
            await gate.pause()
            return recorder
        }
    }
    #endif
}
