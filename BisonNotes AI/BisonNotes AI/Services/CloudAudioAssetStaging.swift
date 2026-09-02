//
//  CloudAudioAssetStaging.swift
//  BisonNotes AI
//
//  Metadata sync has to succeed whether or not audio uploads do. Two rules keep
//  the two apart:
//
//  * a `CKAsset` is only ever built from an immutable per-run staging copy, so a
//    recording that keeps growing (or gets deleted) under an in-flight upload
//    cannot fail the whole batch with `.assetFileModified`; and
//  * a missing or unreadable source skips the asset and still uploads the
//    recording's metadata.
//

import CloudKit
import Foundation

// MARK: - Decision

enum CloudAudioAssetDecision: Equatable {
    /// Audio backup is switched off for this run.
    case skippedDisabled
    /// The cloud record already holds this exact file.
    case skippedUnchanged
    /// Nothing readable on disk. Metadata still uploads.
    case skippedMissingSource
    /// This run has staged as much as it may hold. Metadata uploads and the audio
    /// stays owed, exactly as a failed copy leaves it.
    case deferredOverStagingBudget
    case upload(byteCount: Int64, signature: String)

    var uploads: Bool {
        if case .upload = self { return true }
        return false
    }
}

enum CloudAudioAssetPolicy {
    /// Used when the volume will not say how much room is left. Small on purpose:
    /// an unknown disk is not one to fill.
    static let fallbackStagingByteBudget: Int64 = 512 * 1024 * 1024
    /// Even a roomy disk gains nothing from staging more than this in one run.
    static let maximumStagingByteBudget: Int64 = 8 * 1024 * 1024 * 1024

    /// Peak temporary disk one run may hold in staged copies.
    ///
    /// Every changed recording is copied before the first save request goes out,
    /// so without a bound the peak is the whole changed set — a first backup of a
    /// large library, on a device that may not have room for a second copy of it.
    /// Never more than half of what is free, so a backup cannot be the thing that
    /// fills the disk.
    static func stagingByteBudget(availableCapacity: Int64?) -> Int64 {
        guard let availableCapacity, availableCapacity > 0 else {
            return fallbackStagingByteBudget
        }
        return min(availableCapacity / 2, maximumStagingByteBudget)
    }

    /// - Parameters:
    ///   - localSignature: signature of the file on disk, `nil` when unreadable.
    ///   - cloudSignature: signature stored on the existing cloud record.
    ///   - stagedBytesSoFar: what this run has already copied into staging.
    ///   - stagingByteBudget: the peak this run may hold, from `stagingByteBudget(availableCapacity:)`.
    static func decide(
        includeAudioFiles: Bool,
        sourceExists: Bool,
        localSignature: String?,
        cloudSignature: String?,
        byteCount: Int64,
        stagedBytesSoFar: Int64 = 0,
        stagingByteBudget: Int64 = maximumStagingByteBudget
    ) -> CloudAudioAssetDecision {
        guard includeAudioFiles else { return .skippedDisabled }
        guard sourceExists, let localSignature else { return .skippedMissingSource }
        // An unchanged file is never copied, so it never spends the budget.
        guard localSignature != cloudSignature else { return .skippedUnchanged }
        // The first file of a run always goes, however large. Deferring it on size
        // alone would strand a recording bigger than the budget forever, and one
        // copy is the smallest peak that makes any progress at all.
        if stagedBytesSoFar > 0, stagedBytesSoFar + byteCount > stagingByteBudget {
            return .deferredOverStagingBudget
        }
        return .upload(byteCount: byteCount, signature: localSignature)
    }
}

// MARK: - Staging

@MainActor
protocol CloudAssetStaging: AnyObject {
    /// Copies `sourceURL` into this run's staging directory and returns the copy.
    /// Returns `nil` when no copy could be made — the source is gone, or the
    /// staging directory is full or unwritable. The caller keeps the metadata and
    /// leaves the audio owing.
    ///
    /// Asynchronous because the copy is the one genuinely expensive thing a run
    /// does on disk: a changed library is gigabytes, and doing it inline on the
    /// main actor froze the app for as long as the copy took.
    func stage(_ sourceURL: URL) async -> URL?
    /// Removes every staged file. Callers invoke this from `defer`, after CloudKit
    /// has reported a result for every record that referenced a staged asset.
    func cleanUp()
}

@MainActor
final class TemporaryDirectoryAssetStaging: CloudAssetStaging {
    private let fileManager: FileManager
    private let directory: URL
    private var stagedURLs: [URL] = []
    private var didCreateDirectory = false

    init(runIdentifier: String, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = fileManager.temporaryDirectory
            .appendingPathComponent("iCloudAudioStaging", isDirectory: true)
            .appendingPathComponent(runIdentifier, isDirectory: true)
    }

    var stagedFileCount: Int { stagedURLs.count }

    func stage(_ sourceURL: URL) async -> URL? {
        let destination = directory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(sourceURL.lastPathComponent)

        let copy = AssetStagingCopy(source: sourceURL, destination: destination)
        let outcome = await Task.detached(priority: .utility) { copy.run() }.value
        switch outcome {
        case .copied:
            didCreateDirectory = true
            stagedURLs.append(destination)
            return destination
        case .missingSource:
            return nil
        case .failed(let message):
            AppLog.shared.iCloudSync(
                "Could not stage an audio file for upload: \(message)",
                level: .error
            )
            return nil
        }
    }

    /// Stays synchronous: callers invoke it from `defer`, and unlinking the run
    /// directory is metadata work, not the byte copying that had to move off the
    /// main actor.
    func cleanUp() {
        for url in stagedURLs {
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }
        stagedURLs.removeAll()
        if didCreateDirectory {
            try? fileManager.removeItem(at: directory)
            didCreateDirectory = false
        }
    }
}

/// The filesystem half of staging. Deliberately not main-actor isolated — it is
/// the copy itself, which for a changed library is gigabytes. Following
/// `CacheMaintenanceFileSweeper`, the `FileManager` is constructed inside the
/// detached task, so nothing non-`Sendable` crosses an isolation boundary.
private struct AssetStagingCopy: Sendable {
    enum Outcome: Sendable {
        case copied
        /// The file went away between the decision to upload it and the copy.
        case missingSource
        case failed(String)
    }

    let source: URL
    let destination: URL

    func run() -> Outcome {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: source.path) else { return .missingSource }
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
            return .copied
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension CKError {
    /// CloudKit could not read, or no longer trusts, the file behind a `CKAsset`.
    var isAssetFileProblem: Bool {
        switch code {
        case .assetFileNotFound, .assetFileModified:
            return true
        default:
            return false
        }
    }
}
