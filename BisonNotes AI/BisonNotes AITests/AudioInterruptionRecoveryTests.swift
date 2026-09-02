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

    func testCategoryChangeKeepsAnActiveRecordingOnItsCurrentRoute() {
        let viewModel = AudioRecorderViewModel()
        viewModel.isRecording = true
        viewModel.recordingState = .recording

        viewModel.handleRouteChange(reason: .categoryChange, wasUsingMicrophone: true)

        XCTAssertTrue(viewModel.isRecording)
        XCTAssertEqual(viewModel.recordingState, .recording)
        XCTAssertNil(viewModel.recordingTimer)
        XCTAssertTrue(
            viewModel.lastRouteChangeReason.contains(
                "raw: \(AVAudioSession.RouteChangeReason.categoryChange.rawValue)"
            )
        )
    }

    func testStartingRecordingTimerInvalidatesThePreviousTimer() throws {
        let viewModel = AudioRecorderViewModel()
        defer { viewModel.stopRecordingTimer() }

        viewModel.startRecordingTimer()
        let firstTimer = try XCTUnwrap(viewModel.recordingTimer)

        viewModel.startRecordingTimer()
        let replacementTimer = try XCTUnwrap(viewModel.recordingTimer)

        XCTAssertFalse(firstTimer.isValid)
        XCTAssertFalse(firstTimer === replacementTimer)
        XCTAssertTrue(replacementTimer.isValid)
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
                attempt: AudioActivationFailure.maximumActivationAttempts,
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
                attempt: AudioActivationFailure.maximumActivationAttempts,
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

    func testEndedInterruptionIsRetainedAsFollowUpWhenTheActiveRecoveryYields() async {
        let coordinator = AudioInterruptionRecoveryCoordinator()
        let gate = RecoveryGate()
        let sessionID = UUID()
        coordinator.beginRecordingSession(sessionID)
        let recordingURL = URL(fileURLWithPath: "/tmp/recording.m4a")
        let first = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .interruptionEnded,
            recordingURL: recordingURL
        )
        let second = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .interruptionEnded,
            recordingURL: recordingURL
        )
        let state = RecoveryTestState()
        let operation: AudioInterruptionRecoveryCoordinator.Operation = { request in
            state.operationTriggers.append(request.trigger)
            guard request.id == first.id else { return .recovered }
            // A second interruption took the microphone, so the active
            // operation yields instead of burning its activation budget.
            await gate.wait()
            return .cancelled
        }

        XCTAssertEqual(coordinator.request(first, operation: operation), .started(first.id))
        XCTAssertEqual(coordinator.request(second, operation: operation), .coalesced(first.id))
        gate.release()
        await coordinator.waitForCompletion()

        XCTAssertEqual(state.operationTriggers, [.interruptionEnded, .interruptionEnded])
        XCTAssertEqual(coordinator.operationCount, 2)
        XCTAssertEqual(coordinator.phase, .stoppedOrRecovered)
    }

    func testUnexpectedBackgroundStopIsNeverRetainedAsAFollowUp() async {
        let coordinator = AudioInterruptionRecoveryCoordinator()
        let gate = RecoveryGate()
        let sessionID = UUID()
        coordinator.beginRecordingSession(sessionID)
        let recordingURL = URL(fileURLWithPath: "/tmp/recording.m4a")
        let ended = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .interruptionEnded,
            recordingURL: recordingURL
        )
        let backgroundStop = AudioRecoveryRequest(
            recordingSessionID: sessionID,
            trigger: .unexpectedBackgroundStop,
            recordingURL: recordingURL
        )
        let state = RecoveryTestState()
        let operation: AudioInterruptionRecoveryCoordinator.Operation = { request in
            state.operationTriggers.append(request.trigger)
            await gate.wait()
            return .cancelled
        }

        _ = coordinator.request(ended, operation: operation)
        XCTAssertEqual(coordinator.request(backgroundStop, operation: operation), .coalesced(ended.id))
        gate.release()
        await coordinator.waitForCompletion()

        XCTAssertEqual(state.operationTriggers, [.interruptionEnded])
        XCTAssertEqual(coordinator.operationCount, 1)
    }

    func testUnknownActivationErrorsUseTheirOwnShortBound() {
        let unmapped = NSError(domain: audioSessionErrorDomain, code: -99999)
        XCTAssertEqual(AudioActivationFailure.category(for: unmapped), .unknown)
        XCTAssertLessThan(
            AudioActivationFailure.maximumUnknownActivationAttempts,
            AudioActivationFailure.maximumActivationAttempts
        )
        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .unknown,
                attempt: 1,
                appIsBackgrounding: false
            ),
            .retry
        )
        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .unknown,
                attempt: AudioActivationFailure.maximumUnknownActivationAttempts,
                appIsBackgrounding: false
            ),
            .fail
        )
        // The transient budget is deliberately longer, so the short bound is
        // the unknown category's own and not a shared cap.
        XCTAssertEqual(
            AudioActivationFailure.disposition(
                for: .transient,
                attempt: AudioActivationFailure.maximumUnknownActivationAttempts,
                appIsBackgrounding: false
            ),
            .retry
        )
    }

    func testEndedWithoutResumeOptionRequestsPreservationInsteadOfReacquisition() {
        XCTAssertEqual(
            AudioRecorderViewModel.recoveryTrigger(forInterruptionEndedWithResumeOption: true),
            .interruptionEnded
        )
        XCTAssertEqual(
            AudioRecorderViewModel.recoveryTrigger(forInterruptionEndedWithResumeOption: false),
            .interruptionEndedWithoutResume
        )
    }

    func testStalledInterruptionWatchdogStaysDeferredWhileACallIsActive() async {
        let manager = EnhancedAudioSessionManager()
        let viewModel = AudioRecorderViewModel(audioSessionManager: manager)
        let sessionID = UUID()
        let startedAt = Date()
        let recordingURL = URL(fileURLWithPath: "/tmp/recording.m4a")
        viewModel.recordingSessionID = sessionID
        viewModel.recoveryCoordinator.beginRecordingSession(sessionID)
        viewModel.recordingIntentActive = true
        viewModel.isInInterruption = true
        viewModel.interruptionEndHandled = false
        viewModel.interruptionRecordingURL = recordingURL
        viewModel.recordingState = .interrupted(reason: .phoneCall, startedAt: startedAt)
        viewModel.callInterruptionTracker.observeStart(id: UUID(), at: startedAt)

        await viewModel.reconcileStalledInterruption(startedAt: startedAt)
        viewModel.stopInterruptionWatchdog()

        XCTAssertTrue(viewModel.isInInterruption)
        XCTAssertFalse(viewModel.interruptionEndHandled)
        XCTAssertTrue(viewModel.callInterruptionTracker.hasActiveCalls)
        if case .interrupted = viewModel.recordingState {
            // The recording stays parked until the call actually ends.
        } else {
            XCTFail("The watchdog reconciled a recording while a call was still active")
        }
    }

    /// A reclaim task is suspended across validation and export, and the parked
    /// entry is deliberately left on disk until its save lands. A second
    /// superseded session therefore reads the same entry again — and used to
    /// launch a second task for it, merging the same segments twice and inserting
    /// a duplicate row for one recording.
    @MainActor
    func testASecondPassCannotClaimAReclaimAlreadyInFlight() {
        let viewModel = AudioRecorderViewModel()

        XCTAssertTrue(viewModel.reserveReclaim(forKey: "parked.m4a"), "The first pass owns the reclaim")
        XCTAssertFalse(
            viewModel.reserveReclaim(forKey: "parked.m4a"),
            "A second pass must leave the entry to the task already running"
        )
        XCTAssertTrue(
            viewModel.reserveReclaim(forKey: "other.m4a"),
            "A different parked recovery is independent"
        )

        // A reclaim that did not persist leaves its segments for the next pass,
        // which has to be able to claim them.
        viewModel.releaseReclaim(forKey: "parked.m4a")
        XCTAssertTrue(viewModel.reserveReclaim(forKey: "parked.m4a"))
    }

    func testParkedRecoverySnapshotsDoNotOverwriteEachOther() throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let snapshotURL = documents.appendingPathComponent("deferred-recovery.json")
        let firstMain = documents.appendingPathComponent("test-parked-a.m4a")
        let secondMain = documents.appendingPathComponent("test-parked-b.m4a")
        for url in [firstMain, secondMain] {
            try Data("audio".utf8).write(to: url)
        }
        defer {
            for url in [firstMain, secondMain, snapshotURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let manager = EnhancedAudioSessionManager()
        let viewModel = AudioRecorderViewModel(audioSessionManager: manager)
        try? FileManager.default.removeItem(at: snapshotURL)

        // Session A parks its segment, then session B — which superseded it —
        // parks its own. B's write must not erase A's only durable pointer.
        viewModel.persistRecoverySnapshot(
            segments: [firstMain],
            mainRecordingURL: firstMain,
            currentSegmentIndex: 0
        )
        viewModel.persistRecoverySnapshot(
            segments: [secondMain],
            mainRecordingURL: secondMain,
            currentSegmentIndex: 0
        )

        XCTAssertEqual(
            try parkedMainFilenames(at: snapshotURL),
            ["test-parked-a.m4a", "test-parked-b.m4a"]
        )

        // Retiring one entry leaves the other reachable.
        viewModel.clearDeferredRecoverySnapshot(forKey: "test-parked-a.m4a")
        XCTAssertEqual(try parkedMainFilenames(at: snapshotURL), ["test-parked-b.m4a"])

        viewModel.clearDeferredRecoverySnapshotEntries(containing: secondMain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testSavingOneSegmentDoesNotRetireAMultiSegmentTrail() throws {
        let documents = try XCTUnwrap(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let snapshotURL = documents.appendingPathComponent("deferred-recovery.json")
        let main = documents.appendingPathComponent("test-multi.m4a")
        let second = documents.appendingPathComponent("test-multi_seg1.m4a")
        for url in [main, second] {
            try Data("audio".utf8).write(to: url)
        }
        defer {
            for url in [main, second, snapshotURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let manager = EnhancedAudioSessionManager()
        let viewModel = AudioRecorderViewModel(audioSessionManager: manager)
        try? FileManager.default.removeItem(at: snapshotURL)
        viewModel.persistRecoverySnapshot(
            segments: [main, second],
            mainRecordingURL: main,
            currentSegmentIndex: 1
        )

        // Saving a later segment on its own does not finish this recording:
        // the earlier audio still needs the trail to be merged.
        viewModel.clearDeferredRecoverySnapshotEntries(containing: second)
        XCTAssertEqual(try parkedMainFilenames(at: snapshotURL), ["test-multi.m4a"])

        // Saving the merge target does finish it.
        viewModel.clearDeferredRecoverySnapshotEntries(containing: main)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    private func parkedMainFilenames(at snapshotURL: URL) throws -> [String] {
        let data = try Data(contentsOf: snapshotURL)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = try XCTUnwrap(object?["entries"] as? [[String: Any]])
        return entries.compactMap { $0["mainRecordingFilename"] as? String }.sorted()
    }

    func testReclaimedRecordingIsNamedFromItsOwnCaptureDate() {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let name = AudioRecorderViewModel.appRecordingDisplayName(capturedAt: captured)
        XCTAssertTrue(name.hasPrefix("apprecording-"))
        // The successor session's start time must not be able to produce this.
        XCTAssertNotEqual(
            name,
            AudioRecorderViewModel.appRecordingDisplayName(capturedAt: Date())
        )
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
