import XCTest
@testable import BisonNotes_AI

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
}
