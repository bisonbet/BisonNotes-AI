import Foundation

struct SummarySupplementalData: Codable, Sendable {
    var userNotes: String?
    var attachments: [SummaryAttachment]

    static let empty = SummarySupplementalData(userNotes: nil, attachments: [])
}

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

        let sanitizedName = sanitizeFileName(fileName)
        let storedFileName = "\(id.uuidString)_\(sanitizedName)"
        let destinationURL = destinationFolder.appendingPathComponent(storedFileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let attributes = try? fileManager.attributesOfItem(atPath: destinationURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let attachment = SummaryAttachment(
            id: id,
            fileName: fileName,
            storedFileName: storedFileName,
            contentType: nil,
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
        supplemental.userNotes = (trimmed?.isEmpty == true) ? nil : notes
        try save(supplemental, summaryId: summaryId)
    }

    func fileURL(for attachment: SummaryAttachment, summaryId: UUID) -> URL {
        attachmentsDirectory(for: summaryId).appendingPathComponent(attachment.storedFileName)
    }

    private func save(_ supplemental: SummarySupplementalData, summaryId: UUID) throws {
        let directory = storageDirectory(for: summaryId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadataURL = metadataFileURL(for: summaryId)
        let data = try encoder.encode(supplemental)
        try data.write(to: metadataURL, options: .atomic)
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
