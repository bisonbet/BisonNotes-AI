//
//  WebImportManager.swift
//  BisonNotes AI
//
//  Coordinates imports from web addresses.
//

import Foundation

@MainActor
final class WebImportManager: ObservableObject {
    @Published var isImporting = false
    @Published var currentlyImporting = ""
    @Published var showingImportAlert = false
    @Published var importMessage = ""
    @Published var youtubeRecovery: YouTubeImportRecovery?
    @Published private(set) var lastImportSucceeded = false

    private let downloader: WebImportDownloader
    private let youtubeService = YouTubeImportService()

    init(downloader: WebImportDownloader = WebImportDownloader()) {
        self.downloader = downloader
    }

    func importFromURLString(
        _ rawURLString: String,
        importKind: WebImportKind,
        fileImportManager: FileImportManager,
        transcriptImportManager: TranscriptImportManager
    ) async {
        guard !isImporting else { return }

        isImporting = true
        currentlyImporting = "Preparing..."
        showingImportAlert = false
        importMessage = ""
        youtubeRecovery = nil
        lastImportSucceeded = false

        defer {
            isImporting = false
            currentlyImporting = ""
        }

        do {
            let url = try normalizedURL(from: rawURLString)

            if WebImportURLClassifier.isYouTubeURL(url) {
                try await importYouTubeURL(
                    url,
                    importKind: importKind,
                    transcriptImportManager: transcriptImportManager
                )
                lastImportSucceeded = true
                return
            }

            try await importRemoteFile(
                from: url,
                importKind: importKind,
                fileImportManager: fileImportManager,
                transcriptImportManager: transcriptImportManager
            )
        } catch {
            if configureYouTubeRecovery(for: rawURLString, error: error) {
                AppLog.shared.fileManagement(
                    "YouTube import needs manual transcript recovery: \(error.localizedDescription)",
                    level: .error
                )
                return
            }

            importMessage = error.localizedDescription
            showingImportAlert = true
            AppLog.shared.fileManagement(
                "Web import failed: \(error.localizedDescription)",
                level: .error
            )
        }
    }

    func clearYouTubeRecovery() {
        youtubeRecovery = nil
    }

    private func importRemoteFile(
        from url: URL,
        importKind: WebImportKind,
        fileImportManager: FileImportManager,
        transcriptImportManager: TranscriptImportManager
    ) async throws {
        currentlyImporting = "Downloading..."
        let downloaded = try await downloader.downloadRemoteFile(
            from: url,
            preferredKind: importKind
        )
        defer { try? FileManager.default.removeItem(at: downloaded.localURL) }

        switch downloaded.route {
        case .audioOrVideo:
            currentlyImporting = "Importing audio..."
            await fileImportManager.importAudioFiles(from: [downloaded.localURL])
            let results = fileImportManager.importResults
            fileImportManager.showingImportAlert = false
            guard (results?.successful ?? 0) > 0 else {
                throw WebImportError.importedFileRejected(
                    firstFailureReason(in: results?.errors) ?? "The audio file was rejected."
                )
            }
            lastImportSucceeded = true
        case .transcript:
            currentlyImporting = "Importing transcript..."
            await transcriptImportManager.importTranscriptFiles(from: [downloaded.localURL])
            let results = transcriptImportManager.importResults
            transcriptImportManager.showingImportAlert = false
            guard (results?.successful ?? 0) > 0 else {
                throw WebImportError.importedFileRejected(
                    firstFailureReason(in: results?.errors) ?? "The transcript file was rejected."
                )
            }
            lastImportSucceeded = true
        }
    }

    private func firstFailureReason(in errors: [String]?) -> String? {
        guard let error = errors?.first else { return nil }
        guard let separator = error.range(of: ": ") else { return error }
        return String(error[separator.upperBound...])
    }

    private func importYouTubeURL(
        _ url: URL,
        importKind: WebImportKind,
        transcriptImportManager: TranscriptImportManager
    ) async throws {
        guard importKind != .audioOrVideo else {
            throw WebImportError.youtubeAudioUnsupported
        }

        currentlyImporting = "Importing YouTube captions..."
        let item = try await youtubeService.transcriptItem(from: url)
        await transcriptImportManager.importTranscriptTextItems([item])

        guard (transcriptImportManager.importResults?.successful ?? 0) > 0 else {
            throw WebImportError.transcriptImportFailed
        }
    }

    private func normalizedURL(from rawURLString: String) throws -> URL {
        var trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebImportError.invalidURL
        }

        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw WebImportError.invalidURL
        }

        if scheme == "http", !EndpointSecurityPolicy.isAllowed(endpoint: url.absoluteString) {
            throw WebImportError.insecureURL
        }

        return url
    }

    private func configureYouTubeRecovery(for rawURLString: String, error: Error) -> Bool {
        guard let webImportError = error as? WebImportError,
              case .youtubeRateLimited = webImportError,
              let url = try? normalizedURL(from: rawURLString),
              let videoID = WebImportURLClassifier.youtubeVideoID(from: url) else {
            return false
        }

        importMessage = webImportError.localizedDescription
        youtubeRecovery = YouTubeImportRecovery(videoURL: url, videoID: videoID)
        return true
    }
}
