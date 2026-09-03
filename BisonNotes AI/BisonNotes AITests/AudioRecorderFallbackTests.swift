import XCTest
#if os(iOS)
@preconcurrency import AVFoundation
#endif
@testable import BisonNotes_AI

@MainActor
final class AudioRecorderFallbackTests: XCTestCase {
    func testLiveTranscriptionFailureUsesThePlatformRecordingBackend() {
        #if os(macOS)
        XCTAssertEqual(AudioRecorderViewModel.liveTranscriptionFallbackBackend, .macAudioEngine)
        #else
        XCTAssertEqual(AudioRecorderViewModel.liveTranscriptionFallbackBackend, .avAudioRecorder)
        #endif
    }

    func testNotificationObserverSetupIsIdempotent() throws {
        let viewModel = AudioRecorderViewModel()
        let initialForegroundObserver = try XCTUnwrap(viewModel.willEnterForegroundObserver)
        let initialBackgroundObserver = try XCTUnwrap(viewModel.didEnterBackgroundObserver)
        let initialRecoveryObserver = try XCTUnwrap(viewModel.checkForUnprocessedRecordingsObserver)

        viewModel.setupNotificationObservers()

        let repeatedForegroundObserver = try XCTUnwrap(viewModel.willEnterForegroundObserver)
        let repeatedBackgroundObserver = try XCTUnwrap(viewModel.didEnterBackgroundObserver)
        let repeatedRecoveryObserver = try XCTUnwrap(viewModel.checkForUnprocessedRecordingsObserver)
        XCTAssertTrue(initialForegroundObserver === repeatedForegroundObserver)
        XCTAssertTrue(initialBackgroundObserver === repeatedBackgroundObserver)
        XCTAssertTrue(initialRecoveryObserver === repeatedRecoveryObserver)

        #if os(iOS)
        XCTAssertNotNil(viewModel.interruptionObserver)
        XCTAssertNotNil(viewModel.routeChangeObserver)
        #endif
    }

    func testRejectedFinalizationRemovesOnlyOwnedCurrentAttemptArtifact() throws {
        let directory = try TestHelpers.createTemporaryDirectory()
        defer { try? TestHelpers.cleanupTemporaryDirectory(directory) }

        let ownedURL = directory.appendingPathComponent("owned.m4a")
        let viewModel = AudioRecorderViewModel()
        viewModel.registerRecordingAttemptArtifact(at: ownedURL)
        FileManager.default.createFile(atPath: ownedURL.path, contents: Data([1]))
        viewModel.rejectRecordingFinalization(
            at: ownedURL,
            rejection: .invalidDuration
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))

        let preexistingURL = directory.appendingPathComponent("preexisting.m4a")
        FileManager.default.createFile(atPath: preexistingURL.path, contents: Data([1]))
        viewModel.registerRecordingAttemptArtifact(at: preexistingURL)
        viewModel.removeOwnedRecordingAttemptArtifact(at: preexistingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preexistingURL.path))

        let unregisteredURL = directory.appendingPathComponent("unregistered.m4a")
        FileManager.default.createFile(atPath: unregisteredURL.path, contents: Data([1]))
        viewModel.removeOwnedRecordingAttemptArtifact(at: unregisteredURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unregisteredURL.path))
    }

    func testCrashRecoveryFailsOnlyNonTerminalJobs() {
        let message = BackgroundProcessingCrashRecoveryPolicy.failureMessage
        let nonTerminalStatuses: [JobProcessingStatus] = [
            .ready,
            .queued,
            .processing,
            .interrupted("background")
        ]

        for status in nonTerminalStatuses {
            XCTAssertEqual(
                BackgroundProcessingCrashRecoveryPolicy.statusAfterLaunch(
                    status: status,
                    previousSessionCrashed: true
                ),
                .failed(message)
            )
        }

        let terminalStatuses: [JobProcessingStatus] = [
            .completed,
            .failed("old failure"),
            .cancelled
        ]
        for status in terminalStatuses {
            XCTAssertEqual(
                BackgroundProcessingCrashRecoveryPolicy.statusAfterLaunch(
                    status: status,
                    previousSessionCrashed: true
                ),
                status
            )
        }

        XCTAssertEqual(
            BackgroundProcessingCrashRecoveryPolicy.statusAfterLaunch(
                status: .processing,
                previousSessionCrashed: false
            ),
            .processing
        )
    }

    /// A session that did not crash leaves every job's status alone, so the jobs
    /// queued after a clean launch are still picked up normally.
    func testCleanLaunchLeavesJobStatusesAlone() {
        for status in [JobProcessingStatus.ready, .queued, .processing, .interrupted("background")] {
            XCTAssertEqual(
                BackgroundProcessingCrashRecoveryPolicy.statusAfterLaunch(
                    status: status,
                    previousSessionCrashed: false
                ),
                status
            )
        }
    }

    #if os(iOS)
    func testAudioSessionObserversAreOwnedAndIdempotentAtViewModelBoundary() throws {
        let viewModel = AudioRecorderViewModel()
        let initialInterruptionObserver = try XCTUnwrap(viewModel.interruptionObserver)
        let initialRouteObserver = try XCTUnwrap(viewModel.routeChangeObserver)

        viewModel.setupNotificationObservers()

        XCTAssertTrue(initialInterruptionObserver === viewModel.interruptionObserver)
        XCTAssertTrue(initialRouteObserver === viewModel.routeChangeObserver)
        XCTAssertEqual(viewModel.audioSessionObserverRegistrationCount, 1)
        XCTAssertEqual(viewModel.routeObserverRegistrationCount, 1)
    }
    #endif
}
