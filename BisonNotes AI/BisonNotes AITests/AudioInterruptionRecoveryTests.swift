import XCTest

#if os(iOS)
@preconcurrency import AVFoundation
@testable import BisonNotes_AI

@MainActor
private final class ScriptedAudioSessionController: AudioSessionControlling {
    var category: AVAudioSession.Category = .playAndRecord
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var availableInputs: [AVAudioSessionPortDescription] = []
    var preferredInput: AVAudioSessionPortDescription?
    var currentInput: AVAudioSessionPortDescription?
    var currentOutputTypes: [String] = []

    var activeCalls: [Bool] = []
    var categoryCalls: [AVAudioSession.Category] = []
    var activationErrors: [Error] = []

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        options: AVAudioSession.CategoryOptions
    ) throws {
        categoryCalls.append(category)
        self.category = category
        categoryOptions = options
    }

    func setPreferredSampleRate(_ sampleRate: Double) throws {}

    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}

    func setPreferredInput(_ input: AVAudioSessionPortDescription?) throws {
        preferredInput = input
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activeCalls.append(active)
        if active, !activationErrors.isEmpty {
            throw activationErrors.removeFirst()
        }
    }
}

@MainActor
private final class RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class RecoveryTestState {
    var operationTriggers: [AudioRecoveryTrigger] = []
    var events: [String] = []
}

@MainActor
final class AudioInterruptionRecoveryTests: XCTestCase {
    private let audioSessionErrorDomain = "AVAudioSessionErrorDomain"

    func testCoordinatorRunsOneOperationAndCoalescesDuplicateRequests() async {
        let coordinator = AudioInterruptionRecoveryCoordinator()
        let gate = RecoveryGate()
        let sessionID = UUID()
        coordinator.beginRecordingSession(sessionID)
        let first = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .interruptionEnded,
            recordingURL: URL(fileURLWithPath: "/tmp/recording.m4a")
        )
        let duplicate = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .foregroundReconciliation,
            recordingURL: first.recordingURL
        )
        let state = RecoveryTestState()
        let operation: AudioInterruptionRecoveryCoordinator.Operation = { request in
            state.operationTriggers.append(request.trigger)
            await gate.wait()
            return .recovered
        }

        XCTAssertEqual(coordinator.request(first, operation: operation), .started(first.id))
        XCTAssertEqual(coordinator.request(duplicate, operation: operation), .coalesced(first.id))
        gate.release()
        await coordinator.waitForCompletion()

        XCTAssertEqual(coordinator.operationCount, 1)
        XCTAssertEqual(coordinator.coalescedRequestCount, 1)
        XCTAssertEqual(state.operationTriggers, [.interruptionEnded])
        XCTAssertEqual(coordinator.phase, .stoppedOrRecovered)
    }

    func testViewModelTransitionsOnceForDuplicateInterruptionBegin() {
        let manager = EnhancedAudioSessionManager()
        let viewModel = AudioRecorderViewModel(audioSessionManager: manager)
        let sessionID = UUID()
        viewModel.recordingSessionID = sessionID
        viewModel.recoveryCoordinator.beginRecordingSession(sessionID)
        viewModel.recordingIntentActive = true
        viewModel.isRecording = true
        let began = Notification(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        viewModel.handleAudioInterruption(began)
        viewModel.handleAudioInterruption(began)

        XCTAssertEqual(viewModel.interruptionTransitionCount, 1)
        if case .interrupted(.phoneCall, _) = viewModel.recordingState {
            // Expected recording-specific state transition.
        } else {
            XCTFail("The view model did not enter the interrupted state")
        }
    }

    func testManagerDoesNotReactToPostedInterruptionNotifications() {
        let controller = ScriptedAudioSessionController()
        let manager = EnhancedAudioSessionManager(audioSessionController: controller)
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            ]
        )

        XCTAssertTrue(controller.activeCalls.isEmpty)
        XCTAssertTrue(controller.categoryCalls.isEmpty)
        XCTAssertTrue(manager.currentConfiguration == nil)
    }

    func testForegroundRequestBecomesOneBoundedFollowUpAfterBackgroundDeferral() async {
        let coordinator = AudioInterruptionRecoveryCoordinator()
        let gate = RecoveryGate()
        let sessionID = UUID()
        coordinator.beginRecordingSession(sessionID)
        let background = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .unexpectedBackgroundStop,
            recordingURL: URL(fileURLWithPath: "/tmp/recording.m4a")
        )
        let foreground = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .foregroundReconciliation,
            recordingURL: background.recordingURL
        )
        let state = RecoveryTestState()
        let operation: AudioInterruptionRecoveryCoordinator.Operation = { request in
            state.operationTriggers.append(request.trigger)
            if request.trigger == .unexpectedBackgroundStop {
                await gate.wait()
                return .deferredUntilForeground
            }
            return .recovered
        }

        XCTAssertEqual(coordinator.request(background, operation: operation), .started(background.id))
        XCTAssertEqual(coordinator.request(foreground, operation: operation), .coalesced(background.id))
        gate.release()
        await coordinator.waitForCompletion()

        XCTAssertEqual(state.operationTriggers, [.unexpectedBackgroundStop, .foregroundReconciliation])
        XCTAssertEqual(coordinator.operationCount, 2)
        XCTAssertEqual(coordinator.phase, .stoppedOrRecovered)
    }

    func testCancellationInvalidatesCurrentAndStaleRequests() {
        let coordinator = AudioInterruptionRecoveryCoordinator()
        let sessionID = UUID()
        coordinator.beginRecordingSession(sessionID)
        let request = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .interruptionEnded,
            recordingURL: URL(fileURLWithPath: "/tmp/recording.m4a")
        )

        XCTAssertEqual(
            coordinator.request(request, operation: { _ in .recovered }),
            .started(request.id)
        )
		coordinator.invalidateRecordingSession(reason: "user stop")

        XCTAssertNil(coordinator.activeRequestID)
        XCTAssertEqual(coordinator.phase, .stoppedOrRecovered)
        XCTAssertEqual(
            coordinator.request(request, operation: { _ in .recovered }),
            .ignored
        )
    }

	func testActivationClassificationPreservesNSErrorEvidenceAndBoundedDisposition() {
		let insufficientPriority = NSError(
			domain: audioSessionErrorDomain,
			code: AVAudioSession.ErrorCode.insufficientPriority.rawValue
		)
        let deferFailure = AudioActivationFailure(
            error: insufficientPriority,
            attempt: 1,
            appIsBackgrounding: true
        )
        XCTAssertEqual(deferFailure.domain, audioSessionErrorDomain)
		XCTAssertEqual(deferFailure.code, AVAudioSession.ErrorCode.insufficientPriority.rawValue)
        XCTAssertEqual(deferFailure.category, .insufficientPriority)
        XCTAssertEqual(deferFailure.disposition, .deferUntilForeground)

        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .insufficientPriority,
                attempt: 1,
                appIsBackgrounding: false
            ),
            .retry
        )
        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .insufficientPriority,
                attempt: 3,
                appIsBackgrounding: false
            ),
            .fail
        )

        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .transient,
                attempt: 1,
                appIsBackgrounding: false
            ),
            .retry
        )
        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .transient,
                attempt: 3,
                appIsBackgrounding: false
            ),
            .fail
        )
    }

    func testManagerMissingConfigurationFailsAndRecoveryNeverDeactivatesAsRetryPrelude() {
        let missingController = ScriptedAudioSessionController()
        let missingManager = EnhancedAudioSessionManager(audioSessionController: missingController)
        XCTAssertThrowsError(try missingManager.activatePreparedSession()) { error in
            XCTAssertEqual(error as? AudioSessionRecoveryError, .missingConfiguration)
        }
        XCTAssertTrue(missingController.activeCalls.isEmpty)

		let controller = ScriptedAudioSessionController()
		controller.activationErrors = [
			NSError(domain: audioSessionErrorDomain, code: AVAudioSession.ErrorCode.isBusy.rawValue)
		]
        let manager = EnhancedAudioSessionManager(audioSessionController: controller)
        manager.currentConfiguration = .backgroundRecording

        XCTAssertThrowsError(try manager.activatePreparedSession())
        XCTAssertEqual(controller.activeCalls, [true])
        XCTAssertFalse(controller.activeCalls.contains(false))
    }

    func testActivationOrderingIsStopFinalizeThenActivateThenContinuation() async {
        let coordinator = AudioInterruptionRecoveryCoordinator()
        let sessionID = UUID()
        coordinator.beginRecordingSession(sessionID)
        let request = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .interruptionEnded,
            recordingURL: URL(fileURLWithPath: "/tmp/recording.m4a")
        )
        let state = RecoveryTestState()
        let operation: AudioInterruptionRecoveryCoordinator.Operation = { _ in
            state.events.append("stop")
            state.events.append("finalize")
            state.events.append("activate")
            state.events.append("create-continuation")
            return .recovered
        }

        _ = coordinator.request(request, operation: operation)
        await coordinator.waitForCompletion()

        XCTAssertEqual(state.events, ["stop", "finalize", "activate", "create-continuation"])
    }

    func testCallKitCorrelationClearsOnlyMatchingUUIDAndFallsBackToInterruptionTime() {
        var tracker = CallInterruptionTracker()
        let firstID = UUID()
        let secondID = UUID()
        let firstStart = Date(timeIntervalSince1970: 100)
        let secondStart = Date(timeIntervalSince1970: 200)
        tracker.observeStart(id: firstID, at: firstStart)
        tracker.observeStart(id: secondID, at: secondStart)

        XCTAssertEqual(tracker.observeEnd(id: firstID), firstStart)
        XCTAssertNil(tracker.starts[firstID])
        XCTAssertEqual(tracker.starts[secondID], secondStart)
        XCTAssertEqual(tracker.observeEnd(id: secondID), secondStart)
        XCTAssertTrue(tracker.starts.isEmpty)

        let interruptionStart = Date(timeIntervalSince1970: 300)
        let endedAt = Date(timeIntervalSince1970: 342)
        XCTAssertEqual(
            CallInterruptionDuration.seconds(
                callStartedAt: nil,
                interruptionStartedAt: interruptionStart,
                endedAt: endedAt
            ),
            42
        )
    }
}
#endif
