import AVFoundation
import Speech

/// Serializes stop with the entire buffer operation, not just its active check.
/// Once deactivate returns, no buffer can still write or append to Speech.
final class LiveTranscriptionTapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func whileActive(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        body()
    }

    func deactivate() {
        lock.lock()
        defer { lock.unlock() }
        active = false
    }
}

/// AVAudioEngine and Speech may call these blocks outside MainActor. Build the
/// blocks here so Swift does not inherit the service's actor isolation and emit
/// an executor precondition before the callback body can run.
enum LiveTranscriptionCallbacks {
    nonisolated static func makeAudioTap(
        file: AVAudioFile,
        request: SFSpeechAudioBufferRecognitionRequest,
        gate: LiveTranscriptionTapGate
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            gate.whileActive {
                try? file.write(from: buffer)
                request.append(buffer)
            }
        }
    }

    nonisolated static func makeRecognitionHandler(
        updateTranscript: @escaping @MainActor @Sendable (String) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, _ in
            guard let result else { return }
            let transcript = result.bestTranscription.formattedString
            Task { @MainActor in
                updateTranscript(transcript)
            }
        }
    }
}
