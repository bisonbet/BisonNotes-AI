import Foundation

/// Keeps the app source-compatible on builds where FluidAudio is unavailable.
private actor UnavailableLocalDiarizationModelProvider: LocalDiarizationModelProvider {
    func cacheDirectory(for method: LocalDiarizationMethod) async -> URL? {
        nil
    }

    func isReady(for method: LocalDiarizationMethod) async -> Bool {
        false
    }

    func prepare(
        for method: LocalDiarizationMethod,
        forceRedownload: Bool,
        progressHandler: @escaping LocalDiarizationProgressHandler
    ) async throws {
        throw LocalDiarizationError.fluidAudioUnavailable
    }

    func makeRunner(
        for method: LocalDiarizationMethod
    ) async throws -> any LocalDiarizationRunner {
        throw LocalDiarizationError.fluidAudioUnavailable
    }

    func delete(for method: LocalDiarizationMethod) async throws {
        throw LocalDiarizationError.fluidAudioUnavailable
    }
}

enum LocalDiarizationModelProviderFactory {
    static func makeDefault() -> any LocalDiarizationModelProvider {
        #if canImport(FluidAudio)
        return FluidAudioLocalDiarizationModelProvider()
        #else
        return UnavailableLocalDiarizationModelProvider()
        #endif
    }
}
