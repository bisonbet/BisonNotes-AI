// Stand-ins for app types the Foundation-only sources reference but whose
// real definitions need Apple frameworks. Linux check package only.
import Foundation

/// The real AppLog writes through os.Logger.
final class AppLog: @unchecked Sendable {
    enum Level { case debug, info, warning, error }
    static let shared = AppLog()
    func summarization(_ message: String, level: Level = .info) {}
}

/// BetaFeatures.migrateLegacyOptIns reads this key.
enum TranscriptCleanupSettings {
    enum Keys {
        static let enabled = "swiftCheckStub.transcriptCleanupEnabled"
    }
}
