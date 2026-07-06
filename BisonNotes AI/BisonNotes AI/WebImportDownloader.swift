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
    private let maxMediaDownloadSize: Int64 = 2 * 1024 * 1024 * 1024
    private let maxTranscriptDownloadSize: Int64 = 50 * 1024 * 1024

    private var mimeExtensions: [String: String] {
        [
            "audio/mpeg": "mp3",
            "audio/mp3": "mp3",
            "audio/mp4": "m4a",
            "audio/x-m4a": "m4a",
            "audio/aac": "m4a",
            "audio/wav": "wav",
            "audio/x-wav": "wav",
            "video/mp4": "mp4",
            "video/quicktime": "mov",
            "text/vtt": "vtt",
            "application/pdf": "pdf",
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
            "application/msword": "doc"
        ]
    }

    func downloadRemoteFile(
        from url: URL,
        preferredKind: WebImportKind
    ) async throws -> DownloadedWebFile {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 120
        request.setValue("BisonNotesAI/1.0", forHTTPHeaderField: "User-Agent")

        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebImportError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WebImportError.httpStatus(httpResponse.statusCode)
        }

        let mimeType = httpResponse.mimeType?.lowercased()
        let route = try routeForRemoteFile(
            url: url,
            mimeType: mimeType,
            preferredKind: preferredKind
        )

        try validateDownloadSize(
            response: httpResponse,
            localURL: temporaryURL,
            route: route
        )

        let destinationURL = try moveToImportTempDirectory(
            temporaryURL,
            sourceURL: url,
            response: httpResponse,
            mimeType: mimeType,
            route: route
        )

        return DownloadedWebFile(localURL: destinationURL, route: route)
    }

    private func routeForRemoteFile(
        url: URL,
        mimeType: String?,
        preferredKind: WebImportKind
    ) throws -> WebImportRoute {
        let detectedRoute = routeFromExtension(url.pathExtension)
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
        if mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/") {
            return .audioOrVideo
        }
        if mimeType.hasPrefix("text/")
            || mimeType.contains("pdf")
            || mimeType.contains("wordprocessingml")
            || mimeType.contains("msword") {
            return .transcript
        }
        return nil
    }

    private func validateDownloadSize(
        response: HTTPURLResponse,
        localURL: URL,
        route: WebImportRoute
    ) throws {
        let sizeLimit = route == .transcript ? maxTranscriptDownloadSize : maxMediaDownloadSize
        if response.expectedContentLength > sizeLimit {
            throw WebImportError.fileTooLarge(response.expectedContentLength, sizeLimit)
        }

        let fileSize = try fileSize(at: localURL)
        guard fileSize <= sizeLimit else {
            throw WebImportError.fileTooLarge(fileSize, sizeLimit)
        }
    }

    private func moveToImportTempDirectory(
        _ temporaryURL: URL,
        sourceURL: URL,
        response: HTTPURLResponse,
        mimeType: String?,
        route: WebImportRoute
    ) throws -> URL {
        let fileExtension = inferredFileExtension(
            from: sourceURL,
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

        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func inferredFileExtension(
        from url: URL,
        mimeType: String?,
        route: WebImportRoute
    ) -> String {
        if let routeExtension = routeExtension(from: url.pathExtension) {
            return routeExtension
        }

        if let mimeType, let mappedExtension = mimeExtensions[mimeType] {
            return mappedExtension
        }

        if mimeType?.hasPrefix("text/") == true {
            return "txt"
        }

        return route == .transcript ? "txt" : "m4a"
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

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.size] as? Int64 ?? 0
    }
}
