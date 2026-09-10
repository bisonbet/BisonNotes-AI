import Foundation

enum SQLiteApplicationMediaRootID: String, CaseIterable, Hashable, Sendable {
    case documents = "documents"
    case documentsInbox = "documents-inbox"
    case watchTransferStaging = "watch-transfer-staging"
    case iCloudAudioStaging = "icloud-audio-staging"
    case shareInbox = "share-inbox"
    case sqliteMedia = "sqlite-media"
}

/// Maps paths already used by the app to logical migration roots.
///
/// The mapping does not create directories and does not scan or mutate user
/// data. A future app caller can use the injected FileManager initializer, or
/// tests can supply explicit roots without depending on a live sandbox.
struct SQLiteApplicationMediaRootMapping: Sendable {
    let registry: SQLiteMediaRootRegistry
    let sourceURLs: [SQLiteApplicationMediaRootID: URL]
    let destinationURLs: [SQLiteApplicationMediaRootID: URL]

    init(
        documentsRoot: URL,
        applicationSupportRoot: URL,
        temporaryRoot: URL,
        shareContainerRoot: URL? = nil
    ) throws {
        let sourceURLs = Self.makeSourceURLs(
            documentsRoot: documentsRoot,
            temporaryRoot: temporaryRoot,
            shareContainerRoot: shareContainerRoot
        )
        let destinationURLs = [
            SQLiteApplicationMediaRootID.sqliteMedia:
                applicationSupportRoot.appendingPathComponent(
                    "SQLiteMedia",
                    isDirectory: true
                )
        ]
        self.sourceURLs = sourceURLs
        self.destinationURLs = destinationURLs
        self.registry = try SQLiteMediaRootRegistry(
            sourceRoots: Self.stringKeyed(sourceURLs),
            destinationRoots: Self.stringKeyed(destinationURLs)
        )
    }

    init(
        fileManager: FileManager = .default,
        appGroupIdentifier: String? = nil
    ) throws {
        guard let documentsRoot = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first,
        let applicationSupportRoot = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SQLiteMediaFileOperationError.invalidRoot
        }
        let shareContainerRoot = appGroupIdentifier.flatMap {
            fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: $0
            )
        }
        try self.init(
            documentsRoot: documentsRoot,
            applicationSupportRoot: applicationSupportRoot,
            temporaryRoot: fileManager.temporaryDirectory,
            shareContainerRoot: shareContainerRoot
        )
    }
}

private extension SQLiteApplicationMediaRootMapping {
    static func makeSourceURLs(
        documentsRoot: URL,
        temporaryRoot: URL,
        shareContainerRoot: URL?
    ) -> [SQLiteApplicationMediaRootID: URL] {
        var sourceURLs: [SQLiteApplicationMediaRootID: URL] = [
            .documents: documentsRoot,
            .documentsInbox: documentsRoot.appendingPathComponent(
                "Inbox",
                isDirectory: true
            ),
            .watchTransferStaging: temporaryRoot.appendingPathComponent(
                "WatchTransferStaging",
                isDirectory: true
            ),
            .iCloudAudioStaging: temporaryRoot.appendingPathComponent(
                "iCloudAudioStaging",
                isDirectory: true
            )
        ]
        if let shareContainerRoot {
            sourceURLs[.shareInbox] = shareContainerRoot.appendingPathComponent(
                "ShareInbox",
                isDirectory: true
            )
        }
        return sourceURLs
    }

    static func stringKeyed(
        _ urls: [SQLiteApplicationMediaRootID: URL]
    ) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: urls.map { ($0.key.rawValue, $0.value) })
    }
}
