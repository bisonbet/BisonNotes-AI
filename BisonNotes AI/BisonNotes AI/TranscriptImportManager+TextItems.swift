//
//  TranscriptImportManager+TextItems.swift
//  BisonNotes AI
//
//  Imports transcript text that has already been loaded from another source.
//

import Foundation

struct TranscriptTextImportItem {
    let text: String
    let name: String
}

extension TranscriptImportManager {
    func importTranscriptTextItems(_ items: [TranscriptTextImportItem]) async {
        guard !isImporting else { return }

        isImporting = true
        importProgress = 0.0
        currentlyImporting = "Preparing..."

        let totalCount = items.count
        guard totalCount > 0 else {
            completeImport(with: TranscriptImportResults(total: 0, successful: 0, failed: 0, errors: []))
            return
        }

        var successful = 0
        var failed = 0
        var errors: [String] = []

        for (index, item) in items.enumerated() {
            currentlyImporting = "Importing \(item.name)..."
            importProgress = Double(index) / Double(totalCount)

            do {
                // Text items (pasted transcripts, YouTube captions) skip the file-size check
                // file-based import gets from `validateFileSize`; enforce the same cap here.
                guard item.text.utf8.count <= TranscriptImportManager.FileSizeLimits.maxTextFileSize else {
                    let maxMB = Double(TranscriptImportManager.FileSizeLimits.maxTextFileSize) / (1024 * 1024)
                    throw TranscriptImportError.readFailed(
                        "Transcript text is too large (maximum \(String(format: "%.0f", maxMB)) MB)"
                    )
                }
                _ = try await importTranscript(text: item.text, name: item.name)
                successful += 1
            } catch {
                failed += 1
                errors.append("\(item.name): \(error.localizedDescription)")
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        importProgress = 1.0
        currentlyImporting = "Complete"

        completeImport(with: TranscriptImportResults(
            total: totalCount,
            successful: successful,
            failed: failed,
            errors: errors
        ))
    }
}
