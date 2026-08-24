import CoreData
import Foundation
import UniformTypeIdentifiers

struct SummarySupplementalData: Codable, Sendable {
    var userNotes: String?
    var attachments: [SummaryAttachment]

    static let empty = SummarySupplementalData(userNotes: nil, attachments: [])
}

/// Serializes the synchronous attachment/file operations on the main actor so
/// the shared encoder, decoder, and file-system mutations cannot race. The
/// public API remains synchronous to preserve existing UI call sites.
@MainActor
final class SummaryAttachmentStore {
    static let shared = SummaryAttachmentStore()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load(for summaryId: UUID) -> SummarySupplementalData {
        let metadataURL = metadataFileURL(for: summaryId)
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? decoder.decode(SummarySupplementalData.self, from: data) else {
            return .empty
        }
        return decoded
    }

    @discardableResult
    func addAttachment(from sourceURL: URL, summaryId: UUID) throws -> SummaryAttachment {
        let fileName = sourceURL.lastPathComponent
        let id = UUID()
        let destinationFolder = attachmentsDirectory(for: summaryId)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        AppFileProtection.applyRecursively(to: storageDirectory(for: summaryId))

        let sanitizedName = sanitizeFileName(fileName)
        let storedFileName = "\(id.uuidString)_\(sanitizedName)"
        let destinationURL = destinationFolder.appendingPathComponent(storedFileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        AppFileProtection.apply(to: destinationURL)

        let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let contentType = UTType(filenameExtension: sourceURL.pathExtension)?.identifier

        let attachment = SummaryAttachment(
            id: id,
            fileName: fileName,
            storedFileName: storedFileName,
            contentType: contentType,
            fileSize: fileSize,
            createdAt: Date()
        )

        var supplemental = load(for: summaryId)
        supplemental.attachments.insert(attachment, at: 0)
        try save(supplemental, summaryId: summaryId)

        return attachment
    }

    func removeAttachment(_ attachment: SummaryAttachment, summaryId: UUID) throws {
        let fileURL = fileURL(for: attachment, summaryId: summaryId)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        var supplemental = load(for: summaryId)
        supplemental.attachments.removeAll { $0.id == attachment.id }
        try save(supplemental, summaryId: summaryId)
    }

    func saveUserNotes(_ notes: String?, summaryId: UUID) throws {
        var supplemental = load(for: summaryId)
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        supplemental.userNotes = (trimmed?.isEmpty == true) ? nil : trimmed
        try save(supplemental, summaryId: summaryId)
    }

    func deleteAll(for summaryId: UUID) throws {
        let dir = storageDirectory(for: summaryId)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    /// Moves supplemental data (notes + attachments) from one summary ID to another.
    /// Used when a summary is regenerated and receives a new UUID so existing user
    /// data is not orphaned.
    func migrate(from oldSummaryId: UUID, to newSummaryId: UUID) throws {
        let oldDir = storageDirectory(for: oldSummaryId)
        guard fileManager.fileExists(atPath: oldDir.path) else { return }
        let newDir = storageDirectory(for: newSummaryId)
        if fileManager.fileExists(atPath: newDir.path) {
            try fileManager.removeItem(at: newDir)
        }
        try fileManager.moveItem(at: oldDir, to: newDir)
        AppFileProtection.applyRecursively(to: newDir)
    }

    /// Attachment folders whose summary no longer exists.
    ///
    /// Several paths remove a summary row without touching its files — Core Data
    /// cascade deletes when a recording goes, and the batch delete behind "clear
    /// all data" bypasses relationship callbacks entirely — so the folders
    /// accumulate unreachable. Reconciling against the store catches all of them
    /// at once, including any path added later.
    ///
    /// Only directories named as a UUID are considered, so nothing else living
    /// under the root is ever a candidate.
    func orphanedSummaryIds(knownSummaryIds: Set<UUID>) -> [UUID] {
        let root = rootDirectory()
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let contents = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.compactMap { url in
            guard let summaryId = UUID(uuidString: url.lastPathComponent) else { return nil }
            guard !knownSummaryIds.contains(summaryId) else { return nil }
            return summaryId
        }
    }

    /// Reconciles the attachment folders against a Core Data context and removes
    /// the ones whose summary is gone. Returns nil when the store could not be
    /// read, which callers must not treat as "no summaries exist".
    @discardableResult
    func pruneOrphans(against context: NSManagedObjectContext) -> Int? {
        let request: NSFetchRequest<SummaryEntry> = SummaryEntry.fetchRequest()
        guard let summaries = try? context.fetch(request) else {
            AppLog.shared.coreData(
                "Skipped orphaned attachment cleanup: summaries could not be read",
                level: .error
            )
            return nil
        }

        let removed = deleteOrphaned(knownSummaryIds: Set(summaries.compactMap { $0.id }))
        if removed > 0 {
            AppLog.shared.coreData("Removed \(removed) orphaned summary attachment folder(s)")
        }
        return removed
    }

    /// Removes the folders `orphanedSummaryIds` reported. Returns how many went.
    ///
    /// `knownSummaryIds` must come from a *successful* read of the store. Passing
    /// an empty set because a fetch failed would delete every attachment the user
    /// has, so the caller owns that guarantee and this deliberately does not
    /// second-guess an empty set — a genuinely empty store has no attachments to
    /// keep.
    @discardableResult
    func deleteOrphaned(knownSummaryIds: Set<UUID>) -> Int {
        var removed = 0
        for summaryId in orphanedSummaryIds(knownSummaryIds: knownSummaryIds) {
            do {
                try deleteAll(for: summaryId)
                removed += 1
            } catch {
                AppLog.shared.coreData(
                    "Could not remove orphaned attachments for \(summaryId.uuidString): \(error)",
                    level: .error
                )
            }
        }
        return removed
    }

    func fileURL(for attachment: SummaryAttachment, summaryId: UUID) -> URL {
        attachmentsDirectory(for: summaryId).appendingPathComponent(attachment.storedFileName)
    }

    private func save(_ supplemental: SummarySupplementalData, summaryId: UUID) throws {
        let directory = storageDirectory(for: summaryId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        AppFileProtection.apply(to: directory)
        let metadataURL = metadataFileURL(for: summaryId)
        let data = try encoder.encode(supplemental)
        try data.write(to: metadataURL, options: .atomic)
        AppFileProtection.apply(to: metadataURL)
    }

    private func rootDirectory() -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return documents.appendingPathComponent("SummaryAttachments", isDirectory: true)
    }

    private func storageDirectory(for summaryId: UUID) -> URL {
        rootDirectory().appendingPathComponent(summaryId.uuidString, isDirectory: true)
    }

    private func attachmentsDirectory(for summaryId: UUID) -> URL {
        storageDirectory(for: summaryId).appendingPathComponent("files", isDirectory: true)
    }

    private func metadataFileURL(for summaryId: UUID) -> URL {
        storageDirectory(for: summaryId).appendingPathComponent("metadata.json")
    }

    private func sanitizeFileName(_ fileName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return fileName.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
}
