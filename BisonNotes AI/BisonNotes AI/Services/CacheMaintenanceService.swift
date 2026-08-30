//
//  CacheMaintenanceService.swift
//  BisonNotes AI
//
//  Bounds the two caches that grow without limit inside the app container.
//
//  On a Mac that had been running the app for a few months, `Library/Caches`
//  reached 29 GB and had to be cleared by hand:
//
//    * 11 GB of Hugging Face blobs. `defaultHubApi` downloads through a
//      content-addressed blob cache and then *copies* the result into its
//      `downloadBase`, so every MLX model is stored twice — and deleting a model
//      in Settings only ever removed the copy, leaving the blobs forever. A 7.9 GB
//      model the user still had cost 15.8 GB, and two models they had already
//      deleted were still costing 3.3 GB.
//    * 9.8 GB of CloudKit asset cache. CloudKit copies every `CKAsset` it uploads
//      or downloads into `Caches/CloudKit/<container>/Assets` and never reclaims
//      it, so a single sync of 570 recordings left a second full copy of the
//      user's audio library on disk.
//
//  `MLXSwiftDownloadManager` now drops a model's blobs as soon as the download
//  materializes, and again when the user deletes the model, so the blob sweep here
//  is a backstop rather than the primary fix: it collects what a killed download
//  left behind and what earlier versions of the app already accumulated.
//
//  Both are caches in the strict sense: the app reads neither of them, and both
//  are rebuilt on demand. The rules for what may be removed are pure static
//  functions on `CacheMaintenancePolicy` and are covered by
//  `CacheMaintenanceTests` — change them there, not inline in the sweeps.
//

import Foundation

// MARK: - Policy

enum CacheMaintenancePolicy {

    /// Hugging Face repository directory name for a model id, e.g.
    /// `mlx-community/Qwen3-4B` → `models--mlx-community--Qwen3-4B`. This is the
    /// layout `HubCache` writes and the Python `huggingface_hub` standard.
    static func hubRepoDirectoryName(forModelID modelID: String) -> String {
        "models--" + modelID.replacingOccurrences(of: "/", with: "--")
    }

    /// Inverse of `hubRepoDirectoryName(forModelID:)`. Returns `nil` for anything
    /// that is not a model repository directory, so a sweep never touches
    /// `.metadata`, `datasets--…`, or a stray file.
    ///
    /// A model id can itself contain `--`, so this only splits off the `models--`
    /// prefix and then the *first* remaining `--`, which separates namespace from
    /// repository name.
    static func modelID(forHubRepoDirectoryName name: String) -> String? {
        let prefix = "models--"
        guard name.hasPrefix(prefix) else { return nil }
        let body = String(name.dropFirst(prefix.count))
        guard let separator = body.range(of: "--") else { return nil }
        let namespace = String(body[body.startIndex..<separator.lowerBound])
        let repository = String(body[separator.upperBound...])
        guard !namespace.isEmpty, !repository.isEmpty else { return nil }
        return "\(namespace)/\(repository)"
    }

    /// Why a hub repository directory is being removed. Only used for reporting —
    /// both cases are equally safe to delete — but the two mean very different
    /// things when reading the log, so they are counted apart.
    enum HubPruneReason: Equatable {
        /// The model is installed. These blobs are a byte-for-byte second copy.
        case duplicateOfInstalledModel
        /// No installed model claims these blobs — an aborted or deleted download.
        case orphaned
    }

    /// Blobs are only ever read while a download is running: afterwards the app
    /// resolves models out of `downloadBase` alone. So a sweep is safe whenever no
    /// download is in flight, and must never run when one is, because the blob
    /// cache is also what lets an interrupted download resume.
    static func hubPruneReason(
        directoryName: String,
        installedModelIDs: Set<String>,
        isDownloadInFlight: Bool
    ) -> HubPruneReason? {
        guard !isDownloadInFlight else { return nil }
        guard let modelID = modelID(forHubRepoDirectoryName: directoryName) else { return nil }
        return installedModelIDs.contains(modelID) ? .duplicateOfInstalledModel : .orphaned
    }

    /// Nothing younger than this is ever removed. It is what stands in for an
    /// in-flight check, without coupling this service to the sync engine: the
    /// longest sync run on record took six minutes, so an hour is a wide margin,
    /// and an asset a running operation still needs is minutes old at most.
    static let cloudKitAssetMinimumAge: TimeInterval = 60 * 60

    /// An eligible asset older than this goes regardless of how small the cache is.
    static let cloudKitAssetMaximumAge: TimeInterval = 24 * 60 * 60

    /// Ceiling for the whole asset cache. Age alone is not enough: this cache was
    /// observed growing from 9.8 GB to 32 GB in about an hour of syncing, because
    /// CloudKit keeps a copy of every asset it moves. Past this, the oldest go
    /// first until the cache is back under budget.
    static let cloudKitAssetCacheBudget: Int64 = 2 * 1024 * 1024 * 1024

    /// One file in `Caches/CloudKit/<container>/Assets`.
    struct AssetEntry: Equatable {
        let identifier: String
        let byteCount: Int64
        let modifiedAt: Date?
    }

    /// Decides which cached assets to remove, oldest first.
    ///
    /// An asset with no readable timestamp is never removed — an unknown age must
    /// not be read as "old enough to delete".
    static func assetsToPrune(
        _ entries: [AssetEntry],
        now: Date,
        budget: Int64 = cloudKitAssetCacheBudget,
        minimumAge: TimeInterval = cloudKitAssetMinimumAge,
        maximumAge: TimeInterval = cloudKitAssetMaximumAge
    ) -> [AssetEntry] {
        let eligible = entries
            .filter { entry in
                guard let modifiedAt = entry.modifiedAt else { return false }
                return now.timeIntervalSince(modifiedAt) >= minimumAge
            }
            // `modifiedAt` is non-nil for everything that survived the filter.
            .sorted { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }

        var doomed: [AssetEntry] = []
        var remaining = entries.reduce(Int64(0)) { $0 + $1.byteCount }

        for entry in eligible {
            let isPastMaximumAge = now.timeIntervalSince(entry.modifiedAt ?? .distantPast) >= maximumAge
            guard isPastMaximumAge || remaining > budget else { break }
            doomed.append(entry)
            remaining -= entry.byteCount
        }

        return doomed
    }
}

// MARK: - Report

struct CacheMaintenanceReport: Equatable {
    var duplicateModelBlobBytes: Int64 = 0
    var orphanedModelBlobBytes: Int64 = 0
    var cloudKitAssetBytes: Int64 = 0
    var cloudKitAssetCount = 0
    var removedDirectoryCount = 0

    var reclaimedBytes: Int64 {
        duplicateModelBlobBytes + orphanedModelBlobBytes + cloudKitAssetBytes
    }

    var didReclaimAnything: Bool { reclaimedBytes > 0 }

    var formattedReclaimedBytes: String { Self.format(reclaimedBytes) }
    var formattedDuplicateModelBlobBytes: String { Self.format(duplicateModelBlobBytes) }
    var formattedOrphanedModelBlobBytes: String { Self.format(orphanedModelBlobBytes) }
    var formattedCloudKitAssetBytes: String { Self.format(cloudKitAssetBytes) }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Scheduling

@MainActor
final class CacheMaintenanceService {
    static let shared = CacheMaintenanceService()

    /// A sweep walks the whole blob cache, so it is not something to do on every
    /// activation. A Mac stays open for days, so a launch-only pass would never run
    /// on the machine that needs it most.
    static let sweepInterval: TimeInterval = 6 * 60 * 60

    private var lastSweep: Date?

    /// Sweeps unless one already ran within `sweepInterval`.
    ///
    /// The work happens off the main actor: a first pass on the machine that
    /// prompted this had 21 GB to delete, and doing that inline would have hung
    /// the app at launch. Only the download check is read here, where it is
    /// isolated, and handed to the sweep as a value.
    func pruneCachesIfDue(now: Date = Date()) {
        if let lastSweep, now.timeIntervalSince(lastSweep) < Self.sweepInterval { return }
        lastSweep = now

        Task.detached(priority: .utility) {
            // Checked again immediately before each deletion rather than sampled
            // once: the sweep can spend a long time enumerating and deleting tens
            // of gigabytes, and a download started in that window would otherwise
            // have the repository it is writing deleted out from under it.
            let report = await CacheMaintenanceSweep().run {
                await MainActor.run { MLXSwiftDownloadManager.shared.isDownloading }
            }
            guard report.didReclaimAnything else { return }
            AppLog.shared.fileManagement(
                "Cache maintenance reclaimed \(report.formattedReclaimedBytes) — "
                + "model blobs: \(report.formattedDuplicateModelBlobBytes) duplicate, "
                + "\(report.formattedOrphanedModelBlobBytes) orphaned; "
                + "CloudKit assets: \(report.formattedCloudKitAssetBytes) "
                + "across \(report.cloudKitAssetCount) file(s)"
            )
        }
    }
}

// MARK: - Sweep

/// The filesystem half. Deliberately not main-actor isolated — see
/// `pruneCachesIfDue`. Creates its own `FileManager`, which is the supported way
/// to use one off the main thread; it is constructed inside the detached task, so
/// nothing non-`Sendable` crosses an isolation boundary.
struct CacheMaintenanceSweep {

    private let fileManager = FileManager()

    /// - Parameter isDownloadInFlight: consulted again before every model-cache
    ///   deletion, so a download that starts mid-sweep still protects its blobs.
    func run(isDownloadInFlight: @Sendable () async -> Bool) async -> CacheMaintenanceReport {
        var report = CacheMaintenanceReport()
        await pruneHuggingFaceBlobCache(into: &report, isDownloadInFlight: isDownloadInFlight)
        pruneCloudKitAssetCache(into: &report)
        return report
    }

    private var cachesRoot: URL? {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    // MARK: Hugging Face blob cache

    /// `Library/Caches/huggingface/hub`, where `HubCache` stores downloaded blobs.
    /// Resolved by convention rather than by asking `HubCache`, so this file does
    /// not need the Hub modules linked; the app never sets `HF_HOME` or the other
    /// overrides, so a sandboxed container always resolves here.
    private var hubCacheRoot: URL? {
        cachesRoot?
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    /// `Library/Caches/models/<namespace>/<name>`, the `downloadBase` that
    /// `defaultHubApi` materializes models into and the only copy the app reads.
    private var materializedModelsRoot: URL? {
        cachesRoot?.appendingPathComponent("models", isDirectory: true)
    }

    private func pruneHuggingFaceBlobCache(
        into report: inout CacheMaintenanceReport,
        isDownloadInFlight: @Sendable () async -> Bool
    ) async {
        guard let hubCacheRoot, let materializedModelsRoot else { return }

        let installed = installedModelIDs(under: materializedModelsRoot)

        for directory in directChildren(of: hubCacheRoot) {
            guard isDirectory(directory) else { continue }
            // Re-read per directory. Deleting a repo a download is actively writing
            // would break both the download and the resume state it depends on.
            guard let reason = CacheMaintenancePolicy.hubPruneReason(
                directoryName: directory.lastPathComponent,
                installedModelIDs: installed,
                isDownloadInFlight: await isDownloadInFlight()
            ) else { continue }

            let size = directorySize(directory)
            do {
                try fileManager.removeItem(at: directory)
                report.removedDirectoryCount += 1
                switch reason {
                case .duplicateOfInstalledModel: report.duplicateModelBlobBytes += size
                case .orphaned: report.orphanedModelBlobBytes += size
                }
            } catch {
                AppLog.shared.fileManagement(
                    "Could not prune model blob cache \(directory.lastPathComponent): "
                    + error.localizedDescription,
                    level: .error
                )
            }
        }
    }

    /// A model counts as installed only once its `config.json` is present — the
    /// same check `MLXSwiftDownloadManager` uses to decide a model is usable. A
    /// half-materialized directory is treated as not installed, which at worst
    /// files its blobs under "orphaned"; either way they are safe to remove,
    /// because a download is not in flight.
    private func installedModelIDs(under root: URL) -> Set<String> {
        var ids = Set<String>()
        for namespace in directChildren(of: root) where isDirectory(namespace) {
            for repository in directChildren(of: namespace) where isDirectory(repository) {
                let configURL = repository.appendingPathComponent("config.json")
                guard fileManager.fileExists(atPath: configURL.path) else { continue }
                ids.insert("\(namespace.lastPathComponent)/\(repository.lastPathComponent)")
            }
        }
        return ids
    }

    // MARK: CloudKit asset cache

    private func pruneCloudKitAssetCache(into report: inout CacheMaintenanceReport) {
        guard let cachesRoot else { return }
        let cloudKitRoot = cachesRoot.appendingPathComponent("CloudKit", isDirectory: true)
        let now = Date()

        // One subdirectory per CloudKit container, named by a hash we cannot predict.
        // Each container's cache is budgeted on its own, so a second container can
        // never be starved by the first one's backlog.
        for container in directChildren(of: cloudKitRoot) where isDirectory(container) {
            let assets = container.appendingPathComponent("Assets", isDirectory: true)
            guard isSafeChild(assets, of: cloudKitRoot) else { continue }

            var urlsByIdentifier: [String: URL] = [:]
            var entries: [CacheMaintenancePolicy.AssetEntry] = []
            for asset in directChildren(of: assets) where isRegularFile(asset) {
                let identifier = asset.standardizedFileURL.path
                urlsByIdentifier[identifier] = asset
                entries.append(
                    CacheMaintenancePolicy.AssetEntry(
                        identifier: identifier,
                        byteCount: fileSize(asset),
                        modifiedAt: modificationOrCreationDate(asset)
                    )
                )
            }

            for doomed in CacheMaintenancePolicy.assetsToPrune(entries, now: now) {
                guard let url = urlsByIdentifier[doomed.identifier] else { continue }
                do {
                    try fileManager.removeItem(at: url)
                    report.cloudKitAssetCount += 1
                    report.cloudKitAssetBytes += doomed.byteCount
                } catch {
                    // A file CloudKit still holds open is expected to fail; the next
                    // pass picks it up. Not worth an error line per asset.
                    continue
                }
            }
        }
    }

    // MARK: File helpers

    private func directChildren(of directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func modificationOrCreationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return values?.contentModificationDate ?? values?.creationDate
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator where isRegularFile(url) {
            total += fileSize(url)
        }
        return total
    }

    private func isSafeChild(_ url: URL, of root: URL) -> Bool {
        let childPath = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return childPath == rootPath || childPath.hasPrefix(rootPath + "/")
    }
}
