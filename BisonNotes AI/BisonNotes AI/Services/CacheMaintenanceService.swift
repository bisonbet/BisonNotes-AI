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

    /// A materialized model is usable only when its configuration and all of its
    /// weights have landed. `config.json` can be copied before the download is
    /// interrupted, so it is not a completion marker by itself.
    ///
    /// A sharded model publishes `model.safetensors.index.json`, whose weight map
    /// names every shard. One non-empty shard is no evidence the rest arrived —
    /// and treating a half-copied model as installed is what let the sweep delete
    /// the very blob cache the interrupted download needed to resume, and made
    /// the model read as ready in Settings. So when the index is present, every
    /// shard it names must be present and non-empty; an index that cannot be read
    /// is itself a partly copied model, and counts as incomplete.
    static func isMaterializedModelComplete(at directory: URL) -> Bool {
        let configURL = directory.appendingPathComponent("config.json")
        guard isNonEmptyRegularFile(configURL) else { return false }

        if let shardNames = shardedWeightFilenames(at: directory) {
            guard !shardNames.isEmpty else { return false }
            return shardNames.allSatisfy {
                isNonEmptyRegularFile(directory.appendingPathComponent($0))
            }
        }

        return containsNonEmptyWeightFile(at: directory)
    }

    /// Every distinct filename the safetensors weight map references, or `nil`
    /// when this model is not sharded (no index file at all).
    ///
    /// An index that exists but cannot be parsed returns an empty set rather than
    /// `nil`: the file is there, so the model claims to be sharded, and falling
    /// back to the single-weight check would call it complete on one shard.
    private static func shardedWeightFilenames(at directory: URL) -> Set<String>? {
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        guard isNonEmptyRegularFile(indexURL) else { return nil }

        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = json["weight_map"] as? [String: String] else {
            return []
        }
        return Set(weightMap.values)
    }

    private static func containsNonEmptyWeightFile(at directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let file = enumerator.nextObject() as? URL {
            guard file.pathExtension.lowercased() == "safetensors" else { continue }
            if isNonEmptyRegularFile(file) { return true }
        }
        return false
    }

    private static func isNonEmptyRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
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

struct CacheMaintenanceReport: Equatable, Sendable {
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

        // Reserve the shared Hub cache before leaving the main actor: no sweep may
        // start while a download is running or still unwinding, and two sweeps may
        // never overlap. What protects a download that starts *during* a sweep is
        // the per-deletion re-check below, not this reservation.
        guard MLXSwiftDownloadManager.shared.beginCacheMaintenance() else { return }
        lastSweep = now

        Task.detached(priority: .utility) {
            // Checked again immediately before each deletion rather than sampled
            // once: the sweep can spend a long time enumerating and deleting tens
            // of gigabytes, and a download started in that window would otherwise
            // have the repository it is writing deleted out from under it.
            let report = await CacheMaintenanceSweep().run(
                isDownloadInFlight: {
                    await MainActor.run { MLXSwiftDownloadManager.shared.isDownloading }
                },
                isCloudSyncActive: {
                    await MainActor.run {
                        SummaryManager.shared.getiCloudManager().operationCoordinator.isRunning
                    }
                }
            )
            // Released on its own, before anything that can return early: a
            // reservation left behind blocks every later sweep for the life of
            // the process.
            await MainActor.run { MLXSwiftDownloadManager.shared.endCacheMaintenance() }
            await MainActor.run {
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
}

// MARK: - Sweep

/// The filesystem half. Deliberately not main-actor isolated — see
/// `pruneCachesIfDue`. Creates its own `FileManager`, which is the supported way
/// to use one off the main thread; it is constructed inside the detached task, so
/// nothing non-`Sendable` crosses an isolation boundary.
struct CacheMaintenanceSweep {

    private let fileManager = FileManager()
    private let cachesRootOverride: URL?

    /// - Parameter cachesRoot: overrides the container's `Library/Caches`. Only tests
    ///   pass this; it is what lets the deletion behavior be exercised against a real
    ///   directory tree rather than only through the pure policy.
    init(cachesRoot: URL? = nil) {
        self.cachesRootOverride = cachesRoot
    }

    /// - Parameter isDownloadInFlight: consulted again before every model-cache
    ///   deletion, so a download that starts mid-sweep still protects its blobs.
    /// - Parameter isCloudSyncActive: consulted again before every CloudKit asset
    ///   deletion. A restore fetches its assets and then copies them out of this
    ///   cache one at a time; a sweep that reaches a file the copy has not got to
    ///   yet takes that recording's audio with it.
    func run(
        isDownloadInFlight: @Sendable () async -> Bool,
        isCloudSyncActive: @Sendable () async -> Bool
    ) async -> CacheMaintenanceReport {
        var report = CacheMaintenanceReport()
        await pruneHuggingFaceBlobCache(into: &report, isDownloadInFlight: isDownloadInFlight)
        await pruneCloudKitAssetCache(into: &report, isCloudSyncActive: isCloudSyncActive)
        return report
    }

    private var cachesRoot: URL? {
        cachesRootOverride ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
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
            guard isDirectory(directory),
                  let modelID = CacheMaintenancePolicy.modelID(
                      forHubRepoDirectoryName: directory.lastPathComponent
                  ) else {
                continue
            }

            // A process can die between two file copies, after a complete blob
            // has been promoted, or with only config.json materialized. Keep the
            // durable resume state until a complete materialized model exists.
            guard !shouldKeepRepositoryForResume(
                directory,
                modelID: modelID,
                materializedModelsRoot: materializedModelsRoot
            ) else { continue }

            // Sizing walks the whole repository, which for a multi-gigabyte model is
            // far from instant. Nothing slow may sit between the download check and
            // the delete it authorizes, so the traversal happens first and the check
            // is read immediately before the removal — a download that starts while
            // this is measuring is still seen. Re-read per directory, because a
            // single reading taken before the sweep goes stale the moment it is used.
            let size = directorySize(directory)

            guard let reason = CacheMaintenancePolicy.hubPruneReason(
                directoryName: directory.lastPathComponent,
                installedModelIDs: installed,
                isDownloadInFlight: await isDownloadInFlight()
            ) else { continue }

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

    /// A model counts as installed only once its configuration and weights are
    /// present. A half-materialized directory must not make its blob cache look
    /// like a duplicate or make the download manager report a usable model.
    private func installedModelIDs(under root: URL) -> Set<String> {
        var ids = Set<String>()
        for namespace in directChildren(of: root) where isDirectory(namespace) {
            for repository in directChildren(of: namespace) where isDirectory(repository) {
                guard CacheMaintenancePolicy.isMaterializedModelComplete(at: repository) else { continue }
                ids.insert("\(namespace.lastPathComponent)/\(repository.lastPathComponent)")
            }
        }
        return ids
    }

    private func shouldKeepRepositoryForResume(
        _ directory: URL,
        modelID: String,
        materializedModelsRoot: URL
    ) -> Bool {
        if let materializedDirectory = materializedModelDirectory(
            for: modelID,
            under: materializedModelsRoot
        ) {
            if CacheMaintenancePolicy.isMaterializedModelComplete(at: materializedDirectory) {
                return false
            }
            if isDirectory(materializedDirectory) {
                return true
            }
        }

        if containsIncompleteBlob(in: directory) {
            return true
        }

        // This marker survives a crash or force-quit. It covers the small window
        // after a blob is promoted but before the corresponding materialized file
        // is copied, when neither the `.incomplete` file nor config.json is enough.
        return UserDefaults.standard.string(
            forKey: MLXSwiftSettingsKeys.inFlightDownloadModelID
        ) == modelID
    }

    private func materializedModelDirectory(for modelID: String, under root: URL) -> URL? {
        let components = modelID.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }
        return root
            .appendingPathComponent(String(components[0]), isDirectory: true)
            .appendingPathComponent(String(components[1]), isDirectory: true)
    }

    private func containsIncompleteBlob(in repository: URL) -> Bool {
        let blobs = repository.appendingPathComponent("blobs", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: blobs,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let file = enumerator.nextObject() as? URL {
            guard file.pathExtension == "incomplete" else { continue }
            if isRegularFile(file) { return true }
        }
        return false
    }

    // MARK: CloudKit asset cache

    private func pruneCloudKitAssetCache(
        into report: inout CacheMaintenanceReport,
        isCloudSyncActive: @Sendable () async -> Bool
    ) async {
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
                // Read immediately before each deletion rather than sampled once,
                // for the same reason the blob sweep does: enumerating and deleting
                // takes long enough that a sync started in that window would
                // otherwise have assets removed from under it. A restore that runs
                // past the minimum age is exactly the case — its own files stop
                // being too young to prune while it is still copying them out.
                //
                // Skip the file, do not abandon the sweep: the gate is global, so
                // nothing is removed while a sync runs either way, but a sync that
                // finishes part way through must not cost this pass the rest of the
                // cache — and the containers behind this one with it.
                if await isCloudSyncActive() { continue }
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
