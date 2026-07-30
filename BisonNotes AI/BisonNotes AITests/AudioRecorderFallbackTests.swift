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
}
