//
//  WebImportDownloader.swift
//  BisonNotes AI
//
//  Downloads direct audio, video, and transcript URLs to temporary files.
//

import Foundation

struct WebImportDownloader {
    private let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "caf", "aiff", "aif"]
    private let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv"]
    private let transcriptExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "vtt", "srt", "pdf", "doc", "docx"
    ]
    private let sessionConfiguration: URLSessionConfiguration
    private let maxMediaDownloadSize: Int64
    private let maxTranscriptDownloadSize: Int64

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        maxMediaDownloadSize: Int64 = 2 * 1024 * 1024 * 1024,
        maxTranscriptDownloadSize: Int64 = 50 * 1024 * 1024
    ) {
        let configuration = sessionConfiguration.copy() as? URLSessionConfiguration
            ?? URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil

        self.sessionConfiguration = configuration
        self.maxMediaDownloadSize = maxMediaDownloadSize
        self.maxTranscriptDownloadSize = maxTranscriptDownloadSize
    }

    private var mimeExtensions: [String: String] {
        [
            "audio/mpeg": "mp3",
            "audio/mp3": "mp3",
            "audio/mp4": "m4a",
            "audio/x-m4a": "m4a",
            "audio/wav": "wav",
            "audio/x-wav": "wav",
            "audio/vnd.wave": "wav",
            "audio/x-caf": "caf",
            "audio/aiff": "aiff",
            "audio/x-aiff": "aiff",
            "video/mp4": "mp4",
            "video/quicktime": "mov",
            "video/x-m4v": "m4v",
            "video/x-msvideo": "avi",
            "video/x-matroska": "mkv",
            "text/plain": "txt",
            "text/markdown": "md",
            "text/vtt": "vtt",
            "application/x-subrip": "srt",
            "application/pdf": "pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/msword": "doc"
        ]
    }

    func downloadRemoteFile(
        from url: URL,
        preferredKind: WebImportKind
    ) async throws -> DownloadedWebFile {
        guard Self.isAllowedDownloadURL(url) else {
            throw WebImportError.insecureURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.setValue("BisonNotesAI/1.0", forHTTPHeaderField: "User-Agent")

        let stagingURL = try makeProtectedStagingFile()

        do {
            let transfer = BoundedWebImportTransfer(
                configuration: sessionConfiguration,
                stagingURL: stagingURL,
                routeResolver: { response in
                    try routeForRemoteFile(
                        url: response.url ?? url,
                        mimeType: response.mimeType?.lowercased(),
                        suggestedFilename: filename(from: response),
                        preferredKind: preferredKind
                    )
                },
                sizeLimit: { route in
                    route == .transcript ? maxTranscriptDownloadSize : maxMediaDownloadSize
                }
            )
            let result = try await transfer.start(request: request)
            let mimeType = result.response.mimeType?.lowercased()
            let destinationURL = try moveToImportTempDirectory(
                stagingURL,
                sourceURL: result.response.url ?? url,
                response: result.response,
                mimeType: mimeType,
                route: result.route
            )

            return DownloadedWebFile(localURL: destinationURL, route: result.route)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && EndpointSecurityPolicy.isAllowed(endpoint: url.absoluteString)
    }

    private func routeForRemoteFile(
        url: URL,
        mimeType: String?,
        suggestedFilename: String?,
        preferredKind: WebImportKind
    ) throws -> WebImportRoute {
        let detectedRoute = routeFromExtension(url.pathExtension)
            ?? routeFromExtension(URL(fileURLWithPath: suggestedFilename ?? "").pathExtension)
            ?? routeFromMIME(mimeType)

        switch preferredKind {
        case .automatic:
            if let detectedRoute { return detectedRoute }
        case .audioOrVideo:
            if detectedRoute == .audioOrVideo { return .audioOrVideo }
        case .transcript:
            if detectedRoute == .transcript { return .transcript }
        }

        throw WebImportError.unsupportedRemoteType
    }

    private func routeFromExtension(_ fileExtension: String) -> WebImportRoute? {
        let lowercased = fileExtension.lowercased()
        if audioExtensions.contains(lowercased) || videoExtensions.contains(lowercased) {
            return .audioOrVideo
        }
        if transcriptExtensions.contains(lowercased) {
            return .transcript
        }
        return nil
    }

    private func routeFromMIME(_ mimeType: String?) -> WebImportRoute? {
        guard let mimeType else { return nil }
        if mimeType.hasPrefix("text/") {
            return .transcript
        }
        guard let mappedExtension = mimeExtensions[mimeType] else { return nil }
        if audioExtensions.contains(mappedExtension) || videoExtensions.contains(mappedExtension) {
            return .audioOrVideo
        }
        if transcriptExtensions.contains(mappedExtension) {
            return .transcript
        }
        return nil
    }

    private func makeProtectedStagingFile() throws -> URL {
        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesWebImports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        AppFileProtection.apply(to: destinationDirectory)

        let stagingURL = destinationDirectory
            .appendingPathComponent(".download-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        AppFileProtection.apply(to: stagingURL)
        return stagingURL
    }

    private func moveToImportTempDirectory(
        _ temporaryURL: URL,
        sourceURL: URL,
        response: HTTPURLResponse,
        mimeType: String?,
        route: WebImportRoute
    ) throws -> URL {
        let fileExtension = try inferredFileExtension(
            from: sourceURL,
            response: response,
            mimeType: mimeType,
            route: route
        )
        let filename = uniqueTemporaryFilename(
            suggestedFilename: filename(from: response)
                ?? sourceURL.deletingPathExtension().lastPathComponent,
            fileExtension: fileExtension
        )

        let destinationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisonNotesWebImports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        AppFileProtection.apply(to: destinationDirectory)

        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        AppFileProtection.apply(to: destinationURL)
        return destinationURL
    }

    private func inferredFileExtension(
        from url: URL,
        response: HTTPURLResponse,
        mimeType: String?,
        route: WebImportRoute
    ) throws -> String {
        if let routeExtension = routeExtension(from: url.pathExtension) {
            return routeExtension
        }

        if let dispositionFilename = filename(from: response),
           let dispositionExtension = routeExtension(
               from: URL(fileURLWithPath: dispositionFilename).pathExtension
           ) {
            return dispositionExtension
        }

        if let mimeType, let mappedExtension = mimeExtensions[mimeType] {
            return mappedExtension
        }

        if mimeType?.hasPrefix("text/") == true {
            return "txt"
        }

        // Reaching the transcript fallback means the route came from a generic
        // text MIME. Unknown media MIME types are rejected before downloading.
        guard route == .transcript else {
            throw WebImportError.unsupportedRemoteType
        }
        return "txt"
    }

    private func routeExtension(from fileExtension: String) -> String? {
        let lowercased = fileExtension.lowercased()
        if audioExtensions.contains(lowercased)
            || videoExtensions.contains(lowercased)
            || transcriptExtensions.contains(lowercased) {
            return lowercased
        }
        return nil
    }

    private func filename(from response: HTTPURLResponse) -> String? {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }

        for part in disposition.components(separatedBy: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let filename = decodedFilename(from: trimmed) {
                return filename
            }
        }

        return nil
    }

    private func decodedFilename(from dispositionPart: String) -> String? {
        let lowercased = dispositionPart.lowercased()
        guard let value = dispositionPart.split(separator: "=", maxSplits: 1).last else {
            return nil
        }

        if lowercased.hasPrefix("filename*=") {
            let decoded = value
                .replacingOccurrences(of: "UTF-8''", with: "")
                .replacingOccurrences(of: "\"", with: "")
                .removingPercentEncoding
            return decoded?.isEmpty == false ? decoded : nil
        }

        if lowercased.hasPrefix("filename=") {
            let filename = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return filename.isEmpty ? nil : filename
        }

        return nil
    }

    private func uniqueTemporaryFilename(
        suggestedFilename: String,
        fileExtension: String
    ) -> String {
        let baseName = suggestedFilename
            .split(separator: ".")
            .first
            .map(String.init) ?? "web-import"
        let sanitized = sanitizeFilename(baseName)
        let sanitizedBase = sanitized.isEmpty ? "web-import" : sanitized
        let limitedBase = String(sanitizedBase.prefix(80))
        return "\(limitedBase)-\(UUID().uuidString).\(fileExtension)"
    }

    private func sanitizeFilename(_ filename: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()"))
        return filename.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
    }
}
