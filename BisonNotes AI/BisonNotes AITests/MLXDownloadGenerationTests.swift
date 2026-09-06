import Foundation
import XCTest
@testable import BisonNotes_AI

final class MLXDownloadGenerationTests: XCTestCase {
    @MainActor
    func testCancelledCompletionCannotCleanUpReplacementDownload() async {
        await exerciseRestart(staleFails: false, replacementFinishesFirst: false)
    }

    @MainActor
    func testCancelledFailureCannotSetReplacementError() async {
        await exerciseRestart(staleFails: true, replacementFinishesFirst: false)
    }

    @MainActor
    func testDeferredCleanupRunsOnceTheCancelledWriterStops() async {
        await exerciseRestart(staleFails: false, replacementFinishesFirst: true)
    }

    @MainActor
    private func exerciseRestart(staleFails: Bool, replacementFinishesFirst: Bool) async {
        let defaults = UserDefaults.standard
        let modelKey = MLXSwiftSettingsKeys.modelId
        let markerKey = MLXSwiftSettingsKeys.inFlightDownloadModelID
        let oldModel = defaults.object(forKey: modelKey)
        let oldMarker = defaults.object(forKey: markerKey)
        let model = "tests/generation-\(UUID())"
        defaults.set(model, forKey: modelKey)
        defer {
            defaults.set(oldModel, forKey: modelKey)
            defaults.set(oldMarker, forKey: markerKey)
        }
        let downloads = ControlledMLXDownloads()
        var cleanedModels: [String] = []
        let manager = MLXSwiftDownloadManager(
            downloadOperation: { _ in try await downloads.run() },
            blobCleanup: { cleanedModels.append($0) }
        )
        manager.startDownload()
        await waitUntil { downloads.pending.count == 1 }
        manager.cancelDownload()
        manager.startDownload()
        await waitUntil { downloads.pending.count == 2 }

        if replacementFinishesFirst {
            downloads.finish(1)
            await waitUntil { !manager.isDownloading }
            XCTAssertTrue(manager.isModelDownloaded)
            XCTAssertTrue(cleanedModels.isEmpty)
            XCTAssertFalse(manager.beginCacheMaintenance())
        }

        downloads.finish(0, fail: staleFails)
        await waitUntil { downloads.completed == (replacementFinishesFirst ? 2 : 1) }
        XCTAssertNil(manager.downloadError)
        if replacementFinishesFirst {
            // Nothing is writing blobs any more, so the cleanup the replacement's
            // finish had to defer runs here. It must not wait on the maintenance
            // sweep: `beginCacheMaintenance` is gated on the same counter, so a
            // cancelled download that never unwinds would strand a full duplicate
            // of the model on disk for the life of the process.
            await waitUntil { cleanedModels == [model] }
        } else {
            XCTAssertTrue(cleanedModels.isEmpty, "The cancelled generation must not delete any blobs")
            XCTAssertTrue(manager.isDownloading)
            XCTAssertEqual(defaults.string(forKey: markerKey), model)
            downloads.finish(1)
            await waitUntil { !manager.isDownloading }
            XCTAssertEqual(cleanedModels, [model])
            XCTAssertTrue(manager.isModelDownloaded)
        }
        XCTAssertNil(defaults.string(forKey: markerKey))
        XCTAssertTrue(manager.beginCacheMaintenance())
        manager.endCacheMaintenance()
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the controlled download")
    }
}

@MainActor
private final class ControlledMLXDownloads {
    var pending: [CheckedContinuation<Void, Error>] = []
    var completed = 0

    func run() async throws {
        defer { completed += 1 }
        // Intentionally ignore cancellation, just like a slow Hub operation.
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func finish(_ index: Int, fail: Bool = false) {
        if fail {
            pending[index].resume(throwing: POSIXError(.EIO))
        } else {
            pending[index].resume()
        }
    }
}
