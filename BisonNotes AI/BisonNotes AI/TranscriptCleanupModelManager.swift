//
//  TranscriptCleanupModelManager.swift
//  BisonNotes AI
//
//  Explicit lifecycle for the fixed S1-mini model. Enabling the preference
//  never starts this download; the user must request it here or from the
//  one-time transcript action.
//

import Foundation
import SwiftUI

#if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLXLLM
import MLX
import MLXLMCommon
#endif

enum TranscriptCleanupModelState: Equatable {
    case unavailable(String)
    case notDownloaded
    case downloading
    case waitingForCacheMaintenance
    case waitingForInference
    case ready
    case failed(String)
}

enum TranscriptCleanupModelLocator {
    #if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
    static var directory: URL {
        // Keep inspection aligned with MLXLMCommon.downloadModel's default hub.
        ModelConfiguration(
            id: TranscriptCleanupSettings.modelId,
            revision: TranscriptCleanupSettings.modelRevision
        ).modelDirectory(hub: defaultHubApi)
    }

    static var licenseURL: URL {
        directory.appendingPathComponent("LICENSE")
    }

    /// MLX's local repository path is keyed by model ID, not revision. Keep a
    /// small app-owned marker beside the downloaded files so a complete cache
    /// from another revision cannot be treated as the pinned model.
    static var revisionURL: URL {
        directory.appendingPathComponent(".bisonnotes-revision")
    }

    static var modelFilesComplete: Bool {
        CacheMaintenancePolicy.isMaterializedModelComplete(at: directory)
    }

    static var hasPinnedRevision: Bool {
        guard let marker = try? String(contentsOf: revisionURL, encoding: .utf8) else {
            return false
        }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines)
            == TranscriptCleanupSettings.modelRevision
    }

    static var isComplete: Bool {
        modelFilesComplete
            && FileManager.default.fileExists(atPath: licenseURL.path)
            && hasPinnedRevision
    }
    #else
    static var directory: URL? { nil }
    static var licenseURL: URL? { nil }
    static var revisionURL: URL? { nil }
    static var modelFilesComplete: Bool { false }
    static var hasPinnedRevision: Bool { false }
    static var isComplete: Bool { false }
    #endif
}

@MainActor
final class TranscriptCleanupModelManager: ObservableObject {
    static let shared = TranscriptCleanupModelManager()

    @Published private(set) var state: TranscriptCleanupModelState
    @Published private(set) var progress: Double = 0

    private var downloadTask: Task<Void, Never>?
    private var isCacheMaintenanceInProgress = false
    private var cacheMaintenanceYieldRequested = false
    private var queuedDownload = false
    private var queuedDeletion = false
    private var isDeletionInProgress = false

    private init() {
        state = Self.initialState()
    }

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    var isDownloadCancellable: Bool {
        isDownloading || queuedDownload
    }

    var isReady: Bool {
        return !isDeletionInProgress
            && TranscriptCleanupSettings.availability.isAvailable
            && TranscriptCleanupModelLocator.isComplete
    }

    var statusDescription: String {
        switch state {
        case .unavailable(let reason): return reason
        case .notDownloaded: return "Download S1-mini to enable on-device cleanup."
        case .downloading: return "Downloading S1-mini…"
        case .waitingForCacheMaintenance: return "Waiting for cache maintenance to finish…"
        case .waitingForInference: return "Waiting for active MLX work to finish…"
        case .ready: return "S1-mini is ready on this device."
        case .failed(let message): return message
        }
    }

    /// Re-reads the on-disk model state. Safe to call from any `onAppear`: a
    /// refresh must never overwrite an in-flight or queued download, because
    /// `isDownloading` is what the cache-maintenance sweep reads to decide the
    /// Hub blobs a resuming download still needs are safe to prune.
    func refresh() {
        guard downloadTask == nil, !queuedDownload, !queuedDeletion else { return }
        applyResolvedState()
    }

    /// Unconditional form, for the lifecycle points that already know no
    /// download or deletion is outstanding.
    private func applyResolvedState() {
        guard !isDeletionInProgress else { return }
        guard TranscriptCleanupSettings.availability.isAvailable else {
            state = .unavailable(
                TranscriptCleanupSettings.availability.explanation
                    ?? "Transcript cleanup is unavailable on this device."
            )
            return
        }
        state = TranscriptCleanupModelLocator.isComplete ? .ready : .notDownloaded
    }

    func startDownload() {
        guard TranscriptCleanupSettings.availability.isAvailable else {
            refresh()
            return
        }
        guard !isDownloading, downloadTask == nil, !isDeletionInProgress else { return }
        if isCacheMaintenanceInProgress {
            queuedDeletion = false
            queuedDownload = true
            cacheMaintenanceYieldRequested = true
            state = .waitingForCacheMaintenance
            return
        }

        guard invalidatePinnedRevisionMarker() else {
            state = .failed("The existing S1-mini revision marker could not be replaced.")
            return
        }

        progress = 0
        state = .downloading
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.downloadTask = nil }
            do {
                try await self.downloadModel()
                guard !Task.isCancelled else {
                    self.progress = 0
                    // `downloadTask` is still set until this task's `defer`, so
                    // the guarded `refresh()` would be a no-op here.
                    self.applyResolvedState()
                    return
                }
                self.progress = 1
                self.state = .ready
            } catch is CancellationError {
                self.progress = 0
                self.applyResolvedState()
            } catch {
                self.progress = 0
                self.state = .failed("S1-mini download failed: \(error.localizedDescription)")
            }
        }
    }

    func cancelDownload() {
        if queuedDownload {
            queuedDownload = false
            cacheMaintenanceYieldRequested = false
            progress = 0
            refresh()
            return
        }
        downloadTask?.cancel()
        progress = 0
    }

    func deleteDownloadedModel() {
        guard downloadTask == nil, !isDeletionInProgress else { return }
        if isCacheMaintenanceInProgress {
            queuedDownload = false
            queuedDeletion = true
            cacheMaintenanceYieldRequested = true
            state = .waitingForCacheMaintenance
            return
        }

        isDeletionInProgress = true
        state = .waitingForInference

        Task { @MainActor [weak self] in
            guard await MLXModelResourceCoordinator.shared.acquire() else {
                self?.isDeletionInProgress = false
                self?.refresh()
                return
            }
            guard let self else {
                await MLXModelResourceCoordinator.shared.release()
                return
            }

            #if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
            do {
                if FileManager.default.fileExists(atPath: TranscriptCleanupModelLocator.directory.path) {
                    try FileManager.default.removeItem(at: TranscriptCleanupModelLocator.directory)
                }
                self.isDeletionInProgress = false
                await MLXModelResourceCoordinator.shared.release()
                self.refresh()
            } catch {
                self.isDeletionInProgress = false
                self.state = .failed("Could not remove the S1-mini download: \(error.localizedDescription)")
                await MLXModelResourceCoordinator.shared.release()
            }
            #else
            self.isDeletionInProgress = false
            await MLXModelResourceCoordinator.shared.release()
            self.refresh()
            #endif
        }
    }

    /// Cache maintenance and this download share the same materialized Hub
    /// directory. The maintenance service calls these narrow hooks before it
    /// begins its detached sweep so it cannot delete a writer's partial files.
    @discardableResult
    func beginCacheMaintenance() -> Bool {
        guard downloadTask == nil, !isDeletionInProgress, !isCacheMaintenanceInProgress else { return false }
        isCacheMaintenanceInProgress = true
        cacheMaintenanceYieldRequested = false
        return true
    }

    func endCacheMaintenance() {
        isCacheMaintenanceInProgress = false
        cacheMaintenanceYieldRequested = false
        if queuedDeletion {
            queuedDeletion = false
            deleteDownloadedModel()
        } else if queuedDownload {
            queuedDownload = false
            startDownload()
        }
    }

    var shouldYieldCacheMaintenance: Bool {
        cacheMaintenanceYieldRequested
    }

    private static func initialState() -> TranscriptCleanupModelState {
        guard TranscriptCleanupSettings.availability.isAvailable else {
            return .unavailable(
                TranscriptCleanupSettings.availability.explanation
                    ?? "Transcript cleanup is unavailable on this device."
            )
        }
        return TranscriptCleanupModelLocator.isComplete ? .ready : .notDownloaded
    }

    private func invalidatePinnedRevisionMarker() -> Bool {
        #if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
        let markerURL = TranscriptCleanupModelLocator.revisionURL
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: markerURL)
            return true
        } catch {
            AppLog.shared.transcription(
                "Could not invalidate the S1-mini revision marker: \(error.localizedDescription)",
                level: .error
            )
            return false
        }
        #else
        return true
        #endif
    }

    private func downloadModel() async throws {
        #if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
        let configuration = ModelConfiguration(
            id: TranscriptCleanupSettings.modelId,
            revision: TranscriptCleanupSettings.modelRevision
        )
        _ = try await MLXLMCommon.downloadModel(
            hub: defaultHubApi,
            configuration: configuration
        ) { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self, self.isDownloading else { return }
                self.progress = progress.fractionCompleted
            }
        }

        guard TranscriptCleanupModelLocator.modelFilesComplete else {
            throw NSError(
                domain: "TranscriptCleanup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The downloaded S1-mini files are incomplete."]
            )
        }

        // `downloadModel` intentionally follows the existing MLX weight/config
        // primitive. Retain the model's additional naming license beside the
        // materialized snapshot without making it part of inference.
        try await downloadLicenseIfNeeded()

        try TranscriptCleanupSettings.modelRevision.write(
            to: TranscriptCleanupModelLocator.revisionURL,
            atomically: true,
            encoding: .utf8
        )

        guard TranscriptCleanupModelLocator.isComplete else {
            throw NSError(
                domain: "TranscriptCleanup",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The pinned S1-mini model snapshot is incomplete."]
            )
        }
        #else
        throw TranscriptCleanupNormalizerError.modelUnavailable
        #endif
    }

    #if !os(watchOS) && canImport(MLXLLM) && canImport(MLXLMCommon)
    private func downloadLicenseIfNeeded() async throws {
        let licenseURL = TranscriptCleanupModelLocator.licenseURL
        if FileManager.default.fileExists(atPath: licenseURL.path) {
            return
        }

        let escapedModelId = TranscriptCleanupSettings.modelId.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? TranscriptCleanupSettings.modelId
        let url = URL(
            string: "https://huggingface.co/\(escapedModelId)/resolve/"
                + "\(TranscriptCleanupSettings.modelRevision)/LICENSE"
        )!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "TranscriptCleanup",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The S1-mini license could not be retained."]
            )
        }
        try data.write(to: licenseURL, options: .atomic)
    }
    #endif
}
