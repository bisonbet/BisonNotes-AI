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
    case upload(byteCount: Int64, signature: String)

    var uploads: Bool {
        if case .upload = self { return true }
        return false
    }
}

enum CloudAudioAssetPolicy {
    /// - Parameters:
    ///   - localSignature: signature of the file on disk, `nil` when unreadable.
    ///   - cloudSignature: signature stored on the existing cloud record.
    static func decide(
        includeAudioFiles: Bool,
        sourceExists: Bool,
        localSignature: String?,
        cloudSignature: String?,
        byteCount: Int64
    ) -> CloudAudioAssetDecision {
        guard includeAudioFiles else { return .skippedDisabled }
        guard sourceExists, let localSignature else { return .skippedMissingSource }
        guard localSignature != cloudSignature else { return .skippedUnchanged }
        return .upload(byteCount: byteCount, signature: localSignature)
    }
}

// MARK: - Staging

@MainActor
protocol CloudAssetStaging: AnyObject {
    /// Copies `sourceURL` into this run's staging directory and returns the copy.
    /// Returns `nil` when the source is gone — the caller keeps the metadata.
    func stage(_ sourceURL: URL) -> URL?
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

    func stage(_ sourceURL: URL) -> URL? {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }

        do {
            if !didCreateDirectory {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                didCreateDirectory = true
            }
            let destination = directory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(sourceURL.lastPathComponent)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: sourceURL, to: destination)
            stagedURLs.append(destination)
            return destination
        } catch {
            AppLog.shared.iCloudSync(
                "Could not stage an audio file for upload: \(error.localizedDescription)",
                level: .error
            )
            return nil
        }
    }

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
